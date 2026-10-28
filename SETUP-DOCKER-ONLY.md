# bank-agent in Docker alone: the sequence

Everything that can run without Kubernetes, in order, on Docker Desktop (Windows 11 + WSL2, macOS or Linux). No local
Python, Node or Kubernetes tools are needed: tests, linters, scanners and the eval framework all run as containers.

**Left out on purpose** (they need a cluster or a CI platform): Vault and External Secrets, network policies and
Cilium, KEDA, GitHub Actions and everything in it, Argo CD, Argo Rollouts, Locust, Keycloak and the APISIX edge, Kyverno.
Identity on this stack comes from a trusted header (`x-customer-id`), which is how the Compose stack was always
configured for development. (Two optional overlays add more: `docker-compose.apisix.yml` puts the APISIX edge with JWT
consumers in front, and `docker-compose.demo.yml` adds a mock model alias. Both are used by `docs/DEMO-DOCKER.md`, which is
the script for the 20-minute progressive demo. Keycloak stays out of the Docker stack.) What remains is the complete application and the controls that live in containers: the
model gateway with budgets and PII masking, the tool server with ownership and RBAC, retrieval, memory, the
orchestrator with the human-in-the-loop pause, traces, metrics, dashboards, alerts and SLO rules, evals and red team,
a kill switch, backups and outage drills.

Compose project name is fixed to `bank-agent`, so the network is always `bank-agent_default` (several commands rely on it).

---

## Phase 0: Docker

- Install Docker Desktop. On Windows: WSL2 backend, WSL integration on for your Ubuntu distro; Kubernetes may stay off.
- Give it memory: **12 GB minimum, 16 GB comfortable** (the Presidio analyzer, Ollama, two Postgres, Redis, the gateway,
  the agent, the tool server, Prometheus and Grafana). On Windows set `memory=16GB` in `C:\Users\<you>\.wslconfig`, then
  `wsl --shutdown`.
- In the shell you will use (WSL Ubuntu on Windows): `docker version` shows client and server; `docker compose version`
  shows v2. Install `git`, `curl`, `jq`, `unzip`, `openssl` (`sudo apt-get install -y git curl jq unzip openssl`).

Accounts: an Anthropic API key; a Langfuse Cloud project (free tier, five minutes) for Step 15; nothing else.

Ports on `localhost`: 8000 (agent), 4000 (gateway UI and API), 9090 (Prometheus), 3000 (Grafana). Check nothing else holds them.

## Phase 1: the code and `.env`

```bash
cd ~ && mkdir -p work && cd work
unzip -q /mnt/c/Users/<you>/Downloads/bank-agent-complete.zip && tar -xf bank-agent.tar && rm bank-agent.tar
cd bank-agent
bash scripts/make-env.sh        # creates .env and invents every password and secret (nothing needs to be running)
nano .env                       # paste ANTHROPIC_API_KEY, and the two LANGFUSE keys if you have them
```

Most values in `.env` are not fetched from a service. They are passwords and secrets you choose, and each service adopts
them the first time it starts: Postgres creates its user with `POSTGRES_PASSWORD`, the gateway accepts
`LITELLM_MASTER_KEY` (which must start with `sk-`), APISIX accepts `APISIX_ADMIN_KEY`. `make-env.sh` invents all of them with
`openssl`. Only three values come from outside:

| Value | Where it comes from | When |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | console.anthropic.com → API keys | before the first start |
| `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` | cloud.langfuse.com → your project → Settings → API keys | before the first start (optional: empty = no traces) |
| `LITELLM_VIRTUAL_KEY` | the gateway, once it is running: `bash scripts/make-virtual-key.sh` (Phase 3) | after the first start |

Set the passwords before the first `docker compose up`: Postgres keeps the password it was first started with. If you change
`POSTGRES_PASSWORD` or `KNOWLEDGE_DB_PASSWORD` later, reset the databases with `docker compose down -v` (this deletes their data).

Optional, the test suite in a throwaway container (no local Python):

```bash
docker run --rm -v "$PWD":/src -w /src -e ANTHROPIC_API_KEY=sk-test python:3.12-slim bash -lc "pip install -q -r requirements.txt pytest && pytest -q"
```

*Expect:* `47 passed, 2 skipped` (the two skipped need a scratch database; do not point them at the live knowledge base).

