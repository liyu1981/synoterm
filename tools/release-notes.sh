#!/usr/bin/env bash
# Renders the GitHub release body for a tag.
#
#   tools/release-notes.sh v0.1.2            # notes for v0.1.2 (uses the repo)
#   tools/release-notes.sh v0.1.2 owner/repo
#
# "What's changed" comes from the commits between the previous tag and this one,
# so the notes are version-specific; the package/install/upgrade/troubleshooting
# sections are static. Used by .github/workflows/release.yml.
set -euo pipefail

tag="${1:?usage: release-notes.sh <tag> [owner/repo]}"
repo="${2:-${GITHUB_REPOSITORY:-}}"

# The previous tag reachable from the tagged commit (empty for the first release).
prev="$(git describe --tags --abbrev=0 "${tag}^" 2>/dev/null || true)"

if [ -n "${repo}" ]; then
  compare="https://github.com/${repo}/compare/${prev}...${tag}"
  prev_link="https://github.com/${repo}/releases/tag/${prev}"
else
  compare=""
  prev_link=""
fi

echo "## What's changed"
echo
if [ -n "${prev}" ]; then
  if [ -n "${compare}" ]; then
    echo "Since [\`${prev}\`](${prev_link}) — [full diff](${compare})."
  else
    echo "Since \`${prev}\`."
  fi
  echo
  git log --no-merges --pretty='- %s (%h)' "${prev}..${tag}"
else
  echo "First tagged release."
  echo
  git log --no-merges --pretty='- %s (%h)' "${tag}" | head -40
fi

cat <<'BODY'

## Package

| asset | notes |
| --- | --- |
| `synoterm-<version>-x86_64.spk` | Intel / AMD NAS (apollolake, geminilake, denverton, v1000, …) |
| `synoterm-<version>-armv8.spk` | aarch64 NAS (rtd1296, armada37xx, …) |
| `synoterm-<version>-armv7.spk` | 32-bit ARM NAS (armada38x, …) |
| `SHA256SUMS` | `sha256sum -c SHA256SUMS` |

Static musl binary — no Node.js, Python or SSH service needed on the NAS.

## Install

| step | what to do |
| --- | --- |
| 1 | **Package Center → Manual Install** → the `.spk` for your NAS architecture |
| 2 | **one-time, as root:** `sudo /var/packages/synoterm/target/contrib/install-nginx-mount.sh` |
| 3 | **DSM → main menu → Terminal** |

Step 2 mounts `/synoterm/` on DSM's own web server. DSM 7 reserves that mechanism
for Synology-signed packages (`error 320, non-synology-signed package should not
use internal worker`), so the package ships the snippet as a file and the helper
applies it from your root shell — validating with `nginx -t` and rolling back if
nginx would reject it. **Skipping step 2 is fine**: the app then works with the UI
served by DSM and the terminal on port 7381 of the NAS (allow TCP 7381 in
*Control Panel → Security → Firewall*).

## Upgrading

Install the new `.spk` over the old version — settings in
`/var/packages/synoterm/var/etc/synoterm.conf` are preserved. Re-run step 2 only if
the helper reports that the snippet changed.

## Troubleshooting

```sh
sudo /var/packages/synoterm/target/contrib/diagnose.sh
```

Reports package state, the setuid mode, the bind address and listener, `/synoterm/healthz`
on loopback and LAN, the nginx snippet and `nginx -t`, and the service log. The
terminal UI also names its transport (`window.synotermBackend` → `proxy` or
`direct`).
BODY
