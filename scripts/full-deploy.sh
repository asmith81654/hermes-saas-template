#!/usr/bin/env bash
# =============================================================================
# full-deploy.sh - End-to-end Hermes user deployment pipeline
# =============================================================================
# This script orchestrates the complete deployment lifecycle for a Hermes
# user: project creation, health polling, configuration injection, and
# final verification.
#
# Usage:
#   ./full-deploy.sh --user-id <id> --config <config.json> \
#       [--email <email>] [--name <name>] [--repo-url <url>] \
#       [--branch <branch>] [--dry-run] [--debug]
#
# Required environment variables:
#   RAILWAY_TOKEN - Railway API token
#
# Pipeline steps:
#   1. Call create-user-project.sh
#   2. Poll /health endpoint until service is live (timeout: 10 min)
#   3. Call inject-config.sh with user config
#   4. Verify endpoints: /health, /api/status
#   5. Output deployment summary
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Source shared utilities
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Script dependencies
# ---------------------------------------------------------------------------
CREATE_SCRIPT="${SCRIPT_DIR}/create-user-project.sh"
INJECT_SCRIPT="${SCRIPT_DIR}/inject-config.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-600}"
HEALTH_POLL_INTERVAL="${HEALTH_POLL_INTERVAL:-10}"
VERIFY_ENDPOINTS=("/health" "/api/status")

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat << 'EOF'
Usage: full-deploy.sh --user-id <id> --config <config.json> [options]

Complete end-to-end deployment of a Hermes Agent instance for one user.

Required:
  --user-id <id>              User identifier
  --config <config.json>      Path to user configuration JSON

Options:
  --email <email>             User email for welcome message (optional)
  --name <name>               Project name override (default: hermes-{user-id})
  --repo-url <url>            GitHub repo URL
  --branch <branch>           Git branch to deploy (default: main)
  --skip-verification         Skip the post-deploy endpoint verification
  --send-welcome              Print the welcome email that would be sent (stub)
  --dry-run                   Show the full plan without executing
  --debug                     Enable debug output
  --help                      Show this help message

Environment:
  RAILWAY_TOKEN               Railway API token (required)

Deployment steps:
  1. Create Railway project with persistent /data volume
  2. Wait for initial health check (timeout: 10 minutes)
  3. Inject LLM, IM, and agent configuration
  4. Verify /health and /api/status endpoints
  5. Output complete deployment summary
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
USER_ID=""
CONFIG_FILE=""
USER_EMAIL=""
PROJECT_NAME=""
REPO_URL="${DEFAULT_REPO_URL:-https://github.com/hermes-platform/hermes-agent}"
BRANCH="${DEFAULT_BRANCH:-main}"
SKIP_VERIFICATION=0
SEND_WELCOME=0

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
        --email)
            USER_EMAIL="$2"
            shift 2
            ;;
        --name)
            PROJECT_NAME="$2"
            shift 2
            ;;
        --repo-url)
            REPO_URL="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --skip-verification)
            SKIP_VERIFICATION=1
            shift
            ;;
        --send-welcome)
            SEND_WELCOME=1
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

if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_error "Config file not found: ${CONFIG_FILE}"
    exit 1
fi

if [[ ! -x "${CREATE_SCRIPT}" ]]; then
    log_error "create-user-project.sh not found or not executable: ${CREATE_SCRIPT}"
    exit 1
fi

if [[ ! -x "${INJECT_SCRIPT}" ]]; then
    log_error "inject-config.sh not found or not executable: ${INJECT_SCRIPT}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Dry-run
