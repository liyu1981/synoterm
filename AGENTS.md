# AGENTS.md

Conventions for anyone (human or agent) working in this repository.

## Commit policy — strict

* **Never create a commit unless the user explicitly asks for it.** Working
  changes stay in the work tree until then.
* **One instruction allows at most one commit.** After it, go back to the
  waiting state: report what is committed, then wait for the next explicit ask.
  "Commit" once does not authorise later commits.
* If a change is finished but not committed: summarise it, run `git status`,
  and ask whether to commit. Do not commit "to be helpful".
* Never `amend`, `rebase`, `filter-branch`, force-push, or create/move/delete
  tags or branches unless that is itself explicitly requested. Rewriting
  published history additionally requires confirmation that no remote exists
  (this repo currently has no remote).
* Never commit:
  * build artefacts (`build/`, `zig-out/`, `frontend/dist/`, `node_modules/`,
    `.zig-cache/`) — they are gitignored, keep it that way;
  * secrets or transcripts containing credentials, cookies, tokens or
    passwords (`--log` files must be redacted before they are shared).
* Authorship is the user's configured identity (`Yu Li <liyu1981@gmail.com>`).
  Do **not** pass `-c user.name=…` / `-c user.email=…` overrides to `git
  commit`.

## Before asking for a commit

1. `zig build test` passes.
2. `node tools/e2e.mjs` passes (needs `npm install` at the repo root and a
   Chromium; the script prints why it skipped otherwise).
3. When packaging changed: `./tools/build-spk.sh x86_64 <version>` followed by
   `./tools/verify-spk.sh build/<file>.spk`.
4. `git status` shows only the intended changes.

## Commit messages

* Subject: imperative, `area: summary`, at most ~72 characters
  (`fix(ui):`, `feat(tools):`, `build:`, `docs:`, `test(spk):`).
* Body: the field symptom, the root cause, then the fix — the existing history
  is the template. Include what was verified and how.

## Project-specific rules worth remembering

* **The binary must stay static musl.** `zig build` defaults to
  `-target <arch>-linux-musl`; a glibc-linked build fails on DSM 7.1
  (`GLIBC_2.28 not found`). `verify-spk.sh` and CI enforce this.
* **Never write to `/tmp` on the NAS.** DSM's sshd may use `PrivateTmp`, and the
  sftp/scp subsystem can see a different view than the login shell. Use
  `$HOME/.synoterm-test` and stream files over the SSH exec channel
  (`tools/lib/nas-common.sh`).
* **A running synoterm keeps its old inode.** After replacing the binary, kill
  the process that owns the port, otherwise the old build keeps answering
  (missing `/status`, old token) — `nas-test.sh` does this by port pid.
* **Load xterm.js's stylesheet.** Without `@xterm/xterm/css/xterm.css` the font
  width-measurement container is painted and stray rows of characters appear.
* **Never log terminal content.** nginx `access_log off` for the mount; the
  service log records lifecycle events only.
