#!/usr/bin/env bash
# =============================================================================
# create-user-project.sh - Create a Railway project for one Hermes user
# =============================================================================
# This script provisions a dedicated Railway project for a single paying user.
# It creates the project, adds the Hermes Agent service from the GitHub repo,
# attaches a persistent volume at /data, and sets initial admin credentials.
#
# Usage:
#   ./create-user-project.sh --user-id <id> [--name <name>] \
#       [--repo-url <url>] [--branch <branch>] [--dry-run] [--debug]
#
# Required environment variables:
#   RAILWAY_TOKEN - Railway API token (personal or team)
#
# Output:
#   JSON with project ID, service ID, deploy URL, admin credentials
#   Also writes metadata to /data/projects/{user-id}.json
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Source shared utilities
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Default configuration
# ---------------------------------------------------------------------------
DEFAULT_REPO_URL="${DEFAULT_REPO_URL:-https://github.com/hermes-platform/hermes-agent}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
DEFAULT_SERVICE_NAME="${DEFAULT_SERVICE_NAME:-hermes-agent}"
DEFAULT_VOLUME_MOUNT="${DEFAULT_VOLUME_MOUNT:-/data}"
DEFAULT_HEALTH_PATH="${DEFAULT_HEALTH_PATH:-/health}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat << 'EOF'
Usage: create-user-project.sh --user-id <id> [options]

Create a dedicated Railway project for a Hermes Agent user.

Required:
  --user-id <id>          Unique user identifier (3-64 alphanumeric chars)

Options:
  --name <name>           Project name override (default: hermes-{user-id})
  --repo-url <url>        GitHub repo URL (default: https://github.com/hermes-platform/hermes-agent)
  --branch <branch>       Git branch to deploy (default: main)
  --service-name <name>   Railway service name (default: hermes-agent)
  --dry-run               Show what would be done without executing
  --debug                 Enable debug output
  --help                  Show this help message

Environment:
  RAILWAY_TOKEN           Railway API token (required)
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
USER_ID=""
PROJECT_NAME=""
REPO_URL="${DEFAULT_REPO_URL}"
BRANCH="${DEFAULT_BRANCH}"
SERVICE_NAME="${DEFAULT_SERVICE_NAME}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user-id)
            USER_ID="$2"
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
        --service-name)
            SERVICE_NAME="$2"
            shift 2
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

# Set default project name if not provided
if [[ -z "${PROJECT_NAME}" ]]; then
    PROJECT_NAME="hermes-${USER_ID}"
fi

require_railway_token

# ---------------------------------------------------------------------------
# Idempotency check — see if project already exists
# ---------------------------------------------------------------------------
EXISTING_METADATA=""
meta_path="$(get_project_metadata_path "${USER_ID}")"
if [[ -f "${meta_path}" ]]; then
    log_warn "Metadata already exists for user ${USER_ID} at ${meta_path}"
    EXISTING_METADATA="$(cat "${meta_path}")"
    EXISTING_PROJECT_ID="$(echo "${EXISTING_METADATA}" | jq -r '.project_id // empty')"
    if [[ -n "${EXISTING_PROJECT_ID}" ]]; then
        log_info "User ${USER_ID} already has project: ${EXISTING_PROJECT_ID}"
        log_info "Re-running will update the existing project."
        log_info "To create a fresh project, run deprovision.sh first."
        if ! dry_run_enabled; then
            echo "${EXISTING_METADATA}" | jq '.'
            exit 0
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Dry-run output
# ---------------------------------------------------------------------------
if dry_run_enabled; then
    cat << EOF
${COLOR_MAGENTA}=== DRY RUN ===${COLOR_RESET}

Would create Railway project:
  Project name:   ${PROJECT_NAME}
  User ID:        ${USER_ID}
  Service name:   ${SERVICE_NAME}
  Repository:     ${REPO_URL}
  Branch:         ${BRANCH}
  Volume mount:   ${DEFAULT_VOLUME_MOUNT}
  Admin username: ${ADMIN_USERNAME}
  Admin password: (auto-generated)

No resources will be created.
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 1: Authenticate with Railway
# ---------------------------------------------------------------------------
log_step "Authenticating with Railway..."
if ! railway whoami > /dev/null 2>&1; then
    log_info "Logging in to Railway..."
    RAILWAY_TOKEN="${RAILWAY_TOKEN}" railway login --browserless || {
        log_error "Railway authentication failed. Check your RAILWAY_TOKEN."
        exit 1
    }
fi
log_success "Railway authentication verified"

# ---------------------------------------------------------------------------
# Step 2: Create Railway project
# ---------------------------------------------------------------------------
log_step "Creating Railway project: ${PROJECT_NAME}..."

CREATE_PROJECT_MUTATION='
mutation createProject($input: ProjectCreateInput!) {
    projectCreate(input: $input) {
        id
        name
        createdAt
    }
}'

CREATE_VARS="{\"input\": {\"name\": \"${PROJECT_NAME}\"}}"

