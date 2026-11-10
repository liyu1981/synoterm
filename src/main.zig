//! synoterm: a WebSocket <-> PTY bridge that runs as a Synology DSM package
//! and renders an xterm.js terminal inside the DSM desktop.
//!
//! Process model: one thread per connection, blocking syscalls, no async
//! runtime. A NAS terminal app has a handful of concurrent users, so this
//! keeps the code small and debuggable.

const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const http = @import("http.zig");
const ws = @import("ws.zig");
const pty_session = @import("session.zig");
const auth = @import("auth.zig");

const max_static_bytes: usize = 32 * 1024 * 1024;

/// Bumped whenever the HTTP/WS surface changes, so an old binary that is still
/// running can be recognised (the UI reports it when /status is missing).
const server_version = "0.1.3";
const api_version: u32 = 4;

pub const AuthMode = enum { dev, dsm };

pub const Config = struct {
    bind_port: u16 = 8080,
    /// IPv4 address to bind. 127.0.0.1 by default; 0.0.0.0 for LAN testing.
    bind_addr: [4]u8 = .{ 127, 0, 0, 1 },
    /// Dev mode only: when set, the upgrade must present this secret either as
    /// `?t=<token>` or as the `synoterm.dev-token.<base64url>` subprotocol.
    dev_token: ?[]const u8 = null,
    web_root: []const u8 = "frontend/dist",
    auth_mode: AuthMode = .dev,
    /// Group required in DSM mode. DSM administrators are members of
    /// "administrators"; set to "" to allow any authenticated account.
    require_group: []const u8 = "administrators",
    default_shell: [:0]const u8 = "/bin/sh",
    term: [:0]const u8 = "xterm-256color",
    max_sessions: u32 = 8,
    insecure_origin: bool = false,
    /// Prefix every endpoint lives under (e.g. "/synoterm", used both behind
    /// DSM's nginx mount and on the package's own port); empty in dev.
    base_path: []const u8 = "",
};

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    active_sessions: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Serializes socket writes between the pty pump and control messages.
const Link = struct {
    fd: sys.fd_t,
    mutex: util.Mutex = .{},

    fn sendBinary(self: *Link, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        ws.writeBinary(self.fd, bytes) catch {};
    }

    fn sendText(self: *Link, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        ws.writeText(self.fd, text) catch {};
    }
};

fn envOr(name: [:0]const u8, fallback: []const u8) []const u8 {
    const value = std.c.getenv(name.ptr) orelse return fallback;
    return std.mem.span(value);
}

pub fn main(init: std.process.Init.Minimal) !void {
    sys.ignoreSigpipe();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const argv = init.args.toSlice(allocator) catch return error.InvalidArguments;

    var cfg = Config{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--listen")) {
            cfg.bind_port = try nextPort(argv, &i);
        } else if (std.mem.eql(u8, arg, "--bind")) {
            cfg.bind_addr = parseIpv4(try nextArg(argv, &i)) orelse {
                std.debug.print("synoterm: --bind needs an IPv4 address (e.g. 0.0.0.0)\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--dev-token")) {
            cfg.dev_token = try nextArg(argv, &i);
        } else if (std.mem.eql(u8, arg, "--web-root")) {
            cfg.web_root = try nextArg(argv, &i);
        } else if (std.mem.eql(u8, arg, "--auth")) {
            const value = try nextArg(argv, &i);
            if (std.mem.eql(u8, value, "dev")) {
                cfg.auth_mode = .dev;
            } else if (std.mem.eql(u8, value, "dsm")) {
                cfg.auth_mode = .dsm;
            } else return usage();
        } else if (std.mem.eql(u8, arg, "--require-group")) {
            cfg.require_group = try nextArg(argv, &i);
        } else if (std.mem.eql(u8, arg, "--shell")) {
            cfg.default_shell = try allocator.dupeSentinel(u8, try nextArg(argv, &i), 0);
        } else if (std.mem.eql(u8, arg, "--term")) {
            cfg.term = try allocator.dupeSentinel(u8, try nextArg(argv, &i), 0);
        } else if (std.mem.eql(u8, arg, "--max-sessions")) {
            cfg.max_sessions = std.fmt.parseUnsigned(u32, try nextArg(argv, &i), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--base-path")) {
            cfg.base_path = try nextArg(argv, &i);
        } else if (std.mem.eql(u8, arg, "--insecure-origin")) {
            cfg.insecure_origin = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        } else {
            std.debug.print("synoterm: unknown argument: {s}\n", .{arg});
            return usage();
        }
    }

    // Environment overrides keep the DSM start-stop script tiny.
    const env_port = envOr("SYNOTERM_PORT", "");
    if (env_port.len > 0) cfg.bind_port = std.fmt.parseUnsigned(u16, env_port, 10) catch cfg.bind_port;
    const env_root = envOr("SYNOTERM_WEB_ROOT", "");
    if (env_root.len > 0) cfg.web_root = env_root;
    const env_base = envOr("SYNOTERM_BASE_PATH", "");
    if (env_base.len > 0) cfg.base_path = env_base;
    const env_auth = envOr("SYNOTERM_AUTH", "");
    if (std.mem.eql(u8, env_auth, "dsm")) cfg.auth_mode = .dsm;
    if (std.mem.eql(u8, env_auth, "dev")) cfg.auth_mode = .dev;

    var ctx = Ctx{ .allocator = allocator, .cfg = cfg };

    const listen_fd = sys.listenIp(cfg.bind_addr, cfg.bind_port, 128) catch |err| {
        std.debug.print("synoterm: cannot listen on {d}.{d}.{d}.{d}:{d}: {s} ({s})\n", .{
            cfg.bind_addr[0], cfg.bind_addr[1], cfg.bind_addr[2], cfg.bind_addr[3],
            cfg.bind_port, @errorName(err),
            if (err == error.AddressInUse) "another process is already listening on that port" else "see the error name",
        });
        return err;
    };
    defer sys.close(listen_fd);

    std.debug.print("synoterm {s} (api {d}, pid {d}) listening on http://{d}.{d}.{d}.{d}:{d}{s}/ ({s})\n", .{
        server_version,
        api_version,
        sys.currentPid(),
        cfg.bind_addr[0],
        cfg.bind_addr[1],
        cfg.bind_addr[2],
        cfg.bind_addr[3],
        cfg.bind_port,
        std.mem.trimEnd(u8, cfg.base_path, "/"),
        @tagName(cfg.auth_mode),
    });
    const loopback_only = cfg.bind_addr[0] == 127 and cfg.bind_addr[1] == 0 and
        cfg.bind_addr[2] == 0 and cfg.bind_addr[3] == 1;
    if (!loopback_only) {
        std.debug.print("synoterm: WARNING bound to {d}.{d}.{d}.{d} — reachable from the network\n", .{
            cfg.bind_addr[0], cfg.bind_addr[1], cfg.bind_addr[2], cfg.bind_addr[3],
        });
    }
    if (cfg.auth_mode == .dev and cfg.dev_token == null and !loopback_only) {
        std.debug.print("synoterm: WARNING dev mode without --dev-token on a non-loopback address\n", .{});
    }

    while (true) {
        const conn = sys.accept(listen_fd) catch continue;
        const thread = std.Thread.spawn(.{}, handleConnection, .{ &ctx, conn }) catch {
            sys.close(conn);
            continue;
        };
        thread.detach();
    }
}

fn nextArg(argv: []const [:0]const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* >= argv.len) return error.InvalidArguments;
    return argv[i.*];
}

