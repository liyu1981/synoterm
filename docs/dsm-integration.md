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

## 4. Transport: ship the mount, apply it by hand

DSM 7 only lets **Synology-signed** packages use its *internal workers*, and
`conf/resource` is exactly that. Shipping the nginx mount in `conf/resource`
makes the package uninstallable:

```json
{"error":{"code":320,"description":"non-synology-signed package should not use internal worker"}}
```

So the package ships the mount **as files** and the mount is applied once, by
you, with root over SSH:

```sh
sudo /var/packages/synoterm/target/contrib/install-nginx-mount.sh
```

What that script does (`contrib/install-nginx-mount.sh`):

0. reads the **effective** configuration (`nginx -T`, which follows includes) and
   asks only the `server { }` blocks that listen on the DSM ports what they
   include — parsing `nginx.conf` alone misses server blocks that live in
   included files, and it cannot tell a server-level `include` from an
   http-level one, which is how a snippet ends up "installed" but never loaded;
1. writes the snippet to `/etc/nginx/conf.d/dsm.synoterm.conf` — DSM keeps the
   per-vhost `location` conf of its own apps there and every desktop
   `server { }` block loads `include conf.d/dsm.*.conf;`, so the `dsm.*.conf`
   pattern picks the file up in *both* the `:5000` HTTP and the `:5001` HTTPS
   vhost. It also installs into every other server-level include directory
   nginx.conf uses (`/usr/syno/share/nginx/conf.d/dsm.*.conf`, `www.*.conf`, …),
   skipping any copy that `nginx -t` rejects because the `location` would be a
   duplicate. Without a matching directory it writes
   `/etc/nginx/conf.d/dsm.synoterm.conf` and prints the include line for the
   manual step, naming the vhosts;
2. runs `nginx -t` and **removes the files again if nginx rejects it** — a
   broken snippet can never take the DSM UI down;
3. restarts nginx (`synosystemctl restart nginx`, with fallbacks);
4. probes `http://127.0.0.1:7381/synoterm/healthz` and `/synoterm/healthz` on
   **each `listen` port** (http and https), printing a line per vhost and
   exiting non-zero if a vhost that serves the DSM desktop (`/webman/`) still
   answers 404 — listing, for that vhost, the include patterns its server block
   *does* load. "Installed" and "works where the browser is" are different
   things; the script checks the second one, and a copy that `nginx -t` rejects
   (twice-included location, wrong context) is removed immediately with nginx's
   own error.

Undo: `sudo /var/packages/synoterm/target/contrib/uninstall-nginx-mount.sh`.

### 4.1 Both transports work, the UI picks one

```
mode "proxy"  (mount applied — preferred)
  https://nas:5001/synoterm/…            UI + WSS, same origin, cookies, no extra port
      └─ nginx location ^~ /synoterm/ → 127.0.0.1:7381

mode "direct" (no mount)
  http://nas:5000/webman/3rdparty/synoterm/web/   UI served by DSM's webman
      └─ http://nas:7381/synoterm/ws              own port; the DSM cookie is
                                                  sent anyway (host-scoped)
```

The **paths never change**, only the origin: `/synoterm/healthz`,
`/synoterm/status`, `/synoterm/ws` in both modes. `ui/web/config.js` carries
`{ proxy: "/synoterm", port: 7381, httpsPort: 5001 }`; the bundle probes
`<origin>/synoterm/healthz` once and caches the choice:

1. the origin that served the page (the normal case);
2. `https://<host>:<httpsPort>/synoterm/…` if the page is on plain HTTP — DSM is
   often opened on `:5000` while the mount only exists on the HTTPS vhost
   (reopen DSM over HTTPS in that case: browsers may withhold the session cookie
   from a cross-scheme request);
3. the package's own port, `/synoterm/ws` on `:7381`.

The current choice is visible in the browser console as `window.synotermBackend`.

Notes:

* `synoterm` runs with `--base-path /synoterm` and serves **only** that prefix;
  `/healthz` or `/ws` outside it answer 404, in every transport.
* **Direct mode is HTTP-only in practice.** If DSM is served over HTTPS, an
  `https://` page cannot open `ws://`, so apply the mount (or configure DSM's own
  reverse proxy, §4.2).
* **Direct mode needs the port reachable** from the browser: allow TCP 7381 in
  *Control Panel → Security → Firewall*.
* The mount avoids both problems: same origin, TLS by DSM, no extra port.

### 4.1b Token discovery (what the `.url`/ExtJS page does)

`authenticate.cgi` needs the session **cookie *and* the SynoToken** on DSM 7.1
(cookie only → exit 7, empty output, measured on 7.1.1-42962). The UI therefore
looks for the token, recording every source it tried in
`window.synotermTokenSources`:

