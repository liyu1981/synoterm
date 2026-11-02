# DSM 7 integration reference

Everything here was checked against Synology's *Package Developer Guide*
(DeployVersion 7.2) and/or a shipping DSM 7.2 package. Items that still need
on-device confirmation are marked **to verify**. Sources:
[references.md](references.md).

The files described here already exist under [`packaging/dsm7/`](../packaging/dsm7)
and are assembled by [`tools/build-spk.sh`](../tools/build-spk.sh).

---

## 1. Package layout

```
synoterm-0.1.0-0001-x86_64.spk (tar, not gzip)
├── INFO                     metadata (key="value" lines)
├── package.tgz              payload, unpacked to /var/packages/synoterm/target
│   ├── bin/synoterm         the Zig binary (installed setuid by conf/privilege)
│   ├── nginx/synoterm.conf  nginx snippet mounted by conf/resource
│   └── ui/                  dsmuidir → /usr/syno/synoman/webman/3rdparty/synoterm/
│       ├── config           desktop app registration
│       ├── Synoterm.js      Vue wrapper class (window + iframe)
│       ├── images/icon_*.png
│       └── web/             xterm.js bundle (served statically by DSM)
├── scripts/                 lifecycle scripts (must be 0755)
│   ├── preinst postinst preuninst postuninst preupgrade postupgrade
│   └── start-stop-status
├── conf/
│   ├── privilege            run-as + setuid tool
│   └── resource             nginx web-config
├── LICENSE
└── PACKAGE_ICON.PNG, PACKAGE_ICON_256.PNG
```

Paths DSM gives a package at runtime:

| Variable | Value |
| --- | --- |
| `$SYNOPKG_PKGDEST` | `/var/packages/synoterm/target` (symlink into `@appstore`) |
| `$SYNOPKG_PKGVAR` | `/var/packages/synoterm/var` (writable, package-owned) |
| `$SYNOPKG_PKGNAME` | `synoterm` |
| static UI mount | `/usr/syno/synoman/webman/3rdparty/synoterm` → `target/ui` |

## 2. `INFO`

DSM 7 requires `os_min_ver` ≥ `7.0-40000`; we target `7.1-42661`. The fields we
set and why:

| Field | Value | Why |
| --- | --- | --- |
| `package` | `synoterm` | identity; also the `/var/packages/<id>` name. No `: / > < \| =` characters. |
| `version` | `0.1.0-0001` | `[feature]-[build]`; build must increase every release. |
| `os_min_ver` | `7.1-42661` | DSM 7.1 floor (see the open question about 7.2-only UI APIs). |
| `arch` | `x86_64` / `armv8` / `armv7` | one SPK per architecture (simplest, avoids model-matrix mistakes). |
| `thirdparty` | `yes` | marks the package as non-Synology. |
| `dsmuidir` | `ui` | directory inside `package.tgz` that DSM symlinks into `webman/3rdparty`. |
| `dsmappname` | `SYNO.SDS.App.Synoterm.Instance` | which app class the Package Center "Open" button launches. |
| `extractsize` | KiB of the payload | shown by Package Center (computed by the build script). |
| `startable` / `ctl_stop` | `yes` | Package Center may start/stop; `start-stop-status stop` must work. |
| `silent_install` / `silent_upgrade` | `yes` | no wizard needed. |
| `instuninst_restart_services` | `nginx.service` | reload nginx so the mount takes effect immediately. |

Notes:

* `maintainer`, `distributor`, `support_url` are placeholders in
  `packaging/dsm7/INFO.template`; override with `SYNOTERM_*` env vars.
* **to verify:** whether DSM 7.1 accepts the Vue-based `ui/config` app style
  (DiskShell declares `os_min_ver="7.2-72806"`). If not, emit the documented
  `type: "url"` variant for 7.1 builds.

## 3. `conf/privilege` — run unprivileged, spawn privileged

```json
{
  "defaults": { "run-as": "package" },
  "username": "synoterm",
  "groupname": "synoterm",
  "tool": [
    { "relpath": "bin/synoterm", "user": "root", "group": "package", "permission": "4750" }
  ]
}
```

* `run-as: package` → lifecycle scripts and the service run as the package user.
* `tool` → DSM installs `bin/synoterm` owner `root`, group `package`, mode
  `4750`. That is the *only* privileged artifact, and it exists so the process
  can `fork` → `setgid`/`setuid` → `exec` a shell as the authenticated user.
