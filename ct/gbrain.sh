#!/usr/bin/env bash
# Pre-stage the gbrain banner header so the engine's get_header() call
# doesn't 404 (community-scripts/core has no entry for gbrain yet).
_cs_header_dir="/usr/local/community-scripts/headers/ct"
mkdir -p "$_cs_header_dir"
_cs_header_path="${COMMUNITY_SCRIPTS_HEADER_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../headers/ct}/gbrain"
if [[ -s "$_cs_header_path" ]]; then
  install -m 0644 "$_cs_header_path" "$_cs_header_dir/gbrain"
fi

_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: bruj0
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/garrytan/gbrain | Github (fork): https://github.com/bruj0/gbrain

APP="GBrain"
var_tags="${var_tags:-ai;knowledge;memory;mcp;vector}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-50}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_gbrain_repo="${var_gbrain_repo:-garrytan/gbrain}"
var_gbrain_ref="${var_gbrain_ref:-latest-stable}"
var_gbrain_pinned_version="${var_gbrain_pinned_version:-v0.59.0.0}"
var_gbrain_install_method="${var_gbrain_install_method:-}"
var_gbrain_pg_version="${var_gbrain_pg_version:-}"  # reserved for future --allow-docker ladder rung
var_gbrain_public_url="${var_gbrain_public_url:-}"
var_gbrain_cors_origin="${var_gbrain_cors_origin:-}"
var_gbrain_search_mode="${var_gbrain_search_mode:-}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/gbrain ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "gbrain" "garrytan/gbrain"; then
    msg_info "Stopping Services"
    systemctl stop gbrain-mcp.service gbrain-autopilot.service gbrain-tls-relay.service 2>/dev/null || true
    msg_ok "Stopped Services"

    create_backup /opt/gbrain/.env

    CLEAN_INSTALL=1 fetch_and_deploy_gh_release "gbrain" "garrytan/gbrain" "tarball" "/opt/gbrain"

    msg_info "Rebuilding Application"
    cd /opt/gbrain
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    $STD bun install --frozen-lockfile
    msg_ok "Rebuilt Application"

    restore_backup

    msg_info "Running Schema Migrations"
    $STD sudo -u gbrain bash -c "source /home/gbrain/.gbrain/.env && /home/gbrain/.bun/bin/gbrain apply-migrations --yes"
    msg_ok "Migrations Applied"

    msg_info "Restarting Services"
    systemctl start gbrain-mcp.service gbrain-autopilot.service gbrain-tls-relay.service
    msg_ok "Restarted Services"

    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

# Export user-selectable values so the install script picks them up via lxc-attach
export var_gbrain_repo var_gbrain_ref var_gbrain_pinned_version var_gbrain_install_method \
       var_gbrain_pg_version var_gbrain_public_url var_gbrain_cors_origin var_gbrain_search_mode

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access the MCP server at:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:9119/mcp${CL}"
echo -e "${INFO}${YW}MCP clients (Hermes, Codex, Claude Code) can connect via streamable HTTP.${CL}"
echo -e "${INFO}${YW}Next steps:${CL}"
echo -e "${INFO}  1. Configure embedding provider: gbrain config set embedding_model <provider>:<model>${CL}"
echo -e "${INFO}  2. Initialize the brain: gbrain init${CL}"
echo -e "${INFO}  3. Browse the admin UI at http://${IP}:9119/admin${CL}"
