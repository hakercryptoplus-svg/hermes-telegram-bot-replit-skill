---
name: hermes-telegram-bot
description: Deploy Hermes Agent v0.14.0 as a Telegram bot on Replit using Portkey AI Gateway (Gemini). Always-running Reserved VM deployment.
---

# Hermes Telegram Bot — Replit Skill

## What This Builds

A Hermes Agent (Nous Research v0.14.0) connected to Telegram via `hermes gateway run`, powered by Google Gemini 3.5 Flash through Portkey AI Gateway. Deployed as a Replit Reserved VM.

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
│   ├── hermes_config.yaml         # Hermes model + telegram config
│   ├── requirements.txt           # hermes-agent==0.14.0, python-telegram-bot==22.7
│   ├── portkey_plugin/
│   │   ├── __init__.py            # register_provider(ProviderProfile(...))
│   │   └── plugin.yaml
│   └── .replit-artifact/artifact.toml
└── bot-status/
    ├── src/App.tsx                 # Simple status page
    └── .replit-artifact/artifact.toml
```

## `run_gateway.sh` — Critical Patterns

```bash
#!/bin/bash
export HERMES_HOME="$HOME/.hermes"
export HERMES_NO_UPDATE_CHECK="1"
export PORTKEY_CONFIG="${PORTKEY_CONFIG:-pc-gemini-85dd0b}"

# ── 1. SIGTERM TRAP (prevents zombie restart cascade on workflow restart) ───────
HERMES_PID=""
cleanup_and_exit() {
    [ -n "$HERMES_PID" ] && kill "$HERMES_PID" 2>/dev/null
    wait "$HERMES_PID" 2>/dev/null
    exit 0
}
trap cleanup_and_exit SIGTERM SIGHUP INT

# ... find hermes binary, write .env, install plugin, start health server ...

# ── 2. ONE-TIME STARTUP CLEANUP (NOT repeated in restart loop) ──────────────────
pkill -9 -f "hermes gateway" 2>/dev/null || true
sleep 3
"$HERMES_BIN" gateway stop 2>/dev/null || true
# 3x deleteWebhook + sleep 30 to clear Telegram session
for i in 1 2 3; do
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true" > /dev/null 2>&1
    sleep 5
done
sleep 30

# ── 3. RESTART LOOP with backoff on polling conflict ────────────────────────────
CONSECUTIVE_QUICK_EXITS=0
while true; do
    START_TIME=$(date +%s)

    # timeout 60 forces exit if hermes loops forever on polling conflict
    # hermes v0.14.0 retries internally forever and never self-exits on conflict
    timeout 60 "$HERMES_BIN" gateway run &
    HERMES_PID=$!
    wait $HERMES_PID
    EXIT_CODE=$?
    HERMES_PID=""

    UPTIME=$(( $(date +%s) - START_TIME ))
    echo "[wrapper] Gateway exited (code=$EXIT_CODE, uptime=${UPTIME}s)."

    # exit code 124 = timeout killed hermes = polling conflict with another instance
    if [ $EXIT_CODE -eq 124 ]; then
        CONSECUTIVE_QUICK_EXITS=$((CONSECUTIVE_QUICK_EXITS + 1))
        if [ "$CONSECUTIVE_QUICK_EXITS" -ge 3 ]; then
            echo "[wrapper] Production running. Backing off 5 minutes..."
            CONSECUTIVE_QUICK_EXITS=0
            sleep 300
            continue
        fi
    else
        CONSECUTIVE_QUICK_EXITS=0
    fi

    # DO NOT call deleteWebhook or gateway stop here — it would break the
    # production instance's Telegram session every 15 seconds
    sleep 15
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
```

> **Do NOT add a `providers:` block** — causes `telegram connect timed out`.

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

1. Development `run` MUST use absolute path:
```toml
[services.development]
run = "bash /home/runner/workspace/artifacts/api-server/run_gateway.sh"
```

2. Production build MUST use `--break-system-packages` (not `--user`):
```toml
[services.production.build]
args = ["bash", "-c", "python3 -m pip install --break-system-packages -r artifacts/api-server/requirements.txt && ..."]
```

## All Gotchas (12 total)

| # | Symptom | Fix |
|---|---------|-----|
| 1 | `pip install --user` fails in prod | Use `--break-system-packages` |
| 2 | App starts but Replit health check fails | Health server on `$PORT` must start BEFORE gateway |
| 3 | `Conflict: terminated by other getUpdates` on fresh start | deleteWebhook ×3 + 30s wait at ONE-TIME startup |
| 4 | "Unauthorized" even with correct ID | `TELEGRAM_ALLOWED_USERS` must be **numeric** (not `@username`) |
| 5 | `telegram connect timed out` | Remove `providers:` block from `hermes_config.yaml` |
| 6 | `No such file or directory` | Use absolute path in artifact.toml dev run command |
| 7 | SIGTERM loop — hermes exits code=143 on every restart | `trap cleanup_and_exit SIGTERM` + hermes in background with `&` |
| 8 | `Address already in use` on health server | `SO_REUSEADDR` + `try/except OSError: sys.exit(0)` |
| 9 | Bot shows "typing" but never responds | `deleteWebhook` in restart loop breaks production session — keep it ONLY in one-time startup |
| 10 | Dev/prod fight — typing never resolves | `timeout 60` + backoff 5min after 3 code=124 exits — hermes v0.14.0 NEVER self-exits on polling conflict |
| 11 | `TELEGRAM_ALLOWED_USERS` username rejected silently | Always set numeric Telegram user ID |
| 12 | Reserved VM required | Autoscale puts bot to sleep; long-polling needs 24/7 uptime |

## Deployment

⚠️ Select **Reserved VM** (not Autoscale).

Health path: `/api` — the Python health server answers any path.

## Architecture

```
User → Telegram API (long polling)
→ hermes gateway run (Hermes Agent v0.14.0)
→ Portkey AI Gateway (x-portkey-api-key + x-portkey-config)
→ Google Gemini 3.5 Flash → response → User
```
