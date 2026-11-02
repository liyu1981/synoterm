# synoterm

A web terminal that lives inside the Synology DSM desktop: **xterm.js** in the
browser, a small **Zig** binary on the NAS, and a native `.spk` package that
plugs into DSM 7.1+ without opening a single extra firewall port.

```
 DSM desktop (https://nas:5001)
 ┌──────────────────────────────────────────────────────────────┐
 │  Terminal  window  (SYNO.SDS.App.Synoterm.Instance)          │
 │  ┌────────────────────────────────────────────────────────┐  │
 │  │  iframe → /webman/3rdparty/synoterm/web/index.html     │  │
 │  │  xterm.js  ⇄  wss://nas:5001/synoterm/ws               │  │
 │  └────────────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────┘
                    │ DSM nginx (conf/resource → web-config)
                    ▼
        127.0.0.1:7381  synoterm (Zig, setuid tool)
                    │  authenticate.cgi → DSM user
                    ▼
        /dev/ptmx ── fork ── setuid(user) ── exec /bin/bash
```

## Why this shape

* **No SSH required.** The original sketch for a DSM web terminal proxies to
  `127.0.0.1:22`. That needs SSH enabled, a password typed into the browser,
  and it breaks for 2FA/LDAP accounts. Instead, the backend asks DSM who the
  browser session belongs to (`authenticate.cgi`) and forks a PTY **as that
  user** — the same thing DSM's own terminal tooling does.
* **No extra port.** DSM's nginx proxies `/synoterm/` to the loopback
  listener, so the terminal is same-origin, TLS-terminated by DSM, and covered
  by DSM's firewall rules.
* **One static binary.** Zig cross-compiles to `x86_64`/`aarch64`/`armv7` musl
  binaries from any host. No Node.js, no Python, no runtime dependencies on the
  NAS.
* **Small surface, explicit lifecycle.** xterm.js renders, the backend owns the
  real PTY, and a session ends when its socket ends (v1 policy). Persistent
  sessions via `libghostty-vt` are designed and deliberately deferred.

## Status

| Piece | State |
| --- | --- |
| Zig backend (HTTP, WebSocket, PTY bridge, resize) | working, unit tested |
| xterm.js frontend (tabs, reconnect, fit, status bar) | working, e2e tested in headless Chromium |
| DSM package skeleton (`INFO`, `conf/privilege`, `conf/resource`, nginx, `ui/`) | written; both UI registration styles build |
| DSM session auth (`authenticate.cgi` + group check) | implemented, needs on-device verification |
| Multi-arch SPK build (`tools/build-spk.sh`) | working (x86_64 verified, armv8/armv7 cross-compiled) |
| v1 policy: DSM 7.1 floor, admins only, local accounts only, kill on disconnect | implemented |
| Persistent sessions / reattach (`libghostty-vt`) | deferred (v1 kills sessions on disconnect); design kept in docs |

The full roadmap, decisions, risks and open questions are in
**[docs/PLAN.md](docs/PLAN.md)**.

## Quick start (Linux/macOS, no NAS)

```sh
zig build -Doptimize=ReleaseSmall          # or: zig build
(cd frontend && npm install && npm run build)

./zig-out/bin/synoterm \
  --listen 8080 --auth dev --web-root frontend/dist
# open http://127.0.0.1:8080/
```

Dev mode trusts the caller and runs the shell as *you*. Never expose it.

Run the tests:

```sh
zig build test
node tools/e2e.mjs          # needs a Chromium; see the script header
```

## Build a DSM package

```sh
./tools/build-spk.sh x86_64 0.1.0-0001     # → build/synoterm-0.1.0-0001-x86_64.spk
./tools/build-spk.sh armv8  0.1.0-0001
./tools/build-spk.sh armv7  0.1.0-0001

# DSM 7.2 desktop framework (v-app-window) instead of the 7.1-safe .url style:
SYNOTERM_UI_STYLE=vue ./tools/build-spk.sh x86_64 0.1.0-0001
```

Default UI style is `url` (documented for 7.x, works on the 7.1 floor). Under
that style DSM injects no CSRF token, so the backend authenticates with the DSM
session cookie; if a 7.1 device turns out to require a token, build the `vue`
style (7.2) or add the ExtJS wrapper described in
[docs/dsm-integration.md](docs/dsm-integration.md#53-fallback-if-71-needs-a-token-extjs-wrapper).

Install on the NAS: **Package Center → Manual Install**. DSM 7 refuses
unsigned packages by default; set *Package Center → Settings → General →
Trust Level* to allow any publisher (see
[docs/dsm-integration.md](docs/dsm-integration.md#installing-an-unsigned-spk)).

## Repository layout

```
src/                     Zig backend
  main.zig               CLI, HTTP/WS routing, auth, session wiring
  ws.zig                 RFC 6455 handshake + frame codec
  http.zig               request parsing, static files, traversal protection
  session.zig            PTY spawn (setuid, groups, env) + output pump
  auth.zig               DSM authenticate.cgi bridge
  sys.zig                raw syscall layer (the only file tied to Linux/Zig internals)
  util.zig               allocator/list/mutex shims for Zig 0.17
frontend/                xterm.js UI (esbuild bundle, no framework)
packaging/dsm7/          DSM 7 package skeleton (INFO, conf, nginx, ui, scripts)
tools/                   build-spk.sh, verify-spk.sh, make-icons.py, dev.sh,
                         e2e.mjs, ws-test.mjs, nas-test.sh (interactive NAS run),
                         nas-preflight.sh, nas-auth-test.sh, nas-uninstall.sh
docs/                    plan, architecture, DSM integration, protocol, libghostty-vt
```

## Testing on a real NAS

One interactive script drives the whole thing over SSH and stops before every
step that changes DSM:

```sh
tools/nas-test.sh nas.local              # ssh user "admin"; asks for the DSM password
tools/nas-test.sh nas.local --dry-run    # show the plan, change nothing
tools/nas-test.sh nas.local --skip-install --yes    # read-only + smoke test only
```

It detects the DSM build/architecture, runs the preflight, logs in to DSM to
probe `authenticate.cgi` (cookie vs token), runs the binary from `/tmp` behind
an SSH tunnel so you can use the terminal in your browser, then installs the
right `.spk` for the detected arch and verifies it end to end through nginx,
TLS, DSM auth and the PTY. `tools/nas-uninstall.sh nas.local` rolls back.

Manual stages, expectations and rollback details:
[docs/dsm-integration.md §10](docs/dsm-integration.md#10-testing-on-a-real-production-nas).

## Documentation

* [docs/PLAN.md](docs/PLAN.md) — milestones, decisions, risks, open questions
* [docs/architecture.md](docs/architecture.md) — process/threading model, data flow
* [docs/dsm-integration.md](docs/dsm-integration.md) — every DSM file, verified against Synology's guide and a shipping DSM 7.2 package
* [docs/protocol.md](docs/protocol.md) — WebSocket protocol
* [docs/libghostty-vt.md](docs/libghostty-vt.md) — why/how we use Ghostty's VT library
* [docs/references.md](docs/references.md) — sources

## License

MIT. `libghostty-vt` (once linked) is MIT as well.