# ---------------------------------------------------------------------------
if dry_run_enabled; then
    log_info "=== DRY RUN — Full Deployment Pipeline ==="
    echo ""
    echo "Pipeline steps that would be executed:"
    echo ""
    echo "  1. Create Railway project"
    echo "     Script:  ${CREATE_SCRIPT}"
    echo "     User:    ${USER_ID}"
    echo "     Name:    ${PROJECT_NAME:-hermes-${USER_ID}}"
    echo "     Repo:    ${REPO_URL}"
    echo "     Branch:  ${BRANCH}"
    echo ""
    echo "  2. Wait for health check"
    echo "     Timeout: ${DEPLOY_TIMEOUT}s"
    echo "     Poll:    every ${HEALTH_POLL_INTERVAL}s"
    echo ""
    echo "  3. Inject config"
    echo "     Config:  ${CONFIG_FILE}"
    echo "     Script:  ${INJECT_SCRIPT}"
    echo ""
    echo "  4. Verify endpoints: ${VERIFY_ENDPOINTS[*]}"
    echo ""
    if [[ ${SEND_WELCOME} -eq 1 ]]; then
        echo "  5. Send welcome email to: ${USER_EMAIL:-no email provided}"
    fi
    echo ""
    log_info "No resources will be created. Remove --dry-run to execute."
    exit 0
fi

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------
START_TIME=$(date +%s)

log_info "=============================================="
log_info "  Hermes Full Deployment Pipeline"
log_info "=============================================="
log_info "  User ID:    ${USER_ID}"
log_info "  Config:     ${CONFIG_FILE}"
log_info "  Email:      ${USER_EMAIL:-not provided}"
log_info "  Started at: $(timestamp)"
log_info "=============================================="
echo ""

# ---------------------------------------------------------------------------
# Phase 1: Create project
# ---------------------------------------------------------------------------
log_step "[Phase 1/4] Creating Railway project..."

CREATE_ARGS=(
    --user-id "${USER_ID}"
    --repo-url "${REPO_URL}"
    --branch "${BRANCH}"
)
if [[ -n "${PROJECT_NAME}" ]]; then
    CREATE_ARGS+=(--name "${PROJECT_NAME}")
fi

CREATE_OUTPUT=$("${CREATE_SCRIPT}" "${CREATE_ARGS[@]}" 2>&1) || {
    log_error "Project creation failed"
    echo "${CREATE_OUTPUT}"
    exit 1
}

PROJECT_ID=$(echo "${CREATE_OUTPUT}" | jq -r '.project_id // empty' 2>/dev/null || true)
DEPLOY_URL=$(echo "${CREATE_OUTPUT}" | jq -r '.deploy_url // empty' 2>/dev/null || true)

if [[ -z "${PROJECT_ID}" ]]; then
    log_error "Could not extract project ID from creation output"
    log_error "Output was:"
    echo "${CREATE_OUTPUT}"
    exit 1
fi

log_success "Project created: ${PROJECT_ID}"

# Log the non-sensitive parts of the creation output
echo "${CREATE_OUTPUT}" | jq 'del(.admin_password)' 2>/dev/null || echo "${CREATE_OUTPUT}"

# ---------------------------------------------------------------------------
# Phase 2: Wait for initial health check
# ---------------------------------------------------------------------------
log_step "[Phase 2/4] Waiting for initial deployment to become healthy..."

if [[ -n "${DEPLOY_URL}" && "${DEPLOY_URL}" != "pending" && "${DEPLOY_URL}" != "null" ]]; then
    log_info "Polling ${DEPLOY_URL}${HEALTH_CHECK_ENDPOINT} every ${HEALTH_POLL_INTERVAL}s (timeout: ${DEPLOY_TIMEOUT}s)"

    if wait_for_health "${DEPLOY_URL}" "${DEPLOY_TIMEOUT}" "${HEALTH_POLL_INTERVAL}"; then
        log_success "Initial deployment is healthy!"

        # Update metadata
        METADATA=$(read_metadata "${USER_ID}")
        UPDATED=$(echo "${METADATA}" | jq \
            --arg status "healthy" \
            --arg checked "$(timestamp)" \
            '.status = $status | .health_status = "healthy" | .health_checked_at = $checked')
        write_metadata "${USER_ID}" "${UPDATED}"
    else
        log_error "Health check timed out after ${DEPLOY_TIMEOUT}s"
        log_error "Check the Railway dashboard: https://railway.app/project/${PROJECT_ID}"
        log_info "You can re-run inject-config.sh once the deployment is live:"
        log_info "  ${INJECT_SCRIPT} --user-id ${USER_ID} --config ${CONFIG_FILE}"

        # Update metadata with failure
        METADATA=$(read_metadata "${USER_ID}")
        UPDATED=$(echo "${METADATA}" | jq \
            --arg status "deploy_failed" \
            --arg checked "$(timestamp)" \
            '.status = $status | .health_status = "unhealthy" | .health_checked_at = $checked')
        write_metadata "${USER_ID}" "${UPDATED}"
        exit 1
    fi
