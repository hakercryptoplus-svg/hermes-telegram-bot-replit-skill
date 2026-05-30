---
name: hermes-telegram-bot
description: Deploy Hermes Agent (Nous Research >=0.14.0, tested on 0.15.2) as a Telegram bot on Replit using Portkey AI Gateway (Gemini). Always-running Reserved VM deployment.
---

# Hermes Telegram Bot — Replit Skill

## What This Builds

A Hermes Agent (Nous Research >=0.14.0) connected to Telegram via `hermes gateway run`, powered by Google Gemini 3.5 Flash through Portkey AI Gateway. Deployed as a Replit Reserved VM.

## Required Secrets

| Secret | Where to get it |
|--------|----------------|
| `PORTKEY_API_KEY` | https://app.portkey.ai → API Keys |
| `TELEGRAM_BOT_TOKEN` | @BotFather on Telegram |
| `SESSION_SECRET` | Any random string |

## Required Env Vars

| Variable | Value |
|----------|-------|
| `PORTKEY_CONFIG` | Your Portkey config ID (e.g. `pc-gemini-85dd0b`) |
| `PORTKEY_BASE_URL` | `https://api.portkey.ai/v1` |
| `PORTKEY_MODEL` | `gemini-3.5-flash` |
| `TELEGRAM_CHAT_ID` | Your numeric Telegram user ID (from @userinfobot) |
| `TELEGRAM_ALLOWED_USERS` | Same as TELEGRAM_CHAT_ID — **numeric only, NOT @username** |

## Project Structure

```
artifacts/
├── api-server/
│   ├── run_gateway.sh             # Bot startup — health server + SIGTERM trap + restart loop
│   ├── hermes_config.yaml         # ⚠️ MUST exist here — production build copies it (publish blocker if missing)
│   ├── requirements.txt           # hermes-agent>=0.14.0, python-telegram-bot==22.7
│   ├── portkey_plugin/
│   │   ├── __init__.py            # register_provider(ProviderProfile(...))
│   │   └── plugin.yaml
│   └── .replit-artifact/artifact.toml
└── bot-status/
    ├── src/App.tsx                 # Simple status page (no heavy deps — inline styles only)
    └── .replit-artifact/artifact.toml
```

## `run_gateway.sh` — Critical Patterns

```bash
#!/bin/bash
export HERMES_HOME="$HOME/.hermes"
export HERMES_NO_UPDATE_CHECK="1"
export PORTKEY_CONFIG="${PORTKEY_CONFIG:-pc-gemini-85dd0b}"

# ── 1. SIGTERM TRAP ──────────────────────────────────────────────────────────────
HERMES_PID=""
cleanup_and_exit() {
    [ -n "$HERMES_PID" ] && kill "$HERMES_PID" 2>/dev/null
    wait "$HERMES_PID" 2>/dev/null
    exit 0
}
trap cleanup_and_exit SIGTERM SIGHUP INT

# ... find hermes binary, write .env, install plugin, write config, start health server ...

# ── 2. ONE-TIME STARTUP CLEANUP ──────────────────────────────────────────────────
pkill -9 -f "hermes gateway" 2>/dev/null || true
sleep 2

# deleteWebhook once to drop pending updates
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1

# ⚠️ DO NOT call getUpdates here — it opens a competing long-poll that causes
# Telegram "polling conflict" errors in hermes for up to 10 minutes.
# Wait 35s so Telegram closes any old long-poll session naturally (max timeout = 30s).
echo "[wrapper] Waiting 35s for any existing Telegram session to expire..."
sleep 35

# ── 3. RESTART LOOP ───────────────────────────────────────────────────────────────
while true; do
    START_TIME=$(date +%s)
    PYTHONUNBUFFERED=1 "$HERMES_BIN" gateway run &
    HERMES_PID=$!
    wait $HERMES_PID
    EXIT_CODE=$?
    HERMES_PID=""

    pkill -9 -f "hermes gateway" 2>/dev/null || true

    # ⚠️ DO NOT call getUpdates in the restart loop — creates competing long-polls.
    # Wait 35s for Telegram's session to expire naturally before restarting.
    sleep 35
done
```

## `hermes_config.yaml`

```yaml
model:
  provider: portkey
  name: gemini-3.5-flash

telegram:
  free_response_chats: true
  allow_from:
    - 7281928709      # your numeric Telegram user ID
  admin_from:
    - 7281928709

gateway:
  session_reset:
    mode: idle
    idle_minutes: 60

stt:
  enabled: true

display:
  tool_progress: all       # sends progress messages to Telegram during tool calls
  platforms:
    telegram:
      tool_progress: all
```

