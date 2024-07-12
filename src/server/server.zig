const std = @import("std");
const proto = @import("../proto.zig");
const buffer = @import("../buffer.zig");

const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.websocket);

const OpCode = proto.OpCode;
const Reader = proto.Reader;
const Message = proto.Message;
const Handshake = @import("handshake.zig").Handshake;

const MAX_TIMEOUT = 2_147_483_647;
const DEFAULT_WORKER_COUNT = 1;
const DEFAULT_MAX_HANDSHAKE_SIZE = 1024;

const EMPTY_PONG = ([2]u8{ @intFromEnum(OpCode.pong), 0 })[0..];
// CLOSE, 2 length, code
const CLOSE_NORMAL = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 234 })[0..]; //code: 1002

const force_blocking: bool = blk: {
	const build = @import("build");
	if (@hasDecl(build, "force_blocking")) {
		break :blk  build.force_blocking;
	}
	break :blk false;
};

pub fn blockingMode() bool {
	return true;
	// if (force_blocking) {
	// 	return true;
	// }
	// return switch (builtin.os.tag) {
	// 	.linux, .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => false,
	// 	else => true,
	// };
}

pub const Config = struct {
	port: ?u16 = null,
	address: []const u8 = "127.0.0.1",
	unix_path: ?[]const u8 = null,

	max_message_size: usize = 65536,
	connection_buffer_size: usize = 4096,

	handshake: Config.Handshake = .{},
	shutdown: Shutdown = .{},
	thread_pool: ThreadPool = .{},
	large_buffers: Config.LargeBuffers = .{},

	pub const ThreadPool = struct {
		count: ?u16 = null,
		backlog: ?u32 = null,
		buffer_size: ?usize = null,
	};

	const Shutdown = struct {
		close_socket: bool = true,
		notify_client: bool = true,
		notify_handler: bool = true,
	};

	const Handshake = struct {
		timeout: ?u32 = null,
		max_size: ?u16 = null,
		max_headers: ?u16 = null,
		pool_count: ?u16 = null,
	};

	const LargeBuffers = struct {
		count: ?u16 = null,
		size: ?usize = null,
	};
};

