#!/bin/bash
export HERMES_HOME="$HOME/.hermes"
export HERMES_NO_UPDATE_CHECK="1"
export PORTKEY_CONFIG="${PORTKEY_CONFIG:-pc-gemini-85dd0b}"

# Find hermes binary — works in both dev and production
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
"$HERMES_BIN" --version 2>&1 || { echo "[wrapper] ERROR: hermes not found at $HERMES_BIN"; exit 1; }

PORT="${PORT:-8080}"

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

# Install Portkey plugin fresh every startup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERMES_HOME/plugins/model-providers/portkey"
cp "$SCRIPT_DIR/portkey_plugin/__init__.py" "$HERMES_HOME/plugins/model-providers/portkey/__init__.py"
cp "$SCRIPT_DIR/portkey_plugin/plugin.yaml" "$HERMES_HOME/plugins/model-providers/portkey/plugin.yaml"
echo "[wrapper] Installed Portkey plugin"

cp "$SCRIPT_DIR/hermes_config.yaml" "$HERMES_HOME/config.yaml"
echo "[wrapper] Copied hermes_config.yaml"

# Start HTTP health check server (only if port not already in use)
python3 -c "
import http.server, os, socket, sys
port = int(os.environ.get('PORT', 8080))
# Check if already bound
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
    print('[health] HTTP health check server listening on port', port, flush=True)
    http.server.HTTPServer(('0.0.0.0', port), H).serve_forever()
except OSError:
    print('[health] Port', port, 'already in use — health server already running', flush=True)
    sys.exit(0)
" &

# Aggressively reset Telegram polling — call deleteWebhook multiple times with delay
echo "[wrapper] Aggressively resetting Telegram polling state..."
for i in 1 2 3; do
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    echo "[wrapper] Reset attempt $i done"
    sleep 5
done

# Kill ALL stale hermes processes
echo "[wrapper] Clearing stale hermes processes..."
pkill -9 -f "hermes gateway" 2>/dev/null || true
sleep 3
"$HERMES_BIN" gateway stop 2>/dev/null || true

# Final Telegram reset + wait for session to expire
echo "[wrapper] Final Telegram reset — waiting 30s for session to clear..."
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
sleep 30
echo "[wrapper] Done waiting. Starting gateway..."

while true; do
    # --replace kills any lingering gateway before starting
    "$HERMES_BIN" gateway run --replace
    EXIT_CODE=$?
    echo "[wrapper] Gateway exited (code=$EXIT_CODE). Cleaning up before restart..."
    pkill -9 -f "hermes gateway" 2>/dev/null || true
    "$HERMES_BIN" gateway stop 2>/dev/null || true
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    sleep 15
    echo "[wrapper] Restarting gateway..."
done
