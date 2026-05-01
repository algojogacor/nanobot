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

mkdir -p "$HOME/.nanobot"
mkdir -p /app/data

CONFIG_FILE="$HOME/.nanobot/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Generating config.json via Python..."

    # Keys are read from env vars — never hardcoded in source
    # Set these in Koyeb dashboard:
    #   DEEPSEEK_API_KEY_1 .. DEEPSEEK_API_KEY_10
    #   QWEN_API_KEY_1     .. QWEN_API_KEY_10
    #   GROQ_API_KEY_1     .. GROQ_API_KEY_3
    #   ZHIPU_API_KEY_1    .. ZHIPU_API_KEY_2
    #   MISTRAL_API_KEY_1  .. MISTRAL_API_KEY_4
    #   TELEGRAM_BOT_TOKEN
    #   NANOBOT_MODEL      (optional override, default: deepseek-v4-pro)

    python3 - <<'PYEOF'
import json, os, random

def load_pool(prefix, count):
    """Collect non-empty env vars: PREFIX_1, PREFIX_2, ..., PREFIX_N"""
    pool = []
    for i in range(1, count + 1):
        v = os.environ.get(f"{prefix}_{i}", "").strip()
        if v:
            pool.append(v)
    # Also accept plain PREFIX (single key fallback)
    plain = os.environ.get(prefix, "").strip()
    if plain and plain not in pool:
        pool.append(plain)
    return pool

def pick(pool):
    return random.choice(pool) if pool else None

# ── Load key pools from environment ─────────────────────────────────────────
deepseek_pool = load_pool("DEEPSEEK_API_KEY", 10)
qwen_pool     = load_pool("QWEN_API_KEY",     10)
groq_pool     = load_pool("GROQ_API_KEY",      3)
zhipu_pool    = load_pool("ZHIPU_API_KEY",     2)
mistral_pool  = load_pool("MISTRAL_API_KEY",   8)

# ── Pick one randomly from each pool ────────────────────────────────────────
deepseek_key = pick(deepseek_pool)
qwen_key     = pick(qwen_pool)
groq_key     = pick(groq_pool)
zhipu_key    = pick(zhipu_pool)
mistral_key  = pick(mistral_pool)

# ── Settings ─────────────────────────────────────────────────────────────────
# Model fallback priority: deepseek-v4-pro > deepseek-chat > qwen3.6-plus > qwen-max
default_model = os.environ.get("NANOBOT_MODEL", "deepseek-v4-pro")
workspace     = os.environ.get("NANOBOT_WORKSPACE", "/app/data")
timezone      = os.environ.get("NANOBOT_TIMEZONE", "Asia/Jakarta")
tg_token      = os.environ.get("TELEGRAM_BOT_TOKEN", "")

# ── Build providers block ────────────────────────────────────────────────────
providers = {}

if deepseek_key:
    providers["deepseek"] = {"apiKey": deepseek_key}

if qwen_key:
    # China endpoint (user confirmed)
    providers["dashscope"] = {
        "apiKey":  qwen_key,
        "apiBase": "https://dashscope.aliyuncs.com/compatible-mode/v1",
    }

if groq_key:
    providers["groq"] = {"apiKey": groq_key}

if zhipu_key:
    providers["zhipu"] = {"apiKey": zhipu_key}

if mistral_key:
    providers["mistral"] = {"apiKey": mistral_key}

if not providers:
    raise SystemExit("❌ No API keys found! Set at least DEEPSEEK_API_KEY_1 in Koyeb env vars.")

# ── Build channels block ─────────────────────────────────────────────────────
channels = {"sendProgress": True}
if tg_token:
    channels["telegram"] = {
        "enabled":   True,
        "token":     tg_token,
        "allowFrom": ["*"],
        "streaming": True,
    }

# ── Full config ───────────────────────────────────────────────────────────────
config = {
    "agents": {
        "defaults": {
            "model":            default_model,
            "workspace":        workspace,
            "timezone":         timezone,
            "maxTokens":        8192,
            "temperature":      0.1,
            "providerRetryMode": "persistent",
        }
    },
    "providers": providers,
    "channels":  channels,
    "gateway": {
        "host": "0.0.0.0",
        "port": 18790,
    },
}

config_path = os.path.expanduser("~/.nanobot/config.json")
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

# ── Summary ───────────────────────────────────────────────────────────────────
print(f"✅ Config generated")
print(f"   model    : {default_model}")
for name, cfg in providers.items():
    key_preview = cfg.get("apiKey", "")[:14] + "..."
    base = f" [{cfg['apiBase']}]" if "apiBase" in cfg else ""
    print(f"   {name:<10}: {key_preview}{base}")
print(f"   telegram : {'✓ ' + tg_token[:20] + '...' if tg_token else '✗ not set'}")
print(f"   pools    : deepseek={len(deepseek_pool)} qwen={len(qwen_pool)} groq={len(groq_pool)} mistral={len(mistral_pool)}")
PYEOF
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
