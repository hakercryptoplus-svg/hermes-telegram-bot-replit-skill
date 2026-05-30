#!/bin/bash
export HERMES_HOME="$HOME/.hermes"
export HERMES_NO_UPDATE_CHECK="1"
export PORTKEY_CONFIG="${PORTKEY_CONFIG:-pc-gemini-85dd0b}"

# ── SIGNAL HANDLING ────────────────────────────────────────────────────────────
# When Replit workflow sends SIGTERM, exit cleanly (don't loop forever)
HERMES_PID=""
WATCHDOG_PID=""
TAIL_PID=""
cleanup_and_exit() {
    echo "[wrapper] SIGTERM received — shutting down cleanly..."
    [ -n "$HERMES_PID" ]   && kill "$HERMES_PID"   2>/dev/null
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
    [ -n "$TAIL_PID" ]     && kill "$TAIL_PID"     2>/dev/null
    wait "$HERMES_PID" 2>/dev/null
    exit 0
}
trap cleanup_and_exit SIGTERM SIGHUP INT

# ── FIND HERMES BINARY ─────────────────────────────────────────────────────────
if command -v hermes &>/dev/null; then
    HERMES_BIN="$(command -v hermes)"
elif [ -f "/home/runner/workspace/.pythonlibs/bin/hermes" ]; then
    HERMES_BIN="/home/runner/workspace/.pythonlibs/bin/hermes"
elif [ -f "$HOME/.local/bin/hermes" ]; then
    HERMES_BIN="$HOME/.local/bin/hermes"
else
    HERMES_BIN="$(python3 -c 'import sysconfig; print(sysconfig.get_path("scripts"))')/hermes"
fi
echo "[wrapper] Using hermes binary: $HERMES_BIN"
"$HERMES_BIN" --version 2>&1 || { echo "[wrapper] ERROR: hermes not found"; exit 1; }

PORT="${PORT:-8080}"

# ── WRITE .env ─────────────────────────────────────────────────────────────────
mkdir -p "$HERMES_HOME"
cat > "$HERMES_HOME/.env" <<DOTENV
TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_CHAT_ID:-7281928709}}
TELEGRAM_ADMIN_USERS=${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_CHAT_ID:-7281928709}}
PORTKEY_API_KEY=${PORTKEY_API_KEY}
PORTKEY_CONFIG=${PORTKEY_CONFIG:-pc-gemini-85dd0b}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
DOTENV
echo "[wrapper] Wrote ~/.hermes/.env"
echo "[wrapper] TELEGRAM_BOT_TOKEN set: $([ -n "$TELEGRAM_BOT_TOKEN" ] && echo YES || echo NO)"
echo "[wrapper] PORTKEY_API_KEY set: $([ -n "$PORTKEY_API_KEY" ] && echo YES || echo NO)"

# ── PRE-FLIGHT: verify bot token with Telegram API ────────────────────────────
if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    GETME=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe")
    echo "[wrapper] getMe response: $GETME"
else
    echo "[wrapper] ERROR: TELEGRAM_BOT_TOKEN is empty — bot cannot start"
    exit 1
fi

# ── INSTALL PORTKEY PLUGIN ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERMES_HOME/plugins/model-providers/portkey"
cp "$SCRIPT_DIR/portkey_plugin/__init__.py" "$HERMES_HOME/plugins/model-providers/portkey/__init__.py"
cp "$SCRIPT_DIR/portkey_plugin/plugin.yaml" "$HERMES_HOME/plugins/model-providers/portkey/plugin.yaml"

# Write config dynamically so TELEGRAM_CHAT_ID env var is used (not hardcoded ID)
TGID="${TELEGRAM_CHAT_ID:-${TELEGRAM_ALLOWED_USERS:-7281928709}}"
cat > "$HERMES_HOME/config.yaml" <<CONFIG
model:
  provider: portkey
  name: gemini-3.5-flash

telegram:
  free_response_chats: true
  allow_from:
    - ${TGID}
  admin_from:
    - ${TGID}

gateway:
  session_reset:
    mode: idle
    idle_minutes: 60

