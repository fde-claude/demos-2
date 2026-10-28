# bank-agent demo script — Windows laptop (WSL + Docker Desktop)

Commands and expected results, in order. Run every command in the **Ubuntu (WSL)** terminal, inside `~/bank-agent`; open every
link in the **Windows browser**. *Expect* is what you should see. If you see something else, go to Part G.

| Part | When | Time |
| --- | --- | --- |
| A. First-time set-up | once per laptop | 30–45 min (mostly downloads) |
| B. Dry-run checklist | the day before | about 60 min |
| C. Pre-flight | demo day, 15 minutes before | 10 min |
| D. The demo, stages 1–10 | the demo | 20 min |
| E. Reset between runs | after a rehearsal or a demo | 3 min |
| F. Shut down | when you are done | 1 min |
| G. Troubleshooting | when an *Expect* does not match | — |

---

## Part A — First-time set-up

### A1. Docker Desktop

- Docker Desktop → Settings → General: **Use the WSL 2 based engine** on. Resources → WSL integration: your Ubuntu on. Kubernetes can stay off.
- Memory: create `C:\Users\<you>\.wslconfig` with these lines, then run `wsl --shutdown` in PowerShell and reopen Ubuntu:
  ```ini
  [wsl2]
  memory=16GB
  ```

```bash
docker version && docker compose version
```
*Expect:* a `Client:` and a `Server:` section, then `Docker Compose version v2…` or later.

### A2. Put the code in WSL

```bash
cd ~
cp /mnt/c/Users/<you>/Downloads/bank-agent-complete.zip .
unzip -o -q bank-agent-complete.zip && tar -xf bank-agent.tar && rm bank-agent.tar bank-agent-complete.zip
cd ~/bank-agent
chmod +x scripts/*.sh deploy/compose/apisix/configure.sh
ls
```
*Expect:* `agent.py  app.py  demo-ui  deploy  docs  scripts  tests …`. Unpacking over an existing `~/bank-agent` keeps your `.env`.

### A3. Create `.env`

```bash
bash scripts/make-env.sh
nano .env
```
*Expect:* `.env created with all invented secrets filled in.` In nano, fill these lines, then save (Ctrl+O, Enter) and exit (Ctrl+X):

```
ANTHROPIC_API_KEY=sk-ant-...          from console.anthropic.com -> API keys
LANGFUSE_PUBLIC_KEY=pk-lf-...         from cloud.langfuse.com -> your project -> Settings -> API keys
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_HOST=https://cloud.langfuse.com      (or https://us.cloud.langfuse.com for a US project)
```

If it says `.env already exists`, keep the one you have.

### A4. Tell Compose which files to use (once; every new terminal then knows)

```bash
echo 'export COMPOSE_FILE=docker-compose.yml:docker-compose.observability.yml:docker-compose.apisix.yml:docker-compose.demo.yml:docker-compose.locust.yml' >> ~/.bashrc
source ~/.bashrc
docker compose config --services | wc -l
```
*Expect:* `15`.

### A5. Build and download

```bash
docker compose build
docker compose pull --ignore-buildable
```
*Expect:* the build ends with `bank-agent` and `bank-agent-demo-ui` built; the pull downloads about 5 GB the first time
(Presidio analyzer, Ollama, gateway, databases, monitoring) and ends without errors.

### A6. Start everything and wait

```bash
docker compose up -d
bash scripts/wait-for-stack.sh
```
*Expect:* lines such as `ready 9/15 | waiting for: presidio-analyzer (starting), litellm (created)` every 10 seconds, then
`ready 15/15` and `The stack is ready.` A first start takes 3–6 minutes: the gateway waits for Presidio, which loads slowly.
The agent counts as ready here even though it has no key yet.

### A7. Give the agent its gateway key

Two commands, each on its own line:

```bash
bash scripts/make-virtual-key.sh
docker compose up -d agent
```
*Expect:* `LITELLM_VIRTUAL_KEY written to .env (budget 5 USD).`, then the agent is recreated. Check it:

