# Hermes Telegram Bot — Replit Skill

> **Hermes Agent v0.14.0** (Nous Research) connected to Telegram via official `hermes gateway run`, powered by **Google Gemini 3.5 Flash** through **Portkey AI Gateway**. Deployed as a Replit Reserved VM (always running).

## Quick Start for Any Replit Agent

Read `SKILL.md` — it contains everything needed to rebuild this project from scratch, including:
- All file contents (copy-paste ready)
- Exact setup steps
- All gotchas and sharp edges
- Architecture diagram
- Deployment instructions

## Files in This Repo

| File | Purpose |
|------|---------|
| `SKILL.md` | Complete agent skill — read this first |
| `run_gateway.sh` | Bot startup script with restart loop |
| `hermes_config.yaml` | Hermes model + Telegram configuration |
| `portkey_plugin/__init__.py` | Portkey provider plugin for Hermes |
| `portkey_plugin/plugin.yaml` | Plugin metadata |
| `requirements.txt` | Python dependencies |
| `artifact_api_server.toml` | artifact.toml for the bot backend |
| `artifact_bot_status.toml` | artifact.toml for the web status page |

## Required Secrets

```
PORTKEY_API_KEY      → https://app.portkey.ai
TELEGRAM_BOT_TOKEN   → @BotFather on Telegram
SESSION_SECRET       → any random string
```

## Required Env Vars

```
PORTKEY_CONFIG=pc-gemini-85dd0b
PORTKEY_BASE_URL=https://api.portkey.ai/v1
PORTKEY_MODEL=gemini-3.5-flash
TELEGRAM_CHAT_ID=<your_telegram_user_id>
```

## ⚠️ Critical: Use Reserved VM Deployment

**NOT Autoscale.** The bot uses long-polling and must run 24/7. Autoscale sleeps when idle and doesn't have Python in its build environment.

## Architecture

```
Telegram → hermes gateway run → Hermes Agent v0.14.0 → Portkey → Gemini 3.5 Flash
```
