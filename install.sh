#!/bin/bash
set -euo pipefail

PREFIX="/usr/local/bin"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd -P)"

die() {
  echo "error: $*" >&2
  exit 1
}

needs_sudo() {
  [[ -w "${PREFIX}" ]] && return 1
  return 0
}

run() {
  if needs_sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

abspath() {
  local path="$1"
  local dir
  dir="$(cd "$(dirname "${path}")" && pwd -P)"
  echo "${dir}/$(basename "${path}")"
}

resolve_link_target() {
  local link="$1"
  local target
  target="$(readlink "${link}")" || return 1
  if [[ "${target}" = /* ]]; then
    echo "${target}"
  else
    echo "$(cd "$(dirname "${link}")" && pwd -P)/${target}"
  fi
}

uninstall() {
  [[ -d "${PREFIX}" ]] || exit 0
  while IFS= read -r -d '' link; do
    local target
    target="$(resolve_link_target "${link}")" || continue
    case "${target}" in
      "${REPO_ROOT}/"*) ;;
      *) continue ;;
    esac
    run rm -f "${link}"
    echo "removed: ${link}"
  done < <(find "${PREFIX}" -maxdepth 1 -type l -print0)
}

install_all() {
  [[ -d "${REPO_ROOT}/bin" ]] || die "missing ${REPO_ROOT}/bin"

  if [[ ! -d "${PREFIX}" ]]; then
    run mkdir -p "${PREFIX}"
  fi

  while IFS= read -r -d '' src; do
    local src_abs base cmd dest
    src_abs="$(abspath "${src}")"
    base="$(basename "${src_abs}")"
    cmd="${base%.sh}"
    dest="${PREFIX}/${cmd}"

    if [[ -e "${dest}" && ! -L "${dest}" ]]; then
      echo "skip (not a symlink): ${dest}"
      continue
    fi

    if [[ -L "${dest}" ]]; then
      local existing
      existing="$(resolve_link_target "${dest}")" || existing=""
      if [[ "${existing}" == "${src_abs}" ]]; then
        continue
      fi
      run ln -sfn "${src_abs}" "${dest}"
      echo "updated: ${dest} -> ${src_abs}"
    else
      run ln -s "${src_abs}" "${dest}"
      echo "installed: ${dest} -> ${src_abs}"
    fi
  done < <(
    find "${REPO_ROOT}/bin" \
      -type f \
      -perm -111 \
      ! -name '.*' \
      ! -path '*/.*' \
      -print0
  )
}

case "${1:-}" in
  --uninstall) uninstall ;;
  "" ) install_all ;;
  * ) die "usage: ./install.sh [--uninstall]" ;;
esac
