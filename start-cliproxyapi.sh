#!/usr/bin/env bash
#
# start-cliproxyapi.sh — install / update / run manager for CLIProxyAPI on macOS (Apple Silicon)
#
# What this script does:
#   1. Installs a LaunchAgent that checks the GitHub releases page every day at 10:00
#      for a newer macOS aarch64 build, downloads it into this repo, and restarts the service.
#   2. Downloads + replaces the local binary in this repo (downloads fresh if absent).
#   3. Restarts the local service (managed by a second "run" LaunchAgent with KeepAlive).
#   4. Creates a config.yaml in this repo if missing (api-keys: local-key,
#      remote-management.secret-key: local-key).
#   5. Stops and uninstalls any Homebrew-installed cliproxyapi (those lag behind upstream).
#   6. Installs the cpa-usage-keeper dashboard (https://github.com/Willxup/cpa-usage-keeper)
#      using the same release-download + LaunchAgent approach: it downloads the macOS
#      aarch64 build into this repo, writes a .env pointing it at the local CLIProxyAPI
#      (CPA_BASE_URL=http://127.0.0.1:8317, CPA_MANAGEMENT_KEY=local-key), serves the
#      dashboard on port 30000, and keeps it updated daily + running via KeepAlive.
#      It also flips usage-statistics-enabled: true in config.yaml, which the dashboard
#      requires to receive any usage data.
#
# Usage:
#   ./start-cliproxyapi.sh install     # full setup: purge brew, init config, install agents, download, start
#   ./start-cliproxyapi.sh update      # daily job: download newer release if any, then restart
#   ./start-cliproxyapi.sh start       # start the service
#   ./start-cliproxyapi.sh stop        # stop the service
#   ./start-cliproxyapi.sh restart     # restart the service
#   ./start-cliproxyapi.sh status      # show service + version status
#   ./start-cliproxyapi.sh uninstall   # remove LaunchAgents (keeps repo files)
#
# cpa-usage-keeper dashboard sub-commands (token-usage stats, port 30000):
#   ./start-cliproxyapi.sh keeper-install   # download dashboard, write .env, install agents, start
#   ./start-cliproxyapi.sh keeper-update    # daily job: download newer dashboard if any, restart
#   ./start-cliproxyapi.sh keeper-start     # start the dashboard
#   ./start-cliproxyapi.sh keeper-stop      # stop the dashboard
#   ./start-cliproxyapi.sh keeper-restart   # restart the dashboard
#
# Running with no argument is equivalent to "install" (which also installs the dashboard).
#
# All GitHub fetches (api.github.com queries + github.com release downloads, for both
# CLIProxyAPI and cpa-usage-keeper) go through an HTTP proxy: $http_proxy / $HTTP_PROXY
# if set, otherwise http://127.0.0.1:7890. The proxy is captured early and then ALL
# proxy env-vars (http_proxy, HTTPS_PROXY, ALL_PROXY, …) are unset so that the services
# we start (cli-proxy-api, cpa-usage-keeper) never inherit a proxy from this shell.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="cli-proxy-api"
BIN_PATH="${REPO_DIR}/${BIN_NAME}"
CONFIG_PATH="${REPO_DIR}/config.yaml"
VERSION_FILE="${REPO_DIR}/.cliproxyapi-version"
AUTH_DIR="${HOME}/.cli-proxy-api/"
LOG_DIR="${REPO_DIR}/logs"

GITHUB_REPO="router-for-me/CLIProxyAPI"
LATEST_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
ASSET_SUFFIX="darwin_aarch64.tar.gz"   # macOS Apple Silicon asset

# Proxy used only for GitHub fetches (api.github.com / github.com release downloads).
# Honor an existing http_proxy/HTTP_PROXY from the environment, else fall back to 7890.
GITHUB_PROXY="${http_proxy:-${HTTP_PROXY:-http://127.0.0.1:7890}}"

