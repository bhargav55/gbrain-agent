#!/bin/bash
set -e

# Railway injects secrets as env vars. Required:
#   TELEGRAM_BOT_TOKEN   - from BotFather
#   OPENCODE_GO_API_KEY  - for kimi-k2.6
# Optional overrides:
#   LLM_MODEL            - default: kimi-k2.6
#   LLM_PROVIDER         - default: opencode-go
#   LLM_BASE_URL         - default: https://opencode.ai/zen/go/v1
#   LLM_API_MODE         - default: chat_completions
#   LLM_REASONING_EFFORT - default: high
#   CODEX_ACCESS_TOKEN  - OpenAI Codex OAuth access token
#   CODEX_REFRESH_TOKEN - OpenAI Codex OAuth refresh token
#   HERMES_AUTH_JSON_BASE64 - base64-encoded Hermes auth.json fallback
#   HERMES_PROFILE       - default: gbrain
#   GBRAIN_SEARCH_MODE   - default: balanced

MODEL="${LLM_MODEL:-kimi-k2.6}"
PROVIDER="${LLM_PROVIDER:-opencode-go}"
BASE_URL="${LLM_BASE_URL:-https://opencode.ai/zen/go/v1}"
API_MODE="${LLM_API_MODE:-chat_completions}"
REASONING_EFFORT="${LLM_REASONING_EFFORT:-high}"
PROFILE="${HERMES_PROFILE:-gbrain}"
SEARCH_MODE="${GBRAIN_SEARCH_MODE:-balanced}"

if [ -z "${DATA_DIR:-}" ]; then
    DATA_DIR="/data"
fi

mkdir -p "${DATA_DIR}"
if [ ! -w "${DATA_DIR}" ]; then
    echo "DATA_DIR is not writable: ${DATA_DIR}" >&2
    exit 1
fi
export HERMES_HOME="${DATA_DIR}/.hermes"
export HOME="${DATA_DIR}"
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

# 2. Overwrite profile config with correct model (default profile clones claude-opus-4.6)
cat > "${HERMES_HOME}/profiles/${PROFILE}/config.yaml" <<EOF
model:
  default: ${MODEL}
  provider: ${PROVIDER}
  base_url: ${BASE_URL}
  api_mode: ${API_MODE}
EOF

# Use full path to actual gbrain binary (not the Hermes profile wrapper)
GBRAIN_BIN="/opt/hermes/.bun/bin/gbrain"
if [ ! -x "$GBRAIN_BIN" ]; then
    GBRAIN_BIN="/root/.bun/bin/gbrain"
fi
if [ ! -x "$GBRAIN_BIN" ]; then
    GBRAIN_BIN="$(which gbrain 2>/dev/null || true)"
fi
if [ ! -x "$GBRAIN_BIN" ]; then
    echo "Missing gbrain binary" >&2
    exit 1
fi

# The Hermes profile wrapper can shadow the real gbrain CLI. Force plain
# `gbrain` in terminals/scripts to use the persistent GBrain store. Hermes
# may place profile wrappers under either /opt/hermes or $HOME.
mkdir -p "/opt/hermes/.local/bin" "${DATA_DIR}/.local/bin"
for wrapper in "/opt/hermes/.local/bin/gbrain" "${DATA_DIR}/.local/bin/gbrain"; do
cat > "${wrapper}" <<'SH'
#!/bin/sh
if [ -z "${DATA_DIR:-}" ]; then
    DATA_DIR="/data"
fi
export HOME="${DATA_DIR}"
export HERMES_HOME="${DATA_DIR}/.hermes"
exec /opt/hermes/.bun/bin/gbrain "$@"
SH
chmod +x "${wrapper}"
done

# 3. Configure Hermes root config
cat > "${HERMES_HOME}/config.yaml" <<EOF
model:
  default: ${MODEL}
  provider: ${PROVIDER}
  base_url: ${BASE_URL}
  api_mode: ${API_MODE}
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
  reasoning_effort: ${REASONING_EFFORT}
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

telegram:
  enabled: true

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
    command: ${GBRAIN_BIN}
    env:
      DATA_DIR: ${DATA_DIR}
      HOME: ${DATA_DIR}
      HERMES_HOME: ${HERMES_HOME}
    args:
      - serve
EOF

# 4. Write OAuth auth store and API keys to .env
mkdir -p "${HERMES_HOME}"
if [ -n "${CODEX_ACCESS_TOKEN:-}" ] && [ -n "${CODEX_REFRESH_TOKEN:-}" ]; then
    echo "Installing Hermes Codex OAuth auth store from Railway token secrets"
    umask 077
    export HERMES_ACTIVE_PROFILE="${PROFILE}"
    python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

