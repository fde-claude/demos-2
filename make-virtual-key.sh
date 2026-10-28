#!/usr/bin/env bash
# scripts/make-virtual-key.sh — after the gateway is running: create the agent's virtual key and write it into .env.
# Same result as creating it by hand in the gateway UI (Phase 3 of docs/SETUP-DOCKER-ONLY.md), with a 5 USD budget.
#   bash scripts/make-virtual-key.sh
set -euo pipefail
set -a; source .env; set +a
[ -n "$LITELLM_MASTER_KEY" ] || { echo "LITELLM_MASTER_KEY is empty: run scripts/make-env.sh first"; exit 1; }
curl -sf -o /dev/null http://localhost:4000/health/liveliness || { echo "the gateway is not answering on localhost:4000 yet: wait a minute (docker compose ps litellm)"; exit 1; }

answer=$(curl -s -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "content-type: application/json" \
  -d '{"key_alias": "bank-agent-compose", "max_budget": 5}')
key=$(echo "$answer" | python3 -c "import sys, json; print(json.load(sys.stdin).get('key', ''))")
[ -n "$key" ] || { echo "the gateway did not return a key: $answer"; exit 1; }

sed -i "s|^LITELLM_VIRTUAL_KEY=.*|LITELLM_VIRTUAL_KEY=$key|" .env
echo "LITELLM_VIRTUAL_KEY written to .env (alias bank-agent-compose, budget 5 USD)."
echo "Now restart the agent so it reads it:   docker compose up -d agent"
