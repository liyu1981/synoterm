# Architecture

## 1. Process and thread model

```
synoterm process (starts setuid root, only the PTY spawn is privileged)
├── thread: accept loop              blocking accept(2) on 127.0.0.1:7381
├── thread: connection #1
│    ├── read request head (HTTP)
│    ├── if GET  → serve file from --web-root
│    └── if WS   → handshake → authenticate → spawn PTY
│          ├── thread: pty pump   pty master ──binary frames──▶ socket
│          └── thread (self):     socket ──binary frames──▶ pty master
└── thread: connection #2 …
```

One thread per connection and one extra thread per live terminal. On a NAS
this is 5–20 threads for typical use; there is no async runtime, no event loop
and no growth in complexity with every feature.

Writes to the socket happen from two places (the pump thread and control
messages from the reader loop), so `Link` guards them with a small futex mutex
(`util.Mutex`) — never a spinlock, because a blocked socket write can last up
to the 30 s `SO_SNDTIMEO`.

### Why not async/`std.Io`?

Zig 0.17 replaced `std.Io` wholesale (`std.ArrayList.init`, `std.Thread.Mutex`,
`dupeZ`, `**`, `@cImport` are all gone). All OS and stdlib touch points are
confined to `src/sys.zig` and `src/util.zig`, both written against
`std.os.linux` raw syscalls plus a handful of libc `extern`s. A future
toolchain bump should only require editing those two files; `main.zig`,
`ws.zig`, `http.zig`, `session.zig` and `auth.zig` are plain Zig.

## 2. Session lifecycle

```
browser                         synoterm                        kernel
  │  GET /synoterm/ws                │                              │
  │  Upgrade: websocket              │                              │
  ├─────────────────────────────────▶│                              │
  │                                  │ check Origin == Host         │
  │                                  │ run authenticate.cgi ────────┼─▶ DSM
  │                                  │ id -Gn <user> ───────────────┼─▶ NSS
  │  101 + Sec-WebSocket-Protocol    │                              │
  │◀─────────────────────────────────┤                              │
  │                                  │ open /dev/ptmx ──────────────┼─▶ pty
  │                                  │ fork()                       │
  │                                  │   setsid, TIOCSCTTY          │
  │                                  │   setgroups/setgid/setuid    │
  │                                  │   exec "-bash"               │
  │  {"type":"ready"}                │                              │
  │◀─────────────────────────────────┤                              │
  │  binary: keystrokes              │                              │
  ├─────────────────────────────────▶│ write(master)                │
  │  binary: output                  │◀─ read(master) ──────────────┤
  │◀─────────────────────────────────┤                              │
  │  {"type":"resize","cols":..}     │                              │
  ├─────────────────────────────────▶│ ioctl(master, TIOCSWINSZ)    │
  │  close / socket error            │                              │
  ├─────────────────────────────────▶│ kill(-pid, SIGHUP)           │
  │                                  │ join(pump)                   │
  │                                  │ waitpid()                    │
  │                                  │ close(master), free strings  │
```

Ordering that matters:

* `setsid()` **before** `TIOCSCTTY`, and the slave must not yet be the
  controlling terminal.
* `setgroups()` → `setgid()` → `setuid()`, in that order; `setuid` as root
  drops all three uids on Linux and cannot be undone.
* All allocations, `getgrouplist()` and NSS lookups happen **before** `fork()`;
  the child only performs async-signal-safe syscalls.
* On teardown, SIGHUP the *process group* (so `vim`/`htop`/subshells die), let
  the pump observe EOF, and only then reap and close — closing the master while
  another thread is blocked reading it is a race.

## 3. Module map

