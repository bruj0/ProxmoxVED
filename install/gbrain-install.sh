#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: bruj0
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/garrytan/gbrain | Github (fork): https://github.com/bruj0/gbrain

# Pull in core.func helpers (msg_info, msg_ok, msg_warn, msg_error, color, $STD, etc.).
# When invoked via ProxmoxVED's build.func this is a no-op (already sourced); when run
# standalone (e.g. curl | bash) we fetch the same file directly.
if ! declare -f msg_info >/dev/null 2>&1; then
  source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/core/main/core/core.func)
  load_functions
  # Standalone-mode safety: msg_error is non-fatal without catch_errors, so trap exits.
  trap 'exit 1' ERR
fi
color

# Pull in db.func for setup_postgresql / setup_postgresql_db. Skipped when the
# helpers already exist (ProxmoxVED's build.func loads them globally).
if ! declare -f setup_postgresql >/dev/null 2>&1; then
  source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/core/main/lib/db.func) \
    || msg_error "Failed to fetch db.func from community-scripts/core"
fi

# ----- App-specific work below -----

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential \
  git \
  openssl \
  socat \
  ca-certificates \
  curl \
  unzip
msg_ok "Installed Dependencies"

msg_info "Creating GBrain Service User"
useradd -m -s /bin/bash -d /home/gbrain gbrain 2>/dev/null || true
msg_ok "Created GBrain User"

msg_info "Installing Bun Runtime"
export BUN_INSTALL="/home/gbrain/.bun"
curl -fsSL https://bun.sh/install | BUN_INSTALL="$BUN_INSTALL" bash
chown -R gbrain:gbrain /home/gbrain/.bun
msg_ok "Installed Bun"

# Install the gbrain CLI. Per gbrain INSTALL_FOR_AGENTS.md the canonical path
# is `bun install -g github:garrytan/gbrain`; we honour a configurable repo/ref
# and fall back to downloading the pre-built GitHub release binary if the
# global install doesn't materialize a working `gbrain` on PATH (e.g. due to
# the postinstall-hook race documented in #218). Source build is the last
# resort because it pulls the entire repo (~150 MB) and a Bun toolchain.

# Pinned version (release tag). Override at runtime with var_gbrain_pinned_version.
GBRAIN_PINNED_VERSION="${GBRAIN_PINNED_VERSION:-v0.59.0.0}"

# Repo / ref (used by source-build method). Override via var_gbrain_repo / var_gbrain_ref.
GBRAIN_REPO="${GBRAIN_REPO:-garrytan/gbrain}"
GBRAIN_REF="${GBRAIN_REF:-latest-stable}"
GBRAIN_HOME_DIR="${GBRAIN_HOME:-/home/gbrain/projects/gbrain}"

# Pick install method:
#   release = download pinned release binary (recommended; deterministic, fast)
#   bun     = bun install -g github:<repo>#<ref>           (upstream's documented path)
#   source  = git clone + bun run build                    (last resort, slow)
if [[ -z "${var_gbrain_install_method:-}" ]]; then
  if [[ -t 0 ]]; then
    echo -e "\n${TAB3}${YW}How should gbrain be installed?${CL}"
    echo -e "${TAB3}${YW}  [1] release  — download pinned release ${GBRAIN_PINNED_VERSION} (recommended)${CL}"
    echo -e "${TAB3}${YW}  [2] bun      — bun install -g github:${GBRAIN_REPO}#${GBRAIN_REF}${CL}"
    echo -e "${TAB3}${YW}  [3] source   — clone + build from source${CL}"
    read -r -p "${TAB3}Choice [1/2/3] (default 1): " var_gbrain_install_method
  else
    var_gbrain_install_method=1
  fi
