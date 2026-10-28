#!/usr/bin/env bash
# step-demo-script: docs/DEMO-SCRIPT.md (set-up, dry run, pre-flight, ten stages, drills, troubleshooting, all with expected output),
#   scripts/wait-for-stack.sh (progress until every service is ready), make-virtual-key.sh that waits for the gateway,
#   configure.sh that stops with a clear message if APISIX refuses, a kill switch whose two levers report their own failure,
#   corrected Redis-drill and passcode-trace wording. Run from the repo root:  bash step-demo-script-files.sh
set -euo pipefail
[ -f docker-compose.yml ] || { echo 'run this from the bank-agent folder'; exit 1; }

cat << 'EOF' > README.md
# bank-agent

A retail-banking customer-service assistant built on Claude, and the platform that runs it. The application is small on
purpose; the repository is mostly about running it safely: gateway, GitOps, canaries, evals, PII masking, identity,
admission policies, secrets, SLOs.

- **Start here:** `docs/track-summary.md` (the system, the control points, the file map).
- **Demo script (Windows laptop, commands and expected output):** `docs/DEMO-SCRIPT.md` (set-up, dry run, pre-flight, the ten stages, drills, troubleshooting).
- **Demo (20 minutes, Docker only, with APISIX):** `docs/DEMO-DOCKER.md` (ten progressive stages, the console contract, drills, fallback plan).
- **Demo console:** `demo-ui/` (Streamlit page as a Compose service: ten stages, feature blocks, platform map, request journey).
- **Docker only (no Kubernetes):** `docs/SETUP-DOCKER-ONLY.md` (the application and every container-level control; Compose plus a Prometheus/Grafana overlay).
- **Fresh machine:** `docs/SETUP-SEQUENCE.md` (Windows 11 + WSL2 + Docker Desktop, all 25 steps in order with commands, expected output and troubleshooting).
- **Runbooks:** `docs/runbook-steps-08-10.md`, `docs/runbook-steps-11-14.md`, `docs/runbook-steps-15-19.md`, `docs/runbook-steps-20-26.md`.
- **Operate:** `docs/slo.md`, `docs/capacity.md`, `docs/dr.md`, `docs/audit-and-retention.md`, `scripts/kill-switch.sh`.
- **Go-live:** `docs/production-readiness-review.md`.

## Run locally

```bash
cp .env.example .env            # fill in the keys
docker compose up -d --build    # agent, tool server, gateway, Presidio, stores, Ollama
curl -s -X POST localhost:8000/chat -H 'content-type: application/json' -d '{"message":"What is the balance on ACC-1001?"}'
pytest -q                       # 49 tests, offline
```

## Deploy

Everything under `deploy/` is reconciled by Argo CD (`deploy/argocd/root.yaml`). CI builds, scans, signs and writes
the image digest into `deploy/chart/bank-agent/values-dev.yaml`; production is a reviewed promotion
(`.github/workflows/promote-prod.yaml`). Platform add-ons installed once by Helm: APISIX, kube-prometheus-stack, KEDA,
Argo CD, Argo Rollouts, Kyverno, External Secrets; see the runbooks for pinned versions.

## Layout

| | |
|---|---|
| `agent.py`, `app.py`, `mcp_server.py` | the agent, its HTTP surface, the tool server |
| `prompts/`, `knowledge/`, `tools/contract.json` | versioned behaviour: prompts, documents, tool contract |
| `evals/` | the eval gate and the red team |
| `deploy/` | charts, Argo CD, edge, identity, policies, secrets, network, monitoring, SLOs |
| `.github/workflows/` | ci · evals · nightly-drift · promote-prod · redteam |
| `docs/` | runbooks and operating documents |
EOF
echo "wrote README.md"

mkdir -p "demo-ui"
cat << 'EOF' > demo-ui/demo_ui.py
"""
bank-agent demo console (Docker stack)  -  one Streamlit page, one linear script, no helper functions.

It runs as a container on the same Docker network as the stack, so it reaches the other containers by name
(agent, apisix, litellm, redis ...). Your browser only talks to this page: http://localhost:8501

Left half : the customer chat, then the request journey pulled from Langfuse after every reply.
Right half: the 10 demo stages, the feature blocks, the platform map with live checks, the dashboards.

Three kinds of stage:
  ROUTE    (1, 3, 4)          change WHERE the request goes and WHO it says it is.
  FEATURE  (2, 5, 6, 7, 8, 9) switch a feature on or off for ONE request with x-feature-<name> headers.
  PLATFORM (10)               nothing a chat message can trigger: live checks, alert count, drill commands.

Blocks you can click (green = on, red = off, grey = not reached yet): force-fallback, memory, rag, tools, multi-agent.
Blocks you cannot click (locked green): PII masking, injection rules, OTP approval. No request can waive them, so this
page sends no header for them at all.
"""

import base64
import hashlib
import hmac
import json
import os
import socket
import time
import uuid
from datetime import datetime

import requests
import streamlit as st

# ----- settings: all come from the container's environment (docker-compose.demo.yml) ------------------------
APP_URL = os.getenv("APP_URL", "http://agent:8000")  # stages 1-2 go straight to the app
EDGE_URL = os.getenv("EDGE_URL", "http://apisix:9080")  # stages 3-10 go through APISIX
LITELLM_URL = os.getenv("LITELLM_URL", "http://litellm:4000")
PROM_URL = os.getenv("PROM_URL", "http://prometheus:9090")
GRAFANA_URL = os.getenv("GRAFANA_URL", "http://grafana:3000")
LANGFUSE_HOST = os.getenv("LANGFUSE_HOST", "https://cloud.langfuse.com").rstrip("/")
LANGFUSE_PK = os.getenv("LANGFUSE_PUBLIC_KEY", "")
LANGFUSE_SK = os.getenv("LANGFUSE_SECRET_KEY", "")
FALLBACK_MODEL_ID = os.getenv("FALLBACK_MODEL_ID", "bank-fallback")