fn nextPort(argv: []const [:0]const u8, i: *usize) !u16 {
    return std.fmt.parseUnsigned(u16, try nextArg(argv, i), 10) catch error.InvalidArguments;
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\synoterm - DSM web terminal backend
        \\
        \\  --listen <port>         port to listen on (default 8080)
        \\  --bind <ipv4>           address to bind (default 127.0.0.1, 0.0.0.0 = LAN)
        \\  --dev-token <secret>    dev mode only: require ?t=<secret> or the matching subprotocol
        \\  --web-root <dir>        static files served (dev mode)
        \\  --auth dev|dsm          "dev" trusts the caller, "dsm" requires a DSM session
        \\  --require-group <name>  DSM group required in dsm mode (default: administrators)
        \\  --shell <path>          fallback shell
        \\  --term <name>           TERM value (default xterm-256color)
        \\  --max-sessions <n>      concurrent terminal limit
        \\  --base-path <prefix>    serve every endpoint under this prefix (e.g. /synoterm)
        \\  --insecure-origin       skip same-origin checks (dev only)
        \\
    , .{});
    return error.InvalidArguments;
}

// ---------------------------------------------------------------------------
// Connection handling
// ---------------------------------------------------------------------------

fn handleConnection(ctx: *Ctx, fd: sys.fd_t) void {
    defer sys.close(fd);
    sys.setNoDelay(fd);
    sys.setRecvTimeout(fd, 30);
    sys.setSendTimeout(fd, 30);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var head_buf: [http.max_head_bytes]u8 = undefined;
    const head = http.readHead(&head_buf, fd) catch return;

    const request = http.parse(allocator, head) catch {
        http.sendError(allocator, fd, 400, "Bad request");
        return;
    };

    const rel_path = underBasePath(request.path, ctx.cfg.base_path) orelse {
        // One URL space: /synoterm/healthz, /synoterm/status, /synoterm/ws —
        // behind the mount and on the package's own port alike.
        const hint = std.fmt.allocPrint(allocator, "not found: every endpoint lives under {s}/", .{
            std.mem.trimEnd(u8, ctx.cfg.base_path, "/"),
        }) catch "Not found";
        http.sendError(allocator, fd, 404, hint);
        return;
    };

    // The UI may be served by DSM on another port of the same host; a
    // same-host cross-port fetch is still a CORS request, so /status and
    // /healthz echo the validated origin. WebSockets are not subject to CORS.
    const cors_headers = corsHeaders(allocator, request, false) catch "";

    // A cross-port fetch that carries `X-Syno-Token` needs a preflight first.
    if (std.mem.eql(u8, request.method, "OPTIONS")) {
        handlePreflight(allocator, fd, request);
        return;
    }

    if (std.mem.eql(u8, rel_path, "/healthz")) {
        var body: [96]u8 = undefined;
        const json = std.fmt.bufPrint(&body, "{{\"ok\":true,\"version\":\"{s}\",\"api\":{d}}}\n", .{
            server_version, api_version,
        }) catch "{\"ok\":true}\n";
        var headers = util.List(u8).init(allocator);
        defer headers.deinit();
        headers.appendFmt("Cache-Control: no-store\r\n{s}", .{cors_headers}) catch {};
        http.send(allocator, fd, .{
            .status = 200,
            .content_type = "application/json; charset=utf-8",
            .body = json,
            .extra_headers = headers.items(),
        }) catch {};
        return;
    }
    if (std.mem.eql(u8, rel_path, "/status")) {
        serveStatus(ctx, allocator, fd, request);
        return;
    }

    if (isWebSocketUpgrade(request)) {
        if (!std.mem.eql(u8, rel_path, "/ws")) {
            http.sendError(allocator, fd, 404, "No websocket endpoint here");
            return;
        }
        handleWebSocket(ctx, allocator, fd, request);
    } else {
        serveStatic(allocator, fd, rel_path, request, ctx.cfg);
    }
}