else
    log_warn "No deploy URL yet — waiting 60s then retrying domain resolution..."
    sleep 60

    METADATA=$(read_metadata "${USER_ID}")
    DEPLOY_URL=$(get_deploy_url "${PROJECT_ID}" "hermes-agent" || echo "")

    if [[ -z "${DEPLOY_URL}" || "${DEPLOY_URL}" == "null" ]]; then
        log_error "Still cannot resolve service domain."
        log_error "Check the Railway dashboard: https://railway.app/project/${PROJECT_ID}"
        exit 1
    fi

    # Update metadata with resolved URL
    UPDATED=$(echo "${METADATA}" | jq --arg url "${DEPLOY_URL}" '.deploy_url = $url')
    write_metadata "${USER_ID}" "${UPDATED}"

    log_info "Resolved domain: ${DEPLOY_URL}"

    if wait_for_health "${DEPLOY_URL}" "${DEPLOY_TIMEOUT}" "${HEALTH_POLL_INTERVAL}"; then
        log_success "Initial deployment is healthy!"
    else
        log_error "Health check timed out after ${DEPLOY_TIMEOUT}s"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Phase 3: Inject configuration
# ---------------------------------------------------------------------------
log_step "[Phase 3/4] Injecting user configuration..."

INJECT_ARGS=(
    --user-id "${USER_ID}"
    --config "${CONFIG_FILE}"
)

# With full-deploy we let inject-config handle its own health check
# since the service was already confirmed healthy in phase 2
INJECT_OUTPUT=$("${INJECT_SCRIPT}" "${INJECT_ARGS[@]}" --skip-health-check 2>&1) || {
    log_error "Configuration injection failed"
    echo "${INJECT_OUTPUT}"
    exit 1
}

log_success "Configuration injected successfully"

# ---------------------------------------------------------------------------
# Phase 4: Verify endpoints
# ---------------------------------------------------------------------------
log_step "[Phase 4/4] Verifying endpoints..."

if [[ ${SKIP_VERIFICATION} -eq 0 ]]; then
    # Refresh metadata to get latest deploy URL
    METADATA=$(read_metadata "${USER_ID}")
    DEPLOY_URL=$(echo "${METADATA}" | jq -r '.deploy_url // empty')

    if [[ -z "${DEPLOY_URL}" || "${DEPLOY_URL}" == "pending" || "${DEPLOY_URL}" == "null" ]]; then
        log_warn "No deploy URL — skipping endpoint verification"
    else
        # Wait a moment for the new deployment to be ready
        log_info "Waiting 15s for redeployment to stabilize..."
        sleep 15

        ALL_VERIFIED=true
        for endpoint in "${VERIFY_ENDPOINTS[@]}"; do
            VERIFY_URL="${DEPLOY_URL}${endpoint}"
            log_info "Checking ${VERIFY_URL}..."

            if curl -sf --max-time 10 "${VERIFY_URL}" > /dev/null 2>&1; then
                log_success "  ${endpoint} -> OK"
            else
                log_warn "  ${endpoint} -> FAILED (non-critical, service may still be deploying)"
                ALL_VERIFIED=false
            fi
        done

        if ${ALL_VERIFIED}; then
            log_success "All endpoints verified"

            UPDATED=$(echo "${METADATA}" | jq \
                --arg status "live" \
                --arg verified "$(timestamp)" \
                '.status = $status | .verified_at = $verified')
            write_metadata "${USER_ID}" "${UPDATED}"
        else
            log_warn "Some endpoints failed verification — service may still be deploying"
            log_info "Check manually: curl ${DEPLOY_URL}/health"
        fi
    fi
