#!/usr/bin/env bash
# Renders the GitHub release body for a tag.
#
#   tools/release-notes.sh v0.2.1            # notes for v0.2.1 (uses the repo)
#   tools/release-notes.sh v0.2.1 owner/repo
#
# "What's changed" comes from the commits between the previous tag and this one,
# so the notes are version-specific; the package/install/upgrade/troubleshooting
# sections below are static and must describe the *current* behaviour — the
# default auth mode, how the app is exposed, and what an upgrade changes.
# Used by .github/workflows/release.yml; render it locally before tagging:
#
#   tools/release-notes.sh v0.2.1 liyu1981/synoterm
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

Static musl binary — no Node.js or Python on the NAS. The terminal logs in over
SSH, so the SSH service must be enabled; synoterm itself needs no privileges.

## Install

| step | what to do |
| --- | --- |
| 1 | **Package Center → Manual Install** → the `.spk` for your NAS architecture |
| 2 | **Control Panel → Terminal & SNMP → Enable SSH service** |
| 3 | **Control Panel → Login Portal → Advanced → Reverse Proxy → Create**: source `HTTPS` / `<nas>` / `7171` / path `/`; destination `HTTP` / `localhost` / `7381` |
| 4 | open `https://<nas>:7171/`, type your DSM account, then the password at the terminal prompt |

Step 3 runs on DSM's own web server, so the rule is DSM-managed and survives DSM
and package upgrades (no root shell, no file in `/etc/nginx`). The app answers at
the proxy root only when `BASE_PATH=""` in
`/var/packages/synoterm/var/etc/synoterm.conf` (`synopkg restart synoterm` after
editing); keep the default `BASE_PATH="/synoterm"` and use path `/synoterm` on
the rule instead if you also want the DSM desktop entry (*main menu → Terminal*).

Alternative without a new port — as root, mount the same backend on DSM's
`:5001` vhost:

```sh
sudo /var/packages/synoterm/target/contrib/install-nginx-mount.sh
```

It validates with `nginx -t` and rolls the snippet back if nginx would reject it.
DSM 7 reserves the automatic version of that mechanism for Synology-signed
packages (`error 320, non-synology-signed package should not use internal
worker`), which is why it is a helper script.

## Upgrading

Install the new `.spk` over the old version. Settings in
`/var/packages/synoterm/var/etc/synoterm.conf` are preserved, **but** a file
written before 0.2.0 has no `AUTH=` line, so the service starts in the new
**ssh** mode:

- enable the SSH service (step 2) and log in as before, or
- add `AUTH="dsm"` to keep the old cookie + SynoToken mode. That mode needs a
  package built with `SYNOTERM_SETUID=1`, because the released build ships no
  setuid binary.

If you use the contrib mount, re-run it only when the helper reports that the
snippet changed.

## Troubleshooting

```sh
sudo /var/packages/synoterm/target/contrib/diagnose.sh
```

Reports the package state, the auth mode (`AUTH=ssh` needs port 22 and the ssh
client; `AUTH=dsm` the setuid bit), the bind address and listener, `…/healthz`
on loopback and LAN, the nginx snippet plus `nginx -t`, and the service log.
`…/healthz` also reports the mode (`"auth":"ssh"`), and in ssh mode the terminal
prints ssh's own error text ("Permission denied", "Connection refused").
BODY
