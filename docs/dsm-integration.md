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

`ui/config` registers the app class:

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

`ui/Synoterm.js` defines that class with DSM's Vue globals and hosts the
terminal in an **iframe** so DSM's CSS/JS never touches xterm.js:

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

The iframe URL carries two parameters:

| Param | Source | Purpose |
| --- | --- | --- |
| `ws=/synoterm/ws` | hard-coded | tells the UI where the proxied endpoint lives (the UI is served from `/webman/3rdparty/…`, a different prefix) |
| `SynoToken=…` | DSM appends `?SynoToken=` to this script's own `src` | CSRF token forwarded to the backend |

Icons: `images/icon_{16,24,32,48,64,72,128,256}.png`, plus
`PACKAGE_ICON.PNG` / `PACKAGE_ICON_256.PNG` at the SPK root.

**to verify:** `allUsers: false` correctly limits the icon to the
`administrators` group on 7.1/7.2, and `allowMultiInstance: false` closes the
right kind of window.

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

**to verify:** whether `authenticate.cgi` accepts cookie-only requests on 7.1
(no token), and whether `HTTP_X_SYNO_TOKEN` alone is enough on 7.2. If neither
is reliable, fall back to `SYNO.API.Auth` over `http://127.0.0.1:5000` with the
`id` cookie.

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
[ ] spk installs; Package Center shows "Terminal" with the icon
[ ] menu icon opens a DSM window with the terminal iframe
[ ] ui/web assets load from /webman/3rdparty/synoterm/web/
[ ] /synoterm/ws upgrades (browser devtools: 101 Switching Protocols)
[ ] authenticate.cgi returns the logged-in admin account
[ ] ls -l /var/packages/synoterm/target/bin/synoterm  → -rwsr-x--- root package
[ ] inside terminal: id / whoami / pwd / echo $HOME are the DSM user
[ ] resize the DSM window → xterm reflows, `stty size` matches
[ ] stop package → shells receive SIGHUP; start → works again
[ ] non-admin account: icon hidden and/or WS rejected with 403
[ ] upgrade 0.1.0 → 0.2.0 keeps config, restarts nginx mount
[ ] uninstall removes /var/packages/synoterm and the nginx snippet
[ ] no terminal traffic in /var/log/nginx/access.log
```

## 10. Gotchas worth remembering

* `tar` for the `.spk` is **uncompressed**; `package.tgz` inside is gzipped.
* Scripts must be executable *inside* the tarball (`chmod 755` before tarring).
* Any file you add to `ui/` is world-readable — never put state or secrets
  there.
* The nginx snippet is copied by DSM; editing it requires a package
  update/reinstall (or a manual nginx reload) to take effect.
* `$SYNOPKG_PKGVAR` is the *only* safe place to write at runtime.
* `os_min_ver` must match `-Z` build number format (`7.1-42661`).
* Changing `conf/privilege`'s `tool` list requires a reinstall to re-apply
  permissions; check with `ls -l` after upgrading.