# Links the BROWSER follows (the names above only work inside Docker, so these are localhost)
LINK_GRAFANA = os.getenv("LINK_GRAFANA", "http://localhost:3000")
LINK_LITELLM = os.getenv("LINK_LITELLM", "http://localhost:4000/ui")
LINK_PROM = os.getenv("LINK_PROM", "http://localhost:9090/alerts")
LINK_APISIX = os.getenv("LINK_APISIX", "http://localhost:9180/ui/")
LINK_LOCUST = os.getenv("LINK_LOCUST", "http://localhost:8089")

# The three people of the demo. Stages 1-2: the app trusts the x-customer-id header (dev only, on purpose).
# Stages 3+: each person is an APISIX consumer; this page mints a short-lived token with that consumer's secret.
PERSONAS = {
    "alice": {
        "label": "alice · standard customer",
        "customer": "CUST-100",
        "jwt_key": "bank-client",
        "secret_env": "BANK_CLIENT_JWT_SECRET",
    },
    "bob": {
        "label": "bob · premium customer",
        "customer": "CUST-200",
        "jwt_key": "mobile-app",
        "secret_env": "MOBILE_APP_JWT_SECRET",
    },
    "carol": {
        "label": "carol · staff",
        "customer": "STAFF-001",
        "jwt_key": "staff-portal",
        "secret_env": "STAFF_PORTAL_JWT_SECRET",
    },
}

st.set_page_config(page_title="bank-agent demo console", layout="wide", page_icon="🏦")

# ----- a little CSS so blocks and cards look like a console, not a form -----------------------------------------
st.markdown(
    """
<style>
.block-container {padding-top: 1.2rem;}
.card {border-radius: 10px; padding: 10px 12px; margin-bottom: 6px; border: 1px solid #2A2E3D; background: #1A1D27;}
.card h4 {margin: 0 0 2px 0; font-size: 14px;}
.card p  {margin: 0; font-size: 12px; color: #A7ACBE;}
.on    {border-left: 6px solid #22C55E; background: #122016;}
.off   {border-left: 6px solid #EF4444; background: #231416;}
.warn  {border-left: 6px solid #F59E0B; background: #241C0E;}
.lock  {border-left: 6px solid #4B5063; opacity: 0.55;}
.nodemo {border: 1px dashed #4B5063; opacity: 0.5;}
.pill {display:inline-block; font-size:11px; padding:1px 8px; border-radius:999px; margin-left:6px; font-weight:600;}
.pill.on   {background:#22C55E; color:#04130A;}
.pill.off  {background:#EF4444; color:#fff;}
.pill.warn {background:#F59E0B; color:#1F1300;}
.pill.lock {background:#4B5063; color:#E6E8EF;}
.dot {display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:6px; vertical-align:middle;}
.stage {border-radius: 10px; padding: 12px 14px; border: 1px solid #3B2F80; background: #171433; margin-bottom: 8px;}
.stage h4 {margin:0 0 4px 0; font-size: 15px; color:#C9BFFF;}
.stage p, .stage li {font-size: 13px; color:#CFD3E0; margin: 2px 0;}
.hdr {font-size: 11px; letter-spacing: .12em; text-transform: uppercase; color: #8A90A8; margin: 14px 0 6px 0;}
</style>
""",
    unsafe_allow_html=True,
)

# ----- things that must survive Streamlit re-runs (the script runs top to bottom on every click) ---------------
if "messages" not in st.session_state:
    st.session_state.messages = []
if "session_id" not in st.session_state:
    st.session_state.session_id = "demo-" + uuid.uuid4().hex[:8]
if "last_headers" not in st.session_state:
    st.session_state.last_headers = {}
if "total_cost" not in st.session_state:
    st.session_state.total_cost = 0.0
if "journey" not in st.session_state:
    st.session_state.journey = None  # the last request's trace, fetched once right after the reply
if "overrides" not in st.session_state:
    st.session_state.overrides = {}  # feature name -> True/False when the presenter clicked a block
if "health" not in st.session_state:
    st.session_state.health = {}  # component -> (colour, detail) from the last "Refresh status"
if "burst" not in st.session_state:
    st.session_state.burst = []

# ----- the 10 stages: number, title, kind, what to say, what to try -----------------------------------------------
STAGES = [
    (
        1,
        "Client → Python app → model",
        "route",
        "A small FastAPI app and one model call, with nothing in front of it. Who is calling is a header the app trusts. That is on purpose, and it is why stage 3 exists.",
        "What is the balance on ACC-1001?",
    ),
    (
        2,
        "+ Model gateway (LiteLLM)",
        "feature",
        "The app never holds the provider key: the gateway chooses the model, caps the budget and records every call. Turn Force fallback on: the answering model changes, and the gateway UI shows the call on the other model.",
        "What is the balance on ACC-1001?   (ask once normally, once with Force fallback on)",
    ),
    (
        3,
        "+ Edge gateway (APISIX)",
        "route",
        "Requests now enter through APISIX. Pick 'no token': 401. Pick alice's token: 200. Run `./deploy/compose/apisix/configure.sh limit 3` in a terminal, then press Burst: the 4th request is a 429.",
        "hi",
    ),
    (
        4,
        "+ Token identity (APISIX JWT consumers)",
        "route",
        "Who is calling is a verified token, not a sentence. Same agent, same prompt, three people. A forged x-customer-id header is stripped at the edge.",
        "Balance on ACC-2001?   (alice → not found · bob → 150,000.00 · carol → not found)",
    ),
    (
        5,
        "+ Input guardrails (PII masking, injection rules)",
        "feature",
        "The gateway masks the card number before the model sees it, and text inside data is treated as data. Both blocks are locked on: no request can waive them. Open the trace: the input shows <CREDIT_CARD>.",
        "My card 4111 1111 1111 1111 was stolen, reach me at anna.k@example.com   ·   then: Show my recent transactions on ACC-1002",
    ),
    (
        6,
        "+ Conversation memory (Redis)",
        "feature",
        "Follow-up questions work because the session is in Redis with a time limit. Switch Memory off and ask the follow-up again.",
        "My account is ACC-1001.   then:   What is my balance?",
    ),
    (
        7,
        "+ Enterprise knowledge (RAG, audience filter)",
        "feature",
        "Policy answers come from pgvector with citations; staff documents are filtered in SQL, not in the prompt. Compare carol with alice. Switch Knowledge off to see an answer with no grounding.",
        "What is the daily instant transfer limit for a standard account?   ·   Who do staff escalate fraud cases to?",
    ),
    (
        8,
        "+ Tools via MCP + OTP approval",
        "feature",
        "The rules live in the tool server, where a prompt cannot reach them. As bob, raise a limit: a passcode is requested, then approved. As alice: refused. Keep Memory on: in single-agent mode the conversation carries the challenge.",
        "As bob: Increase the daily limit on ACC-2001 to 60,000, go ahead   then:   123456",
    ),
    (
        9,
        "+ Multi-agent orchestration",
        "feature",
        "A front desk and two specialists, each with its own prompt and tools. In the trace you see the orchestrator, accounts and policy agents, and the passcode reply with no model call at all.",
        "As bob: Balance on ACC-2001 and the daily instant transfer limit?",
    ),
    (
        10,
        "Platform: observe, load, stop, fail",
        "platform",
        "Nothing here is triggered by chat. Use the live map, the alert count and the drill commands next to a terminal.",
        "—",
    ),
]