> **Do NOT add a `providers:` block** — causes `telegram connect timed out`.
>
> ⚠️ **This file must be placed at `artifacts/api-server/hermes_config.yaml`** — the production build copies it from there. A missing file at this path will silently fail at publish time. (See Gotcha #13)

## `portkey_plugin/__init__.py`

```python
import os
from providers import register_provider
from providers.base import ProviderProfile

portkey = ProviderProfile(
    name="portkey",
    aliases=("portkey-ai", "portkey_ai"),
    display_name="Portkey AI Gateway",
    description="Portkey — unified AI gateway",
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

## `artifact.toml` — Critical Points

1. Development `run` MUST use **absolute path**:
```toml
[services.development]
run = "bash /home/runner/workspace/artifacts/api-server/run_gateway.sh"
```

2. Production build MUST use `--break-system-packages` and copy `artifacts/api-server/hermes_config.yaml`:
```toml
[services.production.build]
args = ["bash", "-c", "python3 -m pip install --break-system-packages -r artifacts/api-server/requirements.txt && mkdir -p $HOME/.hermes/plugins/model-providers/portkey && cp artifacts/api-server/portkey_plugin/__init__.py $HOME/.hermes/plugins/model-providers/portkey/__init__.py && cp artifacts/api-server/portkey_plugin/plugin.yaml $HOME/.hermes/plugins/model-providers/portkey/plugin.yaml && cp artifacts/api-server/hermes_config.yaml $HOME/.hermes/config.yaml"]
```

## `bot-status/src/App.tsx`

Simple status page — **no heavy dependencies, inline styles only**. Do NOT use Radix/shadcn components or import from `@workspace/api-client-react` — it causes build failures. Use the `bot_status_App.tsx` file from this repo directly.

## All Gotchas (14 total)

| # | Symptom | Fix |
|---|---------|-----|
| 1 | `pip install --user` fails in prod | Use `--break-system-packages` |
| 2 | App starts but Replit health check fails | Health server on `$PORT` must start BEFORE gateway |
| 3 | `Conflict: terminated by other getUpdates` on fresh start | `deleteWebhook` once + `sleep 35` — let Telegram expire sessions naturally (max 30s). **Never call `getUpdates` in startup or restart loop.** |
| 4 | "Unauthorized" even with correct ID | `TELEGRAM_ALLOWED_USERS` must be **numeric** (not `@username`) |
| 5 | `telegram connect timed out` | Remove `providers:` block from `hermes_config.yaml` |
| 6 | `No such file or directory` | Use absolute path in artifact.toml dev run command |
| 7 | SIGTERM loop — hermes exits code=143 on every restart | `trap cleanup_and_exit SIGTERM` + hermes in background with `&` |
| 8 | `Address already in use` on health server | `SO_REUSEADDR` + `try/except OSError: sys.exit(0)` |
| 9 | Bot shows "typing" but never responds (10+ min delay) | **Root cause**: `getUpdates?timeout=1` in restart loop competes with hermes long-poll → Telegram conflict → 20s × N retries. Fix: remove ALL `getUpdates` calls from startup and restart loop, use `sleep 35` instead. |
| 10 | Bot responds but user never sees "computing..." updates | Add `display.tool_progress: all` and `display.platforms.telegram.tool_progress: all` to `hermes_config.yaml` |
| 11 | `TELEGRAM_ALLOWED_USERS` username rejected silently | Always set numeric Telegram user ID |
| 12 | Reserved VM required | Autoscale puts bot to sleep; long-polling needs 24/7 uptime |
| 13 | **Publish fails silently** — production build errors | `hermes_config.yaml` MUST exist at `artifacts/api-server/hermes_config.yaml`. The build step does `cp artifacts/api-server/hermes_config.yaml $HOME/.hermes/config.yaml` — if the file is missing the build fails. |
| 14 | `timeout 3600` in restart loop causes hourly drops | Removed — hermes runs indefinitely. The SIGTERM trap handles clean shutdown. |

## Rate Limiting

If the bot responds to some messages but not others (HTTP 429 errors in logs):

```
Quota exceeded: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20/day
```

**Fix:** Add a Google AI API key to your Portkey config at https://app.portkey.ai. Without one, Google limits you to 20 requests/day. With a free API key (https://aistudio.google.com/apikey) you get 1500/day.

## Deployment

⚠️ Select **Reserved VM** (not Autoscale).

Health path: `/api` — the Python health server answers any path.

## Architecture

```
User → Telegram API (long polling)
→ hermes gateway run (Hermes Agent >=0.14.0)
→ Portkey AI Gateway (x-portkey-api-key + x-portkey-config)
→ Google Gemini 3.5 Flash → response → User
```
