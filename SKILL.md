---
name: hermes-telegram-bot
description: "Deploy Hermes Agent (Nous Research v0.14.0) as a Telegram bot on Replit using Portkey AI Gateway (Gemini). Always-running VM deployment."
---

# Hermes Telegram Bot — Replit Skill

## What This Builds

A **real** Hermes Agent (Nous Research v0.14.0) connected to Telegram via `hermes gateway run` (official Hermes Telegram integration), powered by Google Gemini 3.5 Flash through Portkey AI Gateway. Deployed as a Replit Reserved VM (always running — no sleep).

## Required Secrets (Replit Secrets tab)

| Secret | Where to get it |
|--------|----------------|
| `PORTKEY_API_KEY` | https://app.portkey.ai → API Keys |
| `TELEGRAM_BOT_TOKEN` | @BotFather on Telegram → /newbot |
| `SESSION_SECRET` | Any random string (e.g. `openssl rand -hex 32`) |

## Required Env Vars (Replit Shared Env)

| Variable | Value |
|----------|-------|
| `PORTKEY_CONFIG` | Your Portkey config ID (e.g. `pc-gemini-85dd0b`) |
| `PORTKEY_BASE_URL` | `https://api.portkey.ai/v1` |
| `PORTKEY_MODEL` | `gemini-3.5-flash` |
| `TELEGRAM_CHAT_ID` | Your Telegram user ID (get from @userinfobot) |
| `TELEGRAM_ALLOWED_USERS` | Same as TELEGRAM_CHAT_ID — numeric Telegram user ID (NOT username) |

> **Critical**: `TELEGRAM_ALLOWED_USERS` must be a **numeric ID** (e.g. `7281928709`), NOT a username like `@myuser`. Set it as a Replit env var AND it gets written to `~/.hermes/.env` at runtime (handled automatically by `run_gateway.sh`).

## Project Structure

```
artifacts/
├── api-server/                    # Hermes bot backend
│   ├── run_gateway.sh             # Bot startup script (health check + reset + restart loop)
│   ├── hermes_config.yaml         # Hermes config (model + telegram settings)
│   ├── requirements.txt           # Python deps: hermes-agent, python-telegram-bot
│   ├── portkey_plugin/            # Custom Portkey provider plugin for Hermes
│   │   ├── __init__.py            # ProviderProfile registration
│   │   └── plugin.yaml            # Plugin metadata
│   └── .replit-artifact/
│       └── artifact.toml          # kind=api, production build+run config
└── bot-status/                    # Web status page (required for Replit Publish)
    ├── src/App.tsx                 # "Bot Online" status page
    └── .replit-artifact/
        └── artifact.toml          # kind=web, previewPath=/, static build
```

## Key Files Content

### `artifacts/api-server/run_gateway.sh`

```bash
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
    HERMES_BIN="$(python3 -c 'import sysconfig; print(sysconfig.get_path(\"scripts\"))')/hermes"
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

# Install Portkey plugin fresh every startup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERMES_HOME/plugins/model-providers/portkey"
cp "$SCRIPT_DIR/portkey_plugin/__init__.py" "$HERMES_HOME/plugins/model-providers/portkey/__init__.py"
cp "$SCRIPT_DIR/portkey_plugin/plugin.yaml" "$HERMES_HOME/plugins/model-providers/portkey/plugin.yaml"
echo "[wrapper] Installed Portkey plugin"

cp "$SCRIPT_DIR/hermes_config.yaml" "$HERMES_HOME/config.yaml"
echo "[wrapper] Copied hermes_config.yaml"

# Start HTTP health check server (Replit deploy probe requires HTTP 200)
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

# Aggressively reset Telegram polling (3x with delay to kill old sessions)
echo "[wrapper] Aggressively resetting Telegram polling state..."
for i in 1 2 3; do
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    echo "[wrapper] Reset attempt $i done"
    sleep 5
done

# Kill all stale hermes processes
pkill -9 -f "hermes" 2>/dev/null || true
sleep 3
"$HERMES_BIN" gateway stop 2>/dev/null || true

# Final reset + wait 30s for Telegram server-side session to fully expire
echo "[wrapper] Final Telegram reset — waiting 30s for session to clear..."
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
sleep 30
echo "[wrapper] Starting gateway..."

while true; do
    "$HERMES_BIN" gateway run
    EXIT_CODE=$?
    echo "[wrapper] Gateway exited (code=$EXIT_CODE). Restarting..."
    pkill -f "hermes gateway" 2>/dev/null || true
    "$HERMES_BIN" gateway stop 2>/dev/null || true
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    sleep 15
done
```