# ----- the clickable blocks: header name, label, description, stage where the block appears, stage from which it is on ----
# tools is on from stage 1 (the Step 1 agent already had a balance tool); its block appears at stage 8 for the OTP story.
FEATURES = [
    ("force-fallback", "Force fallback model", "Ask the gateway for the fallback alias (Opus) for this request", 2, 2),
    ("memory", "Conversation memory", "Redis session with a time limit", 6, 6),
    ("rag", "Knowledge retrieval", "pgvector, audience filter in SQL", 7, 7),
    ("tools", "Banking tools (MCP server)", "Ownership, roles and an audit line per call", 8, 1),
    ("multi-agent", "Multi-agent", "Orchestrator and two specialists", 9, 9),
]
# ----- the locked blocks: no header, no button ---------------------------------------------------------------------
LOCKED = [
    ("PII masking", "Gateway guardrail on every model call", 5),
    ("Injection rules", "Prompt rules 6 and 9, plus the eval gate", 5),
    ("OTP approval", "Enforced by the tool server", 8),
]

left, right = st.columns([1, 1.05], gap="large")

# =============================================================================================================
# RIGHT HALF  -  stages, blocks, platform map
# =============================================================================================================
with right:
    st.markdown('<div class="hdr">Demo stage · progressive build-up</div>', unsafe_allow_html=True)
    stage_no = st.select_slider("Stage", options=[s[0] for s in STAGES], value=1, label_visibility="collapsed")
    s_no, s_title, s_kind, s_say, s_try = STAGES[stage_no - 1]
    st.markdown(
        f'<div class="stage"><h4>Stage {s_no} · {s_title} <span class="pill lock">{s_kind}</span></h4>'
        f"<p>{s_say}</p><p><b>Try:</b> <code>{s_try}</code></p></div>",
        unsafe_allow_html=True,
    )

    # Where the request goes, and which credential it carries, follows from the stage.
    use_edge = stage_no >= 3
    credential = "none"  # none | alice | bob | carol
    if stage_no == 3:
        pick = st.selectbox("Token", ["no token (expect 401)", "alice's token (expect 200)"], key="token3")
        credential = "alice" if pick.startswith("alice") else "none"
    else:
        who = st.selectbox("Calling as", [p["label"] for p in PERSONAS.values()], key="persona")
        credential = [k for k, p in PERSONAS.items() if p["label"] == who][0]
    if stage_no < 3:
        st.caption(
            "Stages 1-2: identity is the trusted header x-customer-id (dev only). From stage 3 it is a verified token."
        )

    # ----- clickable feature blocks ----------------------------------------------------------------------------
    st.markdown('<div class="hdr">Features in this request · click a block to flip it</div>', unsafe_allow_html=True)
    flags = {}
    cols = st.columns(2)
    for i, (name, label, desc, block_stage, on_from) in enumerate(FEATURES):
        visible = stage_no >= block_stage
        if name == "force-fallback":
            state = st.session_state.overrides.get(name, False) if visible else False  # on = force the fallback
            css = "lock" if not visible else ("warn" if state else "on")
            word = f"from stage {block_stage}" if not visible else ("FORCED" if state else "NORMAL")
        else:
            default = stage_no >= on_from  # progressive: on once its stage is reached
            state = st.session_state.overrides.get(name, default) if visible else default
            css = "lock" if not visible else ("on" if state else "off")
            word = (
                (f"from stage {block_stage}" if on_from > 1 else "ON · basic")
                if not visible
                else ("ON" if state else "OFF")
            )
        flags[name] = state
        with cols[i % 2]:
            st.markdown(
                f'<div class="card {css}"><h4>{label}<span class="pill {css}">{word}</span></h4><p>{desc}</p></div>',
                unsafe_allow_html=True,
            )
            if visible:
                if name == "force-fallback":
                    button_text = "Back to normal" if state else "Force fallback"
                else:
                    button_text = "Turn off" if state else "Turn on"
                if st.button(button_text, key="btn-" + name, width="stretch"):
                    st.session_state.overrides[name] = not state
                    st.rerun()
    # locked blocks: always green once their stage is reached, never a button, never a header
    lcols = st.columns(3)
    for i, (label, desc, block_stage) in enumerate(LOCKED):
        reached = stage_no >= block_stage
        css = "on" if reached else "lock"
        word = "ALWAYS ON" if reached else f"from stage {block_stage}"
        with lcols[i]:
            st.markdown(
                f'<div class="card {css}"><h4>🔒 {label}<span class="pill {css}">{word}</span></h4><p>{desc}</p></div>',
                unsafe_allow_html=True,
            )

    # ----- platform map: 24 components. Live check where the container can be reached, grey where it is not in this demo ----
    st.markdown('<div class="hdr">Platform map · the 24 components of the 25 steps</div>', unsafe_allow_html=True)
    # (component, layer, kind, target, note)   kind: http | tcp | optional | inside | ondemand | nodemo
    CHECKS = [
        ("APISIX edge gateway", "edge", "http", "http://apisix:7085/status/ready", ""),
        ("Keycloak (OIDC)", "edge", "nodemo", "", "stage 4 uses APISIX JWT consumers"),
        ("bank-agent app (FastAPI)", "app", "http", APP_URL + "/ready", ""),
        ("LiteLLM model gateway", "app", "http", LITELLM_URL + "/health/liveliness", ""),
        ("Langfuse (traces)", "observe", "http", LANGFUSE_HOST + "/api/public/health", ""),
        ("Prometheus", "observe", "http", PROM_URL + "/-/ready", ""),
        ("Grafana", "observe", "http", GRAFANA_URL + "/api/health", ""),
        ("Argo CD", "deliver", "nodemo", "", "Kubernetes only"),
        ("Redis (memory)", "state", "tcp", "redis:6379", ""),
        ("Postgres + pgvector (RAG)", "state", "tcp", "knowledge-db:5432", ""),
        ("Presidio (PII)", "guard", "http", "http://presidio-analyzer:3000/health", ""),
        ("MCP tool server", "tools", "http", "http://mcp:8100/health", ""),
        ("KEDA autoscaling", "scale", "nodemo", "", "Kubernetes only"),
        (
            "Locust load tests",
            "scale",
            "optional",
            "http://locust:8089/",
            "start: docker compose --profile load up -d locust",
        ),
        ("OpenTelemetry SDK", "observe", "inside", "", "inside the app"),
        ("Argo Rollouts (canary)", "deliver", "nodemo", "", "Kubernetes only"),
        ("GitHub Actions CI", "deliver", "nodemo", "", "CI platform"),
        ("Trivy + Syft (scan, SBOM)", "deliver", "ondemand", "", "docker run, on demand"),
        ("Cosign (signing)", "deliver", "nodemo", "", "CI and registry"),
        ("promptfoo (eval gate, red team)", "deliver", "ondemand", "", "docker run, on demand"),
        ("Kyverno policies", "govern", "nodemo", "", "Kubernetes only"),
        ("Vault + External Secrets", "govern", "nodemo", "", "Kubernetes only"),
        ("Cilium NetworkPolicies", "govern", "nodemo", "", "Kubernetes only"),
        ("Helm chart", "deliver", "nodemo", "", "Kubernetes only"),
    ]
    if st.button("Refresh status", width="stretch") or not st.session_state.health:
        for comp, _layer, kind, target, note in CHECKS:
            if kind == "http" or kind == "optional":
                try:
                    code = requests.get(target, timeout=3).status_code
                    st.session_state.health[comp] = ("#22C55E" if code < 500 else "#EF4444", f"HTTP {code}")
                except requests.RequestException as e:
                    if kind == "optional":
                        st.session_state.health[comp] = ("#7C5CFF", note)
                    else:
                        st.session_state.health[comp] = ("#EF4444", type(e).__name__)
            elif kind == "tcp":
                host, port = target.split(":")
                try:
                    socket.create_connection((host, int(port)), timeout=3).close()
                    st.session_state.health[comp] = ("#22C55E", f"port {port} open")
                except OSError as e:
                    st.session_state.health[comp] = ("#EF4444", type(e).__name__)
    mcols = st.columns(3)
    for i, (comp, layer, kind, _target, note) in enumerate(CHECKS):
        css = ""
        if kind in ("http", "tcp", "optional"):
            colour, detail = st.session_state.health.get(comp, ("#4B5063", "not checked"))
        elif kind == "nodemo":
            colour, detail, css = "#4B5063", f"not in this demo · {note}", "nodemo"
        else:
            colour, detail = "#7C5CFF", note
        with mcols[i % 3]:
            st.markdown(
                f'<div class="card {css}"><h4><span class="dot" style="background:{colour}"></span>{comp}</h4><p>{layer} · {detail}</p></div>',
                unsafe_allow_html=True,
            )

    # ----- stage 10: Docker drills and the live alert count -------------------------------------------------------
    if stage_no == 10:
        st.markdown(
            '<div class="hdr">Stage 10 drills · run in a terminal next to this page</div>', unsafe_allow_html=True
        )
        st.code(
            """./scripts/kill-switch-compose.sh status
./scripts/kill-switch-compose.sh stop        # edge answers 503 with a message, the gateway key is blocked
./scripts/kill-switch-compose.sh resume

LOCUST_TOKEN=<a token> docker compose --profile load up -d locust     # then open the Locust page (link below)

docker compose stop litellm                  # outage: chat returns 502; error ratio and burn rate move at once
docker compose start litellm                 # recovery; the alert itself needs 5 minutes of errors to fire
docker compose stop mcp                      # /ready 503, chat fails closed, no wrong answers
# Redis is shared by memory AND the gateway: rehearse 'docker compose stop redis' in the dry run before showing it
docker compose stop presidio-analyzer        # the gateway refuses rather than pass unmasked text""",
            language="bash",
        )
        try:  # firing alerts, live from Prometheus
            alerts = requests.get(PROM_URL + "/api/v1/alerts", timeout=3).json()["data"]["alerts"]
            firing = [a["labels"]["alertname"] for a in alerts if a["state"] == "firing"]
            pending = [a["labels"]["alertname"] for a in alerts if a["state"] == "pending"]
            c1, c2 = st.columns(2)
            c1.metric("Alerts firing", len(firing), help=", ".join(firing) or "none")
            c2.metric("Alerts pending", len(pending), help=", ".join(pending) or "none")
        except (requests.RequestException, KeyError, ValueError):
            st.caption("Prometheus is not reachable for the alert count (start the observability overlay).")

    st.markdown('<div class="hdr">Dashboards</div>', unsafe_allow_html=True)
    st.markdown(
        f"[Langfuse]({LANGFUSE_HOST}) · [Grafana]({LINK_GRAFANA}) · [LiteLLM spend]({LINK_LITELLM}) · "
        f"[Prometheus alerts]({LINK_PROM}) · [APISIX dashboard]({LINK_APISIX}) · [Locust]({LINK_LOCUST})"
    )