pub fn Server(comptime H: type) type {
	return struct {
		config: Config,
		allocator: Allocator,
		cond: Thread.Condition,

		// these aren't used by the server themselves, but both Blocking and NonBlocking
		// workers need them, so we put them here, and reference them in the workers,
		// to avoid the duplicate code.
		bp: buffer.Provider,
		hp: Handshake.Pool,

		const Self = @This();

		pub fn init(allocator: Allocator, config: Config) !Self {
			var bp = try buffer.Provider.init(allocator, .{
				.max = config.max_message_size,
				.count = config.large_buffers.count orelse 8,
				.size = config.large_buffers.size orelse @min(config.max_message_size * 2, config.max_message_size),
			});
			errdefer bp.deinit();

			var hp = try Handshake.Pool.init(allocator, config.handshake.pool_count orelse 32, config.handshake.max_size orelse 1024, config.handshake.max_headers orelse 10);
			errdefer hp.deinit();

			return .{
				.bp = bp,
				.hp = hp,
				.cond = .{},
				.config = config,
				.allocator = allocator,
			};
		}

		pub fn deinit(self: *Self) void {
			self.bp.deinit();
			self.hp.deinit();
		}

		pub fn listenInNewThread(self: *Self, context: anytype) !Thread {
			return try Thread.spawn(.{}, Self.listen, .{self, context});
		}

		pub fn listen(self: *Self, context: anytype) !void {
			const config = &self.config;

			var no_delay = true;
			const address = blk: {
				if (config.unix_path) |unix_path| {
					if (comptime @import("builtin").os.tag == .windows) {
						return error.UnixPathNotSupported;
					}
					no_delay = false;
					std.fs.deleteFileAbsolute(unix_path) catch {};
					break :blk try net.Address.initUnix(unix_path);
				} else {
					const listen_port = config.port.?;
					const listen_address = config.address;
					break :blk try net.Address.parseIp(listen_address, listen_port);
				}
			};

			const socket = blk: {
				var sock_flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
				if (blockingMode() == false) sock_flags |= posix.SOCK.NONBLOCK;

				const socket_proto = if (address.any.family == posix.AF.UNIX) @as(u32, 0) else posix.IPPROTO.TCP;
				break :blk try posix.socket(address.any.family, sock_flags, socket_proto);
			};

			if (no_delay) {
					// TODO: Broken on darwin:
					// https://github.com/ziglang/zig/issues/17260
					// if (@hasDecl(os.TCP, "NODELAY")) {
					//  try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
					// }
					try posix.setsockopt(socket, posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
			}

			if (@hasDecl(posix.SO, "REUSEPORT_LB")) {
					try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
			} else if (@hasDecl(posix.SO, "REUSEPORT")) {
					try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
			} else {
					try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
			}

			{
				const socklen = address.getOsSockLen();
				try posix.bind(socket, &address.any, socklen);
				try posix.listen(socket, 1024); // kernel backlog
			}

			// used to block our thread until stop() is called
			var mutex = Thread.Mutex{};
			mutex.lock();

			if (comptime blockingMode()) {
				errdefer posix.close(socket);
				var w = try Blocking(H).init(self);
				defer w.deinit();

				const thrd = try std.Thread.spawn(.{}, Blocking(H).listen, .{&w, socket, context});
				log.info("starting blocking worker to listen on {}", .{address});

				// is this really the best way?

				self.cond.wait(&mutex);
				mutex.unlock();
				w.stop();
				posix.close(socket);
				thrd.join();
			} else {
				defer posix.close(socket);
				const signals = try posix.pipe2(.{.NONBLOCK = true});

				var w = try NonBlocking(H).init(self);
				defer w.deinit();

				const thrd = try Thread.spawn(.{}, NonBlocking(H).listen, .{&w, socket, signals[0], context});
				log.info("starting nonblocking worker to listen on {}", .{address});

				// is this really the best way?
				self.cond.wait(&mutex);
				mutex.unlock();
				posix.close(signals[1]);
				thrd.join();
				w.deinit();
			}
		}

		pub fn stop(self: *Self) void {
			self.cond.signal();
		}
	};
}

// This is our Blocking worker. It's very different than NonBlocking and much simpler.
fn Blocking(comptime H: type) type {
	return struct {
		running: bool,
		hp: *Handshake.Pool,
		bp: *buffer.Provider,
		allocator: Allocator,
		config: *const Config,
		handshake_timeout: Timeout,
		handshake_max_size: u16,
		handshake_max_headers: u16,

		// protects access to the conn_list and conn_pool
		conn_lock: Thread.Mutex,
		conn_list: List(HandlerConn(H)),
		conn_pool: std.heap.MemoryPool(HandlerConn(H)),

		const Timeout = struct {
			sec: u32,
			timeval: [@sizeOf(std.posix.timeval)]u8,

			// if sec is null, it means we want to cancel the timeout.
			fn init(sec: ?u32) Timeout {
				return .{
					.sec = if (sec) |s| s else MAX_TIMEOUT,
					.timeval = std.mem.toBytes(posix.timeval{ .tv_sec = @intCast(sec orelse 0), .tv_usec = 0 }),
				};
			}
		};

		const Self = @This();

		pub fn init(server: *Server(H)) !Self {
			const config = &server.config;
			const allocator = server.allocator;

			var conn_pool = std.heap.MemoryPool(HandlerConn(H)).init(allocator);
			errdefer conn_pool.deinit();

			return .{
				.bp = &server.bp,
				.hp = &server.hp,
				.running = true,
				.config = config,
				.conn_list = .{},
				.conn_lock = .{},
				.conn_pool = conn_pool,
				.allocator = allocator,
				.handshake_timeout = Timeout.init(config.handshake.timeout orelse MAX_TIMEOUT),
				.handshake_max_size = config.handshake.max_size orelse DEFAULT_MAX_HANDSHAKE_SIZE,
				.handshake_max_headers = config.handshake.max_headers orelse 0,
			};
		}

		pub fn deinit(self: *Self) void {
			closeAll(H, self.conn_list, &self.conn_pool, self.config.shutdown);
			self.conn_pool.deinit();
		}

		pub fn stop(self: *Self) void {
			@atomicStore(bool, &self.running, false, .monotonic);
		}

		pub fn listen(self: *Self, listener: posix.socket_t, context: anytype) void {
			while (true) {
				var address: net.Address = undefined;
				var address_len: posix.socklen_t = @sizeOf(net.Address);
				const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
					if (@atomicLoad(bool, &self.running, .monotonic) == false) {
						return;
					}
					log.err("failed to accept socket: {}", .{err});
					continue;
				};
				log.debug("({}) connected", .{address});

				const thread = std.Thread.spawn(.{}, Self.handleConnection, .{self, socket, address, context}) catch |err| {
					posix.close(socket);
					log.err("({}) failed to spawn connection thread: {}", .{address, err});
					continue;
				};
				thread.detach();
			}
		}

		// Called in a thread started above in listen.
		// Wrapper around _handleConnection so that we can handle erros
		fn handleConnection(self: *Self, socket: posix.socket_t, address: net.Address, context: anytype) void {
			self._handleConnection(socket, address, context) catch |err| {
				log.err("({}) uncaught error in connection handler: {}", .{address, err});
			};
		}

		fn _handleConnection(self: *Self, socket: posix.socket_t, address: net.Address, context: anytype) !void {
			const hc = blk: {
				errdefer posix.close(socket);

				self.conn_lock.lock();
				defer self.conn_lock.unlock();

				const hc = try self.conn_pool.create();
				hc.* = .{
					.handshake = null,
					.socket = socket,
					.reader = undefined,
					.handler = undefined,
					.conn = .{
						._closed = false,
						._rw_mode = .none,
						._io_mode = .blocking,
						._socket_flags = 0, // not needed in the blocking worker
						.address = address,
						.stream = .{.handle = socket},
					},
				};

				self.conn_list.insert(hc);
				break :blk hc;
			};

			var conn = &hc.conn;

			defer {
				conn.close();
				self.conn_lock.lock();
				self.conn_list.remove(hc);
				self.conn_pool.destroy(hc);
				self.conn_lock.unlock();
			}

			hc.handler = (try self.doHandshake(conn, context)) orelse return;

			defer if (comptime std.meta.hasFn(H, "close")) {
				hc.handler.close();
			};

			if (comptime std.meta.hasFn(H, "afterInit")) {
				hc.handler.afterInit() catch |err| {
					log.debug("({}) " ++ @typeName(H) ++ ".afterInit error: {}", .{address, err});
					return;
				};
			}

			// we delay initializing the reader until AFTER the handshake to avoid
			// unecessarily acllocate config.buffer_size
			hc.reader = Reader.init(self.config.connection_buffer_size, self.bp) catch |err| {
				log.err("({}) error creating reader: {}", .{address, err});
				return;
			};

			var reader = &hc.reader;
			defer reader.deinit();

			log.debug("({}) connection successfully upgraded", .{address});

			while (true) {

				// fill our reader buffer with more data
				reader.fill(hc.conn.stream) catch |err| {
					switch (err) {
						error.BrokenPipe, error.Closed, error.ConnectionResetByPeer => log.debug("({}) connection closed: {}", .{address, err}),
						else => log.warn("({}) error reading from connection: {}", .{address, err}),
					}
					return;
				};

				while (true) {
					const has_more, const message = reader.read() catch |err| {
						switch (err) {
							error.LargeControl => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
							error.ReservedFlags => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
							else => {},
						}
						log.debug("({}) invalid websocket packet: {}", .{address, err});
						return;
					} orelse break; // orelse, we need more data, go back to fill the buffer from the stream

					// Is it ok to swallow these errors?
					// It should be. handleMesage doesn't do any allocations.
					// The error is either a result of a failed socket write, or an
					// error returned by the handler, which, if the app cares about, they
					// can handle within the handler itself.
					handleMessage(H, hc, message) catch |err| {
						log.warn("({}) handle message error: {}", .{address, err});
						return;
					};

					if (conn.isClosed()) {
						return;
					}

					if (has_more == false) {
						// we don't have more data ready to be processed in our buffer
						// break out of the inner loop, back to the outer loop, where
						// we'll read more from the stream into our buffer
						break;
					}
				}
			}
		}

		fn doHandshake(self: *Self, conn: *Conn, context: anytype) !?H {
			var arena = std.heap.ArenaAllocator.init(self.allocator);
			defer arena.deinit();

			const state = try self.hp.acquire();
			defer self.hp.release(state);

			const handshake = self.readHandshake(conn, state) catch |err| {
				log.debug("({}) error reading handshake: {}", .{conn.address, err});
				respondToHandshakeError(conn, err);
				return null;
			};

			var handler = H.init(handshake, conn, context) catch |err| {
				if (comptime std.meta.hasFn(H, "handshakeErrorResponse")) {
					preHandOffWrite(H.handshakeErrorResponse(err));
				} else {
					respondToHandshakeError(conn, err);
				}
				log.debug("({}) " ++ @typeName(H) ++ ".init rejected request {}", .{conn.address, err});
				return null;
			};

			conn.writeFramed(&handshake.reply()) catch |err| {
				if (comptime std.meta.hasFn(H, "close")) {
					handler.close();
				}
				log.warn("({}) error writing handshake response: {}", .{conn.address, err});
				return null;
			};
			return handler;
		}

		fn readHandshake(self: *Self, conn: *Conn, state: *Handshake.State) !Handshake {
			const socket = conn.stream.handle;
			const timeout = self.handshake_timeout;
			const deadline = timestamp() + timeout.sec;

			var buf = state.buf;
			while (state.len < buf.len) {
				const n = try posix.read(socket, buf[state.len..]);
				if (n == 0) {
					return error.Close;
				}

				state.len += n;
				if (try Handshake.parse(state)) |handshake| {
					return handshake;
				}

				// else, we need more data

				if (timestamp() > deadline) {
					return error.Timeout;
				}
			}
			return error.RequestTooLarge;
		}
	};
}

