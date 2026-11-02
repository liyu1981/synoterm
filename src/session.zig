//! PTY sessions: spawn a shell (optionally as another user), pump bytes
//! between the pty master and the browser, and keep the terminal size in
//! sync.
//!
//! Everything the child process does after `fork()` is async-signal-safe:
//! all allocation and NSS lookups happen in the parent beforehand.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const util = @import("util.zig");
const ws = @import("ws.zig");

extern "c" fn getgrouplist(user: [*:0]const u8, group: c_uint, groups: [*]sys.gid_t, ngroups: *c_int) c_int;

pub const max_groups: usize = 64;

pub const Options = struct {
    /// Absolute path to the shell, e.g. "/bin/bash".
    shell: [:0]const u8,
    /// Login name; `null` keeps the current (already authenticated) user.
    user: ?[:0]const u8 = null,
    uid: sys.uid_t = 0,
    gid: sys.gid_t = 0,
    home: [:0]const u8 = "/",
    term: [:0]const u8 = "xterm-256color",
    cols: u16 = 80,
    rows: u16 = 24,
};

pub const SpawnError = error{
    ForkFailed,
    SyscallFailed,
    OutOfMemory,
    Unexpected,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    master: sys.fd_t,
    pid: sys.pid_t,
    /// Strings referenced by the child's argv/envp; kept alive so the child
    /// (and the shell it execs) can read them at any time.
    owned: [][]u8,

    pub fn resize(self: *Session, cols: u16, rows: u16) void {
        const c = if (cols == 0) 80 else cols;
        const r = if (rows == 0) 24 else rows;
        sys.setWinsize(self.master, r, c) catch {};
    }

    pub fn writeInput(self: *Session, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try sys.writeAll(self.master, bytes);
    }

    /// Returns 0 on EOF (child closed the pty).
    pub fn readOutput(self: *Session, buf: []u8) !usize {
        while (true) {
            const rc = linux.read(self.master, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                // EIO is how Linux signals "the slave side is gone".
                .IO => return 0,
                else => return error.SyscallFailed,
            }
        }
    }

    pub fn wait(self: *Session) u8 {
        const res = sys.waitPid(self.pid) catch return 255;
        const status = res.status;
        const signal_bits: u32 = 0x7f;
        if ((status & signal_bits) == 0) return @intCast((status >> 8) & 0xff);
        return @intCast(128 + (status & signal_bits));
    }

    /// Sends SIGHUP to the process group so the whole shell tree exits, then
    /// reaps the child and closes the pty.
    pub fn terminate(self: *Session) void {
        sys.kill(-self.pid, .HUP);
        sys.kill(self.pid, .TERM); // in case the shell escapes the group
        _ = sys.waitPid(self.pid) catch {};
        sys.close(self.master);
    }

    pub fn deinit(self: *Session) void {
        for (self.owned) |s| self.allocator.free(s);
        self.allocator.free(self.owned);
    }
};

/// Spawns a login shell on a fresh pty. When `opts.user` is set the caller
/// must already be root (this is the `tool`-privileged binary path).
pub fn spawn(allocator: std.mem.Allocator, opts: Options) SpawnError!Session {
    var owned = util.List([]u8).init(allocator);
    errdefer {
        for (owned.items()) |s| allocator.free(s);
        owned.deinit();
    }

    // ---- group list (parent side: NSS safe) ----
    var groups: [max_groups]sys.gid_t = undefined;
    var group_count: usize = 0;
    if (opts.user) |user| {
        var ngroups: c_int = max_groups;
        if (getgrouplist(user.ptr, opts.gid, &groups, &ngroups) >= 0) {
            group_count = @min(@as(usize, @intCast(ngroups)), max_groups);
        } else {
            // Truncated result: fall back to the primary group only.
            groups[0] = opts.gid;
            group_count = 1;
        }
    }

    // ---- argv / envp ----
    const argv0 = try util.allocPrintZ(allocator, "-{s}", .{std.fs.path.basename(opts.shell)});
    try owned.append(argv0);

    var envp = util.List(?[*:0]const u8).init(allocator);
    defer envp.deinit();

    const env_pairs = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "PATH", .v = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" },
        .{ .k = "TERM", .v = opts.term },
        .{ .k = "HOME", .v = opts.home },
        .{ .k = "SHELL", .v = opts.shell },
        .{ .k = "LANG", .v = "en_US.UTF-8" },
        .{ .k = "SYNOTERM", .v = "1" },
    };
    for (env_pairs) |pair| {
        const kv = try util.allocPrintZ(allocator, "{s}={s}", .{ pair.k, pair.v });
        try owned.append(kv);
        try envp.append(kv.ptr);
    }
    if (opts.user) |user| {
        const user_kv = try util.allocPrintZ(allocator, "USER={s}", .{user});
        try owned.append(user_kv);
        try envp.append(user_kv.ptr);
        const logname_kv = try util.allocPrintZ(allocator, "LOGNAME={s}", .{user});
        try owned.append(logname_kv);
        try envp.append(logname_kv.ptr);
    }
    try envp.append(null);

    // ---- pty ----
    const pty = try sys.openPty();
    errdefer sys.close(pty.master);
    sys.setWinsize(pty.master, opts.rows, opts.cols) catch {};

    const argv = [_:null]?[*:0]const u8{argv0.ptr};

    const child = sys.libcFork() catch return error.ForkFailed;

    if (child == 0) {
        // ---- child: async-signal-safe syscalls only ----
        sys.setsid() catch sys.exitNow(126);
        sys.setControllingTty(pty.slave) catch {};
        sys.dup2(pty.slave, 0) catch sys.exitNow(126);
        sys.dup2(pty.slave, 1) catch sys.exitNow(126);
        sys.dup2(pty.slave, 2) catch sys.exitNow(126);
        if (pty.slave > 2) sys.close(pty.slave);
        sys.close(pty.master);

        if (opts.user != null) {
            sys.setgroups(groups[0..group_count]) catch sys.exitNow(126);
            sys.setgid(opts.gid) catch sys.exitNow(126);
            sys.setuid(opts.uid) catch sys.exitNow(126);
        }
        sys.chdir(opts.home) catch {};
        sys.execveZ(opts.shell.ptr, &argv, @ptrCast(envp.items().ptr)) catch {};
        sys.exitNow(127);
    }

    sys.close(pty.slave);

    return .{
        .allocator = allocator,
        .master = pty.master,
        .pid = child,
        .owned = try owned.toOwnedSlice(),
    };
}

/// Pumps pty output to the websocket until the session ends.
pub fn pumpToWebSocket(session: *Session, sock: sys.fd_t) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = session.readOutput(&buf) catch return;
        if (n == 0) return;
        ws.writeBinary(sock, buf[0..n]) catch return;
    }
}