# =============================================================================================================
# LEFT HALF  -  the chat and the journey
# =============================================================================================================
with left:
    c1, c2, c3 = st.columns(3)
    c1.metric("Stage", f"{stage_no} / 10")
    c2.metric("Spend this session", f"${st.session_state.total_cost:.4f}")
    c3.metric("Route", "edge" if use_edge else "direct")
    if st.button("New conversation", width="stretch"):
        st.session_state.messages = []
        st.session_state.session_id = "demo-" + uuid.uuid4().hex[:8]
        st.session_state.total_cost = 0.0
        st.session_state.journey = None
        st.session_state.burst = []
        st.rerun()

    chat_url = (EDGE_URL if use_edge else APP_URL) + "/chat"
    st.caption(f"session `{st.session_state.session_id}` · as `{credential}` · → `{chat_url}`")

    # The headers every request of this page carries: feature switches, and the credential.
    # Only the five switchable names are ever sent. Nothing for PII masking, injection rules or OTP approval.
    base_headers = {"content-type": "application/json"}
    for name, on in flags.items():
        base_headers["x-feature-" + name] = "on" if on else "off"
    if credential != "none":
        persona = PERSONAS[credential]
        if stage_no < 3:
            base_headers["x-customer-id"] = persona["customer"]  # stages 1-2: the trusted header
        else:
            # Mint a short-lived HS256 token the way APISIX's jwt-auth expects: header.payload.signature, payload has the
            # consumer's key and an expiry. The secret is the consumer's secret from .env.
            secret = os.getenv(persona["secret_env"], "")
            head = base64.urlsafe_b64encode(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()).rstrip(b"=")
            body = base64.urlsafe_b64encode(
                json.dumps({"key": persona["jwt_key"], "exp": int(time.time()) + 300}).encode()
            ).rstrip(b"=")
            sig = base64.urlsafe_b64encode(
                hmac.new(secret.encode(), head + b"." + body, hashlib.sha256).digest()
            ).rstrip(b"=")
            base_headers["Authorization"] = "Bearer " + (head + b"." + body + b"." + sig).decode()
            if not secret:
                st.warning(f"{persona['secret_env']} is empty: set it in .env and recreate this container.")

    for m in st.session_state.messages:
        with st.chat_message(m["role"]):
            st.markdown(m["content"])

    # ----- edge rate limit: a burst of cheap requests, stages 3+ -------------------------------------------------------
    if use_edge:
        if st.button("Burst: 6 quick requests (watch for 429)", width="stretch"):
            codes = []
            for _ in range(6):
                try:
                    rb = requests.post(
                        chat_url,
                        json={"message": "hi", "session_id": st.session_state.session_id},
                        headers={**base_headers, "x-request-id": str(uuid.uuid4())},
                        timeout=90,
                    )
                    codes.append(rb.status_code)
                except requests.RequestException:
                    codes.append("error")
            st.session_state.burst = codes
        if st.session_state.burst:
            st.caption(
                "Burst result: "
                + "  ".join(str(c) for c in st.session_state.burst)
                + "   (200 = answered, 429 = edge limit, 401 = no token)"
            )

    prompt = st.chat_input("Ask the bank…")
    if prompt:
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)

        request_id = str(uuid.uuid4())
        headers = {**base_headers, "x-request-id": request_id}
        payload = {"message": prompt, "session_id": st.session_state.session_id}
        trace_id = ""
        with st.chat_message("assistant"):
            with st.spinner(f"→ {chat_url}"):
                try:
                    r = requests.post(chat_url, json=payload, headers=headers, timeout=90)
                    if r.status_code == 200:
                        answer = r.json()
                        reply = answer.get("reply", "")
                        if answer.get("model"):
                            reply += f"\n\n`answered by {answer['model']}`"
                        # Did the app honour the demo headers? Forcing the fallback must change the answering model.
                        if flags.get("force-fallback") and answer.get("model") != FALLBACK_MODEL_ID:
                            reply += "\n\n⚠️ The app ignored the demo headers: set DEMO_FEATURE_HEADERS=true in .env and recreate the agent."
                    else:
                        reply = f"**HTTP {r.status_code}** from the {'edge' if use_edge else 'app'}\n\n```\n{r.text[:400]}\n```"
                    st.session_state.last_headers = dict(r.headers)
                    trace_id = r.headers.get("x-trace-id", "")
                except requests.RequestException as e:
                    reply = f"**Connection failed:** `{e}`"
            st.markdown(reply)
        st.session_state.messages.append({"role": "assistant", "content": reply})

        # ----- fetch the journey ONCE, right after the reply (never on a later re-run, or the cost would count twice) ---
        st.session_state.journey = None
        if trace_id and LANGFUSE_PK and LANGFUSE_SK:
            with st.spinner("Waiting for Langfuse (traces are exported in batches) …"):
                for _ in range(5):
                    try:
                        t = requests.get(
                            f"{LANGFUSE_HOST}/api/public/traces/{trace_id}", auth=(LANGFUSE_PK, LANGFUSE_SK), timeout=15
                        )
                    except requests.RequestException:
                        break
                    if t.status_code == 200 and t.json().get("observations"):
                        trace = t.json()
                        rows = []
                        for o in sorted(trace["observations"], key=lambda x: x.get("startTime", "")):
                            ms = ""
                            if o.get("startTime") and o.get("endTime"):
                                a = datetime.fromisoformat(o["startTime"].replace("Z", "+00:00"))
                                b = datetime.fromisoformat(o["endTime"].replace("Z", "+00:00"))
                                ms = int((b - a).total_seconds() * 1000)
                            u = o.get("usageDetails") or o.get("usage") or {}
                            tokens = u.get("total") or ((u.get("input") or 0) + (u.get("output") or 0))
                            rows.append(
                                {
                                    "step": o.get("name", ""),
                                    "type": o.get("type", ""),
                                    "model": o.get("model") or "",
                                    "tokens": tokens,
                                    "ms": ms,
                                }
                            )
                        cost = float(trace.get("totalCost") or 0.0)
                        st.session_state.total_cost += cost
                        st.session_state.journey = {"trace_id": trace_id, "cost": cost, "rows": rows}
                        break
                    time.sleep(2)
        st.rerun()  # redraw once so the spend metric and the journey table show the new numbers

    # ----- journey ------------------------------------------------------------------------------------------------
    st.markdown('<div class="hdr">Request journey · from Langfuse</div>', unsafe_allow_html=True)
    with st.expander("Headers this page sends / headers that came back"):
        st.json(
            {
                "sent (feature switches only)": {k: v for k, v in base_headers.items() if k.startswith("x-feature-")},
                "received": st.session_state.last_headers,
            }
        )
    if st.session_state.journey:
        j = st.session_state.journey
        st.caption(f"trace `{j['trace_id']}` · ${j['cost']:.5f}")
        st.dataframe(j["rows"], width="stretch", hide_index=True)
        st.markdown(f"[open in Langfuse]({LANGFUSE_HOST}/trace/{j['trace_id']})")
    elif not (LANGFUSE_PK and LANGFUSE_SK):
        st.info(
            "Set LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY in .env (then recreate this container) to see the journey here."
        )
    else:
        st.caption("Send a message: the trace of that request appears here, a few seconds after the reply.")
