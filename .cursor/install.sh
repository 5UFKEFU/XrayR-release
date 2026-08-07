#!/usr/bin/env bash
# Cloud Agent install step for XrayR-release.
#
# This repository is a collection of Bash/Python deployment scripts, systemd
# units, Docker assets and example configs for XrayR. There is no compiled
# project to build; "development" here means editing and validating shell
# scripts, the Python config generator and the JSON/YAML config files.
#
# The Cursor default base image already ships bash, python3, go, jq, yq and
# unzip. The only tools missing for a productive workflow are the shell
# linter/formatter, so this script installs them. It is idempotent: apt-get
# install is a no-op when the packages are already present.
set -euo pipefail

echo "==> XrayR-release environment install"

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
  fi

  # Only touch apt when a required tool is actually missing, so re-runs on a
  # warm/snapshotted VM stay fast.
  missing=()
  command -v shellcheck >/dev/null 2>&1 || missing+=(shellcheck)
  command -v shfmt >/dev/null 2>&1 || missing+=(shfmt)
  # unzip/jq are used to unpack and inspect the bundled release archives; keep
  # them guaranteed even if a future base image drops them.
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  command -v jq >/dev/null 2>&1 || missing+=(jq)

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "==> Installing: ${missing[*]}"
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq "${missing[@]}"
  else
    echo "==> All required apt packages already present"
  fi
else
  echo "!! apt-get not available; skipping system package installation" >&2
fi

echo "==> Tool versions:"
bash --version | head -1
python3 --version
shellcheck --version | awk '/^version:/{print "shellcheck " $2}'
shfmt --version | sed 's/^/shfmt /'
jq --version
if command -v go >/dev/null 2>&1; then go version; fi

echo "==> Sanity: syntax-checking repository shell scripts"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find "$repo_root" -name '*.sh' -not -path '*/.git/*' -print0)

echo "==> Sanity: byte-compiling the aobai-node config generator"
python3 -m py_compile "$repo_root/aobai-node/configure.py"

echo "==> install complete"