* The privilege file is applied at install/upgrade time — **to verify** that an
  upgrade re-applies mode 4750 and that the binary keeps working after
  `synopkg upgrade`.

Do **not** set `"run-as": "root"`: it would give the whole package root, which
is unnecessary and vastly increases the blast radius.

## 4. `conf/resource` — nginx mount (the WebSocket path)

```json
{
  "web-config": {
    "nginx-static-config": {
      "enable": [
        {
          "type": "dsm",
          "relpath": "nginx/synoterm.conf",
          "ports": [{ "port": 7381, "protocol": "tcp", "schema": "http" }],
          "alias": ["synoterm"]
        }
      ]
    }
  }
}
```

DSM copies the snippet into its nginx configuration and reloads nginx; the
snippet's own `location ^~ /synoterm/` block does the proxying:

```nginx
location ^~ /synoterm/ {
    access_log off;
    proxy_pass http://127.0.0.1:7381;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
}
```

Why this matters:

* **Same origin** (`https://nas:5001/synoterm/…`) → no mixed-content block on
  `wss://`, no CORS, cookies and the DSM token are sent automatically.
* **No firewall change**: only `127.0.0.1:7381` is bound.
* `proxy_buffering off` is what makes keystroke round-trips feel local;
  `proxy_read_timeout` keeps idle terminals alive.
* **to verify:** the exact `web-config` schema on DSM 7.1 (documented for
  Web Station "web service" resources; DiskShell ships this form on 7.2).

Escape hatch if a DSM update breaks the mount: expose the loopback port through
*Control Panel → Login Portal → Advanced → Reverse Proxy* with
`https://nas:5001/synoterm → http://127.0.0.1:7381`.

## 5. `ui/` — desktop application

Two registrations are supported. The build picks one with
`SYNOTERM_UI_STYLE` (default `url`):

| Style | Files | DSM versions | `SynoToken` |
| --- | --- | --- | --- |
| `url` (default) | `ui/config.url` → `ui/config` | documented for 7.x, safe for the **7.1 floor** | not injected; the UI falls back to cookie-only auth |
| `vue` | `ui/config.vue` + `ui/Synoterm.js` | DSM **7.2+** desktop framework | DSM appends `?SynoToken=` to the wrapper script, which forwards it |

### 5.1 `url` style (default, 7.1-safe)

`ui/config`:

```json
{
  ".url": {
    "SYNO.SDS.Synoterm.Instance": {
      "type": "url",
      "title": "Terminal",
      "desc": "An interactive, multi-tab terminal for DSM.",
      "icon": "images/icon_{0}.png",
      "url": "webman/3rdparty/synoterm/web/index.html",
      "allUsers": false
    }
  }
}
```

* `type: "url"` + a relative `url` is the form documented in Synology's
  *Application Config* page, which has existed since DSM 6 and is therefore the
  lowest-risk choice for a 7.1 floor.
* `allUsers: false` → administrators only (matches the v1 policy).
* Nothing is injected into the page URL, so the frontend discovers the
  WebSocket endpoint from `ui/web/config.js` (written at packaging time) and
  tries, in order, `?SynoToken=`, the same-origin parent DSM frame, and the
  token cookie. If no token is available the backend authenticates with the
  cookie alone.
* **to verify (M1):** whether `authenticate.cgi` accepts cookie-only requests on
  7.1. If it does not, use the `vue` style (7.2) or an ExtJS wrapper for 7.1
  (see 5.3).

### 5.2 `vue` style (DSM 7.2+)

`ui/config`:

```json
{
  "Synoterm.js": {
    "SYNO.SDS.App.Synoterm.Instance": {
      "type": "app",
      "title": "Terminal",
      "appWindow": "SYNO.SDS.App.Synoterm.Instance",
      "allUsers": false,
      "allowMultiInstance": false,
      "hidden": false,
      "icon": "images/icon_{0}.png",
      "depend": []
    }
  }
}
```

`ui/Synoterm.js` defines the class with DSM's Vue globals and hosts the terminal
in an **iframe** so DSM's CSS/JS never touches xterm.js:

```js
SYNO.namespace("SYNO.SDS.App.Synoterm");
SYNO.SDS.App.Synoterm.Instance = Vue.extend({
  template: [
    '<v-app-instance class-name="SYNO.SDS.App.Synoterm.Instance">',
    '  <v-app-window width="1040" height="680" :resizable="true"',
    '                syno-id="SYNO.SDS.App.Synoterm.Window">',
    '    <iframe :src="frameSrc" style="width:100%;height:100%;border:0"></iframe>',
    '  </v-app-window>',
    '</v-app-instance>',
  ].join(""),
});
```

The iframe URL carries `ws=/synoterm/ws` and `SynoToken=…` (read from the
wrapper script's own `src`, where DSM appends it).

### 5.3 Fallback if 7.1 needs a token: ExtJS wrapper

If M1 shows that cookie-only auth is rejected on 7.1 *and* the `.url` style is
preferred over the 7.2 Vue framework, the third option is the classic ExtJS
class registration documented in Synology's *UI files* page
(`type: "app"` + `appWindow`, class defined with `Ext.define`, an iframe panel
inside a `SYNO.SDS._ThirdParty.App.BaseWindow`). It is not shipped today because
it cannot be verified without a 7.1 device; the two styles above cover both
ends of the range.

### Icons and runtime config

* `images/icon_{16,24,32,48,64,72,128,256}.png`, plus
  `PACKAGE_ICON.PNG` / `PACKAGE_ICON_256.PNG` at the SPK root.
* `ui/web/config.js` is generated by `tools/build-spk.sh`:

```js
window.SYNOTERM_CONFIG = { ws: "/synoterm/ws" };
```

Without it the bundle derives the WebSocket path from the page URL, which is
only correct when the UI is served from the same mount as the proxy.

## 6. Authentication: who is calling?

The backend must not trust the network path. Two layers:

1. **Same-origin check** — `Origin` must equal `Host` on the WebSocket upgrade
   (browsers do not apply CORS to WebSockets, so this is required).
2. **DSM session check** — run
   `/usr/syno/synoman/webman/modules/authenticate.cgi` with a CGI environment
   that mirrors the browser request:

```
REQUEST_METHOD=GET
GATEWAY_INTERFACE=CGI/1.1
PATH=/usr/syno/bin:/usr/bin:/bin
HTTP_COOKIE=<browser Cookie header>
HTTP_X_SYNO_TOKEN=<token from the WS subprotocol>
HTTP_HOST=<Host header>
REMOTE_ADDR=<peer address>
```

`authenticate.cgi` prints the authenticated account name (empty on failure).
With the default `.url` UI style no `SynoToken` is available, so the request is
sent with the cookie only (`HTTP_X_SYNO_TOKEN=`); the server treats an empty
result as "not authenticated" and returns 401.

Policy in v1 (decided):

* **administrators only** — `require_group = "administrators"`, `allUsers: false`;
* **local DSM accounts only** — the account must exist in `/etc/passwd`
  (AD/LDAP accounts get an explicit 403 instead of a half-working shell);
* **no token, no session** — the WebSocket upgrade must carry a valid DSM
  session cookie; a bare `127.0.0.1` request from another local process is
  rejected because it has no cookie.

Then check group membership with DSM's own tooling:

```
/usr/bin/id -Gn <user>     # must contain "administrators" by default
```

Rationale for `id` instead of libc `getgrouplist`: the release binary is
statically linked against musl, which cannot use DSM's NSS modules. Calling
`id` inherits whatever NSS setup DSM has (including LDAP/AD).

The token cannot be sent as an HTTP header on a WebSocket, so it travels in the
`Sec-WebSocket-Protocol` value:

```
Sec-WebSocket-Protocol: synoterm.syno-token.<base64url(SynoToken)>
```

The server must echo the *selected* protocol back in the 101 response, which is
why `ws.acceptKey` and the handshake code return it.

**to verify (M1):** whether `authenticate.cgi` accepts cookie-only requests on
7.1. If it does not, the fallbacks are, in order: (a) the `vue` UI style, which
supplies the token; (b) an ExtJS wrapper for 7.1 (see 5.3); (c) `SYNO.API.Auth`
session validation over `http://127.0.0.1:5000` using the `id` cookie.

## 7. Lifecycle scripts

`start-stop-status` is the only one with real logic:

```sh
HOME="${SYNOPKG_PKGVAR}/home" nohup "${SYNOPKG_PKGDEST}/bin/synoterm" \
  --listen 7381 --auth dsm --base-path /synoterm \
  --web-root "${SYNOPKG_PKGDEST}/ui/web" \
  >>"${SYNOPKG_PKGVAR}/runtime/synoterm.log" 2>&1 &
```

* `status` must exit `0` when running and `3` when stopped (DSM convention).
* The pid file lives in `$SYNOPKG_PKGVAR/runtime` (writable).
* `postinst` creates `$SYNOPKG_PKGVAR/home` (the package user's `HOME`) and
  `runtime`, both `0700`.
* `stop` sends SIGTERM, waits up to 20 s, then SIGKILL.
* All scripts are `0755` and start with `#!/bin/sh` (DSM 7's `/bin/sh` is bash
  in POSIX mode; busybox-isms are avoided).

## 8. Installing an unsigned SPK

DSM 7 verifies package signatures by default. For an unsigned build:

1. **Package Center → Settings → General → Trust Level → "Synology Inc. and
   trusted publishers"** → change to allow any publisher (wording varies by
   DSM build).
2. **Package Center → Manual Install** → choose the `.spk` → accept the
   third-party warning.
3. If DSM reports `arch` mismatch, confirm the NAS architecture in
   *Control Panel → Info Center* (`x86_64`, `armv8`, `armv7`) and use the
   matching build.

## 9. Device verification checklist (M1)

```
[ ] spk installs on DSM 7.1; Package Center shows "Terminal" with the icon
[ ] menu icon opens the terminal (url style, default build)
[ ] ui/web assets load from /webman/3rdparty/synoterm/web/
[ ] ui/web/config.js points the socket at /synoterm/ws
[ ] /synoterm/ws upgrades (browser devtools: 101 Switching Protocols)
[ ] authenticate.cgi returns the logged-in admin account (cookie only)
[ ] if not: SYNOTERM_UI_STYLE=vue build works (DSM 7.2) and carries the token
[ ] ls -l /var/packages/synoterm/target/bin/synoterm  → -rwsr-x--- root package
[ ] inside terminal: id / whoami / pwd / echo $HOME are the DSM user
[ ] resize the DSM window → xterm reflows, `stty size` matches
[ ] stop package → shells receive SIGHUP; start → works again
[ ] non-admin account: icon hidden and WS rejected with 403
[ ] domain/LDAP account: rejected with 403, no shell spawned
[ ] upgrade 0.1.0 → 0.2.0 keeps config, restarts nginx mount
[ ] uninstall removes /var/packages/synoterm and the nginx snippet
[ ] no terminal traffic in /var/log/nginx/access.log
```

## 10. Testing on a real (production) NAS

Yes — a real DSM 7.1 box is the best test target. The whole sequence below is
automated, interactively, by:

```sh
tools/nas-test.sh nas.local
```

It prints every remote command as `+ …` (passwords, cookies and tokens are
redacted), explains in one or two lines what each step is for, stops before the
smoke test and before the install, and never uninstalls unless you pass
`--uninstall`. `--trace` adds `set -x`/remote `sh -x` output, `--log <file>`
writes a shareable transcript, `--quiet` silences the command trace. The manual stages
are kept here as the reference for what it does and for troubleshooting.

Do it in four stages so the risky step is last and reversible. Nothing in
stages 0–2 writes to DSM's config.

### Stage 0 — read-only preflight

```sh
scp tools/nas-preflight.sh admin@nas:/tmp/
ssh admin@nas 'sudo sh /tmp/nas-preflight.sh'
```

Checks DSM build vs `os_min_ver`, architecture, `authenticate.cgi` usability,
port 7381, `synopkg`, and whether an old install exists. If the build is older
than 42661, rebuild with `SYNOTERM_OS_MIN_VER=<major>.<minor>-<build>`.

### Stage 1 — answer the cookie/token question (no changes)

Log in to the DSM desktop, copy the `id` cookie from DevTools
(Application → Cookies → `https://<nas>:5001`), then:

```sh
scp tools/nas-auth-test.sh admin@nas:/tmp/
ssh admin@nas "sudo sh /tmp/nas-auth-test.sh 'id=<value>; stay_login=0' '<SynoToken-if-present>'"
```

Outcome decides the UI style:

| Result | Action |
| --- | --- |
| `cookie only` prints the account | ship the default `.url` build |
| only `cookie + token` prints it | build `SYNOTERM_UI_STYLE=vue` (7.2) or add the ExtJS wrapper (§5.3) |
| both empty | re-copy the cookie with the desktop tab open; the session may have expired |

### Stage 2 — binary, PTY and browser, no package (reversible)

This validates the static musl binary, PTY spawning, `setuid`-based user
switching, and the frontend — without touching DSM's nginx or Package Center.

```sh
# on the laptop: build for the NAS architecture (uname -m there)
./tools/build-spk.sh "$(uname -m)" 0.0.0-probe >/dev/null   # just to get frontend/dist
# actually only the binary + bundle are needed:
scp zig-out/bin/synoterm admin@nas:/tmp/synoterm
scp -r frontend/dist admin@nas:/tmp/synoterm-web

# on the NAS: run loopback-only, as root, in dev mode (trusts the caller)
ssh admin@nas 'sudo /tmp/synoterm --listen 7382 --auth dev --web-root /tmp/synoterm-web'

# on the laptop: forward the loopback port and open http://127.0.0.1:7382/
ssh -N -L 7382:127.0.0.1:7382 admin@nas
```

Expected: tabs, a root shell, resize works, `Ctrl+Shift+T` opens a second tab.
Ctrl-C the server when done; `/tmp` cleanup is `rm -f /tmp/synoterm*`.

If the terminal does not appear, check the binary's dynamic/static nature
(`ldd /tmp/synoterm` → "not a dynamic executable") and run it in the foreground
to see the log line.

### Stage 3 — the package (the only step that changes DSM)

Preconditions: you are an administrator, nobody else relies on the DSM web UI
for the next five minutes (the install reloads nginx), and you accept a **setuid
root helper** on the NAS for the duration of the test.

1. Package Center → Settings → General → Trust Level → allow any publisher.
2. Package Center → Manual Install → `synoterm-<ver>-<arch>.spk`.
3. Run the checklist in §9 above.

### Stage 4 — rollback

1. Package Center → synoterm → **Uninstall** (DSM removes the nginx snippet and
   the package directories; it also reloads nginx).
2. Verify:

```sh
grep -r synoterm /etc/nginx/ 2>/dev/null            # expect nothing
ls -d /var/packages/synoterm 2>/dev/null            # expect nothing
netstat -ltn | grep 7381                            # expect nothing
```

3. Revert the Package Center trust level to the stricter setting.

What to capture if something fails:

```sh
tail -n 200 /var/packages/synoterm/var/runtime/synoterm.log
tail -n 200 /var/log/nginx/error.log
ls -l /var/packages/synoterm/target/bin/synoterm     # expect -rwsr-x--- root package
/usr/syno/bin/synopkg status synoterm
grep -n synoterm /etc/nginx/conf.d/*.conf /etc/nginx/nginx.conf 2>/dev/null
```

Plus the browser's Network tab entry for `GET /synoterm/ws` (status code) and
the exact response body of a rejected upgrade.

### Notes for a live system

* 2FA/LDAP users: 2FA is fine (we reuse the existing session, no password is
  typed); domain accounts are refused by design in v1.
* Custom DSM ports (`:5000`/`:5001` changed) need no change: the origin check
  compares `Origin`'s host:port against the `Host` header, and nginx forwards
  `$http_host`.
* If DSM sits behind a reverse proxy with its own hostname, `$http_host` is that
  hostname and the check still matches.
* Uninstalling kills any open shells; warn other administrators first.

## 11. Gotchas worth remembering

* `tar` for the `.spk` is **uncompressed**; `package.tgz` inside is gzipped.
* Scripts must be executable *inside* the tarball (`chmod 755` before tarring).
* Any file you add to `ui/` is world-readable — never put state or secrets
  there.
* The nginx snippet is copied by DSM; editing it requires a package
  update/reinstall (or a manual nginx reload) to take effect.
* `$SYNOPKG_PKGVAR` is the *only* safe place to write at runtime.
* The `.url` style gives you no `SynoToken`; do not make the backend depend on
  one unless the UI style supplies it.
* `os_min_ver` must match `-Z` build number format (`7.1-42661`).
* Changing `conf/privilege`'s `tool` list requires a reinstall to re-apply
  permissions; check with `ls -l` after upgrading.
