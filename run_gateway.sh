#!/bin/bash
export HERMES_HOME="$HOME/.hermes"
export HERMES_NO_UPDATE_CHECK="1"
export PORTKEY_CONFIG="${PORTKEY_CONFIG:-pc-gemini-85dd0b}"
# PORTKEY_API_KEY and TELEGRAM_BOT_TOKEN come from Replit secrets automatically

HERMES_BIN="/home/runner/workspace/.pythonlibs/bin/hermes"
PORT="${PORT:-8080}"

# Write ~/.hermes/.env so Hermes picks up allowed users and gateway settings
mkdir -p "$HERMES_HOME"
cat > "$HERMES_HOME/.env" <<DOTENV
TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_CHAT_ID:-7281928709}}
TELEGRAM_ADMIN_USERS=${TELEGRAM_ALLOWED_USERS:-${TELEGRAM_CHAT_ID:-7281928709}}
PORTKEY_API_KEY=${PORTKEY_API_KEY}
PORTKEY_CONFIG=${PORTKEY_CONFIG:-pc-gemini-85dd0b}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
DOTENV
echo "[wrapper] Wrote ~/.hermes/.env"

# Start minimal HTTP health check server in background
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

# Reset Telegram polling state — clears any stale getUpdates sessions from previous instances
echo "[wrapper] Resetting Telegram polling state..."
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" && echo ""
sleep 2

# Kill ALL stale hermes processes aggressively
echo "[wrapper] Clearing stale hermes processes..."
pkill -f "hermes gateway" 2>/dev/null || true
sleep 2
"$HERMES_BIN" gateway stop 2>/dev/null || true
sleep 3

echo "[wrapper] Starting Hermes Gateway loop..."

while true; do
    "$HERMES_BIN" gateway run
    EXIT_CODE=$?
    echo "[wrapper] Gateway exited (code=$EXIT_CODE). Cleaning up before restart..."
    pkill -f "hermes gateway" 2>/dev/null || true
    "$HERMES_BIN" gateway stop 2>/dev/null || true
    # Reset Telegram state before each restart to prevent polling conflicts
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    sleep 10
    echo "[wrapper] Restarting gateway..."
done
