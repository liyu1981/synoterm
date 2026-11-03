# History and design decisions

This document collects background that used to live in the README.

## Why this shape

- **No SSH required.** The original sketch for a DSM web terminal proxies to
  `127.0.0.1:22`. That needs SSH enabled, a password typed into the browser,
  and it breaks for 2FA/LDAP accounts. Instead, the backend asks DSM who the
  browser session belongs to (`authenticate.cgi`) and forks a PTY **as that
  user** — the same thing DSM's own terminal tooling does.
- **No internal worker.** DSM 7 only lets Synology-signed packages use the
  framework's internal workers, and the nginx mount is one of them. The package
  therefore ships the snippet as a file and a root helper applies it once.
  Cookies are host-scoped, not port-scoped, so the same DSM session also
  authenticates the direct (`nas:7381`) transport: the mount is about HTTPS and
  same-origin convenience, not about auth.
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
| DSM session auth (`authenticate.cgi` + group check) | **working on DSM 7.1.1** |
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
