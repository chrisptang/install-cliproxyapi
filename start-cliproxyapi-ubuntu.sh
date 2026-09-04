#!/usr/bin/env bash
#
# start-cliproxyapi-ubuntu.sh — install / update / run manager for CLIProxyAPI on Ubuntu
#
# What this script does:
#   1. Installs user-level systemd services that start CLIProxyAPI and
#      cpa-usage-keeper after login and restart them after a crash.
#   2. Installs user-level systemd timers that check GitHub every day at a
#      user-selected time (defaults to 09:00),
#      download newer Linux builds, and restart the corresponding service.
#   3. Creates config.yaml and the cpa-usage-keeper .env file when missing.
#   4. Stores binaries, configuration, logs, versions, and an installed copy of
#      this manager under ~/.local/share/cliproxyapi.
#   5. Stops and uninstalls Homebrew/Linuxbrew copies when present.
#
# Supported architectures: x86_64/amd64 and aarch64/arm64.
#
# Usage:
#   ./start-cliproxyapi-ubuntu.sh install [--port PORT] [--lan --api-key KEY]
#                                      # defaults to 127.0.0.1:8317
#   # --lan binds 0.0.0.0 so other machines on the local network can use the proxy.
#   # It requires --api-key (>=16 chars of [A-Za-z0-9._~-]) because binding 0.0.0.0
#   # also exposes the management API, and the shipped "local-key" default is public.
#   # The cpa-usage-keeper dashboard stays bound to 127.0.0.1 either way.
#   ./start-cliproxyapi-ubuntu.sh install --lan --api-key "$(openssl rand -hex 24)"
#   ./start-cliproxyapi-ubuntu.sh update
#   ./start-cliproxyapi-ubuntu.sh start
#   ./start-cliproxyapi-ubuntu.sh stop
#   ./start-cliproxyapi-ubuntu.sh restart
#   ./start-cliproxyapi-ubuntu.sh status
#   ./start-cliproxyapi-ubuntu.sh uninstall
#
# cpa-usage-keeper commands:
#   ./start-cliproxyapi-ubuntu.sh keeper-install
#   ./start-cliproxyapi-ubuntu.sh keeper-update
#   ./start-cliproxyapi-ubuntu.sh keeper-start
#   ./start-cliproxyapi-ubuntu.sh keeper-stop
#   ./start-cliproxyapi-ubuntu.sh keeper-restart
#
# Running with no argument is equivalent to "install".
#
# GitHub fetches use $http_proxy, then $HTTP_PROXY, and finally
# http://127.0.0.1:7890. Managed services do not inherit proxy variables.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${HOME}/.local/share/cliproxyapi"
MANAGER_PATH="${DATA_DIR}/start-cliproxyapi-ubuntu.sh"
BIN_NAME="cli-proxy-api"
BIN_PATH="${DATA_DIR}/${BIN_NAME}"
CONFIG_PATH="${DATA_DIR}/config.yaml"
VERSION_FILE="${DATA_DIR}/.cliproxyapi-version"
AUTH_DIR="${HOME}/.cli-proxy-api/"
LOG_DIR="${DATA_DIR}/logs"

GITHUB_REPO="router-for-me/CLIProxyAPI"
LATEST_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
PROXY_PORT=8317
PORT_WAS_SPECIFIED=false
# Listen address written into config.yaml. --lan flips it to 0.0.0.0 so other
# machines on the local network can reach the proxy.
PROXY_HOST="127.0.0.1"
LAN_WAS_SPECIFIED=false
# API key clients must present. Required (and must be non-default) with --lan.
PROXY_API_KEY="local-key"
API_KEY_WAS_SPECIFIED=false

GITHUB_PROXY="${http_proxy:-${HTTP_PROXY:-http://127.0.0.1:7890}}"
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
RUN_SERVICE="cliproxyapi.service"
UPDATE_SERVICE="cliproxyapi-update.service"
UPDATE_TIMER="cliproxyapi-update.timer"
RUN_UNIT_PATH="${SYSTEMD_USER_DIR}/${RUN_SERVICE}"
UPDATE_UNIT_PATH="${SYSTEMD_USER_DIR}/${UPDATE_SERVICE}"
UPDATE_TIMER_PATH="${SYSTEMD_USER_DIR}/${UPDATE_TIMER}"

UPDATE_HOUR=9
UPDATE_MINUTE=0
UPDATE_TIME_PROMPTED=false

# ---------------------------------------------------------------------------
# cpa-usage-keeper
# ---------------------------------------------------------------------------
KEEPER_BIN_NAME="cpa-usage-keeper"
KEEPER_BIN_PATH="${DATA_DIR}/${KEEPER_BIN_NAME}"
KEEPER_DATA_DIR="${DATA_DIR}/keeper-data"
KEEPER_ENV_PATH="${KEEPER_DATA_DIR}/.env"
KEEPER_VERSION_FILE="${DATA_DIR}/.cpa-usage-keeper-version"

KEEPER_GITHUB_REPO="Willxup/cpa-usage-keeper"
KEEPER_LATEST_API="https://api.github.com/repos/${KEEPER_GITHUB_REPO}/releases/latest"
KEEPER_PORT=30000
KEEPER_CPA_BASE_URL="http://127.0.0.1:${PROXY_PORT}"
KEEPER_CPA_MANAGEMENT_KEY="local-key"

KEEPER_RUN_SERVICE="cpa-usage-keeper.service"
KEEPER_UPDATE_SERVICE="cpa-usage-keeper-update.service"
KEEPER_UPDATE_TIMER="cpa-usage-keeper-update.timer"
KEEPER_RUN_UNIT_PATH="${SYSTEMD_USER_DIR}/${KEEPER_RUN_SERVICE}"
KEEPER_UPDATE_UNIT_PATH="${SYSTEMD_USER_DIR}/${KEEPER_UPDATE_SERVICE}"
KEEPER_UPDATE_TIMER_PATH="${SYSTEMD_USER_DIR}/${KEEPER_UPDATE_TIMER}"

PROXY_ARCH=""
KEEPER_ARCH=""
DISPLAY_ARCH=""