fn NonBlocking(comptime H: type) type {
	const ThreadPool = @import("thread_pool.zig").ThreadPool(NonBlocking(H).dataAvailable);

	return struct {
		// KQueue or Epoll, depending on the platform
		loop: Loop,
		allocator: Allocator,
		config: *const Config,

		bp: *buffer.Provider,
		hp: *Handshake.Pool,
		tp: ThreadPool,

		max_conn: usize,
		conn_list: List(HandlerConn(H)),
		conn_pool: std.heap.MemoryPool(HandlerConn(H)),

		const Self = @This();

		const Loop = switch (@import("builtin").os.tag) {
			.macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => KQueue(H),
			.linux => EPoll(H),
			else => unreachable,
		};

		pub fn init(server: *Server(H)) !Self {
			const config = &server.config;
			const allocator = server.allocator;

			const loop = try Loop.init();
			errdefer loop.deinit();

			const conn_pool = std.heap.MemoryPool(HandlerConn(H)).init(allocator);
			errdefer conn_pool.deinit();

			var tp = try ThreadPool.init(allocator, .{
				.count = config.thread_pool.count,
				.backlog = config.thread_pool.backlog orelse 500,
				.buffer_size = config.thread_pool.buffer_size orelse 32_768,
			});
			errdefer tp.deinit();

			return .{
				.loop = loop,
				.config = config,
				.bp = &server.pb,
				.hp = &server.hb,
				.tp = tp,
				.conn_list = .{},
				.conn_pool = conn_pool,
				.allocator = allocator,
				.max_conn = config.workers.max_conn orelse 8192,
			};
		}

		pub fn deinit(self: *Self) void {
			closeAll(H, self.conn_list, &self.conn_pool, self.config.shutdown);
			self.conn_pool.deinit();
			self.loop.deinit();
			self.bp.deinit();
		}

		pub fn listen(self: *Self, listener: posix.socket_t, signal: posix.fd_t, context: anytype) void {
			_ = context;
			self.loop.monitorAccept(listener) catch |err| {
				log.err("failed to add monitor to listening socket: {}", .{err});
				return;
			};

			self.loop.monitorSignal(signal) catch |err| {
				log.err("failed to add monitor to signal pipe: {}", .{err});
				return;
			};

			while (true) {
				var it = self.loop.wait() catch |err| {
					log.err("failed to wait on events: {}", .{err});
					std.time.sleep(std.time.ns_per_s);
					continue;
				};

				while (it.next()) |data| {
					if (data == 0) {
						self.accept(listener) catch |err| {
							log.err("accept error: {}", .{err});
							std.time.sleep(std.time.ns_per_ms);
						};
						continue;
					}

					if (data == 1) {
						log.info("received shutdown signal", .{});
						// for now, activity on the signal can only mean shutdown
						return;
					}

					const hc: *HandlerConn(H) = @ptrFromInt(data);
					self.tp.spawn(self, hc);
				}
			}
		}

		fn accept(self: *Self, listener: posix.fd_t) !void {
			const max_conn = self.max_conn;

			var count = self.conn_list.len;
			while (count < max_conn) {
				var address: net.Address = undefined;
				var address_len: posix.socklen_t = @sizeOf(net.Address);

				const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
					// When available, we use SO_REUSEPORT_LB or SO_REUSEPORT, so WouldBlock
					// should not be possible in those cases, but if it isn't available
					// this error should be ignored as it means another thread picked it up.
					return if (err == error.WouldBlock) {} else err;
				};
				errdefer posix.close(socket);

				log.debug("({}) connected", .{address});

				// set non blocking
				const flags = (try posix.fcntl(socket, posix.F.GETFL, 0)) | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
				_ = try posix.fcntl(socket, posix.F.SETFL, flags);

				const hc = try self.conn_pool.create();
				errdefer self.conn_pool.destroy(hc);

				hc.* = .{
					.socket = socket,
					.reader = undefined,
					.handler = undefined, // DANGEROUS
					.conn = .{
						._closed = false,
						._rw_mode = .none,
						._io_mode = .nonblocking,
						.address = address,
						.stream = .{.handle = socket},
						._socket_flags = flags,
					},
				};
				try self.loop.monitorRead(hc, false);
				self.conn_list.insert(hc);
				count += 1;
			}
		}


		// Called in a thread-pool thread/
		// !! Access to self has to be synchronized !!
		// Will not be called concurrently for the same hc.
		// But, as always, the app can have a reference to hc.conn, so hc.conn
		// has to be synchornized (which its methods are).
		fn dataAvailable(self: *Self, hc: *HandlerConn, thread_buf: []u8) void {
			if (hc.handshake) |*state| {
				self.doHandshake(hc, state) catch {}; // TODO log
			} else {
				self.processIncoming(hc, thread_buf) catch {}; // TODO log
			}
		}

		fn doHandshake(self: *Self, hc: *HandlerConn, state: *Handshake.State) !void {
			_ = self;
			_ = hc;
			_ = state;
		}


		fn doDataAvailable(self: *Self, hc: *HandlerConn, thread_buf: []u8) !void {
			_ = self;
			_ = hc;
			_ = thread_buf;
		}

		fn closeConn(self: *Self, hc: *HandlerConn) void {
			posix.close(hc.conn.stream.handle);
			self.conn_list.remove(hc.node);
			self.coon_pool.destroy(hc);
		}
	};
}