```bash
bash scripts/wait-for-stack.sh
curl -s localhost:8000/ready; echo
```
*Expect:* `The stack is ready.` and `{"status":"ready","model":"bank-primary","tools":["get_account_balance", …]}`.

### A8. Load the knowledge base

```bash
docker compose --profile ingest run --rm ingest
```
*Expect:* the last line reads `ingest complete {"documents": 5, "chunks": 29, "embedded": 29, "unchanged": 0, "deleted": 0, "pii_masked": 1, "pii_scrub": true, …}`
(`pii_masked` can be higher). Running it again gives `"embedded": 0, "unchanged": 29`.

### A9. Configure the edge (APISIX)

```bash
./deploy/compose/apisix/configure.sh apply
```
*Expect* exactly:
```
upstream bank-agent -> agent:8000
consumer bank_client (jwt key bank-client) -> CUST-100 standard
consumer mobile_app (jwt key mobile-app) -> CUST-200 premium
consumer staff_portal (jwt key staff-portal) -> STAFF-001 staff
route /chat: jwt-auth, limit-count 30/min per consumer, request-id, header hygiene
prometheus plugin enabled globally
```

### A10. Browser tabs and logins

```bash
grep -E '^(UI_USERNAME|UI_PASSWORD|GRAFANA_PASSWORD|APISIX_ADMIN_KEY)=' .env
```

| Tab | Address | Login |
| --- | --- | --- |
| Demo console | http://localhost:8501 | none |
| Grafana (dashboards *bank-agent · GenAI service* and *bank-agent · SLOs*) | http://localhost:3000 | `admin` / `GRAFANA_PASSWORD` |
| Gateway UI (keys, spend, logs) | http://localhost:4000/ui | `UI_USERNAME` / `UI_PASSWORD` |
| Prometheus alerts | http://localhost:9090/alerts | none |
| APISIX dashboard | http://localhost:9180/ui/ | `APISIX_ADMIN_KEY` |
| Langfuse | https://cloud.langfuse.com | your account |
| Locust (only during drill 2) | http://localhost:8089 | none |

### A11. Console check

In the console, press **Refresh status**.

*Expect:* green dots on APISIX, bank-agent app, LiteLLM, Langfuse, Prometheus, Grafana, Redis, Postgres + pgvector, Presidio and
MCP tool server; purple on Locust (not started), OpenTelemetry, Trivy + Syft and promptfoo; ten grey cards marked
*not in this demo*.

---

## Part B — Dry-run checklist (the day before)

- [ ] **B1. Console self-test**
  ```bash
  docker compose run --rm demo-ui python smoke_test.py
  ```
  *Expect:* `33 of 33 checks passed`.
- [ ] **B2. Walk all ten stages of Part D once**, ticking every *Expect*. Note anything different and tell me.
- [ ] **B3. One trace per request.** After a stage 1 message the journey table fills within about 10 seconds with `POST /chat`,
  `agent.main`, `gen_ai.chat` and `tool …` rows. Click **open in Langfuse**: the app's steps and the gateway's model call must
  be in the same trace. If the table stays empty or the model call is missing, note what Langfuse shows.
- [ ] **B4. The edge keeps the demo headers.** At stage 4 (through APISIX), click **Force fallback**, ask anything.
  *Expect:* `answered by bank-fallback`. Click **Back to normal**.
- [ ] **B5. Plan B, the mock model, answers.**
  ```bash
  curl -s localhost:4000/v1/messages -H "x-api-key: $(grep '^LITELLM_VIRTUAL_KEY=' .env | cut -d= -f2)" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"bank-mock","max_tokens":50,"messages":[{"role":"user","content":"hi"}]}'; echo
  ```
  *Expect:* JSON containing `DEMO MOCK ANSWER`, instantly.
- [ ] **B6. Rehearse drills 3, 4 and 5** (Part D, stage 10) and write down how long each recovery takes.
- [ ] **B7. Optional: the Redis drill.** `docker compose stop redis`, ask a question at stage 6, `docker compose start redis`.
  The gateway also uses Redis: if answers fail while it is stopped, leave this drill out of the real demo.