/// Explains *why* a terminal connection would be refused. The browser cannot
/// read the status of a failed WebSocket handshake, so the UI calls this first
/// and can show "test token is stale" instead of an endless retry loop.
/// CORS headers for the control endpoints, but only for an origin that passes
/// the same host check as the WebSocket upgrade.
fn corsHeaders(allocator: std.mem.Allocator, request: http.Request, credentials: bool) ![]const u8 {
    const origin = request.header("Origin") orelse return "";
    const host = request.header("Host") orelse return "";
    if (!originMatchesHost(origin, host)) return "";
    if (credentials) {
        return std.fmt.allocPrint(allocator, "Access-Control-Allow-Origin: {s}\r\nAccess-Control-Allow-Credentials: true\r\nVary: Origin\r\n", .{origin});
    }
    return std.fmt.allocPrint(allocator, "Access-Control-Allow-Origin: {s}\r\nVary: Origin\r\n", .{origin});
}

/// Answers the CORS preflight that a cross-port `fetch()` with an
/// `X-Syno-Token` header triggers. Only an origin that passes the same host
/// check as the WebSocket upgrade gets an answer.
fn handlePreflight(allocator: std.mem.Allocator, fd: sys.fd_t, request: http.Request) void {
    const cors = corsHeaders(allocator, request, true) catch "";
    if (cors.len == 0) {
        http.sendError(allocator, fd, 403, "cross-origin request denied");
        return;
    }
    var headers = util.List(u8).init(allocator);
    defer headers.deinit();
    headers.appendFmt(
        "{s}Access-Control-Allow-Methods: GET, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: X-Syno-Token\r\n" ++
            "Access-Control-Max-Age: 600\r\n",
        .{cors},
    ) catch {};
    http.send(allocator, fd, .{ .status = 204, .extra_headers = headers.items() }) catch {};
}

fn serveStatus(ctx: *Ctx, allocator: std.mem.Allocator, fd: sys.fd_t, request: http.Request) void {
    const cors = corsHeaders(allocator, request, true) catch "";
    const access = checkAccess(ctx, allocator, fd, request, false) catch {
        http.sendError(allocator, fd, 500, "authorization failed");
        return;
    };
    switch (access) {
        .denied => |denied| {
            logDenial(request, fd, denied);
            var body = util.List(u8).init(allocator);
            defer body.deinit();
            body.appendFmt(
                "{{\"ok\":false,\"code\":{d},\"reason\":\"{s}\"}}\n",
                .{ denied.code, denied.reason },
            ) catch return;
            var headers = util.List(u8).init(allocator);
            defer headers.deinit();
            headers.appendFmt("Cache-Control: no-store\r\n{s}", .{cors}) catch {};
            http.send(allocator, fd, .{
                .status = denied.code,
                .content_type = "application/json; charset=utf-8",
                .body = body.items(),
                .extra_headers = headers.items(),
            }) catch {};
        },
        .allowed => |identity| {
            var body = util.List(u8).init(allocator);
            defer body.deinit();
            body.appendFmt(
                "{{\"ok\":true,\"user\":\"{s}\",\"sessions\":{d},\"max_sessions\":{d}," ++
                    "\"version\":\"{s}\",\"api\":{d}}}\n",
                .{
                    identity.user orelse "",
                    ctx.active_sessions.load(.monotonic),
                    ctx.cfg.max_sessions,
                    server_version,
                    api_version,
                },
            ) catch return;
            var headers = util.List(u8).init(allocator);
            defer headers.deinit();
            headers.appendFmt("Cache-Control: no-store\r\n{s}", .{cors}) catch {};
            http.send(allocator, fd, .{
                .status = 200,
                .content_type = "application/json; charset=utf-8",
                .body = body.items(),
                .extra_headers = headers.items(),
            }) catch {};
        },
    }
}

fn isWebSocketUpgrade(request: http.Request) bool {
    if (!request.hasToken("Connection", "upgrade")) return false;
    const upgrade = request.header("Upgrade") orelse return false;
    return std.ascii.eqlIgnoreCase(upgrade, "websocket");
}

/// Removes the configured prefix from a request path. Requests outside it are
/// refused (null), so there is exactly one endpoint space:
///   https://nas:5001/synoterm/…  (DSM nginx proxy, mounted by hand)
///   http://nas:7381/synoterm/…   (direct, package's own port)
fn underBasePath(path: []const u8, base_path: []const u8) ?[]const u8 {
    const base = std.mem.trimEnd(u8, base_path, "/");
    if (base.len == 0) return path;
    if (std.mem.eql(u8, path, base)) return "/";
    if (!std.mem.startsWith(u8, path, base)) return null;
    const rest = path[base.len..];
    if (rest[0] != '/') return null;
    return rest;
}

