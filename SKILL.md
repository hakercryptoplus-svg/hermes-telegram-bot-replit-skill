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

## Project Structure

```
artifacts/
├── api-server/                    # Hermes bot backend
│   ├── run_gateway.sh             # Bot startup script (restart loop)
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
```

**Why the restart loop?** Hermes exits with code 1 on SIGTERM (expects systemd to restart it). Replit isn't systemd, so the wrapper loop handles this.

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
args = ["bash", "-c", "python3 -m pip install --user -r artifacts/api-server/requirements.txt && mkdir -p $HOME/.hermes/plugins/model-providers/portkey && cp artifacts/api-server/portkey_plugin/__init__.py $HOME/.hermes/plugins/model-providers/portkey/__init__.py && cp artifacts/api-server/portkey_plugin/plugin.yaml $HOME/.hermes/plugins/model-providers/portkey/plugin.yaml && cp artifacts/api-server/hermes_config.yaml $HOME/.hermes/config.yaml"]

[services.production.run]
args = ["bash", "artifacts/api-server/run_gateway.sh"]
```

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

### Step 1: Install Hermes

```bash
pip install hermes-agent==0.14.0 python-telegram-bot==22.7 openai>=2.0.0 httpx>=0.28.0
```

Verify: `hermes -z` (should connect and respond)

### Step 2: Install Portkey Plugin

```bash
mkdir -p ~/.hermes/plugins/model-providers/portkey
# Copy portkey_plugin/__init__.py → ~/.hermes/plugins/model-providers/portkey/__init__.py
# Copy portkey_plugin/plugin.yaml → ~/.hermes/plugins/model-providers/portkey/plugin.yaml
```

### Step 3: Configure Hermes

```bash
# Copy hermes_config.yaml → ~/.hermes/config.yaml
# Edit allow_from: [your_telegram_user_id]
```

### Step 4: Set Replit Workflow

The workflow runs: `bash artifacts/api-server/run_gateway.sh`

Confirm in `.replit`:
```toml
[[workflows.workflow]]
name = "Hermes Telegram Bot"
[[workflows.workflow.tasks]]
task = "shell.exec"
args = "bash artifacts/api-server/run_gateway.sh"
```

### Step 5: Deploy (Replit Publish)

⚠️ **CRITICAL**: Must select **Reserved VM** (not Autoscale) because:
- Autoscale sleeps when idle — bot stops responding
- Bot uses long-polling (persistent connection to Telegram)
- Python/pip not available in Autoscale cloud build images

Steps:
1. Click **Publish** in Replit
2. In Publishing settings → select **Reserved VM**
3. Click Deploy

## Gotchas & Sharp Edges

### 1. `pip3: command not found` in production build
**Cause**: Autoscale build images don't have Python.  
**Fix**: Use `python3 -m pip install --user` (not `pip3`) AND use Reserved VM deployment.

### 2. Hermes exits code 1 on SIGTERM
**Cause**: Hermes expects systemd to restart it (exits 1 = "signal-initiated shutdown, please restart me").  
**Fix**: The `run_gateway.sh` wrapper uses a `while true` restart loop.

### 3. "Nothing to publish" error in Replit UI
**Cause**: Replit's publishing UI requires at least one `kind=web` artifact. A project with only `kind=api` and `kind=design` is rejected.  
**Fix**: Create a minimal react-vite artifact at `previewPath="/"` (the `bot-status` artifact handles this).

### 4. `verifyAndReplaceArtifactToml cannot change artifact kind`
**Cause**: Replit's artifact system doesn't allow changing `kind` via the callback.  
**Fix**: The `kind=api` artifact cannot be changed. The bot-status `kind=web` artifact at `/` satisfies the publishing requirement.

### 5. HERMES_HOME must be set
The hermes binary reads config from `$HERMES_HOME` (defaults to `~/.hermes`). Always set `export HERMES_HOME="$HOME/.hermes"` in the run script.

### 6. Portkey config ID
`PORTKEY_CONFIG=pc-gemini-85dd0b` is a specific Portkey virtual key/config. Create yours at https://app.portkey.ai/configs pointing to Gemini.

### 7. Telegram allow_from
The `allow_from` list in `hermes_config.yaml` must include your Telegram numeric user ID. Get it from @userinfobot on Telegram.

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

The Portkey plugin is a **Hermes provider plugin** registered via `register_provider()`. It sets custom HTTP headers (`x-portkey-api-key`, `x-portkey-config`) on every LLM call, routing through Portkey's proxy to Gemini.

## Testing

```bash
# Test Hermes + Portkey connection
hermes -z

# Test gateway
hermes gateway run
# → Should show: ✓ telegram connected

# Check logs
tail -f ~/.hermes/logs/gateway.log
```

## Monitoring in Production

```bash
# Check internal logs (dev environment)
tail -f ~/.hermes/logs/gateway.log

# Replit deployment logs
# Use Replit's "Logs" tab in the deployment panel
```
