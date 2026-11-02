# synoterm — project plan

Target: **DSM 7.1+** (`os_min_ver="7.1-42661"`), x86_64 / armv8 / armv7.
Language: **Zig** (backend) + **xterm.js** (frontend), packaged as a native
Synology `.spk`.

Product decisions for v1 (settled, see §6):

* **7.1 floor** → default to the *documented* `.url` desktop registration, which
  exists in 7.0/7.1/7.2; the 7.2-only Vue window wrapper is a build-time
  alternative (`SYNOTERM_UI_STYLE=vue`).
* **Admins only** (`allUsers: false`, group `administrators`).
* **Local DSM accounts only** — AD/LDAP accounts are refused in v1.
* **Sessions die with the socket** — no detached sessions, so no server-side VT
  state is needed in v1 (`libghostty-vt` is deferred, §M3).
* **Unsigned builds** for development; signing is documented but not required.

This document is the source of truth for scope, sequencing and risk. It is
updated as milestones close; everything marked **verified** was checked against
Synology's published developer guide or against a shipping DSM 7.2 package
(links in [references.md](references.md)), everything marked **to verify** needs
a real NAS or Virtual DSM.

---

## 1. Problem statement

DSM 7 runs third-party packages with strict privilege separation: the package
user cannot fork a shell as an arbitrary DSM account, and the DSM desktop is
served from a single origin with a single session model. A terminal therefore
needs three things that are easy to get wrong:

1. a way to spawn a shell **as the logged-in DSM user** without asking for a
   password a second time,
2. a transport that is **same-origin, TLS, WebSocket-capable** and does not
   punch a hole in the NAS firewall,
3. correct cleanup: no orphaned shells, no root processes sprawling, no
   cross-site WebSocket hijacking.

synoterm solves these with DSM's own primitives:

| Need | Primitive |
| --- | --- |
| identity | `/usr/syno/synoman/webman/modules/authenticate.cgi` (returns the DSM account of the calling browser session) |
| privilege | `conf/privilege` `"tool"` entry → the server binary is installed setuid root, everything else runs as the package user |
| transport | `conf/resource` `web-config/nginx-static-config` → DSM nginx mounts `/synoterm/` → `127.0.0.1:7381`, with WebSocket upgrade headers |
| desktop integration | `dsmuidir` + `ui/config` + a small Vue wrapper that opens an iframe in a DSM window |

All four are **verified** to be supported (see dsm-integration.md). The SSH
loopback design from the original brief remains available as an optional
provider (M6) but is not the default: it requires the SSH service, exposes
password handling to the frontend, and conflicts with 2FA-enforced accounts.

---

## 2. Milestones

### M0 — Walking skeleton ✅ (this repository)

Goal: prove the risky parts end-to-end on a normal Linux box.

* [x] Zig project (`build.zig`, Zig 0.17, static musl targets)
* [x] Minimal HTTP/1.1 server (static files, path traversal guard, MIME map)
* [x] RFC 6455 server: handshake (`Sec-WebSocket-Accept`), framing, masking,
      fragmentation, ping/pong/close, payload cap
* [x] PTY: `/dev/ptmx` + `fork` + `setsid` + `TIOCSCTTY` + `TIOCSWINSZ`
* [x] Session: setgroups/setgid/setuid, login-shell `argv[0]`, env
* [x] Thread-per-connection bridge with a futex-backed write lock
* [x] xterm.js frontend: tabs, fit addon, resize, reconnect, status bar
* [x] Dev auth mode (`--auth dev`), same-origin check, base-path mounting
* [x] DSM package skeleton + `build-spk.sh` producing a real `.spk`
* [x] Unit tests + headless-browser e2e (`tools/e2e.mjs`)

Acceptance: `zig build test` green; e2e asserts terminal echo in Chromium;
`build/synoterm-*.spk` contains `INFO`, `package.tgz`, `scripts/`, `conf/`.

### M1 — Runs on DSM (1–2 days)

* [ ] Install the x86_64 SPK on Virtual DSM **7.1** (primary target), then 7.2
* [ ] Verify the `.url` registration: menu icon opens the terminal window
* [ ] Verify `ui/web/config.js` is honoured (WS goes to `/synoterm/ws`)
* [x] `--auth dsm` cookie-only probe on DSM 7.1.1-42962: **rejected** — a token
      is required (`cookie + token` works), so the `.url` build discovers the
      token from the same-origin DSM desktop (see dsm-integration.md §5.3)
