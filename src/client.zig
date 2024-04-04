const std = @import("std");
const lib = @import("lib.zig");
const pipe = @import("pipe.zig");

const buffer = lib.buffer;
const framing = lib.framing;
const Reader = lib.Reader;
const Message = lib.Message;
const OpCode = framing.OpCode;

const os = std.posix;
const net = std.net;
const tls = std.crypto.tls;
const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;

pub const Config = struct {
    max_size: usize = 65536,
    buffer_size: usize = 4096,
    mask_fn: *const fn () [4]u8 = generateMask,
    tls: bool = false,
    ca_bundle: ?Bundle = null,
    handle_ping: bool = false,
    handle_pong: bool = false,
    handle_close: bool = false,
    buffer_provider: ?*buffer.Provider = null,
};

pub const HandshakeOpts = struct {
    timeout_ms: u32 = 10000,
    headers: ?[]const u8 = null,
};

pub fn connect(allocator: Allocator, host: []const u8, port: u16, config: Config) !Client {
    var tls_client: ?tls.Client = null;
    const net_stream = try net.tcpConnectToHost(allocator, host, port);

    if (config.tls) {
        var own_bundle = false;
        var bundle = config.ca_bundle orelse blk: {
            own_bundle = true;
            var b = Bundle{};
            try b.rescan(allocator);
            break :blk b;
        };
        tls_client = try tls.Client.init(net_stream, bundle, host);

        if (own_bundle) {
            bundle.deinit(allocator);
        }
    }
    const stream = Stream.init(net_stream, tls_client);
    return Client.init(allocator, stream, config);
}