# ---------------------------------------------------------------------------
# Logging & validation
# ---------------------------------------------------------------------------
log() { printf '\033[0;32m[cliproxyapi]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[cliproxyapi]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[0;31m[cliproxyapi]\033[0m %s\n' "$*" >&2; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command not found: $1"
    exit 1
  fi
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

prompt_update_time() {
  ${UPDATE_TIME_PROMPTED} && return 0

  local value
  while true; do
    printf 'Daily update time [09:00] (HH:MM): '
    IFS= read -r value || value=""
    value="${value:-09:00}"
    if [[ "${value}" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
      UPDATE_HOUR="$((10#${BASH_REMATCH[1]}))"
      UPDATE_MINUTE="$((10#${BASH_REMATCH[2]}))"
      UPDATE_TIME_PROMPTED=true
      return 0
    fi
    warn "Invalid time: ${value} (expected HH:MM, for example 09:00 or 23:30)."
  done
}

update_time_display() {
  printf '%02d:%02d' "${UPDATE_HOUR}" "${UPDATE_MINUTE}"
}

set_proxy_port() {
  PROXY_PORT="$((10#$1))"
  # The dashboard always reaches CPA over loopback, even when CPA binds 0.0.0.0.
  KEEPER_CPA_BASE_URL="http://127.0.0.1:${PROXY_PORT}"
}

# Best-effort LAN address of this machine, for the post-install hint only.
lan_ip_hint() {
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')"
  printf '%s' "${ip:-<this-machine-ip>}"
}

# Keys land in a double-quoted YAML scalar and in the keeper's .env, so restrict
# them to characters that are safe verbatim in both.
set_proxy_api_key() {
  local value="$1"
  if [[ ! "${value}" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    err "Invalid --api-key: use only letters, digits, and . _ ~ - characters."
    return 1
  fi
  if ((${#value} < 16)); then
    err "Invalid --api-key: use at least 16 characters."
    return 1
  fi
  PROXY_API_KEY="${value}"
  KEEPER_CPA_MANAGEMENT_KEY="${value}"
  API_KEY_WAS_SPECIFIED=true
}

parse_arguments() {
  COMMAND=""
  while (($# > 0)); do
    case "$1" in
    --port)
      if (($# < 2)); then
        err "--port requires a value between 1 and 65535."
        exit 1
      fi
      is_valid_port "$2" || {
        err "Invalid port: $2 (expected 1-65535)."
        exit 1
      }
      set_proxy_port "$2"
      PORT_WAS_SPECIFIED=true
      shift 2
      ;;
    --port=*)
      local port_value="${1#*=}"
      is_valid_port "${port_value}" || {
        err "Invalid port: ${port_value:-<empty>} (expected 1-65535)."
        exit 1
      }
      set_proxy_port "${port_value}"
      PORT_WAS_SPECIFIED=true
      shift
      ;;
    --lan)
      PROXY_HOST="0.0.0.0"
      LAN_WAS_SPECIFIED=true
      shift
      ;;
    --api-key)
      if (($# < 2)); then
        err "--api-key requires a value."
        exit 1
      fi
      set_proxy_api_key "$2" || exit 1
      shift 2
      ;;
    --api-key=*)
      set_proxy_api_key "${1#*=}" || exit 1
      shift
      ;;
    -h | --help | help)
      [[ -z "${COMMAND}" ]] || {
        err "Unexpected argument: $1"
        exit 1
      }
      COMMAND="help"
      shift
      ;;
    -*)
      err "Unknown option: $1"
      exit 1
      ;;
    *)
      [[ -z "${COMMAND}" ]] || {
        err "Unexpected argument: $1"
        exit 1
      }
      COMMAND="$1"
      shift
      ;;
    esac
  done

  COMMAND="${COMMAND:-install}"
  if ${PORT_WAS_SPECIFIED} && [[ "${COMMAND}" != "install" ]]; then
    err "--port is only supported with the install command."
    exit 1
  fi
  if ${LAN_WAS_SPECIFIED} && [[ "${COMMAND}" != "install" ]]; then
    err "--lan is only supported with the install command."
    exit 1
  fi
  if ${API_KEY_WAS_SPECIFIED} && [[ "${COMMAND}" != "install" ]]; then
    err "--api-key is only supported with the install command."
    exit 1
  fi
  # Binding 0.0.0.0 exposes the proxy AND its management API to the whole local
  # network, so the shipped "local-key" default must not be reused there.
  if ${LAN_WAS_SPECIFIED} && ! ${API_KEY_WAS_SPECIFIED}; then
    err "--lan requires --api-key: binding 0.0.0.0 exposes the proxy and its"
    err "management API to the local network, and the default key is public."
    err "Example: ./start-cliproxyapi-ubuntu.sh install --lan --api-key \"\$(openssl rand -hex 24)\""
    exit 1
  fi
}

require_ubuntu() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    err "This script can only run on Ubuntu."
    exit 1
  fi

  if [[ ! -r /etc/os-release ]]; then
    err "Cannot identify this Linux distribution: /etc/os-release is missing."
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && " ${ID_LIKE:-} " != *" ubuntu "* ]]; then
    err "Unsupported Linux distribution: ${PRETTY_NAME:-unknown}. This script supports Ubuntu."
    exit 1
  fi
}

detect_architecture() {
  case "$(uname -m)" in
  x86_64 | amd64)
    PROXY_ARCH="amd64"
    KEEPER_ARCH="amd64"
    DISPLAY_ARCH="x64"
    ;;
  aarch64 | arm64)
    PROXY_ARCH="aarch64"
    KEEPER_ARCH="arm64"
    DISPLAY_ARCH="ARM64"
    ;;
  *)
    err "Unsupported Ubuntu architecture: $(uname -m). Only x86_64 and ARM64 are supported."
    exit 1
    ;;
  esac
}

require_user_systemd() {
  require systemctl
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    err "The user systemd manager is not available."
    err "Log in as the target user and run this script without sudo."
    exit 1
  fi
}

gh_curl() {
  if [[ -n "${GITHUB_PROXY}" ]]; then
    curl --proxy "${GITHUB_PROXY}" "$@"
  else
    curl "$@"
  fi
}