EOF
echo "wrote demo-ui/demo_ui.py"

mkdir -p "deploy/compose/apisix"
cat << 'EOF' > deploy/compose/apisix/configure.sh
#!/usr/bin/env bash
# deploy/compose/apisix/configure.sh — the edge configuration as code, applied through the Admin API.
#   ./deploy/compose/apisix/configure.sh apply     upstream, route /chat, three JWT consumers, Prometheus plugin (idempotent)
#   ./deploy/compose/apisix/configure.sh limit 3   change the per-consumer rate limit live (shows the 429 in three calls)
#   ./deploy/compose/apisix/configure.sh stop      edge kill switch: every /chat gets a 503 with a customer message
#   ./deploy/compose/apisix/configure.sh resume    remove the 503 (re-applies the route)
# Secrets come from .env: APISIX_ADMIN_KEY, BANK_CLIENT_JWT_SECRET, MOBILE_APP_JWT_SECRET, STAFF_PORTAL_JWT_SECRET.
set -euo pipefail
set -a; source .env; set +a
# every call below uses curl -f: if APISIX refuses (wrong APISIX_ADMIN_KEY, not started yet) the script stops and says so
ADMIN="${ADMIN:-http://localhost:9180/apisix/admin}"
H=(-H "X-API-KEY: $APISIX_ADMIN_KEY" -H "content-type: application/json")
ACTION="${1:-apply}"
LIMIT="${EDGE_RATE_LIMIT:-10}"

