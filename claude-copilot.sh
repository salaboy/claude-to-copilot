#!/usr/bin/env bash
# Launch the Claude Code CLI against the Dockerised LiteLLM gateway, so every
# request is served by a GitHub Copilot model on your Copilot subscription.
# Arguments are forwarded to `claude`, so `./claude-copilot.sh -p "hi"` works.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="http://127.0.0.1:4000"

[[ -f "$HERE/.env" ]] || { echo "Run ./setup.sh first." >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$HERE/.env"
set +a

if ! curl -fsS -m 3 "$BASE/health/liveliness" >/dev/null 2>&1; then
  echo "Nothing is answering on $BASE." >&2
  echo "Start the gateway with: docker compose -f $HERE/docker-compose.yml up -d" >&2
  exit 1
fi

# Route the CLI at the gateway and authenticate with the proxy master key.
export ANTHROPIC_BASE_URL="$BASE"
export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
# A stale key here would be sent as x-api-key and beat the bearer token.
unset ANTHROPIC_API_KEY

# Map Claude Code's built-in aliases onto the model_name entries in config.yaml.
# Without these the CLI asks for Anthropic model IDs the gateway does not serve.
# The haiku alias also carries all background work, so keep it cheap.
export ANTHROPIC_DEFAULT_OPUS_MODEL="${COPILOT_OPUS_MODEL:-copilot-opus}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${COPILOT_SONNET_MODEL:-copilot-sonnet}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${COPILOT_HAIKU_MODEL:-copilot-haiku}"

# Let /model list what the gateway serves. Needs Claude Code 2.1.129 or later.
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

# The CLI does not recognise these model names, so it guesses the context
# window and warns. Copilot reports max_prompt_tokens=200000 for every Claude
# model here, so state it and the warning goes away. Raise it to 272000 if you
# work mainly through copilot-gpt.
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${COPILOT_MAX_CONTEXT_TOKENS:-200000}"

exec claude "$@"
