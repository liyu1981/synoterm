//! Thin, version-stable OS layer.
//!
//! Everything in this file is deliberately written against `std.os.linux`
//! (raw syscalls) plus a handful of libc `extern` declarations, and avoids
//! `std.Io` / `std.posix` helper APIs whose shape changes between Zig
//! releases. Porting synoterm to a newer Zig should only require touching
//! this file.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const util = @import("util.zig");

const is_linux = builtin.os.tag == .linux;

pub const fd_t = linux.fd_t;
pub const pid_t = linux.pid_t;
pub const uid_t = linux.uid_t;
pub const gid_t = linux.gid_t;

pub const Error = error{
    SyscallFailed,
    OutOfMemory,
    Unexpected,
};

pub fn errnoOf(rc: usize) linux.E {
    return linux.errno(rc);
}

fn okOrErr(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        else => error.SyscallFailed,
    };
}

// ---------------------------------------------------------------------------
// libc externs
// ---------------------------------------------------------------------------

extern "c" fn initgroups(user: [*:0]const u8, group: c_uint) c_int;
extern "c" fn getpid() c_int;
extern "c" fn fork() c_int;
extern "c" fn _exit(status: c_int) noreturn;
extern "c" fn signal(sig: c_int, handler: ?*const anyopaque) ?*const anyopaque;

pub fn geteuid() uid_t {
    return linux.geteuid();
}

pub fn getuid() uid_t {
    return linux.getuid();
}

pub fn currentPid() pid_t {
    if (is_linux) return @intCast(linux.getpid());
    return @intCast(getpid());
}

pub fn libcFork() Error!pid_t {
    const rc = fork();
    if (rc < 0) return error.SyscallFailed;
    return @intCast(rc);
}

pub fn exitNow(status: u8) noreturn {
    _exit(@intCast(status));
}

pub fn ignoreSigpipe() void {
    // SIGPIPE = 13. Ignoring it turns "peer went away" into EPIPE errors,
    // which the socket layer already handles via `manageWriteError`.
    _ = signal(13, @ptrFromInt(@as(usize, 1))); // SIG_IGN
}

// ---------------------------------------------------------------------------
// Files / fd helpers
// ---------------------------------------------------------------------------

pub fn openRead(path: [:0]const u8) Error!fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    return @intCast(try okOrErr(rc));
}

pub fn openRdwrNoCtty(path: [:0]const u8) Error!fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0);
    return @intCast(try okOrErr(rc));
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

/// True when `path` resolves to a directory. Uses statx so that no libc
/// compatibility wrapper is required.
pub fn isDirZ(path: [*:0]const u8) bool {
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return false;
    if (!st.mask.TYPE) return false;
    return linux.S.ISDIR(st.mode);
}

pub fn existsZ(path: [*:0]const u8) bool {
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &st);
    return linux.errno(rc) == .SUCCESS;
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    const err = linux.errno(rc);
    if (err == .INTR) return read(fd, buf);
    if (err != .SUCCESS) return error.SyscallFailed;
    return rc;
}

pub fn writeAll(fd: fd_t, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err == .AGAIN) {
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
            _ = linux.poll(&pfd, 1, 1000);
            continue;
        }
        if (err != .SUCCESS) return error.SyscallFailed;
        if (rc == 0) return error.SyscallFailed;
        off += rc;
    }
}

pub fn dup2(old: fd_t, new: fd_t) Error!void {
    _ = try okOrErr(linux.dup2(old, new));
}

pub fn chdir(path: [:0]const u8) Error!void {
    _ = try okOrErr(linux.chdir(path.ptr));
}

