#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local/bin}"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
TMP_INSTALL_LIST=""

cleanup() {
  if [[ -n "${TMP_INSTALL_LIST}" ]] && [[ -f "${TMP_INSTALL_LIST}" ]]; then
    rm -f "${TMP_INSTALL_LIST}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM HUP

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
  TMP_INSTALL_LIST="$(mktemp -t bin-install.XXXXXX)"

  if [[ ! -d "${PREFIX}" ]]; then
    run mkdir -p "${PREFIX}"
  fi

  while IFS= read -r -d '' src; do
    local src_abs base cmd
    src_abs="$(abspath "${src}")"
    base="$(basename "${src_abs}")"
    cmd="${base%.sh}"
    printf '%s\t%s\n' "${cmd}" "${src_abs}" >>"${TMP_INSTALL_LIST}"
  done < <(
    find "${REPO_ROOT}" \
      -mindepth 2 \
      -type f \
      -perm -111 \
      ! -name '.*' \
      ! -path '*/.*' \
      -print0
  )

  if [[ ! -s "${TMP_INSTALL_LIST}" ]]; then
    echo "no executables found under ${REPO_ROOT}/*/"
    return 0
  fi

  local dup
  dup="$(sort -t$'\t' -k1,1 "${TMP_INSTALL_LIST}" | awk -F $'\t' 'prev==$1 {print $1; exit 0} {prev=$1} END{exit 0}')"
  [[ -z "${dup}" ]] || die "duplicate command name detected: ${dup}"

  while IFS=$'\t' read -r cmd src_abs; do
    local dest
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
  done < <(sort -t$'\t' -k1,1 "${TMP_INSTALL_LIST}")

  rm -f "${TMP_INSTALL_LIST}"
  TMP_INSTALL_LIST=""
}

case "${1:-}" in
  --uninstall) uninstall ;;
  "" ) install_all ;;
  * ) die "usage: ./install.sh [--uninstall]" ;;
esac