fn serveStatic(allocator: std.mem.Allocator, fd: sys.fd_t, rel_path: []const u8, request: http.Request, cfg: Config) void {
    if (!std.mem.eql(u8, request.method, "GET") and !std.mem.eql(u8, request.method, "HEAD")) {
        http.sendError(allocator, fd, 405, "Method not allowed");
        return;
    }
    const resolved = (http.resolvePath(allocator, cfg.web_root, rel_path) catch null) orelse {
        http.sendError(allocator, fd, 403, "Forbidden");
        return;
    };
    const body = http.readFileAll(allocator, resolved, max_static_bytes) catch {
        http.sendError(allocator, fd, 404, "Not found");
        return;
    };
    http.send(allocator, fd, .{
        .status = 200,
        .content_type = http.contentTypeFor(resolved),
        .body = body,
        .head_only = std.mem.eql(u8, request.method, "HEAD"),
        .extra_headers = "Cache-Control: no-cache\r\n",
    }) catch {};
}

const Identity = struct {
    /// `null` in dev mode: keep the invoking user.
    user: ?[:0]const u8 = null,
    uid: sys.uid_t = 0,
    gid: sys.gid_t = 0,
    home: [:0]const u8 = "/",
};

const Denied = struct {
    code: u16,
    reason: []const u8,
};

const Access = union(enum) {
    allowed: Identity,
    denied: Denied,
};

fn deny(code: u16, reason: []const u8) Access {
    return .{ .denied = .{ .code = code, .reason = reason } };
}

/// One line per refused request. A refused WebSocket handshake is invisible to
/// JavaScript (the browser reports "connection failed" and nothing else), so
/// the reason has to land in the service log. Presence flags only: the cookie
/// and the token are never written.
fn logDenial(request: http.Request, fd: sys.fd_t, denied: Denied) void {
    var peer_buf: [16]u8 = undefined;
    const peer = sys.peerIp(fd, &peer_buf) orelse "?";
    const token_count = tokenCandidateCount(request);
    // The request line is attacker-controlled: keep control bytes out of the
    // service log.
    var path_buf: [160]u8 = undefined;
    var origin_buf: [120]u8 = undefined;
    std.debug.print(
        "synoterm: refused {d} ({s}) path={s} peer={s} origin={s} cookie={s} tokens={d}\n",
        .{
            denied.code,
            denied.reason,
            printable(request.path, &path_buf),
            peer,
            printable(request.header("Origin") orelse "-", &origin_buf),
            if (request.header("Cookie") != null) "yes" else "no",
            token_count,
        },
    );
}

/// How many token candidates this request carries (0 = none presented).
fn tokenCandidateCount(request: http.Request) usize {
    var count: usize = 0;
    if (request.header("X-Syno-Token")) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            if (std.mem.trim(u8, part, " \t").len > 0) count += 1;
        }
    }
    if (request.header("Sec-WebSocket-Protocol")) |protocols| {
        var it = std.mem.splitScalar(u8, protocols, ',');
        while (it.next()) |raw| {
            const proto = std.mem.trim(u8, raw, " \t");
            if (std.mem.startsWith(u8, proto, "synoterm.syno-token.")) count += 1;
        }
    }
    return count;
}

/// Copies at most `buf.len` bytes, replacing control characters.
fn printable(text: []const u8, buf: []u8) []const u8 {
    const n = @min(text.len, buf.len);
    for (text[0..n], 0..) |c, i| buf[i] = if (c < 0x20 or c == 0x7f) '?' else c;
    return buf[0..n];
}