1. `?SynoToken=` on the page URL (percent-encoded forms too),
2. the DSM desktop frame/opener/top: its **own `location.search`** (DSM redirects
   to `…/index.cgi?SynoToken=…` after login), globals (`SynoToken`, `_SynoToken`,
   `SYNO.SDS.Session.getSynoToken()`, `Ext.util.Cookies`), its cookies, and a
   scan of its DOM,
3. `fetch('/webman/index.cgi')` and `/webman/desktop/index.html`, same-origin,
4. the package's own `ui/auth-probe.cgi` (diagnostic, see below),
5. cookies visible to the page.

Every candidate the UI found is presented — `X-Syno-Token: t1,t2,…` on the
probe, one `synoterm.syno-token.<base64url>` subprotocol per candidate on the
upgrade — and the server tries them in order until `authenticate.cgi` accepts
one. That matters because a scrape can match the wrong `SynoToken=` in the
desktop markup; the UI also asks `auth-probe.cgi?token=…` what DSM says about
the first candidate and logs the answer (`exit N, user "…"`). The refusal now
names the exit status and the sizes instead of a canned "token was not
presented", and the cache is only dropped *after* reporting. If the token cannot be found the backend answers
`401 DSM rejected the session - the SynoToken was not presented`, and the UI says
`no DSM token presented`.

Every refusal is also written to `var/runtime/synoterm.log` as one line —
code, reason, path, peer, origin, and whether a cookie/token was presented
(never their values) — because a browser cannot show why a WebSocket handshake
failed. To see what DSM offers on a given build, open:

```
http://<nas>:5000/webman/3rdparty/synoterm/auth-probe.cgi
```

It reports `remote_user`, whether the request carried a token
(`syno_token_env_present`), `authenticate.cgi`'s exit status and the account it
returned — without printing any secret value. That output decides whether the
fallback (a CGI minting a short-lived, HMAC-signed identity for the backend)
is needed.

### 4.2 Same thing without the helper script

*Control Panel → Login Portal → Advanced → Reverse Proxy → Create*: source
`HTTPS`, host `nas`, port `5001`, path `/synoterm`; destination `HTTP`,
host `localhost`, port `7381`. That is DSM's own feature, no worker involved —
the shipped snippet and this rule are equivalent.

### 4b. For signed packages: automatic mount

```sh
SYNOTERM_NGINX_MOUNT=1 ./tools/build-spk.sh x86_64 0.1.0-1
```

That build adds `conf/resource` (DSM applies the mount itself through its
internal worker) and is only installable if the package is signed by Synology.

## 5. `ui/` — a real DSM window (ExtJS, 7.0/7.1)

Two registrations exist and they behave very differently:

| `ui/config` | what DSM does |
| --- | --- |
| `"type": "url"` + `"url": …` | opens a **browser window/tab** at that address (address bar visible) |
| `"type": "app"` + `"appWindow": "<class>"` | opens a **DSM desktop window**: title bar, minimise/maximise, resize, taskbar entry, remembered geometry |

On DSM 7.0/7.1 the desktop is ExtJS, so the window class is built from DSM's own
`SYNO.SDS.AppWindow`, and the entry point from `SYNO.SDS.AppInstance`:

```js
// ui/Synoterm.js — loaded by DSM because ui/config names it
Ext.ns("SYNO.SDS.App.Synoterm");

SYNO.SDS.App.Synoterm = Ext.extend(SYNO.SDS.AppWindow, {
  constructor: function () {
    SYNO.SDS.App.Synoterm.superclass.constructor.call(this, {
      width: 1000, height: 650, minWidth: 480, minHeight: 320,
      maximizable: true, resizable: true, layout: "fit",
      title: "Terminal",
      items: [{
        xtype: "panel", border: false, layout: "fit",
        html: '<iframe src="/webman/3rdparty/synoterm/web/index.html" ' +
              'style="display:block;width:100%;height:100%;border:0"></iframe>'
      }],
      listeners: { show: …, activate: …, destroy: …, scope: this }
    });
  },
  // clicks inside an iframe do not bubble: raise the window on mousedown
});

SYNO.SDS.App.Synoterm.Instance = Ext.extend(SYNO.SDS.AppInstance, {
  appWindowName: "SYNO.SDS.App.Synoterm"
});
```

`ui/config` then maps the file to the classes it defines:

```json
{ "Synoterm.js": {
    "SYNO.SDS.App.Synoterm.Instance": {
      "type": "app", "appWindow": "SYNO.SDS.App.Synoterm",
      "icon": "images/icon_{0}.png", "allUsers": false,
      "allowMultiInstance": true, "maxInstance": 4,
      "allowSharing": true, "allowStandalone": false,
      "depend": ["SYNO.SDS.App.Synoterm"] },
    "SYNO.SDS.App.Synoterm": { "type": "lib", "icon": "images/icon_{0}.png", "depend": [] }
} }
```

`INFO` needs `dsmuidir="ui"` and `dsmappname="SYNO.SDS.App.Synoterm.Instance"` to
match, which it does. `allowMultiInstance`/`maxInstance` give one DSM window per
terminal; `allowStandalone: false` keeps it out of a browser popup.

### 5.1 Why the window body is an iframe

Embedding xterm.js directly into the ExtJS panel is possible — the panel would
host a `<div>` and the bundle would mount into it from `afterrender` — but the
iframe buys three things and costs nothing measurable:

* **isolation** — xterm.js measures its own font metrics and ships its own CSS;
  DSM's ExtJS stylesheets and global font rules cannot disturb it, and a render
  problem cannot wedge the desktop;
* **lifecycle** — destroying the window destroys the frame, which closes the
  WebSocket, frees the PTY and every timer with it;
* **multi-instance** — each window gets its own JS context, so the terminal UI
  needs no per-window plumbing (it is written as a single-page app).

The frame is same-origin with DSM (`/webman/3rdparty/synoterm/web/`), so the
`SynoToken` is readable from the desktop page and the DSM cookie is sent to the
terminal's own port; keystrokes and output cross the boundary as the same
WebSocket frames, so there is no added latency.

Relative vs absolute: DSM resolves a relative `url` against the web root, so the
iframe `src` (and the `url` registration) must be absolute —
`/webman/3rdparty/synoterm/web/index.html`. `3rdparty/…` resolves to
`/3rdparty/…` and 404s (confirmed on 7.1.1).

### 5.2 Other flavours

`SYNOTERM_UI_STYLE` selects the registration at build time (default `extjs`):

| value | window | notes |
| --- | --- | --- |
| `extjs` | real DSM window (7.0/7.1) | **default**, target for 7.1 |
| `vue` | real DSM window (7.2+) | `<v-app-window>`; the 7.2 equivalent |
| `url` | browser window | diagnostic only; address bar visible |

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

> **DSM 7 blocks unsigned packages on the CLI, by design.** `synopkg install` is
> the *internal worker* and answers:
>
> ```json
> {"results":[{"action":"install","error":{"code":320,
>   "description":"non-synology-signed package should not use internal worker"}}],
>  "success":false}
> ```
>
> Package Center is the *external* worker and does allow unsigned packages, so
> the install has to go through the desktop UI (or a signed package). There is
> no supported CLI flag for this. `tools/nas-install.sh` recognises error 320 and
> prints the exact steps; afterwards run it with `--verify-only` to check the
> result (and to run the end-to-end probe with your DSM session).

DSM 7 verifies package signatures by default. For an unsigned build:

1. **Package Center → Settings → General → Trust Level → "Synology Inc. and
   trusted publishers"** → change to allow any publisher (wording varies by
   DSM build).
2. **Package Center → Manual Install** → choose the `.spk` → accept the
   third-party warning.
3. If DSM reports `arch` mismatch, confirm the NAS architecture in
   *Control Panel → Info Center* (`x86_64`, `armv8`, `armv7`) and use the
   matching build.
4. Verify what got installed, and probe the terminal end to end:

   ```sh
   tools/nas-install.sh 192.168.0.18 --user yli --verify-only
   ```

   That logs in, checks `synopkg status`, the setuid mode, the nginx mount,
   `/synoterm/healthz` and a real `wss://` connection with your session.

Uninstalling has the same worker restriction on some builds — use
*Package Center → Uninstall* if `synopkg uninstall` refuses.

## 9. Device verification checklist (M1)

```
[ ] spk installs on DSM 7.1; Package Center shows "Terminal" with the icon
[ ] menu icon opens the terminal (url style, default build)
[ ] ui/web assets load from /webman/3rdparty/synoterm/web/
[ ] ui/web/config.js carries `proxy: "/synoterm"`, `port`, `httpsPort`
[ ] /synoterm/ws upgrades (browser devtools: 101 Switching Protocols)
[ ] `X-Syno-Token` + cookie make authenticate.cgi return the account (`/synoterm/status` 200)
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

Yes — a real DSM 7.1 box is the best test target. Two scripts automate it:

```sh
tools/nas-install.sh nas.local --user <you>   # install + verify only
tools/nas-test.sh nas.local --user <you>      # full checklist (preflight, auth
                                              # probe, LAN smoke test, install)