# pre-check: is APISIX up, and does it accept our admin key? Stop here with a clear message if not.
if ! curl -sf -o /dev/null "$ADMIN/routes" -H "X-API-KEY: $APISIX_ADMIN_KEY"; then
  echo "APISIX did not accept the request. Check: docker compose ps apisix (healthy?) and APISIX_ADMIN_KEY in .env"
  echo "(if you changed APISIX_ADMIN_KEY after APISIX started: docker compose up -d apisix, then run this again)"
  exit 1
fi

if [ "$ACTION" = "apply" ] || [ "$ACTION" = "resume" ]; then
  # 1. upstream: the agent container (Compose DNS). Timeouts match the model's latency, not a web page's.
  curl -sSf -X PUT "$ADMIN/upstreams/bank-agent" "${H[@]}" -d '{
    "type": "roundrobin",
    "nodes": {"agent:8000": 1},
    "timeout": {"connect": 5, "send": 60, "read": 180}
  }' > /dev/null && echo "upstream bank-agent -> agent:8000"

  # 2. consumers: one per channel. APISIX consumer names allow letters, digits and underscores only; identity.py maps them.
  curl -sSf -X PUT "$ADMIN/consumers/bank_client" "${H[@]}" -d "{
    \"username\": \"bank_client\",
    \"plugins\": {\"jwt-auth\": {\"key\": \"bank-client\", \"secret\": \"$BANK_CLIENT_JWT_SECRET\", \"algorithm\": \"HS256\"}}
  }" > /dev/null && echo "consumer bank_client (jwt key bank-client) -> CUST-100 standard"
  curl -sSf -X PUT "$ADMIN/consumers/mobile_app" "${H[@]}" -d "{
    \"username\": \"mobile_app\",
    \"plugins\": {\"jwt-auth\": {\"key\": \"mobile-app\", \"secret\": \"$MOBILE_APP_JWT_SECRET\", \"algorithm\": \"HS256\"}}
  }" > /dev/null && echo "consumer mobile_app (jwt key mobile-app) -> CUST-200 premium"

  curl -sSf -X PUT "$ADMIN/consumers/staff_portal" "${H[@]}" -d "{
    \"username\": \"staff_portal\",
    \"plugins\": {\"jwt-auth\": {\"key\": \"staff-portal\", \"secret\": \"$STAFF_PORTAL_JWT_SECRET\", \"algorithm\": \"HS256\"}}
  }" > /dev/null && echo "consumer staff_portal (jwt key staff-portal) -> STAFF-001 staff"

  # 3. the route: POST /chat only; no valid token, no request; 10 requests per minute per consumer; a request id minted
  #    at the edge and echoed back; identity headers a client might try to inject are removed before the agent sees them.
  curl -sSf -X PUT "$ADMIN/routes/chat" "${H[@]}" -d '{
    "name": "bank-agent-chat",
    "uri": "/chat",
    "methods": ["POST"],
    "upstream_id": "bank-agent",
    "plugins": {
      "jwt-auth": {},
      "limit-count": {"count": '"$LIMIT"', "time_window": 60, "key_type": "var", "key": "consumer_name", "rejected_code": 429, "policy": "local", "show_limit_quota_header": true},
      "request-id": {"header_name": "X-Request-Id", "include_in_response": true},
      "proxy-rewrite": {"headers": {"remove": ["X-Customer-Id", "X-Actor-Role"]}}
    }
  }' > /dev/null && echo "route /chat: jwt-auth, limit-count ${LIMIT}/min per consumer, request-id, header hygiene"

  # 4. metrics for every route (the observability overlay scrapes apisix:9091)
  curl -sSf -X PUT "$ADMIN/global_rules/1" "${H[@]}" -d '{"plugins": {"prometheus": {"prefer_name": true}}}' > /dev/null && echo "prometheus plugin enabled globally"
  [ "$ACTION" = "resume" ] && echo "RESUMED: the edge forwards /chat again"
  exit 0
fi