# Strip all proxy env-vars from this shell session NOW so that any service we
# start (cli-proxy-api, cpa-usage-keeper, launchctl, brew …) does NOT inherit
# them. GITHUB_PROXY above has already captured the value we need for gh_curl.
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY

LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
RUN_LABEL="me.router-for.cliproxyapi"
UPDATE_LABEL="me.router-for.cliproxyapi.update"
RUN_PLIST="${LAUNCH_AGENTS_DIR}/${RUN_LABEL}.plist"
UPDATE_PLIST="${LAUNCH_AGENTS_DIR}/${UPDATE_LABEL}.plist"

UPDATE_HOUR=10
UPDATE_MINUTE=0

# ---------------------------------------------------------------------------
# cpa-usage-keeper (token-usage dashboard) — same release/agent approach
# ---------------------------------------------------------------------------
KEEPER_BIN_NAME="cpa-usage-keeper"
KEEPER_BIN_PATH="${REPO_DIR}/${KEEPER_BIN_NAME}"
KEEPER_DATA_DIR="${REPO_DIR}/keeper-data"
# The keeper loads ".env" from its working directory; keep it inside the data dir so
# we run the binary from there and never touch any other .env in the repo.
KEEPER_ENV_PATH="${KEEPER_DATA_DIR}/.env"
KEEPER_VERSION_FILE="${REPO_DIR}/.cpa-usage-keeper-version"

KEEPER_GITHUB_REPO="Willxup/cpa-usage-keeper"
KEEPER_LATEST_API="https://api.github.com/repos/${KEEPER_GITHUB_REPO}/releases/latest"
KEEPER_ASSET_SUFFIX="darwin_arm64.tar.gz"   # macOS Apple Silicon asset

KEEPER_PORT=30000
# What the dashboard uses to reach the local CLIProxyAPI. CPA_MANAGEMENT_KEY must be the
# *plaintext* management key (config.yaml stores its bcrypt hash); we seeded "local-key".
KEEPER_CPA_BASE_URL="http://127.0.0.1:8317"
KEEPER_CPA_MANAGEMENT_KEY="local-key"