/// Same-origin + DSM/dev authentication + account policy. Shared by the
/// WebSocket upgrade and the `/status` probe so the UI can explain a refusal
/// instead of retrying blindly (a failed WS handshake gives JS no details).
fn checkAccess(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    fd: sys.fd_t,
    request: http.Request,
    strict_origin: bool,
) !Access {
    const host = request.header("Host") orelse "";

    // --- 1. same-origin check: WebSocket is not protected by CORS ---
    // Browsers always send Origin on a WebSocket upgrade. A same-origin
    // `fetch()` (the /status probe) only sends `Sec-Fetch-Site`, so the strict
    // path accepts that too; non-browser clients (curl) are allowed only when
    // `strict_origin` is false, which is the /status endpoint.
    if (!ctx.cfg.insecure_origin and !requestIsSameOrigin(request, host)) {
        const browser_context = request.header("Origin") != null or
            request.header("Referer") != null or
            request.header("Sec-Fetch-Site") != null;
        if (strict_origin or browser_context) {
            return deny(403, "cross-origin request denied");
        }
    }

    // --- 2. subprotocols/headers: DSM CSRF token and/or dev shared secret ---
    const syno_tokens = synoTokenCandidates(allocator, request);

    // --- 3. authenticate ---
    var identity = Identity{};
    switch (ctx.cfg.auth_mode) {
        .dev => {
            if (ctx.cfg.dev_token) |expected| {
                const presented = devTokenFromRequest(request, allocator);
                if (presented == null or !std.mem.eql(u8, presented.?, expected)) {
                    return deny(403, "test token missing or stale — reload the URL printed by nas-test.sh");
                }
            }
        },
        .dsm => {
            var peer_buf: [16]u8 = undefined;
            const peer = sys.peerIp(fd, &peer_buf) orelse "127.0.0.1";
            const cookie = request.header("Cookie") orelse "";
            const no_env = [_][*:0]const u8{};
            const proto = request.header("X-Forwarded-Proto") orelse
                (if (std.mem.endsWith(u8, host, ":443")) "https" else "http");

            // Try every token the page offered; the first one DSM accepts wins.
            // With no token at all, one attempt is made anyway, so a build that
            // does not need one still works.
            var last_status: u8 = 0;
            var attempted: usize = 0;
            var token_bytes: usize = 0;
            const attempts: usize = if (syno_tokens.len == 0) 1 else syno_tokens.len;
            var attempt: usize = 0;
            while (attempt < attempts) : (attempt += 1) {
                const token = if (syno_tokens.len == 0) "" else syno_tokens[attempt];
                token_bytes = token.len;
                const env = auth.cgiEnv(allocator, cookie, token, host, proto, request.path, peer, &no_env) catch
                    return deny(500, "out of memory");
                const capture = auth.runCapture(allocator, auth.authenticate_cgi, &no_env, env) catch
                    return deny(500, "DSM session lookup failed");
                attempted += 1;
                if (capture.status == 127) return deny(500, "authenticate.cgi is missing on this DSM build");
                if (capture.status != 0) {
                    last_status = capture.status;
                    continue;
                }
                const candidate = std.mem.trim(u8, capture.output, " \t\r\n");
                if (candidate.len == 0) {
                    last_status = 1;
                    continue;
                }
                if (!validAccountName(candidate)) return deny(403, "invalid account name");
                if (ctx.cfg.require_group.len > 0 and !accountInGroup(allocator, candidate, ctx.cfg.require_group)) {
                    return deny(403, "this account is not allowed to open a terminal");
                }
                const pw = (sys.lookupPasswd(allocator, "/etc/passwd", candidate) catch null) orelse
                    return deny(403, "account is not a local DSM user");
                identity.user = allocator.dupeSentinel(u8, candidate, 0) catch return deny(500, "out of memory");
                identity.uid = pw.uid;
                identity.gid = pw.gid;
                if (sys.homeDir(allocator, "/etc/passwd", candidate) catch null) |home| {
                    if (home.len > 0) identity.home = allocator.dupeSentinel(u8, home, 0) catch "/";
                }
                break;
            }
            if (identity.user == null) {
                if (attempted == 0) {
                    return deny(401, "no DSM session — open the terminal from the DSM desktop, or reload the page");
                }
                // The exit status is what distinguishes "no token found" from
                // "the token was rejected"; the sizes say which was sent.
                const reason = std.fmt.allocPrint(
                    allocator,
                    "DSM rejected the session (authenticate.cgi exit {d}; {d} token(s), {d} B, cookie {d} B)",
                    .{ last_status, attempted, token_bytes, cookie.len },
                ) catch "DSM rejected the session (SynoToken not accepted)";
                return deny(401, reason);
            }
        },
    }

    if (identity.user != null and sys.geteuid() != 0) {
        return deny(500, "synoterm lacks the setuid tool privilege");
    }
    return .{ .allowed = identity };
}

/// RFC 6455: echo exactly one of the offered subprotocols.
fn selectSubprotocol(request: http.Request) ?[]const u8 {
    const protocols = request.header("Sec-WebSocket-Protocol") orelse return null;
    var it = std.mem.splitScalar(u8, protocols, ',');
    var dev: ?[]const u8 = null;
    var syno: ?[]const u8 = null;
    while (it.next()) |raw| {
        const proto = std.mem.trim(u8, raw, " \t");
        if (dev == null and std.mem.startsWith(u8, proto, "synoterm.dev-token.")) dev = proto;
        if (syno == null and std.mem.startsWith(u8, proto, "synoterm.syno-token.")) syno = proto;
    }
    return dev orelse syno;
}