fn KQueue(comptime H: type) type {
	return struct {
		q: i32,
		change_count: usize,
		change_buffer: [16]Kevent,
		event_list: [64]Kevent,

		const Kevent = posix.Kevent;

		fn init() !KQueue {
			return .{
				.q = try posix.kqueue(),
				.change_count = 0,
				.change_buffer = undefined,
				.event_list = undefined,
			};
		}

		fn deinit(self: KQueue) void {
			posix.close(self.q);
		}

		fn monitorAccept(self: *KQueue, fd: c_int) !void {
			try self.change(fd, 0, posix.system.EVFILT_READ, posix.system.EV_ADD);
		}

		fn monitorSignal(self: *KQueue, fd: c_int) !void {
			try self.change(fd, 1, posix.system.EVFILT_READ, posix.system.EV_ADD);
		}

		fn monitorRead(self: *KQueue, hc: *HandlerConn(H), comptime rearm: bool) !void {
			_ = rearm; // used by epoll
			try self.change(hc.socket, @intFromPtr(hc), posix.system.EVFILT_READ, posix.system.EV_ADD | posix.system.EV_ENABLE | posix.system.EV_DISPATCH);
		}

		fn remove(self: *KQueue, hc: *HandlerConn(H)) !void {
			try self.change(hc.socket, 0, posix.system.EVFILT_READ, posix.system.EV_DELETE);
		}

		fn change(self: *KQueue, fd: posix.fd_t, data: usize, filter: i16, flags: u16) !void {
			var change_count = self.change_count;
			var change_buffer = &self.change_buffer;

			if (change_count == change_buffer.len) {
				// calling this with an empty event_list will return immediate
				_ = try posix.kevent(self.q, change_buffer, &[_]Kevent{}, null);
				change_count = 0;
			}
			change_buffer[change_count] = .{
				.ident = @intCast(fd),
				.filter = filter,
				.flags = flags,
				.fflags = 0,
				.data = 0,
				.udata = data,
			};
			self.change_count = change_count + 1;
		}

		fn wait(self: *KQueue) !Iterator {
			const event_list = &self.event_list;
			const event_count = try posix.kevent(self.q, self.change_buffer[0..self.change_count], event_list, null);
			self.change_count = 0;

			return .{
				.index = 0,
				.events = event_list[0..event_count],
			};
		}

		const Iterator = struct {
			index: usize,
			events: []Kevent,

			fn next(self: *Iterator) ?usize {
				const index = self.index;
				const events = self.events;
				if (index == events.len) {
					return null;
				}
				self.index = index + 1;
				return self.events[index].udata;
			}
		};
	};
}