pub fn setNonBlocking(fd: fd_t) void {
    const flags_rc = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags_rc) != .SUCCESS) return;
    const flags: u32 = @intCast(flags_rc);
    _ = linux.fcntl(fd, linux.F.SETFL, @as(usize, flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
}

// ---------------------------------------------------------------------------
// Process control
// ---------------------------------------------------------------------------

pub fn setsid() Error!void {
    _ = try okOrErr(linux.setsid());
}

pub fn setpgid(pid: pid_t, pgid: pid_t) void {
    _ = linux.setpgid(pid, pgid);
}

pub fn setgid(gid: gid_t) Error!void {
    _ = try okOrErr(linux.setgid(gid));
}

pub fn setuid(uid: uid_t) Error!void {
    _ = try okOrErr(linux.setuid(uid));
}

pub fn setgroups(groups: []const gid_t) Error!void {
    _ = try okOrErr(linux.setgroups(groups.len, groups.ptr));
}

pub fn initGroups(name: [:0]const u8, gid: gid_t) Error!void {
    if (initgroups(name.ptr, gid) != 0) return error.SyscallFailed;
}

pub fn kill(pid: pid_t, sig: linux.SIG) void {
    _ = linux.kill(pid, sig);
}

pub const WaitResult = struct {
    pid: pid_t,
    status: u32,
};

pub fn waitPid(pid: pid_t) Error!WaitResult {
    var status: i32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, 0);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return error.SyscallFailed;
        return .{ .pid = @intCast(rc), .status = @bitCast(status) };
    }
}

pub fn execveZ(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) Error {
    const rc = linux.execve(path, argv, envp);
    // execve only returns on failure.
    _ = rc;
    return error.SyscallFailed;
}

// ---------------------------------------------------------------------------
// Sockets (blocking, IPv4 loopback by default)
// ---------------------------------------------------------------------------

pub const SOCK = struct {
    pub const STREAM: u32 = 1;
    pub const CLOEXEC: u32 = 0o2000000;
};

pub const AF_INET: u32 = 2;
pub const SOL_SOCKET: u32 = 1;
pub const SO_REUSEADDR: u32 = 2;
pub const SO_RCVTIMEO: u32 = 20;
pub const SO_SNDTIMEO: u32 = 21;
pub const IPPROTO_TCP: u32 = 6;
pub const TCP_NODELAY: u32 = 1;
pub const SHUT_WR: u32 = 1;

pub const SockaddrIn = extern struct {
    family: u16 = AF_INET,
    port_be: u16,
    addr_be: u32,
    zero: [8]u8 = @splat(0),
};

pub fn sockaddrLoopback(port: u16) SockaddrIn {
    return .{
        .port_be = std.mem.nativeToBig(u16, port),
        // 127.0.0.1
        .addr_be = std.mem.nativeToBig(u32, 0x7f000001),
    };
}

pub fn listenLoopback(port: u16, backlog: u32) Error!fd_t {
    const sfd_rc = linux.socket(AF_INET, SOCK.STREAM | SOCK.CLOEXEC, 0);
    if (linux.errno(sfd_rc) != .SUCCESS) return error.SyscallFailed;
    const sfd: fd_t = @intCast(sfd_rc);
    errdefer close(sfd);

    const one: u32 = 1;
    _ = linux.setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), @sizeOf(u32));

    var addr = sockaddrLoopback(port);
    _ = try okOrErr(linux.bind(sfd, @ptrCast(&addr), @sizeOf(SockaddrIn)));
    _ = try okOrErr(linux.listen(sfd, backlog));
    return sfd;
}

pub fn accept(sfd: fd_t) Error!fd_t {
    while (true) {
        const rc = linux.accept4(sfd, null, null, SOCK.CLOEXEC);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return error.SyscallFailed;
        return @intCast(rc);
    }
}

pub fn setNoDelay(fd: fd_t) void {
    const one: u32 = 1;
    _ = linux.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, @ptrCast(&one), @sizeOf(u32));
}

pub fn setRecvTimeout(fd: fd_t, seconds: u32) void {
    const tv = linux.timeval{ .sec = @intCast(seconds), .usec = 0 };
    _ = linux.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
}

pub fn setSendTimeout(fd: fd_t, seconds: u32) void {
    const tv = linux.timeval{ .sec = @intCast(seconds), .usec = 0 };
    _ = linux.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
}

pub fn shutdownWrite(fd: fd_t) void {
    _ = linux.shutdown(fd, SHUT_WR);
}

/// Formats the IPv4 peer address into `buf` (e.g. "192.168.1.20").
pub fn peerIp(fd: fd_t, buf: *[16]u8) ?[]const u8 {
    var addr: SockaddrIn = undefined;
    var len: linux.socklen_t = @sizeOf(SockaddrIn);
    const rc = linux.getpeername(fd, @ptrCast(&addr), &len);
    if (linux.errno(rc) != .SUCCESS) return null;
    const host = std.mem.bigToNative(u32, addr.addr_be);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        (host >> 24) & 0xff,
        (host >> 16) & 0xff,
        (host >> 8) & 0xff,
        host & 0xff,
    }) catch null;
}

