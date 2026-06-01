#!/usr/bin/env bash
# =============================================================================
# deprovision.sh - Tear down a Hermes user's Railway project
# =============================================================================
# This script removes a user's dedicated Railway project and its associated
# resources (services, volumes, domains, env vars). It also cleans up the
# local metadata file.
#
# Usage:
#   ./deprovision.sh --user-id <id> [--force] [--dry-run] [--debug]
#
# Required environment variables:
#   RAILWAY_TOKEN - Railway API token
#
# Safety:
#   By default, this script requires interactive confirmation unless
#   --force is provided.
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
Usage: deprovision.sh --user-id <id> [options]

Delete a Hermes user's Railway project and all associated resources.

Required:
  --user-id <id>          User identifier to deprovision

Options:
  --force                 Skip confirmation prompt
  --keep-metadata         Keep the local metadata file after deletion
  --dry-run               Show what would be deleted without executing
  --debug                 Enable debug output
  --help                  Show this help message

Environment:
  RAILWAY_TOKEN           Railway API token (required)

WARNING: This operation is destructive and cannot be undone.
         Railway project deletion is permanent.
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
USER_ID=""
FORCE=0
KEEP_METADATA=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user-id)
            USER_ID="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --keep-metadata)
            KEEP_METADATA=1
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

validate_user_id "${USER_ID}"
require_railway_token

# ---------------------------------------------------------------------------
# Load project metadata
# ---------------------------------------------------------------------------
log_step "Loading project metadata for user: ${USER_ID}..."

meta_path="$(get_project_metadata_path "${USER_ID}")"
if [[ ! -f "${meta_path}" ]]; then
    log_error "No metadata found for user ${USER_ID} at ${meta_path}"
    log_error "The project may have already been deprovisioned or was never created."
    log_info "If the project was created manually, you'll need to delete it via the Railway dashboard."
    exit 1
fi

METADATA=$(cat "${meta_path}")
PROJECT_ID=$(echo "${METADATA}" | jq -r '.project_id // empty')
PROJECT_NAME=$(echo "${METADATA}" | jq -r '.project_name // "unknown"')
SERVICE_ID=$(echo "${METADATA}" | jq -r '.service_id // "unknown"')
SERVICE_NAME=$(echo "${METADATA}" | jq -r '.service_name // "unknown"')
DEPLOY_URL=$(echo "${METADATA}" | jq -r '.deploy_url // "unknown"')
CREATED_AT=$(echo "${METADATA}" | jq -r '.created_at // "unknown"')
STATUS=$(echo "${METADATA}" | jq -r '.status // "unknown"')

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
    log_error "Metadata file is missing project_id — it may be corrupted"
    log_error "Metadata: ${meta_path}"
    log_info "If the project ID is unknown, delete the metadata file manually:"
    log_info "  rm ${meta_path}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Display what will be deleted
# ---------------------------------------------------------------------------
log_info "Preparing to deprovision:"
echo ""
echo "  User ID:        ${USER_ID}"
echo "  Project Name:   ${PROJECT_NAME}"
echo "  Project ID:     ${PROJECT_ID}"
echo "  Service:        ${SERVICE_NAME} (${SERVICE_ID})"
echo "  Deploy URL:     ${DEPLOY_URL}"
echo "  Status:         ${STATUS}"
echo "  Created:        ${CREATED_AT}"
echo "  Dashboard:      https://railway.app/project/${PROJECT_ID}"
echo ""
log_warn "This will permanently delete the Railway project and all its resources!"
log_warn "This action CANNOT be undone."

# ---------------------------------------------------------------------------
# Dry-run
# ---------------------------------------------------------------------------
if dry_run_enabled; then
    echo ""
    log_info "DRY RUN — no resources will be deleted."
    log_info "Would delete:"
    log_info "  1. Railway project: ${PROJECT_ID} (${PROJECT_NAME})"
    log_info "  2. Service:         ${SERVICE_NAME} (${SERVICE_ID})"
    log_info "  3. All associated volumes, env vars, and domains"
    if [[ ${KEEP_METADATA} -eq 0 ]]; then
        log_info "  4. Local metadata:  ${meta_path}"
    else
        log_info "  4. Local metadata:  kept (--keep-metadata)"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
