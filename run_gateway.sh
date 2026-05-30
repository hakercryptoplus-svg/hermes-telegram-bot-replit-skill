#!/bin/bash
export OPENCLAW_NO_UPDATE_CHECK="1"
export PORTKEY_CONFIG="${PORTKEY_CONFIG:-pc-gemini-85dd0b}"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-${SESSION_SECRET}}"

# ── SIGNAL HANDLING ────────────────────────────────────────────────────────────
OPENCLAW_PID=""
cleanup_and_exit() {
    echo "[wrapper] SIGTERM received — shutting down cleanly..."
    [ -n "$OPENCLAW_PID" ] && kill "$OPENCLAW_PID" 2>/dev/null
    wait "$OPENCLAW_PID" 2>/dev/null
    exit 0
}
trap cleanup_and_exit SIGTERM SIGHUP INT

# ── FIND / INSTALL OPENCLAW BINARY ─────────────────────────────────────────────
if command -v openclaw &>/dev/null; then
    OPENCLAW_BIN="$(command -v openclaw)"
else
    echo "[wrapper] openclaw not found — installing via npm..."
    npm install -g openclaw 2>&1
    OPENCLAW_BIN="$(command -v openclaw)"
fi
echo "[wrapper] Using openclaw binary: $OPENCLAW_BIN"
"$OPENCLAW_BIN" --version 2>&1 || { echo "[wrapper] ERROR: openclaw not found after install"; exit 1; }

PORT="${PORT:-8080}"

# ── PRE-FLIGHT: verify bot token ───────────────────────────────────────────────
if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    echo "[wrapper] ERROR: TELEGRAM_BOT_TOKEN is empty — bot cannot start"
    exit 1
fi
GETME=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe")
echo "[wrapper] getMe response: $GETME"

echo "[wrapper] TELEGRAM_BOT_TOKEN set: YES"
echo "[wrapper] PORTKEY_API_KEY set: $([ -n "$PORTKEY_API_KEY" ] && echo YES || echo NO)"

# ── WRITE ~/.openclaw/.env ─────────────────────────────────────────────────────
mkdir -p "$HOME/.openclaw"
cat > "$HOME/.openclaw/.env" <<DOTENV
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
PORTKEY_API_KEY=${PORTKEY_API_KEY}
PORTKEY_CONFIG=${PORTKEY_CONFIG}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
DOTENV
echo "[wrapper] Wrote ~/.openclaw/.env"

# ── WRITE ~/.openclaw/openclaw.json ────────────────────────────────────────────
TGID="${TELEGRAM_CHAT_ID:-${TELEGRAM_ALLOWED_USERS:-7281928709}}"
cat > "$HOME/.openclaw/openclaw.json" <<CONFIG
{
  "models": {
    "providers": {
      "litellm": {
        "baseUrl": "https://api.portkey.ai/v1",
        "apiKey": "${PORTKEY_API_KEY}",
        "api": "openai-completions",
        "headers": {
          "x-portkey-config": "${PORTKEY_CONFIG}"
        },
        "models": [
          {
            "id": "gemini-3.5-flash",
            "name": "Gemini 3.5 Flash",
            "reasoning": false,
            "input": ["text"],
            "contextWindow": 1000000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "litellm/gemini-3.5-flash"
      }
    }
  },
  "memory": {
    "search": {
      "enabled": false
    }
  },
  "channels": {
    "telegram": {
      "botToken": "${TELEGRAM_BOT_TOKEN}",
      "dmPolicy": "allowlist",
      "allowFrom": ["${TGID}"],
      "streaming": {
        "mode": "partial",
        "preview": {
          "toolProgress": true
        }
      }
    }
  },
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "${OPENCLAW_GATEWAY_TOKEN}"
    }
  }
}
CONFIG
echo "[wrapper] Wrote ~/.openclaw/openclaw.json (telegram_id=${TGID})"

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
            self.wfile.write(b'OpenClaw Gateway Running\n')
        def log_message(self, *a): pass
    print('[health] Listening on port', port, flush=True)
    http.server.HTTPServer(('0.0.0.0', port), H).serve_forever()
except OSError:
    print('[health] Port', port, 'already bound — OK', flush=True)
    sys.exit(0)
" &

# ── ONE-TIME STARTUP CLEANUP ───────────────────────────────────────────────────
echo "[wrapper] Killing any stale openclaw processes..."
pkill -9 -f "openclaw gateway" 2>/dev/null || true
sleep 2

curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
echo "[wrapper] deleteWebhook done"

# Wait for old Telegram long-poll session to expire (Telegram max poll timeout = 30s)
echo "[wrapper] Waiting 35s for any existing Telegram session to expire..."
sleep 35
echo "[wrapper] Starting gateway..."

# ── RESTART LOOP ───────────────────────────────────────────────────────────────
while true; do
    START_TIME=$(date +%s)
    echo "[wrapper] Starting openclaw gateway..."

    "$OPENCLAW_BIN" gateway &
    OPENCLAW_PID=$!
    echo "[wrapper] Gateway PID: $OPENCLAW_PID"

    wait $OPENCLAW_PID
    EXIT_CODE=$?
    OPENCLAW_PID=""

    END_TIME=$(date +%s)
    UPTIME=$((END_TIME - START_TIME))
    echo "[wrapper] Gateway exited (code=$EXIT_CODE, uptime=${UPTIME}s)"

    pkill -9 -f "openclaw gateway" 2>/dev/null || true

    echo "[wrapper] Waiting 35s for Telegram session to expire before restart..."
    sleep 35
done