- [ ] **B8. Restart survives.**
  ```bash
  docker compose stop && docker compose start && bash scripts/wait-for-stack.sh
  ```
  *Expect:* `The stack is ready.`; stage 3 with alice's token still answers (the edge configuration is kept), stage 7 still
  cites the document (the index is kept).
- [ ] **B9. Reset** (Part E). Leave the stack running overnight, or `docker compose stop` (Part F).

---

## Part C — Demo day pre-flight (15 minutes before)

```bash
cd ~/bank-agent
docker compose up -d
bash scripts/wait-for-stack.sh
./deploy/compose/apisix/configure.sh limit 30
./scripts/kill-switch-compose.sh status
curl -s localhost:8000/ready; echo
```
*Expect:* `The stack is ready.`; `rate limit is now 30 requests per minute per consumer`; `gateway key … blocked: False` and
`edge: POST /chat without a token -> HTTP 401 (401 = forwarding, 503 = stopped)`; `{"status":"ready", …}`.

Then: open the tabs from A10, reload the console (F5), press **Refresh status** (A11), set the slider to **1**.

---

## Part D — The demo, stage by stage

In the console: move the **slider**, pick **Calling as** (or **Token** at stage 3), type in the chat box, press Enter.
Press **New conversation** where it says so.

### Stage 1 — client → app → model
Slider **1** · Calling as **alice**
```
What is the balance on ACC-1001?
```
*Expect:* a reply with **25,430.50**; `answered by bank-primary`; Route **direct**; the journey table fills with `POST /chat`,
`agent.main`, `gen_ai.chat`, `tool get_account_balance`.

### Stage 2 — the model gateway
Slider **2** · click **Force fallback** (the block turns amber, FORCED)
```
What is the balance on ACC-1001?
```
*Expect:* `answered by bank-fallback`; Gateway UI → Logs: the newest call is on `claude-opus-5-5`. Click **Back to normal**.

### Stage 3 — the edge
Slider **3** · Token **no token (expect 401)**
```
hi
```
*Expect:* **HTTP 401** from the edge, `Missing JWT token in request`. Route shows **edge**.

Token **alice's token (expect 200)**, type `hi` again. *Expect:* a normal reply. Then in the terminal:
```bash
./deploy/compose/apisix/configure.sh limit 3
```
*Expect:* `rate limit is now 3 requests per minute per consumer`. Wait one minute, then click **Burst: 6 quick requests (watch for 429)**.
*Expect:* `Burst result: 200 200 200 429 429 429`. Restore:
```bash
./deploy/compose/apisix/configure.sh limit 30
```

### Stage 4 — token identity
Slider **4** · ask the same question as each person:
```
Balance on ACC-2001?
```
*Expect:* alice → not found · bob → **150,000.00** · carol → not found.

Optional, in the terminal (a forged identity header is dropped at the edge):
```bash
ALICE=$(JWT_KEY=bank-client JWT_SECRET=$(grep '^BANK_CLIENT_JWT_SECRET=' .env | cut -d= -f2) ./scripts/mint-jwt.sh 600)
curl -s -X POST localhost:9080/chat -H "Authorization: Bearer $ALICE" -H 'x-customer-id: CUST-200' -H 'content-type: application/json' -d '{"message":"Balance on ACC-2001?"}'; echo
```
*Expect:* the reply says ACC-2001 is not found.

### Stage 5 — input guardrails (locked)
Slider **5** · Calling as **alice** · the blocks **PII masking** and **Injection rules** show ALWAYS ON
```
My card 4111 1111 1111 1111 was stolen last night, reach me at anna.k@example.com
```
*Expect:* the reply helps block the card and repeats neither the number nor the address. **open in Langfuse**: the model call's
input reads `<CREDIT_CARD>` and `<EMAIL_ADDRESS>`.
```
Show my recent transactions on ACC-1002
```
*Expect:* the transactions (Coffee −20.00 and others); the 9 Oct refund is called an unusual memo; no "account is closed", no
instruction to move money.