# ---------------------------------------------------------------------------
# Runtime migration and installed manager copy
# ---------------------------------------------------------------------------
install_manager_copy() {
  mkdir -p "${DATA_DIR}"
  local source="${REPO_DIR}/$(basename "${BASH_SOURCE[0]}")"
  if [[ "${source}" != "${MANAGER_PATH}" ]]; then
    cp -f "${source}" "${MANAGER_PATH}"
  fi
  chmod +x "${MANAGER_PATH}"
  log "Installed manager script at ${MANAGER_PATH}"
}

migrate_from_repo() {
  local moved=false

  if [[ -f "${REPO_DIR}/${BIN_NAME}" && ! -f "${BIN_PATH}" ]]; then
    mkdir -p "${DATA_DIR}"
    mv "${REPO_DIR}/${BIN_NAME}" "${BIN_PATH}"
    log "Migrated ${BIN_NAME} → ${DATA_DIR}/"
    moved=true
  fi

  if [[ -f "${REPO_DIR}/config.yaml" && ! -f "${CONFIG_PATH}" ]]; then
    mkdir -p "${DATA_DIR}"
    cp "${REPO_DIR}/config.yaml" "${CONFIG_PATH}"
    log "Migrated config.yaml → ${DATA_DIR}/"
    moved=true
  fi

  if [[ -f "${REPO_DIR}/.cliproxyapi-version" && ! -f "${VERSION_FILE}" ]]; then
    mkdir -p "${DATA_DIR}"
    mv "${REPO_DIR}/.cliproxyapi-version" "${VERSION_FILE}"
    moved=true
  fi

  if [[ -d "${REPO_DIR}/logs" && ! -d "${LOG_DIR}" ]]; then
    mkdir -p "${DATA_DIR}"
    mv "${REPO_DIR}/logs" "${LOG_DIR}"
    log "Migrated logs/ → ${LOG_DIR}/"
    moved=true
  fi

  if [[ -f "${REPO_DIR}/${KEEPER_BIN_NAME}" && ! -f "${KEEPER_BIN_PATH}" ]]; then
    mkdir -p "${DATA_DIR}"
    mv "${REPO_DIR}/${KEEPER_BIN_NAME}" "${KEEPER_BIN_PATH}"
    log "Migrated ${KEEPER_BIN_NAME} → ${DATA_DIR}/"
    moved=true
  fi

  if [[ -f "${REPO_DIR}/.cpa-usage-keeper-version" && ! -f "${KEEPER_VERSION_FILE}" ]]; then
    mkdir -p "${DATA_DIR}"
    mv "${REPO_DIR}/.cpa-usage-keeper-version" "${KEEPER_VERSION_FILE}"
    moved=true
  fi

  if [[ -d "${REPO_DIR}/keeper-data" && ! -d "${KEEPER_DATA_DIR}" ]]; then
    mkdir -p "${DATA_DIR}"
    mv "${REPO_DIR}/keeper-data" "${KEEPER_DATA_DIR}"
    log "Migrated keeper-data/ → ${KEEPER_DATA_DIR}/"
    moved=true
  fi

  "${moved}" || true
}

purge_homebrew() {
  if ! command -v brew >/dev/null 2>&1; then
    return 0
  fi

  local found=false
  if brew list --formula 2>/dev/null | grep -qx cliproxyapi; then
    found=true
    log "Found Homebrew/Linuxbrew cliproxyapi — stopping and uninstalling it."
    brew services stop cliproxyapi >/dev/null 2>&1 || true
    brew uninstall --force cliproxyapi >/dev/null 2>&1 || warn "brew uninstall cliproxyapi reported an issue (continuing)."
    log "Homebrew/Linuxbrew cliproxyapi removed."
  fi

  if brew list --formula 2>/dev/null | grep -qx cpa-usage-keeper; then
    found=true
    log "Found Homebrew/Linuxbrew cpa-usage-keeper — stopping and uninstalling it."
    brew services stop cpa-usage-keeper >/dev/null 2>&1 || true
    brew uninstall --force cpa-usage-keeper >/dev/null 2>&1 || warn "brew uninstall cpa-usage-keeper reported an issue (continuing)."
    log "Homebrew/Linuxbrew cpa-usage-keeper removed."
  fi

  "${found}" || log "No Homebrew/Linuxbrew cliproxyapi / cpa-usage-keeper found — nothing to purge."
}

# ---------------------------------------------------------------------------
# Release discovery and downloads
# ---------------------------------------------------------------------------
fetch_latest_release() {
  local json tag url asset_suffix
  asset_suffix="linux_${PROXY_ARCH}.tar.gz"
  json="$(gh_curl -fsSL "${LATEST_API}")" || {
    err "Failed to query GitHub releases API."
    return 1
  }

  tag="$(printf '%s' "${json}" |
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' |
    sed -E 's/.*"([^"]+)"$/\1/' |
    head -n1)"
  url="$(printf '%s' "${json}" |
    grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' |
    sed -E 's/.*"([^"]+)"$/\1/' |
    grep "${asset_suffix}$" |
    grep -v 'no-plugin' |
    head -n1)"

  if [[ -z "${tag}" || -z "${url}" ]]; then
    err "Could not determine latest version or Ubuntu ${DISPLAY_ARCH} asset URL."
    return 1
  fi
  printf '%s\t%s\n' "${tag}" "${url}"
}

fetch_latest_keeper_release() {
  local json tag url asset_suffix
  asset_suffix="linux_${KEEPER_ARCH}.tar.gz"
  json="$(gh_curl -fsSL "${KEEPER_LATEST_API}")" || {
    err "Failed to query cpa-usage-keeper releases API."
    return 1
  }

  tag="$(printf '%s' "${json}" |
    grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' |
    sed -E 's/.*"([^"]+)"$/\1/' |
    head -n1)"
  url="$(printf '%s' "${json}" |
    grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' |
    sed -E 's/.*"([^"]+)"$/\1/' |
    grep "${asset_suffix}$" |
    head -n1)"

  if [[ -z "${tag}" || -z "${url}" ]]; then
    err "Could not determine latest cpa-usage-keeper version or Ubuntu ${DISPLAY_ARCH} asset URL."
    return 1
  fi
  printf '%s\t%s\n' "${tag}" "${url}"
}