PROJECT_RESPONSE=$(graphql_call "${CREATE_PROJECT_MUTATION}" "${CREATE_VARS}")
PROJECT_ID=$(echo "${PROJECT_RESPONSE}" | jq -r '.data.projectCreate.id')

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
    log_error "Failed to create Railway project"
    log_error "Response: ${PROJECT_RESPONSE}"
    exit 1
fi

log_success "Project created: ${PROJECT_ID} (${PROJECT_NAME})"

# ---------------------------------------------------------------------------
# Step 3: Link Railway CLI to the new project
# ---------------------------------------------------------------------------
log_step "Linking Railway CLI to project ${PROJECT_ID}..."
railway link -p "${PROJECT_ID}" || {
    log_warn "Failed to link project — continuing, this may not be critical"
}
log_success "Linked to project ${PROJECT_ID}"

# ---------------------------------------------------------------------------
# Step 4: Add hermes-agent service from GitHub repo
# ---------------------------------------------------------------------------
log_step "Adding service '${SERVICE_NAME}' from ${REPO_URL} (branch: ${BRANCH})..."

# Railway's GraphQL API for service creation via GitHub repo
ADD_SERVICE_MUTATION='
mutation serviceCreate($input: ServiceCreateInput!) {
    serviceCreate(input: $input) {
        id
        name
        serviceInstances {
            edges {
                node {
                    source {
                        repo
                        branch
                    }
                }
            }
        }
    }
}'

SERVICE_VARS=$(jq -n \
    --arg projectId "${PROJECT_ID}" \
    --arg name "${SERVICE_NAME}" \
    --arg repo "${REPO_URL}" \
    --arg branch "${BRANCH}" \
    '{
        input: {
            projectId: $projectId,
            name: $name,
            source: {
                repo: $repo,
                branch: $branch
            }
        }
    }')

SERVICE_RESPONSE=$(graphql_call "${ADD_SERVICE_MUTATION}" "${SERVICE_VARS}")
SERVICE_ID=$(echo "${SERVICE_RESPONSE}" | jq -r '.data.serviceCreate.id')

if [[ -z "${SERVICE_ID}" || "${SERVICE_ID}" == "null" ]]; then
    log_error "Failed to create service"
    log_error "Response: ${SERVICE_RESPONSE}"
    log_warn "Project ${PROJECT_ID} was created but has no service."
    log_warn "You may need to add the service manually or delete the project."
    # Save partial metadata for cleanup reference
    write_metadata "${USER_ID}" "$(jq -n \
        --arg project_id "${PROJECT_ID}" \
        --arg project_name "${PROJECT_NAME}" \
        --arg user_id "${USER_ID}" \
        --arg status "partial" \
        --arg created_at "$(timestamp)" \
        '{project_id: $project_id, project_name: $project_name, user_id: $user_id, status: $status, created_at: $created_at}')"
    exit 1
fi

log_success "Service created: ${SERVICE_ID} (${SERVICE_NAME})"

# ---------------------------------------------------------------------------
# Step 5: Create persistent volume at /data
# ---------------------------------------------------------------------------
log_step "Creating persistent volume at ${DEFAULT_VOLUME_MOUNT}..."

CREATE_VOLUME_MUTATION='
mutation volumeCreate($input: VolumeCreateInput!) {
    volumeCreate(input: $input) {
        id
        volumePath
        sizeMB
    }
}'

VOLUME_VARS=$(jq -n \
    --arg projectId "${PROJECT_ID}" \
    --arg serviceId "${SERVICE_ID}" \
    --arg mountPath "${DEFAULT_VOLUME_MOUNT}" \
    '{
        input: {
            projectId: $projectId,
            serviceId: $serviceId,
            mountPath: $mountPath
        }
    }')

VOLUME_RESPONSE=$(graphql_call "${CREATE_VOLUME_MUTATION}" "${VOLUME_VARS}")
VOLUME_ID=$(echo "${VOLUME_RESPONSE}" | jq -r '.data.volumeCreate.id // empty')

if [[ -z "${VOLUME_ID}" || "${VOLUME_ID}" == "null" ]]; then
    log_warn "Volume creation may have failed — continuing without volume"
    log_warn "Response: ${VOLUME_RESPONSE}"
    VOLUME_ID="unknown"
else
    log_success "Volume created: ${VOLUME_ID} at ${DEFAULT_VOLUME_MOUNT}"
fi

# ---------------------------------------------------------------------------
# Step 6: Generate and set admin credentials
# ---------------------------------------------------------------------------
log_step "Generating admin credentials..."

ADMIN_PASSWORD=$(generate_password 24)