if [ "$ACTION" = "limit" ]; then
  # change only the rate limit, live, without touching anything else on the route
  N="${2:?usage: $0 limit <requests-per-minute>}"
  curl -sSf -X PATCH "$ADMIN/routes/chat" "${H[@]}" -d "{\"plugins\": {\"limit-count\": {\"count\": $N, \"time_window\": 60, \"key_type\": \"var\", \"key\": \"consumer_name\", \"rejected_code\": 429, \"policy\": \"local\", \"show_limit_quota_header\": true}}}" > /dev/null && echo "rate limit is now $N requests per minute per consumer"
  exit 0
fi

if [ "$ACTION" = "stop" ]; then
  # the edge kill switch: the route answers 503 with a message; the agent and the gateway are untouched
  curl -sSf -X PATCH "$ADMIN/routes/chat" "${H[@]}" -d '{
    "plugins": {"fault-injection": {"abort": {"http_status": 503, "body": "{\"error\":\"The assistant is temporarily unavailable. Please use the mobile app or call us.\"}"}}}
  }' > /dev/null && echo "STOPPED at the edge: every /chat returns 503 with a customer message. Resume: $0 resume"
  exit 0
fi
echo "usage: $0 apply | limit <n> | stop | resume"; exit 2
EOF
echo "wrote deploy/compose/apisix/configure.sh"

mkdir -p "docs"
cat << 'EOF' > docs/DEMO-DOCKER.md
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