pub const Client = struct {
    stream: Stream,
    _reader: Reader,
    _closed: bool,
    _handle_ping: bool,
    _handle_pong: bool,
    _handle_close: bool,
    _bp: ?*buffer.Provider,
    _mask_fn: *const fn () [4]u8,

    const Self = @This();

    pub fn init(allocator: Allocator, stream: Stream, config: Config) !Self {
        var bp: *buffer.Provider = undefined;
        var owned_bp: ?*buffer.Provider = null;

        // If a buffer_provider is provided, we'll use that.
        // If it isn't, we need to create one which also means we now "own" it
        // and we're responsible for cleaning it up
        if (config.buffer_provider) |shared_bp| {
            bp = shared_bp;
        } else {
            bp = try allocator.create(buffer.Provider);
            bp.* = buffer.Provider.initNoPool(allocator);
            owned_bp = bp;
        }

        errdefer {
            if (owned_bp) |obp| {
                allocator.destroy(obp);
            }
        }

        return .{
            .stream = stream,
            ._bp = owned_bp,
            ._closed = false,
            ._mask_fn = config.mask_fn,
            ._handle_ping = config.handle_ping,
            ._handle_pong = config.handle_pong,
            ._handle_close = config.handle_close,
            ._reader = try Reader.init(config.buffer_size, config.max_size, bp),
        };
    }

    pub fn deinit(self: *Self) void {
        self._reader.deinit();
        if (self._bp) |bp| {
            bp.allocator.destroy(bp);
        }
        self.close();
    }

    pub fn handshake(self: *Self, path: []const u8, opts: HandshakeOpts) !void {
        const stream = &self.stream;
        errdefer self.closeWithCode(1002);

        // we've already setup our reader, and the reader has a static buffer
        // we might as well use it!
        const buf = self._reader.static.data;

        const key = blk: {
            const bin_key = generateKey();
            var encoded_key: [24]u8 = undefined;
            break :blk std.base64.standard.Encoder.encode(&encoded_key, &bin_key);
        };

        try sendHandshake(path, key, buf, &opts, stream);

        const over_read = try readHandshakeReply(buf, key, &opts, stream);
        // We might have read more than handshake response. If so, readHandshakeReply
        // has positioned the extra data at the start of the buffer, but we need
        // to set the length.
        self._reader.len = over_read;
    }

    pub fn readLoop(self: *Self, h: anytype) !void {
        var reader = &self._reader;
        const stream = &self.stream;
        defer h.close();

        const handle_ping = self._handle_ping;
        const handle_pong = self._handle_pong;
        const handle_close = self._handle_close;

        while (true) {
            const message = reader.readMessage(stream) catch |err| switch (err) {
                error.Closed, error.ConnectionResetByPeer, error.BrokenPipe => {
                    _ = @cmpxchgStrong(bool, &self._closed, false, true, .monotonic, .monotonic);
                    return;
                },
                else => {
                    self.closeWithCode(1002);
                    return;
                },
            };

            switch (message.type) {
                .text, .binary => {
                    try h.handle(message);
                    reader.handled();
                },
                .ping => {
                    if (handle_ping) {
                        try h.handle(message);
                    } else {
                        // @constCast is safe because we know message.data points to
                        // reader.buffer.buf, which we own and which can be mutated
                        try self.writeFrame(.pong, @constCast(message.data));
                    }
                },
                .close => {
                    if (handle_close) {
                        try h.handle(message);
                    } else {
                        self.close();
                    }
                    return;
                },
                .pong => {
                    if (handle_pong) {
                        try h.handle(message);
                    }
                },
            }
        }
    }

    pub fn readLoopInNewThread(self: *Self, h: anytype) !std.Thread {
        return std.Thread.spawn(.{}, readLoopOwnedThread, .{ self, h });
    }

    fn readLoopOwnedThread(self: *Self, h: anytype) void {
        pipe.maybeIgnoreSigpipe();
        self.readLoop(h) catch {};
    }

    pub fn write(self: *Self, data: []u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn writeText(self: *Self, data: []u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn writeBin(self: *Self, data: []u8) !void {
        return self.writeFrame(.binary, data);
    }

    pub fn writePing(self: *Self, data: []u8) !void {
        return self.writeFrame(.ping, data);
    }

    pub fn writePong(self: *Self, data: []u8) !void {
        return self.writeFrame(.pong, data);
    }

    pub fn writeFrame(self: *Self, op_code: OpCode, data: []u8) !void {
        const l = data.len;
        const mask = self._mask_fn();
        var stream = &self.stream;

        // maximum possible prefix length. op_code + length_type + 8byte length + 4 byte mask
        var buf: [14]u8 = undefined;
        buf[0] = @intFromEnum(op_code);

        if (l <= 125) {
            buf[1] = @as(u8, @intCast(l)) | 128;
            @memcpy(buf[2..6], &mask);
            try stream.writeAll(buf[0..6]);
        } else if (l < 65536) {
            buf[1] = 254; // 126 | 128
            buf[2] = @intCast((l >> 8) & 0xFF);
            buf[3] = @intCast(l & 0xFF);
            @memcpy(buf[4..8], &mask);
            try stream.writeAll(buf[0..8]);
        } else {
            buf[1] = 255; // 127 | 128
            buf[2] = @intCast((l >> 56) & 0xFF);
            buf[3] = @intCast((l >> 48) & 0xFF);
            buf[4] = @intCast((l >> 40) & 0xFF);
            buf[5] = @intCast((l >> 32) & 0xFF);
            buf[6] = @intCast((l >> 24) & 0xFF);
            buf[7] = @intCast((l >> 16) & 0xFF);
            buf[8] = @intCast((l >> 8) & 0xFF);
            buf[9] = @intCast(l & 0xFF);
            @memcpy(buf[10..], &mask);
            try stream.writeAll(buf[0..]);
        }
        if (l > 0) {
            framing.mask(&mask, data);
            try stream.writeAll(data);
        }
    }

    pub fn close(self: *Self) void {
        if (@cmpxchgStrong(bool, &self._closed, false, true, .monotonic, .monotonic) == null) {
            self.writeFrame(.close, "") catch {};
            self.stream.close();
        }
    }

    pub fn closeWithCode(self: *Self, code: u16) void {
        if (@cmpxchgStrong(bool, &self._closed, false, true, .monotonic, .monotonic) == null) {
            var buf: [2]u8 = undefined;
            buf[0] = @intCast((code >> 8) & 0xFF);
            buf[1] = @intCast(code & 0xFF);
            self.writeFrame(.close, &buf) catch {};
            self.stream.close();
        }
    }
};

// wraps a net.Stream and optional a tls.Client
pub const Stream = struct {
    stream: net.Stream,
    tls_client: ?tls.Client = null,

    pub fn init(stream: net.Stream, tls_client: ?tls.Client) Stream {
        return .{
            .stream = stream,
            .tls_client = tls_client,
        };
    }

    pub fn close(self: *Stream) void {
        if (self.tls_client) |*tls_client| {
            _ = tls_client.writeEnd(self.stream, "", true) catch {};
        }
        self.stream.close();
    }

    pub fn read(self: *Stream, buf: []u8) !usize {
        if (self.tls_client) |*tls_client| {
            return tls_client.read(self.stream, buf);
        }
        return self.stream.read(buf);
    }

    pub fn writeAll(self: *Stream, data: []const u8) !void {
        if (self.tls_client) |*tls_client| {
            return tls_client.writeAll(self.stream, data);
        }
        return self.stream.writeAll(data);
    }

    const zero_timeout = std.mem.toBytes(os.timeval{ .tv_sec = 0, .tv_usec = 0 });
    pub fn writeTimeout(self: *const Stream, ms: u32) !void {
        if (ms == 0) {
            return self.setsockopt(os.SO.SNDTIMEO, &zero_timeout);
        }

        const timeout = std.mem.toBytes(os.timeval{
            .tv_sec = @intCast(@divTrunc(ms, 1000)),
            .tv_usec = @intCast(@mod(ms, 1000) * 1000),
        });
        return self.setsockopt(os.SO.SNDTIMEO, &timeout);
    }

    pub fn receiveTimeout(self: *const Stream, ms: u32) !void {
        if (ms == 0) {
            return self.setsockopt(os.SO.RCVTIMEO, &zero_timeout);
        }

        const timeout = std.mem.toBytes(os.timeval{
            .tv_sec = @intCast(@divTrunc(ms, 1000)),
            .tv_usec = @intCast(@mod(ms, 1000) * 1000),
        });
        return self.setsockopt(os.SO.RCVTIMEO, &timeout);
    }

    pub fn setsockopt(self: *const Stream, optname: u32, value: []const u8) !void {
        return os.setsockopt(self.stream.handle, os.SOL.SOCKET, optname, value);
    }
};

fn generateKey() [16]u8 {
    if (comptime lib.is_test) {
        return [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    }
    var key: [16]u8 = undefined;
    std.crypto.random.bytes(&key);
    return key;
}

fn generateMask() [4]u8 {
    var m: [4]u8 = undefined;
    std.crypto.random.bytes(&m);
    return m;
}

fn sendHandshake(path: []const u8, key: []const u8, buf: []u8, opts: *const HandshakeOpts, stream: anytype) !void {
    @memcpy(buf[0..4], "GET ");
    var pos: usize = 4;
    var end = pos + path.len;

    {
        @memcpy(buf[pos..end], path);
        pos = end;
    }

    {
        const headers = " HTTP/1.1\r\ncontent-length: 0\r\nupgrade: websocket\r\nsec-websocket-version: 13\r\nconnection: upgrade\r\nsec-websocket-key: ";
        end = pos + headers.len;
        @memcpy(buf[pos..end], headers);

        pos = end;
        end = pos + key.len;
        @memcpy(buf[pos..end], key);

        pos = end;
        end = pos + 2;
        @memcpy(buf[pos..end], "\r\n");
        pos = end;
    }

    if (opts.headers) |extra_headers| {
        end = pos + extra_headers.len;
        @memcpy(buf[pos..end], extra_headers);
        pos = end;
        if (!std.mem.endsWith(u8, extra_headers, "\r\n")) {
            buf[pos] = '\r';
            buf[pos + 1] = '\n';
            pos += 2;
        }
    }
    buf[pos] = '\r';
    buf[pos + 1] = '\n';

    try stream.writeTimeout(opts.timeout_ms);
    try stream.writeAll(buf[0 .. pos + 2]);
    try stream.writeTimeout(0);
}

fn readHandshakeReply(buf: []u8, key: []const u8, opts: *const HandshakeOpts, stream: anytype) !usize {
    const mem = std.mem;
    const ascii = std.ascii;

    const timeout_ms = opts.timeout_ms;
    const deadline = std.time.milliTimestamp() + timeout_ms;
    try stream.receiveTimeout(timeout_ms);

    var pos: usize = 0;
    var line_start: usize = 0;
    var complete_response: u8 = 0;
    while (true) {
        const n = try stream.read(buf[pos..]);
        if (n == 0) {
            return error.ConnectionClosed;
        }

        pos += n;
        while (std.mem.indexOfScalar(u8, buf[line_start..pos], '\r')) |relative_end| {
            if (relative_end == 0) {
                if (complete_response != 15) {
                    return error.InvalidHandshakeResponse;
                }
                const over_read = pos - (line_start + 2);
                std.mem.copyForwards(u8, buf[0..over_read], buf[line_start + 2 .. pos]);
                try stream.receiveTimeout(0);
                return over_read;
            }

            const line_end = line_start + relative_end;
            const line = buf[line_start..line_end];

            // the next line starts where this line ends, skip over the \r\n
            line_start = line_end + 2;

            if (complete_response == 0) {
                if (!ascii.startsWithIgnoreCase(line, "HTTP/1.1 101 ")) {
                    return error.InvalidHandshakeResponse;
                }
                complete_response |= 1;
                continue;
            }

            for (line, 0..) |b, i| {
                // find the colon and lowercase the header while we're iterating
                if ('A' <= b and b <= 'Z') {
                    line[i] = b + 32;
                    continue;
                }
                if (b != ':') {
                    continue;
                }

                const name = line[0..i];
                const value = line[i + 1 ..];
                if (mem.eql(u8, name, "upgrade")) {
                    if (!ascii.eqlIgnoreCase(mem.trim(u8, value, &ascii.whitespace), "websocket")) {
                        return error.InvalidUpgradeHeader;
                    }
                    complete_response |= 2;
                } else if (mem.eql(u8, name, "connection")) {
                    if (!ascii.eqlIgnoreCase(mem.trim(u8, value, &ascii.whitespace), "upgrade")) {
                        return error.InvalidConnectionHeader;
                    }
                    complete_response |= 4;
                } else if (mem.eql(u8, name, "sec-websocket-accept")) {
                    var h: [20]u8 = undefined;
                    {
                        var hasher = std.crypto.hash.Sha1.init(.{});
                        hasher.update(key);
                        hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
                        hasher.final(&h);
                    }

                    var encoded_buf: [28]u8 = undefined;
                    const sec_hash = std.base64.standard.Encoder.encode(&encoded_buf, &h);
                    const header_value = mem.trim(u8, value, &ascii.whitespace);

                    if (!mem.eql(u8, header_value, sec_hash)) {
                        return error.InvalidWebsocketAcceptHeader;
                    }
                    complete_response |= 8;
                }
            }
        }

        if (std.time.milliTimestamp() > deadline) {
            return error.Timeout;
        }

        if (pos == buf.len) {
            return error.ResponseTooLarge;
        }
    }
}

const t = lib.testing;
test "client: handshake" {
    {
        // empty reponse
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("\r\n\r\n");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // invalid websocket response
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 200 OK\r\n\r\n");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // missing upgrade header
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\n\r\n");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // wrong upgrade header
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nUpgrade: nope\r\n\r\n");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try t.expectError(error.InvalidUpgradeHeader, client.handshake("/", .{}));
    }

    {
        // missing connection header
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nUpgrade: websocket\r\n\r\n");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // wrong connection header
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: something\r\n\r\n");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try t.expectError(error.InvalidConnectionHeader, client.handshake("/", .{}));
    }

    {
        // missing Sec-Websocket-Accept header
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nUpgrade: websocket\r\nConnection: upgrade\r\n\r\n");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // wrong Sec-Websocket-Accept header
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: UPGRADE\r\nSec-Websocket-Accept: hack\r\n\r\n");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try t.expectError(error.InvalidWebsocketAcceptHeader, client.handshake("/", .{}));
    }

    {
        // ok for successful
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: UPGRADE\r\nSec-Websocket-Accept: C/0nmHhBztSRGR1CwL6Tf4ZjwpY=\r\n\r\n");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try client.handshake("/", .{});
        try t.expectEqual(0, client._reader.len);
    }

    {
        // ok for successful, with overread
        var pair = t.SocketPair.init();
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: UPGRADE\r\nSec-Websocket-Accept: C/0nmHhBztSRGR1CwL6Tf4ZjwpY=\r\n\r\nSome Random Data Which is Part Of the Next Message");

        var client = try Client.init(t.allocator, .{ .stream = pair.server }, .{});
        defer client.deinit();
        try client.handshake("/", .{});
        try t.expectEqual(50, client._reader.len);
    }
}
