# GBrain Agent

A 24/7 Telegram personal assistant powered by Hermes Agent + GBrain knowledge graph.

## Architecture

- **Hermes Agent** (kimi-k2.6 via opencode-go) — the conversational agent
- **GBrain** — self-building knowledge graph with 70 MCP tools
- **Telegram** — messaging platform via polling
- **Railway** — 24/7 hosting

## Deploy to Railway

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template/YOUR_TEMPLATE_ID)

Or deploy manually:

```bash
railway login
railway init
railway up
```

## Required Environment Variables

| Variable | Description |
|----------|-------------|
| `TELEGRAM_BOT_TOKEN` | From [@BotFather](https://t.me/botfather) |
| `OPENCODE_GO_API_KEY` | Your opencode-go API key |

## Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_MODEL` | `kimi-k2.6` | Model identifier |
| `LLM_PROVIDER` | `opencode-go` | Provider name |
| `LLM_BASE_URL` | `https://opencode.ai/zen/go/v1` | API base URL |
| `LLM_API_MODE` | `chat_completions` | Hermes API mode |
| `LLM_REASONING_EFFORT` | `high` | Reasoning effort for supported models |
| `HERMES_PROFILE` | `gbrain` | Hermes profile name |
| `GBRAIN_SEARCH_MODE` | `balanced` | `conservative`, `balanced`, `tokenmax` |

## Features

- **Brain-first lookup** — agent checks GBrain before any web search
- **Self-building knowledge graph** — people, companies, concepts auto-linked
- **Overnight synthesis** — dream cycle compiles daily conversations into patterns
- **70 MCP tools** — query, search, graph traversal, timeline, enrich, maintain

## Commands (in Telegram)

- `/help` — list commands
- `/status` — session info
- Any message — agent responds with brain-augmented context

## Persistent Storage

The GBrain PGLite database is initialized under `/data/.hermes/.gbrain`.
The service starts with `--no-embedding` unless you configure an embedding
provider, so capture/list/status work immediately and semantic embeddings can
be enabled later.

The service also maintains `/data/brain-repo` as a git-backed GBrain
source. A Hermes cron job syncs current Hermes sessions into
`brain-repo/conversations` every 10 minutes and a nightly cron runs
`gbrain dream`.

For production at larger scale, migrate to Supabase:

```bash
gbrain migrate --to supabase
```

Set `DATABASE_URL` env var and update `GBRAIN_DATABASE_URL` in Railway.

## Local Development

```bash
docker build -t gbrain-agent .
docker run -e TELEGRAM_BOT_TOKEN=xxx -e OPENCODE_GO_API_KEY=yyy gbrain-agent
```