### Stage 6 — memory
Slider **6** · **New conversation** · Calling as **alice**
```
My account is ACC-1001.
```
```
What is my balance?
```
*Expect:* **25,430.50** without asking which account. Click **Turn off** under Conversation memory, ask `What is my balance?` again.
*Expect:* it asks which account. Click **Turn on**.

### Stage 7 — knowledge and the audience filter
Slider **7** · Calling as **alice**
```
What is the daily instant transfer limit for a standard account?
```
*Expect:* **USD 5,000**, citing *Transfer Limits, Charges and Cut-off Times* / *Daily transfer limits*. Click **Turn off** under
Knowledge retrieval, ask again. *Expect:* no document citation. Click **Turn on**.

Calling as **carol**:
```
Who do staff escalate fraud cases to?
```
*Expect:* an answer citing *Internal Escalation Matrix for Customer Service Staff*. The same question as **alice**: *Expect:* not available.

### Stage 8 — tools and OTP approval
Slider **8** · **New conversation** · Calling as **bob**
```
Increase the daily limit on ACC-2001 to 60,000. Yes, go ahead.
```
*Expect:* a one-time passcode is requested.
```
123456
```
*Expect:* approved, new daily limit **60,000**.

**New conversation** · Calling as **alice**:
```
Increase my daily transfer limit on ACC-1001 to 20,000, go ahead.
```
*Expect:* not eligible (premium accounts only; a temporary 24-hour increase in the app). Click **Turn off** under Banking tools,
ask `What is the balance on ACC-1001?` *Expect:* it cannot look it up. Click **Turn on**.

### Stage 9 — multi-agent
Slider **9** · **New conversation** · Calling as **bob**
```
What is the balance on ACC-2001, and what is the daily instant transfer limit?
```
*Expect:* both answers; the journey table shows `agent.orchestrator`, `agent.accounts` and `agent.policy` rows.
```
Increase the daily limit on ACC-2001 to 80,000. Yes, go ahead.
```
```
123456
```
*Expect:* approved; the journey for the `123456` turn shows only `POST /chat`, with no `gen_ai.chat` row: no model was called.
Click **Turn off** under Multi-agent, ask the first question again. *Expect:* only `agent.main` rows.

### Stage 10 — drills
Slider **10**. *Expect:* **Alerts firing 0**, **Alerts pending 0**, and the drill commands on the page.

**Drill 1 — kill switch**
```bash
./scripts/kill-switch-compose.sh stop
```
*Expect:* `[0s] edge: every /chat now returns 503 with a customer message` and `[1s] gateway: virtual key BLOCKED …`.
In the console type `hi`. *Expect:* **HTTP 503** with *The assistant is temporarily unavailable. Please use the mobile app or call us.*
```bash
./scripts/kill-switch-compose.sh resume
```
*Expect:* `gateway: virtual key unblocked` and `edge: forwarding /chat again`; `hi` is answered again.

