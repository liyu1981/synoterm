# WebSocket protocol (v1)

One WebSocket per terminal tab. The endpoint is `/ws` relative to the mount
point (`/synoterm/ws` in DSM, `/ws` in dev).

* Transport: RFC 6455 over the DSM origin (`wss://nas:5001/synoterm/ws`).
* No subprotocol is required, but clients **may** offer
  `synoterm.syno-token.<base64url>`; the server echoes it when it uses the token
  for DSM authentication.
* Binary frames carry raw terminal bytes. Text frames carry JSON control
  messages. This split keeps the hot path (keystrokes/output) free of parsing.

## 1. Browser → server

### Binary frame: terminal input

Raw bytes exactly as xterm.js produced them (UTF-8, including `\r`, control
characters, bracketed-paste sequences). Written verbatim to the PTY master.

### Text frame: control

```json
{ "type": "resize", "cols": 120, "rows": 40 }
```

| Type | Fields | Meaning |
| --- | --- | --- |
| `resize` | `cols`, `rows` (1..65535) | `TIOCSWINSZ` on the PTY; the kernel sends `SIGWINCH` to the foreground process group |
| `close` | — | Ask the server to end the session (the client usually also sends a WS close frame) |

Unknown `type` values are ignored (forward compatibility). Unknown numeric
fields are clamped to sane bounds.

## 2. Server → browser

### Text frame: control

```json
{ "type": "ready", "user": "alice" }
{ "type": "error", "code": "shell_start_failed", "message": "…" }
{ "type": "exit",  "code": 0 }
{ "type": "session", "id": "s-7f3a", "state": "attached" }   // M3
{ "type": "snapshot", "cols": 120, "rows": 40, "bytes": 8123 } // M3 (header only)
```

| Type | When |
| --- | --- |
| `ready` | after the PTY exists and the shell was exec'd |
| `error` | PTY/exec failure, policy rejection, limit hit; the socket closes after it |
| `exit` | the shell exited; `code` is the exit status (128+signal for signals) |
| `session` | (M3) session metadata on attach/detach |
| `snapshot` | (M3) the next binary frames are a VT replay, not live output |

### Binary frame: terminal output

Raw PTY output. In v1 it is always live output; with M3, the first binary
frames after a `snapshot` control message are the replay of the VT state, and
the client writes them to xterm.js exactly like live data.

## 3. Close behaviour

| Event | Server action |
| --- | --- |
| client close frame | reply with close, SIGHUP the process group (v1), reap |
| socket error / timeout | same as client close |
| shell exits | send `exit`, then a close frame |
| server shutdown | close frames on all sessions, then SIGHUP |

v1 always terminates the shell when the socket goes away. M3 changes this:
the session moves to `detached` and stays alive until the idle GC removes it.

## 4. Handshake details

```
GET /synoterm/ws HTTP/1.1
Host: nas:5001
Origin: https://nas:5001
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <base64 16 bytes>
Sec-WebSocket-Version: 13
Sec-WebSocket-Protocol: synoterm.syno-token.<base64url>
Cookie: id=<DSM session>
```

Response:

```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: <sha1(key + GUID), base64>
Sec-WebSocket-Protocol: synoterm.syno-token.<base64url>   (echoed if used)
```

Rejection responses (plain HTTP, before the upgrade):

| Status | Cause |
| --- | --- |
| 401 | no valid DSM session |
| 403 | cross-origin, or account not in the required group |
| 404 | upgrade on a path other than `/ws` |
| 429 | session limit reached |
| 500 | `authenticate.cgi` failed / binary lacks the setuid privilege |

## 5. Plain HTTP endpoints

| Path | Purpose |
| --- | --- |
| `GET /healthz` | `{"ok":true}` — reachability probe, no auth |
| `GET /status` | runs the **same** origin/auth/policy checks as the upgrade and returns `{"ok":true,"user":"…","sessions":n,"max_sessions":n}` or `{"ok":false,"code":401,"reason":"…"}` |

`/status` exists because a browser cannot read the status code of a failed
WebSocket handshake: when a connection drops, the UI fetches `/status` and shows
the reason ("test token missing or stale — reload the URL printed by
nas-test.sh", "no DSM session", "this account is not allowed…") instead of an
endless `disconnected, retrying in 1s…` loop. Non-browser clients (curl) may call
`/status` without an `Origin` header; the WebSocket upgrade itself is strict.

## 6. Framing rules

Server-side limits (all enforced in `src/ws.zig`):

| Limit | Value |
| --- | --- |
| message payload | 1 MiB |
| fragmentation | reassembled, control frames must not be fragmented |
| masking | client frames must be masked; unmasked → 1002 |
| RSV bits | must be zero (no extensions negotiated) |
| opcodes | text, binary, close, ping, pong, continuation |

Ping/pong is handled transparently; the server also answers pings while the
PTY is idle, which keeps DSM's nginx proxy from timing the connection out.

## 7. Compatibility notes

* `resize` may arrive before `ready`; it is applied to the PTY as soon as it
  exists (the client sends its current size on `open`).
* The client sends `resize` on every xterm.js resize event; the server debounces
  nothing and relies on `TIOCSWINSZ` being cheap.
* Additional fields in control messages must be ignored, not rejected, so that
  older frontends keep working against newer backends (and vice versa).
* The server reads the HTTP request head and then expects to *send* the 101
  before any WebSocket frame arrives. Clients must not pipeline frames with the
  upgrade request (browsers do not). Pipelined bytes are discarded.