KEEPER_RUN_LABEL="me.willxup.cpa-usage-keeper"
KEEPER_UPDATE_LABEL="me.willxup.cpa-usage-keeper.update"
KEEPER_RUN_PLIST="${LAUNCH_AGENTS_DIR}/${KEEPER_RUN_LABEL}.plist"
KEEPER_UPDATE_PLIST="${LAUNCH_AGENTS_DIR}/${KEEPER_UPDATE_LABEL}.plist"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[0;32m[cliproxyapi]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[cliproxyapi]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[cliproxyapi]\033[0m %s\n' "$*" >&2; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command not found: $1"
    exit 1
  fi
}

# curl wrapper for GitHub fetches — routes through GITHUB_PROXY (env http_proxy/
# HTTP_PROXY if set, else http://127.0.0.1:7890). Pass through all caller args.
gh_curl() {
  if [[ -n "${GITHUB_PROXY}" ]]; then
    curl --proxy "${GITHUB_PROXY}" "$@"
  else
    curl "$@"
  fi
}

# ---------------------------------------------------------------------------
# 5. Purge any Homebrew-installed cliproxyapi
# ---------------------------------------------------------------------------
purge_homebrew() {
  if ! command -v brew >/dev/null 2>&1; then
    return 0
  fi
  if ! brew list --formula 2>/dev/null | grep -qx cliproxyapi; then
    log "No Homebrew cliproxyapi found — nothing to purge."
    return 0
  fi
  log "Found Homebrew cliproxyapi — stopping and uninstalling it."
  brew services stop cliproxyapi >/dev/null 2>&1 || true
  # Remove the brew-managed launch agent if it lingers.
  local brew_plist="${LAUNCH_AGENTS_DIR}/homebrew.mxcl.cliproxyapi.plist"
  if [[ -f "${brew_plist}" ]]; then
    launchctl bootout "gui/$(id -u)/homebrew.mxcl.cliproxyapi" >/dev/null 2>&1 || true
    launchctl unload "${brew_plist}" >/dev/null 2>&1 || true
    rm -f "${brew_plist}"
  fi
  brew uninstall --force cliproxyapi >/dev/null 2>&1 || warn "brew uninstall reported an issue (continuing)."
  log "Homebrew cliproxyapi removed."
}

# ---------------------------------------------------------------------------
# Release discovery
# ---------------------------------------------------------------------------
# Echoes "<tag>\t<download_url>" for the latest macOS aarch64 asset.
fetch_latest_release() {
  local json tag url
  json="$(gh_curl -fsSL "${LATEST_API}")" || { err "Failed to query GitHub releases API."; return 1; }

  tag="$(printf '%s' "${json}" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  url="$(printf '%s' "${json}" \
        | grep '"browser_download_url"' \
        | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/' \
        | grep "${ASSET_SUFFIX}$" \
        | grep -v 'no-plugin' \
        | head -n1)"

  if [[ -z "${tag}" || -z "${url}" ]]; then
    err "Could not determine latest version or macOS aarch64 asset URL."
    return 1
  fi
  printf '%s\t%s\n' "${tag}" "${url}"
}

local_version() {
  [[ -f "${VERSION_FILE}" ]] && cat "${VERSION_FILE}" || echo "none"
}

# ---------------------------------------------------------------------------
# 2. Download + replace the binary
# ---------------------------------------------------------------------------
download_binary() {
  local tag="$1" url="$2"
  local tmpdir rc=0
  tmpdir="$(mktemp -d)"

  log "Downloading ${tag} (${url##*/}) ..."
  if ! gh_curl -fsSL "${url}" -o "${tmpdir}/release.tar.gz"; then
    err "Download failed."; rm -rf "${tmpdir}"; return 1
  fi
  if ! tar -xzf "${tmpdir}/release.tar.gz" -C "${tmpdir}"; then
    err "Extraction failed."; rm -rf "${tmpdir}"; return 1
  fi

  local extracted
  extracted="$(find "${tmpdir}" -type f -name "${BIN_NAME}" | head -n1)"
  if [[ -z "${extracted}" ]]; then
    err "Binary '${BIN_NAME}' not found inside the release archive."
    rm -rf "${tmpdir}"; return 1
  fi

  chmod +x "${extracted}"
  mv -f "${extracted}" "${BIN_PATH}"
  echo "${tag}" > "${VERSION_FILE}"
  rm -rf "${tmpdir}"
  log "Installed ${BIN_NAME} ${tag} at ${BIN_PATH}"
  return ${rc}
}

# ---------------------------------------------------------------------------
# 6. cpa-usage-keeper: release discovery + download (mirrors the CPA flow)
# ---------------------------------------------------------------------------
# Echoes "<tag>\t<download_url>" for the latest macOS aarch64 keeper asset.
fetch_latest_keeper_release() {
  local json tag url
  json="$(gh_curl -fsSL "${KEEPER_LATEST_API}")" || { err "Failed to query cpa-usage-keeper releases API."; return 1; }

  tag="$(printf '%s' "${json}" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  url="$(printf '%s' "${json}" \
        | grep '"browser_download_url"' \
        | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/' \
        | grep "${KEEPER_ASSET_SUFFIX}$" \
        | head -n1)"

  if [[ -z "${tag}" || -z "${url}" ]]; then
    err "Could not determine latest cpa-usage-keeper version or macOS aarch64 asset URL."
    return 1
  fi
  printf '%s\t%s\n' "${tag}" "${url}"
}

keeper_local_version() {
  [[ -f "${KEEPER_VERSION_FILE}" ]] && cat "${KEEPER_VERSION_FILE}" || echo "none"
}

download_keeper_binary() {
  local tag="$1" url="$2"
  local tmpdir
  tmpdir="$(mktemp -d)"

  log "Downloading cpa-usage-keeper ${tag} (${url##*/}) ..."
  if ! gh_curl -fsSL "${url}" -o "${tmpdir}/release.tar.gz"; then
    err "Keeper download failed."; rm -rf "${tmpdir}"; return 1
  fi
  if ! tar -xzf "${tmpdir}/release.tar.gz" -C "${tmpdir}"; then
    err "Keeper extraction failed."; rm -rf "${tmpdir}"; return 1
  fi

  # The archive nests the binary under a versioned dir; find it anywhere inside.
  local extracted
  extracted="$(find "${tmpdir}" -type f -name "${KEEPER_BIN_NAME}" | head -n1)"
  if [[ -z "${extracted}" ]]; then
    err "Binary '${KEEPER_BIN_NAME}' not found inside the keeper release archive."
    rm -rf "${tmpdir}"; return 1
  fi

  chmod +x "${extracted}"
  mv -f "${extracted}" "${KEEPER_BIN_PATH}"
  echo "${tag}" > "${KEEPER_VERSION_FILE}"
  rm -rf "${tmpdir}"
  log "Installed ${KEEPER_BIN_NAME} ${tag} at ${KEEPER_BIN_PATH}"
}

# ---------------------------------------------------------------------------
# 4. Ensure config.yaml exists
# ---------------------------------------------------------------------------
ensure_config() {
  if [[ -f "${CONFIG_PATH}" ]]; then
    log "config.yaml already exists — leaving it untouched."
    return 0
  fi
  log "config.yaml not found — creating a default one."
  cat > "${CONFIG_PATH}" <<EOF
# CLIProxyAPI config — tuned for low-latency Codex (GPT-5.x) forwarding.
# Generated/updated by start-cliproxyapi.sh. Full reference: https://help.router-for.me/
#
# Optimization goal: make Codex feel fast WITHOUT changing request semantics or cost.
# We deliberately do NOT force \`reasoning.effort\` and do NOT inject \`service_tier\`
# (those are quality/cost tradeoffs the client/user controls). Everything below is
# pure overhead/stall reduction and better credential reuse.

# Bind to localhost only by default.
host: "127.0.0.1"
port: 8317
# Authentication directory for OAuth/credential files.
auth-dir: "${AUTH_DIR}"
# API keys clients must present to use the proxy.
api-keys:
  - local-key
# Management API (control panel / remote management).
remote-management:
  allow-remote: true
  secret-key: "local-key"
debug: true
# --------------------------------------------------------------------------
# Streaming stability — biggest perceived-latency / reliability fix for Codex.
# Codex CLI is sensitive to the first SSE byte and to idle gaps; without
# keepalives a slow "thinking" phase looks like a hang and can surface as 502s
# (see CLIProxyAPI issues #2401 / discussions). Keepalives emit SSE comments so
# the connection stays warm and the client keeps reading.
# --------------------------------------------------------------------------
streaming:
  keepalive-seconds: 15 # emit SSE keep-alive every 15s during long thinking
  bootstrap-retries: 1 # retry once before the first byte is sent (transient upstream blips)
# For non-streaming Codex requests, emit blank lines so upstream/idle timeouts
# don't kill a long generation.
nonstream-keepalive-interval: 15
# --------------------------------------------------------------------------
# Per-request overhead — drop high-overhead request logging + middleware.
# Lowers CPU/memory work per request, which helps under concurrency.
# --------------------------------------------------------------------------
commercial-mode: true
# In-memory usage stats aggregation (required by cpa-usage-keeper dashboard).
usage-statistics-enabled: true
# pprof debug server off.
pprof:
  enable: false
  addr: "127.0.0.1:8316"
# --------------------------------------------------------------------------
# Retry / cooldown — fail fast instead of stalling on cooled-down credentials.
# A request that lands on a cooling credential otherwise waits out the cooldown.
# --------------------------------------------------------------------------
request-retry: 2 # retry transient 403/408/5xx a couple of times (default 3)
max-retry-credentials: 2 # try at most 2 different creds before giving up (don't sweep all)
max-retry-interval: 8 # wait at most 8s for a cooled cred before triggering retry (default 30)
transient-error-cooldown-seconds: -1 # don't blackout a cred after a transient 408/5xx; keep it usable
# --------------------------------------------------------------------------
# Routing — keep a conversation pinned to one warm credential.
# fill-first + session-affinity maximizes OpenAI-side prompt-cache hits for a
# Codex session (cached prefix => faster + cheaper), with automatic failover
# if the bound credential becomes unavailable.
# --------------------------------------------------------------------------
routing:
  strategy: "fill-first"
  session-affinity: true
  session-affinity-ttl: "2h"
# Codex provider behavior. identity-confuse remaps per-auth identity when using
# fill-first/affinity; leave default unless you specifically need it.
codex:
  identity-confuse: false
# Quota handling: keep auto-switching so a quota hit doesn't block the request.
quota-exceeded:
  switch-project: true
  switch-preview-model: true
  antigravity-credits: true
redis-usage-queue-retention-seconds: 60
# --------------------------------------------------------------------------
# Anthropic-compatible upstreams. Replace REPLACE_ME with your real api-key.
# Clients hit POST http://127.0.0.1:8317/v1/messages and pick a model by its
# alias below (e.g. model: "glm" or "minimax").
# --------------------------------------------------------------------------
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

# --------------------------------------------------------------------------
# Payload tuning (intentionally minimal).
# We do NOT override reasoning.effort or service_tier per choice. If you later
# want a "fast lane", uncomment ONE of the blocks below:
#
# (a) Force lower reasoning effort for all Codex gpt-* models (faster, less deep):
# payload:
#   override:
#     - models:
#         - name: "gpt-*"
#           protocol: "codex"
#       params:
#         "reasoning.effort": "medium"
#
# (b) Use OpenAI Priority processing (needs paid Priority access; lower latency):
# payload:
#   override:
#     - models:
#         - name: "gpt-*"
#           protocol: "codex"
#       params:
#         service_tier: "priority"
# --------------------------------------------------------------------------
EOF
  log "Wrote ${CONFIG_PATH} (api-key: local-key, management secret-key: local-key)."
  log "NOTE: edit claude-api-key REPLACE_ME_* values before using the Anthropic endpoint."
}

# The dashboard only sees data when CPA emits usage stats. Flip the flag on if it's
# off, so cpa-usage-keeper has something to persist. Idempotent.
ensure_usage_statistics_enabled() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    return 0
  fi
  if grep -Eq '^[[:space:]]*usage-statistics-enabled:[[:space:]]*true' "${CONFIG_PATH}"; then
    log "usage-statistics-enabled already true in config.yaml."
    return 0
  fi
  if grep -Eq '^[[:space:]]*usage-statistics-enabled:' "${CONFIG_PATH}"; then
    # Flip an existing false (or other value) to true, preserving any trailing comment.
    sed -E -i '' 's/^([[:space:]]*usage-statistics-enabled:[[:space:]]*)[^[:space:]#]+(.*)$/\1true\2/' "${CONFIG_PATH}"
    log "Set usage-statistics-enabled: true in config.yaml (required by cpa-usage-keeper)."
  else
    printf '\n# Enabled so cpa-usage-keeper can persist token usage.\nusage-statistics-enabled: true\n' >> "${CONFIG_PATH}"
    log "Appended usage-statistics-enabled: true to config.yaml (required by cpa-usage-keeper)."
  fi
}

# ---------------------------------------------------------------------------
# 6. Ensure the cpa-usage-keeper .env exists (points it at the local CPA)
# ---------------------------------------------------------------------------
ensure_keeper_env() {
  mkdir -p "${KEEPER_DATA_DIR}"
  if [[ -f "${KEEPER_ENV_PATH}" ]]; then
    log "cpa-usage-keeper .env already exists — leaving it untouched."
    return 0
  fi
  log "cpa-usage-keeper .env not found — creating one."
  cat > "${KEEPER_ENV_PATH}" <<EOF
# cpa-usage-keeper config generated by start-cliproxyapi.sh
# Full reference: https://github.com/Willxup/cpa-usage-keeper

# Where the dashboard reaches the local CLIProxyAPI (server-side only).
CPA_BASE_URL=${KEEPER_CPA_BASE_URL}

# CPA management key (plaintext). config.yaml stores its bcrypt hash; we seeded "local-key".
CPA_MANAGEMENT_KEY=${KEEPER_CPA_MANAGEMENT_KEY}

# Dashboard HTTP port.
APP_PORT=${KEEPER_PORT}

# SQLite DB, logs, and backups live here (resolved against this .env's directory).
WORK_DIR=.

# Local-only deployment: no login wall.
AUTH_ENABLED=false

TZ=Asia/Shanghai
EOF
  log "Wrote ${KEEPER_ENV_PATH} (CPA ${KEEPER_CPA_BASE_URL}, dashboard port ${KEEPER_PORT})."
}

# ---------------------------------------------------------------------------
# 1 + 3. LaunchAgents: run service (KeepAlive) + daily updater at 10:00
# ---------------------------------------------------------------------------
write_run_plist() {
  mkdir -p "${LAUNCH_AGENTS_DIR}" "${LOG_DIR}"
  cat > "${RUN_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${RUN_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN_PATH}</string>
        <string>-config</string>
        <string>${CONFIG_PATH}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/cliproxyapi.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/cliproxyapi.err.log</string>
</dict>
</plist>
EOF
  log "Wrote run LaunchAgent: ${RUN_PLIST}"
}

write_update_plist() {
  mkdir -p "${LAUNCH_AGENTS_DIR}" "${LOG_DIR}"
  cat > "${UPDATE_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${UPDATE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${REPO_DIR}/$(basename "${BASH_SOURCE[0]}")</string>
        <string>update</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_DIR}</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${UPDATE_HOUR}</integer>
        <key>Minute</key>
        <integer>${UPDATE_MINUTE}</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/cliproxyapi.update.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/cliproxyapi.update.log</string>
</dict>
</plist>
EOF
  log "Wrote daily-updater LaunchAgent (10:00): ${UPDATE_PLIST}"
}

write_keeper_run_plist() {
  mkdir -p "${LAUNCH_AGENTS_DIR}" "${LOG_DIR}" "${KEEPER_DATA_DIR}"
  cat > "${KEEPER_RUN_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${KEEPER_RUN_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${KEEPER_BIN_PATH}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${KEEPER_DATA_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/cpa-usage-keeper.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/cpa-usage-keeper.err.log</string>
</dict>
</plist>
EOF
  log "Wrote cpa-usage-keeper run LaunchAgent: ${KEEPER_RUN_PLIST}"
}

write_keeper_update_plist() {
  mkdir -p "${LAUNCH_AGENTS_DIR}" "${LOG_DIR}"
  cat > "${KEEPER_UPDATE_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${KEEPER_UPDATE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${REPO_DIR}/$(basename "${BASH_SOURCE[0]}")</string>
        <string>keeper-update</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${REPO_DIR}</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>${UPDATE_HOUR}</integer>
        <key>Minute</key>
        <integer>${UPDATE_MINUTE}</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/cpa-usage-keeper.update.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/cpa-usage-keeper.update.log</string>
</dict>
</plist>
EOF
  log "Wrote cpa-usage-keeper daily-updater LaunchAgent (10:00): ${KEEPER_UPDATE_PLIST}"
}

load_agent() {
  local label="$1" plist="$2"
  local domain="gui/$(id -u)"
  # bootout first to make this idempotent, then bootstrap.
  launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
  launchctl bootstrap "${domain}" "${plist}" >/dev/null 2>&1 \
    || launchctl load "${plist}" >/dev/null 2>&1 \
    || { err "Failed to load LaunchAgent ${label}"; return 1; }
}

unload_agent() {
  local label="$1" plist="$2"
  local domain="gui/$(id -u)"
  launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || launchctl unload "${plist}" >/dev/null 2>&1 || true
  # Give launchd a moment to fully tear the job down so an immediate re-bootstrap
  # (restart) doesn't race the old process still holding its listen port.
  local i
  for i in 1 2 3 4 5; do
    launchctl print "${domain}/${label}" >/dev/null 2>&1 || break
    sleep 1
  done
}

# ---------------------------------------------------------------------------
# Service control
# ---------------------------------------------------------------------------
start_service() {
  if [[ ! -f "${RUN_PLIST}" ]]; then write_run_plist; fi
  load_agent "${RUN_LABEL}" "${RUN_PLIST}"
  log "Service started (LaunchAgent ${RUN_LABEL})."
}

stop_service() {
  unload_agent "${RUN_LABEL}" "${RUN_PLIST}"
  log "Service stopped."
}

restart_service() {
  log "Restarting service ..."
  stop_service
  start_service
}

start_keeper() {
  if [[ ! -f "${KEEPER_RUN_PLIST}" ]]; then write_keeper_run_plist; fi
  load_agent "${KEEPER_RUN_LABEL}" "${KEEPER_RUN_PLIST}"
  log "Dashboard started (LaunchAgent ${KEEPER_RUN_LABEL}) — http://127.0.0.1:${KEEPER_PORT}"
}

stop_keeper() {
  unload_agent "${KEEPER_RUN_LABEL}" "${KEEPER_RUN_PLIST}"
  log "Dashboard stopped."
}

restart_keeper() {
  log "Restarting dashboard ..."
  stop_keeper
  start_keeper
}

status_service() {
  log "Local version:  $(local_version)"
  log "Binary:         ${BIN_PATH} $( [[ -x "${BIN_PATH}" ]] && echo '(present)' || echo '(MISSING)')"
  log "Config:         ${CONFIG_PATH} $( [[ -f "${CONFIG_PATH}" ]] && echo '(present)' || echo '(MISSING)')"
  if launchctl print "gui/$(id -u)/${RUN_LABEL}" >/dev/null 2>&1; then
    log "Run agent:      loaded (${RUN_LABEL})"
  else
    log "Run agent:      not loaded"
  fi
  if launchctl print "gui/$(id -u)/${UPDATE_LABEL}" >/dev/null 2>&1; then
    log "Update agent:   loaded (daily 10:00)"
  else
    log "Update agent:   not loaded"
  fi
  log "--- cpa-usage-keeper (dashboard) ---"
  log "Keeper version: $(keeper_local_version)"
  log "Keeper binary:  ${KEEPER_BIN_PATH} $( [[ -x "${KEEPER_BIN_PATH}" ]] && echo '(present)' || echo '(MISSING)')"
  log "Keeper env:     ${KEEPER_ENV_PATH} $( [[ -f "${KEEPER_ENV_PATH}" ]] && echo '(present)' || echo '(MISSING)')"
  log "Dashboard URL:  http://127.0.0.1:${KEEPER_PORT}"
  if launchctl print "gui/$(id -u)/${KEEPER_RUN_LABEL}" >/dev/null 2>&1; then
    log "Keeper run:     loaded (${KEEPER_RUN_LABEL})"
  else
    log "Keeper run:     not loaded"
  fi
  if launchctl print "gui/$(id -u)/${KEEPER_UPDATE_LABEL}" >/dev/null 2>&1; then
    log "Keeper update:  loaded (daily 10:00)"
  else
    log "Keeper update:  not loaded"
  fi
}

# ---------------------------------------------------------------------------
# Core flows
# ---------------------------------------------------------------------------
# Returns 0 (and downloads) if an update was applied; 1 if already up to date.
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
  return 0
}

