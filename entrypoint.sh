#!/bin/sh
dir="$HOME/.nanobot"
if [ -d "$dir" ] && [ ! -w "$dir" ]; then
    owner_uid=$(stat -c %u "$dir" 2>/dev/null || stat -f %u "$dir" 2>/dev/null)
    cat >&2 <<EOF
Error: $dir is not writable (owned by UID $owner_uid, running as UID $(id -u)).

Fix (pick one):
  Host:   sudo chown -R 1000:1000 ~/.nanobot
  Docker: docker run --user \$(id -u):\$(id -g) ...
  Podman: podman run --userns=keep-id ...
EOF
    exit 1
fi

# --- Auto-generate config.json from environment variables ---
CONFIG_FILE="$HOME/.nanobot/config.json"
mkdir -p "$HOME/.nanobot"

# Create workspace directory
mkdir -p /app/data

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Generating config.json from environment variables..."

    # Build providers section dynamically
    PROVIDERS_JSON=""

    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        PROVIDERS_JSON="${PROVIDERS_JSON},\"anthropic\":{\"apiKey\":\"${ANTHROPIC_API_KEY}\"}"
    fi
    if [ -n "${OPENAI_API_KEY:-}" ]; then
        PROVIDERS_JSON="${PROVIDERS_JSON},\"openai\":{\"apiKey\":\"${OPENAI_API_KEY}\"}"
    fi
    if [ -n "${OPENROUTER_API_KEY:-}" ]; then
        PROVIDERS_JSON="${PROVIDERS_JSON},\"openrouter\":{\"apiKey\":\"${OPENROUTER_API_KEY}\"}"
    fi
    if [ -n "${GEMINI_API_KEY:-}" ]; then
        PROVIDERS_JSON="${PROVIDERS_JSON},\"gemini\":{\"apiKey\":\"${GEMINI_API_KEY}\"}"
    fi
    if [ -n "${GROQ_API_KEY:-}" ]; then
        PROVIDERS_JSON="${PROVIDERS_JSON},\"groq\":{\"apiKey\":\"${GROQ_API_KEY}\"}"
    fi
    if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
        PROVIDERS_JSON="${PROVIDERS_JSON},\"deepseek\":{\"apiKey\":\"${DEEPSEEK_API_KEY}\"}"
    fi

    # Strip leading comma
    PROVIDERS_JSON=$(echo "$PROVIDERS_JSON" | sed 's/^,//')

    # Default model (can be overridden via NANOBOT_MODEL env var)
    DEFAULT_MODEL="${NANOBOT_MODEL:-anthropic/claude-opus-4-5}"
    WORKSPACE="${NANOBOT_WORKSPACE:-/app/data}"
    TIMEZONE="${NANOBOT_TIMEZONE:-Asia/Jakarta}"

    cat > "$CONFIG_FILE" <<EOCFG
{
  "agents": {
    "defaults": {
      "model": "${DEFAULT_MODEL}",
      "workspace": "${WORKSPACE}",
      "timezone": "${TIMEZONE}",
      "maxTokens": 8192,
      "temperature": 0.1
    }
  },
  "providers": {${PROVIDERS_JSON}},
  "gateway": {
    "host": "0.0.0.0",
    "port": 18790
  }
}
EOCFG
    echo "Config generated at $CONFIG_FILE"
fi

run_supabase_sync() {
    action="$1"
    if [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
        python -m nanobot.supabase_sync "$action" || true
    fi
}

should_manage_backups=0
if [ "${1:-}" = "gateway" ] || [ "${1:-}" = "serve" ]; then
    should_manage_backups=1
fi

if [ "$should_manage_backups" -eq 1 ]; then
    run_supabase_sync restore
fi

sync_pid=""
cleanup() {
    if [ -n "$sync_pid" ]; then
        kill "$sync_pid" 2>/dev/null || true
    fi
    if [ "$should_manage_backups" -eq 1 ]; then
        run_supabase_sync backup
    fi
}

if [ "$should_manage_backups" -eq 1 ] && [ -n "${SUPABASE_SYNC_INTERVAL_SECONDS:-}" ]; then
    (
        while true; do
            sleep "${SUPABASE_SYNC_INTERVAL_SECONDS}"
            run_supabase_sync backup
        done
    ) &
    sync_pid="$!"
    trap cleanup INT TERM EXIT
fi

exec nanobot "$@"
