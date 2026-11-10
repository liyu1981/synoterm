# contrib — the one manual step

DSM 7 refuses to let an unsigned package use its package framework's internal
workers, and the same-origin nginx mount (`/synoterm/`) is one of them:

```
error 320: non-synology-signed package should not use internal worker
```

So the mount is applied **by you, once, as root**, instead of by the package:

```sh
# on the NAS (root shell or sudo)
sudo /var/packages/synoterm/target/contrib/install-nginx-mount.sh
```

That writes the snippet to `/etc/nginx/conf.d/dsm.synoterm.conf` — DSM's own
apps and packages keep their per-vhost `location` conf there, and every
`server { }` block that serves the desktop loads
`include conf.d/dsm.*.conf;`. Naming the file `dsm.synoterm.conf` is what makes
one copy cover the `:5000` HTTP *and* the `:5001` HTTPS vhost, so this is a
single root run with no `nginx.conf` edit.

It decides from `nginx -T` (the effective configuration), not from
`nginx.conf` alone: only `include` lines that the server blocks listening on the
DSM ports really load are used, so a snippet in an http-level or Web Station
directory is never mistaken for a working mount. A copy that `nginx -t` rejects
(duplicate `location`, or a context where a `location` is invalid) is removed
again and nginx's own error is printed.

Finally it reloads nginx and probes `/synoterm/healthz` on every `listen` port.
Any DSM vhost that still answers 404 is listed together with the include
patterns *its* server block loads — that list is what to look at if a DSM build
names things differently.

Without this step the package still works — DSM serves the UI from
`/webman/3rdparty/synoterm/web/` and the terminal talks to the NAS on port 7381
directly, at the same paths (`/synoterm/healthz`, `/synoterm/ws`); the UI
detects which origin is available and prefers the mount.

Undo:

```sh
sudo /var/packages/synoterm/target/contrib/uninstall-nginx-mount.sh
```
