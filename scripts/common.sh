#!/usr/bin/env bash
# =============================================================================
# common.sh - Shared utilities for Hermes Railway automation scripts
# =============================================================================
# This file is sourced by all other scripts in this directory.
# It provides logging, API helpers, validation, config loading, and
# error handling shared across the Hermes platform deployment tooling.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# ANSI color codes
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly COLOR_RESET='\033[0m'
    readonly COLOR_BOLD='\033[1m'
    readonly COLOR_DIM='\033[2m'
    readonly COLOR_GREEN='\033[0;32m'
    readonly COLOR_RED='\033[0;31m'
    readonly COLOR_YELLOW='\033[0;33m'
    readonly COLOR_BLUE='\033[0;34m'
    readonly COLOR_CYAN='\033[0;36m'
    readonly COLOR_MAGENTA='\033[0;35m'
else
    # No color when output is not a terminal (e.g. CI, pipes)
    readonly COLOR_RESET=''
    readonly COLOR_BOLD=''
    readonly COLOR_DIM=''
    readonly COLOR_GREEN=''
    readonly COLOR_RED=''
    readonly COLOR_YELLOW=''
    readonly COLOR_BLUE=''
    readonly COLOR_CYAN=''
    readonly COLOR_MAGENTA=''
fi

# ---------------------------------------------------------------------------
# Global constants
# ---------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly DATA_DIR="${PROJECT_ROOT}/data"
readonly PROJECTS_DIR="${DATA_DIR}/projects"
readonly LOG_DIR="${DATA_DIR}/logs"
readonly METADATA_DIR="${PROJECTS_DIR}"

# Default Railway API endpoint
readonly RAILWAY_API_URL="${RAILWAY_API_URL:-https://backboard.railway.app/graphql/v2}"

# Health check settings
readonly HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-10}"
readonly HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-600}"
readonly HEALTH_CHECK_ENDPOINT="${HEALTH_CHECK_ENDPOINT:-/health}"

# ---------------------------------------------------------------------------
# Logging functions
# ---------------------------------------------------------------------------
log_info() {
    printf "${COLOR_BLUE}[INFO]${COLOR_RESET}  %s %s\n" "$(timestamp)" "$*"
}

log_success() {
    printf "${COLOR_GREEN}[OK]${COLOR_RESET}    %s %s\n" "$(timestamp)" "$*"
}

log_error() {
    printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s %s\n" "$(timestamp)" "$*" >&2
}

log_warn() {
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET}  %s %s\n" "$(timestamp)" "$*" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        printf "${COLOR_DIM}[DEBUG]${COLOR_RESET} %s %s\n" "$(timestamp)" "$*"
    fi
}

log_step() {
    printf "${COLOR_CYAN}[STEP]${COLOR_RESET}  %s %s\n" "$(timestamp)" "$*"
}

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line_no=$1
    log_error "Script failed at line ${line_no} with exit code ${exit_code}"
    # Print a condensed stack trace
    local i=0
    local frame
    while frame=$(caller $i 2>/dev/null); do
        log_error "  trace[${i}]: ${frame}"
        ((i++))
    done
    exit "${exit_code}"
}

# Install the error trap — scripts sourcing common.sh get this automatically.
# Individual scripts can override by setting their own trap after sourcing.
trap 'on_error ${LINENO}' ERR

# ---------------------------------------------------------------------------
# Directory setup
# ---------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "${PROJECTS_DIR}" "${LOG_DIR}"
}

# ---------------------------------------------------------------------------
# Environment validation
# ---------------------------------------------------------------------------
validate_env_vars() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("${var}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required environment variables: ${missing[*]}"
        log_error "Please set them and try again."
        return 1
    fi
}

require_railway_token() {
    if [[ -z "${RAILWAY_TOKEN:-}" ]]; then
        log_error "RAILWAY_TOKEN environment variable is not set."
        log_error "Generate a token at https://railway.app/account/tokens"
        log_error "Then run: export RAILWAY_TOKEN=your-token-here"
        return 1
    fi
    log_debug "RAILWAY_TOKEN is set"
}