| File | Responsibility | Depends on |
| --- | --- | --- |
| `src/main.zig` | CLI/env config, routing, auth orchestration, session wiring, tests | all |
| `src/http.zig` | request-head parse, header access, static file serving, MIME, path traversal guard | `sys` |
| `src/ws.zig` | RFC 6455 handshake, frame codec (masking, fragmentation, control frames), 1 MiB cap | `sys`, `util` |
| `src/session.zig` | PTY open, fork/exec, user switch, env/argv lifetime, resize, output pump | `sys`, `ws`, `util` |
| `src/auth.zig` | CGI env construction, `runCapture()` (pipe+fork+exec), authenticate.cgi | `sys`, `util` |
| `src/sys.zig` | sockets, PTY ioctls, process control, waitpid, users, `/etc/passwd` | `std.os.linux`, libc externs |
| `src/util.zig` | `List(T)` (0.17 unmanaged ArrayList + captured allocator), futex `Mutex`, `allocPrintZ` | `std` |
| `frontend/src/main.js` | tab manager, xterm.js terminals, WS client, token subprotocol | xterm.js, addons |
| `packaging/dsm7/*` | DSM metadata, nginx snippet, Vue wrapper, lifecycle scripts | — |

## 4. Frontend

* Bundled by esbuild into `frontend/dist/app.js` (~350 KB, no framework, no CDN
  — the NAS may be offline).
* `Terminal` per tab, `FitAddon` for sizing, `WebLinksAddon` for clickable URLs.
* Keystrokes go out as **binary** frames (xterm.js `onData` → `TextEncoder`);
  control messages (`resize`, `close`) are **text** frames with JSON.
* Reconnect with exponential backoff (0.5 s → 8 s). With M3 the reattach
  includes the VT snapshot, so the user lands exactly where they left off.
* The stylesheet is imported as text and injected by the bundle, so a DSM
  upgrade cannot leave a stale `<link>` behind (a real bug in similar packages).

## 5. Security model

Trust boundaries:

1. **Browser → DSM nginx** — DSM's TLS and session cookie.
2. **DSM nginx → 127.0.0.1:7381** — loopback only; the nginx snippet is the
   only ingress.
3. **synoterm → DSM** — `authenticate.cgi` and `id` are read-only lookups; no
   credentials are ever stored or forwarded.
4. **synoterm → kernel** — the only privileged operations are `openpt`,
   `fork`, `setgroups/setgid/setuid` and `ioctl(TIOCSWINSZ)`.

Threats and mitigations:

| Threat | Mitigation |
| --- | --- |
| Cross-site WebSocket hijack | `Origin` host must equal `Host`; optional `SynoToken` requirement (M4) |
| Privilege escalation via the setuid binary | no shell invocation, no `exec` of user-supplied paths, fixed-format inputs, session count cap, M4 privileged-spawner split |
| Path traversal on static files | segment-wise resolution, `.`/`..` rejected, no symlink follow-out, 404 not 403 for misses |
| Memory exhaustion | 1 MiB WS message cap, 16 KiB HTTP head cap, 32 MiB static file cap, bounded sessions, 16 KiB pump buffer |
| Secret leakage in logs | no terminal content is logged; nginx `access_log off` for the mount |
| Orphaned processes | one SIGHUP per socket close, `waitpid`, package stop kills the group |
| Root process exposed to the network | M4: network process drops to the package user; only a minimal spawner stays root |

## 6. Data flow for the M3 persistence layer

```
                     ┌──────────────────────────────────┐
  pty master ──────▶ │ VT state (libghostty-vt)         │ ──▶ search / snapshot
                     │  ghostty_terminal_vt_write()     │
                     └──────────────────────────────────┘
                                    │
                                    ├── live: raw bytes ──▶ attached socket
                                    └── reattach: GHOSTTY_FORMATTER_FORMAT_VT
                                                   ──▶ new socket ──▶ xterm.js
```

Both paths share one writer, so the browser always sees a consistent stream:
snapshot first, then the bytes that arrived after the snapshot was taken
(a small per-session queue closes the gap).

## 7. Failure behaviour

| Failure | Result |
| --- | --- |
| `authenticate.cgi` missing/errors | 500, nothing spawned |
| Not an administrator | 403 before the handshake completes |
| `fork`/`exec` fails | `{"type":"error","code":"shell_start_failed"}` then close |
| Socket drops | shell gets SIGHUP (M0–M2) or stays alive for reattach (M3) |
| Package stop | all sessions in the process group get SIGHUP |
| nginx snippet missing | static UI still loads; the WS URL falls back to `--web-root`-served assets and a direct loopback port (dev only) |
