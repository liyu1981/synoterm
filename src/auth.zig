//! DSM session authentication.
//!
//! DSM exposes `/usr/syno/synoman/webman/modules/authenticate.cgi`, a CGI that
//! reads the request environment (cookie + CSRF token) and prints the
//! authenticated DSM account name. We replay the browser's request headers
//! into that CGI, so a valid DSM desktop session is enough to open a terminal
//! — no password is ever seen by synoterm.
//!
//! Group membership is then checked with DSM's own `id`, which keeps
//! domain/LDAP accounts working (a statically linked binary cannot use NSS).

const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");

pub const authenticate_cgi = "/usr/syno/synoman/webman/modules/authenticate.cgi";
/// What `SCRIPT_NAME` looks like to webman; only informational for the CGI.
const auth_cgi_script = "/webman/modules/authenticate.cgi";
pub const id_bin = "/usr/bin/id";

pub const Identity = struct {
    name: []const u8,
    /// Numeric uid/gid resolved from /etc/passwd; may be absent for
    /// domain/LDAP accounts (Phase 2: resolve through `id -u`).
    uid: ?sys.uid_t = null,
    gid: ?sys.gid_t = null,
    home: ?[]const u8 = null,
};

pub const AuthError = error{
    Unauthenticated,
    NotPermitted,
    LookupFailed,
    OutOfMemory,
    Unexpected,
};

pub const Capture = struct {
    output: []u8,
    /// 0..255, 128+n for signals. 127 means "could not execute".
    status: u8,
};

/// Runs a program and captures stdout. `extra_env` entries are "KEY=VALUE".
pub fn runCapture(
    allocator: std.mem.Allocator,
    path: [:0]const u8,
    envp_in: []const [*:0]const u8,
    extra_env: []const [:0]const u8,
) !Capture {
    var envp = util.List(?[*:0]const u8).init(allocator);
    defer envp.deinit();
    for (envp_in) |e| try envp.append(e);
    for (extra_env) |e| try envp.append(e.ptr);
    try envp.append(null);

    var argv = [_:null]?[*:0]const u8{path.ptr};

    var fds: [2]sys.fd_t = undefined;
    const pipe_rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
    if (std.os.linux.errno(pipe_rc) != .SUCCESS) return error.Unexpected;
    const read_fd = fds[0];
    const write_fd = fds[1];
    errdefer sys.close(read_fd);

    const child = sys.libcFork() catch {
        sys.close(write_fd);
        return error.Unexpected;
    };
    if (child == 0) {
        sys.close(read_fd);
        sys.dup2(write_fd, 1) catch sys.exitNow(126);
        if (write_fd > 2) sys.close(write_fd);
        sys.execveZ(path.ptr, &argv, @ptrCast(envp.items().ptr)) catch {};
        sys.exitNow(127);
    }
    sys.close(write_fd);

    var out = util.List(u8).init(allocator);
    errdefer out.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.read(read_fd, &buf) catch break;
        if (n == 0) break;
        if (out.items().len + n > 16 * 1024) break;
        try out.appendSlice(buf[0..n]);
    }
    sys.close(read_fd);
    const result = sys.waitPid(child) catch return error.Unexpected;
    const status: u8 = blk: {
        if (result.status & 0x7f == 0) break :blk @intCast((result.status >> 8) & 0xff);
        break :blk @intCast(128 + (result.status & 0x7f));
    };

    return .{ .output = try out.toOwnedSlice(), .status = status };
}

/// Builds the CGI environment for `authenticate.cgi` from the browser request.
/// It mirrors what webman hands a package CGI (scheme, server name/port,
/// request URI), because that CGI validates a DSM session and can be stricter
/// than the cookie itself.
pub fn cgiEnv(
    allocator: std.mem.Allocator,
    cookie: []const u8,
    syno_token: []const u8,
    host: []const u8,
    proto: []const u8,
    path: []const u8,
    peer_ip: []const u8,
    base_env: []const [*:0]const u8,
) ![]const [:0]const u8 {
    var list = util.List([:0]const u8).init(allocator);
    errdefer list.deinit();

    // "nas:5001" -> SERVER_NAME "nas", SERVER_PORT "5001".
    const colon = std.mem.lastIndexOfScalar(u8, host, ':');
    const server_name = if (colon) |i| host[0..i] else host;
    const server_port = if (colon) |i| host[i + 1 ..] else if (std.mem.eql(u8, proto, "https")) "443" else "80";
    const https = std.mem.eql(u8, proto, "https");

    try list.append(try util.allocPrintZ(allocator, "REQUEST_METHOD=GET", .{}));
    try list.append(try util.allocPrintZ(allocator, "REQUEST_URI={s}", .{path}));
    try list.append(try util.allocPrintZ(allocator, "SCRIPT_NAME={s}", .{auth_cgi_script}));
    try list.append(try util.allocPrintZ(allocator, "QUERY_STRING=", .{}));
    try list.append(try util.allocPrintZ(allocator, "GATEWAY_INTERFACE=CGI/1.1", .{}));
    try list.append(try util.allocPrintZ(allocator, "SERVER_SOFTWARE=nginx", .{}));
    try list.append(try util.allocPrintZ(allocator, "SERVER_PROTOCOL=HTTP/1.1", .{}));
    try list.append(try util.allocPrintZ(allocator, "SERVER_NAME={s}", .{server_name}));
    try list.append(try util.allocPrintZ(allocator, "SERVER_PORT={s}", .{server_port}));
    try list.append(try util.allocPrintZ(allocator, "HTTPS={s}", .{if (https) "on" else "off"}));
    try list.append(try util.allocPrintZ(allocator, "PATH=/usr/syno/bin:/usr/bin:/bin", .{}));
    try list.append(try util.allocPrintZ(allocator, "HTTP_COOKIE={s}", .{cookie}));
    try list.append(try util.allocPrintZ(allocator, "HTTP_HOST={s}", .{host}));
    try list.append(try util.allocPrintZ(allocator, "REMOTE_ADDR={s}", .{peer_ip}));
    try list.append(try util.allocPrintZ(allocator, "HTTP_X_SYNO_TOKEN={s}", .{syno_token}));
    try list.append(try util.allocPrintZ(allocator, "HTTP_USER_AGENT=synoterm", .{}));
    for (base_env) |e| try list.append(std.mem.sliceTo(e, 0));
    return list.toOwnedSlice();
}

pub fn freeEnv(allocator: std.mem.Allocator, env: []const [:0]const u8) void {
    for (env) |e| allocator.free(e);
    allocator.free(env);
}
