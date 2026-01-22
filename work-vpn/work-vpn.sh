#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="${SCRIPT_DIR}/.env"

die() {
  echo "error: $*" >&2
  exit 1
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "${name} is required (see ${ENV_FILE}.example)"
}

require_array() {
  local name="$1"
  local decl=""
  if ! decl="$(declare -p "${name}" 2>/dev/null)"; then
    die "${name} is required (see ${ENV_FILE}.example)"
  fi
  [[ "${decl}" == declare\ -a* ]] || die "${name} must be a bash array (see ${ENV_FILE}.example)"

  eval "local len=\${#${name}[@]}"
  (( len > 0 )) || die "${name} must not be empty"
}

OC_PID=""
RESOLVER_FILE=""

cleanup() {
  set +e
  set +u

  # Stop VPN
  if [[ -n "${OC_PID}" ]] && kill -0 "${OC_PID}" 2>/dev/null; then
    kill "${OC_PID}" 2>/dev/null || true
    sleep 1
    kill -9 "${OC_PID}" 2>/dev/null || true
  fi

  # Remove scoped resolver
  if [[ -n "${RESOLVER_FILE}" ]] && [[ -f "${RESOLVER_FILE}" ]]; then
    sudo rm -f "${RESOLVER_FILE}" >/dev/null 2>&1 || true
  fi

  # Reset DNS to DHCP for both services
  if declare -p WORK_VPN_NETWORK_SERVICES >/dev/null 2>&1; then
    for svc in "${WORK_VPN_NETWORK_SERVICES[@]}"; do
      sudo networksetup -setdnsservers "$svc" empty >/dev/null 2>&1 || true
    done
  fi

  # Flush caches
  sudo dscacheutil -flushcache >/dev/null 2>&1 || true
  sudo killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM HUP

[[ -f "${ENV_FILE}" ]] || die "missing ${ENV_FILE} (copy ${ENV_FILE}.example to ${ENV_FILE} and edit)"

# shellcheck disable=SC1090
. "${ENV_FILE}"

require_var "WORK_VPN_ENDPOINT_URL"
require_var "WORK_VPN_CORP_DOMAIN"
require_array "WORK_VPN_CORP_DNS_SERVERS"
require_array "WORK_VPN_NETWORK_SERVICES"

RESOLVER_FILE="/etc/resolver/${WORK_VPN_CORP_DOMAIN}"

sudo -K
sudo -v

# Create scoped DNS resolver
sudo mkdir -p /etc/resolver
{
  for ns in "${WORK_VPN_CORP_DNS_SERVERS[@]}"; do
    echo "nameserver ${ns}"
  done
} | sudo tee "${RESOLVER_FILE}" >/dev/null

# Start VPN (DNS-safe)
sudo openconnect-sso \
  --server "${WORK_VPN_ENDPOINT_URL}" \
  --no-dns \
  --script /bin/true &
OC_PID="$!"

wait "${OC_PID}"
