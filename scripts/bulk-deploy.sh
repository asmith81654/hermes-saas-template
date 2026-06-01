#!/usr/bin/env bash
# =============================================================================
# bulk-deploy.sh - Deploy Hermes agents for multiple users
# =============================================================================
# Reads a CSV or JSON file listing users and their configurations,
# then deploys each user's Hermes instance via the full-deploy pipeline.
# Supports sequential and parallel execution with detailed reporting.
#
# Usage:
#   ./bulk-deploy.sh --input <users.csv> [--parallel <n>] [--dry-run] [--debug]
#
# Required environment variables:
#   RAILWAY_TOKEN - Railway API token
#
# Input formats:
#
#   CSV (users.csv):
#     user-id,email,config-file-path,name,repo-url,branch
#     alice,alice@example.com,configs/alice.json,hermes-alice,,
#     bob,bob@example.com,configs/bob.json,,https://...,feature
#
#   JSON (users.json):
#     [
#       {
#         "user_id": "alice",
#         "email": "alice@example.com",
#         "config": "configs/alice.json",
#         "name": "hermes-alice",
#         "repo_url": "",
#         "branch": ""
#       }
#     ]
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
FULL_DEPLOY_SCRIPT="${SCRIPT_DIR}/full-deploy.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEFAULT_PARALLEL="${DEFAULT_PARALLEL:-1}"
REPORT_FILE=""
INPUT_FILE=""
PARALLEL="${DEFAULT_PARALLEL}"

# Results tracking
declare -a RESULTS=()
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0
START_TIME=""
END_TIME=""

# Temp directory for parallel job outputs
JOBS_DIR=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat << 'EOF'
Usage: bulk-deploy.sh --input <file.csv|file.json> [options]

Deploy Hermes Agent instances for multiple users from a CSV or JSON file.

Required:
  --input <file>            Input file in CSV or JSON format

Options:
  --parallel <n>            Max concurrent deployments (default: 1)
  --output-report <file>    Write JSON report to this file
  --continue-on-error       Continue deploying remaining users on failure
  --dry-run                 Parse input and show plan without deploying
  --debug                   Enable debug output
  --help                    Show this help message

Environment:
  RAILWAY_TOKEN             Railway API token (required)

Input formats:
  CSV:  user-id,email,config-file-path[,name][,repo-url][,branch]
  JSON: Array of objects with keys: user_id, email, config, name, repo_url, branch
        (only user_id and config are required)

Examples:
  ./bulk-deploy.sh --input users.csv
  ./bulk-deploy.sh --input users.json --parallel 5
  ./bulk-deploy.sh --input users.csv --dry-run
  ./bulk-deploy.sh --input users.csv --continue-on-error --output-report report.json
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
CONTINUE_ON_ERROR=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)
            INPUT_FILE="$2"
            shift 2
            ;;
        --parallel)
            PARALLEL="$2"
            if ! [[ "${PARALLEL}" =~ ^[0-9]+$ ]] || [[ "${PARALLEL}" -lt 1 ]]; then
                log_error "--parallel must be a positive integer"
                exit 1
            fi
            shift 2
            ;;
        --output-report)
            REPORT_FILE="$2"
            shift 2
            ;;
        --continue-on-error)
            CONTINUE_ON_ERROR=1
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
if [[ -z "${INPUT_FILE}" ]]; then
    log_error "--input is required"
    echo "Use --help for usage information."
    exit 1
fi

if [[ ! -f "${INPUT_FILE}" ]]; then
    log_error "Input file not found: ${INPUT_FILE}"
    exit 1
fi

require_railway_token

if [[ ! -x "${FULL_DEPLOY_SCRIPT}" ]]; then
    log_error "full-deploy.sh not found or not executable: ${FULL_DEPLOY_SCRIPT}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse input file
# ---------------------------------------------------------------------------
log_step "Parsing input file: ${INPUT_FILE}..."

# Determine format by extension
INPUT_EXT="${INPUT_FILE##*.}"
INPUT_EXT="${INPUT_EXT,,}"  # lowercase

declare -a USER_ROWS=()

