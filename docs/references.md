# References

Checked while writing the plan; keep this list updated when DSM or the
toolchain changes.

## Synology

* Package Developer Guide (index) — <https://help.synology.com/developer-guide/>
  * INFO, necessary fields — `synology_package/INFO_necessary_fields.html`
  * INFO, optional fields — `synology_package/INFO_optional_fields.html`
  * package.tgz / UI files — `synology_package/package_tgz/package_tgz.html`,
    `synology_package/package_tgz/launch_app.html`
  * scripts / env vars — `synology_package/scripts.html`,
    `synology_package/script_env_var.html`
  * conf / privilege — `synology_package/conf.html`,
    `privilege/privilege_config.html`
  * resource: web service — `resource_acquisition/web_service.html`
  * resource: port config — `resource_acquisition/port_config.html`
  * Desktop application — `integrate_dsm/desktopapp.html`
  * Application config (`ui/config`, `.url`) — `integrate_dsm/config.html`
  * Application authentication — `integrate_dsm/web_authentication.html`
  * Pack stage — `toolkit/pack_stage.html`
  * Guide release notes — `release_notes.html`, `breaking_changes.html`
    (guide's DeployVersion at the time of writing: **7.2**)

* DSM documentation, install/troubleshooting:
  * Manual install with Package Center —
    <https://kb.synology.com/en-global/DSM/tutorial/How_to_install_applications_with_Package_Center>

## Reference implementation (DSM 7.2, shipping)

* DiskShell — native multi-tab terminal `.spk` (Go + xterm.js) —
  <https://github.com/dei79/disk-shell>
  Files that informed this design:
  * `INFO.template` (`os_min_ver="7.2-72806"`, `dsmuidir`, `dsmappname`,
    `extractsize`, `instuninst_restart_services="nginx.service"`)
  * `conf/privilege` (`run-as: package` + `tool` setuid 4750)
  * `conf/resource` (`web-config` → `nginx-static-config`)
  * `payload/nginx/diskshell.conf` (loopback proxy + WS upgrade headers)
  * `payload/ui/config` (`type: "app"`, `appWindow`, `icon: images/icon_{0}.png`)
  * `native/main.go` (`authenticate.cgi` invocation, `X-Syno-Token`
    subprotocol, same-origin check, session limits)
  * `build.mjs` (package.tgz layout, icons, `extractsize`, unsigned SPK)

## Synology-related community knowledge

* SynoForum: opening `.spk` packages / DSM 7 layout —
  <https://www.synoforum.com/threads/how-to-open-spk-for-dsm-7-0.5261/>
* SynoForum: DiskShell announcement —
  <https://www.synoforum.com/threads/diskshell-native-multi-tab-terminal-for-synology-dsm.16299/>
* SynoCommunity spksrc (packaging conventions, `spksrc.spk.mk`) —
  <https://github.com/SynoCommunity/spksrc>

## Zig

* Zig language / std source, pinned version **0.17.0**
* Notable 0.17 changes this project works around (all isolated in
  `src/sys.zig` and `src/util.zig`):
  * `std.ArrayList` is unmanaged (`.empty`, methods take an allocator)
  * `std.Thread.Mutex` / `std.Io.Mutex` replaced by `std.Io.Mutex` (needs `Io`)
  * `Allocator.dupeZ` → `dupeSentinel` / `Allocator.printSentinel`
  * `std.fmt.allocPrintZ` / `bufPrintZ` removed
  * array repetition `**` removed (use `@splat`)
  * `@cImport` removed (use `b.addTranslateC` or `extern` declarations)
  * `std.mem.trimRight` → `trimEnd`; `std.net` → `std.Io.net`
  * `std.posix` no longer exposes `fork`/`execve`/`setuid`/`waitpid`
    (use `std.os.linux` + libc externs)

## libghostty-vt

* Repository: <https://github.com/ghostty-org/ghostty> (tag `v1.4.0`)
* Headers: `include/ghostty/vt.h`, `include/ghostty/vt/{terminal,formatter,
  screen,search,selection,types}.h`
* Build: `-Demit-lib-vt=true`; `src/build/GhosttyLibVt.zig`
* Examples: `example/c-vt-stream/`, `example/zig-vt/`,
  `example/c-vt-cmake-cross/`
* `build.zig.zon` → `minimum_zig_version = "0.17.0"`
* Licence: MIT

### Items to confirm on first integration

* Exact artifact name for the static library (`ghostty-vt` vs
  `ghostty-vt-static`) when consumed as a `lazyDependency`.
* Whether `translate-c` on `include/ghostty/vt.h` needs the
  `GHOSTTY_STATIC`/`GHOSTTY_SHARED` define set for our link mode.
* Cross-build results for `aarch64-linux-musl` and `arm-linux-musleabihf`.

## Frontend

* xterm.js — <https://xtermjs.org> (`@xterm/xterm` 6.x,
  `@xterm/addon-fit`, `@xterm/addon-web-links`)
* esbuild — <https://esbuild.github.io>
* RFC 6455 (WebSocket) — <https://www.rfc-editor.org/rfc/rfc6455>
