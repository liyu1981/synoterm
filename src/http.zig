//! Minimal HTTP/1.1: request-head parsing, static file serving, and the
//! handoff to the WebSocket layer. No keep-alive, no chunked bodies: the
//! only HTTP traffic synoterm sees is `GET` for a handful of static assets
//! and the WebSocket upgrade.

const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");

pub const max_head_bytes: usize = 16 * 1024;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    /// Path portion of `target` (query string stripped).
    path: []const u8,
    query: []const u8,
    headers: []Header,

    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    pub fn hasToken(self: Request, name: []const u8, token: []const u8) bool {
        const value = self.header(name) orelse return false;
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |part| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " \t"), token)) return true;
        }
        return false;
    }
};

pub const Response = struct {
    status: u16 = 200,
    content_type: []const u8 = "text/plain; charset=utf-8",
    body: []const u8 = "",
    extra_headers: []const u8 = "",
    head_only: bool = false,
};

pub fn statusText(status: u16) []const u8 {
    return switch (status) {
        101 => "Switching Protocols",
        200 => "OK",
        204 => "No Content",
        301 => "Moved Permanently",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        426 => "Upgrade Required",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        else => "OK",
    };
}

pub fn send(allocator: std.mem.Allocator, fd: sys.fd_t, res: Response) !void {
    const head = if (res.extra_headers.len > 0)
        try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\nServer: synoterm\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n{s}Connection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n", .{
            res.status, statusText(res.status), res.content_type, res.body.len, res.extra_headers,
        })
    else
        try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\nServer: synoterm\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n", .{
            res.status, statusText(res.status), res.content_type, res.body.len,
        });
    defer allocator.free(head);
    try sys.writeAll(fd, head);
    if (!res.head_only and res.body.len > 0) try sys.writeAll(fd, res.body);
}

pub fn sendError(allocator: std.mem.Allocator, fd: sys.fd_t, status: u16, message: []const u8) void {
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{s}\n", .{message}) catch message;
    send(allocator, fd, .{ .status = status, .body = body }) catch {};
}

pub const ParseError = error{
    BadRequest,
    HeadTooLarge,
    Closed,
    OutOfMemory,
    SyscallFailed,
    Unexpected,
};

/// Reads and parses the request head. `buf` must outlive the returned Request.
pub fn readHead(buf: []u8, fd: sys.fd_t) ParseError![]u8 {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = sys.read(fd, buf[filled..]) catch return error.Closed;
        if (n == 0) return error.Closed;
        filled += n;
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |idx| {
            // Keep exactly the head; anything after it belongs to the
            // upgraded protocol (WebSocket frames) or is ignored.
            return buf[0 .. idx + 4];
        }
    }
    return error.HeadTooLarge;
}

pub fn parse(allocator: std.mem.Allocator, head: []const u8) !Request {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version = parts.next() orelse return error.BadRequest;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadRequest;

    var headers = util.List(Header).init(allocator);
    errdefer headers.deinit();

    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        try headers.append(.{ .name = name, .value = value });
    }

    const qmark = std.mem.indexOfScalar(u8, target, '?');
    const path = if (qmark) |i| target[0..i] else target;
    const query = if (qmark) |i| target[i + 1 ..] else "";

    return .{
        .method = method,
        .target = target,
        .path = path,
        .query = query,
        .headers = try headers.toOwnedSlice(),
    };
}

pub fn contentTypeFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json") or std.mem.eql(u8, ext, ".map")) return "application/json; charset=utf-8";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".ttf")) return "font/ttf";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}

/// Resolves a URL path below `root`, rejecting traversal. The returned path
/// is owned by the caller.
pub fn resolvePath(allocator: std.mem.Allocator, root: []const u8, url_path: []const u8) !?[]u8 {
    var out = util.List(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice(std.mem.trimEnd(u8, root, "/"));
    if (url_path.len == 0 or std.mem.eql(u8, url_path, "/")) {
        try out.appendSlice("/index.html");
        return try out.toOwnedSlice();
    }
    if (url_path[0] != '/') return null;

    var it = std.mem.splitScalar(u8, url_path[1..], '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return null;
        if (std.mem.indexOfScalar(u8, segment, 0) != null) return null;
        try out.append('/');
        try out.appendSlice(segment);
    }
    // A directory URL maps to its index.html.
    const result = try out.toOwnedSlice();
    const resultz = try allocator.dupeSentinel(u8, result, 0);
    defer allocator.free(resultz);
    if (sys.isDirZ(resultz)) {
        defer allocator.free(result);
        const indexed = try std.fmt.allocPrint(allocator, "{s}/index.html", .{std.mem.trimEnd(u8, result, "/")});
        return indexed;
    }
    return result;
}

pub fn readFileAll(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const pathz = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(pathz);
    const fd = sys.openRead(pathz) catch return error.FileNotFound;
    defer sys.close(fd);

    var out = util.List(u8).init(allocator);
    errdefer out.deinit();
    var tmp: [16 * 1024]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &tmp) catch return error.ReadFailed;
        if (n == 0) break;
        if (out.items().len + n > max_bytes) return error.FileTooLarge;
        try out.appendSlice(tmp[0..n]);
    }
    return out.toOwnedSlice();
}
