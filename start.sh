#!/usr/bin/env bash
# =============================================================================
# Hermes Agent Railway SaaS — Startup Script
# =============================================================================
# Prepares the persistent /data volume, initializes default agent config,
# and launches the web dashboard + gateway manager.
# =============================================================================

set -euo pipefail

# ── Paths ───────────────────────────────────────────────────────────────────
HERMES_ROOT="${HERMES_HOME:-/data/.hermes}"
CONFIG_DIR="${HERMES_ROOT}/config"
AGENT_CONFIG="${CONFIG_DIR}/default_agent.json"

# ── Logging helpers ─────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die()  { log "FATAL: $*" >&2; exit 1; }

log "=== Hermes Agent SaaS starting ==="
log "HOME=${HOME}"
log "HERMES_HOME=${HERMES_HOME}"
log "PORT=${PORT:-8080}"

# ── Create persistent directories ───────────────────────────────────────────
log "Creating persistent directories under ${HERMES_ROOT} ..."
mkdir -p "${HERMES_ROOT}"/{sessions,skills,workspace,pairing,config,logs}
log "Directories ready."

# ── Install bundled skills into runtime ─────────────────────────────────────
if [ -d "/app/skills" ]; then
    log "Installing bundled skills from /app/skills ..."
    cp -rn /app/skills/* "${HERMES_ROOT}/skills/" 2>/dev/null || true
    for skill_dir in /app/skills/*/; do
        skill_name=$(basename "$skill_dir")
        cp -r "$skill_dir"* "${HERMES_ROOT}/skills/${skill_name}/" 2>/dev/null || true
    done
    log "Skills installed: $(ls ${HERMES_ROOT}/skills/ | tr '\n' ' ')"
fi

# ── Initialize default agent configuration from environment variables ────────
# These env vars are set by Railway per-user deployment:
#   HERMES_DEFAULT_AGENT_NAME         — display name for the default agent
#   HERMES_DEFAULT_AGENT_SYSTEM_PROMPT — system prompt that defines behavior
#   HERMES_DEFAULT_AGENT_MODEL        — LLM model identifier
#   HERMES_DEFAULT_AGENT_TOOLS        — comma-separated tool list (optional)

DEFAULT_NAME="${HERMES_DEFAULT_AGENT_NAME:-Hermes Assistant}"
DEFAULT_MODEL="${HERMES_DEFAULT_AGENT_MODEL:-openrouter/openai/gpt-4o}"

if [ -n "${HERMES_DEFAULT_AGENT_SYSTEM_PROMPT:-}" ] || [ ! -f "${AGENT_CONFIG}" ]; then
    log "Initializing default agent configuration ..."

    # Build the default agent JSON config
    cat > "${AGENT_CONFIG}" <<AGENTEOF
{
  "name": "${DEFAULT_NAME}",
  "type": "default",
  "model": "${DEFAULT_MODEL}",
  "system_prompt": $(printf '%s' "${HERMES_DEFAULT_AGENT_SYSTEM_PROMPT:-You are a helpful AI assistant powered by Hermes.}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "tools": $(printf '%s' "${HERMES_DEFAULT_AGENT_TOOLS:-}" | python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.dumps([x.strip() for x in t.split(",") if x.strip()]) if t else "[]")'),
  "created_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "version": "1.0"
}
AGENTEOF

    log "Default agent config written to ${AGENT_CONFIG}"
else
    log "Default agent config already exists at ${AGENT_CONFIG}, skipping initialization."
fi

# ── Show environment summary (redact secrets) ────────────────────────────────
log "=== Environment Summary ==="
log "Providers configured:"
for var in OPENROUTER_API_KEY OPENAI_API_KEY DEEPSEEK_API_KEY \
           ANTHROPIC_API_KEY GOOGLE_API_KEY GROQ_API_KEY \
           XAI_API_KEY TOGETHER_API_KEY; do
    if [ -n "${!var:-}" ]; then
        log "  [x] ${var%%_API_KEY} (set)"
    fi
done

log "Channels configured:"
for var in TELEGRAM_BOT_TOKEN SLACK_BOT_TOKEN SLACK_APP_TOKEN \
           DISCORD_BOT_TOKEN WHATSAPP_TOKEN MSTEAMS_CLIENT_ID \
           MATRIX_HOMESERVER TWITTER_USERNAME; do
    if [ -n "${!var:-}" ]; then
        channel="${var%%_*}"
        log "  [x] ${channel} (set)"
    fi
done



# ── LLM Provider Configuration ──────────────────────────────────────────────
# Write hermes config.yaml with the LLM provider if env vars are set
LLM_CFG="${HERMES_HOME}/config.yaml"
if [ -n "${OPENAI_API_KEY:-}" ] && [ ! -f "${LLM_CFG}" ]; then
    log "Writing LLM provider config to ${LLM_CFG}"
    cat > "${LLM_CFG}" <<LLMEOF
providers:
  openai:
    api_key: "${OPENAI_API_KEY}"
    base_url: "${OPENAI_BASE_URL:-https://api.openai.com/v1}"
default_model: "${HERMES_DEFAULT_AGENT_MODEL:-MiniMax-M3}"
LLMEOF
    log "LLM provider configured (model: ${HERMES_DEFAULT_AGENT_MODEL:-MiniMax-M3})"
fi

# ── API Server Port Configuration ──────────────────────────────────────────
# When API_SERVER_ENABLED=true, hermes API server handles external traffic.
# Management dashboard moves to internal port 8081.
if [ "${API_SERVER_ENABLED:-false}" = "true" ]; then
    export API_SERVER_PORT="${PORT:-8080}"
    export API_SERVER_HOST="0.0.0.0"
    export PORT="8081"
    log "API server on external port ${API_SERVER_PORT}, mgmt on ${PORT}"
fi

# ── Launch server ────────────────────────────────────────────────────────────
log "=== Launching Hermes SaaS server on port ${PORT:-8080} ==="
exec python /app/server.py