local_version() {
  [[ -f "${VERSION_FILE}" ]] && cat "${VERSION_FILE}" || echo "none"
}

keeper_local_version() {
  [[ -f "${KEEPER_VERSION_FILE}" ]] && cat "${KEEPER_VERSION_FILE}" || echo "none"
}

download_binary() {
  local tag="$1" url="$2" tmpdir extracted
  tmpdir="$(mktemp -d)"

  log "Downloading ${tag} (${url##*/}) ..."
  if ! gh_curl -fsSL "${url}" -o "${tmpdir}/release.tar.gz"; then
    err "Download failed."
    rm -rf "${tmpdir}"
    return 1
  fi
  if ! tar -xzf "${tmpdir}/release.tar.gz" -C "${tmpdir}"; then
    err "Extraction failed."
    rm -rf "${tmpdir}"
    return 1
  fi

  extracted="$(find "${tmpdir}" -type f -name "${BIN_NAME}" | head -n1)"
  if [[ -z "${extracted}" ]]; then
    err "Binary '${BIN_NAME}' not found inside the release archive."
    rm -rf "${tmpdir}"
    return 1
  fi

  chmod +x "${extracted}"
  mv -f "${extracted}" "${BIN_PATH}"
  printf '%s\n' "${tag}" >"${VERSION_FILE}"
  rm -rf "${tmpdir}"
  log "Installed ${BIN_NAME} ${tag} at ${BIN_PATH}"
}

