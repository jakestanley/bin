#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_DIR="$ROOT/config/macos/resolver"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Missing $SRC_DIR" >&2
  exit 1
fi

echo "Installing resolver files from: $SRC_DIR"
sudo mkdir -p /etc/resolver

resolver_files=()
resolver_domains=()
for f in "$SRC_DIR"/*; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f")"
  [[ "$name" == *.example ]] && continue
  resolver_files+=("$f")
  resolver_domains+=("$name")
done

if [[ ${#resolver_files[@]} -eq 0 ]]; then
  echo "No resolver files found in $SRC_DIR (excluding *.example)." >&2
  echo "Create local-only resolver files (gitignored) based on the *.example templates." >&2
  exit 1
fi

for f in "${resolver_files[@]}"; do
  name="$(basename "$f")"
  echo "-> /etc/resolver/$name"
  sudo install -m 0644 "$f" "/etc/resolver/$name"
done

echo "Done. Current scoped resolvers:"
domain_re="$(printf '%s\n' "${resolver_domains[@]}" | sed 's/[][\\\\.^$*+?()|{}]/\\\\&/g' | paste -sd'|' -)"
scutil --dns | grep -E -n "domain[[:space:]]+:[[:space:]]+(${domain_re})|nameserver\\[[01]\\]" || true