### `artifacts/api-server/hermes_config.yaml`

> ⚠️ Do NOT add a `providers:` block pointing to `http://127.0.0.1:8765` — that local proxy doesn't exist and causes `telegram connect timed out`. The Portkey plugin handles provider registration directly.

```yaml
model:
  provider: portkey
  name: gemini-3.5-flash

telegram:
  free_response_chats: true
  allow_from:
    - 7281928709      # Replace with your numeric Telegram user ID
  admin_from:
    - 7281928709

gateway:
  session_reset:
    mode: idle
    idle_minutes: 60
```

### `artifacts/api-server/portkey_plugin/__init__.py`

```python
"""Portkey AI Gateway provider plugin for Hermes Agent."""
import os
from providers import register_provider
from providers.base import ProviderProfile

portkey = ProviderProfile(
    name="portkey",
    aliases=("portkey-ai", "portkey_ai"),
    display_name="Portkey AI Gateway",
    description="Portkey — unified AI gateway with observability and fallbacks",
    signup_url="https://app.portkey.ai/",
    env_vars=("PORTKEY_API_KEY",),
    base_url="https://api.portkey.ai/v1",
    default_headers={
        "x-portkey-api-key": os.environ.get("PORTKEY_API_KEY", ""),
        "x-portkey-config": os.environ.get("PORTKEY_CONFIG", "pc-gemini-85dd0b"),
    },
    fallback_models=("gemini-3.5-flash",),
    default_aux_model="gemini-3.5-flash",
)

register_provider(portkey)
```

### `artifacts/api-server/portkey_plugin/plugin.yaml`

```yaml
name: portkey
kind: model-provider
version: "1.0.0"
description: "Portkey AI Gateway — unified gateway for Gemini, OpenAI, and more"
```

### `artifacts/api-server/requirements.txt`

```
hermes-agent==0.14.0
python-telegram-bot==22.7
openai>=2.0.0
httpx>=0.28.0
```

### `artifacts/api-server/.replit-artifact/artifact.toml`

```toml
kind = "api"
previewPath = "/api"
title = "Hermes Telegram Bot"
version = "1.0.0"
id = "3B4_FFSkEVBkAeYMFRJ2e"

[[services]]
localPort = 8080
name = "API Server"
paths = ["/api"]

[services.development]
run = "pnpm --filter @workspace/api-server run dev"

[services.production]

[services.production.build]
args = ["bash", "-c", "python3 -m pip install --break-system-packages -r artifacts/api-server/requirements.txt && mkdir -p $HOME/.hermes/plugins/model-providers/portkey && cp artifacts/api-server/portkey_plugin/__init__.py $HOME/.hermes/plugins/model-providers/portkey/__init__.py && cp artifacts/api-server/portkey_plugin/plugin.yaml $HOME/.hermes/plugins/model-providers/portkey/plugin.yaml && cp artifacts/api-server/hermes_config.yaml $HOME/.hermes/config.yaml"]

[services.production.run]
args = ["bash", "artifacts/api-server/run_gateway.sh"]

[services.production.health.startup]
path = "/api"
```

### `artifacts/bot-status/.replit-artifact/artifact.toml`

