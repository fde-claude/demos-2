#!/usr/bin/env bash
# scripts/make-env.sh — create .env for the Docker stack, before anything is running.
#
# Most values in .env are not fetched from a service: they are passwords and secrets YOU invent, and each service adopts
# them the first time it starts (Postgres creates its user with POSTGRES_PASSWORD, the gateway accepts LITELLM_MASTER_KEY,
# APISIX accepts APISIX_ADMIN_KEY ...). This script invents them all with openssl. Afterwards you paste only:
#   ANTHROPIC_API_KEY                         from console.anthropic.com -> API keys
#   LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY  from cloud.langfuse.com -> your project -> Settings -> API keys (optional: no keys = no traces)
#   LITELLM_VIRTUAL_KEY                       after the first start: ./scripts/make-virtual-key.sh fills it for you
#
# Run once, from the bank-agent folder:   bash scripts/make-env.sh
set -euo pipefail
[ -f .env.example ] || { echo "run this from the bank-agent folder"; exit 1; }
if [ -f .env ]; then
  echo ".env already exists, so nothing was changed. To start fresh: mv .env .env.old && bash scripts/make-env.sh"
  exit 1
fi
cp .env.example .env

# every invented secret: 48 hex characters (safe inside URLs such as the database address)
for name in LITELLM_SALT_KEY UI_PASSWORD POSTGRES_PASSWORD KNOWLEDGE_DB_PASSWORD GRAFANA_PASSWORD APISIX_ADMIN_KEY \
            BANK_CLIENT_JWT_SECRET MOBILE_APP_JWT_SECRET STAFF_PORTAL_JWT_SECRET; do
  sed -i "s|^$name=.*|$name=$(openssl rand -hex 24)|" .env
done
# the gateway's master key must start with sk-
sed -i "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24)|" .env

# demo settings
sed -i "s|^DEMO_FEATURE_HEADERS=.*|DEMO_FEATURE_HEADERS=true|" .env
sed -i "s|^EDGE_RATE_LIMIT=.*|EDGE_RATE_LIMIT=30|" .env

# the values that come from outside start EMPTY, so nothing runs with a fake key by accident
for name in ANTHROPIC_API_KEY LANGFUSE_PUBLIC_KEY LANGFUSE_SECRET_KEY LITELLM_VIRTUAL_KEY; do
  sed -i "s|^$name=.*|$name=|" .env
done
chmod 600 .env   # only you can read it

echo ".env created with all invented secrets filled in."
echo "Now paste these two lines' values into .env (nano .env):"
echo "   ANTHROPIC_API_KEY=            <- console.anthropic.com, API keys"
echo "   LANGFUSE_PUBLIC_KEY= / LANGFUSE_SECRET_KEY=   <- cloud.langfuse.com project settings (optional)"
echo "Then start the stack, and run:  bash scripts/make-virtual-key.sh"
