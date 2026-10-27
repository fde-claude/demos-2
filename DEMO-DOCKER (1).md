# The 20-minute progressive demo, Docker only (with APISIX)

One stack on one laptop, shown one layer at a time: client → Python app → model first, then a layer per stage. The demo
console (`demo-ui/`, a Streamlit page that runs as a Compose service) drives it; this document is what the console talks to and what you say.

**What the console and the stack agree on**

- Chat goes to the app (stages 1–2) or through APISIX (stages 3–10), with the persona's identity.
- Five features can be switched off or forced for **one request** with `x-feature-*` headers. The app honours them only when
  `DEMO_FEATURE_HEADERS=true`.
- Three security controls are **locked on** and show green in the console: PII masking (gateway guardrail), the injection rules
  (prompt rules 6 and 9 plus the eval gate) and OTP approval (tool server). No header can switch them; a test guards that.
- Identity comes from the token (stage 4 is "token identity", with APISIX JWT consumers; Keycloak is not in the Docker stack).

---

## 0. The demo console

**On Windows, read this first.** Run every command of this document in **Ubuntu (WSL)**, not in PowerShell: the helper scripts
(`configure.sh`, `mint-jwt.sh`, the kill switches) are bash scripts, and `export` is a bash command. The unpacked folder is at
`/mnt/c/Users/<you>/Downloads/bank-agent` inside Ubuntu. One-time fixes there:

```bash
chmod +x scripts/*.sh deploy/compose/apisix/configure.sh        # Windows unpacking drops the executable bit
sed -i 's/\r$//' scripts/*.sh deploy/compose/apisix/configure.sh  # only if a script fails with "bad interpreter ... ^M"
```

If you must use PowerShell for `docker compose` itself, `export COMPOSE_FILE=...` does not work there. Name the files instead
(this works in every shell), and use the same four `-f` flags on every command:

```powershell
docker compose -f docker-compose.yml -f docker-compose.observability.yml -f docker-compose.apisix.yml -f docker-compose.demo.yml up -d --build
```

A `no such service: demo-ui` error means the overlay files were not loaded; `... config --services` lists what Compose sees.
Warnings such as `The "ANTHROPIC_API_KEY" variable is not set` mean there is no `.env` file yet: `cp .env.example .env` and fill it in.

```bash
docker compose up -d --build demo-ui        # then open http://localhost:8501   (only on this machine: it holds the demo secrets)
docker compose run --rm demo-ui python smoke_test.py      # 33 checks against a fake network; needs no stack
```

- **Left:** the chat, the spend of this session, and under it the **request journey**: after each reply the page fetches that
  request's trace from Langfuse by the `x-trace-id` header and shows each step (agent, model call, tool) with tokens and time.
- **Right:** the 10-stage slider with what to say and what to try; the **feature blocks** (click to flip: Force fallback, Memory,
  Knowledge, Tools, Multi-agent; green on, red off, grey not reached yet); three **locked** blocks (PII masking, Injection rules,
  OTP approval: always green, no button, no header); the **platform map** of the 24 components; the dashboard links.
- **Platform map:** components that can be reached from inside Docker get a live dot (green or red): APISIX, the app, the gateway,
  Langfuse, Prometheus, Grafana, Redis, the knowledge database, Presidio, the tool server, and Locust (purple "start it" until the
  `load` profile runs). Ten components are greyed "not in this demo" because they need Kubernetes or a CI platform: Keycloak, Argo CD,
  KEDA, Argo Rollouts, GitHub Actions, Cosign, Kyverno, Vault and External Secrets, Cilium, the Helm chart. Three show purple:
  OpenTelemetry (inside the app), Trivy and Syft, promptfoo (run on demand).
- **Defaults per stage** (what the page sends): Banking tools are on from stage 1, because the Step 1 agent already had a balance tool
  and the identity stage needs data. Memory is on from stage 6, Knowledge from 7, Multi-agent from 9; a feature that has not been
  reached is sent as `off`, so stage 1 really is client → app → model. Clicking a block overrides the default for the next request.
