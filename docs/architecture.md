# Architecture

## 1. Process and thread model

```
synoterm process (unprivileged in AUTH="ssh"; a setuid tool only in "dsm")
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

The PTY plumbing is the same in both auth modes; only what the child *is*
differs:

* `AUTH="ssh"` (default) — the child is the ssh client
  (`ssh -tt -o … -l <account> 127.0.0.1`) and DSM's sshd shows the password/OTP
  prompt **inside xterm**. The process never leaves the unprivileged package
  user and no DSM API is called.
* `AUTH="dsm"` — `authenticate.cgi` maps the browser's cookie + SynoToken to an
  account, and the child is a login shell forked as that user, which needs the
  setuid `tool` build (`SYNOTERM_SETUID=1`).

```
browser                         synoterm                        kernel
  │  GET /synoterm/ws?user=…         │                              │
  │  Upgrade: websocket              │                              │
  ├─────────────────────────────────▶│                              │
  │                                  │ check Origin == Host         │
  │                                  │ ssh: validate the account    │
  │                                  │ dsm: authenticate.cgi ───────┼─▶ DSM
  │                                  │      id -Gn <user> ──────────┼─▶ NSS
  │  101                             │                              │
  │◀─────────────────────────────────┤                              │
  │                                  │ open /dev/ptmx ──────────────┼─▶ pty
  │                                  │ fork()                       │
  │                                  │   setsid, TIOCSCTTY          │
  │                                  │   (dsm) setgroups/setgid/setuid
  │                                  │   exec ssh -l <user> | -bash │
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
  │  {"type":"exit","code":n}        │                              │
  │◀─────────────────────────────────┤ close(master), free strings  │