* [ ] If cookie-only fails: build with `SYNOTERM_UI_STYLE=vue` and re-test
* [ ] Verify group gating with a non-admin DSM account (403 / hidden icon)
* [ ] Verify the nginx mount: `/synoterm/ws` upgrades over HTTPS
* [ ] Verify the setuid tool privilege: `ls -l target/bin/synoterm` → `4750 root package`
* [ ] Verify shell identity: `id`, `whoami`, `pwd` inside the terminal
* [ ] Verify start/stop/upgrade/uninstall leave nothing behind

Acceptance: terminal usable from the DSM desktop on HTTPS on **7.1**, as an
administrator account, with no extra open port.

### M2 — Robustness and UX (3–5 days)

* [ ] Per-user session cap (currently one global cap of 8)
* [ ] Idle timeout (`--idle-timeout`) and max session age
* [ ] `{"type":"exit","code":n}` and clean tab state when the shell exits
* [ ] Copy/paste: Ctrl+Shift+V, right-click paste, bracketed paste
* [ ] `Ctrl+Shift+T/W`, tab renaming, `Ctrl+Shift+F` search (xterm search addon)
* [ ] Font size shortcuts, "reset terminal", DSM-style theme
* [ ] Logging: structured, no terminal content, rotation in `$SYNOPKG_PKGVAR`
* [ ] i18n scaffolding for the wrapper strings (EN/DE at minimum)

Acceptance: dropping the network for 30 s reconnects with a **fresh** shell and
a clear "session ended" marker; `zig build test` covers the reconnect state
machine and the session accounting.

### M3 — Privilege and hardening (1 week)

* [ ] Split the binary: a small privileged spawner (root, only speaks a
      length-prefixed protocol over a socketpair, only creates PTYs) and the
      network process, which **drops to the package user** after binding
* [ ] Require the `SynoToken` subprotocol in DSM mode (not just the cookie)
* [ ] Refuse to start if euid is root but the spawner handshake failed
* [ ] Audit log (user, session id, open/close, peer IP) in `$SYNOPKG_PKGVAR`
* [ ] `--allow-users` / `--deny-users` allowlist, group policy in `conf`
* [ ] Rate limiting per peer, connection cap, `SO_RCVTIMEO` on the WS
* [ ] Reject non-local accounts with an explicit message (v1 decision; no
      `getent`/NSS path)
* [ ] Make the "no DSM token" case explicit in the UI instead of a bare 401

Acceptance: `ps` shows the network process as the package user; `strace`-level
review shows the privileged child does nothing but `openpty`/`fork`/`setuid`.

### M4 — Release engineering (2–3 days)

* [ ] CI: `zig build test`, frontend build, e2e, 3-arch cross-build, SPK
      artifacts, checksums
* [ ] Reproducible `package.tgz` (sorted entries, fixed mtimes, owner 0:0)
* [ ] Upgrade test 0.1.0 → 0.2.0 on a live NAS, nginx snippet reload
* [ ] Publish instructions (Package Center trust level, DSM 7.1 vs 7.2 support
      matrix, per-arch model list)
* [ ] Signing: **deferred** — document the trust-level workaround for dev builds
      and leave the signing pipeline for a later release
* [ ] Screenshots, changelog, troubleshooting section

### M5 — Optional / post-1.0 (backlog)

**Persistent sessions** (the `libghostty-vt` design in
[libghostty-vt.md](libghostty-vt.md)) are deferred until after v1: v1 explicitly
kills the shell when the socket closes, so there is no session state to keep.
When persistence is added it ships as an opt-in `--persist` mode with
detach/attach, a session list, and server-side scrollback search.

* [ ] `--persist`: keep sessions alive across socket loss (needs
      `libghostty-vt`; behind a build flag)
* [ ] `--provider ssh`: PTY running `/usr/bin/ssh -tt 127.0.0.1` (the original
      design) for setups where the setuid tool is unacceptable
* [ ] `--provider localpty`: no auth, single user, for kiosk/lab use
* [ ] File upload/download by dragging files into the terminal (chunked base64
      over the WS, written by the unprivileged side)
* [ ] Split panes, mobile layout
* [ ] 2FA-aware flow (if `authenticate.cgi` cannot represent 2FA sessions)
* [ ] AD/LDAP account support (resolve home/shell through `getent`), if ever needed

---

## 3. Verified DSM facts that shape the design

Details and file contents: [dsm-integration.md](dsm-integration.md).

1. **Package layout.** `INFO` + `package.tgz` + `scripts/` + `conf/` (+ icons)
   in the `.spk`; `dsmuidir="ui"` points at a directory *inside* `package.tgz`
   that DSM symlinks to `/usr/syno/synoman/webman/3rdparty/<pkg>/`.