- **Credentials:** stages 1–2 send `x-customer-id`. Stage 3 offers "no token" (401) or alice's token. From stage 4 the page mints a
  short-lived token for the selected person with that person's APISIX consumer secret.
- **Burst button** (stage 3+): six quick requests, shows the status codes. Run `./deploy/compose/apisix/configure.sh limit 3` first
  to see 200, 200, 200, 429, 429, 429.
- **Diagnostics:** if you force the fallback and the answer does not change model, the page says the app ignored the demo headers
  (set `DEMO_FEATURE_HEADERS=true` in `.env`). A missing secret or Langfuse key is reported on the page.

## 1. Bring it up (once, before the demo)

```bash
cd bank-agent && cp -n .env.example .env
# in .env: the keys from docs/SETUP-DOCKER-ONLY.md Phase 1, plus these (use openssl rand -hex 32 for secrets):
#   APISIX_ADMIN_KEY, BANK_CLIENT_JWT_SECRET, MOBILE_APP_JWT_SECRET, STAFF_PORTAL_JWT_SECRET, GRAFANA_PASSWORD
#   DEMO_FEATURE_HEADERS=true      FALLBACK_MODEL_ID=bank-fallback      EDGE_RATE_LIMIT=30
export COMPOSE_FILE=docker-compose.yml:docker-compose.observability.yml:docker-compose.apisix.yml:docker-compose.demo.yml:docker-compose.locust.yml
docker compose build && docker compose up -d      # includes the demo console
```

Then, in order: create the gateway virtual key (`docs/SETUP-DOCKER-ONLY.md` Phase 3) → run the ingest (Phase 6) → configure the edge:

```bash
./deploy/compose/apisix/configure.sh apply
```

*Expect:* `docker compose ps` shows every service `healthy` (APISIX takes about 30 s after etcd); `configure.sh` prints the upstream,
three consumers, the route and the Prometheus plugin. Set `EDGE_RATE_LIMIT` high (30) for the demo; stage 3 lowers it live.

**Ports on `localhost`**

| Port | What | Port | What |
| --- | --- | --- | --- |
| 8000 | agent (stages 1–2 go here) | 9080 | APISIX proxy (stages 3–10 go here) |
| 4000 | gateway API and UI | 9180 | APISIX Admin API and dashboard (`/ui/`, login `APISIX_ADMIN_KEY`) |
| 3000 | Grafana | 7085 | APISIX health (`/status/ready`) |
| 9090 | Prometheus | 8089 | Locust (only with `--profile load`) |

## 2. The three personas and their tokens

| Persona | Stage 1–2 (direct to the app) | Stage 3+ (through APISIX) | Who they are |
| --- | --- | --- | --- |
| alice | header `x-customer-id: CUST-100` | consumer `bank_client`, jwt key `bank-client` | standard customer, owns ACC-1001 and ACC-1002 |
| bob | header `x-customer-id: CUST-200` | consumer `mobile_app`, jwt key `mobile-app` | premium customer, owns ACC-2001 |
| carol | header `x-customer-id: STAFF-001` | consumer `staff_portal`, jwt key `staff-portal` | staff: sees the staff documents, owns no accounts |

```bash
set -a; source .env; set +a
ALICE=$(JWT_KEY=bank-client  JWT_SECRET=$BANK_CLIENT_JWT_SECRET  ./scripts/mint-jwt.sh 3600)
BOB=$(JWT_KEY=mobile-app     JWT_SECRET=$MOBILE_APP_JWT_SECRET   ./scripts/mint-jwt.sh 3600)
CAROL=$(JWT_KEY=staff-portal JWT_SECRET=$STAFF_PORTAL_JWT_SECRET ./scripts/mint-jwt.sh 3600)
```

The token carries only the consumer's key and an expiry; APISIX verifies the signature and tells the app which consumer it was,
and the app looks up the customer. The persona is never typed into the request body.

## 3. What the console sends and reads