```

Both are interactive, print every command (secrets redacted), and stop before
anything is changed. The rest of this section describes what they do.

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

### Troubleshooting the test run

| Symptom | Cause | Fix |
| --- | --- | --- |
| `scp: dest open "…": No such file or directory` right after a successful `mkdir` | the sftp/scp subsystem sees a different filesystem view than the login shell (PrivateTmp and friends) | `nas-test.sh` no longer uses scp: files are streamed over the SSH exec channel (`cat > file`) and the probes run inside one session. If the cross-session check still fails, use `--remote-dir <path on a normal volume>` |
| write test says "files written now are not visible to a later ssh session" | per-session mount view on this NAS | run the diagnostic the script prints, then `--remote-dir /volume1/homes/<user>/.synoterm-test` |
| password asked on every command | no SSH connection reuse | `nas-test.sh` sets `ControlMaster`/`ControlPersist`; one prompt per run |
| `cannot create … on the NAS` | `$HOME` is `/` or not writable (user home service disabled) | Control Panel → User & Group → Advanced → enable User Home, or `--user root` |
| probe says `cookie only -> <empty>` | DSM needs the `SynoToken` for this build | `--ui-style vue` (7.2) or the ExtJS wrapper (§5.3) |
| terminal answers **403** | account not in `administrators` | add the account to that group, or set `REQUIRE_GROUP=""` in `$SYNOPKG_PKGVAR/etc/synoterm.conf` and restart the package |

Two-line diagnostic if file copies misbehave (run from this machine):

```sh
ssh <user>@<nas> 'd="$HOME/.synoterm-test"; mkdir -p "$d" && echo hi > "$d/t" && ls -l "$d/t"'
ssh <user>@<nas> 'ls -l "$HOME/.synoterm-test/t"'      # ENOENT => per-session view
```

The service config lives in `$SYNOPKG_PKGVAR/etc/synoterm.conf` (created by
`postinst`, never overwritten on upgrade):

```sh
REQUIRE_GROUP="administrators"   # empty = any authenticated local account
MAX_SESSIONS="8"
EXTRA_ARGS=""                    # e.g. --idle-timeout 3600
```

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
ls -l /etc/nginx/conf.d/dsm.synoterm.conf      # the file the helper installs
grep -n 'conf.d/dsm\.\*' /etc/nginx/nginx.conf  # the include that loads it
```

A file called `/etc/nginx/conf.d/synoterm.conf` is **not** loaded: DSM's server
blocks include `conf.d/dsm.*.conf`, so the name has to start with `dsm.`. The
installer warns about such a leftover and suggests removing it.

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
* The smoke test serves a **dev** terminal on `0.0.0.0:7382` so you can open it
  from a different machine (`http://<nas>:7382/?t=<secret>`). It runs a shell as
  your SSH user without DSM authentication — the random `?t=` secret is the only
  guard, and the server is stopped at the end of the step. Use `--loopback` to
  bind 127.0.0.1 instead.
* **DSM kills background processes when the login session ends.** A
  `nohup … &` server started from an `ssh` command dies the moment that command
  returns (`systemd` `KillUserProcesses`, or the session's cgroup being torn
  down) — the listener disappears and `curl` then reports *connection refused*.
  That is why `nas-test.sh` starts the dev server in the **foreground of a
  dedicated SSH connection it keeps open** for the whole step. Manual
  equivalent, with the SSH window left open while you test:

  ```sh
  ssh <user>@<nas> '~/\.synoterm-test/synoterm --listen 7382 --bind 0.0.0.0 \
      --auth dev --dev-token s3cret --web-root ~/.synoterm-test/web'
  ```

  If you need it detached, use DSM's Task Scheduler ("Run command" as your
  user) rather than `nohup` over ssh.
* The UI says "server has no /status (old build…)" or the smoke probe returns
  `403 dev token missing` while the freshly copied file is on the NAS: an old
  synoterm process still owns the port (the new file is on disk, the old process
  keeps the old inode). `nas-test.sh` now kills the exact PID that owns the port
  and then picks a port that is really free; manually:
  `ssh <user>@<nas> "pkill -f 'synoterm --listen'"`
* Stray rows of repeated characters in the terminal (e.g. `$$$$$$$` or `----4444`)
  mean xterm.js's stylesheet is missing from the bundle — it hides the font
  width-measurement container. `tools/e2e.mjs` asserts this now.
* `connection refused` vs `timeout` when testing from the LAN tells you which
  problem you have: *refused* = nothing listening (the process died), *timeout*
  = DSM's firewall (Control Panel → Security → Firewall) is dropping the port.
* Standalone equivalent: `synoterm --listen 7382 --bind 0.0.0.0 --auth dev
  --dev-token <secret> --web-root <dir>`.

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
