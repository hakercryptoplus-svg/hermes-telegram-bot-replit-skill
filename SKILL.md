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
| `TELEGRAM_ALLOWED_USERS` | Same as TELEGRAM_CHAT_ID — numeric Telegram user ID |

> **Critical**: `TELEGRAM_ALLOWED_USERS` must be set as a Replit env var AND written to `~/.hermes/.env` at runtime (handled automatically by `run_gateway.sh`). Hermes v0.14.0 requires this — `allow_from` in config alone is not sufficient.

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
# Required: Replit deploy probe needs HTTP 200 to confirm app started
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

# Reset Telegram polling state — clears stale getUpdates sessions from old instances
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
```

**Why `deleteWebhook` before starting?**
Telegram's long-polling (`getUpdates`) has a server-side session. If a previous instance is killed without Telegram releasing the session, the next instance gets `Conflict: terminated by other getUpdates request`. Calling `deleteWebhook?drop_pending_updates=true` before each start resets this state immediately — no need to wait for Telegram's session timeout.

**Why the health check server?**
Replit's deploy probe sends `GET /` and requires HTTP 200 before marking the app as started. Hermes gateway does not serve HTTP, so without this Python server the deployment always fails with "app built successfully but failed to start".

**Why aggressive cleanup + 10s delay between restarts?**
Hermes exits code 1 on SIGTERM. The `pkill` + `hermes gateway stop` + `sleep 10` gives Telegram time to clear the session before the next attempt.

**Why write `~/.hermes/.env`?**
Hermes v0.14.0 reads `TELEGRAM_ALLOWED_USERS` from `$HERMES_HOME/.env`. Setting it only as a system env var is not sufficient.

### `artifacts/api-server/hermes_config.yaml`

```yaml
model:
  provider: portkey
  name: gemini-3.5-flash

telegram:
  free_response_chats: true
  allow_from:
    - 7281928709      # Replace with your Telegram user ID
  admin_from:
    - 7281928709

gateway:
  session_reset:
    mode: idle
    idle_minutes: 60
```

> Note: `allow_from` in config alone is NOT enough in Hermes v0.14.0. You must also set `TELEGRAM_ALLOWED_USERS` in `~/.hermes/.env` (done automatically by `run_gateway.sh`).

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

> **Critical**: Do NOT use `--user` in the pip install command. It fails with `ERROR: Can not perform a '--user' install. User site-packages are not visible in this virtualenv.`

### `artifacts/bot-status/.replit-artifact/artifact.toml`

```toml
kind = "web"
previewPath = "/"
title = "Hermes Bot Status"
version = "1.0.0"

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

Use the Replit package manager to install the `python-3.12` module.

### Step 2: Install Hermes & dependencies

```bash
pip install hermes-agent==0.14.0 python-telegram-bot==22.7 openai>=2.0.0 httpx>=0.28.0
```

Verify: `hermes --version` (should show v0.14.0)

### Step 3: Install Portkey Plugin

```bash
mkdir -p ~/.hermes/plugins/model-providers/portkey
cp artifacts/api-server/portkey_plugin/__init__.py ~/.hermes/plugins/model-providers/portkey/__init__.py
cp artifacts/api-server/portkey_plugin/plugin.yaml ~/.hermes/plugins/model-providers/portkey/plugin.yaml
```

### Step 4: Configure Hermes

```bash
cp artifacts/api-server/hermes_config.yaml ~/.hermes/config.yaml
# Edit allow_from: [your_telegram_user_id]
```

### Step 5: Set Required Env Vars

In Replit Secrets: `PORTKEY_API_KEY`, `TELEGRAM_BOT_TOKEN`, `SESSION_SECRET`

In Replit Shared Env:
- `PORTKEY_CONFIG=pc-gemini-85dd0b`
- `PORTKEY_BASE_URL=https://api.portkey.ai/v1`
- `PORTKEY_MODEL=gemini-3.5-flash`
- `TELEGRAM_CHAT_ID=<your_telegram_user_id>`
- `TELEGRAM_ALLOWED_USERS=<your_telegram_user_id>` ← **required, same value as TELEGRAM_CHAT_ID**

### Step 6: Deploy (Replit Publish)

⚠️ **CRITICAL**: Must select **Reserved VM** (not Autoscale) because:
- Autoscale sleeps when idle — bot stops responding
- Bot uses long-polling (persistent connection to Telegram)

Steps:
1. Click **Publish** in Replit
2. In Publishing settings → select **Reserved VM**
3. Click Deploy

## Gotchas & Sharp Edges

### 1. `pip install --user` fails in production build
**Cause**: Replit's build environment has a virtualenv active where `--user` installs are blocked.
**Fix**: Use `python3 -m pip install --break-system-packages -r requirements.txt` (no `--user` flag).

### 2. "App built successfully but failed to start"
**Cause**: Hermes gateway does not serve HTTP. Replit's deploy probe expects HTTP 200 on startup.
**Fix**: `run_gateway.sh` starts a Python `http.server` in the background on `$PORT` before launching the gateway.

### 3. `Conflict: terminated by other getUpdates request`
**Cause**: Telegram's long-polling has a server-side session. When an instance restarts, the old session isn't immediately released, causing conflicts.
**Fix**: Call `curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true"` before each gateway start. This resets Telegram's session state immediately.

### 4. "Unauthorized user" even with correct ID in hermes_config.yaml
**Cause**: Hermes v0.14.0 requires `TELEGRAM_ALLOWED_USERS` in `~/.hermes/.env`, not only `allow_from` in config.
**Fix**: `run_gateway.sh` writes `~/.hermes/.env` with `TELEGRAM_ALLOWED_USERS` on every startup. Also set `TELEGRAM_ALLOWED_USERS` as a Replit env var.

### 5. Hermes exits code 1 on SIGTERM
**Cause**: Hermes expects systemd to restart it (exits 1 = "signal-initiated shutdown").
**Fix**: The `run_gateway.sh` wrapper uses a `while true` restart loop.

### 6. "Nothing to publish" error in Replit UI
**Cause**: Replit's publishing UI requires at least one `kind=web` artifact.
**Fix**: Create a minimal react-vite artifact at `previewPath="/"` (the `bot-status` artifact handles this).

### 7. HERMES_HOME must be set
Hermes reads config from `$HERMES_HOME`. Always set `export HERMES_HOME="$HOME/.hermes"` in the run script.

### 8. Portkey config ID
`PORTKEY_CONFIG` must point to a valid Portkey virtual key/config targeting Gemini. Create at https://app.portkey.ai/configs.

### 9. Telegram allow_from
The `allow_from` list in `hermes_config.yaml` must include your numeric Telegram user ID (get from @userinfobot on Telegram). Also set the same value as `TELEGRAM_ALLOWED_USERS` env var.

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

# Check logs
tail -f ~/.hermes/logs/gateway.log
```

## Monitoring in Production

Look for these lines in Replit's deployment Logs tab:
- `[health] HTTP health check server listening on port 8080` — app started
- `[wrapper] Resetting Telegram polling state...` — clearing old sessions
- `[wrapper] Starting Hermes Gateway loop...` — gateway starting
- `✓ telegram connected` — bot is live and ready