**Request:** `POST /chat` with `{"message": "...", "session_id": "..."}`, plus `x-request-id` (any string) and the persona's
identity (header on stages 1–2, `Authorization: Bearer <token>` from stage 3). Switches:

| Header | Values | Effect | Default when absent |
| --- | --- | --- | --- |
| `x-feature-force-fallback` | `on` | call the fallback alias `bank-fallback` (Opus 5.5) instead of `bank-primary` (Haiku 5.5) | normal model |
| `x-feature-memory` | `off` | no conversation history loaded or saved for this request | on |
| `x-feature-rag` | `off` | the policy-search tool is not offered | on |
| `x-feature-tools` | `off` | the banking tools are not offered (balance, transactions, cheque book, limits) | on |
| `x-feature-multi-agent` | `off` | single-agent path even though the deployment runs the orchestrator | on |

A header can only turn something **off** (or choose between two model aliases that already exist). Naming `pii`, `injection`,
`hitl` or `approval` does nothing. The reply's `model` field reports the alias that really answered.

**Response headers to read:** `x-request-id` (echo) and `x-trace-id` (the Langfuse trace id for this request).

**Health checks the console can run from the host**

| Component | Check | Healthy |
| --- | --- | --- |
| agent | `GET :8000/health`, and `GET :8000/ready` (also proves the tool server is reachable) | 200 |
| gateway | `GET :4000/health/liveliness` | 200 |
| APISIX | `GET :7085/status/ready` (503 until every worker has its config from etcd) | 200 |
| Prometheus | `GET :9090/-/healthy` | 200 |
| Grafana | `GET :3000/api/health` | 200 |
| Langfuse Cloud | `GET {LANGFUSE_HOST}/api/public/health` | 200 |
| tool server, Redis, Postgres, knowledge-db, Presidio, Ollama, etcd | not published on the host: `docker compose ps --format json` and read each service's `Health` | `healthy` |

**Alert count for stage 10:** `curl -s localhost:9090/api/v1/alerts | jq '[.data.alerts[] | select(.state=="firing")] | length'`.

## 4. One trace per request (and a correction)

Before this step the app's spans carried a random trace id and appeared in Langfuse as a **separate** trace from the gateway's
model-call records; the earlier statement (Step 15 runbook, handbook) that they share one trace was not true. Now:

- the app derives the trace id from the request id: a UUID becomes the same 32 digits without dashes, anything else
  (`trace-001`) becomes the first 32 hex characters of its SHA-256;
- the same id goes to the gateway as `x-litellm-trace-id` and to the client as `x-trace-id`;
- the root span carries the session id as `langfuse.session.id`.

For the console: `GET {LANGFUSE_HOST}/api/public/traces/{x-trace-id}` with HTTP basic auth `LANGFUSE_PUBLIC_KEY:LANGFUSE_SECRET_KEY`
returns the trace; its observations are the journey table (agent spans, model calls with tokens and cost, tool calls). If a
session has no trace yet, the fallback is `GET /api/public/traces?sessionId={session_id}`. Allow a few seconds: traces are
exported in batches.

## 5. The ten stages