```

Ordering that matters:

* `setsid()` **before** `TIOCSCTTY`, and the slave must not yet be the
  controlling terminal.
* `setgroups()` → `setgid()` → `setuid()`, in that order; `setuid` as root
  drops all three uids on Linux and cannot be undone. (dsm mode only.)
* All allocations, `getgrouplist()` and NSS lookups happen **before** `fork()`;
  the child only performs async-signal-safe syscalls.
* On teardown, SIGHUP the *process group* (so `vim`/`htop`/subshells die), let
  the pump observe EOF, and only then reap and close — closing the master while
  another thread is blocked reading it is a race.
* The pump reports the child's exit status (`{"type":"exit","code":n}`) and
  closes once; `code` 0 means a deliberate `exit`, ssh's 255 a refused login.
  Only one close frame may be sent (`Link.sendClose`), otherwise browsers log
  "Close received after close" and fire an `error` event.

## 3. Module map

| File | Responsibility | Depends on |
| --- | --- | --- |
| `src/main.zig` | CLI/env config, routing, auth per mode (dev/dsm/ssh), ssh argv, session wiring, tests | all |
| `src/http.zig` | request-head parse, header access, static file serving, MIME, path traversal guard | `sys` |
| `src/ws.zig` | RFC 6455 handshake, frame codec (masking, fragmentation, control frames), 1 MiB cap | `sys`, `util` |
| `src/session.zig` | PTY open, fork/exec of an arbitrary argv (ssh or shell), optional user switch, env/argv lifetime, resize, output pump | `sys`, `ws`, `util` |
| `src/auth.zig` | dsm mode only: CGI env construction, `runCapture()` (pipe+fork+exec), authenticate.cgi | `sys`, `util` |
| `src/sys.zig` | sockets, PTY ioctls, process control, waitpid, users, `/etc/passwd` | `std.os.linux`, libc externs |
| `src/util.zig` | `List(T)` (0.17 unmanaged ArrayList + captured allocator), futex `Mutex`, `allocPrintZ` | `std` |
| `frontend/src/main.js` | tab manager, xterm.js terminals, WS client, login prompt (ssh) / token subprotocol (dsm) | xterm.js, addons |
| `packaging/dsm7/*` | DSM metadata, nginx snippet, Vue wrapper, lifecycle scripts | — |

## 4. Frontend

Two hard-won rules, each guarding against a bug seen on a real NAS:

* **Load `@xterm/xterm/css/xterm.css`.** xterm's helper elements (font-width
  measurement container, hidden textarea, accessibility layer) rely on it. Without
  it they are painted, producing a stray row of repeated characters (e.g.
  `$$$$$$$$$$` or `----4444`) above the prompt.
* **Open the terminal only in a visible, laid-out pane**, and re-`fit()` after
  `document.fonts.ready`; xterm measures the character cell from the container at
  `open()`/`resize()` time.


* Bundled by esbuild into `frontend/dist/app.js` (~350 KB, no framework, no CDN
  — the NAS may be offline).
* `Terminal` per tab, `FitAddon` for sizing, `WebLinksAddon` for clickable URLs.
* The 16-colour palette is tuned for a dark surface and `minimumContrastRatio:
  4.5` is set, so colours a program chooses (including the 256-colour cube and
  `ls --color`'s `ow=34;42` "blue on green") are raised to a readable contrast
  instead of vanishing into the background.
* Keystrokes go out as **binary** frames (xterm.js `onData` → `TextEncoder`);
  control messages (`resize`, `close`) are **text** frames with JSON.
* Reconnect with exponential backoff (0.5 s → 8 s), and only when the socket
  really dropped: the backend clears `SO_RCVTIMEO` after the upgrade, because an
  interactive session is idle for minutes and a 30 s receive timeout silently
  killed it (visible as "disconnected, retrying in 1 s" after a pause). With M3 the reattach
  includes the VT snapshot, so the user lands exactly where they left off.
* The stylesheet is imported as text and injected by the bundle, so a DSM
  upgrade cannot leave a stale `<link>` behind (a real bug in similar packages).
* **Clipboard**: xterm.js maps `Ctrl+V` to `^V` and calls `preventDefault()`, so
  the browser never performed a paste (this was a real bug report). The custom
  key handler now returns `false` for plain `Ctrl/Cmd+V` *without* preventing the
  default, which lets Chromium paste into xterm's hidden textarea — no clipboard
  permission required. `Ctrl+Shift+V` and `Shift+Insert` are handled explicitly
  via `navigator.clipboard.readText()` (needs a user gesture; the ExtJS wrapper
  grants the iframe `clipboard-read`/`clipboard-write`), `Ctrl/Cmd+C` copies a
  selection and clears it, and a document-level `paste` listener forwards pastes
  that land outside the terminal.
* **Appearance settings** (`frontend/src/settings.js`): font family, size and
  line height, with URL parameters (`?fontFamily=…&fontSize=…&lineHeight=…`) >
  `localStorage` (`synoterm.settings.v1`) > defaults. Values are sanitised and
  clamped (size 8–32, line height 1.0–2.5, family ≤ 200 chars, no control or
  CSS-breaking characters). Changing them sets the xterm options, re-fits so the
  PTY gets the new column count, and repaints; no webfonts are downloaded — the
  family must exist on the device.

## 5. Security model

Trust boundaries:

1. **Browser → DSM nginx** — DSM's TLS (reverse proxy or the contrib snippet).
2. **DSM nginx → 127.0.0.1:7381** — loopback only; DSM's web server is the only
   ingress in both shipped deployments.
3. **synoterm → DSM** — ssh mode: the ssh client is the *only* thing that talks
   to DSM, and the password goes browser → pty → ssh → sshd without synoterm
   inspecting it. dsm mode: `authenticate.cgi` and `id` are read-only lookups;
   no credentials are stored or forwarded.
4. **synoterm → kernel** — in ssh mode the process is unprivileged: `openpt`,
   `fork`, `execve`, `ioctl(TIOCSWINSZ)`. Only the dsm-mode build adds
   `setgroups/setgid/setuid`.

Threats and mitigations:

| Threat | Mitigation |
| --- | --- |
| Cross-site WebSocket hijack | `Origin` host must equal `Host` (both modes); a SynoToken is additionally required in dsm mode |
| Credential theft | ssh mode: the password only exists in the pty stream; it is never parsed, logged or stored. dsm mode: no credential is involved at all |
| Brute force | ssh mode: DSM's own sshd limits (`MaxAuthTries`, 3 password prompts per session) and DSM auto-block; the login prompt is loopback-only unless `BIND=0.0.0.0` |
| Privilege escalation via the setuid binary | only the opt-in dsm build has one; no shell invocation, no `exec` of user-supplied paths, fixed-format inputs, session count cap |
| Path traversal on static files | segment-wise resolution, `.`/`..` rejected, no symlink follow-out, 404 not 403 for misses |
| Memory exhaustion | 1 MiB WS message cap, 16 KiB HTTP head cap, 32 MiB static file cap, bounded sessions, 16 KiB pump buffer |
| Secret leakage in logs | no terminal content is logged; nginx `access_log off` for the mount |
| Orphaned processes | one SIGHUP per socket close, `waitpid`, package stop kills the group |
| Root process exposed to the network | ssh mode has no privileged process at all; dsm mode: the network process drops to the package user, only the spawn is privileged |

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
| `authenticate.cgi` missing/errors (dsm) | 500, nothing spawned |
| Not an administrator (dsm) | 403 before the handshake completes |
| ssh client missing / sshd not running (ssh) | the pty exists, ssh writes the reason into the terminal and exits 255; the UI reconnects so the password can be retried |
| No account name on the upgrade (ssh) | 400 before any process is spawned (a leading `-` is refused too) |
| `fork`/`exec` fails | `{"type":"error","code":"shell_start_failed"}` then close |
| Socket drops | shell gets SIGHUP (M0–M2) or stays alive for reattach (M3) |
| Package stop | all sessions in the process group get SIGHUP |
| nginx snippet missing | static UI still loads; the WS URL falls back to `--web-root`-served assets and a direct loopback port (dev only) |