// ---------------------------------------------------------------------------
// PTY
// ---------------------------------------------------------------------------

pub const TIOCSPTLCK: u32 = 0x4004_5431;
pub const TIOCGPTN: u32 = 0x8004_5430;
pub const TIOCSCTTY: u32 = 0x540E;
pub const TIOCSWINSZ: u32 = 0x5414;
pub const TIOCGWINSZ: u32 = 0x5413;

pub const Winsize = extern struct {
    rows: u16 = 24,
    cols: u16 = 80,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

pub const Pty = struct {
    master: fd_t,
    slave: fd_t,
};

/// Opens a new PTY pair via /dev/ptmx (no libutil dependency).
pub fn openPty() Error!Pty {
    const master = try openRdwrNoCtty("/dev/ptmx");

    var unlock: u32 = 0;
    _ = try okOrErr(linux.ioctl(master, TIOCSPTLCK, @intFromPtr(&unlock)));

    var pty_num: u32 = 0;
    _ = try okOrErr(linux.ioctl(master, TIOCGPTN, @intFromPtr(&pty_num)));

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/dev/pts/{d}", .{pty_num}) catch return error.Unexpected;
    path_buf[path.len] = 0;
    const slave = openRdwrNoCtty(path_buf[0..path.len :0]) catch |err| {
        close(master);
        return err;
    };
    return .{ .master = master, .slave = slave };
}

pub fn setWinsize(fd: fd_t, rows: u16, cols: u16) Error!void {
    var ws = Winsize{ .rows = rows, .cols = cols };
    _ = try okOrErr(linux.ioctl(fd, TIOCSWINSZ, @intFromPtr(&ws)));
}

pub fn setControllingTty(fd: fd_t) Error!void {
    _ = try okOrErr(linux.ioctl(fd, TIOCSCTTY, 0));
}

// ---------------------------------------------------------------------------
// Users (local /etc/passwd; AD/LDAP via DSM's own tools is a Phase 2 task)
// ---------------------------------------------------------------------------

pub const User = struct {
    name: []const u8,
    uid: uid_t,
    gid: gid_t,
};

/// Minimal /etc/passwd lookup. Deliberately does not use NSS so that a
/// statically linked binary behaves identically on every DSM version.
pub fn lookupPasswd(allocator: std.mem.Allocator, path: [:0]const u8, name: []const u8) !?User {
    const fd = try openRead(path);
    defer close(fd);

    var buf = util.List(u8).init(allocator);
    defer buf.deinit();
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try read(fd, &tmp);
        if (n == 0) break;
        try buf.appendSlice(tmp[0..n]);
    }

    var lines = std.mem.splitScalar(u8, buf.items(), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var it = std.mem.splitScalar(u8, trimmed, ':');
        const entry_name = it.next() orelse continue;
        if (!std.mem.eql(u8, entry_name, name)) continue;
        _ = it.next() orelse continue; // password
        const uid_str = it.next() orelse continue;
        const gid_str = it.next() orelse continue;
        const uid = std.fmt.parseUnsigned(uid_t, uid_str, 10) catch continue;
        const gid = std.fmt.parseUnsigned(gid_t, gid_str, 10) catch continue;
        return .{ .name = try allocator.dupe(u8, entry_name), .uid = uid, .gid = gid };
    }
    return null;
}

pub fn homeDir(allocator: std.mem.Allocator, path: [:0]const u8, name: []const u8) !?[]const u8 {
    const fd = try openRead(path);
    defer close(fd);

    var buf = util.List(u8).init(allocator);
    defer buf.deinit();
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try read(fd, &tmp);
        if (n == 0) break;
        try buf.appendSlice(tmp[0..n]);
    }

    var lines = std.mem.splitScalar(u8, buf.items(), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;
        var it = std.mem.splitScalar(u8, trimmed, ':');
        const entry_name = it.next() orelse continue;
        if (!std.mem.eql(u8, entry_name, name)) continue;
        for (0..4) |_| _ = it.next();
        const home = it.next() orelse continue;
        return try allocator.dupe(u8, home);
    }
    return null;
}