home = Path(os.environ["HERMES_HOME"])
profile = os.environ.get("HERMES_ACTIVE_PROFILE", "").strip()
now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
access_token = os.environ["CODEX_ACCESS_TOKEN"]
refresh_token = os.environ["CODEX_REFRESH_TOKEN"]
auth = {
    "version": 1,
    "providers": {
        "openai-codex": {
            "tokens": {
                "access_token": access_token,
                "refresh_token": refresh_token,
            },
            "last_refresh": now,
            "auth_mode": "chatgpt",
        }
    },
    "credential_pool": {
        "openai-codex": [
            {
                "id": "railway-codex",
                "label": "device_code",
                "auth_type": "oauth",
                "priority": 0,
                "source": "device_code",
                "access_token": access_token,
                "refresh_token": refresh_token,
                "last_status": None,
                "last_status_at": None,
                "last_error_code": None,
                "last_error_reason": None,
                "last_error_message": None,
                "last_error_reset_at": None,
                "base_url": "https://chatgpt.com/backend-api/codex",
                "last_refresh": now,
                "request_count": 0,
            }
        ]
    },
    "active_provider": "openai-codex",
    "updated_at": now,
}
payload = json.dumps(auth, indent=2) + "\n"
(home / "auth.json").write_text(payload)
if profile:
    profile_home = home / "profiles" / profile
    profile_home.mkdir(parents=True, exist_ok=True)
    (profile_home / "auth.json").write_text(payload)
PY
elif [ -n "${HERMES_AUTH_JSON_BASE64:-}" ]; then
    echo "Installing Hermes OAuth auth store from Railway secret"
    umask 077
    printf '%s' "${HERMES_AUTH_JSON_BASE64}" | base64 -d > "${HERMES_HOME}/auth.json"
fi

if [ "${PROVIDER}" = "openai-codex" ]; then
    python3 - <<'PY'
import json
import sys
from pathlib import Path
import os

path = Path(os.environ["HERMES_HOME"]) / "auth.json"
try:
    data = json.loads(path.read_text())
    tokens = data["providers"]["openai-codex"]["tokens"]
    if not tokens.get("access_token") or not tokens.get("refresh_token"):
        raise ValueError("missing Codex tokens")
except Exception as exc:
    print(f"Missing usable Codex auth store at {path}: {exc}", file=sys.stderr)
    sys.exit(1)
print(f"Codex auth store installed at {path}")
PY
fi

cat > "${HERMES_HOME}/.env" <<EOF
OPENCODE_GO_API_KEY=${OPENCODE_GO_API_KEY}
GATEWAY_ALLOW_ALL_USERS=true
EOF

# 5. Initialize GBrain brain if not already present
if [ ! -f "${HERMES_HOME}/.gbrain/brain.pglite" ]; then
    echo "Initializing GBrain..."
    mkdir -p "${HERMES_HOME}/.gbrain"
    cd "${HERMES_HOME}"
    # No embedding provider is configured in this Railway service by default.
    # Initialize anyway so capture/list/status work; embeddings can be enabled later.
    "$GBRAIN_BIN" init --pglite --no-embedding
    "$GBRAIN_BIN" config set search.mode "${SEARCH_MODE}" || true
    # Configure Ollama embeddings if available locally, otherwise leave default
    if command -v ollama >/dev/null 2>&1; then
        "$GBRAIN_BIN" config set embedding.provider ollama 2>/dev/null || true
        "$GBRAIN_BIN" config set embedding.model nomic-embed-text 2>/dev/null || true
    fi
fi

# Keep a git-backed brain repo for recovered/imported conversation pages.
BRAIN_REPO="${DATA_DIR}/brain-repo"
mkdir -p "${BRAIN_REPO}/conversations"
cd "${BRAIN_REPO}"
if [ ! -d .git ]; then
    git init
    git config user.email "gbrain-agent@railway.local"
    git config user.name "gbrain-agent"
    touch .gitkeep
    git add .
    git commit -m "Initialize GBrain repo" || true
fi

mkdir -p "${HERMES_HOME}/scripts" "${HERMES_HOME}/profiles/${PROFILE}/scripts"
cat > "${HERMES_HOME}/scripts/gbrain-sync-sessions.sh" <<'SYNC'
#!/bin/bash
set -euo pipefail
export HOME="/opt/hermes"
if [ -z "${DATA_DIR:-}" ]; then
    DATA_DIR="/data"
fi
export HOME="${DATA_DIR}"
export HERMES_HOME="${DATA_DIR}/.hermes"
OUT="${DATA_DIR}/brain-repo/conversations"
mkdir -p "$OUT"

python3 - <<'PY'
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

import os

data_dir = Path(os.environ.get("DATA_DIR", "/opt/hermes"))
db = data_dir / ".hermes" / "profiles" / "gbrain" / "state.db"
out = data_dir / "brain-repo" / "conversations"
if not db.exists():
    raise SystemExit(0)

