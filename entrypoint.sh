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