```toml
kind = "web"
previewPath = "/"
title = "Hermes Bot Status"
version = "1.0.0"
id = "artifacts/bot-status"

[[services]]
name = "web"
paths = ["/"]
localPort = 22053

[services.development]
run = "pnpm --filter @workspace/bot-status run dev"

[services.production]
build = ["pnpm", "--filter", "@workspace/bot-status", "run", "build"]
publicDir = "artifacts/bot-status/dist/public"
serve = "static"

[[services.production.rewrites]]
from = "/*"
to = "/index.html"
```

## Setup Steps (from scratch)

### Step 1: Install Python 3.12

Use the Replit package manager (`installProgrammingLanguage({ language: "python-3.12" })`).

### Step 2: Install Hermes & dependencies

```bash
pip install hermes-agent==0.14.0 python-telegram-bot==22.7 "openai>=2.0.0" "httpx>=0.28.0"
```

Verify: `hermes --version` (should show v0.14.0)

### Step 3: Set Required Env Vars

In Replit Secrets: `PORTKEY_API_KEY`, `TELEGRAM_BOT_TOKEN`, `SESSION_SECRET`

In Replit Shared Env:
- `PORTKEY_CONFIG=pc-gemini-85dd0b`
- `PORTKEY_BASE_URL=https://api.portkey.ai/v1`
- `PORTKEY_MODEL=gemini-3.5-flash`
- `TELEGRAM_CHAT_ID=<numeric_telegram_user_id>`
- `TELEGRAM_ALLOWED_USERS=<same_numeric_id>` ← **must be numeric, NOT a username**

### Step 4: Deploy (Replit Publish)

⚠️ **CRITICAL**: Must select **Reserved VM** (not Autoscale).

## Gotchas & Sharp Edges

### 1. `pip install --user` fails in production build
**Fix**: Use `python3 -m pip install --break-system-packages` (no `--user` flag).

### 2. "App built successfully but failed to start"
**Fix**: `run_gateway.sh` starts a Python `http.server` in background on `$PORT` before launching gateway.

### 3. `Conflict: terminated by other getUpdates request`
**Cause**: Old deployment instance still holds Telegram polling session.
**Fix**: `run_gateway.sh` calls `deleteWebhook?drop_pending_updates=true` 3× with delays, then waits 30s before starting. This outlasts Telegram's ~25s session timeout.

### 4. "Unauthorized user" even with correct ID
**Fix**: `TELEGRAM_ALLOWED_USERS` must be **numeric** (e.g. `7281928709`), NOT `@username`. Written to `~/.hermes/.env` on every startup.

### 5. `telegram connect timed out` / no gateway connection
**Cause**: `providers:` block in `hermes_config.yaml` pointing to `http://127.0.0.1:8765` — that local proxy doesn't exist.
**Fix**: Remove the `providers:` block entirely. The Portkey plugin registers itself directly.

### 6. Hermes exits code 1 on SIGTERM
**Fix**: `run_gateway.sh` uses a `while true` restart loop.

### 7. `TELEGRAM_ALLOWED_USERS` must be numeric
Always use the numeric Telegram user ID (get from @userinfobot on Telegram), never a username.

### 8. HERMES_HOME must be set
Always `export HERMES_HOME="$HOME/.hermes"` in the run script.

## How It Works (Architecture)

```
Telegram User
     ↓ message
Telegram API (polling)
     ↓
hermes gateway run  ← official Hermes Telegram integration
     ↓
Hermes Agent Core (Nous Research v0.14.0)
     ↓ LLM call
Portkey AI Gateway (x-portkey-api-key + x-portkey-config headers)
     ↓
Google Gemini 3.5 Flash
     ↓ response
hermes → Telegram → User
```

## Testing

```bash
# Verify hermes is installed
hermes --version

# Verify Telegram token works
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"

# Test gateway locally
bash artifacts/api-server/run_gateway.sh
```

## Monitoring in Production

Look for these lines in Replit's deployment Logs tab:
- `[health] HTTP health check server listening on port 8080` — app started
- `[wrapper] Aggressively resetting Telegram polling state...` — clearing old sessions
- `[wrapper] Starting gateway...` — about to launch
- `✓ telegram connected` — bot is live and ready