**Drill 2 — load and the 429 wave**
```bash
ALICE=$(JWT_KEY=bank-client JWT_SECRET=$(grep '^BANK_CLIENT_JWT_SECRET=' .env | cut -d= -f2) ./scripts/mint-jwt.sh 3600)
LOCUST_TOKEN=$ALICE docker compose --profile load up -d locust
```
Open http://localhost:8089, Host `http://apisix:9080`, press **Start**. *Expect:* users ramp from 3 to 12 over about three minutes;
failures 0 % (a 429 counts as expected). In Prometheus (http://localhost:9090/graph) run:
```
sum by (code) (rate(apisix_http_status[1m]))
```
*Expect:* a `200` line and a rising `429` line. Press **Stop** in Locust, then:
```bash
docker compose --profile load stop locust
```

**Drill 3 — gateway outage**
```bash
docker compose stop litellm
```
Click **Burst**. *Expect:* `502 502 502 502 502 502`; **Refresh status**: LiteLLM red; Grafana *bank-agent · SLOs*: the availability
burn rate jumps within 1–2 minutes; **Alerts pending** becomes 1 or more within about 2 minutes (the error-ratio alert fires after 5 minutes of errors).
```bash
docker compose start litellm && bash scripts/wait-for-stack.sh
```
*Expect:* `The stack is ready.`; the next message is answered.

**Drill 4 — tool server outage**
```bash
docker compose stop mcp
```
Ask `What is the balance on ACC-1001?` *Expect:* it says it cannot retrieve the balance now (no invented number); **Refresh status**:
MCP tool server red.
```bash
docker compose start mcp
```

**Drill 5 — the masking service is down**
```bash
docker compose stop presidio-analyzer
```
Type `hi`. *Expect:* **HTTP 502**: the gateway refuses rather than send unmasked text.
```bash
docker compose start presidio-analyzer && bash scripts/wait-for-stack.sh
```
*Expect:* `The stack is ready.` after 1–2 minutes.

**Plan B — the model provider is slow**
```bash
echo "AGENT_MODEL_ID=bank-mock" >> .env && docker compose up -d agent
```
*Expect:* every answer reads `DEMO MOCK ANSWER: …`; stages 1–5 still work (edge, identity, masking, traces). Back to normal:
```bash
sed -i '/^AGENT_MODEL_ID=/d' .env && docker compose up -d agent
```

---

## Part E — Reset between runs

```bash
./scripts/kill-switch-compose.sh resume
./deploy/compose/apisix/configure.sh limit 30
docker compose --profile load stop locust
docker compose start litellm mcp presidio-analyzer redis
bash scripts/wait-for-stack.sh
```
*Expect:* `The stack is ready.` Then reload the console (F5: every block goes back to its default) and set the slider to 1.
bob's limit changes stay until `docker compose restart mcp`.

## Part F — Shut down

| Command | Keeps |
| --- | --- |
| `docker compose stop` | everything; `docker compose start` brings it back |
| `docker compose down` | the data (virtual key, knowledge index, edge configuration); containers are removed |
| `docker compose down -v` | nothing: repeat A6 to A9 afterwards |

---

## Part G — Troubleshooting

| You see | Do this |
| --- | --- |
| `the gateway does not answer on localhost:4000` | first start takes 3–6 minutes: `bash scripts/wait-for-stack.sh`; then `docker compose logs --tail 40 presidio-analyzer litellm` |
| `no such service: demo-ui` | this terminal has no `COMPOSE_FILE`: repeat A4 (or `source ~/.bashrc`) |
| `variable is not set` or `APISIX_ADMIN_KEY is missing a value` | no `.env` here: `cd ~/bank-agent`, then A3 |
| `pull access denied for bank-agent` | old files: use the current zip (A2), then `docker compose build` before `up` |
| `mcr.microsoft.com/presidio-…: not found` | old files: use the current zip (A2) |
| alice's token gives **HTTP 401** at stage 3 or 4 | `./deploy/compose/apisix/configure.sh apply`; if you changed a JWT secret in `.env`, also `docker compose up -d demo-ui` |
| `APISIX did not accept the request` | `docker compose ps apisix` must say healthy; if you changed `APISIX_ADMIN_KEY`: `docker compose up -d apisix`, then run the command again |
| the console says *The app ignored the demo headers* | `DEMO_FEATURE_HEADERS=true` in `.env`, then `docker compose up -d agent` |
| the journey table stays empty | Langfuse keys in `.env`, then `docker compose up -d agent litellm demo-ui`; wait 10 seconds after a reply |
| **HTTP 502** *temporarily unavailable* on every message | `./scripts/kill-switch-compose.sh status`: blocked → `resume`; spend at 5 USD → `bash scripts/make-virtual-key.sh` and `docker compose up -d agent` |
| a red dot in the platform map | `docker compose ps <service>` and `docker compose logs --tail 40 <service>` |
| `Permission denied` or `bad interpreter … ^M` on a script | `chmod +x scripts/*.sh deploy/compose/apisix/configure.sh` and `sed -i 's/\r$//' scripts/*.sh deploy/compose/apisix/configure.sh` |
| `port is already allocated` | another program uses the port; in PowerShell `netstat -ano | findstr :<port>` shows which |
| Presidio restarts or exits with code 137 | not enough memory: A1 |