fn handleWebSocket(ctx: *Ctx, allocator: std.mem.Allocator, fd: sys.fd_t, request: http.Request) void {
    const access = checkAccess(ctx, allocator, fd, request, true) catch {
        http.sendError(allocator, fd, 500, "authorization failed");
        return;
    };
    var identity: Identity = switch (access) {
        .denied => |denied| {
            logDenial(request, fd, denied);
            http.sendError(allocator, fd, denied.code, denied.reason);
            return;
        },
        .allowed => |allowed| allowed,
    };
    _ = &identity;

    if (identity.user != null and sys.geteuid() != 0) {
        http.sendError(allocator, fd, 500, "synoterm is not running with the setuid tool privilege");
        return;
    }

    // --- 4. session budget ---
    if (ctx.active_sessions.fetchAdd(1, .monotonic) >= ctx.cfg.max_sessions) {
        _ = ctx.active_sessions.fetchSub(1, .monotonic);
        http.sendError(allocator, fd, 429, "Too many terminal sessions");
        return;
    }
    defer _ = ctx.active_sessions.fetchSub(1, .monotonic);

    // --- 5. handshake ---
    const key = request.header("Sec-WebSocket-Key") orelse {
        http.sendError(allocator, fd, 400, "Missing Sec-WebSocket-Key");
        return;
    };
    var accept_buf: [28]u8 = undefined;
    const accept = ws.acceptKey(&accept_buf, key);

    const selected_protocol = selectSubprotocol(request);
    var response = util.List(u8).init(allocator);
    defer response.deinit();
    response.appendFmt(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n",
        .{accept},
    ) catch return;
    if (selected_protocol) |proto| {
        response.appendFmt("Sec-WebSocket-Protocol: {s}\r\n", .{proto}) catch return;
    }
    response.appendSlice("\r\n") catch return;
    sys.writeAll(fd, response.items()) catch return;

    // The receive timeout above only exists to bound the HTTP header read.
    // An interactive terminal is idle for minutes at a time: keeping the
    // timeout would silently kill the session after N seconds of no input.
    sys.clearRecvTimeout(fd);

    // --- 6. spawn the shell and bridge ---
    var link = Link{ .fd = fd };

    const session_ptr = allocator.create(pty_session.Session) catch {
        http.sendError(allocator, fd, 500, "Out of memory");
        return;
    };
    session_ptr.* = pty_session.spawn(allocator, .{
        .shell = ctx.cfg.default_shell,
        .user = identity.user,
        .uid = identity.uid,
        .gid = identity.gid,
        .home = identity.home,
        .term = ctx.cfg.term,
    }) catch {
        allocator.destroy(session_ptr);
        link.sendText("{\"type\":\"error\",\"code\":\"shell_start_failed\"}");
        return;
    };
    defer {
        session_ptr.deinit();
        allocator.destroy(session_ptr);
    }

    var ready_buf: [192]u8 = undefined;
    const ready = std.fmt.bufPrint(&ready_buf, "{{\"type\":\"ready\",\"user\":\"{s}\",\"version\":\"{s}\"}}", .{
        identity.user orelse "", server_version,
    }) catch "{\"type\":\"ready\"}";
    link.sendText(ready);

    // pty -> browser
    const pump_thread = std.Thread.spawn(.{}, pumpFn, .{ session_ptr, &link }) catch null;

    // browser -> pty (frames allocate/free per message, so no arena)
    bridgeInput(std.heap.smp_allocator, session_ptr, &link);

    // Closing the master while the pump is still blocked in read() would race
    // with the pump; signal the shell instead and let the pump see EOF.
    sys.kill(-session_ptr.pid, .HUP);
    if (pump_thread) |t| t.join();
    session_ptr.terminate();
}

fn pumpFn(session_ptr: *pty_session.Session, link: *Link) void {
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = session_ptr.readOutput(&buf) catch return;
        if (n == 0) return;
        link.sendBinary(buf[0..n]);
    }
}