fn EPoll(comptime H: type) type {
	return struct {
		q: i32,
		event_list: [64]EpollEvent,

		const linux = std.os.linux;
		const EpollEvent = linux.epoll_event;

		fn init() !EPoll {
			return .{
				.event_list = undefined,
				.q = try posix.epoll_create1(0),
			};
		}

		fn deinit(self: EPoll) void {
			posix.close(self.q);
		}

		fn monitorAccept(self: *EPoll, fd: c_int) !void {
			var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 0 } };
			return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
		}

		fn monitorSignal(self: *EPoll, fd: c_int) !void {
			var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 1 } };
			return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
		}

		fn monitorRead(self: *EPoll, hc: *HandlerConn(H), comptime rearm: bool) !void {
			const op = if (rearm) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
			var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT, .data = .{ .ptr = @intFromPtr(hc) } };
			return posix.epoll_ctl(self.q, op, hc.socket, &event);
		}

		fn remove(self: *EPoll, hc: *HandlerConn(H)) !void {
			return posix.epoll_ctl(self.q, linux.EPOLL.CTL_DEL, hc.socket, null);
		}

		fn wait(self: *EPoll) !Iterator {
			const event_list = &self.event_list;
			const event_count = blk: while (true) {
				const rc = linux.syscall6(
					.epoll_pwait2,
					@as(usize, @bitCast(@as(isize, self.q))),
					@intFromPtr(event_list.ptr),
					event_list.len,
					0,
					0,
					@sizeOf(linux.sigset_t),
				);

				// taken from std.os.epoll_waits
				switch (posix.errno(rc)) {
					.SUCCESS => break :blk @as(usize, @intCast(rc)),
					.INTR => continue,
					.BADF => unreachable,
					.FAULT => unreachable,
					.INVAL => unreachable,
					else => unreachable,
				}
			};

			return .{
				.index = 0,
				.events = event_list[0..event_count],
			};
		}

		const Iterator = struct {
			index: usize,
			events: []EpollEvent,

			fn next(self: *Iterator) ?usize {
				const index = self.index;
				const events = self.events;
				if (index == events.len) {
					return null;
				}
				self.index = index + 1;
				return self.events[index].data.ptr;
			}
		};
	};
}

