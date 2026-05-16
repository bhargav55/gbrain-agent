#!/bin/bash
set -e

# Railway injects secrets as env vars. Required:
#   TELEGRAM_BOT_TOKEN   - from BotFather
#   OPENCODE_GO_API_KEY  - for kimi-k2.6
# Optional overrides:
#   LLM_MODEL            - default: kimi-k2.6
#   HERMES_PROFILE       - default: gbrain
#   GBRAIN_SEARCH_MODE   - default: balanced

MODEL="${LLM_MODEL:-kimi-k2.6}"
PROVIDER="${LLM_PROVIDER:-opencode-go}"
BASE_URL="${LLM_BASE_URL:-https://opencode.ai/zen/go/v1}"
PROFILE="${HERMES_PROFILE:-gbrain}"
SEARCH_MODE="${GBRAIN_SEARCH_MODE:-balanced}"

export HERMES_HOME="/opt/hermes/.hermes"
export PATH="/opt/hermes/.local/bin:${PATH}"

echo "=== GBrain Agent Bootstrap ==="
echo "Model: ${MODEL}"
echo "Provider: ${PROVIDER}"
echo "Profile: ${PROFILE}"

# 1. Ensure Hermes profile exists
if ! hermes profile list | grep -q "${PROFILE}"; then
    echo "Creating Hermes profile: ${PROFILE}"
    hermes profile create "${PROFILE}" --clone-from default || true
fi

hermes profile use "${PROFILE}"

# Use full path to actual gbrain binary (not the Hermes profile wrapper)
GBRAIN_BIN="/opt/hermes/.bun/bin/gbrain"
if [ ! -x "$GBRAIN_BIN" ]; then
    GBRAIN_BIN="/root/.bun/bin/gbrain"
fi
if [ ! -x "$GBRAIN_BIN" ]; then
    GBRAIN_BIN="$(which gbrain 2>/dev/null || true)"
fi

# 2. Configure Hermes model + provider
cat > "${HERMES_HOME}/config.yaml" <<EOF
model:
  default: ${MODEL}
  provider: ${PROVIDER}
  base_url: ${BASE_URL}
  api_mode: chat_completions
providers: {}
fallback_providers: []
credential_pool_strategies: {}
toolsets:
- hermes-cli
agent:
  max_turns: 60
  gateway_timeout: 1800
  restart_drain_timeout: 180
  api_max_retries: 3
  service_tier: ''
  tool_use_enforcement: auto
  gateway_timeout_warning: 900
  gateway_notify_interval: 180
  gateway_auto_continue_freshness: 3600
  image_input_mode: auto
  disabled_toolsets: []
  verbose: false
  reasoning_effort: medium
terminal:
  backend: local
  modal_mode: auto
  cwd: .
  timeout: 180
  env_passthrough: []
  shell_init_files: []
  auto_source_bashrc: true
  persistent_shell: true
  lifetime_seconds: 300
browser:
  inactivity_timeout: 120
  command_timeout: 30
  record_sessions: false
  allow_private_urls: false
  auto_local_for_private_urls: true
  cdp_url: ''
  dialog_policy: must_respond
  dialog_timeout_s: 300
checkpoints:
  enabled: false
  max_snapshots: 50
display:
  skin: default
  tool_progress: true
  show_reasoning: false
  show_cost: false
compression:
  enabled: true
  threshold: 0.7
  target_ratio: 0.2
memory:
  memory_enabled: true
  user_profile_enabled: true
  provider: built-in
gateway:
  enabled: true
  platforms:
    telegram:
      enabled: true
      bot_token: "${TELEGRAM_BOT_TOKEN}"
      webhook_url: ""
      polling: true
      allowed_usernames: []
      deny_usernames: []
  runtime_footer:
    enabled: false
    fields:
    - model
    - context_pct
security:
  tirith_enabled: true
delegation:
  model: ''
  provider: ''
  max_iterations: 50
smart_model_routing:
  enabled: false
  cheap_model: ''
stt:
  enabled: false
  provider: local
  local:
    model: base
tts:
  provider: edge
mcp_servers:
  gbrain:
    command: gbrain
    args:
      - serve
EOF

# 2. Write API keys to .env
mkdir -p "${HERMES_HOME}"
cat > "${HERMES_HOME}/.env" <<EOF
OPENCODE_GO_API_KEY=${OPENCODE_GO_API_KEY}
GATEWAY_ALLOW_ALL_USERS=true
EOF

# 4. Initialize GBrain brain if not already present
if [ ! -f "${HERMES_HOME}/.gbrain/brain.pglite" ]; then
    echo "Initializing GBrain..."
    mkdir -p "${HERMES_HOME}/.gbrain"
    cd /opt/hermes/gbrain
    # Non-interactive init with PGLite
    echo "${SEARCH_MODE}" | "$GBRAIN_BIN" init || true
    # Configure Ollama embeddings if available locally, otherwise leave default
    if command -v ollama >/dev/null 2>&1; then
        "$GBRAIN_BIN" config set embedding.provider ollama 2>/dev/null || true
        "$GBRAIN_BIN" config set embedding.model nomic-embed-text 2>/dev/null || true
    fi
fi

# 5. Write SOUL.md for brain-first behavior
mkdir -p "${HERMES_HOME}/profiles/${PROFILE}"
cat > "${HERMES_HOME}/profiles/${PROFILE}/SOUL.md" <<'SOUL'
# Hermes Agent Persona

You are a clairvoyant personal assistant powered by GBrain.
Before ANY external API call or web search, check GBrain first.
Use gbrain_query for semantic questions, gbrain_search for keyword lookups,
and gbrain_get_page for known pages. Cite every fact from the brain.
If the brain lacks info, say so -- do not hallucinate.
After gathering external info, write it back to the brain.

Warm, practical, first-principles thinker. Terse directives.
SOUL

# 6. Start a lightweight health-check HTTP server on PORT (Railway requirement)
PORT="${PORT:-8080}"
python3 -m http.server "${PORT}" --bind 0.0.0.0 &

echo "=== Starting Hermes Gateway with GBrain ==="
hermes gateway run