fi
case "${var_gbrain_install_method:-1}" in
  2|GBRAIN_INSTALL_METHOD_BUN|bun)     var_gbrain_install_method=bun ;;
  3|GBRAIN_INSTALL_METHOD_SOURCE|source) var_gbrain_install_method=source ;;
  1|GBRAIN_INSTALL_METHOD_RELEASE|""|release) var_gbrain_install_method=release ;;
  *) msg_error "Invalid install method: ${var_gbrain_install_method}"; exit 1 ;;
esac

# Method 1 (preferred): GitHub release binary, pinned to GBRAIN_PINNED_VERSION
if [[ "${var_gbrain_install_method}" == "release" ]]; then
  msg_info "Fetching GBrain release binary ${GBRAIN_PINNED_VERSION} from github:${GBRAIN_REPO}"
  mkdir -p /home/gbrain/.bun/bin
  chown -R gbrain:gbrain /home/gbrain/.bun
  RELEASE_URL="https://github.com/${GBRAIN_REPO}/releases/download/${GBRAIN_PINNED_VERSION}/gbrain-linux-x64"
  if sudo -u gbrain bash -c "curl -fsSL --retry 3 -o /home/gbrain/.bun/bin/gbrain '${RELEASE_URL}' && chmod +x /home/gbrain/.bun/bin/gbrain"; then
    msg_ok "Installed GBrain ${GBRAIN_PINNED_VERSION} (release binary)"
    GBRAIN_BIN_METHOD=release
  else
    msg_warn "Release binary not found for ${GBRAIN_PINNED_VERSION}; switching to source build"
    var_gbrain_install_method=source
  fi
fi

# Method 2: bun install -g github:<repo>#<ref>
if [[ "${var_gbrain_install_method}" == "bun" ]]; then
  msg_info "Installing GBrain via bun (github:${GBRAIN_REPO}#${GBRAIN_REF})"
  if sudo -u gbrain bash -c "export BUN_INSTALL=/home/gbrain/.bun && export PATH=/home/gbrain/.bun/bin:\$PATH && cd /tmp && bun install -g \"github:${GBRAIN_REPO}#${GBRAIN_REF}\"" 2>/dev/null; then
    if sudo -u gbrain bash -c "export PATH=/home/gbrain/.bun/bin:\$PATH && command -v gbrain >/dev/null"; then
      msg_ok "Installed GBrain via bun global"
      GBRAIN_BIN_METHOD=bun
    else
      msg_warn "bun install completed but no gbrain on PATH; switching to source build"
      var_gbrain_install_method=source
    fi
  else
    msg_warn "bun install failed; switching to source build"
    var_gbrain_install_method=source
  fi
fi

# Method 3: source build
if [[ "${var_gbrain_install_method}" == "source" ]]; then
  msg_info "Cloning GBrain repository for source build (ref=${GBRAIN_REF})"
  $STD sudo -u gbrain bash -c "git clone \"https://github.com/${GBRAIN_REPO}.git\" --branch \"${GBRAIN_REF}\" --depth 1 ${GBRAIN_HOME_DIR}"
  msg_ok "Cloned GBrain"

  msg_info "Building GBrain from source"
  cd "${GBRAIN_HOME_DIR}"
  $STD sudo -u gbrain bash -c "export PATH=/home/gbrain/.bun/bin:\$PATH && bun install"
  $STD sudo -u gbrain bash -c "export PATH=/home/gbrain/.bun/bin:\$PATH && bun run --bun build"
  install -m 0755 bin/gbrain /home/gbrain/.bun/bin/gbrain
  chown -R gbrain:gbrain "${GBRAIN_HOME_DIR}" /home/gbrain/.bun
  msg_ok "Built GBrain from source"
  GBRAIN_BIN_METHOD=source
fi