stt:
  enabled: true
CONFIG
echo "[wrapper] Installed plugin + wrote config (telegram_id=${TGID})"

# ── HEALTH CHECK SERVER ────────────────────────────────────────────────────────
python3 -c "
import http.server, os, socket, sys
port = int(os.environ.get('PORT', 8080))
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('0.0.0.0', port))
    s.close()
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'Hermes Gateway Running\n')
        def log_message(self, *a): pass
    print('[health] Listening on port', port, flush=True)
    http.server.HTTPServer(('0.0.0.0', port), H).serve_forever()
except OSError:
    print('[health] Port', port, 'already bound — OK', flush=True)
    sys.exit(0)
" &

# ── ONE-TIME STARTUP CLEANUP (runs once only, not on every restart) ────────────
echo "[wrapper] Killing any stale hermes processes..."
pkill -9 -f "hermes gateway" 2>/dev/null || true
sleep 3
"$HERMES_BIN" gateway stop 2>/dev/null || true

echo "[wrapper] Resetting Telegram polling state..."
for i in 1 2 3; do
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    echo "[wrapper] Reset $i done"
    sleep 5
done

echo "[wrapper] Waiting 30s for Telegram session to clear..."
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
sleep 30
echo "[wrapper] Starting gateway..."

# ── RESTART LOOP ───────────────────────────────────────────────────────────────
# hermes v0.14.0 has an internal bug: when the Updater gets "wedged" it calls
# start_polling() on an already-running Updater → self-conflict → bot delays 3-6 min.
# Fix: watchdog monitors hermes output and kills it immediately on wedge signals,
# then the loop restarts with a fresh session steal for a clean reconnect.
HERMES_LOG="/tmp/hermes_run.log"

while true; do
    START_TIME=$(date +%s)

    # Force-steal the Telegram polling session before each start.
    # Terminates any lingering getUpdates connection (zombie process, old deployment).
    echo "[wrapper] Stealing Telegram session slot..."
    for _i in 1 2 3; do
        curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=1&offset=-1" > /dev/null 2>&1
        sleep 2
    done
    pkill -9 -f "hermes gateway" 2>/dev/null || true
    sleep 2

    # Fresh log file each run
    > "$HERMES_LOG"

    # Run hermes — output goes to log file (watchdog reads it)
    # Hard timeout 600s (10 min) as ultimate safety net.
    # NOTE: never use timeout <120s — Telegram long-poll=30s so hermes exits at
    # ~60s even when healthy, code=124 looks like conflict but isn't.
    timeout 600 "$HERMES_BIN" gateway run > "$HERMES_LOG" 2>&1 &
    HERMES_PID=$!
    echo "[wrapper] Gateway PID: $HERMES_PID"

    # Tail log to stdout so deployment logs stay visible
    tail -f "$HERMES_LOG" &
    TAIL_PID=$!

    # Watchdog: kill hermes immediately on internal wedge signals
    # (hermes v0.14.0 bug: retries wedged Updater instead of exiting)
    _HPID=$HERMES_PID
    (
        sleep 45
        while kill -0 "$_HPID" 2>/dev/null; do
            sleep 15
            if grep -qE "Updater not running|polling retry failed|Updater is already running" "$HERMES_LOG" 2>/dev/null; then
                echo "[watchdog] Wedge detected — killing hermes $_HPID for clean restart"
                kill -9 "$_HPID" 2>/dev/null
                break
            fi
        done
    ) &
    WATCHDOG_PID=$!

    wait $HERMES_PID
    EXIT_CODE=$?
    HERMES_PID=""

    kill "$WATCHDOG_PID" 2>/dev/null; wait "$WATCHDOG_PID" 2>/dev/null; WATCHDOG_PID=""
    kill "$TAIL_PID"     2>/dev/null; wait "$TAIL_PID"     2>/dev/null; TAIL_PID=""

    END_TIME=$(date +%s)
    UPTIME=$((END_TIME - START_TIME))
    echo "[wrapper] Gateway exited (code=$EXIT_CODE, uptime=${UPTIME}s) — restarting in 10s..."
    sleep 10
done