download_keeper_binary() {
  local tag="$1" url="$2" tmpdir extracted
  tmpdir="$(mktemp -d)"

  log "Downloading cpa-usage-keeper ${tag} (${url##*/}) ..."
  if ! gh_curl -fsSL "${url}" -o "${tmpdir}/release.tar.gz"; then
    err "Keeper download failed."
    rm -rf "${tmpdir}"
    return 1
  fi
  if ! tar -xzf "${tmpdir}/release.tar.gz" -C "${tmpdir}"; then
    err "Keeper extraction failed."
    rm -rf "${tmpdir}"
    return 1
  fi

  extracted="$(find "${tmpdir}" -type f -name "${KEEPER_BIN_NAME}" | head -n1)"
  if [[ -z "${extracted}" ]]; then
    err "Binary '${KEEPER_BIN_NAME}' not found inside the keeper release archive."
    rm -rf "${tmpdir}"
    return 1
  fi

  chmod +x "${extracted}"
  mv -f "${extracted}" "${KEEPER_BIN_PATH}"
  printf '%s\n' "${tag}" >"${KEEPER_VERSION_FILE}"
  rm -rf "${tmpdir}"
  log "Installed ${KEEPER_BIN_NAME} ${tag} at ${KEEPER_BIN_PATH}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
load_proxy_port_from_config() {
  [[ -f "${CONFIG_PATH}" ]] || return 0

  local line value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    if [[ "${line}" =~ ^port:[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      value="${BASH_REMATCH[1]}"
      if is_valid_port "${value}"; then
        set_proxy_port "${value}"
      fi
      return 0
    fi
  done <"${CONFIG_PATH}"
}

update_config_port() {
  local tmp_path="${CONFIG_PATH}.tmp.$$" line comment replaced=false
  : >"${tmp_path}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if ! ${replaced} && [[ "${line}" =~ ^port:[[:space:]]* ]]; then
      comment=""
      if [[ "${line}" == *#* ]]; then
        comment=" #${line#*#}"
      fi
      printf 'port: %s%s\n' "${PROXY_PORT}" "${comment}" >>"${tmp_path}"
      replaced=true
    else
      printf '%s\n' "${line}" >>"${tmp_path}"
    fi
  done <"${CONFIG_PATH}"
  if ! ${replaced}; then
    printf '\nport: %s\n' "${PROXY_PORT}" >>"${tmp_path}"
  fi
  mv -f "${tmp_path}" "${CONFIG_PATH}"
  log "Set CLIProxyAPI port to ${PROXY_PORT} in ${CONFIG_PATH}."
}

# Reads the effective host:port out of config.yaml for `status` (which runs
# without --lan/--port, so the globals still hold defaults).
config_listen_summary() {
  local host port
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    printf 'unknown (no config.yaml)'
    return 0
  fi
  host="$(sed -nE 's/^host:[[:space:]]*"?([^"#[:space:]]+)"?.*$/\1/p' "${CONFIG_PATH}" | head -n1)"
  port="$(sed -nE 's/^port:[[:space:]]*([0-9]+).*$/\1/p' "${CONFIG_PATH}" | head -n1)"
  host="${host:-127.0.0.1}"
  port="${port:-${PROXY_PORT}}"
  if [[ "${host}" == "0.0.0.0" ]]; then
    printf '%s:%s (LAN — reachable at http://%s:%s)' "${host}" "${port}" "$(lan_ip_hint)" "${port}"
  else
    printf '%s:%s (this machine only)' "${host}" "${port}"
  fi
}
update_config_host() {
  local tmp_path="${CONFIG_PATH}.tmp.$$" line comment replaced=false
  : >"${tmp_path}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    # Drop any previous bind note (stock or ours) so it can't contradict the new
    # value, and so repeated runs don't stack up comment lines.
    if ! ${replaced} && [[ "${line}" == "# Bind to localhost only by default." ||
      "${line}" == "# Bound to 0.0.0.0 by --lan: reachable from the local network." ]]; then
      continue
    fi
    if ! ${replaced} && [[ "${line}" =~ ^host:[[:space:]]* ]]; then
      comment=""
      if [[ "${line}" == *#* ]]; then
        comment=" #${line#*#}"
      fi
      if [[ "${PROXY_HOST}" == "0.0.0.0" ]]; then
        printf '# Bound to 0.0.0.0 by --lan: reachable from the local network.\n' >>"${tmp_path}"
      fi
      printf 'host: "%s"%s\n' "${PROXY_HOST}" "${comment}" >>"${tmp_path}"
      replaced=true
    else
      printf '%s\n' "${line}" >>"${tmp_path}"
    fi
  done <"${CONFIG_PATH}"
  if ! ${replaced}; then
    printf '\nhost: "%s"\n' "${PROXY_HOST}" >>"${tmp_path}"
  fi
  mv -f "${tmp_path}" "${CONFIG_PATH}"
  log "Set CLIProxyAPI host to ${PROXY_HOST} in ${CONFIG_PATH}."
}
# Replaces the api-keys list (and the management secret-key) with the single key
# given via --api-key. Any other keys previously listed are dropped.
update_config_api_key() {
  local tmp_path="${CONFIG_PATH}.tmp.$$" line
  local in_api_keys=false keys_replaced=false secret_replaced=false
  : >"${tmp_path}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if ${in_api_keys}; then
      # Consume the existing list items; anything else ends the block.
      if [[ "${line}" =~ ^[[:space:]]+-[[:space:]] ]]; then
        continue
      fi
      in_api_keys=false
    fi
    if ! ${keys_replaced} && [[ "${line}" =~ ^api-keys:[[:space:]]*$ ]]; then
      printf 'api-keys:\n  - %s\n' "${PROXY_API_KEY}" >>"${tmp_path}"
      in_api_keys=true
      keys_replaced=true
      continue
    fi
    if ! ${secret_replaced} && [[ "${line}" =~ ^[[:space:]]+secret-key:[[:space:]] ]]; then
      printf '  secret-key: "%s"\n' "${PROXY_API_KEY}" >>"${tmp_path}"
      secret_replaced=true
      continue
    fi
    printf '%s\n' "${line}" >>"${tmp_path}"
  done <"${CONFIG_PATH}"
  if ! ${keys_replaced}; then
    printf '\napi-keys:\n  - %s\n' "${PROXY_API_KEY}" >>"${tmp_path}"
  fi
  mv -f "${tmp_path}" "${CONFIG_PATH}"
  if ${secret_replaced}; then
    log "Set api-keys and remote-management.secret-key to the provided key in ${CONFIG_PATH}."
  else
    warn "Set api-keys in ${CONFIG_PATH}, but found no remote-management.secret-key to update."
    warn "Check that the management key is not still the default before exposing this host."
  fi
}

ensure_config() {
  mkdir -p "${DATA_DIR}"
  if [[ -f "${CONFIG_PATH}" ]]; then
    if ${PORT_WAS_SPECIFIED}; then
      update_config_port
    else
      load_proxy_port_from_config
    fi
    if ${API_KEY_WAS_SPECIFIED}; then
      update_config_api_key
    fi
    if ${LAN_WAS_SPECIFIED}; then
      update_config_host
    fi
    if ! ${PORT_WAS_SPECIFIED} && ! ${API_KEY_WAS_SPECIFIED} && ! ${LAN_WAS_SPECIFIED}; then
      log "config.yaml already exists — leaving it untouched."
    fi
    return 0
  fi

  log "config.yaml not found — creating a default one."
  cat >"${CONFIG_PATH}" <<EOF
# CLIProxyAPI config — tuned for low-latency Codex (GPT-5.x) forwarding.
# Generated/updated by start-cliproxyapi-ubuntu.sh. Full reference: https://help.router-for.me/
#
# Optimization goal: make Codex feel fast WITHOUT changing request semantics or cost.
# We deliberately do NOT force \`reasoning.effort\` and do NOT inject \`service_tier\`.

# Bind address. 127.0.0.1 = this machine only; 0.0.0.0 (--lan) = reachable from
# the local network.
host: "${PROXY_HOST}"
port: ${PROXY_PORT}
auth-dir: "${AUTH_DIR}"
api-keys:
  - ${PROXY_API_KEY}
remote-management:
  allow-remote: true
  secret-key: "${PROXY_API_KEY}"
debug: true
streaming:
  keepalive-seconds: 15
  bootstrap-retries: 1
nonstream-keepalive-interval: 15
commercial-mode: true
usage-statistics-enabled: true
pprof:
  enable: false
  addr: "127.0.0.1:8316"
request-retry: 2
max-retry-credentials: 2
max-retry-interval: 8
transient-error-cooldown-seconds: -1
routing:
  strategy: "fill-first"
  session-affinity: true
  session-affinity-ttl: "2h"
codex:
  identity-confuse: false
quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true
redis-usage-queue-retention-seconds: 60
claude-api-key:
  - api-key: REPLACE_ME_BIGMODEL_KEY
    base-url: https://open.bigmodel.cn/api/anthropic
    models:
      - name: glm-5.2
        alias: glm
    disable-cooling: true
  - api-key: REPLACE_ME_MINIMAX_KEY
    base-url: https://api.minimaxi.com/anthropic
    proxy-url: ""
    models:
      - name: MiniMax-M3
        alias: "minimax"
      - name: MiniMax-M2.7-highspeed
        alias: minimax-2.7
    disable-cooling: true
logging-to-file: true
proxy-url: http://127.0.0.1:7890
EOF
  log "Wrote ${CONFIG_PATH} (host: ${PROXY_HOST}, api-key + management secret-key: ${PROXY_API_KEY})."
  log "NOTE: edit claude-api-key REPLACE_ME_* values before using the Anthropic endpoint."
}

ensure_usage_statistics_enabled() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*usage-statistics-enabled:[[:space:]]*true' "${CONFIG_PATH}"; then
    log "usage-statistics-enabled already true in config.yaml."
    return 0
  fi
  if grep -Eq '^[[:space:]]*usage-statistics-enabled:' "${CONFIG_PATH}"; then
    sed -E -i 's/^([[:space:]]*usage-statistics-enabled:[[:space:]]*)[^[:space:]#]+(.*)$/\1true\2/' "${CONFIG_PATH}"
    log "Set usage-statistics-enabled: true in config.yaml (required by cpa-usage-keeper)."
  else
    printf '\n# Enabled so cpa-usage-keeper can persist token usage.\nusage-statistics-enabled: true\n' >>"${CONFIG_PATH}"
    log "Appended usage-statistics-enabled: true to config.yaml (required by cpa-usage-keeper)."
  fi
}

update_keeper_base_url() {
  local tmp_path="${KEEPER_ENV_PATH}.tmp.$$" line replaced=false
  : >"${tmp_path}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if ! ${replaced} && [[ "${line}" == CPA_BASE_URL=* ]]; then
      printf 'CPA_BASE_URL=%s\n' "${KEEPER_CPA_BASE_URL}" >>"${tmp_path}"
      replaced=true
    else
      printf '%s\n' "${line}" >>"${tmp_path}"
    fi
  done <"${KEEPER_ENV_PATH}"
  if ! ${replaced}; then
    printf '\nCPA_BASE_URL=%s\n' "${KEEPER_CPA_BASE_URL}" >>"${tmp_path}"
  fi
  mv -f "${tmp_path}" "${KEEPER_ENV_PATH}"
  log "Set cpa-usage-keeper CPA_BASE_URL to ${KEEPER_CPA_BASE_URL}."
}

update_keeper_management_key() {
  local tmp_path="${KEEPER_ENV_PATH}.tmp.$$" line replaced=false
  : >"${tmp_path}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if ! ${replaced} && [[ "${line}" == CPA_MANAGEMENT_KEY=* ]]; then
      printf 'CPA_MANAGEMENT_KEY=%s\n' "${KEEPER_CPA_MANAGEMENT_KEY}" >>"${tmp_path}"
      replaced=true
    else
      printf '%s\n' "${line}" >>"${tmp_path}"
    fi
  done <"${KEEPER_ENV_PATH}"
  if ! ${replaced}; then
    printf '\nCPA_MANAGEMENT_KEY=%s\n' "${KEEPER_CPA_MANAGEMENT_KEY}" >>"${tmp_path}"
  fi
  mv -f "${tmp_path}" "${KEEPER_ENV_PATH}"
  log "Set cpa-usage-keeper CPA_MANAGEMENT_KEY to match config.yaml."
}

ensure_keeper_env() {
  mkdir -p "${KEEPER_DATA_DIR}"
  if [[ -f "${KEEPER_ENV_PATH}" ]]; then
    if ${PORT_WAS_SPECIFIED}; then
      update_keeper_base_url
    fi
    # The dashboard authenticates with the management key; keep it in sync with
    # the secret-key just written into config.yaml, or it silently gets no data.
    if ${API_KEY_WAS_SPECIFIED}; then
      update_keeper_management_key
    fi
    if ! ${PORT_WAS_SPECIFIED} && ! ${API_KEY_WAS_SPECIFIED}; then
      log "cpa-usage-keeper .env already exists — leaving it untouched."
    fi
    return 0
  fi

  if ! ${PORT_WAS_SPECIFIED}; then
    load_proxy_port_from_config
  fi
  log "cpa-usage-keeper .env not found — creating one."
  cat >"${KEEPER_ENV_PATH}" <<EOF
# cpa-usage-keeper config generated by start-cliproxyapi-ubuntu.sh
CPA_BASE_URL=${KEEPER_CPA_BASE_URL}
CPA_MANAGEMENT_KEY=${KEEPER_CPA_MANAGEMENT_KEY}
APP_PORT=${KEEPER_PORT}
WORK_DIR=.
AUTH_ENABLED=false
TZ=Asia/Shanghai
EOF
  log "Wrote ${KEEPER_ENV_PATH} (CPA ${KEEPER_CPA_BASE_URL}, dashboard port ${KEEPER_PORT})."
}

# ---------------------------------------------------------------------------
# User-level systemd units
# ---------------------------------------------------------------------------
write_run_service() {
  mkdir -p "${SYSTEMD_USER_DIR}" "${LOG_DIR}"
  cat >"${RUN_UNIT_PATH}" <<EOF
[Unit]
Description=CLIProxyAPI local proxy

[Service]
Type=simple
WorkingDirectory=${DATA_DIR}
ExecStart=${BIN_PATH} -config ${CONFIG_PATH}
Restart=always
RestartSec=5
Environment=http_proxy=
Environment=HTTP_PROXY=
Environment=https_proxy=
Environment=HTTPS_PROXY=
Environment=all_proxy=
Environment=ALL_PROXY=
Environment=no_proxy=
Environment=NO_PROXY=
StandardOutput=append:${LOG_DIR}/cliproxyapi.out.log
StandardError=append:${LOG_DIR}/cliproxyapi.err.log

[Install]
WantedBy=default.target
EOF
  log "Wrote user service: ${RUN_UNIT_PATH}"
}

write_update_units() {
  mkdir -p "${SYSTEMD_USER_DIR}" "${LOG_DIR}"
  cat >"${UPDATE_UNIT_PATH}" <<EOF
[Unit]
Description=Check CLIProxyAPI for updates

[Service]
Type=oneshot
WorkingDirectory=${DATA_DIR}
ExecStart=/bin/bash ${MANAGER_PATH} update
StandardOutput=append:${LOG_DIR}/cliproxyapi.update.log
StandardError=append:${LOG_DIR}/cliproxyapi.update.log
EOF

  cat >"${UPDATE_TIMER_PATH}" <<EOF
[Unit]
Description=Daily CLIProxyAPI update check

[Timer]
OnCalendar=*-*-* $(printf '%02d:%02d:00' "${UPDATE_HOUR}" "${UPDATE_MINUTE}")
Persistent=true
Unit=${UPDATE_SERVICE}

[Install]
WantedBy=timers.target
EOF
  log "Wrote daily update timer ($(update_time_display)): ${UPDATE_TIMER_PATH}"
}

write_keeper_run_service() {
  mkdir -p "${SYSTEMD_USER_DIR}" "${LOG_DIR}" "${KEEPER_DATA_DIR}"
  cat >"${KEEPER_RUN_UNIT_PATH}" <<EOF
[Unit]
Description=cpa-usage-keeper dashboard

[Service]
Type=simple
WorkingDirectory=${KEEPER_DATA_DIR}
ExecStart=${KEEPER_BIN_PATH}
Restart=always
RestartSec=5
Environment=http_proxy=
Environment=HTTP_PROXY=
Environment=https_proxy=
Environment=HTTPS_PROXY=
Environment=all_proxy=
Environment=ALL_PROXY=
Environment=no_proxy=
Environment=NO_PROXY=
StandardOutput=append:${LOG_DIR}/cpa-usage-keeper.out.log
StandardError=append:${LOG_DIR}/cpa-usage-keeper.err.log

[Install]
WantedBy=default.target
EOF
  log "Wrote user service: ${KEEPER_RUN_UNIT_PATH}"
}

write_keeper_update_units() {
  mkdir -p "${SYSTEMD_USER_DIR}" "${LOG_DIR}"
  cat >"${KEEPER_UPDATE_UNIT_PATH}" <<EOF
[Unit]
Description=Check cpa-usage-keeper for updates

[Service]
Type=oneshot
WorkingDirectory=${DATA_DIR}
ExecStart=/bin/bash ${MANAGER_PATH} keeper-update
StandardOutput=append:${LOG_DIR}/cpa-usage-keeper.update.log
StandardError=append:${LOG_DIR}/cpa-usage-keeper.update.log
EOF

  cat >"${KEEPER_UPDATE_TIMER_PATH}" <<EOF
[Unit]
Description=Daily cpa-usage-keeper update check

[Timer]
OnCalendar=*-*-* $(printf '%02d:%02d:00' "${UPDATE_HOUR}" "${UPDATE_MINUTE}")
Persistent=true
Unit=${KEEPER_UPDATE_SERVICE}

[Install]
WantedBy=timers.target
EOF
  log "Wrote cpa-usage-keeper daily update timer ($(update_time_display)): ${KEEPER_UPDATE_TIMER_PATH}"
}

reload_user_systemd() {
  systemctl --user daemon-reload
}

install_update_timer() {
  write_update_units
  reload_user_systemd
  systemctl --user enable --now "${UPDATE_TIMER}" >/dev/null
  systemctl --user restart "${UPDATE_TIMER}"
}

install_keeper_update_timer() {
  write_keeper_update_units
  reload_user_systemd
  systemctl --user enable --now "${KEEPER_UPDATE_TIMER}" >/dev/null
  systemctl --user restart "${KEEPER_UPDATE_TIMER}"
}

# ---------------------------------------------------------------------------
# Service control and status
# ---------------------------------------------------------------------------
start_service() {
  write_run_service
  reload_user_systemd
  systemctl --user enable "${RUN_SERVICE}" >/dev/null
  systemctl --user restart "${RUN_SERVICE}"
  log "Service started (${RUN_SERVICE})."
}

stop_service() {
  systemctl --user stop "${RUN_SERVICE}" >/dev/null 2>&1 || true
  log "Service stopped."
}

start_keeper() {
  write_keeper_run_service
  reload_user_systemd
  systemctl --user enable "${KEEPER_RUN_SERVICE}" >/dev/null
  systemctl --user restart "${KEEPER_RUN_SERVICE}"
  log "Dashboard started (${KEEPER_RUN_SERVICE}) — http://127.0.0.1:${KEEPER_PORT}"
}

stop_keeper() {
  systemctl --user stop "${KEEPER_RUN_SERVICE}" >/dev/null 2>&1 || true
  log "Dashboard stopped."
}

keeper_is_running() {
  systemctl --user is-active --quiet "${KEEPER_RUN_SERVICE}" ||
    pgrep -f -x "${KEEPER_BIN_PATH}" >/dev/null 2>&1
}

restart_service() {
  log "Restarting service ..."
  local keeper_was_running=false
  if keeper_is_running; then
    keeper_was_running=true
    log "Stopping cpa-usage-keeper before restart to avoid management-API ban ..."
    stop_keeper
    pkill -f -x "${KEEPER_BIN_PATH}" >/dev/null 2>&1 || true
    sleep 1
  fi

  stop_service
  start_service
  if "${keeper_was_running}"; then
    log "Restarting cpa-usage-keeper ..."
    start_keeper
  fi
}

restart_keeper() {
  log "Restarting dashboard ..."
  stop_keeper
  start_keeper
}

unit_state() {
  local unit="$1" path="$2"
  if systemctl --user is-active --quiet "${unit}"; then
    printf 'active'
  elif systemctl --user is-enabled --quiet "${unit}" 2>/dev/null; then
    printf 'enabled, inactive'
  elif [[ -f "${path}" ]]; then
    printf 'installed, inactive'
  else
    printf 'not installed'
  fi
}

status_service() {
  log "Architecture:   ${DISPLAY_ARCH}"
  log "Data directory: ${DATA_DIR}"
  log "Local version:  $(local_version)"
  log "Binary:         ${BIN_PATH} $([[ -x "${BIN_PATH}" ]] && echo '(present)' || echo '(MISSING)')"
  log "Config:         ${CONFIG_PATH} $([[ -f "${CONFIG_PATH}" ]] && echo '(present)' || echo '(MISSING)')"
  log "Listen:         $(config_listen_summary)"
  log "Run service:    $(unit_state "${RUN_SERVICE}" "${RUN_UNIT_PATH}")"
  log "Update timer:   $(unit_state "${UPDATE_TIMER}" "${UPDATE_TIMER_PATH}")"
  log "--- cpa-usage-keeper (dashboard) ---"
  log "Keeper version: $(keeper_local_version)"
  log "Keeper binary:  ${KEEPER_BIN_PATH} $([[ -x "${KEEPER_BIN_PATH}" ]] && echo '(present)' || echo '(MISSING)')"
  log "Keeper env:     ${KEEPER_ENV_PATH} $([[ -f "${KEEPER_ENV_PATH}" ]] && echo '(present)' || echo '(MISSING)')"
  log "Dashboard URL:  http://127.0.0.1:${KEEPER_PORT}"
  log "Keeper service: $(unit_state "${KEEPER_RUN_SERVICE}" "${KEEPER_RUN_UNIT_PATH}")"
  log "Keeper timer:   $(unit_state "${KEEPER_UPDATE_TIMER}" "${KEEPER_UPDATE_TIMER_PATH}")"
}

# ---------------------------------------------------------------------------
# Update and install flows
# ---------------------------------------------------------------------------
do_update_check() {
  local line tag url current
  line="$(fetch_latest_release)" || return 2
  tag="${line%%$'\t'*}"
  url="${line#*$'\t'}"
  current="$(local_version)"

  if [[ "${current}" == "${tag}" && -x "${BIN_PATH}" ]]; then
    log "Already up to date (${current})."
    return 1
  fi

  log "Update available: ${current} -> ${tag}"
  download_binary "${tag}" "${url}"
}

do_keeper_update_check() {
  local line tag url current
  line="$(fetch_latest_keeper_release)" || return 2
  tag="${line%%$'\t'*}"
  url="${line#*$'\t'}"
  current="$(keeper_local_version)"

  if [[ "${current}" == "${tag}" && -x "${KEEPER_BIN_PATH}" ]]; then
    log "cpa-usage-keeper already up to date (${current})."
    return 1
  fi

  log "cpa-usage-keeper update available: ${current} -> ${tag}"
  download_keeper_binary "${tag}" "${url}"
}

install_keeper() {
  prompt_update_time
  log "--- Installing cpa-usage-keeper dashboard ---"
  ensure_keeper_env
  if do_keeper_update_check; then :; else
    if [[ ! -x "${KEEPER_BIN_PATH}" ]]; then
      err "No cpa-usage-keeper binary present and update check failed — skipping dashboard."
      return 1
    fi
  fi
  install_keeper_update_timer
  start_keeper
}

cmd_install() {
  prompt_update_time
  require curl
  require tar
  log "=== Installing CLIProxyAPI manager for Ubuntu ${DISPLAY_ARCH} (repo: ${REPO_DIR}) ==="

  migrate_from_repo
  install_manager_copy
  purge_homebrew
  ensure_config
  ensure_usage_statistics_enabled

  if do_update_check; then :; else
    if [[ ! -x "${BIN_PATH}" ]]; then
      err "No binary present and update check failed — cannot start."
      exit 1
    fi
  fi

  install_update_timer
  start_service
  install_keeper

  if [[ "${PROXY_HOST}" == "0.0.0.0" ]]; then
    log "=== Done. CPA on ${PROXY_HOST}:${PROXY_PORT} (LAN); dashboard on http://127.0.0.1:${KEEPER_PORT}. ==="
    log "LAN clients: http://$(lan_ip_hint):${PROXY_PORT} — they must send the api-key you set."
    log "The dashboard stays bound to this machine only."
    log "If ufw/firewalld is active, allow inbound TCP ${PROXY_PORT} for LAN clients to connect."
  else
    log "=== Done. CPA on port ${PROXY_PORT}; dashboard on http://127.0.0.1:${KEEPER_PORT}. ==="
  fi
  status_service
}

cmd_update() {
  require curl
  require tar
  log "=== Daily update check ==="
  ensure_config
  local rc=0
  do_update_check || rc=$?
  case "${rc}" in
  0)
    log "New version installed — restarting service."
    restart_service
    ;;
  1) log "No update; leaving running service as-is." ;;
  *)
    err "Update check failed (network/API error). Will retry next run."
    exit 1
    ;;
  esac
}

cmd_keeper_update() {
  require curl
  require tar
  log "=== cpa-usage-keeper daily update check ==="
  ensure_keeper_env
  local rc=0
  do_keeper_update_check || rc=$?
  case "${rc}" in
  0)
    log "New dashboard version installed — restarting dashboard."
    restart_keeper
    ;;
  1) log "No dashboard update; leaving it running as-is." ;;
  *)
    err "Dashboard update check failed (network/API error). Will retry next run."
    exit 1
    ;;
  esac
}

cmd_uninstall() {
  log "Stopping and removing user systemd units (runtime data kept)."

  systemctl --user disable --now "${UPDATE_TIMER}" >/dev/null 2>&1 || true
  systemctl --user disable --now "${KEEPER_UPDATE_TIMER}" >/dev/null 2>&1 || true
  systemctl --user disable --now "${RUN_SERVICE}" >/dev/null 2>&1 || true
  systemctl --user disable --now "${KEEPER_RUN_SERVICE}" >/dev/null 2>&1 || true
  systemctl --user stop "${UPDATE_SERVICE}" "${KEEPER_UPDATE_SERVICE}" >/dev/null 2>&1 || true

  rm -f \
    "${RUN_UNIT_PATH}" \
    "${UPDATE_UNIT_PATH}" \
    "${UPDATE_TIMER_PATH}" \
    "${KEEPER_RUN_UNIT_PATH}" \
    "${KEEPER_UPDATE_UNIT_PATH}" \
    "${KEEPER_UPDATE_TIMER_PATH}"

  reload_user_systemd
  systemctl --user reset-failed >/dev/null 2>&1 || true
  log "Done. Runtime data remains in ${DATA_DIR}."
}

show_help() {
  sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d; s/^# \{0,1\}//; s/^#$//; p;}' "${BASH_SOURCE[0]}"
}

main() {
  parse_arguments "$@"
  local cmd="${COMMAND}"
  case "${cmd}" in
  -h | --help | help)
    show_help
    return 0
    ;;
  esac

  require_ubuntu
  detect_architecture
  require_user_systemd

  case "${cmd}" in
  install) cmd_install ;;
  update) cmd_update ;;
  start) start_service ;;
  stop) stop_service ;;
  restart) restart_service ;;
  status) status_service ;;
  uninstall) cmd_uninstall ;;
  keeper-install)
    require curl
    require tar
    install_manager_copy
    install_keeper
    ;;
  keeper-update) cmd_keeper_update ;;
  keeper-start) start_keeper ;;
  keeper-stop) stop_keeper ;;
  keeper-restart) restart_keeper ;;
  *)
    err "Unknown command: ${cmd}"
    err "Run '$(basename "${BASH_SOURCE[0]}") --help' for usage."
    exit 1
    ;;
  esac
}

main "$@"
