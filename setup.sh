#!/usr/bin/env bash
# Configure the Claude Code CLI to run on GitHub Copilot models through a
# Dockerised LiteLLM gateway on port 4000.
#
# Order matters. The gateway resolves a Copilot key while it loads a
# github_copilot model, so with no cached token it runs the OAuth device flow
# inline: the code goes into the container log and the port never opens. This
# script authorizes first and starts the gateway second.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/.env"
TOKEN_DIR="$HOME/.config/litellm/github_copilot"
BASE="http://127.0.0.1:4000"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mfail:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Prerequisites ---------------------------------------------------------
command -v docker >/dev/null || die "docker not found."
docker compose version >/dev/null 2>&1 || die "The docker compose plugin is not available."
docker info >/dev/null 2>&1 || die "The Docker daemon is not running. Start Docker Desktop."
command -v claude >/dev/null || die "The claude CLI is not on PATH. Install Claude Code first."
[[ -f "$HERE/config.yaml" ]] || die "config.yaml is missing next to this script."
[[ -f "$HERE/docker-compose.yml" ]] || die "docker-compose.yml is missing next to this script."

if lsof -nP -iTCP:4000 -sTCP:LISTEN >/dev/null 2>&1 \
   && ! docker ps --format '{{.Names}}' | grep -qx litellm-copilot; then
  die "Something other than this gateway already listens on port 4000."
fi

# --- 2. Master key ------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
  log "Reusing existing $ENV_FILE"
else
  log "Generating a proxy master key into $ENV_FILE"
  umask 077
  {
    echo "# Local LiteLLM gateway settings. Do not commit."
    echo "LITELLM_MASTER_KEY=sk-$(python3 -c 'import secrets; print(secrets.token_hex(20))' 2>/dev/null \
      || openssl rand -hex 20)"
  } > "$ENV_FILE"
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
[[ -n "${LITELLM_MASTER_KEY:-}" ]] || die "LITELLM_MASTER_KEY is missing from $ENV_FILE."

# --- 3. GitHub Copilot device authorization -----------------------------------
# Create the directory as your user first. Left to Docker it would appear as a
# root-owned mount point.
mkdir -p "$TOKEN_DIR"

if [[ -s "$TOKEN_DIR/access-token" ]]; then
  log "Copilot access token already cached in $TOKEN_DIR"
else
  log "Authorizing with GitHub. This runs in a throwaway container."
  echo
  echo "  A URL and an 8-character code appear below."
  echo "  Open the URL, paste the code, and approve the request."
  echo "  The poll window is 60 seconds. If it times out, re-run this script."
  echo
  docker compose -f "$HERE/docker-compose.yml" run --rm --no-deps \
    --entrypoint /app/.venv/bin/python litellm /app/copilot_login.py \
    || die "Copilot authorization did not complete. Re-run ./setup.sh."
  [[ -s "$TOKEN_DIR/access-token" ]] \
    || die "Authorization reported success but $TOKEN_DIR/access-token is empty."
fi

# --- 4. Start the gateway -----------------------------------------------------
log "Starting the gateway"
docker compose -f "$HERE/docker-compose.yml" up -d

log "Waiting for the gateway to report healthy"
for _ in $(seq 1 60); do
  state="$(docker inspect -f '{{.State.Health.Status}}' litellm-copilot 2>/dev/null || echo starting)"
  [[ "$state" == "healthy" ]] && break
  sleep 2
done
[[ "$state" == "healthy" ]] \
  || die "The gateway is $state. Check: docker compose logs litellm"
log "Gateway healthy on $BASE"

# --- 5. Prove Copilot answers through the gateway -----------------------------
log "Testing a real completion against Copilot"
if curl -fsS -m 120 -X POST "$BASE/v1/messages" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"copilot-sonnet","max_tokens":16,"messages":[{"role":"user","content":"Reply with the single word: ready"}]}' \
    | grep -qi ready; then
  log "Copilot answered. The whole chain works."
else
  die "The completion failed. Check: docker compose logs --tail 40 litellm"
fi

cat <<EOF

Setup complete. Launch Claude Code on Copilot models with:

    $HERE/claude-copilot.sh

Pick a model up front, or with /model inside the session:

    $HERE/claude-copilot.sh --model copilot-gpt

Gateway controls:

    docker compose logs -f litellm     # follow the request log
    docker compose restart litellm     # after editing config.yaml
    docker compose down                # stop it
EOF