| # | Layer added | Console sends | What you say | What to expect |
| --- | --- | --- | --- | --- |
| 1 | client → Python app → model | `POST :8000/chat`, `x-customer-id` of the persona | "A 60-line loop with one tool. Nothing in front of it." | an answer with the balance; `model: bank-primary` |
| 2 | + the model gateway | same, plus `x-feature-force-fallback: on` for one request | "The app never holds the provider key. The gateway chooses the model, caps the budget and records every call." | `model: bank-fallback`; gateway UI → Logs shows the call on Opus with cost; the key's spend moves |
| 3 | + APISIX | `POST :9080/chat`, no token → 401; with `$ALICE` → 200; then `./deploy/compose/apisix/configure.sh limit 3` and four calls → 429 | "Nothing reaches the app without a verified token, and a client cannot exceed its quota." | 401, 200 with `x-request-id`, then 429 with `X-RateLimit-*`; APISIX dashboard shows the route; reset with `configure.sh limit 30` |
| 4 | + token identity | `$ALICE`, `$BOB`, `$CAROL`; the same question "balance on ACC-2001?" | "Who is calling is a verified token, not a sentence. Same agent, same prompt." | alice: not found; bob: 150,000.00; carol: not found. A forged `x-customer-id: CUST-200` sent with alice's token changes nothing (APISIX strips it) |
| 5 | + input guardrails (locked) | "My card 4111 1111 1111 1111 was stolen, reach me at anna.k@example.com" | "The model never saw the number. Masking is in the gateway, so no application can forget it." | the reply helps block the card without repeating it; in Langfuse the input reads `<CREDIT_CARD>`, `<EMAIL_ADDRESS>`. Then alice: "Show my recent transactions on ACC-1002": the planted memo is called an unusual memo and ignored |
| 6 | + memory | one `session_id`: "My account is ACC-1001." then "What is my balance?", with `x-feature-memory: on` then `off` | "Memory is Redis with a time limit, and the agent still answers if Redis is down." | on: remembered; off: asks for the account again |
| 7 | + retrieval and the audience filter | "What is the daily instant transfer limit for a standard account?" with `x-feature-rag: on` then `off`; then the escalation question as alice and as carol | "Answers come from the bank's documents, with citations. Staff documents are filtered in SQL, not in the prompt." | on: USD 5,000 with the document and section; off: no grounded answer (this is the point); carol gets the staff document, alice gets "not available" |
| 8 | + the tool server and OTP | bob: "Increase the daily limit on ACC-2001 to 60,000, go ahead", then "123456"; alice asks the same | "Rules live in the tool server, where a prompt cannot reach them. The code is the human step." | bob: passcode requested, then approved; alice: refused (premium only). Keep memory on: in single-agent mode the conversation carries the challenge. `x-feature-tools: off` shows the same question with no tools |
| 9 | + multi-agent | a mixed question: "Balance on ACC-2001 and the daily instant transfer limit?" with `x-feature-multi-agent: on` then `off`; then bob's limit request and the code | "A front desk and two specialists, each with its own prompt and tools, on the same loop." | Langfuse tree: orchestrator → accounts → policy; six model calls tagged by agent; the passcode reply has **no model call** (no trace for that turn) |
| 10 | platform drills | see section 6 | "How we stop it, how it behaves under load, and what we see when things fail." | kill switch, Locust, an outage and the alert count |

The three locked blocks stay green from the stage that introduces them: PII masking and injection rules (stage 5), OTP approval (stage 8). They never become a header.

## 6. Stage 10: the drills

**Kill switch (two levers, timed)**

```bash
./scripts/kill-switch-compose.sh status
./scripts/kill-switch-compose.sh stop       # edge answers 503 with a customer message; the agent's gateway key is blocked
curl -s -w "\n%{http_code}\n" -X POST localhost:9080/chat -H "Authorization: Bearer $ALICE" -H 'content-type: application/json' -d '{"message":"hi"}'
./scripts/kill-switch-compose.sh resume
```

*Expect:* `[1s] edge: ...503`, `[2s] gateway: virtual key BLOCKED`, then 503 with the message; after `resume`, 200 again. Each lever works alone.

**Load and the 429 wave (Locust as a container)**

```bash
LOCUST_TOKEN=$ALICE docker compose --profile load up -d locust      # http://localhost:8089
```

In the Locust page set the host: `http://apisix:9080` to see the edge limit (429 per consumer), or `http://agent:8000` with
`LOCUST_TOKEN` empty and a TPM limit on the virtual key (gateway UI) to see the quota ceiling. A 429 counts as success in the
test; only 5xx is a failure. The shape ramps 3 → 12 users in five minutes. Stop it: `docker compose --profile load stop locust`.

**Outage drills (`docker compose stop <service>`, then `start`)**