# ---------------------------------------------------------------------------
# User ID validation (alphanumeric, hyphens, underscores, 3-64 chars)
# ---------------------------------------------------------------------------
validate_user_id() {
    local user_id="$1"
    if [[ ! "${user_id}" =~ ^[a-zA-Z0-9_-]{3,64}$ ]]; then
        log_error "Invalid user ID: '${user_id}'"
        log_error "User ID must be 3-64 characters: alphanumeric, hyphens, underscores"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Config file loading
# ---------------------------------------------------------------------------
load_config_file() {
    local config_path="$1"
    if [[ ! -f "${config_path}" ]]; then
        log_error "Config file not found: ${config_path}"
        return 1
    fi
    if ! jq empty "${config_path}" 2>/dev/null; then
        log_error "Config file is not valid JSON: ${config_path}"
        return 1
    fi
    log_debug "Config file loaded and validated: ${config_path}"
}

# ---------------------------------------------------------------------------
# Metadata file helpers
# ---------------------------------------------------------------------------
get_project_metadata_path() {
    local user_id="$1"
    echo "${PROJECTS_DIR}/${user_id}.json"
}

read_metadata() {
    local user_id="$1"
    local meta_path
    meta_path="$(get_project_metadata_path "${user_id}")"
    if [[ ! -f "${meta_path}" ]]; then
        log_error "No metadata found for user: ${user_id}"
        log_error "Expected at: ${meta_path}"
        return 1
    fi
    cat "${meta_path}"
}

write_metadata() {
    local user_id="$1"
    local json_data="$2"
    local meta_path
    meta_path="$(get_project_metadata_path "${user_id}")"
    mkdir -p "$(dirname "${meta_path}")"
    echo "${json_data}" | jq '.' > "${meta_path}"
    log_debug "Metadata written to: ${meta_path}"
}

delete_metadata() {
    local user_id="$1"
    local meta_path
    meta_path="$(get_project_metadata_path "${user_id}")"
    if [[ -f "${meta_path}" ]]; then
        rm -f "${meta_path}"
        log_info "Deleted metadata for user: ${user_id}"
    else
        log_warn "No metadata file to delete for user: ${user_id}"
    fi
}

# ---------------------------------------------------------------------------
# Railway API helpers via GraphQL
# ---------------------------------------------------------------------------
graphql_call() {
    local query="$1"
    local variables="${2:-"{}"}"
    local tmp_response
    tmp_response="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '${tmp_response}'" RETURN

    local http_code
    http_code=$(curl -s -w '%{http_code}' -o "${tmp_response}" \
        -X POST "${RAILWAY_API_URL}" \
        -H "Authorization: Bearer ${RAILWAY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg query "${query}" \
            --argjson variables "${variables}" \
            '{query: $query, variables: $variables}')" 2>/dev/null)

    if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
        log_error "GraphQL API returned HTTP ${http_code}"
        log_error "Response: $(cat "${tmp_response}")"
        return 1
    fi

    # Check for GraphQL-level errors
    if jq -e '.errors' "${tmp_response}" > /dev/null 2>&1; then
        log_error "GraphQL errors: $(jq -c '.errors' "${tmp_response}")"
        return 1
    fi

    cat "${tmp_response}"
}

railway_api_call() {
    # Thin wrapper that uses the railway CLI for operations not yet
    # exposed via GraphQL or where CLI is more convenient.
    # All commands pass --json for structured output where supported.
    railway "$@"
}

# ---------------------------------------------------------------------------
# Retry logic
# ---------------------------------------------------------------------------
retry() {
    local max_attempts="${1:-3}"
    local delay_seconds="${2:-5}"
    local description="${3:-operation}"
    shift 3 || true

    local attempt=1
    local exit_code=0

    while [[ ${attempt} -le ${max_attempts} ]]; do
        log_debug "Attempt ${attempt}/${max_attempts}: ${description}"
        if "$@"; then
            return 0
        fi
        exit_code=$?
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            log_warn "${description} failed (attempt ${attempt}/${max_attempts}), retrying in ${delay_seconds}s..."
            sleep "${delay_seconds}"
        fi
        ((attempt++))
    done

    log_error "${description} failed after ${max_attempts} attempts"
    return "${exit_code}"
}

# ---------------------------------------------------------------------------
# Health check polling
# ---------------------------------------------------------------------------
wait_for_health() {
    local url="$1"
    local timeout="${2:-${HEALTH_CHECK_TIMEOUT}}"
    local interval="${3:-${HEALTH_CHECK_INTERVAL}}"

    local elapsed=0
    local health_url="${url}${HEALTH_CHECK_ENDPOINT}"

    log_info "Waiting for service to become healthy at ${health_url}..."
    log_info "Timeout: ${timeout}s, Poll interval: ${interval}s"

    while [[ ${elapsed} -lt ${timeout} ]]; do
        if curl -sf --max-time 5 "${health_url}" > /dev/null 2>&1; then
            log_success "Health check passed after ${elapsed}s"
            return 0
        fi
        log_debug "Health check not ready yet (${elapsed}s elapsed)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    log_error "Health check timed out after ${timeout}s"
    return 1
}

# ---------------------------------------------------------------------------
# URL / endpoint helpers
# ---------------------------------------------------------------------------
get_deploy_url() {
    local project_id="$1"
    local service_name="${2:-hermes-agent}"

    # Query Railway for the service domain
    local result
    result=$(graphql_call '
        query($projectId: String!, $serviceName: String!) {
            project(id: $projectId) {
                services(name: $serviceName) {
                    edges {
                        node {
                            domains {
                                serviceDomains {
                                    domain
                                }
                            }
                        }
                    }
                }
            }
        }' "{\"projectId\": \"${project_id}\", \"serviceName\": \"${service_name}\"}")

    # Extract domain from response
    local domain
    domain=$(echo "${result}" | jq -r '.data.project.services.edges[0].node.domains.serviceDomains[0].domain // empty' 2>/dev/null)

    if [[ -z "${domain}" || "${domain}" == "null" ]]; then
        log_warn "Could not resolve service domain for project ${project_id}"
        echo ""
        return 1
    fi

    echo "https://${domain}"
}

# ---------------------------------------------------------------------------
# Generate secure random password
# ---------------------------------------------------------------------------
generate_password() {
    local length="${1:-24}"
    LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()-_=+' < /dev/urandom | head -c "${length}"
}

# ---------------------------------------------------------------------------
# Dry-run mode
# ---------------------------------------------------------------------------
dry_run_enabled() {
    [[ "${DRY_RUN:-0}" == "1" ]]
}

dry_run_log() {
    if dry_run_enabled; then
        printf "${COLOR_MAGENTA}[DRY-RUN]${COLOR_RESET} %s\n" "$*"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing helpers
# ---------------------------------------------------------------------------
parse_common_args() {
    # Parses --dry-run, --debug, and other flags shared across scripts.
    # Call this early in each script's argument loop.
    # Sets: DRY_RUN, DEBUG, FORCE
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                export DRY_RUN=1
                shift
                ;;
            --debug)
                export DEBUG=1
                shift
                ;;
            --force)
                export FORCE=1
                shift
                ;;
            *)
                # Unknown flag — caller should handle
                break
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Initialize on source
# ---------------------------------------------------------------------------
ensure_directories
