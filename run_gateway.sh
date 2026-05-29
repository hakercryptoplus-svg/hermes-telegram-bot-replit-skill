#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export HERMES_HOME="$HOME/.hermes"
export HERMES_NO_UPDATE_CHECK="1"
export PORTKEY_CONFIG="${PORTKEY_CONFIG:-pc-gemini-85dd0b}"

PORT="${PORT:-8080}"

# Find hermes binary dynamically — path differs between dev and production
find_hermes() {
    local h
    h=$(which hermes 2>/dev/null)
    if [ -n "$h" ] && [ -f "$h" ]; then echo "$h"; return; fi

    for candidate in \
        "/usr/local/bin/hermes" \
        "/usr/bin/hermes" \
        "$HOME/.local/bin/hermes" \
        "/home/runner/workspace/.pythonlibs/bin/hermes" \
        "/home/runner/.pythonlibs/bin/hermes"; do
        if [ -f "$candidate" ]; then echo "$candidate"; return; fi
    done

    local pybase
    pybase=$(python3 -m site --user-base 2>/dev/null)
    if [ -f "${pybase}/bin/hermes" ]; then echo "${pybase}/bin/hermes"; return; fi
    echo ""
}

HERMES_BIN=$(find_hermes)
if [ -z "$HERMES_BIN" ]; then
    echo "[wrapper] ERROR: hermes binary not found!"
    exit 1
fi
echo "[wrapper] Using hermes at: $HERMES_BIN"
"$HERMES_BIN" --version

# Write ~/.hermes/.env so Hermes picks up allowed users and keys
mkdir -p "$HERMES_HOME"
cat > "$HERMES_HOME/.env" <<DOTENV
TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_CHAT_ID:-7281928709}}
TELEGRAM_ADMIN_USERS=${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_CHAT_ID:-7281928709}}
PORTKEY_API_KEY=${PORTKEY_API_KEY}
PORTKEY_CONFIG=${PORTKEY_CONFIG:-pc-gemini-85dd0b}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
DOTENV
echo "[wrapper] Wrote ~/.hermes/.env"
echo "[wrapper] TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_CHAT_ID:-7281928709}}"

# Start HTTP health check server (Replit deploy probe needs HTTP 200)
python3 -c "
import http.server, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'Hermes Gateway Running\n')
    def log_message(self, *a): pass
port = int(os.environ.get('PORT', 8080))
print('[health] HTTP health check server listening on port', port, flush=True)
http.server.HTTPServer(('0.0.0.0', port), H).serve_forever()
" &

# Start Portkey proxy — adds x-portkey-api-key + x-portkey-config headers
# Hermes cannot add custom headers; this proxy bridges the gap
echo "[wrapper] Starting Portkey proxy..."
python3 "$SCRIPT_DIR/portkey_proxy.py" &
PROXY_PID=$!
sleep 2
echo "[wrapper] Portkey proxy started (pid=$PROXY_PID)"

# Reset Telegram polling state — clears stale getUpdates sessions
echo "[wrapper] Resetting Telegram polling state..."
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" && echo ""
sleep 2

# Kill stale hermes processes
echo "[wrapper] Clearing stale hermes processes..."
pkill -f "hermes gateway" 2>/dev/null || true
sleep 2
"$HERMES_BIN" gateway stop 2>/dev/null || true
sleep 3

echo "[wrapper] Starting Hermes Gateway loop..."

while true; do
    "$HERMES_BIN" gateway run 2>&1
    EXIT_CODE=$?
    echo "[wrapper] Gateway exited (code=$EXIT_CODE). Cleaning up before restart..."
    pkill -f "hermes gateway" 2>/dev/null || true
    "$HERMES_BIN" gateway stop 2>/dev/null || true
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    sleep 10
    echo "[wrapper] Restarting gateway..."
done