> **Presenting on a Windows laptop?** `docs/DEMO-SCRIPT.md` is the step-by-step version of this document: every command in order,
> with what you should see. This document explains the why.

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
Warnings such as `The "ANTHROPIC_API_KEY" variable is not set`, or `required variable APISIX_ADMIN_KEY is missing a value`, mean
there is no `.env` file yet. Create it with `bash scripts/make-env.sh` (nothing needs to be running: see section 1).

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
cd bank-agent
bash scripts/make-env.sh        # invents every password and secret, sets DEMO_FEATURE_HEADERS=true and EDGE_RATE_LIMIT=30
nano .env                       # paste ANTHROPIC_API_KEY (and the two LANGFUSE keys for the journey table)
export COMPOSE_FILE=docker-compose.yml:docker-compose.observability.yml:docker-compose.apisix.yml:docker-compose.demo.yml:docker-compose.locust.yml
docker compose build && docker compose up -d      # includes the demo console
```

Then, in order: create the gateway virtual key with `bash scripts/make-virtual-key.sh` and `docker compose up -d agent` →
run the ingest (`docs/SETUP-DOCKER-ONLY.md` Phase 6) → configure the edge:

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
| 9 | + multi-agent | a mixed question: "Balance on ACC-2001 and the daily instant transfer limit?" with `x-feature-multi-agent: on` then `off`; then bob's limit request and the code | "A front desk and two specialists, each with its own prompt and tools, on the same loop." | Langfuse tree: orchestrator → accounts → policy; six model calls tagged by agent; the passcode reply makes **no model call**: its trace has only the `POST /chat` step |
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
| `redis` | memory is lost, and the gateway also uses Redis, so its behaviour depends on the gateway version | rehearse it in the dry run first; leave it out of the live demo if the gateway errors |
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
EOF
echo "wrote docs/DEMO-DOCKER.md"

mkdir -p "docs"
cat << 'EOF' > docs/DEMO-SCRIPT.md
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
EOF
echo "wrote docs/DEMO-SCRIPT.md"

mkdir -p "docs"
cat << 'EOF' > docs/SETUP-DOCKER-ONLY.md
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
docker compose pull --ignore-buildable   # once, ~5 GB: Presidio analyzer (2 GB), Ollama, LiteLLM, Postgres, pgvector, Redis
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

*Troubleshooting:* `pull access denied for bank-agent` → that image is built on your machine, never downloaded: run
`docker compose build` before `up`, and pull only the public images with `docker compose pull --ignore-buildable`. `litellm` unhealthy → `docker compose logs litellm`; a weak master key is refused. `presidio-analyzer`
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
stopped the agent itself carries on without memory (log `memory unavailable`); the gateway also uses Redis, so if
replies fail while Redis is down, that is the gateway, not the agent.

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
confirmed with **no model call** (its trace has only the `POST /chat` step) and the key is gone. A wrong code (`000000`) keeps the pause;
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
(memory is lost; the gateway also uses Redis, so rehearse this one before relying on it); `docker compose stop knowledge-db` (policy questions "not available", nothing invented);
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
EOF
echo "wrote docs/SETUP-DOCKER-ONLY.md"

mkdir -p "scripts"
cat << 'EOF' > scripts/kill-switch-compose.sh
#!/usr/bin/env bash
# scripts/kill-switch-compose.sh — the kill switch for the Docker stack. Two levers, each works without the other:
#   1. the edge:    APISIX answers every /chat with a 503 and a customer message         (skipped if APISIX is not running)
#   2. the gateway: the agent's virtual key is blocked, so every model call fails closed
#   ./scripts/kill-switch-compose.sh stop     both levers, edge first (customers see a message, not a hang)
#   ./scripts/kill-switch-compose.sh resume   gateway key first, then the edge
#   ./scripts/kill-switch-compose.sh status
set -euo pipefail
set -a; source .env; set +a                       # LITELLM_MASTER_KEY, LITELLM_VIRTUAL_KEY, APISIX_ADMIN_KEY come from .env
ACTION="${1:-status}"
GATEWAY="${GATEWAY:-http://localhost:4000}"
EDGE="deploy/compose/apisix/configure.sh"
T0=$(date +%s); mark() { echo "[$(( $(date +%s) - T0 ))s] $*"; }
edge_up() { curl -sf -o /dev/null "http://localhost:7085/status/ready"; }

if [ "$ACTION" = "stop" ]; then
  if edge_up; then
    if "$EDGE" stop | sed 's/^/        /'; then mark "edge: every /chat now returns 503 with a customer message"; else mark "edge: FAILED (continuing with the gateway lever)"; fi
  else mark "edge: APISIX not running, skipped"; fi
  if curl -sSf -X POST "$GATEWAY/key/block" -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'content-type: application/json' -d "{\"key\": \"$LITELLM_VIRTUAL_KEY\"}" > /dev/null; then
    mark "gateway: virtual key BLOCKED, every model call from the agent fails closed"
  else mark "gateway: FAILED to block the key (is the gateway up? is LITELLM_VIRTUAL_KEY set?)"; fi
elif [ "$ACTION" = "resume" ]; then
  curl -s -X POST "$GATEWAY/key/unblock" -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'content-type: application/json' -d "{\"key\": \"$LITELLM_VIRTUAL_KEY\"}" > /dev/null
  mark "gateway: virtual key unblocked"
  if edge_up; then "$EDGE" resume | tail -1 | sed 's/^/        /'; mark "edge: forwarding /chat again"; fi
else
  curl -s "$GATEWAY/key/info?key=$LITELLM_VIRTUAL_KEY" -H "Authorization: Bearer $LITELLM_MASTER_KEY" | python3 -c "import sys, json; d = json.load(sys.stdin).get('info', {}); print('gateway key', d.get('key_alias', ''), 'blocked:', d.get('blocked', False), '| spend so far:', d.get('spend'))"
  if edge_up; then curl -s -o /dev/null -w "edge: POST /chat without a token -> HTTP %{http_code} (401 = forwarding, 503 = stopped)\n" -X POST http://localhost:9080/chat; else echo "edge: APISIX not running"; fi
fi
EOF
echo "wrote scripts/kill-switch-compose.sh"

mkdir -p "scripts"
cat << 'EOF' > scripts/make-virtual-key.sh
#!/usr/bin/env bash
# scripts/make-virtual-key.sh — after the gateway is running: create the agent's virtual key and write it into .env.
# Same result as creating it by hand in the gateway UI (Phase 3 of docs/SETUP-DOCKER-ONLY.md), with a 5 USD budget.
#   bash scripts/make-virtual-key.sh
#   docker compose up -d agent          <- a separate command: the agent reads the new key when it is recreated
set -euo pipefail
if [ "$#" -gt 0 ]; then
  echo "note: this script takes no arguments, so '$*' was ignored. Run it, then run the next command on its own line."
fi
set -a; source .env; set +a
[ -n "$LITELLM_MASTER_KEY" ] || { echo "LITELLM_MASTER_KEY is empty: run scripts/make-env.sh first"; exit 1; }

# the gateway starts only after Postgres, Redis and Presidio are healthy: on a first start that can take several minutes
for i in $(seq 1 36); do
  if curl -sf -o /dev/null http://localhost:4000/health/liveliness; then break; fi
  if [ "$i" -eq 36 ]; then
    echo "the gateway still does not answer on localhost:4000 after 6 minutes. Check: docker compose ps   and   docker compose logs --tail 40 litellm"
    exit 1
  fi
  echo "waiting for the gateway on localhost:4000 ... $((i * 10))s"
  sleep 10
done

# a fresh alias each run, so running the script twice never collides with an existing key
answer=$(curl -s -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "content-type: application/json" \
  -d "{\"key_alias\": \"bank-agent-compose-$(date +%Y%m%d-%H%M%S)\", \"max_budget\": 5}")
key=$(echo "$answer" | python3 -c "import sys, json; print(json.load(sys.stdin).get('key', ''))")
[ -n "$key" ] || { echo "the gateway did not return a key: $answer"; exit 1; }

sed -i "s|^LITELLM_VIRTUAL_KEY=.*|LITELLM_VIRTUAL_KEY=$key|" .env
echo "LITELLM_VIRTUAL_KEY written to .env (budget 5 USD)."
echo "Next, on its own line:   docker compose up -d agent"
EOF
echo "wrote scripts/make-virtual-key.sh"

mkdir -p "scripts"
cat << 'EOF' > scripts/wait-for-stack.sh
#!/usr/bin/env bash
# scripts/wait-for-stack.sh — after 'docker compose up -d': wait until every service is ready, and say what is still starting.
# A first start takes 3 to 6 minutes: the gateway waits for Postgres, Redis and Presidio, and Presidio is slow to load.
#   bash scripts/wait-for-stack.sh            (gives up after 10 minutes and tells you which logs to read)
set -euo pipefail
[ -n "${COMPOSE_FILE:-}" ] || echo "note: COMPOSE_FILE is not set, so only docker-compose.yml is checked (see docs/DEMO-SCRIPT.md, A4)"
key=$(grep -E '^LITELLM_VIRTUAL_KEY=' .env 2>/dev/null | cut -d= -f2-)

# reads 'docker compose ps --format json' (one JSON object per line, or one JSON list: both Compose formats exist)
PARSE='
import json, sys
text = sys.stdin.read().strip()
rows = json.loads(text) if text.startswith("[") else [json.loads(line) for line in text.splitlines() if line.strip()]
no_key = sys.argv[1] == ""
ready, waiting = [], []
for r in rows:
    name, state, health = r.get("Service", "?"), r.get("State", ""), r.get("Health", "")
    if name in ("locust", "ingest"):
        continue                                # on-demand services: started and stopped by hand, never waited for
    if state == "exited" and r.get("ExitCode", 1) == 0:
        ready.append(name)                      # a one-shot job that finished (ollama-pull)
    elif state == "running" and health in ("healthy", ""):
        ready.append(name)
    elif name == "agent" and no_key:
        ready.append(name + " (no virtual key yet: run scripts/make-virtual-key.sh)")
    else:
        waiting.append(f"{name} ({health or state})")
print(f"ready {len(ready)}/{len(ready) + len(waiting)}" + (" | waiting for: " + ", ".join(waiting) if waiting else ""))
sys.exit(0 if rows and not waiting else 1)
'
for i in $(seq 1 60); do
  if docker compose ps --all --format json | python3 -c "$PARSE" "$key"; then
    echo "The stack is ready."
    exit 0
  fi
  sleep 10
done
echo "Still not ready after 10 minutes. Look at the services listed above, for example:"
echo "  docker compose logs --tail 40 presidio-analyzer litellm"
exit 1
EOF
echo "wrote scripts/wait-for-stack.sh"

chmod +x scripts/*.sh deploy/compose/apisix/configure.sh
echo "step-demo-script: 9 files written. Next: docs/DEMO-SCRIPT.md"
