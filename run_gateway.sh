#!/bin/bash
export HERMES_HOME="$HOME/.hermes"
export PORTKEY_CONFIG="pc-gemini-85dd0b"
export HERMES_NO_UPDATE_CHECK="1"
# PORTKEY_API_KEY and TELEGRAM_BOT_TOKEN come from Replit secrets automatically

HERMES_BIN="/home/runner/workspace/.pythonlibs/bin/hermes"

# Kill any stale gateway and clean lock
"$HERMES_BIN" gateway stop 2>/dev/null || true
sleep 1

echo "[wrapper] Starting Hermes Gateway loop..."

while true; do
    "$HERMES_BIN" gateway run
    EXIT_CODE=$?
    echo "[wrapper] Gateway exited (code=$EXIT_CODE). Restarting in 3s..."
    sleep 3
done