fn bridgeInput(allocator: std.mem.Allocator, session_ptr: *pty_session.Session, link: *Link) void {
    while (true) {
        // Per-message buffers use a real allocator: the connection arena is
        // never freed, so keystrokes would otherwise leak for the session's life.
        const frame = ws.readMessage(allocator, link.fd) catch return;
        defer allocator.free(frame.payload);

        switch (frame.opcode) {
            .binary => session_ptr.writeInput(frame.payload) catch return,
            .text => {
                if (jsonIntField(frame.payload, "cols")) |cols| {
                    const rows = jsonIntField(frame.payload, "rows") orelse 24;
                    session_ptr.resize(cols, rows);
                }
                if (std.mem.indexOf(u8, frame.payload, "\"close\"") != null) return;
            },
            .ping => {
                link.mutex.lock();
                ws.writeFrame(link.fd, .pong, frame.payload) catch {};
                link.mutex.unlock();
            },
            .close => {
                link.mutex.lock();
                ws.writeFrame(link.fd, .close, &.{}) catch {};
                link.mutex.unlock();
                return;
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parseIpv4(text: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var count: usize = 0;
    while (it.next()) |part| {
        if (count >= 4) return null;
        if (part.len == 0 or part.len > 3) return null;
        octets[count] = std.fmt.parseUnsigned(u8, part, 10) catch return null;
        count += 1;
    }
    if (count != 4) return null;
    return octets;
}

/// Every DSM CSRF token the page managed to find, in the order it found them.
///
/// The UI cannot know which of its sources is the real one (the desktop URL,
/// a global, a cookie, the page HTML), so it sends all of them and the first
/// one `authenticate.cgi` accepts wins. Two channels, because a WebSocket
/// cannot carry request headers and a `fetch()` cannot set
/// `Sec-WebSocket-Protocol`:
///   - `X-Syno-Token: t1,t2,…` — HTTP probes (`/status`);
///   - repeated `synoterm.syno-token.<base64url>` entries in
///     `Sec-WebSocket-Protocol` — the upgrade.
fn synoTokenCandidates(allocator: std.mem.Allocator, request: http.Request) []const []const u8 {
    const max_tokens = 8;
    var list = util.List([]const u8).init(allocator);

    if (request.header("X-Syno-Token")) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |part| {
            if (list.items().len >= max_tokens) break;
            const token = std.mem.trim(u8, part, " \t");
            if (token.len == 0 or token.len > 256) continue;
            if (containsToken(list.items(), token)) continue;
            list.append(token) catch break;
        }
    }
    if (request.header("Sec-WebSocket-Protocol")) |protocols| {
        var it = std.mem.splitScalar(u8, protocols, ',');
        while (it.next()) |raw| {
            if (list.items().len >= max_tokens) break;
            const proto = std.mem.trim(u8, raw, " \t");
            if (!std.mem.startsWith(u8, proto, "synoterm.syno-token.")) continue;
            const decoded = decodeBase64Url(allocator, proto["synoterm.syno-token.".len..]) orelse continue;
            if (decoded.len == 0 or decoded.len > 256) continue;
            if (containsToken(list.items(), decoded)) continue;
            list.append(decoded) catch break;
        }
    }
    return list.toOwnedSlice() catch &[_][]const u8{};
}

fn containsToken(tokens: []const []const u8, needle: []const u8) bool {
    for (tokens) |t| {
        if (std.mem.eql(u8, t, needle)) return true;
    }
    return false;
}

/// Dev-mode shared secret: `?t=<token>` or `synoterm.dev-token.<base64url>`.
fn devTokenFromRequest(request: http.Request, allocator: std.mem.Allocator) ?[]const u8 {
    if (queryParam(request.query, "t")) |value| {
        if (value.len > 0) return value;
    }
    if (request.header("Sec-WebSocket-Protocol")) |protocols| {
        var it = std.mem.splitScalar(u8, protocols, ',');
        while (it.next()) |raw| {
            const proto = std.mem.trim(u8, raw, " \t");
            if (std.mem.startsWith(u8, proto, "synoterm.dev-token.")) {
                return decodeBase64Url(allocator, proto["synoterm.dev-token.".len..]);
            }
        }
    }
    return null;
}

fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

fn requestIsSameOrigin(request: http.Request, host: []const u8) bool {
    if (request.header("Origin")) |origin| return originMatchesHost(origin, host);
    if (request.header("Sec-Fetch-Site")) |site| {
        if (std.mem.eql(u8, site, "same-origin") or std.mem.eql(u8, site, "none")) return true;
    }
    if (request.header("Referer")) |referer| return originMatchesHost(referer, host);
    return false;
}

fn hostWithoutPort(value: []const u8) []const u8 {
    // IPv6 literals keep their brackets; strip "]:port" as well.
    if (std.mem.lastIndexOfScalar(u8, value, ':')) |colon| {
        const after = value[colon + 1 ..];
        const is_port = after.len > 0 and std.mem.indexOfScalar(u8, value, ']') == null;
        if (is_port) return value[0..colon];
    }
    return value;
}

fn originMatchesHost(origin: []const u8, host: []const u8) bool {
    if (origin.len == 0 or host.len == 0) return false;
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return false;
    const after_scheme = origin[scheme_end + 3 ..];
    const end = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
    const origin_host = after_scheme[0..end];

    // Same host, different port is expected: DSM serves the UI on :5000 while the
    // terminal listens on its own port, and cookies are host-scoped (not
    // port-scoped), so the browser does send the DSM session cookie to us.
    // Authentication still requires the DSM token, which only a page served by
    // DSM itself can obtain, so this does not let another local app impersonate
    // the user.
    return std.ascii.eqlIgnoreCase(hostWithoutPort(origin_host), hostWithoutPort(host));
}

fn decodeBase64Url(allocator: std.mem.Allocator, encoded: []const u8) ?[]u8 {
    var padded = util.List(u8).init(allocator);
    padded.appendSlice(encoded) catch return null;
    while (padded.items().len % 4 != 0) padded.append('=') catch return null;
    const decoder = std.base64.url_safe.Decoder;
    const out_len = decoder.calcSizeForSlice(padded.items()) catch return null;
    const out = allocator.alloc(u8, out_len) catch return null;
    decoder.decode(out, padded.items()) catch return null;
    return out;
}

fn validAccountName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        if (c <= 0x20 or c == ':' or c == 0x7f) return false;
    }
    return true;
}

/// Returns true when `user` is a member of `group`, using DSM's own `id` so
/// that LDAP/AD group memberships resolve exactly like they do in a shell.
fn accountInGroup(allocator: std.mem.Allocator, user: []const u8, group: []const u8) bool {
    const userz = allocator.dupeSentinel(u8, user, 0) catch return false;
    const argv = [_:null]?[*:0]const u8{ auth.id_bin, "-Gn", userz.ptr };
    const envp = [_:null]?[*:0]const u8{null};

    var fds: [2]sys.fd_t = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return false;
    const read_fd = fds[0];
    const write_fd = fds[1];

    const child = sys.libcFork() catch {
        sys.close(read_fd);
        sys.close(write_fd);
        return false;
    };
    if (child == 0) {
        sys.close(read_fd);
        sys.dup2(write_fd, 1) catch sys.exitNow(126);
        if (write_fd > 2) sys.close(write_fd);
        sys.execveZ(auth.id_bin, &argv, @ptrCast(&envp)) catch {};
        sys.exitNow(127);
    }
    sys.close(write_fd);

    var out: [4096]u8 = undefined;
    var filled: usize = 0;
    while (filled < out.len) {
        const n = sys.read(read_fd, out[filled..]) catch break;
        if (n == 0) break;
        filled += n;
    }
    sys.close(read_fd);
    _ = sys.waitPid(child) catch {};

    var it = std.mem.tokenizeAny(u8, out[0..filled], " \t\r\n");
    while (it.next()) |name| {
        if (std.mem.eql(u8, name, group)) return true;
    }
    return false;
}

fn jsonIntField(json: []const u8, key: []const u8) ?u16 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, json, needle) orelse return null;
    var i = idx + needle.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseUnsigned(u16, json[start..i], 10) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "accept key matches the RFC 6455 example" {
    var buf: [28]u8 = undefined;
    const accept = ws.acceptKey(&buf, "dGhlIHNhbXBsZSBub25jZQ==");
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "origin host comparison" {
    try std.testing.expect(originMatchesHost("https://nas.local:5001", "nas.local:5001"));
    try std.testing.expect(originMatchesHost("http://127.0.0.1:8080", "127.0.0.1:8080"));
    // DSM page on :5000 → terminal on :7381 of the same host.
    try std.testing.expect(originMatchesHost("http://nas.local:5000", "nas.local:7381"));
    try std.testing.expect(originMatchesHost("http://192.168.0.18:5000", "192.168.0.18:7381"));
    // Different host stays rejected.
    try std.testing.expect(!originMatchesHost("https://evil.example", "nas.local:5001"));
    try std.testing.expect(!originMatchesHost("http://evil.example:5000", "nas.local:7381"));
    try std.testing.expect(!originMatchesHost("", "nas.local:5001"));
}

test "json int field" {
    try std.testing.expectEqual(@as(?u16, 120), jsonIntField("{\"type\":\"resize\",\"cols\":120,\"rows\":40}", "cols"));
    try std.testing.expectEqual(@as(?u16, 40), jsonIntField("{\"cols\":120,\"rows\":40}", "rows"));
    try std.testing.expectEqual(@as(?u16, null), jsonIntField("{\"cols\":\"x\"}", "cols"));
}

test "ipv4 parsing and query params" {
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, parseIpv4("0.0.0.0").?);
    try std.testing.expectEqual([4]u8{ 192, 168, 0, 18 }, parseIpv4("192.168.0.18").?);
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("192.168.0"));
    try std.testing.expectEqual(@as(?[4]u8, null), parseIpv4("192.168.0.256"));
    try std.testing.expectEqualStrings("secret", queryParam("ws=/ws&t=secret", "t").?);
    try std.testing.expectEqual(@as(?[]const u8, null), queryParam("ws=/ws", "t"));
}