| Stop | What the audience sees | Alert or panel |
| --- | --- | --- |
| `litellm` | chat returns 502 (generic message); `/ready` stays 200 | error ratio and the SLO burn-rate panel move within a minute; `BankAgentHighErrorRatio` fires after 5 minutes |
| `mcp` | `/ready` returns 503; chat fails closed, no wrong answers | tool errors rise |
| `redis` | answers continue, context is lost | log `memory unavailable` |
| `presidio-analyzer` | the gateway refuses rather than passing unmasked text | errors on every call (fail closed) |

**Alerts take minutes by design** (five minutes of errors, or two for a scrape-down). Start the outage around minute 12 and look at
Prometheus → Alerts and the alert count at minute 17; the burn-rate panel on the SLO dashboard reacts at once.

## 7. Fallback plan: the model provider is slow

`docker-compose.demo.yml` makes the gateway also serve `bank-mock`: a fixed sentence produced by the gateway itself, no provider call.

```bash
curl -s localhost:4000/v1/messages -H "x-api-key: $LITELLM_VIRTUAL_KEY" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
  -d '{"model":"bank-mock","max_tokens":50,"messages":[{"role":"user","content":"hi"}]}'        # dry run: must answer instantly
echo "AGENT_MODEL_ID=bank-mock" >> .env && docker compose up -d agent                           # switch
sed -i '/^AGENT_MODEL_ID=/d' .env && docker compose up -d agent                                  # switch back
```

*What still works on the mock:* the edge (401/429), token identity, masking, traces, metrics, the kill switch. *What does not:* tools,
retrieval, memory content and OTP (a mock never asks for a tool). So stages 1–5 survive a slow provider; stages 6–9 need the real model.
If the virtual key has a model allow-list, add `bank-mock` to it.

## 8. The 20 minutes

| Minutes | Stages | Notes |
| --- | --- | --- |
| 0–2 | 1 | the loop, nothing in front |
| 2–4 | 2 | the gateway: the fallback and the cost |
| 4–7 | 3–4 | 401, 429, three personas |
| 7–9 | 5 | the card number never reaches the model |
| 9–11 | 6–7 | memory, retrieval, staff vs customer |
| 11–14 | 8–9 | tools, passcode, orchestrator; start the `litellm` outage at minute 12 |
| 14–19 | 10 | kill switch, Locust, the alert and the SLO panel |
| 19–20 | | the security controls that no switch can change |

## 9. Verify on the first dry run (ten minutes, before the real one)

These pieces are tested with fakes or at library level here, not against the running containers. Check each once:

- **APISIX healthy:** `docker compose ps apisix` shows `healthy` (the container healthcheck uses `curl` inside the image; if it never turns healthy, change the check or remove it).
- **Edge keeps your headers:** a request through APISIX with `x-feature-memory: off` and your own `x-request-id` comes back with the same `x-request-id` and behaves as off.
- **One trace in Langfuse:** after a request through the edge, open the trace for `x-trace-id`: the app's spans and the gateway's model call must be in it. If they are in two traces, tell me what Langfuse shows and I will adjust the id mapping.
- **Session mapping:** the trace shows the session id under Sessions; the root span sets `langfuse.session.id`.
- **Mock alias:** the `bank-mock` curl above answers instantly through the running gateway.
- **Alerts:** stop `litellm`, send five requests, confirm the error ratio rises on the SLO dashboard within a minute.
- **Console:** `http://localhost:8501` loads, `docker compose ps demo-ui` shows `healthy`, the platform map shows green dots for the containers that run (press Refresh status), and `docker compose run --rm demo-ui python smoke_test.py` prints `33 of 33 checks passed`.
- **Journey table:** after a message the table fills within about ten seconds. If it stays empty, the trace is not under the `x-trace-id` the page used: open Langfuse, find the trace by time, and tell me what it shows.

## 10. What this demo does not show

Keycloak OIDC (stage 4 uses JWT consumers), signed-image admission, GitOps and canary releases, network policy enforcement and
a secrets manager: they need Kubernetes and CI, and are in `docs/SETUP-SEQUENCE.md` and the handbook. Stages 1–2 trust a header for
identity on purpose; port 8000 is published for them, so run the demo on a trusted laptop.