# Initialise the brain. PGLite is the zero-config Postgres-17-WASM engine
# gbrain ships with — matches INSTALL_FOR_AGENTS.md "lighter ways in" path.
# No external Postgres or Docker required. --no-embedding keeps it keyless;
# Voyage/OpenAI config is explicit opt-in later. The init creates
# ~/.gbrain/brain.pglite and ~/.gbrain/config.json; the engine is
# single-process so a single `gbrain serve` owns the data dir lock.
# `gbrain init` itself runs Step 3.5 (search mode prompt) on a TTY, or
# defaults to tokenmax otherwise. Override the search mode via
# var_gbrain_search_mode=conservative|balanced|tokenmax before running.
GBRAIN_SEARCH_MODE="${var_gbrain_search_mode:-}"
if [[ -n "${GBRAIN_SEARCH_MODE}" ]]; then
  msg_info "Pre-setting gbrain search.mode=${GBRAIN_SEARCH_MODE}"
fi
msg_info "Initialising GBrain (PGLite, keyless)"
$STD sudo -u gbrain bash -lc "PATH=/home/gbrain/.bun/bin:\$PATH gbrain init --pglite --no-embedding"
msg_ok "Initialised GBrain"

if [[ -n "${GBRAIN_SEARCH_MODE}" ]]; then
  $STD sudo -u gbrain bash -lc "PATH=/home/gbrain/.bun/bin:\$PATH gbrain config set search.mode ${GBRAIN_SEARCH_MODE}"
fi

# Initialise the brain. PGLite is the zero-config default per
# INSTALL_FOR_AGENTS.md (no external Postgres, no Docker required).
# --no-embedding keeps it keyless; Voyage/OpenAI config is explicit opt-in later.
# `gbrain init` itself runs Step 3.5 (search mode prompt) on a TTY, or
# defaults to tokenmax otherwise. Override the search mode via
# var_gbrain_search_mode=conservative|balanced|tokenmax before running.
GBRAIN_SEARCH_MODE="${var_gbrain_search_mode:-}"
if [[ -n "${GBRAIN_SEARCH_MODE}" ]]; then
  msg_info "Pre-setting gbrain search.mode=${GBRAIN_SEARCH_MODE}"
fi
$STD sudo -u gbrain bash -lc "PATH=/home/gbrain/.bun/bin:\$PATH gbrain init --pglite --no-embedding"
msg_ok "Initialised GBrain"

# Apply the search mode choice if preset (gbrain init runs its own prompt on a TTY).
if [[ -n "${GBRAIN_SEARCH_MODE}" ]]; then
  $STD sudo -u gbrain bash -lc "PATH=/home/gbrain/.bun/bin:\$PATH gbrain config set search.mode ${GBRAIN_SEARCH_MODE}"
fi

# Verify health. The doctor command is engine-free (it works even with the
# DB down) — non-zero exit means real warnings worth reading.
msg_info "Running gbrain doctor"
sudo -u gbrain bash -lc "PATH=/home/gbrain/.bun/bin:\$PATH gbrain doctor" || msg_warn "gbrain doctor reported warnings — review with: sudo -u gbrain gbrain doctor"
msg_ok "Verified GBrain"

msg_info "Preparing GBrain Directories"
mkdir -p /home/gbrain/.gbrain/{audit,backups,content,integrations,migrations,persistence,run,workers,content_root}
chown -R gbrain:gbrain /home/gbrain/.gbrain
chmod 700 /home/gbrain/.gbrain
msg_ok "Prepared Directories"

msg_info "Enabling Linger for User Services"
$STD loginctl enable-linger gbrain
msg_ok "Enabled Linger"