# Returns 0 (and downloads) if a keeper update was applied; 1 if already up to date.
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
  return 0
}

cmd_install() {
  require curl
  require tar
  log "=== Installing CLIProxyAPI manager (repo: ${REPO_DIR}) ==="

  purge_homebrew                 # 5
  ensure_config                  # 4
  ensure_usage_statistics_enabled  # 6 prerequisite: dashboard needs usage stats on

  # 2: download (fresh if missing, or latest)
  if do_update_check; then :; else
    if [[ ! -x "${BIN_PATH}" ]]; then
      err "No binary present and update check failed — cannot start."
      exit 1
    fi
  fi

  write_run_plist                # service definition
  write_update_plist             # 1: daily 10:00 updater

  load_agent "${UPDATE_LABEL}" "${UPDATE_PLIST}"
  start_service                  # 3 (initial start)

  # 6: cpa-usage-keeper dashboard (same download/agent approach)
  install_keeper

  log "=== Done. CPA on port 8317; dashboard on http://127.0.0.1:${KEEPER_PORT}. ==="
  status_service
}

# 6. Install the dashboard: env, download, agents, start. Tolerant of network
# failure when a binary is already present so a flaky run doesn't abort install.
install_keeper() {
  log "--- Installing cpa-usage-keeper dashboard ---"
  ensure_keeper_env
  if do_keeper_update_check; then :; else
    if [[ ! -x "${KEEPER_BIN_PATH}" ]]; then
      err "No cpa-usage-keeper binary present and update check failed — skipping dashboard."
      return 1
    fi
  fi
  write_keeper_run_plist
  write_keeper_update_plist
  load_agent "${KEEPER_UPDATE_LABEL}" "${KEEPER_UPDATE_PLIST}"
  start_keeper
}

