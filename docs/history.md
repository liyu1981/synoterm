# History and design decisions

This document collects background that used to live in the README.

## Why this shape

- **Two auth modes, ssh by default.** The first design asked DSM who the browser
  session belongs to (`authenticate.cgi`) and forked a PTY **as that user** —
  no SSH, no password. It works, but it depends on scraping a `SynoToken` out of
  the DSM desktop and on `authenticate.cgi`'s undocumented exit codes, which
  changed between DSM builds and failed on a real NAS (`exit 5` with a token the
  page had just scraped). The default is now the opposite trade: the terminal
  runs `ssh -l <account> 127.0.0.1`, so DSM's own sshd asks for the password (or
  OTP) *inside xterm*. synoterm then never sees a credential, needs no DSM API,
  and does not need its setuid tool at all. The cost is that SSH must be
  enabled, and a new browser session starts with a prompt (`ControlPersist`
  reuses the login for later tabs). `AUTH="dsm"` keeps the old mode for anyone
  who would rather not enable SSH.
- **No internal worker.** DSM 7 only lets Synology-signed packages use the
  framework's internal workers, and the nginx mount is one of them. The package
  therefore ships the snippet as a file and a root helper applies it once — or,
  with no root shell at all, you create the same route as a DSM reverse-proxy
  rule on a port of its own. Both are transport only: in ssh mode nothing about
  the mount takes part in authentication.
- **One static binary.** Zig cross-compiles to `x86_64`/`aarch64`/`armv7`
  **static musl** binaries; libc is embedded, so the binary does not depend on
  DSM's glibc (7.1 ships 2.26, while a native build needs 2.36+). No Node.js, no
  Python, no runtime dependencies on the NAS.
- **Appearance that fits your eyes.** Font family, size and line height are
  adjustable from the `Aa` button on the right of the header (persisted per
  browser) or from the URL:
  `?fontFamily=Fira+Code&fontSize=16&lineHeight=1.4`.
- **Normal clipboard behaviour.** `Ctrl/Cmd+V` pastes (also `Ctrl+Shift+V` and
  `Shift+Insert`), `Ctrl/Cmd+C` copies a selection — and only sends `^C` when
  nothing is selected — and pasting works even when focus is on the DSM window
  chrome rather than the terminal.
- **Small surface, explicit lifecycle.** xterm.js renders, the backend owns the
  real PTY, and a session ends when its socket ends (v1 policy). Persistent
  sessions via `libghostty-vt` are designed and deliberately deferred.

## Status

| Piece | State |
| --- | --- |
| Zig backend (HTTP, WebSocket, PTY bridge, resize) | working, unit tested |
| xterm.js frontend (tabs, reconnect, fit, status bar, font settings) | working, e2e tested in headless Chromium |
| DSM package (`INFO`, `conf/privilege`, ExtJS app window, contrib helpers) | **installed and running on a DS218+ / DSM 7.1.1** |
| SSH login mode (`ssh -l <account> 127.0.0.1`, no setuid) | implemented, unit + e2e tested |
| DSM session mode (`authenticate.cgi` + group check) | working on DSM 7.1.1; fragile across builds (see above) |
| Reverse-proxy deployment (own port, `BASE_PATH=""`) | implemented, documented in dsm-integration §4.3 |
| DSM window survives nginx regeneration (`PROXY_HTTPS_PORT`) | implemented, e2e tested (dsm-integration §4.3a) |
| Multi-arch SPK build (`tools/build-spk.sh`) | working (x86_64 verified, armv8/armv7 cross-compiled) |
| v1 policy: DSM 7.1 floor, admins only, local accounts only, kill on disconnect | implemented |
| Service config (`$SYNOPKG_PKGVAR/etc/synoterm.conf`) | implemented |
| Persistent sessions / reattach (`libghostty-vt`) | deferred |

Full roadmap: [docs/PLAN.md](../docs/PLAN.md).

## Releasing

Pushing a version tag builds every architecture and publishes a GitHub Release:

```sh
git tag -a v0.1.3 -m "synoterm 0.1.3"
git push origin v0.1.3
```