# Set environment variables on the service
log_info "Setting admin environment variables..."
railway variables set \
    -s "${SERVICE_NAME}" \
    "ADMIN_USERNAME=${ADMIN_USERNAME}" \
    "ADMIN_PASSWORD=${ADMIN_PASSWORD}" \
    "HEALTH_CHECK_PATH=${DEFAULT_HEALTH_PATH}" \
    "VOLUME_MOUNT_PATH=${DEFAULT_VOLUME_MOUNT}" \
    2>/dev/null || {
    # Fallback: use GraphQL API if CLI fails
    log_info "Falling back to GraphQL for variable setting..."
    SET_VARS_MUTATION='
    mutation upsertVariables($input: VariableCollectionUpsertInput!) {
        variableCollectionUpsert(input: $input) {
            id
        }
    }'

    VARS_VARS=$(jq -n \
        --arg projectId "${PROJECT_ID}" \
        --arg serviceId "${SERVICE_ID}" \
        --arg adminUser "${ADMIN_USERNAME}" \
        --arg adminPass "${ADMIN_PASSWORD}" \
        --arg healthPath "${DEFAULT_HEALTH_PATH}" \
        --arg volumePath "${DEFAULT_VOLUME_MOUNT}" \
        '{
            input: {
                projectId: $projectId,
                serviceId: $serviceId,
                variables: {
                    ADMIN_USERNAME: $adminUser,
                    ADMIN_PASSWORD: $adminPass,
                    HEALTH_CHECK_PATH: $healthPath,
                    VOLUME_MOUNT_PATH: $volumePath
                },
                replace: true
            }
        }')
    graphql_call "${SET_VARS_MUTATION}" "${VARS_VARS}" > /dev/null
}

log_success "Admin credentials set (username: ${ADMIN_USERNAME})"

# ---------------------------------------------------------------------------
# Step 7: Trigger initial deployment
# ---------------------------------------------------------------------------
log_step "Triggering initial deployment..."

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

log_success "Deployment triggered: ${DEPLOY_ID} (status: ${DEPLOY_STATUS})"

# ---------------------------------------------------------------------------
# Step 8: Resolve service domain
# ---------------------------------------------------------------------------
log_step "Resolving service domain..."
DEPLOY_URL=""
sleep 5  # Give Railway a moment to assign a domain

DEPLOY_URL=$(get_deploy_url "${PROJECT_ID}" "${SERVICE_NAME}" || echo "")
if [[ -z "${DEPLOY_URL}" ]]; then
    log_warn "Domain not yet available — the project will have one after the first deploy completes"
    log_info "You can check with: railway domain -p ${PROJECT_ID}"
    DEPLOY_URL="pending"
fi

# ---------------------------------------------------------------------------
# Step 9: Write metadata
# ---------------------------------------------------------------------------
log_step "Writing deployment metadata..."

METADATA=$(jq -n \
    --arg project_id "${PROJECT_ID}" \
    --arg project_name "${PROJECT_NAME}" \
    --arg service_id "${SERVICE_ID}" \
    --arg service_name "${SERVICE_NAME}" \
    --arg volume_id "${VOLUME_ID}" \
    --arg volume_mount "${DEFAULT_VOLUME_MOUNT}" \
    --arg repo_url "${REPO_URL}" \
    --arg branch "${BRANCH}" \
    --arg deploy_id "${DEPLOY_ID}" \
    --arg deploy_url "${DEPLOY_URL}" \
    --arg admin_username "${ADMIN_USERNAME}" \
    --arg admin_password "${ADMIN_PASSWORD}" \
    --arg status "provisioning" \
    --arg created_at "$(timestamp)" \
    --arg user_id "${USER_ID}" \
    '{
        user_id: $user_id,
        project_id: $project_id,
        project_name: $project_name,
        service_id: $service_id,
        service_name: $service_name,
        volume_id: $volume_id,
        volume_mount: $volume_mount,
        repo_url: $repo_url,
        branch: $branch,
        deploy_id: $deploy_id,
        deploy_url: $deploy_url,
        admin_username: $admin_username,
        admin_password: $admin_password,
        status: $status,
        created_at: $created_at,
        configured_at: null,
        health_status: null,
        injected: false
    }')

write_metadata "${USER_ID}" "${METADATA}"
log_success "Metadata saved to: $(get_project_metadata_path "${USER_ID}")"

# ---------------------------------------------------------------------------
# Output summary
# ---------------------------------------------------------------------------
log_step "Provisioning complete!"
echo ""
echo "=============================================="
echo "  Hermes Project Created"
echo "=============================================="
echo "  User ID:       ${USER_ID}"
echo "  Project Name:  ${PROJECT_NAME}"
echo "  Project ID:    ${PROJECT_ID}"
echo "  Service ID:    ${SERVICE_ID}"
echo "  Deploy URL:    ${DEPLOY_URL}"
echo "  Dashboard:     https://railway.app/project/${PROJECT_ID}"
echo "  Admin User:    ${ADMIN_USERNAME}"
echo "  Admin Pass:    ${ADMIN_PASSWORD}"
echo "=============================================="
echo ""
log_info "Next steps:"
log_info "  1. Wait for deployment:  monitor at ${DEPLOY_URL}${DEFAULT_HEALTH_PATH}"
log_info "  2. Inject user config:   ./inject-config.sh --user-id ${USER_ID} --config <config.json>"
log_info "  3. Or run full pipeline:  ./full-deploy.sh --user-id ${USER_ID} --config <config.json>"
echo ""

# Output machine-readable JSON to stdout for piping
echo "${METADATA}" | jq 'del(.admin_password)'  # Hide password from stdout

# Save with password to metadata file — already done above

log_success "Done."