parse_csv() {
    local file="$1"
    local line_num=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        ((line_num++))
        # Skip empty lines and comments
        [[ -z "$(echo "${line}" | tr -d '[:space:]')" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue

        # Parse CSV fields (handle commas correctly with basic field splitting)
        IFS=',' read -ra FIELDS <<< "${line}"

        local user_id="${FIELDS[0]:-}"
        local email="${FIELDS[1]:-}"
        local config="${FIELDS[2]:-}"
        local name="${FIELDS[3]:-}"
        local repo_url="${FIELDS[4]:-}"
        local branch="${FIELDS[5]:-}"

        # Trim whitespace
        user_id=$(echo "${user_id}" | xargs)
        email=$(echo "${email}" | xargs)
        config=$(echo "${config}" | xargs)
        name=$(echo "${name}" | xargs)
        repo_url=$(echo "${repo_url}" | xargs)
        branch=$(echo "${branch}" | xargs)

        if [[ -z "${user_id}" ]]; then
            log_warn "Line ${line_num}: skipping — empty user-id"
            continue
        fi

        if [[ -z "${config}" ]]; then
            log_warn "Line ${line_num}: skipping user '${user_id}' — no config file"
            continue
        fi

        # Resolve config path (relative to input file directory)
        local input_dir
        input_dir="$(cd "$(dirname "${file}")" && pwd)"
        if [[ "${config}" != /* ]]; then
            config="${input_dir}/${config}"
        fi

        USER_ROWS+=("${user_id}|${email}|${config}|${name}|${repo_url}|${branch}")
    done < "${file}"

    log_info "Parsed ${#USER_ROWS[@]} user(s) from CSV"
}

parse_json() {
    local file="$1"
    local count
    count=$(jq '. | length' "${file}")

    for ((i=0; i<count; i++)); do
        local user_id email config name repo_url branch
        user_id=$(jq -r ".[${i}].user_id // empty" "${file}")
        email=$(jq -r ".[${i}].email // empty" "${file}")
        config=$(jq -r ".[${i}].config // empty" "${file}")
        name=$(jq -r ".[${i}].name // empty" "${file}")
        repo_url=$(jq -r ".[${i}].repo_url // empty" "${file}")
        branch=$(jq -r ".[${i}].branch // empty" "${file}")

        if [[ -z "${user_id}" ]]; then
            log_warn "Entry ${i}: skipping — empty user_id"
            continue
        fi

        if [[ -z "${config}" ]]; then
            log_warn "Entry ${i}: skipping user '${user_id}' — no config file"
            continue
        fi

        # Resolve config path
        local input_dir
        input_dir="$(cd "$(dirname "${file}")" && pwd)"
        if [[ "${config}" != /* ]]; then
            config="${input_dir}/${config}"
        fi

        USER_ROWS+=("${user_id}|${email}|${config}|${name}|${repo_url}|${branch}")
    done

    log_info "Parsed ${#USER_ROWS[@]} user(s) from JSON"
}

# Dispatch to parser
if [[ "${INPUT_EXT}" == "json" ]]; then
    # Validate JSON first
    if ! jq empty "${INPUT_FILE}" 2>/dev/null; then
        log_error "Input file is not valid JSON"
        exit 1
    fi
    parse_json "${INPUT_FILE}"
elif [[ "${INPUT_EXT}" == "csv" ]]; then
    parse_csv "${INPUT_FILE}"
else
    log_error "Unsupported input format: .${INPUT_EXT}"
    log_error "Use .csv or .json files"
    exit 1
fi

TOTAL_COUNT=${#USER_ROWS[@]}

if [[ ${TOTAL_COUNT} -eq 0 ]]; then
    log_error "No valid user entries found in input file"
    exit 1
fi

# ---------------------------------------------------------------------------
# Dry-run: print plan
# ---------------------------------------------------------------------------
if dry_run_enabled; then
    echo ""
    log_info "=== DRY RUN — Bulk Deployment Plan ==="
    echo ""
    echo "  Total users:   ${TOTAL_COUNT}"
    echo "  Max parallel:  ${PARALLEL}"
    echo "  Input file:    ${INPUT_FILE}"
    echo ""
    echo "Users to deploy:"
    echo "----------------------------------------"
    for row in "${USER_ROWS[@]}"; do
        IFS='|' read -r uid email cfg name repo branch <<< "${row}"
        printf "  %-20s | %-30s | %-20s | %s\n" \
            "${uid}" "${email:-N/A}" "${name:-hermes-${uid}}" "${cfg}"
    done
    echo "----------------------------------------"
    echo ""
    log_info "No deployments will be made. Remove --dry-run to execute."
    exit 0
fi

# ---------------------------------------------------------------------------
# Deploy a single user
# ---------------------------------------------------------------------------
deploy_user() {
    local row="$1"
    local index="$2"

    IFS='|' read -r uid email cfg name repo_url branch <<< "${row}"

    local deploy_args=(--user-id "${uid}" --config "${cfg}")

    if [[ -n "${email}" ]]; then
        deploy_args+=(--email "${email}")
    fi
    if [[ -n "${name}" ]]; then
        deploy_args+=(--name "${name}")
    fi
    if [[ -n "${repo_url}" ]]; then
        deploy_args+=(--repo-url "${repo_url}")
    fi
    if [[ -n "${branch}" ]]; then
        deploy_args+=(--branch "${branch}")
    fi

    local log_file="${JOBS_DIR}/${uid}.log"
    local result_file="${JOBS_DIR}/${uid}.result"

    log_info "[${index}/${TOTAL_COUNT}] Deploying user: ${uid}"

    # Run full-deploy and capture output
    if "${FULL_DEPLOY_SCRIPT}" "${deploy_args[@]}" > "${log_file}" 2>&1; then
        echo "success" > "${result_file}"
        # Extract deploy URL from log
        local deploy_url
        deploy_url=$(grep -o '"deploy_url"[[:space:]]*:[[:space:]]*"[^"]*"' "${log_file}" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || echo "unknown")
        log_success "[${index}/${TOTAL_COUNT}] ${uid} — deployed at ${deploy_url}"
        echo "SUCCESS|${uid}|${deploy_url}" >> "${JOBS_DIR}/results.txt"
    else
        echo "failure" > "${result_file}"
        local error_msg
        error_msg=$(tail -20 "${log_file}" | grep -i 'error\|fatal\|fail' | head -3 | tr '\n' '; ' || echo "Unknown error")
        log_error "[${index}/${TOTAL_COUNT}] ${uid} — FAILED: ${error_msg}"
        echo "FAILURE|${uid}|${error_msg}" >> "${JOBS_DIR}/results.txt"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Sequential deployment
# ---------------------------------------------------------------------------
deploy_sequential() {
    local index=1
    for row in "${USER_ROWS[@]}"; do
        IFS='|' read -r uid email cfg name repo_url branch <<< "${row}"

        if deploy_user "${row}" "${index}"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            if [[ ${CONTINUE_ON_ERROR} -ne 1 ]]; then
                log_error "Deployment failed for user '${uid}'"
                log_error "Use --continue-on-error to keep deploying remaining users"
                log_info "Deployed: ${SUCCESS_COUNT} succeeded, ${FAIL_COUNT} failed (out of ${index}/${TOTAL_COUNT})"
                return 1
            fi
        fi
        index=$((index + 1))
    done
}

# ---------------------------------------------------------------------------
# Parallel deployment
# ---------------------------------------------------------------------------
deploy_parallel() {
    local max_jobs="$1"
    local running=0
    local index=1
    local row_index=0
    declare -a pids=()
    declare -A pid_to_uid=()

    for row in "${USER_ROWS[@]}"; do
        ((row_index++))

        IFS='|' read -r uid email cfg name repo_url branch <<< "${row}"

        # Wait if we've reached max parallelism
        while [[ ${running} -ge ${max_jobs} ]]; do
            # Wait for any child to finish
            if wait -n 2>/dev/null; then
                running=$((running - 1))
            else
                # A child failed
                running=$((running - 1))
            fi
        done

        # Launch deployment in background
        deploy_user "${row}" "${index}" &
        pids+=($!)
        pid_to_uid[$!]="${uid}"
        running=$((running + 1))
        index=$((index + 1))
    done

    # Wait for remaining jobs
    for pid in "${pids[@]}"; do
        local uid="${pid_to_uid[${pid}]}"
        if wait "${pid}" 2>/dev/null; then
            :
        else
            if [[ ${CONTINUE_ON_ERROR} -ne 1 ]]; then
                log_error "Deployment failed for user '${uid}' (and --continue-on-error not set)"
                # Let remaining jobs finish but stop new ones
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# Execute deployments
# ---------------------------------------------------------------------------
log_step "Starting bulk deployment of ${TOTAL_COUNT} user(s)..."

# Create jobs directory for logs and results
JOBS_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${JOBS_DIR}'" EXIT

START_TIME=$(timestamp)
DEPLOY_START=$(date +%s)

if [[ "${PARALLEL}" -gt 1 ]]; then
    log_info "Running with parallelism: ${PARALLEL}"
    deploy_parallel "${PARALLEL}" || true
else
    log_info "Running sequentially"
    deploy_sequential || true
fi

DEPLOY_END=$(date +%s)
DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))
END_TIME=$(timestamp)

# ---------------------------------------------------------------------------
# Aggregate results
# ---------------------------------------------------------------------------
log_step "Aggregating results..."

RESULTS_FILE="${JOBS_DIR}/results.txt"
SUCCESS_COUNT=0
FAIL_COUNT=0
declare -a SUCCESS_USERS=()
declare -a FAIL_USERS=()

if [[ -f "${RESULTS_FILE}" ]]; then
    while IFS='|' read -r status uid detail; do
        case "${status}" in
            SUCCESS)
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                SUCCESS_USERS+=("${uid}: ${detail}")
                ;;
            FAILURE)
                FAIL_COUNT=$((FAIL_COUNT + 1))
                FAIL_USERS+=("${uid}: ${detail}")
                ;;
        esac
    done < "${RESULTS_FILE}"
fi

# ---------------------------------------------------------------------------
# Generate report
# ---------------------------------------------------------------------------
log_step "Generating deployment report..."

# Build JSON report
REPORT_JSON=$(jq -n \
    --arg started_at "${START_TIME}" \
    --arg ended_at "${END_TIME}" \
    --argjson duration "${DEPLOY_DURATION}" \
    --argjson total "${TOTAL_COUNT}" \
    --argjson success "${SUCCESS_COUNT}" \
    --argjson failed "${FAIL_COUNT}" \
    --argjson parallel "${PARALLEL}" \
    --arg input_file "${INPUT_FILE}" \
    '{
        started_at: $started_at,
        ended_at: $ended_at,
        duration_seconds: $duration,
        total: $total,
        success: $success,
        failed: $failed,
        parallel: $parallel,
        input_file: $input_file,
        succeeded: [],
        failures: []
    }')

# Add success entries
for entry in "${SUCCESS_USERS[@]}"; do
    uid="${entry%%:*}"
    url="${entry#*: }"
    REPORT_JSON=$(echo "${REPORT_JSON}" | jq \
        --arg uid "${uid}" \
        --arg url "${url}" \
        '.succeeded += [{"user_id": $uid, "url": $url}]')
done

# Add failure entries
for entry in "${FAIL_USERS[@]}"; do
    uid="${entry%%:*}"
    err="${entry#*: }"
    REPORT_JSON=$(echo "${REPORT_JSON}" | jq \
        --arg uid "${uid}" \
        --arg err "${err}" \
        '.failures += [{"user_id": $uid, "error": $err}]')
done

# Write report to file if requested
if [[ -n "${REPORT_FILE}" ]]; then
    echo "${REPORT_JSON}" | jq '.' > "${REPORT_FILE}"
    log_info "Report written to: ${REPORT_FILE}"
fi

# ---------------------------------------------------------------------------
# Summary output
# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            BULK DEPLOYMENT COMPLETE                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-56s ║\n" "Total users:      ${TOTAL_COUNT}"
printf "║  %-56s ║\n" "Succeeded:        ${SUCCESS_COUNT}"
printf "║  %-56s ║\n" "Failed:           ${FAIL_COUNT}"
printf "║  %-56s ║\n" "Duration:         ${DEPLOY_DURATION}s"
printf "║  %-56s ║\n" "Parallelism:      ${PARALLEL}"
echo "╠══════════════════════════════════════════════════════════════╣"

if [[ ${SUCCESS_COUNT} -gt 0 ]]; then
    echo "║  Successful deployments:"
    for entry in "${SUCCESS_USERS[@]}"; do
        printf "║    ${COLOR_GREEN}✔${COLOR_RESET} %s\n" "${entry}"
    done
fi

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo "║  Failed deployments:"
    for entry in "${FAIL_USERS[@]}"; do
        printf "║    ${COLOR_RED}✘${COLOR_RESET} %s\n" "${entry}"
    done
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Print report JSON to stdout for piping
echo "${REPORT_JSON}" | jq '.'

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    log_warn "${FAIL_COUNT} deployment(s) failed. Check the report above for details."
    if [[ -n "${REPORT_FILE}" ]]; then
        log_info "Full report saved to: ${REPORT_FILE}"
    fi
    exit 1
else
    log_success "All ${SUCCESS_COUNT} deployment(s) completed successfully!"
fi