2. **Privileges.** `conf/privilege` with `"run-as": "package"` plus a `tool`
   entry (`user: root`, `permission: 4750`) is how a package gets one setuid
   helper without running as root. Everything else stays unprivileged.
3. **Web transport.** `conf/resource` → `web-config` → `nginx-static-config`
   mounts `/synoterm/` inside DSM's nginx — but that is an **internal worker**,
   which DSM 7 only allows for Synology-signed packages (verified on a DS218+:
   error 320 `non-synology-signed package should not use internal worker`). The
   default build therefore ships **no** `conf/resource`: DSM serves the UI from
   `ui/web` and the terminal listens on its own port, with the DSM cookie
   reaching it because cookies are host-scoped. `SYNOTERM_NGINX_MOUNT=1` keeps
   the mount for signed builds.
4. **Desktop app.** Two documented registrations exist: `.url` with
   `type: "url"` + a relative `url` (used by default here, 7.x-safe) and the
   7.2 Vue form where `ui/config` maps a JS file to a class
   (`SYNO.SDS.App.Synoterm.Instance`) with `type: "app"`, `appWindow`, and the
   class is built from `SYNO.namespace` + `Vue.extend` +
   `<v-app-instance>`/`<v-app-window>`.
5. **Session identity.** `/usr/syno/synoman/webman/modules/authenticate.cgi`
   prints the authenticated account when invoked with the browser's cookie and
   `HTTP_X_SYNO_TOKEN`; DSM appends `?SynoToken=…` to third-party app script
   URLs, and browsers cannot set headers on a WebSocket, so the token travels
   as the `Sec-WebSocket-Protocol` value (RFC 6455 subprotocol).
6. **Group checks** must use DSM's `id -Gn <user>` (NSS), because a statically
   linked binary only sees `/etc/passwd` and `/etc/group`.

## 4. Decisions (ADR summary)

| # | Decision | Rationale | Reversal cost |
| --- | --- | --- | --- |
| D1 | Zig over Go/Node | single static binary per arch, no runtime, cross-compiles with `zig build -Dtarget=…`, direct PTY control | high |
| D2 | No SSH in the default path | no second credential, no SSH service dependency, 2FA/LDAP friendly, real `login`-equivalent semantics | low (M6 keeps SSH as a provider) |
| D3 | Setuid `tool` for one binary | only way to fork a PTY as another user while the package itself is unprivileged; DSM-sanctioned mechanism | medium |
| D4 | xterm.js, not a server-rendered terminal | best emulation/UX, tiny integration surface, offline bundle | low |
| D5 | iframe isolation for the UI | DSM's Vue/ExtJS globals, CSS resets and upgrade leftovers cannot break xterm; wrapper stays ~60 lines of ES5 | low |
| D6 | Hand-rolled HTTP + WebSocket | ~600 lines, no dependency churn; Zig 0.17 removed `std.ArrayList.init`, `std.Thread.Mutex`, `dupeZ`, `**`, `@cImport` — fewer deps means fewer breakages | low (swap for `http.zig` later if needed) |
| D7 | Raw syscalls + libc `extern`s in `sys.zig` | isolates the entire OS/toolchain surface in one file; `std.Io` is still moving | none (by design) |
| D8 | Static musl, per-arch SPKs | runs on any DSM 7.1+ regardless of glibc; no toolchain on the NAS | low |
| D9 | `libghostty-vt` for server-side VT state (M3) | correct reflow/scrollback/reattach without reimplementing a VT parser; MIT, Zig-native, needs exactly the Zig version we use | medium (fallback: raw ring buffer) |
| D10 | Admin-only by default (`allUsers: false`, group `administrators`) | a terminal is root-adjacent; opt-in for other users later | none |
| D11 | Default to the documented `.url` desktop registration (7.1-safe); Vue wrapper only with `SYNOTERM_UI_STYLE=vue` | 7.1 is the target floor and the `.url` form is documented for 7.x; the Vue `<v-app-window>` path is only proven on 7.2 | low (config + one JS file) |
| D12 | Sessions die with the WebSocket (no detach, no server-side VT) | simplest, safest, matches "terminal = a window you close"; removes the biggest dependency from v1 | medium (M5 adds `--persist`) |
| D13 | Local DSM accounts only; non-admin and domain accounts refused | avoids an unverifiable NSS path and keeps the privileged surface small | low |

## 5. Risk register