test "endpoints live under the configured prefix" {
    // No prefix (dev): paths pass through unchanged.
    try std.testing.expectEqualStrings("/healthz", underBasePath("/healthz", "").?);
    // Behind the mount and on the direct port alike.
    try std.testing.expectEqualStrings("/healthz", underBasePath("/synoterm/healthz", "/synoterm").?);
    try std.testing.expectEqualStrings("/ws", underBasePath("/synoterm/ws", "/synoterm/").?);
    try std.testing.expectEqualStrings("/", underBasePath("/synoterm", "/synoterm").?);
    // Anything outside the prefix, or a bare lookalike, is refused.
    try std.testing.expectEqual(@as(?[]const u8, null), underBasePath("/healthz", "/synoterm"));
    try std.testing.expectEqual(@as(?[]const u8, null), underBasePath("/synotermfoo/ws", "/synoterm"));
    try std.testing.expectEqual(@as(?[]const u8, null), underBasePath("/", "/synoterm"));
}

test "syno token candidates come from the header or the upgrade subprotocol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const header_only = try http.parse(a, "GET /synoterm/status HTTP/1.1\r\nHost: nas:7381\r\nX-Syno-Token: abc123\r\n\r\n");
    const one = synoTokenCandidates(a, header_only);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("abc123", one[0]);

    // The UI sends every token it found; the server tries them in order.
    const many = try http.parse(a, "GET /synoterm/status HTTP/1.1\r\nHost: nas:7381\r\nX-Syno-Token: aaa, bbb ,ccc\r\n\r\n");
    const list = synoTokenCandidates(a, many);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("bbb", list[1]);

    // base64url("tok") = "dG9r", base64url("other") = "b3RoZXI"
    const upgrade = try http.parse(a, "GET /synoterm/ws HTTP/1.1\r\nHost: nas:7381\r\nSec-WebSocket-Protocol: synoterm.syno-token.dG9r, synoterm.syno-token.b3RoZXI\r\n\r\n");
    const protos = synoTokenCandidates(a, upgrade);
    try std.testing.expectEqual(@as(usize, 2), protos.len);
    try std.testing.expectEqualStrings("tok", protos[0]);
    try std.testing.expectEqualStrings("other", protos[1]);

    const none = try http.parse(a, "GET /synoterm/status HTTP/1.1\r\nHost: nas:7381\r\n\r\n");
    try std.testing.expectEqual(@as(usize, 0), synoTokenCandidates(a, none).len);
    try std.testing.expectEqual(@as(usize, 0), tokenCandidateCount(none));
}

test "request parsing" {
    const head = "GET /app.js?v=1 HTTP/1.1\r\nHost: nas:5001\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n\r\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try http.parse(arena.allocator(), head);
    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/app.js", req.path);
    try std.testing.expectEqualStrings("v=1", req.query);
    try std.testing.expect(req.hasToken("Connection", "upgrade"));
    try std.testing.expect(isWebSocketUpgrade(req));
}