con = sqlite3.connect(db)
con.row_factory = sqlite3.Row
sessions = con.execute("select * from sessions order by started_at").fetchall()
for s in sessions:
    sid = s["id"]
    msgs = con.execute(
        "select role, content, timestamp, tool_name from messages where session_id=? order by timestamp",
        (sid,),
    ).fetchall()
    human = [m for m in msgs if m["role"] in ("user", "assistant") and (m["content"] or "").strip()]
    if not human:
        continue
    started = datetime.fromtimestamp(float(s["started_at"]), tz=timezone.utc).isoformat()
    title = s["title"] or f"Hermes conversation {sid}"
    body = [
        "---",
        "type: conversation",
        "source: gbrain-agent",
        f"session_id: {sid}",
        f"platform: {s['source'] or ''}",
        f"model: {s['model'] or ''}",
        f"started_at: {started}",
        "---",
        "",
        f"# {title}",
        "",
    ]
    for m in human:
        ts = datetime.fromtimestamp(float(m["timestamp"]), tz=timezone.utc).isoformat()
        body.extend([f"## {ts} {m['role']}", "", (m["content"] or "").strip(), ""])
    (out / f"gbrain-agent-{sid}.md").write_text("\n".join(body))
PY

cd "${DATA_DIR}/brain-repo"
git add conversations .gitkeep
git commit -m "Sync Hermes conversations" >/dev/null 2>&1 || true
gbrain sync --repo "${DATA_DIR}/brain-repo" --no-embed --yes >/dev/null
SYNC
chmod +x "${HERMES_HOME}/scripts/gbrain-sync-sessions.sh"
cp "${HERMES_HOME}/scripts/gbrain-sync-sessions.sh" "${HERMES_HOME}/profiles/${PROFILE}/scripts/gbrain-sync-sessions.sh"
chmod +x "${HERMES_HOME}/profiles/${PROFILE}/scripts/gbrain-sync-sessions.sh"

cat > "${HERMES_HOME}/scripts/gbrain-dream.sh" <<'DREAM'
#!/bin/bash
set -euo pipefail
export HOME="/opt/hermes"
if [ -z "${DATA_DIR:-}" ]; then
    DATA_DIR="/data"
fi
export HOME="${DATA_DIR}"
export HERMES_HOME="${DATA_DIR}/.hermes"
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${ZEROENTROPY_API_KEY:-}" ] && [ -z "${VOYAGE_API_KEY:-}" ]; then
    echo "Skipping gbrain dream: no GBrain synthesis or embedding API key configured"
    exit 0
fi
gbrain dream --dir "${DATA_DIR}/brain-repo"
DREAM
chmod +x "${HERMES_HOME}/scripts/gbrain-dream.sh"
cp "${HERMES_HOME}/scripts/gbrain-dream.sh" "${HERMES_HOME}/profiles/${PROFILE}/scripts/gbrain-dream.sh"
chmod +x "${HERMES_HOME}/profiles/${PROFILE}/scripts/gbrain-dream.sh"

# 6. Write SOUL.md for brain-first behavior
mkdir -p "${HERMES_HOME}/profiles/${PROFILE}"
cat > "${HERMES_HOME}/profiles/${PROFILE}/SOUL.md" <<'SOUL'
# Hermes Agent Persona

You are a clairvoyant personal assistant powered by GBrain.
Only use GBrain pages from this gbrain-agent profile as personal memory.
Do not treat hermes-gateway, pleasant-balance, or other service histories as
this user's gbrain-agent memory unless the user explicitly asks to inspect
those separate services.
If session_search has no past sessions, check GBrain for gbrain-agent pages
before concluding history is missing.
Use GBrain MCP search/query/get_page or `gbrain search` for gbrain-agent
conversation memory.
Before external API calls or web search, check GBrain first when the question
could depend on prior context. Cite recovered page slugs when using history.
After gathering durable new info, write it back with GBrain capture/put_page.

Warm, practical, first-principles thinker. Terse directives.
SOUL

cp "${HERMES_HOME}/profiles/${PROFILE}/SOUL.md" "${HERMES_HOME}/SOUL.md"

# 7. Schedule GBrain maintenance if jobs do not already exist.
if ! hermes cron list | grep -q "gbrain-session-sync"; then
    hermes cron create "every 10m" \
        --name "gbrain-session-sync" \
        --profile "${PROFILE}" \
        --script "gbrain-sync-sessions.sh" \
        --no-agent \
        --deliver local || true
fi
if ! hermes cron list | grep -q "gbrain-dream"; then
    hermes cron create "0 3 * * *" \
        --name "gbrain-dream" \
        --profile "${PROFILE}" \
        --script "gbrain-dream.sh" \
        --no-agent \
        --deliver local || true
fi

cd /opt/hermes

# 8. Start a lightweight health-check HTTP server on PORT (Railway requirement)
PORT="${PORT:-8080}"
python3 -m http.server "${PORT}" --bind 0.0.0.0 &

echo "=== Starting Hermes Gateway with GBrain ==="
hermes gateway run
