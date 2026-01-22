#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# work-vpn.sh (macOS)
# ----------------------------
# Requires:
#   - openconnect-sso
#   - openconnect
#   - a vpnc-script wrapper that strips DNS env vars (vpnc-script-no-dns)
#
# .env expected (arrays supported):
#   WORK_VPN_ENDPOINT_URL="https://vpn.example.com/"
#   WORK_VPN_CORP_DOMAIN="corp.example.com"
#   WORK_VPN_CORP_DNS_SERVERS=("10.0.0.10" "10.0.0.11")
#   WORK_VPN_NETWORK_SERVICES=("USB 10/100/1000 LAN" "Wi-Fi")
# Optional:
#   WORK_VPN_VPNC_SCRIPT_NO_DNS="/opt/homebrew/etc/vpnc/vpnc-script-no-dns"
# ----------------------------

log() { printf '[work-vpn] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

# Resolve symlink so SCRIPT_DIR is the real script location
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE (copy .env.example -> .env and fill it in)"

# shellcheck disable=SC1090
source "$ENV_FILE"

# ---- Validate required vars ----
[[ -n "${WORK_VPN_ENDPOINT_URL:-}" ]] || die "WORK_VPN_ENDPOINT_URL not set"
[[ -n "${WORK_VPN_CORP_DOMAIN:-}" ]] || die "WORK_VPN_CORP_DOMAIN not set"

if ! declare -p WORK_VPN_CORP_DNS_SERVERS >/dev/null 2>&1; then
  die "WORK_VPN_CORP_DNS_SERVERS not set (must be a bash array)"
fi
if (( ${#WORK_VPN_CORP_DNS_SERVERS[@]} == 0 )); then
  die "WORK_VPN_CORP_DNS_SERVERS is empty"
fi

# WORK_VPN_NETWORK_SERVICES optional
if ! declare -p WORK_VPN_NETWORK_SERVICES >/dev/null 2>&1; then
  WORK_VPN_NETWORK_SERVICES=()
fi

WORK_VPN_VPNC_SCRIPT_NO_DNS="${WORK_VPN_VPNC_SCRIPT_NO_DNS:-/opt/homebrew/etc/vpnc/vpnc-script-no-dns}"

RESOLVER_DIR="/etc/resolver"
RESOLVER_FILE="$RESOLVER_DIR/$WORK_VPN_CORP_DOMAIN"
STATE_DIR="/tmp/work-vpn-state.$$"
mkdir -p "$STATE_DIR"

backup_resolver() {
  sudo mkdir -p "$RESOLVER_DIR"

  if sudo test -f "$RESOLVER_FILE"; then
    log "backing up existing resolver: $RESOLVER_FILE"
    sudo cp -p "$RESOLVER_FILE" "$STATE_DIR/resolver.bak"
    echo "had_resolver=1" > "$STATE_DIR/meta"
  else
    echo "had_resolver=0" > "$STATE_DIR/meta"
  fi
}

install_resolver() {
  log "installing scoped resolver: $RESOLVER_FILE"
  {
    echo "# managed by work-vpn.sh"
    for ns in "${WORK_VPN_CORP_DNS_SERVERS[@]}"; do
      echo "nameserver $ns"
    done
  } | sudo tee "$RESOLVER_FILE" >/dev/null

  sudo chmod 0644 "$RESOLVER_FILE"
  sudo chown root:wheel "$RESOLVER_FILE" 2>/dev/null || true
}

restore_resolver() {
  [[ -f "$STATE_DIR/meta" ]] || return 0
  # shellcheck disable=SC1090
  source "$STATE_DIR/meta"

  if [[ "${had_resolver:-0}" == "1" ]]; then
    [[ -f "$STATE_DIR/resolver.bak" ]] || return 0
    log "restoring previous resolver: $RESOLVER_FILE"
    sudo cp -p "$STATE_DIR/resolver.bak" "$RESOLVER_FILE"
  else
    log "removing resolver we created: $RESOLVER_FILE"
    sudo rm -f "$RESOLVER_FILE"
  fi
}

reset_network_services_to_dhcp() {
  (( ${#WORK_VPN_NETWORK_SERVICES[@]} > 0 )) || return 0

  require_cmd networksetup
  log "resetting network services to DHCP (cleanup)"
  for svc in "${WORK_VPN_NETWORK_SERVICES[@]}"; do
    log " - $svc"
    sudo networksetup -setdhcp "$svc" >/dev/null 2>&1 || true
  done
}

cleanup() {
  set +e
  reset_network_services_to_dhcp
  restore_resolver
  rm -rf "$STATE_DIR"
}
trap cleanup EXIT INT TERM

connect_vpn() {
  require_cmd sudo
  require_cmd openconnect-sso
  require_cmd openconnect

  [[ -x "$WORK_VPN_VPNC_SCRIPT_NO_DNS" ]] || die "vpnc wrapper not executable: $WORK_VPN_VPNC_SCRIPT_NO_DNS"

  log "endpoint:    $WORK_VPN_ENDPOINT_URL"
  log "corp domain: $WORK_VPN_CORP_DOMAIN"
  log "dns servers: ${WORK_VPN_CORP_DNS_SERVERS[*]}"
  log "vpnc-script: $WORK_VPN_VPNC_SCRIPT_NO_DNS"

  # IMPORTANT:
  # - The VPN endpoint/server goes to openconnect-sso via -s
  # - Anything after the first `--` is passed to openconnect (via openconnect-sso)
  # - openconnect-sso's argument parser drops the first openconnect arg after `--`,
  #   so we insert a dummy `--` sentinel before the real flags
  # - Do NOT pass the server again after `--` (that causes “Too many arguments”)
  cmd=(sudo openconnect-sso -s "$WORK_VPN_ENDPOINT_URL" -- -- --script "$WORK_VPN_VPNC_SCRIPT_NO_DNS")

  if (( DRY_RUN )); then
    log "DRY RUN - would exec:"
    printf '%q ' "${cmd[@]}" >&2
    printf '\n' >&2
    return 0
  fi

  log "connecting (Ctrl+C to disconnect)…"
  "${cmd[@]}"
}

main() {
  backup_resolver
  install_resolver
  connect_vpn
}

main "$@"