msg_info "Writing GBrain Shell Env"
# gbrain init wrote the engine + DB config into ~/.gbrain/config.json and
# ~/.gbrain/env. This .env only adds the public URL (OAuth issuer) and CORS
# origins. CRITICAL: must be systemd EnvironmentFile-safe — only KEY=VALUE
# lines, no shell-style comments or `export` prefix. systemd treats every
# non-parseable line as a fatal error for that directive.
GBRAIN_PUBLIC_URL_EFFECTIVE="${var_gbrain_public_url:-https://$(hostname -I 2>/dev/null | awk '{print $1}'):8443}"
[[ "${GBRAIN_PUBLIC_URL_EFFECTIVE}" == "https://:8443" ]] && GBRAIN_PUBLIC_URL_EFFECTIVE="https://127.0.0.1:8443"
cat >/home/gbrain/.gbrain/.env <<ENV
GBRAIN_HOME=/home/gbrain
GBRAIN_PUBLIC_URL=${GBRAIN_PUBLIC_URL_EFFECTIVE}
GBRAIN_HTTP_CORS_ORIGIN=${var_gbrain_cors_origin:-}
GBRAIN_NO_AUTOPILOT_INSTALL=1
GBRAIN_NO_REEMBED=1
ENV
chown gbrain:gbrain /home/gbrain/.gbrain/.env
chmod 600 /home/gbrain/.gbrain/.env
msg_ok "Wrote Shell Env"

msg_info "Creating systemd-user Services"
mkdir -p /home/gbrain/.config/systemd/user
chown -R gbrain:gbrain /home/gbrain/.config

# 1. gbrain-mcp.service
# WorkingDirectory intentionally left unset: the release install doesn't clone
# the source repo, so /home/gbrain/projects/gbrain doesn't exist. gbrain reads
# its config from GBRAIN_HOME, not from a project tree.
# systemd does NOT expand $VAR/${VAR} in ExecStart (only its own %H/%i
# specifiers), so the public URL is baked into the unit literal at install time.
# Default = the LXC's primary auto-detected IP on port 8443 (TLS relay).
# Override with var_gbrain_public_url=https://your.host:port before running.
GBRAIN_PUBLIC_URL_EFFECTIVE="${var_gbrain_public_url:-https://$(hostname -I 2>/dev/null | awk '{print $1}'):8443}"
[[ "${GBRAIN_PUBLIC_URL_EFFECTIVE}" == "https://:8443" ]] && GBRAIN_PUBLIC_URL_EFFECTIVE="https://127.0.0.1:8443"
cat >/home/gbrain/.config/systemd/user/gbrain-mcp.service <<UNIT
[Unit]
Description=GBrain MCP HTTP server
After=network-online.target

[Service]
Type=simple
ExecStart=/home/gbrain/.bun/bin/gbrain serve --http --bind 0.0.0.0 --public-url ${GBRAIN_PUBLIC_URL_EFFECTIVE} --enable-dcr --port 9119
Restart=on-failure
RestartSec=5
EnvironmentFile=-%h/.gbrain/.env
# GBRAIN_HOME is the parent of .gbrain (per gbrain docs: "GBRAIN_HOME is the
# parent of .gbrain, not .gbrain itself"). %h already expands to the user's
# home directory, so GBRAIN_HOME=%h resolves to /home/gbrain.
Environment=GBRAIN_HOME=%h
Environment=PATH=%h/.bun/bin:/usr/local/bin:/usr/bin:/bin
Environment=XDG_RUNTIME_DIR=/run/user/%U

[Install]
WantedBy=default.target
UNIT

# 2. gbrain-tls-relay.service (optional; requires /home/gbrain/.gbrain/tls/cert.pem + key.pem)
cat >/home/gbrain/.config/systemd/user/gbrain-tls-relay.service <<'UNIT'
[Unit]
Description=GBrain TLS relay (HTTPS:8443 -> HTTP:9119)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat -d OPENSSL-LISTEN:8443,reuseaddr,fork,bind=0.0.0.0,cert=%h/.gbrain/tls/cert.pem,key=%h/.gbrain/tls/key.pem,verify=0 TCP:127.0.0.1:9119
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT

# Hand unit files back to the gbrain user so systemctl --user can manage them.
chown -R gbrain:gbrain /home/gbrain/.config
msg_ok "Created systemd-user Services"

# motd_ssh / customize are no-ops in standalone mode (provided by build.func in
# ProxmoxVED). cleanup_lxc ships in core.func and is always safe to call.
declare -f cleanup_lxc >/dev/null 2>&1 && cleanup_lxc
