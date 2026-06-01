#!/usr/bin/env bash
# =============================================================================
# inject-config.sh - Inject user configuration into a Hermes Railway project
# =============================================================================
# This script reads a user's configuration JSON file and sets the
# corresponding Railway environment variables for their project.
# After setting variables, it triggers a redeployment and waits for
# the health check to pass.
#
# Usage:
#   ./inject-config.sh --user-id <id> --config <config-file.json> \
#       [--skip-health-check] [--dry-run] [--debug]
#
# Required environment variables:
#   RAILWAY_TOKEN - Railway API token
#
# Config file format: see config-template.json
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Source shared utilities
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat << 'EOF'
Usage: inject-config.sh --user-id <id> --config <config-file.json> [options]

Inject LLM, IM, and agent configuration into a Hermes Railway project.

Required:
  --user-id <id>              User identifier
  --config <config-file.json> Path to JSON configuration file

Options:
  --skip-health-check         Skip the post-deploy health check wait
  --no-restart                Skip triggering redeployment
  --dry-run                   Show what would be set without executing
  --debug                     Enable debug output
  --help                      Show this help message

Environment:
  RAILWAY_TOKEN               Railway API token (required)

Config file format:
  See config-template.json for the expected structure.
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
USER_ID=""
CONFIG_FILE=""
SKIP_HEALTH_CHECK=0
NO_RESTART=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user-id)
            USER_ID="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --skip-health-check)
            SKIP_HEALTH_CHECK=1
            shift
            ;;
        --no-restart)
            NO_RESTART=1
            shift
            ;;
        --dry-run)
            export DRY_RUN=1
            shift
            ;;
        --debug)
            export DEBUG=1
            shift
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown argument: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ -z "${USER_ID}" ]]; then
    log_error "--user-id is required"
    echo "Use --help for usage information."
    exit 1
fi

if [[ -z "${CONFIG_FILE}" ]]; then
    log_error "--config is required"
    echo "Use --help for usage information."
    exit 1
fi

validate_user_id "${USER_ID}"
require_railway_token

# Load and validate config JSON
load_config_file "${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# Load project metadata
# ---------------------------------------------------------------------------
log_step "Loading project metadata for user: ${USER_ID}..."
METADATA=$(read_metadata "${USER_ID}")
PROJECT_ID=$(echo "${METADATA}" | jq -r '.project_id')
SERVICE_ID=$(echo "${METADATA}" | jq -r '.service_id')
SERVICE_NAME=$(echo "${METADATA}" | jq -r '.service_name')
DEPLOY_URL=$(echo "${METADATA}" | jq -r '.deploy_url // empty')

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
    log_error "No project ID found in metadata for user ${USER_ID}"
    log_error "Run create-user-project.sh first."
    exit 1
fi

log_info "Project: ${PROJECT_ID}, Service: ${SERVICE_ID} (${SERVICE_NAME})"

# ---------------------------------------------------------------------------
# Parse and validate config sections
# ---------------------------------------------------------------------------
log_step "Validating configuration file..."

# Validate top-level sections
REQUIRED_SECTIONS=("llm" "im" "default_agent")
for section in "${REQUIRED_SECTIONS[@]}"; do
    if ! jq -e ".${section}" "${CONFIG_FILE}" > /dev/null 2>&1; then
        log_error "Config file is missing required section: '${section}'"
        exit 1
    fi
done

