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
| `TELEGRAM_ALLOWED_USERS` | Same as TELEGRAM_CHAT_ID — **numeric Telegram user ID** (NOT username) |

> **Critical**: `TELEGRAM_ALLOWED_USERS` must be a **numeric ID** (e.g. `7281928709`), NOT a username like `@myuser`. Set it as a Replit env var AND it gets written to `~/.hermes/.env` at runtime (handled automatically by `run_gateway.sh`).

## Project Structure

```
artifacts/
├── api-server/                    # Hermes bot backend
│   ├── run_gateway.sh             # Bot startup script (health + SIGTERM trap + restart loop)
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

> ⚠️ **Critical**: Must use `trap cleanup_and_exit SIGTERM SIGHUP INT` at the top, and run `hermes gateway run` in **background** (`&`) with PID tracking. Without this, Replit workflow restarts create multiple bash instances fighting over the same hermes process.

```bash
#!/bin/bash
export HERMES_HOME="$HOME/.hermes"
export HERMES_NO_UPDATE_CHECK="1"
export PORTKEY_CONFIG="${PORTKEY_CONFIG:-pc-gemini-85dd0b}"

# ── SIGNAL HANDLING ────────────────────────────────────────────────────────────
# When Replit workflow sends SIGTERM, exit cleanly (don't loop forever)
HERMES_PID=""
cleanup_and_exit() {
    echo "[wrapper] SIGTERM received — shutting down cleanly..."
    [ -n "$HERMES_PID" ] && kill "$HERMES_PID" 2>/dev/null
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

# ── INSTALL PORTKEY PLUGIN ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERMES_HOME/plugins/model-providers/portkey"
cp "$SCRIPT_DIR/portkey_plugin/__init__.py" "$HERMES_HOME/plugins/model-providers/portkey/__init__.py"
cp "$SCRIPT_DIR/portkey_plugin/plugin.yaml" "$HERMES_HOME/plugins/model-providers/portkey/plugin.yaml"
cp "$SCRIPT_DIR/hermes_config.yaml" "$HERMES_HOME/config.yaml"
echo "[wrapper] Installed plugin + copied config"

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

# ── INITIAL CLEANUP ────────────────────────────────────────────────────────────
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
while true; do
    # Run hermes in background so our SIGTERM trap can catch workflow shutdown
    "$HERMES_BIN" gateway run &
    HERMES_PID=$!
    echo "[wrapper] Gateway PID: $HERMES_PID"

    # Wait for hermes to exit (trap fires on SIGTERM before this)
    wait $HERMES_PID
    EXIT_CODE=$?

    echo "[wrapper] Gateway exited (code=$EXIT_CODE). Restarting in 15s..."
    HERMES_PID=""

    "$HERMES_BIN" gateway stop 2>/dev/null || true
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    sleep 15
    echo "[wrapper] Restarting gateway..."
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
run = "bash /home/runner/workspace/artifacts/api-server/run_gateway.sh"

[services.production]

[services.production.build]
args = ["bash", "-c", "python3 -m pip install --break-system-packages -r artifacts/api-server/requirements.txt && mkdir -p $HOME/.hermes/plugins/model-providers/portkey && cp artifacts/api-server/portkey_plugin/__init__.py $HOME/.hermes/plugins/model-providers/portkey/__init__.py && cp artifacts/api-server/portkey_plugin/plugin.yaml $HOME/.hermes/plugins/model-providers/portkey/plugin.yaml && cp artifacts/api-server/hermes_config.yaml $HOME/.hermes/config.yaml"]

[services.production.run]
args = ["bash", "/home/runner/workspace/artifacts/api-server/run_gateway.sh"]

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
router = "path"

[[integratedSkills]]
name = "react-vite"
version = "1.0.0"

[[services]]
name = "web"
paths = [ "/" ]
localPort = 22053

[services.development]
run = "pnpm --filter @workspace/bot-status run dev"

[services.production]
build = [ "pnpm", "--filter", "@workspace/bot-status", "run", "build" ]
publicDir = "artifacts/bot-status/dist/public"
serve = "static"

[[services.production.rewrites]]
from = "/*"
to = "/index.html"

[services.env]
PORT = "22053"
BASE_PATH = "/"
```

## Setup Steps (from scratch)

### Step 1: Install Python 3.12

Use the Replit package manager (`installProgrammingLanguage({ language: "python-3.12" })`).

### Step 2: Install Hermes & dependencies

```bash
pip install hermes-agent==0.14.0 python-telegram-bot==22.7 "openai>=2.0.0" "httpx>=0.28.0" --break-system-packages
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

### Step 4: Update artifact.toml development command

The development run command must use the **absolute path**:
```
run = "bash /home/runner/workspace/artifacts/api-server/run_gateway.sh"
```
Using a relative path like `bash artifacts/api-server/run_gateway.sh` fails because the workflow runner uses a different working directory.

### Step 5: Deploy (Replit Publish)

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

### 6. `bash: run_gateway.sh: No such file or directory`
**Cause**: Relative path in artifact.toml development `run` command. Workflow runner uses different working directory.
**Fix**: Use absolute path: `bash /home/runner/workspace/artifacts/api-server/run_gateway.sh`

### 7. Gateway SIGTERM loop — hermes starts then immediately exits code=143
**Cause**: Replit workflow restart sends SIGTERM to bash. Without a proper trap, bash exits but the `while true` loop may continue in orphaned instances. Multiple instances then use `pkill -f "hermes gateway"` and kill each other's hermes processes.
**Fix**: Add `trap cleanup_and_exit SIGTERM SIGHUP INT` at the top of the script. Run `hermes gateway run &` in **background** with `HERMES_PID=$!` tracking. The trap kills only the tracked PID and exits cleanly. **Do NOT use `pkill -f "hermes gateway"` inside the restart loop** — it kills the newly started gateway too.

### 8. Health server `Address already in use` on loop restart
**Cause**: Health server is started in background and remains running. On loop restart the script tries to bind the same port again.
**Fix**: Use `SO_REUSEADDR` + try/except in the health server — if port already bound, just `sys.exit(0)` silently.

### 9. `TELEGRAM_ALLOWED_USERS` must be numeric
Always use the numeric Telegram user ID (get from @userinfobot on Telegram), never a username.

### 10. HERMES_HOME must be set
Always `export HERMES_HOME="$HOME/.hermes"` in the run script.

### 11. Dev and Production conflict on same bot token
Only ONE instance of hermes can poll Telegram at a time with the same bot token. If you have a production deployment running, the dev workflow will show `Conflict: terminated by other getUpdates request` and cannot connect. Stop the production deployment or use a different bot token for dev testing.

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
bash /home/runner/workspace/artifacts/api-server/run_gateway.sh
```

## Monitoring in Production

Look for these lines in Replit's deployment Logs tab:
- `[health] Listening on port 8080` — app started
- `[wrapper] Resetting Telegram polling state...` — clearing old sessions
- `[wrapper] Starting gateway...` — about to launch
- `[wrapper] Gateway PID: XXXX` — hermes started in background
- `✓ telegram connected` — bot is live and ready
