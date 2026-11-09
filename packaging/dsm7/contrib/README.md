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

That copies `nginx/synoterm.conf` into **every** server-level include directory
DSM's nginx has (the `:5000` HTTP and `:5001` HTTPS vhosts are separate blocks —
a `location` included by only one of them 404s on the other), runs `nginx -t`
(and rolls back if it fails), reloads nginx, then probes
`/synoterm/healthz` on each `listen` port and names any vhost that still
answers 404.

Without this step the package still works — DSM serves the UI from
`/webman/3rdparty/synoterm/web/` and the terminal talks to the NAS on port 7381
directly, at the same paths (`/synoterm/healthz`, `/synoterm/ws`); the UI
detects which origin is available and prefers the mount.

Undo:

```sh
sudo /var/packages/synoterm/target/contrib/uninstall-nginx-mount.sh
```