if [[ ${FORCE} -eq 0 ]]; then
    echo ""
    read -r -p "Type 'DELETE ${USER_ID}' to confirm deprovisioning: " CONFIRMATION
    echo ""
    if [[ "${CONFIRMATION}" != "DELETE ${USER_ID}" ]]; then
        log_error "Confirmation did not match. Expected: 'DELETE ${USER_ID}'"
        log_error "Got: '${CONFIRMATION}'"
        log_info "Deprovisioning cancelled. No resources were affected."
        exit 1
    fi
    log_info "Confirmation received."
else
    log_info "Skipping confirmation (--force)"
fi

# ---------------------------------------------------------------------------
# Step 1: Delete the Railway project
# ---------------------------------------------------------------------------
log_step "Deleting Railway project: ${PROJECT_ID} (${PROJECT_NAME})..."

# Use GraphQL API to delete the project
DELETE_PROJECT_MUTATION='
mutation projectDelete($id: String!) {
    projectDelete(id: $id)
}'

DELETE_VARS="{\"id\": \"${PROJECT_ID}\"}"

DELETE_RESPONSE=$(graphql_call "${DELETE_PROJECT_MUTATION}" "${DELETE_VARS}") || {
    log_error "GraphQL project deletion failed"
    log_error "Response: ${DELETE_RESPONSE:-no response}"

    # Try CLI fallback
    log_info "Trying Railway CLI fallback..."
    if railway link -p "${PROJECT_ID}" 2>/dev/null; then
        railway project delete --force 2>/dev/null || {
            log_error "CLI deletion also failed"
            log_error "You may need to manually delete the project at:"
            log_error "  https://railway.app/project/${PROJECT_ID}/settings"
            exit 1
        }
        log_success "Project deleted via CLI fallback"
    else
        log_error "Cannot link to project — manual deletion required"
        log_error "Visit: https://railway.app/project/${PROJECT_ID}/settings"
        exit 1
    fi
}

# Verify deletion
DELETE_RESULT=$(echo "${DELETE_RESPONSE}" | jq -r '.data.projectDelete // empty')
if [[ "${DELETE_RESULT}" == "true" ]]; then
    log_success "Railway project deleted: ${PROJECT_ID} (${PROJECT_NAME})"
else
    log_warn "Project deletion returned non-true. Checking if it was actually deleted..."
    # Verify by trying to query the project
    VERIFY_QUERY='
    query($id: String!) {
        project(id: $id) {
            id
        }
    }'
    VERIFY_VARS="{\"id\": \"${PROJECT_ID}\"}"
    if graphql_call "${VERIFY_QUERY}" "${VERIFY_VARS}" 2>/dev/null | jq -e '.data.project == null' > /dev/null 2>&1; then
        log_success "Project confirmed deleted (project not found)"
    else
        log_warn "Project may still exist — please verify at the Railway dashboard"
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Clean up local metadata
# ---------------------------------------------------------------------------
if [[ ${KEEP_METADATA} -eq 0 ]]; then
    log_step "Cleaning up local metadata..."

    # Archive metadata before deleting (save to log dir)
    ARCHIVE_PATH="${LOG_DIR}/deprovisioned-${USER_ID}-$(date -u +%Y%m%d%H%M%S).json"
    mkdir -p "${LOG_DIR}"
    echo "${METADATA}" | jq \
        --arg deprovisioned_at "$(timestamp)" \
        '.deprovisioned_at = $deprovisioned_at' \
        > "${ARCHIVE_PATH}"
    log_info "Metadata archived to: ${ARCHIVE_PATH}"

    delete_metadata "${USER_ID}"
    log_success "Local metadata deleted"
else
    log_info "Keeping local metadata (--keep-metadata)"

    # Update metadata to reflect deprovisioned state
    UPDATED=$(echo "${METADATA}" | jq \
        --arg status "deprovisioned" \
        --arg deprovisioned_at "$(timestamp)" \
        '.status = $status | .deprovisioned_at = $deprovisioned_at')
    write_metadata "${USER_ID}" "${UPDATED}"
fi

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  Deprovisioning Complete"
echo "=============================================="
echo "  User ID:        ${USER_ID}"
echo "  Project:        ${PROJECT_NAME} (${PROJECT_ID})"
echo "  Status:         Deprovisioned"
echo "  Deleted at:     $(timestamp)"
echo "=============================================="
echo ""
log_success "User ${USER_ID} has been fully deprovisioned."

if [[ ${KEEP_METADATA} -eq 1 ]]; then
    log_info "Metadata retained at: ${meta_path}"
fi
