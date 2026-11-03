<img src="assets/icon.svg" width="88" align="right" alt="synoterm icon">

# synoterm

A terminal that opens **inside the Synology DSM desktop** as a real desktop
window: **xterm.js** renders it, a small **Zig** binary owns the PTY, and it
ships as a native `.spk` with no runtime dependencies on the NAS.

![synoterm demo](https://raw.githubusercontent.com/liyu1981/synoterm/master/assets/synoterm-demo.png)

## Features

- Real PTY with `/bin/bash` (or the logged-in user's shell)
- Multiple terminal windows, resize, scrollback
- xterm.js rendering with font/size/line-height settings
- Runs as the logged-in DSM user (DSM account integration)
- Static musl binary: x86_64, aarch64, armv7
- No runtime dependencies on the NAS

## Install

1. Download the `.spk` for your architecture from the
   [releases page](https://github.com/liyu1981/synoterm/releases).
2. In DSM: **Package Center → Manual Install**, select the `.spk`.
3. Open **SynoTerm** from the DSM desktop.

## High-level overview

```
DSM desktop (http://nas:5000)
  Terminal window (iframe)  ⇄  ws://nas:7381/ws  (or /synoterm/ws via nginx)
       xterm.js
                              │ DSM cookie + SynoToken
                              ▼
  synoterm (Zig, static musl) on 127.0.0.1:7381
                              │ authenticate.cgi → DSM user
                              ▼
  /dev/ptmx ── fork ── setuid(user) ── exec shell
```

## Develop

Prerequisites: Zig, Node.js, npm.

```sh
# frontend
cd frontend && npm install && npm run build

# backend
zig build
zig build test

# end-to-end
npm install   # repo root
node tools/e2e.mjs
```

Package a `.spk`:

```sh
./tools/build-spk.sh x86_64 <version>
./tools/verify-spk.sh build/<file>.spk
```

## License

See [LICENSE](LICENSE).