// We want to extract as much common logic as possible from the Blocking and
// NonBlockign workers. The code from this point on is meant to be used with
// both workers, independently from the blocking/nonblocking nonsense.

fn HandlerConn(comptime H: type) type {
	return struct {
		conn: Conn,
		handler: H,
		reader: Reader,
		socket: posix.socket_t, // denormalization from conn.stream.handle
		handshake: ?Handshake.State,
		next: ?*HandlerConn(H) = null,
		prev: ?*HandlerConn(H) = null,
	};
}

pub const Conn = struct {
	_closed: bool,
	_io_mode: IOMode,
	_rw_mode: RWMode,
	_socket_flags: usize,
	stream: net.Stream,
	address: net.Address,

	const IOMode = enum {
		blocking,
		nonblocking,
	};

	const RWMode = enum {
		none,
		read,
		write,
	};

	pub fn blocking(self: *Conn) !void {
		// in blockingMode, io_mode is ALWAYS blocking, so we can skip this
		if (comptime blockingMode() == false) {
			if (@atomicRmw(IOMode, &self._io_mode, .Xchg, .blocking, .monotonic) == .nonblock) {
				// we don't care if the above check + this call isn't atomic.
				// at worse, we're doing an unecessary syscall
				_ = try posix.fcntl(self.stream.handle, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
			}
		}
	}

	pub fn isClosed(self: *Conn) bool {
		return @atomicLoad(bool, &self._closed, .monotonic);
	}

	pub fn close(self: *Conn) void {
		if (self.isClosed() == false) {
			posix.close(self.stream.handle);
			@atomicStore(bool, &self._closed, true, .monotonic);
		}
	}

	pub fn writeBin(self: *Conn, data: []const u8) !void {
		return self.writeFrame(.binary, data);
	}

	pub fn writeText(self: *Conn, data: []const u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn write(self: *Conn, data: []const u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn writePing(self: *Conn, data: []u8) !void {
		return self.writeFrame(.ping, data);
	}

	pub fn writePong(self: *Conn, data: []u8) !void {
		return self.writeFrame(.pong, data);
	}

	pub fn writeClose(self: *Conn) void {
		self.writeFramed(CLOSE_NORMAL) catch {};
	}

	pub fn writeCloseWithCode(self: *Conn, code: u16) void {
		var buf: [2]u8 = undefined;
		std.mem.writeInt(u16, &buf, code, .Big);
		self.writeFrame(.close, &buf) catch {};
	}

	pub fn writeFrame(self: *Conn, op_code: OpCode, data: []const u8) !void {
		const l = data.len;
		const stream = self.stream;

		// maximum possible prefix length. op_code + length_type + 8byte length
		var buf: [10]u8 = undefined;
		buf[0] = @intFromEnum(op_code);

		if (l <= 125) {
			buf[1] = @intCast(l);
			try stream.writeAll(buf[0..2]);
		} else if (l < 65536) {
			buf[1] = 126;
			buf[2] = @intCast((l >> 8) & 0xFF);
			buf[3] = @intCast(l & 0xFF);
			try stream.writeAll(buf[0..4]);
		} else {
			buf[1] = 127;
			buf[2] = @intCast((l >> 56) & 0xFF);
			buf[3] = @intCast((l >> 48) & 0xFF);
			buf[4] = @intCast((l >> 40) & 0xFF);
			buf[5] = @intCast((l >> 32) & 0xFF);
			buf[6] = @intCast((l >> 24) & 0xFF);
			buf[7] = @intCast((l >> 16) & 0xFF);
			buf[8] = @intCast((l >> 8) & 0xFF);
			buf[9] = @intCast(l & 0xFF);
			try stream.writeAll(buf[0..]);
		}
		if (l > 0) {
			try stream.writeAll(data);
		}
	}

	// TODO: SO MUCH
	// (WouldBlock handling, thread safety...)
	pub fn writeFramed(self: Conn, data: []const u8) !void {
		try self.stream.writeAll(data);
	}
};

fn handleMessage(comptime H: type, hc: *HandlerConn(H), message: Message) !void {
	const message_type = message.type;
	defer hc.reader.done(message_type);

	log.debug("({}) received {s} message", .{hc.conn.address, @tagName(message_type)});

	const handler = &hc.handler;

	switch (message_type) {
		.text, .binary => {
			switch (comptime @typeInfo(@TypeOf(H.handleMessage)).Fn.params.len) {
				2 => try handler.handleMessage(message.data),
				3 => try handler.handleMessage(message.data, if (message_type == .text) .text else .binary),
				else => @compileError(@typeName(H) ++ ".handleMessage must accept 2 or 3 parameters"),
			}
		},
		.pong => if (comptime std.meta.hasFn(H, "handlePong")) {
			try handler.handlePong();
		},
		.ping => {
			const data = message.data;
			if (comptime std.meta.hasFn(H, "handlePing")) {
				try handler.handlePing(data);
			} else if (data.len == 0) {
				try hc.conn.writeFramed(EMPTY_PONG);
			} else {
				try hc.conn.writeFrame(.pong, data);
			}
		},
		.close => {
			const conn = &hc.conn;
			defer conn.close();
			const data = message.data;
			if (comptime std.meta.hasFn(H, "handleClose")) {
				return handler.handleClose(data);
			}

			const l = data.len;
			if (l == 0) {
				return conn.writeClose();
			}

			if (l == 1) {
				// close with a payload always has to have at least a 2-byte payload,
				// since a 2-byte code is required
				return conn.writeFramed(CLOSE_PROTOCOL_ERROR);
			}

			const code = @as(u16, @intCast(data[1])) | (@as(u16, @intCast(data[0])) << 8);
			if (code < 1000 or code == 1004 or code == 1005 or code == 1006 or (code > 1013 and code < 3000)) {
				return conn.writeFramed(CLOSE_PROTOCOL_ERROR);
			}

			if (l == 2) {
				return try conn.writeFramed(CLOSE_NORMAL);
			}

			const payload = data[2..];
			if (!std.unicode.utf8ValidateSlice(payload)) {
				// if we have a payload, it must be UTF8 (why?!)
				return try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
			}
			return conn.writeClose();
		},
	}
}

fn closeAll(comptime H: type, conn_list: List(HandlerConn(H)), conn_pool: *std.heap.MemoryPool(HandlerConn(H)), shutdown: Config.Shutdown) void {
	var next_node = conn_list.head;
	while (next_node) |hc| {
		if (shutdown.notify_handler) {
			hc.handler.close();
		}

		const conn = &hc.conn;
		if (shutdown.notify_client) {
			conn.writeClose();
		}

		if (shutdown.close_socket) {
			posix.close(hc.socket);
		}

		defer conn_pool.destroy(hc);
		next_node = hc.next;
	}
}

fn respondToHandshakeError(conn: *Conn, err: anyerror) void {
	const response = switch (err) {
		error.Close => return,
		error.RequestTooLarge => buildError(400, "too large"),
		error.Timeout, error.WouldBlock => buildError(400, "timeout"),
		error.InvalidProtocol => buildError(400, "invalid protocol"),
		error.InvalidRequestLine => buildError(400, "invalid requestline"),
		error.InvalidHeader => buildError(400, "invalid header"),
		error.InvalidUpgrade => buildError(400, "invalid upgrade"),
		error.InvalidVersion => buildError(400, "invalid version"),
		error.InvalidConnection => buildError(400, "invalid connection"),
		error.MissingHeaders => buildError(400, "missingheaders"),
		error.Empty => buildError(400, "invalid request"),
		else => buildError(400, "unknown"),
	};
	preHandOffWrite(conn, response);
}

fn buildError(comptime status: u16, comptime err: []const u8) []const u8 {
	return std.fmt.comptimePrint("HTTP/1.1 {d} \r\nConnection: Close\r\nError: {s}\r\nContent-Length: 0\r\n\r\n", .{ status, err });
}

// Doesn't neeed to worry about Conn's threadsafety since this can only be
// called from the initial thread that accepted the connection, well before
// the conn is handed off to the app.
fn preHandOffWrite(conn: *Conn, response: []const u8) void {
	const socket = conn.stream.handle;
	const timeout = std.mem.toBytes(posix.timeval{ .tv_sec = 5, .tv_usec = 0 });
	posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout) catch return;

	var pos: usize = 0;
	while (pos < response.len) {
		const n = posix.write(socket, response[pos..]) catch |err| switch (err) {
			error.WouldBlock => {
				if (conn._io_mode == .blocking) {
					// We were in blocking mode, which means we reached our timeout
					// We're done trying to send the response.
					return;
				}
				try conn.blocking();
				continue;
			},
			else => return,
		};

		if (n == 0) {
			// closed
			return;
		}
		pos += n;
	}
}

fn timestamp() u32 {
	if (comptime @hasDecl(std.c, "CLOCK") == false) {
		return @intCast(std.time.timestamp());
	}
	var ts: posix.timespec = undefined;
	posix.clock_gettime(posix.CLOCK.REALTIME, &ts) catch unreachable;
	return @intCast(ts.tv_sec);
}

// intrusive doubly-linked list with count, not thread safe
// Blocking worker has to guard this with a mutex
// NonBlocking worker doesn't have to guard this
fn List(comptime T: type) type {
	return struct {
		len: usize = 0,
		head: ?*T = null,
		tail: ?*T = null,

		const Self = @This();

		pub fn insert(self: *Self, node: *T) void {
			if (self.tail) |tail| {
				tail.next = node;
				node.prev = tail;
				self.tail = node;
			} else {
				self.head = node;
				self.tail = node;
			}
			self.len += 1;
			node.next = null;
		}

		pub fn remove(self: *Self, node: *T) void {
			if (node.prev) |prev| {
				prev.next = node.next;
			} else {
				self.head = node.next;
			}

			if (node.next) |next| {
				next.prev = node.prev;
			} else {
				self.tail = node.prev;
			}
			node.prev = null;
			node.next = null;
			self.len -= 1;
		}
	};
}

const t = @import("../t.zig");
test "List: insert & remove" {
	var list = List(TestNode){};
	try expectList(&.{}, list);

	var n1 = TestNode{ .id = 1 };
	list.insert(&n1);
	try expectList(&.{1}, list);

	list.remove(&n1);
	try expectList(&.{}, list);

	var n2 = TestNode{ .id = 2 };
	list.insert(&n2);
	list.insert(&n1);
	try expectList(&.{ 2, 1 }, list);

	var n3 = TestNode{ .id = 3 };
	list.insert(&n3);
	try expectList(&.{ 2, 1, 3 }, list);

	list.remove(&n1);
	try expectList(&.{ 2, 3 }, list);

	list.insert(&n1);
	try expectList(&.{ 2, 3, 1 }, list);

	list.remove(&n2);
	try expectList(&.{ 3, 1 }, list);

	list.remove(&n1);
	try expectList(&.{3}, list);

	list.remove(&n3);
	try expectList(&.{}, list);
}

const TestNode = struct {
	id: i32,
	next: ?*TestNode = null,
	prev: ?*TestNode = null,
};

fn expectList(expected: []const i32, list: List(TestNode)) !void {
	if (expected.len == 0) {
		try t.expectEqual(null, list.head);
		try t.expectEqual(null, list.tail);
		return;
	}

	var i: usize = 0;
	var next = list.head;
	while (next) |node| {
		try t.expectEqual(expected[i], node.id);
		i += 1;
		next = node.next;
	}
	try t.expectEqual(expected.len, i);

	i = expected.len;
	var prev = list.tail;
	while (prev) |node| {
		i -= 1;
		try t.expectEqual(expected[i], node.id);
		prev = node.prev;
	}
	try t.expectEqual(0, i);
}
