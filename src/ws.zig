//! Minimal RFC 6455 server-side implementation: handshake + frame codec.
//! Only what a terminal bridge needs: text/binary messages, ping/pong, close.

const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xa,
};

fn opcodeFromInt(v: u4) ?Opcode {
    return switch (v) {
        0x0 => .continuation,
        0x1 => .text,
        0x2 => .binary,
        0x8 => .close,
        0x9 => .ping,
        0xa => .pong,
        else => null,
    };
}

pub const max_payload: usize = 1 << 20; // 1 MiB per message

pub const Frame = struct {
    opcode: Opcode,
    payload: []u8,
};

pub const Error = error{
    ProtocolViolation,
    PayloadTooLarge,
    Closed,
    SyscallFailed,
    OutOfMemory,
    Unexpected,
};

fn readExact(fd: sys.fd_t, buf: []u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = sys.read(fd, buf[off..]) catch |err| switch (err) {
            error.SyscallFailed => return error.Closed,
            else => return err,
        };
        if (n == 0) return error.Closed;
        off += n;
    }
}

/// Reads one complete message (fragments are reassembled). Control frames
/// interleaved with fragments are returned immediately when they arrive
/// before any fragment, which is enough for a terminal session.
pub fn readMessage(allocator: std.mem.Allocator, fd: sys.fd_t) Error!Frame {
    var assembled = util.List(u8).init(allocator);
    errdefer assembled.deinit();

    var msg_opcode: ?Opcode = null;

    while (true) {
        var hdr: [2]u8 = undefined;
        try readExact(fd, &hdr);

        const fin = (hdr[0] & 0x80) != 0;
        const rsv = hdr[0] & 0x70;
        if (rsv != 0) return error.ProtocolViolation;
        const opcode = opcodeFromInt(@intCast(hdr[0] & 0x0f)) orelse return error.ProtocolViolation;
        const masked = (hdr[1] & 0x80) != 0;
        if (!masked) return error.ProtocolViolation; // clients MUST mask

        var len: u64 = hdr[1] & 0x7f;
        if (len == 126) {
            var ext: [2]u8 = undefined;
            try readExact(fd, &ext);
            len = std.mem.readInt(u16, &ext, .big);
        } else if (len == 127) {
            var ext: [8]u8 = undefined;
            try readExact(fd, &ext);
            len = std.mem.readInt(u64, &ext, .big);
        }
        if (len > max_payload) return error.PayloadTooLarge;

        var mask_key: [4]u8 = undefined;
        try readExact(fd, &mask_key);

        const payload = try allocator.alloc(u8, @intCast(len));
        errdefer allocator.free(payload);
        if (len > 0) try readExact(fd, payload);
        for (payload, 0..) |*byte, i| byte.* ^= mask_key[i % 4];

        switch (opcode) {
            .ping, .pong, .close => {
                // Control frames must not be fragmented.
                if (!fin) return error.ProtocolViolation;
                return .{ .opcode = opcode, .payload = payload };
            },
            .continuation => {
                if (msg_opcode == null) return error.ProtocolViolation;
                try assembled.appendSlice(payload);
                allocator.free(payload);
                if (fin) return .{ .opcode = msg_opcode.?, .payload = try assembled.toOwnedSlice() };
            },
            .text, .binary => {
                if (msg_opcode != null) return error.ProtocolViolation; // no interleaved data frames
                msg_opcode = opcode;
                if (fin) return .{ .opcode = opcode, .payload = payload };
                try assembled.appendSlice(payload);
                allocator.free(payload);
            },
        }
    }
}

pub fn writeFrame(fd: sys.fd_t, opcode: Opcode, payload: []const u8) Error!void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @backingInt(opcode));
    var hdr_len: usize = 2;
    if (payload.len < 126) {
        hdr[1] = @intCast(payload.len);
    } else if (payload.len <= 0xffff) {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
        hdr_len = 4;
    } else {
        hdr[1] = 127;
        std.mem.writeInt(u64, hdr[2..10], payload.len, .big);
        hdr_len = 10;
    }
    sys.writeAll(fd, hdr[0..hdr_len]) catch return error.SyscallFailed;
    if (payload.len > 0) sys.writeAll(fd, payload) catch return error.SyscallFailed;
}

pub fn writeText(fd: sys.fd_t, text: []const u8) Error!void {
    return writeFrame(fd, .text, text);
}

pub fn writeBinary(fd: sys.fd_t, bytes: []const u8) Error!void {
    return writeFrame(fd, .binary, bytes);
}

/// Computes `Sec-WebSocket-Accept` for the client's key.
pub fn acceptKey(buf: *[28]u8, key: []const u8) []const u8 {
    const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);

    var encoder = std.base64.standard.Encoder;
    return encoder.encode(buf, &digest);
}