| Risk | Impact | Likelihood | Mitigation |
| --- | --- | --- | --- |
| Zig 0.17 is a moving target (APIs already removed: `std.Io` rework, `@cImport`, `std.Thread.Mutex`, `ArrayList.init`) | build breaks on toolchain bump | high | pin `.zigversion`; all churn confined to `sys.zig`/`util.zig`; CI pins the toolchain |
| `authenticate.cgi` behaviour differs across 7.1/7.2, or ignores `X-Syno-Token` | auth fails or is CSRF-weak | medium | M1 verification matrix; fallback to `SYNO.API.Auth` session check against `127.0.0.1:5000`; M4 requires the token |
| 7.1 vs 7.2 desktop registration differs | app does not open, or opens without a `SynoToken` | medium | default to the documented `.url` form (D11); Vue wrapper is a build option; token discovery in the UI falls back to the same-origin parent frame and the token cookie |
| `authenticate.cgi` needs the token, and `.url` style cannot inject one | 401 on 7.1 | medium | cookie-only path is implemented; M1 verifies it; fallback = Vue/ExtJS wrapper that receives `?SynoToken=` |
| nginx `web-config` disabled by a DSM update | no WebSocket path | low | server serves the UI itself on the loopback port; document manual reverse-proxy setup as escape hatch |
| Setuid helper compromised via a parsing bug | full root on the NAS | medium | tiny privileged surface, no shell invocation, fixed-format handshake, no env trust, M4 split; audit |
| `libghostty-vt` needs a newer Zig / fails on musl-aarch64 | future `--persist` blocked | low (deferred) | not on the v1 critical path (D12); spike before committing to `--persist` |
| WebSocket hijacking (no CORS on WS) | session theft | medium | same-origin check on `Origin` vs `Host`; DSM token subprotocol; loopback-only bind |
| Orphaned shells / fd leaks | resource exhaustion | medium | one session per socket, SIGHUP to the process group, `waitpid`, bounded sessions, GC in M3 |
| Terminal output in logs | secret leakage | low | no content logging by design; `access_log off` in nginx |

## 6. Decisions taken for v1

Answered by the project owner (recorded here so the plan and the code cannot
drift apart):

| Question | Decision | Consequence in the code |
| --- | --- | --- |
| Minimum DSM version | **7.1** | `os_min_ver="7.1-42661"`; default UI registration is the documented `.url` form |
| AD/LDAP accounts | **refuse** | `/etc/passwd` lookup only; explicit 403 "not a local DSM user" |
| Session lifetime | **kill on disconnect** | SIGHUP on socket close; no session registry; `libghostty-vt` deferred |
| Who may use it | **administrators only** | `allUsers: false` + `require_group = "administrators"` |
| Signing | **later** | unsigned dev builds; trust-level instructions documented |

Remaining minor questions (not blocking M1):

1. Should the 7.2 `SYNOTERM_UI_STYLE=vue` build be published alongside the 7.1
   default, or only built on request?
2. Shell default per account: `/bin/sh`, or `bash` when present?
3. Session cap per user (currently one global cap of 8) — per-user limit worth
   adding in M2?

## 7. Testing strategy

| Layer | Tool | What it proves |
| --- | --- | --- |
| Unit | `zig build test` | WS handshake vector (RFC 6455 example), frame parsing, origin matching, control JSON, request parsing |
| Protocol | `tools/ws-test.mjs` (ws client) | end-to-end bridge: ready frame, prompt, echo, resize |
| UI | `tools/e2e.mjs` (playwright-core + system Chromium) | the bundle boots, the socket connects, keystrokes reach a real shell, output renders |
| Package | `tools/verify-spk.sh` | SPK structure, INFO fields, setuid relpath present, no stray files, deterministic tarball |
| Device | checklist in dsm-integration.md | install/upgrade/uninstall, HTTPS, nginx upgrade, authenticate.cgi, privilege file |

CI runs the first four on every push; the device checklist runs manually
(and, once available, against a Virtual DSM snapshot in a nightly job).

## 8. Definition of done (v1.0)

* Installs and uninstalls cleanly on DSM 7.1 and 7.2, x86_64 and armv8
* Opens from the DSM menu, in a DSM window, over HTTPS, with no extra port
* Authenticates via the DSM session; admins only by default
* Multiple tabs, correct resize, reconnect after network loss
* Sessions end cleanly with the socket (v1 policy); no orphaned shells
* Privileged surface reviewed; network process unprivileged (M3)
* Docs: install, security model, troubleshooting, upgrade notes