else
    log_info "Skipping endpoint verification (--skip-verification)"
fi

# ---------------------------------------------------------------------------
# Deployment summary
# ---------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

METADATA=$(read_metadata "${USER_ID}")
FINAL_URL=$(echo "${METADATA}" | jq -r '.deploy_url // "pending"')
ADMIN_USER=$(echo "${METADATA}" | jq -r '.admin_username // "admin"')
ADMIN_PASS=$(echo "${METADATA}" | jq -r '.admin_password // ""')

LLM_PROVIDER=$(jq -r '.llm.provider' "${CONFIG_FILE}")
LLM_MODEL=$(jq -r '.llm.model' "${CONFIG_FILE}")
IM_PLATFORM=$(jq -r '.im.platform' "${CONFIG_FILE}")
AGENT_NAME=$(jq -r '.default_agent.name' "${CONFIG_FILE}")

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            HERMES DEPLOYMENT COMPLETE                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-56s ║\n" "User ID:       ${USER_ID}"
printf "║  %-56s ║\n" "Project ID:    ${PROJECT_ID}"
printf "║  %-56s ║\n" "Deploy URL:    ${FINAL_URL}"
printf "║  %-56s ║\n" "Dashboard:     https://railway.app/project/${PROJECT_ID}"
printf "║  %-56s ║\n" ""
printf "║  %-56s ║\n" "LLM Provider:  ${LLM_PROVIDER}"
printf "║  %-56s ║\n" "LLM Model:     ${LLM_MODEL}"
printf "║  %-56s ║\n" "IM Platform:   ${IM_PLATFORM}"
printf "║  %-56s ║\n" "Agent Name:    ${AGENT_NAME}"
printf "║  %-56s ║\n" ""
printf "║  %-56s ║\n" "Admin User:    ${ADMIN_USER}"
printf "║  %-56s ║\n" "Admin Pass:    ${ADMIN_PASS}"
printf "║  %-56s ║\n" ""
printf "║  %-56s ║\n" "Duration:      ${DURATION}s"
printf "║  %-56s ║\n" "Completed at:  $(timestamp)"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# Welcome email stub
# ---------------------------------------------------------------------------
if [[ ${SEND_WELCOME} -eq 1 ]]; then
    echo ""
    log_step "Welcome Email (stub)"
    echo "----------------------------------------"
    cat << WELCOME_EOF
To: ${USER_EMAIL:-user@example.com}
Subject: Your Hermes Agent is ready!

Hi there,

Your personal Hermes Agent has been deployed successfully!

Here are your access details:

  Agent URL:       ${FINAL_URL}
  Admin Dashboard: ${FINAL_URL}/admin
  Username:        ${ADMIN_USER}
  Password:        ${ADMIN_PASS}

Your agent "${AGENT_NAME}" is configured with:
  - LLM: ${LLM_PROVIDER} / ${LLM_MODEL}
  - IM:  ${IM_PLATFORM}

To connect your IM bot, use the following link:
  ${FINAL_URL}/connect/${IM_PLATFORM}

If you have any questions, reply to this email.

— The Hermes Team
WELCOME_EOF
    echo "----------------------------------------"
    echo ""
    log_info "(This was a stub. Implement actual email sending in production.)"
fi

# ---------------------------------------------------------------------------
# Final metadata output (machine-readable, sans password)
# ---------------------------------------------------------------------------
echo "${METADATA}" | jq 'del(.admin_password)'

log_success "Full deployment pipeline completed successfully!"
