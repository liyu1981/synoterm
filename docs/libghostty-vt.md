# `libghostty-vt` — evaluation and integration plan

> **Status: evaluated, deferred (post-1.0).**
>
> v1 deliberately kills the shell when the WebSocket closes (decision D12), so
> there is no server-side session state to maintain and nothing for
> `libghostty-vt` to do. This document is the design for the future opt-in
> `--persist` mode (detach/attach, session list, scrollback search); it is kept
> because it is the only sane way to add persistence later.
>
> **Short version for that future work.** Use it for the *terminal state*, not
> for the PTY. PTY handling is ~80 lines of syscalls and stays in
> `src/session.zig`. `libghostty-vt` is what makes detached sessions, correct
> reflow on reattach, and server-side scrollback search possible without
> writing a VT emulator. Plan it behind a compile-time switch (`-Dvt`), with a
> ring-buffer fallback if the dependency proves unbuildable on a target.

## 1. What it is

`libghostty-vt` is the terminal-emulation core of [Ghostty](https://ghostty.org)
exposed as a C library, MIT-licensed, in the `ghostty-org/ghostty` repository:

```
include/ghostty/vt.h            umbrella header
include/ghostty/vt/terminal.h   terminal_new / resize / vt_write / get / set
include/ghostty/vt/formatter.h  format to VT / plain text / HTML
include/ghostty/vt/screen.h     screen/grid inspection
include/ghostty/vt/search.h     scrollback search
include/ghostty/vt/selection.h  selection model
include/ghostty/vt/render.h     render state (not needed for a browser UI)
include/ghostty/vt/*.h          colors, modes, mouse, kitty graphics, …
```

Facts verified against tag `v1.4.0` (October 2025):

| Fact | Value |
| --- | --- |
| Minimum Zig | `0.17.0` (`build.zig.zon` → `minimum_zig_version`) — matches this project |
| Build flag | `-Demit-lib-vt=true` (`Config.emit_lib_vt`) |
| Artifacts | shared + **static** `libghostty-vt.a`, a pkg-config file, CMake examples |
| Cross-compilation | supported (CMake cross example ships in `example/c-vt-cmake-cross`) |
| Language of the lib | pure Zig (+ optional SIMD); no C++/Rust |
| Licences | MIT |

The C API is small and ownership is explicit:

```c
GhosttyTerminal term;
ghostty_terminal_new(NULL, &term, 120, 40);          // allocator, ptr, cols, rows
ghostty_terminal_vt_write(term, bytes, len);         // feed PTY output
ghostty_terminal_resize(term, cols, rows, ...);      // reflow

GhosttyFormatterTerminalOptions opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
opts.emit = GHOSTTY_FORMATTER_FORMAT_VT;             // or PLANE / HTML
GhosttyFormatter f;
ghostty_formatter_terminal_new(NULL, &f, term, opts);
uint8_t *buf; size_t len;
ghostty_formatter_format_alloc(f, NULL, &buf, &len); // replayable VT stream
ghostty_free(NULL, buf, len);
ghostty_formatter_free(f);
ghostty_terminal_free(term);
```

## 2. What it does **not** do

`libghostty-vt` contains no PTY management and no I/O. Ghostty's own PTY/termio
layer (`src/termio/`) is application-internal and is not part of the library.
So the user-facing suggestion "use libghostty for PTY maintaining" splits into:

| Job | Where it lives in synoterm |
| --- | --- |
| open `/dev/ptmx`, `fork`, `setsid`, `TIOCSCTTY`, `TIOCSWINSZ`, `setuid` | `src/session.zig` (already written, no dependency) |
| track cursor/grid/scrollback/modes, reflow on resize, replay a screen | `libghostty-vt` (only for `--persist`) |
| render pixels | xterm.js in the browser (already written) |

Keeping those separate is a feature: the PTY path stays a few dozen syscalls,
and the VT dependency can be compiled out (`-Dvt=false`) for a minimal build.

## 3. Why we want it (if we add persistence)

Without VT state, the only ways to reattach a session are:

1. keep the raw byte log and replay everything (terminal reparses it — works for
   short sessions, explodes for a day of `htop`, and ignores resizes),
2. run `tmux`/`screen` inside the PTY (great, but a *user-space dependency* that
   not every NAS has; SynoCommunity's `tmux` is a separate package),
3. keep the browser tab open forever (not how a DSM window behaves).

With VT state we get, for one dependency:

* **Reattach to a live session** (`vim`, `htop`, `irssi`) with the exact screen,
  cursor, modes (alternate screen, bracketed paste, mouse reporting) — replay
  `GHOSTTY_FORMATTER_FORMAT_VT` and continue streaming.
* **Correct reflow** when the DSM window is resized while nobody is attached
  (`ghostty_terminal_resize` on the server side, not just `TIOCSWINSZ`).
* **Server-side scrollback search** (`search.h`) for `Ctrl+Shift+F`, including
  history the browser never received.
* **Plain-text snapshot** for the session list preview, and HTML export later.
* **A robust parse of dangerous output** — the same parser the Ghostty project
  ships and fuzzes, rather than our own.

## 4. Integration design

### 4.1 Build

`build.zig.zon`:

```zig
.dependencies = .{
    .ghostty = .{
        .url = "https://github.com/ghostty-org/ghostty/archive/<commit>.tar.gz",
        .hash = "…",
        .lazy = true,               // only fetched when -Dvt=true
    },
},
```

`build.zig`:

```zig
const vt = b.option(bool, "vt", "link libghostty-vt for persistent sessions") orelse true;
if (vt) {
    const dep = b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
    }) orelse return;                    // lazy dependency unavailable
    const exe = b.addExecutable(...);
    exe.root_module.linkLibrary(dep.artifact("ghostty-vt"));
    exe.root_module.addCMacro("SYNOTERM_VT", "1");
}
```

* The example in Ghostty's repo uses `dep.artifact("ghostty-vt")`; the build
  script also renames the static archive to `libghostty-vt.a` when installed.
  Confirm the exact artifact name (`ghostty-vt` vs `ghostty-vt-static`) on the
  first build and record it in `docs/references.md`.
* Reproducible/offline release builds **must vendor** the tarball
  (`build.zig.zon` URL + hash is enough for CI; for a fully offline release,
  keep `vendor/ghostty-<commit>.tar.gz` and use a path dependency).
* CI must prove: `x86_64-linux-musl`, `aarch64-linux-musl`,
  `arm-linux-musleabihf` all link with `-Dvt=true`.
* Expected size increase: a few hundred KiB per binary; measure and record.

### 4.2 Zig-side wrapper

A single file, `src/vt.zig`, is the only place that knows the C API:

```zig
pub const Terminal = struct {
    handle: c.GhosttyTerminal,
    pub fn init(cols: u16, rows: u16) !Terminal
    pub fn deinit(self: *Terminal) void
    pub fn write(self: *Terminal, bytes: []const u8) void
    pub fn resize(self: *Terminal, cols: u16, rows: u16) void
    pub fn snapshotVt(self: *Terminal, allocator) ![]u8          // formatter
    pub fn snapshotPlain(self: *Terminal, allocator) ![]u8
    pub fn search(self: *Terminal, needle: []const u8) ![]Match
};
```

Bindings: Zig 0.17 removed `@cImport`, so use
`b.addTranslateC(...)` on `include/ghostty/vt.h` (the library ships an umbrella
header and `module.modulemap`) and import the generated module. Alternative:
hand-written `extern` declarations for the ~15 functions we use — smaller and
immune to header churn, at the cost of maintaining struct layouts (the
`GHOSTTY_INIT_SIZED` option structs are versioned, so prefer translate-c).

### 4.3 Session manager changes

```
struct Session {
    pty: Pty,                      // master fd + child pid
    vt: vt.Terminal,                // server-side screen state
    attached: ?*Link,               // current websocket, if any
    backlog: RingBuffer(u8),        // bytes produced while attaching
    mutex: util.Mutex,              // guards vt + backlog + attached
};
```

Output path (thread `pty.read`):

```
read(master) ──▶ vt.write(bytes)          (under session lock)
             └─▶ attached?.sendBinary(bytes)   (under link lock, never blocking pty)
             └─▶ backlog.write(bytes)  when attached == null
```

Attach path (WS upgrade):

```
1. lock session
2. vt.snapshotVt()            → send as "snapshot" + binary frames
3. flush backlog              → keeps the vt/live streams consistent
4. attached = link; unlock
5. resume live forwarding
```

Detach path (socket close): `attached = null`, do **not** SIGHUP. Session stays
until `--detach-ttl` expires or the user closes it from the session list.

Resize: `ioctl(TIOCSWINSZ)` **and** `vt.resize(cols, rows)` so the snapshot
matches any future reattach.

Important: the VT write must never be on the same thread as a blocking socket
write, otherwise a slow browser stalls the shell. The pump thread writes to the
VT and appends to the link's own queue; the link flushes.

### 4.4 Frontend changes

* Handle `{"type":"snapshot", "cols":.., "rows":..}` → `term.resize(cols, rows)`
  then write the following binary frames.
* Session list panel (`GET /synoterm/sessions`, `DELETE …?id=`), reuse the same
  auth path as the WS upgrade.
* Search box → `/synoterm/sessions/<id>/search?q=…` → highlight matches by
  feeding decoded coordinates into xterm.js selections.

## 5. Alternatives considered

| Option | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| **`libghostty-vt`** (this) | correct VT, reflow, search, MIT, Zig, small C API | new(ish) library, Zig-version coupling, extra build dep | **chosen for `--persist`** |
| Raw byte ring buffer | zero deps, trivial | no reflow, unbounded growth for full-screen apps, reparse cost | fallback for `--persist` (also the `-Dvt=false` path) |
| `tmux` inside the PTY | battle-tested persistence, real detach | extra package on the NAS, second config surface, still needs replay for "screen" | recommended alongside, not instead |
| xterm.js `SerializeAddon` | client-side state | dies with the browser tab; no server search | not applicable |
| Write our own VT parser | no deps | months of work, guaranteed bugs | no |

## 6. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Ghostty requires a newer Zig than our pinned version | pin both; the M0 code is already isolated from `std.Io`, so bumping Zig is cheap; vendored CI toolchain |
| musl/aarch64/armv7 cross-build fails | spike on all three targets before committing to the design; fallback `-Dvt=false` or the ring buffer |
| Binary size / memory per session grows | measure; VT state is ~ (cols×rows + scrollback) cells — cap scrollback (`--scrollback-lines`) |
| C ABI churn between ghostty 1.x releases | pin a tag, use `addTranslateC`, run the ABI schema test in CI, upgrade deliberately |
| Bugs in the VT layer crash the package | the VT write path is per-session; isolate with a session thread and a panic handler that kills only that session |
| Build-time network fetch in release builds | vendor the tarball for releases; CI caches it |

## 7. Task list when `--persist` is picked up

1. Spike: cross-build `libghostty-vt` for the three targets; record artifact
   names, sizes, build flags.
2. `src/vt.zig` wrapper + unit tests (write "hello", resize, snapshot contains
   the text; alternate-screen round trip).
3. Session manager: detach/attach, backlog, TTL, session list.
4. Frontend: snapshot handling, session panel, search.
5. Soak test: 24 h `htop` session, 100 attach/detach cycles, memory plateau.
   Revisit the v1 decision (D12) with real usage data before flipping the
   default.
6. Documentation + `-Dvt=false` fallback verified.

## 8. References

* `include/ghostty/vt.h`, `include/ghostty/vt/terminal.h`,
  `include/ghostty/vt/formatter.h`, `include/ghostty/vt/types.h` (tag `v1.4.0`)
* `example/c-vt-stream/` and `example/zig-vt/` in the Ghostty repository
* `src/build/GhosttyLibVt.zig` (`initStatic`, `initShared`, install rules)
* `build.zig.zon` → `minimum_zig_version = "0.17.0"`