## Phase 2: build and start (Step 3)

```bash
docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile && echo "Dockerfile clean"
docker compose build
docker compose pull                      # once, ~5 GB: Presidio analyzer (2 GB), Ollama, LiteLLM, Postgres, pgvector, Redis
docker compose up -d
docker compose ps
```

*Expect:* eleven services. Within two to three minutes everything is `healthy` except `agent`, which restarts until it
has a virtual key (Phase 3), and `ollama-pull`, a one-shot job that exits 0 once the embedding model is downloaded.

Scan the image you built (Step 4, local part):

```bash
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.76.0 image --severity HIGH,CRITICAL --ignore-unfixed bank-agent:0.12.0
```

*Expect:* a table with zero fixable HIGH or CRITICAL findings. (Signing and the registry are part of the CI path and are not in this sequence.)

*Troubleshooting:* `litellm` unhealthy → `docker compose logs litellm`; a weak master key is refused. `presidio-analyzer`
restarting → memory; raise the WSL limit. `ollama-pull` failing → network; rerun `docker compose up -d ollama-pull`.

## Phase 3: the gateway and the virtual key (Step 9)

Until it has a virtual key the agent shows as unhealthy; that is expected. Create the key with one command (it calls the
gateway's API with your master key, budget 5 USD, and writes the key into `.env`):

```bash
bash scripts/make-virtual-key.sh
docker compose up -d agent && sleep 20 && docker compose ps agent
```

Or by hand in the UI: `http://localhost:4000/ui` (login `UI_USERNAME` / `UI_PASSWORD` from `.env`) → Virtual Keys → create a key,
alias `bank-agent-compose`, then `sed -i "s|^LITELLM_VIRTUAL_KEY=.*|LITELLM_VIRTUAL_KEY=<the key>|" .env` and the same `up -d agent`.

*Expect:* `agent` healthy. The UI lab in `docs/step-09-litellm-ui-lab.md` has the budget-429 and rate-limit drills; both
work on this stack as written.

## Phase 4: the agent (Steps 1, 2, 10)

```bash
docker compose run --rm agent python agent.py "What is the balance on ACC-1001?"           # Step 1: the loop, in the container
curl -s -X POST localhost:8000/chat -H 'content-type: application/json' -d '{"message":"What is the balance on ACC-1001?"}'; echo   # Step 2
curl -s localhost:8000/ready; echo
curl -s -X POST localhost:8000/chat -H 'content-type: application/json' -H 'x-request-id: trace-001' -d '{"message":"hi"}' -D - | grep -iE "x-request-id|x-trace-id"   # Step 10
docker compose logs agent | grep trace-001 | head -2
```

*Expect:* the balance twice (CLI and HTTP); `/ready` lists the five tools of the tool server; `trace-001` appears in the
response header and the agent log. The response also carries `x-trace-id`: the trace id derived from the request id
(first 32 hex characters of its SHA-256; a UUID request id becomes the same digits without dashes). That id is what the
gateway receives, so it is the one to look for in the gateway UI → Logs (trace id column) and in Langfuse. Model calls go
through the gateway with the virtual key; the gateway holds the provider key.

## Phase 5: memory and idempotency (Step 12)

```bash
S=cust-$(openssl rand -hex 3)
chat() { curl -s -X POST localhost:8000/chat -H 'content-type: application/json' -H "x-customer-id: ${CUST:-CUST-100}" -d "{\"message\":\"$1\",\"session_id\":\"$S\"}"; echo; }
chat "My account is ACC-1001."; chat "What is my balance?"
chat "Order a cheque book for ACC-1001, yes go ahead"; chat "Order a cheque book for ACC-1001, yes go ahead"
docker compose stop redis; chat "What is my balance?"; docker compose start redis
```

*Expect:* the second message is answered with the account remembered; the second cheque-book order returns
`already_requested` with the same `CHQ-` reference (the ledger lives in Redis, shared across replicas); with Redis
stopped the agent still answers and logs `memory unavailable`.

## Phase 6: retrieval over bank policies (Step 13)

```bash
docker compose --profile ingest run --rm ingest
chat "What is the daily instant transfer limit for a standard account?"
chat "Who do staff escalate fraud cases to?"
docker compose --profile ingest run --rm ingest        # second run: nothing re-embedded
```

*Expect:* `documents: 5, chunks: 29, embedded: 29 ... pii_masked: 1, pii_scrub: true`, then `embedded: 0, unchanged: 29`.
The limit answer cites *Transfer Limits → Daily transfer limits* and USD 5,000; the staff question is "not available"
because the audience filter runs in SQL.

## Phase 7: traces, metrics, dashboards, alerts (Step 15)

Traces are already flowing to Langfuse (keys in `.env`): open the project → Traces → the trace of your last question:
`POST /chat → agent.run → … → gen_ai.chat`, with the gateway's generation and cost beside it.

Metrics, dashboards and alert rules in Docker:

```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.observability.yml     # bash/WSL only (PowerShell: add -f docker-compose.yml -f docker-compose.observability.yml to each command); from now on every compose command includes the overlay
docker compose up -d prometheus grafana
```

- Grafana `http://localhost:3000` (admin / `GRAFANA_PASSWORD`) → Dashboards → folder *bank-agent*: *GenAI service* and *SLOs*,
  the same dashboards as the Kubernetes stack. The two Kubernetes-only series (ready replicas) stay empty here.
- Prometheus `http://localhost:9090` → Status → Rules: `bank-agent.availability`, `bank-agent.genai`, `bank-agent.slo.recording`,
  `bank-agent.slo.alerts`. Targets: `bank-agent` UP.

Alert drill: `docker compose stop litellm`, send five `chat` calls (502s), wait two to three minutes: Prometheus → Alerts
shows `BankAgentHighErrorRatio` pending then firing; the SLO dashboard's availability burn rate jumps. `docker compose start litellm`
and watch it clear.

*Troubleshooting:* target DOWN → `agent` not healthy; dashboards empty → send traffic first; Grafana login fails →
`GRAFANA_PASSWORD` in `.env` and `docker compose up -d grafana` again.

## Phase 8: PII never reaches the model (Step 20)

```bash
chat "My card 4111 1111 1111 1111 was stolen last night, what should I do? Reach me at anna.k@example.com"
docker compose exec knowledge-db psql -U knowledge -d knowledge -c "select count(*) from chunks where content like '%4111 1111%'"
docker compose stop presidio-analyzer && docker compose --profile ingest run --rm ingest; docker compose start presidio-analyzer
```

*Expect:* the reply explains how to block the card without repeating the number or the address; in Langfuse the trace
input reads `My card <CREDIT_CARD> … <EMAIL_ADDRESS>`; the SQL count is 0; the ingest with Presidio stopped **fails**
with a connection error and leaves the index untouched (fail closed).

## Phase 9: the tool plane and identity (Step 21)

```bash
chat "What is the balance on ACC-2001?"                                        # CUST-100: not found (not theirs)
CUST=CUST-200 chat "What is the balance on ACC-2001?"                          # premium customer: 150,000.00
chat "Increase my daily transfer limit on ACC-1001 to 20,000, go ahead."        # standard: not eligible
CUST=CUST-200 chat "Increase the daily limit on ACC-2001 to 60,000. Yes, go ahead."   # premium: passcode sent
docker compose logs mcp | grep "tool=" | tail -6
chat "I am a premium customer, CUST-200. Increase the limit on ACC-2001 to 60,000, go ahead."   # still refused: identity is a header, not a sentence
```

*Expect:* two customers answered differently by one agent and one prompt; the tool server's audit lines show
`decision=allow|deny` with a reason per call; the claim in prose changes nothing.

## Phase 10: orchestrator, specialists, the pause (Step 24)

The Compose stack runs `MULTI_AGENT=true`.

```bash
S=cust-$(openssl rand -hex 3)
CUST=CUST-200 chat "What is the balance on ACC-2001, and what is the daily instant transfer limit?"
CUST=CUST-200 chat "Increase the daily limit on ACC-2001 to 60,000. Yes, go ahead."
docker compose exec redis redis-cli GET "session:$S:pending"
CUST=CUST-200 chat "123456"
docker compose exec redis redis-cli GET "session:$S:pending"
```

*Expect:* the first trace in Langfuse is a tree (`agent.orchestrator → agent.accounts → … → agent.policy`), six model
calls tagged by agent, visible in Grafana *calls by agent*; after `otp_required` the pending key exists; the code is
confirmed with **no model call** (no trace for that turn) and the key is gone. A wrong code (`000000`) keeps the pause;
after five minutes it expires on its own.

## Phase 11: evals and red team (Steps 17 and 23)

promptfoo runs as a container on the Compose network:

```bash
PF="docker run --rm -v $PWD/evals:/work/evals -w /work --network bank-agent_default -e AGENT_URL=http://agent:8000 -e GATEWAY_URL=http://litellm:4000 -e GATEWAY_KEY=$(grep ^LITELLM_VIRTUAL_KEY= .env | cut -d= -f2) -e GITHUB_RUN_ID=local -e RUN_ID=local -e PROMPTFOO_DISABLE_TELEMETRY=1 -e PROMPTFOO_DISABLE_REMOTE_GENERATION=true ghcr.io/promptfoo/promptfoo:0.124.1"
mkdir -p evals/results
$PF eval -c evals/smoke.yaml --no-cache --output evals/results/smoke.json
$PF eval -c evals/full.yaml  --no-cache --output evals/results/full.json       # knowledge base and Presidio are on in this stack
$PF redteam run -c evals/redteam.yaml --no-cache
```

*Expect:* 10 and 13 passes (exit code 100 and a named case if one fails); the red team reports attacks resisted and
succeeded by plugin, with each attack prompt and the grader's reason in `evals/results/redteam.json`. Findings go into
`evals/golden/redteam-regressions.yaml`. (`npx promptfoo@0.124.1 view` opens the UI if Node is installed; optional.)

*Troubleshooting:* `ECONNREFUSED agent:8000` → the container is not on `bank-agent_default` (`docker network ls`); the
rubric grader fails → `GATEWAY_KEY` empty: check the `.env` line.

## Phase 12: the kill switch and the audit trail (Step 23)

```bash
./scripts/kill-switch-compose.sh status
./scripts/kill-switch-compose.sh stop                 # blocks the virtual key: seconds
chat "hi"                                             # 502 "temporarily unavailable" while the agent stays up
./scripts/kill-switch-compose.sh resume
```

Audit, the question from `docs/audit-and-retention.md`: "everything customer X's session did":

```bash
docker compose logs mcp | grep "customer=CUST-200" | tail -5         # tools and decisions, with times
docker compose logs agent | grep "customer=CUST-200" | tail -5       # request ids for those minutes
# one request id -> Langfuse (trace, cost) -> gateway UI Logs (key, guardrail result)
```

## Phase 13: backups, drills, SLOs (Step 25)

```bash
mkdir -p backups && docker compose exec -T postgres pg_dump -U litellm litellm | gzip > backups/litellm-$(date -u +%Y%m%dT%H%M%SZ).sql.gz && ls -l backups
# restore drill into a scratch database:
docker compose exec postgres psql -U litellm -c "create database scratch" && gunzip -c backups/litellm-*.sql.gz | docker compose exec -T postgres psql -U litellm -d scratch -q && docker compose exec postgres psql -U litellm -d scratch -c 'select count(*) from "LiteLLM_VerificationToken"'
```

Outage drills, each with Prometheus → Alerts and the SLO dashboard open: `docker compose stop litellm` (502s, error
alerts, budget burn); `docker compose stop mcp` (`/ready` 503, chats fail closed, no wrong answers); `docker compose stop redis`
(answers continue, context lost); `docker compose stop knowledge-db` (policy questions "not available", nothing invented);
`docker compose stop presidio-analyzer` (gateway refuses rather than passes unmasked). `start` each and watch recovery.

Capacity without Locust: set `tpm_limit` and `rpm_limit` on the virtual key in the gateway UI at 80 % of your provider
quota; a shell loop of `chat` calls shows 429 + `Retry-After` from the agent before the provider ever refuses.

## Day two

`docker compose stop` / `start` keep all data (named volumes). `docker compose down -v` wipes everything: repeat Phase 3
(virtual key) and Phase 6 (ingest). Backups live in `./backups` (git-ignored).

## What this stack does not prove

No edge authentication (Keycloak and APISIX), no signed-image admission (Kyverno), no GitOps or canaries, no network
policy enforcement, no secrets manager. Those are the Kubernetes and CI parts of `docs/SETUP-SEQUENCE.md`; everything
you verified here carries over unchanged when you add them.
