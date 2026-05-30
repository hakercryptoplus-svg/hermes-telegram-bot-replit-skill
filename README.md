# OpenClaw Telegram Bot

An OpenClaw (v2026.5.28) personal AI assistant connected to Telegram via long-polling, powered by Google Gemini 3.5 Flash through Portkey AI Gateway. Deployed as a Replit Reserved VM.

## Run & Operate

- Bot starts automatically via `artifacts/api-server/run_gateway.sh`
- Status page served from `artifacts/bot-status/`
- Required env: see Secrets section below

## Stack

- OpenClaw: v2026.5.28 (Node.js, installed via npm)
- AI: Google Gemini 3.5 Flash via Portkey AI Gateway (litellm-compatible provider)
- Frontend status page: React + Vite (inline styles only — no heavy deps)

## Where things live

- `artifacts/api-server/run_gateway.sh` — Bot startup script (health server + SIGTERM trap + restart loop)
- `artifacts/api-server/.replit-artifact/artifact.toml` — Service config (build: npm install -g openclaw)

## Architecture

```
User → Telegram API (long polling)
→ openclaw gateway (OpenClaw v2026.5.28)
→ Portkey AI Gateway (litellm provider, x-portkey-config header)
→ Google Gemini 3.5 Flash → response → User
```

## Config written at runtime

`run_gateway.sh` writes two files on startup:
- `~/.openclaw/.env` — env vars (PORTKEY_API_KEY, TELEGRAM_BOT_TOKEN, etc.)
- `~/.openclaw/openclaw.json` — full config (provider, model, channels, gateway)

## Required Secrets

| Secret | Where to get |
|--------|-------------|
| `PORTKEY_API_KEY` | https://app.portkey.ai → API Keys |
| `TELEGRAM_BOT_TOKEN` | @BotFather on Telegram |
| `SESSION_SECRET` | Any random string (used as gateway token) |

## Required Env Vars

| Variable | Value |
|----------|-------|
| `PORTKEY_CONFIG` | Your Portkey config ID (e.g. `pc-gemini-85dd0b`) |
| `PORTKEY_BASE_URL` | `https://api.portkey.ai/v1` |
| `PORTKEY_MODEL` | `gemini-3.5-flash` |
| `TELEGRAM_CHAT_ID` | Your numeric Telegram user ID (from @userinfobot) |
| `TELEGRAM_ALLOWED_USERS` | Same as TELEGRAM_CHAT_ID — numeric only |

## Deployment

⚠️ **Must use Reserved VM** (not Autoscale). The bot uses long-polling and must run 24/7.

Health path: `/api`

## Why OpenClaw instead of Hermes

Hermes had a streaming bug: "waiting for stream response (60s, no chunks yet)" causing 8-10+ minute delays on responses. The issue was in Hermes's streaming layer, not the model (Gemini via Portkey is fast). OpenClaw is a drop-in replacement that uses Telegram long-polling without streaming issues.

## Gotchas

- `TELEGRAM_ALLOWED_USERS` must be **numeric** (not `@username`)
- `TELEGRAM_CHAT_ID` is used as `allowFrom` in openclaw.json — must be numeric
- The startup script waits 35s before connecting — intentional, lets Telegram expire old sessions
- `gateway.mode: "local"` is required in openclaw.json — gateway refuses to start without it
- `gateway.auth.token` (not `gateway.token`) is the correct config key
- OpenClaw is installed to `~/.config/npm/node_global/bin/openclaw` on first run if not already present
- Use Reserved VM deployment, not Autoscale

## User preferences

_Populate as you build — explicit user instructions worth remembering across sessions._
