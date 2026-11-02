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

That copies `nginx/synoterm.conf` into DSM's nginx include directory, runs
`nginx -t` (and rolls back if it fails), reloads nginx, and probes the backend.

Without this step the package still works — DSM serves the UI from
`/webman/3rdparty/synoterm/web/` and the terminal talks to the NAS on port 7381
directly; the UI detects which mode is available and prefers the mount.

Undo:

```sh
sudo /var/packages/synoterm/target/contrib/uninstall-nginx-mount.sh
```