cmd_update() {
  require curl
  require tar
  log "=== Daily update check ==="
  ensure_config
  local rc=0
  do_update_check || rc=$?
  case "${rc}" in
    0) log "New version installed — restarting service."; restart_service ;;   # 3
    1) log "No update; leaving running service as-is." ;;
    *) err "Update check failed (network/API error). Will retry next run." ; exit 1 ;;
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
    0) log "New dashboard version installed — restarting dashboard."; restart_keeper ;;
    1) log "No dashboard update; leaving it running as-is." ;;
    *) err "Dashboard update check failed (network/API error). Will retry next run." ; exit 1 ;;
  esac
}

cmd_uninstall() {
  log "Removing LaunchAgents (repo files kept)."
  unload_agent "${RUN_LABEL}" "${RUN_PLIST}"
  unload_agent "${UPDATE_LABEL}" "${UPDATE_PLIST}"
  unload_agent "${KEEPER_RUN_LABEL}" "${KEEPER_RUN_PLIST}"
  unload_agent "${KEEPER_UPDATE_LABEL}" "${KEEPER_UPDATE_PLIST}"
  rm -f "${RUN_PLIST}" "${UPDATE_PLIST}" "${KEEPER_RUN_PLIST}" "${KEEPER_UPDATE_PLIST}"
  log "Done."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-install}"
  case "${cmd}" in
    install)        cmd_install ;;
    update)         cmd_update ;;
    start)          start_service ;;
    stop)           stop_service ;;
    restart)        restart_service ;;
    status)         status_service ;;
    uninstall)      cmd_uninstall ;;
    keeper-install) require curl; require tar; install_keeper ;;
    keeper-update)  cmd_keeper_update ;;
    keeper-start)   start_keeper ;;
    keeper-stop)    stop_keeper ;;
    keeper-restart) restart_keeper ;;
    -h|--help|help)
      # Print the header doc-block (everything before "set -euo pipefail").
      sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d; s/^# \{0,1\}//; s/^#$//; p;}' "${BASH_SOURCE[0]}" ;;
    *)
      err "Unknown command: ${cmd}"
      err "Run '$(basename "${BASH_SOURCE[0]}") --help' for usage."
      exit 1 ;;
  esac
}

main "$@"