# Validate LLM section
REQUIRED_LLM=("provider" "api_key" "model")
for field in "${REQUIRED_LLM[@]}"; do
    if [[ "$(jq -r ".llm.${field} // empty" "${CONFIG_FILE}")" == "" ]]; then
        log_error "Config file is missing required field: llm.${field}"
        exit 1
    fi
done

# Validate IM section
REQUIRED_IM=("platform" "bot_token")
for field in "${REQUIRED_IM[@]}"; do
    if [[ "$(jq -r ".im.${field} // empty" "${CONFIG_FILE}")" == "" ]]; then
        log_error "Config file is missing required field: im.${field}"
        exit 1
    fi
done

# Validate default_agent section
REQUIRED_AGENT=("name" "system_prompt" "model")
for field in "${REQUIRED_AGENT[@]}"; do
    if [[ "$(jq -r ".default_agent.${field} // empty" "${CONFIG_FILE}")" == "" ]]; then
        log_error "Config file is missing required field: default_agent.${field}"
        exit 1
    fi
done

log_success "Configuration file is valid"

# ---------------------------------------------------------------------------
# Read config values
# ---------------------------------------------------------------------------
LLM_PROVIDER="$(jq -r '.llm.provider' "${CONFIG_FILE}")"
LLM_API_KEY="$(jq -r '.llm.api_key' "${CONFIG_FILE}")"
LLM_MODEL="$(jq -r '.llm.model' "${CONFIG_FILE}")"
LLM_BASE_URL="$(jq -r '.llm.base_url // ""' "${CONFIG_FILE}")"
LLM_MAX_TOKENS="$(jq -r '.llm.max_tokens // ""' "${CONFIG_FILE}")"
LLM_TEMPERATURE="$(jq -r '.llm.temperature // ""' "${CONFIG_FILE}")"

IM_PLATFORM="$(jq -r '.im.platform' "${CONFIG_FILE}")"
IM_BOT_TOKEN="$(jq -r '.im.bot_token' "${CONFIG_FILE}")"
IM_ALLOWED_USERS="$(jq -r '.im.allowed_users // [] | join(",")' "${CONFIG_FILE}")"
IM_WEBHOOK_SECRET="$(jq -r '.im.webhook_secret // ""' "${CONFIG_FILE}")"

AGENT_NAME="$(jq -r '.default_agent.name' "${CONFIG_FILE}")"
AGENT_SYSTEM_PROMPT="$(jq -r '.default_agent.system_prompt' "${CONFIG_FILE}")"
AGENT_MODEL="$(jq -r '.default_agent.model' "${CONFIG_FILE}")"
AGENT_TOOLS="$(jq -r '.default_agent.tools // [] | join(",")' "${CONFIG_FILE}")"

# Read optional fields
APP_NAME="$(jq -r '.app_name // ""' "${CONFIG_FILE}")"
APP_ENV="$(jq -r '.app_env // "production"' "${CONFIG_FILE}")"
LOG_LEVEL="$(jq -r '.log_level // "info"' "${CONFIG_FILE}")"

# ---------------------------------------------------------------------------
# Build environment variable list
# ---------------------------------------------------------------------------
log_step "Preparing environment variables..."

# We build an associative-like structure using two parallel arrays
# because we need to handle values with spaces and special characters.
declare -a VAR_NAMES=()
declare -a VAR_VALUES=()

add_var() {
    local name="$1"
    local value="$2"
    VAR_NAMES+=("${name}")
    VAR_VALUES+=("${value}")
}

# LLM configuration
add_var "LLM_PROVIDER" "${LLM_PROVIDER}"
add_var "LLM_API_KEY" "${LLM_API_KEY}"
add_var "LLM_MODEL" "${LLM_MODEL}"
if [[ -n "${LLM_BASE_URL}" ]]; then
    add_var "LLM_BASE_URL" "${LLM_BASE_URL}"
fi
if [[ -n "${LLM_MAX_TOKENS}" ]]; then
    add_var "LLM_MAX_TOKENS" "${LLM_MAX_TOKENS}"
fi
if [[ -n "${LLM_TEMPERATURE}" ]]; then
    add_var "LLM_TEMPERATURE" "${LLM_TEMPERATURE}"
fi

# IM configuration
add_var "IM_PLATFORM" "${IM_PLATFORM}"
add_var "IM_BOT_TOKEN" "${IM_BOT_TOKEN}"
if [[ -n "${IM_ALLOWED_USERS}" ]]; then
    add_var "IM_ALLOWED_USERS" "${IM_ALLOWED_USERS}"
fi
if [[ -n "${IM_WEBHOOK_SECRET}" ]]; then
    add_var "IM_WEBHOOK_SECRET" "${IM_WEBHOOK_SECRET}"
fi

# Default agent configuration
add_var "DEFAULT_AGENT_NAME" "${AGENT_NAME}"
add_var "DEFAULT_AGENT_SYSTEM_PROMPT" "${AGENT_SYSTEM_PROMPT}"
add_var "DEFAULT_AGENT_MODEL" "${AGENT_MODEL}"
if [[ -n "${AGENT_TOOLS}" ]]; then
    add_var "DEFAULT_AGENT_TOOLS" "${AGENT_TOOLS}"
fi

# App-level configuration
if [[ -n "${APP_NAME}" ]]; then
    add_var "APP_NAME" "${APP_NAME}"
fi
add_var "APP_ENV" "${APP_ENV}"
add_var "LOG_LEVEL" "${LOG_LEVEL}"

# Mark config as injected with timestamp
add_var "CONFIG_INJECTED_AT" "$(timestamp)"
add_var "CONFIG_VERSION" "1"

# ---------------------------------------------------------------------------
# Dry-run output
# ---------------------------------------------------------------------------
if dry_run_enabled; then
    log_info "DRY RUN — would set the following environment variables for project ${PROJECT_ID}:"
    echo ""
    for i in "${!VAR_NAMES[@]}"; do
        local_val="${VAR_VALUES[$i]}"
        # Mask sensitive values
        if [[ "${VAR_NAMES[$i]}" =~ API_KEY|BOT_TOKEN|SECRET|PASSWORD ]]; then
            local_val="${local_val:0:4}...${local_val: -4}"
        fi
        printf "  ${COLOR_CYAN}%-35s${COLOR_RESET} = %s\n" "${VAR_NAMES[$i]}" "${local_val}"
    done
    echo ""
    log_info "Would trigger redeploy: $([[ ${NO_RESTART} -eq 0 ]] && echo 'yes' || echo 'no')"
    log_info "Would wait for health check: $([[ ${SKIP_HEALTH_CHECK} -eq 0 ]] && echo 'yes' || echo 'no')"
    exit 0
fi

# ---------------------------------------------------------------------------
# Set environment variables
# ---------------------------------------------------------------------------
log_step "Setting environment variables on service '${SERVICE_NAME}'..."

# Build the railway variables set command arguments
# Using CLI for simplicity; GraphQL fallback if needed
VAR_ARGS=()
for i in "${!VAR_NAMES[@]}"; do
    VAR_ARGS+=("${VAR_NAMES[$i]}=${VAR_VALUES[$i]}")
done

if ! railway variables set -s "${SERVICE_NAME}" "${VAR_ARGS[@]}" 2>/dev/null; then
    log_info "CLI-based variable setting failed, trying GraphQL API..."

    # Build GraphQL variable payload
    VARS_JSON="{}"
    for i in "${!VAR_NAMES[@]}"; do
        VARS_JSON=$(echo "${VARS_JSON}" | jq \
            --arg k "${VAR_NAMES[$i]}" \
            --arg v "${VAR_VALUES[$i]}" \
            '. + {($k): $v}')
    done

    SET_VARS_MUTATION='
    mutation upsertVariables($input: VariableCollectionUpsertInput!) {
        variableCollectionUpsert(input: $input) {
            id
        }
    }'

    VARS_INPUT=$(jq -n \
        --arg projectId "${PROJECT_ID}" \
        --arg serviceId "${SERVICE_ID}" \
        --argjson variables "${VARS_JSON}" \
        '{
            input: {
                projectId: $projectId,
                serviceId: $serviceId,
                variables: $variables,
                replace: true
            }
        }')

    graphql_call "${SET_VARS_MUTATION}" "${VARS_INPUT}" > /dev/null || {
        log_error "Failed to set environment variables via both CLI and GraphQL"
        exit 1
    }
fi

log_success "Set ${#VAR_NAMES[@]} environment variables"

# ---------------------------------------------------------------------------
# Update metadata
# ---------------------------------------------------------------------------
log_step "Updating metadata..."
UPDATE_TIME=$(timestamp)

UPDATED_METADATA=$(echo "${METADATA}" | jq \
    --arg configured_at "${UPDATE_TIME}" \
    --arg status "configured" \
    --argjson injected true \
    --arg config_file "${CONFIG_FILE}" \
    '.configured_at = $configured_at |
     .status = $status |
     .injected = $injected |
     .config_file = $config_file |
     .config_sections = {
         llm_provider: $llm_prov,
         im_platform: $im_plat,
         agent_name: $agent_nm
     }' \
    --arg llm_prov "${LLM_PROVIDER}" \
    --arg im_plat "${IM_PLATFORM}" \
    --arg agent_nm "${AGENT_NAME}")

write_metadata "${USER_ID}" "${UPDATED_METADATA}"
log_success "Metadata updated"

# ---------------------------------------------------------------------------
# Trigger redeployment (unless --no-restart)
# ---------------------------------------------------------------------------
if [[ ${NO_RESTART} -eq 0 ]]; then
    log_step "Triggering redeployment to pick up new environment variables..."

    DEPLOY_MUTATION='
    mutation deployService($input: DeploymentTriggerInput!) {
        deploymentTrigger(input: $input) {
            id
            status
        }
    }'

    DEPLOY_VARS=$(jq -n \
        --arg projectId "${PROJECT_ID}" \
        --arg serviceId "${SERVICE_ID}" \
        '{
            input: {
                projectId: $projectId,
                serviceId: $serviceId
            }
        }')

    DEPLOY_RESPONSE=$(graphql_call "${DEPLOY_MUTATION}" "${DEPLOY_VARS}")
    DEPLOY_ID=$(echo "${DEPLOY_RESPONSE}" | jq -r '.data.deploymentTrigger.id // empty')
    DEPLOY_STATUS=$(echo "${DEPLOY_RESPONSE}" | jq -r '.data.deploymentTrigger.status // "unknown"')

    log_success "Redeployment triggered: ${DEPLOY_ID} (status: ${DEPLOY_STATUS})"

    # Update metadata with new deploy ID
    UPDATED_METADATA=$(read_metadata "${USER_ID}" | jq \
        --arg deploy_id "${DEPLOY_ID}" \
        --arg status "deploying" \
        '.deploy_id = $deploy_id | .status = $status')
    write_metadata "${USER_ID}" "${UPDATED_METADATA}"

    # -----------------------------------------------------------------------
    # Wait for health check
    # -----------------------------------------------------------------------
    if [[ ${SKIP_HEALTH_CHECK} -eq 0 ]]; then
        if [[ -n "${DEPLOY_URL}" && "${DEPLOY_URL}" != "pending" && "${DEPLOY_URL}" != "null" ]]; then
            if wait_for_health "${DEPLOY_URL}" "${HEALTH_CHECK_TIMEOUT}" "${HEALTH_CHECK_INTERVAL}"; then
                UPDATED_METADATA=$(read_metadata "${USER_ID}" | jq \
                    --arg status "healthy" \
                    --arg health_checked "$(timestamp)" \
                    '.status = $status | .health_status = "healthy" | .health_checked_at = $health_checked')
                write_metadata "${USER_ID}" "${UPDATED_METADATA}"
            else
                UPDATED_METADATA=$(read_metadata "${USER_ID}" | jq \
                    --arg status "unhealthy" \
                    --arg health_checked "$(timestamp)" \
                    '.status = $status | .health_status = "unhealthy" | .health_checked_at = $health_checked')
                write_metadata "${USER_ID}" "${UPDATED_METADATA}"
                log_error "Health check failed — the service may not be running correctly"
                exit 1
            fi
        else
            log_warn "No deploy URL available — skipping health check"
            log_info "Monitor manually at the Railway dashboard: https://railway.app/project/${PROJECT_ID}"
        fi
    else
        log_info "Skipping health check (--skip-health-check)"
    fi
else
    log_info "Skipping redeployment (--no-restart)"
fi

# ---------------------------------------------------------------------------
# Output summary
# ---------------------------------------------------------------------------
log_step "Configuration injection complete!"
echo ""
echo "=============================================="
echo "  Configuration Injected"
echo "=============================================="
echo "  User ID:         ${USER_ID}"
echo "  Project ID:      ${PROJECT_ID}"
echo "  LLM Provider:    ${LLM_PROVIDER}"
echo "  LLM Model:       ${LLM_MODEL}"
echo "  IM Platform:     ${IM_PLATFORM}"
echo "  Agent Name:      ${AGENT_NAME}"
echo "  Deployment URL:  ${DEPLOY_URL}"
echo "=============================================="
echo ""

# Output current metadata (without admin password)
read_metadata "${USER_ID}" | jq 'del(.admin_password)'

log_success "Done."
