# SmartOps-Lite — End-to-End Design & Diagrams

> **The visual reference.** Every angle of the project as a diagram, with narration. This is the **picture book** you flip through when someone says "walk me through the architecture".
>
> **As built (v1.0, recorded run 25 Sep 2026).** Everything below was deployed and exercised except two optional paths: the Slack **Acknowledge** button (the remediator Lambda is deployed, but Slack wasn't pointed at it, so §4.2 wasn't exercised) and the **Grafana Cloud** dashboard (CloudWatch had the metrics; Grafana wasn't connected). Diagrams mark both as optional.
>
> **Rendering.** Every diagram below is [Mermaid](https://mermaid.js.org/). GitHub renders them natively in the file preview. To export a PNG, paste the block into [mermaid.live](https://mermaid.live/) → Actions → PNG. Source `.mmd` files are also in [`docs/diagrams/`](diagrams/) if you want to regenerate.
>
> **Companion docs.**
> - [`README.md`](../README.md) — top-of-repo overview
> - [`INSTALL.md`](INSTALL.md) — how to set it up and run it
> - [`docs/adr/`](adr/) — architecture decision records
> - [`docs/modules/`](modules/) — per-module runbooks

---

## Table of contents

- [Legend & conventions](#legend--conventions)
- [§1 — System context (the "one-slide" view)](#1--system-context-the-one-slide-view)
- [§2 — Component architecture (the master diagram)](#2--component-architecture-the-master-diagram)
- [§3 — Deployment topology (where things physically run)](#3--deployment-topology-where-things-physically-run)
- [§4 — Sequence flows (temporal traces)](#4--sequence-flows-temporal-traces)
  - [§4.1 Happy path — pod crash to Slack card](#41-happy-path--pod-crash-to-slack-card)
  - [§4.2 Ack path — Slack button to DDB update](#42-ack-path--slack-button-to-ddb-update)
  - [§4.3 MTTR aggregation — 5-min tick to Grafana](#43-mttr-aggregation--5-min-tick-to-grafana)
  - [§4.4 Lambda cold-start — secrets through KMS](#44-lambda-cold-start--secrets-through-kms)
- [§5 — State machines](#5--state-machines)
  - [§5.1 Incident lifecycle](#51-incident-lifecycle)
  - [§5.2 RCA generation (Groq, fail-soft)](#52-rca-generation-groq-fail-soft)
  - [§5.3 Publisher factory (DRY_RUN vs real EventBridge)](#53-publisher-factory-dry_run-vs-real-eventbridge)
- [§6 — Data flow (where every piece of data lives)](#6--data-flow-where-every-piece-of-data-lives)
- [§7 — IAM permission graph](#7--iam-permission-graph)
- [§8 — EventBridge routing](#8--eventbridge-routing)
- [§9 — Module dependency graph](#9--module-dependency-graph)
- [§10 — Free-tier headroom (cost visual)](#10--free-tier-headroom-cost-visual)
- [§11 — Teardown decision tree (eod vs nuke)](#11--teardown-decision-tree-eod-vs-nuke)
- [§12 — Directory map](#12--directory-map)

---

## Legend & conventions

Every diagram in this file uses the same color + shape system.

```mermaid
flowchart LR
    Actor[Human actor<br/>developer, engineer]:::actor
    Pod["K8s pod<br/>runs on cluster"]:::pod
    Fn["AWS Lambda<br/>serverless compute"]:::lambda
    Bus{{"Event bus / router<br/>EventBridge"}}:::bus
    Store[("Data store<br/>DynamoDB / CloudWatch")]:::store
    Sec[["Secret store<br/>SSM SecureString"]]:::secret
    Ext(["External service<br/>Groq / Slack / Grafana"]):::ext
    FnURL[["Lambda Function URL<br/>public HTTPS"]]:::fnurl
    CI[["CI system<br/>GitHub Actions"]]:::ci
    Actor --> Pod
    Pod --> Fn --> Bus --> Store
    Fn --> Sec
    Fn --> Ext
    Ext --> FnURL --> Fn
    Actor --> CI

    classDef actor    fill:#fff8dc,stroke:#c8a417,color:#333;
    classDef pod      fill:#e6f2ff,stroke:#2563eb,color:#111;
    classDef lambda   fill:#fef3c7,stroke:#d97706,color:#111;
    classDef bus      fill:#f3e8ff,stroke:#7c3aed,color:#111;
    classDef store    fill:#ecfdf5,stroke:#059669,color:#111;
    classDef secret   fill:#fee2e2,stroke:#dc2626,color:#111;
    classDef ext      fill:#f5f5f5,stroke:#525252,color:#111;
    classDef fnurl    fill:#fef3c7,stroke:#d97706,color:#111,stroke-dasharray: 5 5;
    classDef ci       fill:#e0e7ff,stroke:#4f46e5,color:#111;
```

**Arrow conventions:**
- **Solid** (`-->`) — request/response, data write.
- **Dashed** (`-.->`) — asynchronous / log emission / eventual consistency.
- **Labeled** (`-->|"..."|`) — includes the payload or method (e.g., `PutItem`, `HMAC-signed POST`).

---

## §1 — System context (the "one-slide" view)

The whole system in one diagram — everything outside the box is external.

```mermaid
flowchart LR
    Dev[Developer / SRE<br/>on-call engineer]:::actor
    Slack(["Slack workspace<br/>#smartops-alerts"]):::ext
    Groq(["Groq LLM<br/>qwen/qwen3.8-27b"]):::ext
    Graf(["Grafana Cloud<br/>dashboard (optional)"]):::ext

    subgraph SmartOps["SmartOps-Lite (AWS free-tier)"]
        direction TB
        Ctrl[K8s controller]:::pod
        Bus{{EventBridge}}:::bus
        Fns[3 × Lambda]:::lambda
        Data[(DDB + CloudWatch)]:::store
    end

    Dev -->|"kubectl / make"| SmartOps
    Ctrl --> Bus --> Fns --> Data
    Fns -->|"RCA prompt"| Groq
    Fns -->|"Block Kit card"| Slack
    Slack -.->|"Ack button click<br/>(HMAC-signed, optional)"| Fns
    Data -.->|"up to 5 metrics<br/>CloudWatch API"| Graf
    Graf --> Dev

    classDef actor  fill:#fff8dc,stroke:#c8a417,color:#333;
    classDef pod    fill:#e6f2ff,stroke:#2563eb,color:#111;
    classDef lambda fill:#fef3c7,stroke:#d97706,color:#111;
    classDef bus    fill:#f3e8ff,stroke:#7c3aed,color:#111;
    classDef store  fill:#ecfdf5,stroke:#059669,color:#111;
    classDef ext    fill:#f5f5f5,stroke:#525252,color:#111;
```

**What this shows.** The whole system is one box. Everything outside — Slack, Groq, Grafana, the developer — is a boundary integration.
**What to say in interviews.** "Three external integrations: LLM for enrichment, Slack for alerts (and an optional Ack button), and an optional Grafana dashboard. Everything inside is on AWS free tier."

---

## §2 — Component architecture (the master diagram)

Same picture, with every internal component named. This is the diagram to draw on a whiteboard.

```mermaid
flowchart LR
    %% Actors
    Dev[Developer<br/>make tf-apply / make chaos-crash]:::actor

    %% K8s cluster
    subgraph K3S["K3s cluster — 2 × t3.micro (multi-AZ)"]
        direction TB
        Crashy["crashy-app<br/>(FastAPI, 2 replicas)<br/>hard anti-affinity"]:::pod
        Ctrl["smartops-controller<br/>(K8s watch → EventBridge)<br/>LRU dedup (4096)"]:::pod
        Crashy -.->|"pod events<br/>CrashLoop / OOM / etc."| Ctrl
    end
    Dev -->|"kubectl / helm"| K3S

    %% Event bus + Lambdas
    Bus{{"EventBridge<br/>custom bus 'smartops-dev'"}}:::bus
    Ctrl -->|"IncidentDetected<br/>schema v1.0"| Bus

    RcaFn["rca-generator<br/>Lambda (Python 3.12)"]:::lambda
    Rem["remediator<br/>Lambda (Slack Ack)"]:::lambda
    Mttr["mttr-aggregator<br/>rate(5 min)"]:::lambda

    Sched{{"EventBridge default bus<br/>schedule rule"}}:::bus
    Bus -->|"rule: IncidentDetected"| RcaFn
    Sched -->|"rate(5 minutes)"| Mttr
    Rem -.->|"RemediationRequested<br/>(no consumer yet — Module 7.1)"| Bus

    %% Persistence + secrets
    DDB[("DynamoDB<br/>smartops-incidents<br/>on-demand")]:::store
    SSM[["SSM SecureString<br/>slack_webhook · groq_api_key<br/>(+ optional slack_signing_secret)<br/>KMS aws/ssm"]]:::secret
    RcaFn -->|"GetParameters<br/>batched, cold-start"| SSM
    RcaFn -->|"PutItem<br/>idempotent by incidentId"| DDB
    Rem -->|"UpdateItem<br/>rcaStatus→acknowledged<br/>(conditional)"| DDB
    Rem -->|"GetParameter<br/>signing secret"| SSM
    Mttr -->|"Scan<br/>60-min window"| DDB

    %% External services
    Groq(["Groq LLM<br/>qwen/qwen3.8-27b<br/>free tier"]):::ext
    Slack(["Slack workspace<br/>#smartops-alerts"]):::ext
    RcaFn -->|"chat/completions<br/>urllib.request"| Groq
    RcaFn -->|"Block Kit card"| Slack
    Slack -.->|"block_actions POST<br/>HMAC-SHA256 signed<br/>(optional)"| RemURL
    RemURL[["Lambda Function URL<br/>HTTPS, no API GW"]]:::fnurl
    RemURL --> Rem

    %% Observability
    CW[("CloudWatch<br/>metrics: SmartOps (≤ 5 no-dim)<br/>logs: /aws/lambda/*")]:::store
    Mttr -->|"PutMetricData"| CW
    RcaFn -.->|"stdout logs"| CW
    Rem -.->|"stdout logs"| CW

    Graf(["Grafana Cloud<br/>free tier (optional)"]):::ext
    CW -.->|"CloudWatch DS<br/>+ Logs Insights"| Graf
    Graf -.-> Dev

    %% CI/CD
    GH[["GitHub Actions<br/>ci.yml + security.yml"]]:::ci
    Dev -->|"git push"| GH
    GH -.->|"lint / test / Trivy / Gitleaks"| K3S

    classDef actor    fill:#fff8dc,stroke:#c8a417,color:#333;
    classDef pod      fill:#e6f2ff,stroke:#2563eb,color:#111;
    classDef lambda   fill:#fef3c7,stroke:#d97706,color:#111;
    classDef bus      fill:#f3e8ff,stroke:#7c3aed,color:#111;
    classDef store    fill:#ecfdf5,stroke:#059669,color:#111;
    classDef secret   fill:#fee2e2,stroke:#dc2626,color:#111;
    classDef ext      fill:#f5f5f5,stroke:#525252,color:#111;
    classDef fnurl    fill:#fef3c7,stroke:#d97706,color:#111,stroke-dasharray: 5 5;
    classDef ci       fill:#e0e7ff,stroke:#4f46e5,color:#111;
```

**What to notice.**
- **Decoupled at EventBridge.** The controller only knows the bus; the rule decides who consumes. The 5-minute schedule that drives the aggregator is a separate rule on the account's default bus.
- **Return path (optional).** Slack Ack → Function URL → remediator. NO API Gateway in between.
- **Dashed arrows** are log/async emits or optional paths — not synchronous dependencies.
- **Controller and app logs stay in the cluster** (`kubectl logs`). No log agent runs on the nodes; only the Lambdas log to CloudWatch.
- **No open ports on the cluster.** kubectl reaches K3s via SSM Session Manager port-forward (implicit from `make kube-config`).

**Source `.mmd`.** [`docs/diagrams/architecture.mmd`](diagrams/architecture.mmd) — regenerate PNG via `npx @mermaid-js/mermaid-cli` or paste at [mermaid.live](https://mermaid.live/).

---

## §3 — Deployment topology (where things physically run)

Same components, arranged by *where they physically live*.

```mermaid
flowchart TB
    subgraph AWS["AWS account · ap-south-1"]
        direction TB

        subgraph VPC["VPC 10.0.0.0/16"]
            direction LR
            subgraph AZa["Subnet ap-south-1a (10.0.1.0/24)"]
                direction TB
                EC2a["EC2 t3.micro<br/>K3s server<br/>+ crashy-app pod #1<br/>+ CoreDNS"]:::pod
            end
            subgraph AZb["Subnet ap-south-1b (10.0.2.0/24)"]
                direction TB
                EC2b["EC2 t3.micro<br/>K3s agent<br/>+ crashy-app pod #2<br/>+ controller pod *"]:::pod
            end
            IGW["Internet Gateway"]:::store
            AZa --- IGW
            AZb --- IGW
        end

        subgraph Serverless["Serverless plane (regional, no VPC)"]
            direction LR
            Lam1["rca-generator<br/>Lambda"]:::lambda
            Lam2["remediator<br/>Lambda"]:::lambda
            Lam3["mttr-aggregator<br/>Lambda"]:::lambda
            LamURL[["Function URL<br/>for remediator"]]:::fnurl
            Lam2 --- LamURL
        end

        subgraph Managed["Managed data plane"]
            direction LR
            DDB[("DynamoDB<br/>smartops-incidents")]:::store
            EB{{"EventBridge<br/>smartops-dev bus"}}:::bus
            SSMS[["SSM Params<br/>2 secrets (+1 optional)<br/>+ 4 written by K3s"]]:::secret
            CWS[("CloudWatch<br/>metrics + logs")]:::store
            ECR[("ECR<br/>2 images")]:::store
            S3[("S3<br/>tf-state")]:::store
        end

        EC2b -->|"PutEvents"| EB
        EB --> Lam1
        EB --> Lam3
        Lam1 --> DDB
        Lam1 --> SSMS
        Lam2 --> DDB
        Lam3 --> DDB
        Lam3 --> CWS
        EC2a -.-> ECR
        EC2b -.-> ECR
    end

    Slack(["Slack<br/>(HTTPS)"]):::ext
    Groq(["Groq<br/>(HTTPS)"]):::ext
    Graf(["Grafana Cloud<br/>(HTTPS, optional)"]):::ext
    Lam1 --> Groq
    Lam1 --> Slack
    Slack -.-> LamURL
    Graf -.-> CWS

    classDef pod    fill:#e6f2ff,stroke:#2563eb,color:#111;
    classDef lambda fill:#fef3c7,stroke:#d97706,color:#111;
    classDef bus    fill:#f3e8ff,stroke:#7c3aed,color:#111;
    classDef store  fill:#ecfdf5,stroke:#059669,color:#111;
    classDef secret fill:#fee2e2,stroke:#dc2626,color:#111;
    classDef ext    fill:#f5f5f5,stroke:#525252,color:#111;
    classDef fnurl  fill:#fef3c7,stroke:#d97706,color:#111,stroke-dasharray: 5 5;
```

**What to notice.**
- **crashy-app is spread 1-per-AZ.** Hard anti-affinity on `topology.kubernetes.io/zone` forces this — no two pods in the same AZ, ever.
- **\* The controller can land on either node** (single replica, cluster-scoped RBAC, no node pinning). In the recorded run the scheduler put it on the agent. Both nodes share one IAM role, so it can publish from either.
- **Lambdas are outside the VPC.** No NAT Gateway needed → free.
- **Everything managed is single-region** (`ap-south-1`). Multi-region would multiply cost — out of scope for demo.
- **Egress-only external calls** — Slack/Groq return via Function URL (Slack) and HTTPS response (Groq). No inbound to VPC.

---

## §4 — Sequence flows (temporal traces)

### §4.1 Happy path — pod crash to Slack card

The full path from `GET /crash` to a rendered Slack Block Kit card. ~5 seconds end-to-end.

```mermaid
sequenceDiagram
    autonumber
    actor Dev as Developer
    participant CA as crashy-app pod<br/>(FastAPI)
    participant Kubelet as kubelet<br/>(K3s node)
    participant Api as K8s API server
    participant Ctrl as smartops-controller
    participant LRU as LRU dedup set
    participant Bus as EventBridge<br/>smartops-dev
    participant Rca as rca-generator<br/>Lambda
    participant SSM as SSM<br/>SecureString
    participant Groq as Groq LLM
    participant DDB as DynamoDB
    participant Slack as Slack channel

    Dev->>CA: GET /crash (via kubectl port-forward)
    CA->>CA: os._exit(1)
    CA-->>Kubelet: container exited (code 1)
    Kubelet->>Kubelet: restart container in the same pod (restartCount 1)
    Kubelet->>Api: update pod status (lastState: Error, exit 1)
    Ctrl->>Api: watch all pods (Watch API)
    Api-->>Ctrl: MODIFIED pod event
    Ctrl->>Ctrl: detector.detect() → Incident
    Ctrl->>LRU: check (ns,pod,ctr,reason)
    LRU-->>Ctrl: not seen — publish
    Ctrl->>Bus: PutEvents(IncidentDetected)

    Note over Bus,Rca: (rule: source=smartops.controller<br/> → target: rca-generator)

    Bus->>Rca: invoke (async)
    alt cold start
        Rca->>SSM: GetParameters(2 params, batched)
        SSM-->>Rca: {slack_webhook, groq_key}
    end
    Rca->>Rca: parse_event() [fail-loud on schema]
    Rca->>Groq: POST /v1/chat/completions
    alt Groq OK
        Groq-->>Rca: 2-sentence RCA
    else Groq timeout/error
        Rca->>Rca: rcaText = placeholder<br/>rcaSource = fallback
    end
    Rca->>DDB: PutItem(incidentId, ...)
    DDB-->>Rca: 200 OK
    Rca->>Slack: POST Block Kit card
    Slack-->>Dev: renders red-headed alert<br/>with Acknowledge button
```

**What to say in interviews (§4.1).**
"From `GET /crash` to Slack card in ~5 seconds. Key design points: LRU dedup so 20 crashes/min → 1 Slack card, cold-start-only secret loading so warm invocations skip SSM, fail-loud on schema (EventBridge retries) but fail-soft on Groq (placeholder text, DDB + Slack still land)."

### §4.2 Ack path — Slack button to DDB update

What happens between the click and the "acknowledged" footer appearing.

> **Optional — not exercised in the recorded run.** The remediator Lambda and its Function URL are deployed and covered by 40 unit tests. To turn the button on, store the signing secret (`make put-signing-secret`) and set the Slack app's Interactivity Request URL to `make remediator-url` (see [`modules/07-remediator.md`](modules/07-remediator.md)).

```mermaid
sequenceDiagram
    autonumber
    actor Eng as Engineer
    participant Slack as Slack
    participant URL as Lambda Function URL
    participant Rem as remediator Lambda
    participant SSM as SSM SecureString
    participant Verify as verify.py<br/>(HMAC)
    participant DDB as DynamoDB
    participant Bus as EventBridge

    Eng->>Slack: click "Acknowledge" button
    Slack->>URL: POST /<br/>payload=block_actions<br/>X-Slack-Signature: v0=hmac
    URL->>Rem: invoke (sync)
    alt cold start
        Rem->>SSM: GetParameter(signing_secret)
        SSM-->>Rem: signing_secret
    end
    Rem->>Verify: verify_signature(hdrs, body, secret)
    Verify->>Verify: check timestamp ≤ 300s
    Verify->>Verify: hmac.compare_digest (constant-time)
    alt bad signature
        Verify-->>Rem: raise VerifyError
        Rem-->>Slack: HTTP 401
        Note over Rem,DDB: NO DDB write, NO bus event
    else valid
        Verify-->>Rem: OK
        Rem->>Rem: parse block_actions payload
        Rem->>DDB: UpdateItem(<br/>Key=incidentId,<br/>Cond: row exists AND rcaStatus ≠ acknowledged,<br/>Set: acknowledged/by/at)
        alt condition passes
            DDB-->>Rem: 200 OK
            opt reason in whitelist
                Rem-->>Bus: PutEvents(RemediationRequested)
                Note right of Bus: (nothing consumes yet<br/> — Module 7.1 deferred)
            end
            Rem->>Slack: 200 OK<br/>+ replacement block payload<br/>(strips button, adds footer)
            Slack-->>Eng: renders acked card
        else ConditionalCheckFailedException
            Rem->>DDB: GetItem(incidentId) to read prior actor
            DDB-->>Rem: rcaStatus=acknowledged by <@other>
            Rem->>Slack: 200 OK<br/>+ echo prior actor
            Slack-->>Eng: "Already acked by <@other>"
        end
    end
```

**What to say in interviews (§4.2).**
"Three protections stacked: HMAC-SHA256 (proves Slack), 5-minute replay window (defeats replay attacks), conditional DDB update (defeats double-ack race). And `hmac.compare_digest`, not `==` — constant-time compare defeats timing side-channels."

### §4.3 MTTR aggregation — 5-min tick to Grafana

How dashboards get populated. In the recorded run the metrics were checked with `make cloudwatch-metrics-mttr` and the CloudWatch console; the Grafana half is optional.

```mermaid
sequenceDiagram
    autonumber
    participant Sched as EventBridge<br/>scheduled rule
    participant Agg as mttr-aggregator Lambda
    participant DDB as DynamoDB
    participant Pure as aggregator.py<br/>(pure function)
    participant CW as CloudWatch<br/>SmartOps namespace
    participant Graf as Grafana Cloud<br/>(optional)
    actor Eng as Engineer

    loop every 5 minutes
        Sched->>Agg: invoke ({time: ISO8601})
        Agg->>Agg: now = _now_from_event(event)
        Agg->>DDB: Scan(<br/>FilterExpression: ingestedAt >= now-60min)
        DDB-->>Agg: rows[]
        Agg->>Pure: compute_metrics(rows, now)
        Pure-->>Agg: [<br/> IncidentCount,<br/> AckedIncidentCount,<br/> AckRatePercent,<br/> LLMSuccessRatePercent,<br/> MTTRSecondsAvg<br/>]
        Agg->>CW: PutMetricData(batch of ≤ 5)<br/>MTTRSecondsAvg only if a row was acked
    end

    loop every 30s (dashboard refresh)
        Graf->>CW: GetMetricData(SmartOps.*)
        CW-->>Graf: values + timestamps
        Graf->>Graf: render 8 panels
    end

    Eng->>Graf: view dashboard
    Graf-->>Eng: MTTR trend, ack rate, headline stats
```

**What to say in interviews (§4.3).**
"Deterministic aggregation window — reads `event['time']` from the schedule tick, not `datetime.now()`. Aggregator core is a pure function — 32 tests with no mocks. 5 no-dimension metrics fits the 10-metric free-tier ceiling with 100% headroom. Per-reason breakouts move to CloudWatch Logs Insights queries (free within 5 GB/mo)."

### §4.4 Lambda cold-start — secrets through KMS

Where secrets come from + why cold-start-only loading matters.

```mermaid
sequenceDiagram
    autonumber
    participant Op as Operator
    participant Env as Local shell (env vars)
    participant PS as scripts/put-secrets.sh
    participant SSM as SSM Parameter Store
    participant KMS as KMS (aws/ssm)
    participant Lambda as RCA Lambda runtime
    participant Handler as handler(event, context)

    rect rgba(200,200,255,0.15)
      Note over Op,KMS: Setup — one-time
      Op->>Env: read -rsp → export SLACK_WEBHOOK_URL
      Op->>Env: read -rsp → export GROQ_API_KEY
      Op->>PS: make put-secrets
      PS->>SSM: PutParameter(SecureString × 2)
      Op->>Env: unset the variables
      Note over Op,PS: optional: SLACK_SIGNING_SECRET + make put-signing-secret (Ack button only)
      SSM->>KMS: Encrypt(value, key=aws/ssm)
      KMS-->>SSM: ciphertext
      SSM->>SSM: persist ciphertext
    end

    rect rgba(255,200,200,0.15)
      Note over Lambda,Handler: Runtime — every cold start (~250-400ms)
      Lambda->>Lambda: import module (module scope)
      Lambda->>SSM: GetParameters(2 names, WithDecryption=true)
      SSM->>KMS: Decrypt (via kms:ViaService condition)
      KMS-->>SSM: plaintext × 2
      SSM-->>Lambda: {slack_webhook, groq_api_key}
      Lambda->>Lambda: Secrets(...) held at module scope
    end

    rect rgba(200,255,200,0.15)
      Note over Lambda,Handler: Runtime — every warm invocation (~5ms)
      Lambda->>Handler: handler(event, context)
      Handler->>Handler: uses cached Secrets — no SSM/KMS call
    end
```

**What to say in interviews (§4.4).**
"Cold-start-only secret loading. `Secrets.load()` at module scope runs once per cold container; warm invocations reuse. Batched `GetParameters` fetches both secrets in one API call (the remediator reads its signing secret the same way, separately). `kms:ViaService` condition on the Lambda's IAM policy scopes decrypt to *only via SSM* — tightest possible KMS scope. Total setup cost + runtime cost sits inside SSM + KMS free tier permanently."

---

## §5 — State machines

### §5.1 Incident lifecycle

Every DDB row goes through this state machine.

```mermaid
stateDiagram-v2
    [*] --> generated: RCA Lambda PutItem<br/>Groq returned an RCA
    [*] --> pending: RCA Lambda PutItem<br/>LLM off or Groq failed (placeholder text)
    generated --> generated: duplicate event<br/>[PutItem condition fails — swallowed]
    generated --> acknowledged: Remediator UpdateItem<br/>[condition passes]
    pending --> acknowledged: Remediator UpdateItem<br/>[condition passes]

    acknowledged --> acknowledged: double-click<br/>[ConditionalCheckFailed]<br/>Slack echoes prior actor

    generated --> remediated: (future — Module 7.1)<br/>kubectl-executor auto-fix
    acknowledged --> remediated: (future — Module 7.1)
```

Rows are never deleted in dev: the DynamoDB module supports TTL, but `infra/envs/dev/main.tf` sets `enable_ttl = false`. Nothing was acknowledged in the recorded run, so no row reached `acknowledged`.

**Fields on the DDB row per state:**

| State | rcaStatus | acknowledgedBy | acknowledgedAt | remediationEvents |
|---|---|---|---|---|
| `generated` | `"generated"` | ∅ | ∅ | ∅ |
| `pending` | `"pending"` | ∅ | ∅ | ∅ |
| `acknowledged` | `"acknowledged"` | Slack user ID | ISO 8601 | ∅ |
| `remediated` (future) | `"remediated"` | Slack user ID | ISO 8601 | array of `RemediationRequested` events |

### §5.2 RCA generation (Groq, fail-soft)

One backend, configured by Lambda environment variables that Terraform sets.

```mermaid
flowchart TB
    Env["Lambda env vars (from Terraform)<br/>LLM_ENABLED · LLM_MODEL=qwen/qwen3.8-27b<br/>LLM_TIMEOUT_SECONDS=10 · LLM_MAX_TOKENS=200"]:::secret
    Handler[handler.py]:::lambda
    Groq(["Groq API<br/>urllib.request<br/>/openai/v1/chat/completions"]):::ext

    Env --> Handler
    Handler -->|"LLM enabled + key loaded"| Groq
    Groq -->|"2-sentence RCA"| Ok["rcaSource=groq<br/>rcaStatus=generated"]:::store
    Groq -->|"HTTP error / timeout / bad JSON<br/>log: groq call failed (soft)"| Fb["placeholder text<br/>rcaSource=fallback<br/>rcaStatus=pending"]:::store
    Handler -->|"LLM disabled or no key"| No["rcaSource=none<br/>rcaStatus=pending"]:::store

    Ok --> Out
    Fb --> Out
    No --> Out
    Out[("DynamoDB row + Slack card<br/>on every branch")]:::store

    classDef secret fill:#fee2e2,stroke:#dc2626,color:#111;
    classDef lambda fill:#fef3c7,stroke:#d97706,color:#111;
    classDef ext    fill:#f5f5f5,stroke:#525252,color:#111;
    classDef store  fill:#ecfdf5,stroke:#059669,color:#111;
```

**Why one backend.** [ADR-002](adr/002-ai-backend-choice.md) first planned Groq, Bedrock and Ollama behind one interface; only Groq was built, because it's free and needs no SDK in the Lambda zip. The model is a Terraform variable (`llm_model`), so when Groq retired `llama-3.3-70b-versatile` during the first AWS run, the switch to `qwen/qwen3.8-27b` changed one default and no code.

### §5.3 Publisher factory (DRY_RUN vs real EventBridge)

The controller uses the same code path in prod and local kind demos.

```mermaid
flowchart LR
    Env["Env var<br/>DRY_RUN"]:::secret
    Factory[publisher.py<br/>create_publisher]:::lambda

    Env -->|"true / 1 / yes"| DryRun
    Env -->|"false (default)"| Real

    DryRun[DryRunPublisher<br/>stdout JSON]:::pod
    Real[EventBridgePublisher<br/>boto3.events.put_events]:::lambda

    DryRun -->|"json.dumps(event)"| Stdout([console log]):::ext
    Real -->|"PutEvents"| Bus{{EventBridge}}:::bus

    classDef secret fill:#fee2e2,stroke:#dc2626,color:#111;
    classDef lambda fill:#fef3c7,stroke:#d97706,color:#111;
    classDef pod    fill:#e6f2ff,stroke:#2563eb,color:#111;
    classDef bus    fill:#f3e8ff,stroke:#7c3aed,color:#111;
    classDef ext    fill:#f5f5f5,stroke:#525252,color:#111;
```

**Why.** Same code path in prod and local. Reviewer running `DRY_RUN=true` in the devcontainer sees the full pipeline in stdout without touching AWS.

---

## §6 — Data flow (where every piece of data lives)

Every piece of data in the system + who reads/writes it.

```mermaid
flowchart LR
    subgraph Secrets["🔒 Secrets (SSM SecureString, KMS-encrypted at rest)"]
        S1["/smartops/dev/slack_webhook"]:::secret
        S2["/smartops/dev/groq_api_key"]:::secret
        S3["/smartops/dev/slack_signing_secret<br/>(optional — Ack button)"]:::secret
        S4["/smartops/dev/kubeconfig<br/>(written by K3s server boot script)"]:::secret
        S5["/smartops/dev/k3s_join_token<br/>(K3s agent join)"]:::secret
    end

    subgraph Config["⚙️ Config (SSM String / env vars, plaintext)"]
        C1["EVENT_BUS_NAME<br/>smartops-dev"]:::store
        C2["INCIDENTS_TABLE_NAME<br/>smartops-incidents"]:::store
        C3["LLM_MODEL<br/>qwen/qwen3.8-27b"]:::store
        C4["/smartops/dev/k3s_server_url<br/>/smartops/dev/k3s_server_instance_id<br/>(written by K3s server)"]:::store
    end

    subgraph Records["🗄️ Records (DynamoDB smartops-incidents)"]
        R1["incidentId (PK, S)<br/>UUID"]:::store
        R2["ingestedAt (ISO 8601)<br/>reason, namespace, pod<br/>container, restartCount"]:::store
        R3["rcaText, rcaSource<br/>rcaStatus (generated/acknowledged)"]:::store
        R4["acknowledgedBy<br/>acknowledgedAt"]:::store
    end

    subgraph Metrics["📈 Metrics (CloudWatch, namespace SmartOps)"]
        M1["IncidentCount (Count)"]:::store
        M2["AckedIncidentCount (Count)"]:::store
        M3["AckRatePercent (Percent)"]:::store
        M4["LLMSuccessRatePercent (Percent)"]:::store
        M5["MTTRSecondsAvg (Seconds)"]:::store
    end

    subgraph Logs["📜 Logs (CloudWatch, 14-day retention)"]
        L1["/aws/lambda/smartops-lite-rca-generator"]:::store
        L2["/aws/lambda/smartops-lite-remediator"]:::store
        L3["/aws/lambda/smartops-lite-mttr-aggregator"]:::store
    end

    L4["Pod logs<br/>(kubectl logs only —<br/>not shipped to CloudWatch)"]:::store

    Ctrl[controller]:::pod
    Rca[rca-generator]:::lambda
    Rem[remediator]:::lambda
    Agg[mttr-aggregator]:::lambda

    Ctrl -.->|"reads"| C1
    Rca -.->|"reads (cold start)"| S1
    Rca -.->|"reads (cold start)"| S2
    Rca -->|"writes"| Records
    Rca -.->|"stdout"| L1
    Rem -.->|"reads (cold start)"| S3
    Rem -->|"updates"| Records
    Rem -.->|"stdout"| L2
    Agg -->|"scans"| Records
    Agg -->|"writes"| Metrics
    Agg -.->|"stdout"| L3
    Ctrl -.->|"stdout"| L4

    classDef pod    fill:#e6f2ff,stroke:#2563eb,color:#111;
    classDef lambda fill:#fef3c7,stroke:#d97706,color:#111;
    classDef secret fill:#fee2e2,stroke:#dc2626,color:#111;
    classDef store  fill:#ecfdf5,stroke:#059669,color:#111;
```

**Key invariants.**
- **Secrets never appear in DDB, CW metrics, CW logs.** Ever. Only SSM.
- **PII-free.** No email/user names in DDB. `acknowledgedBy` is Slack user ID (opaque), not display name.
- **Time is UTC everywhere.** ISO 8601 with `Z` suffix. Aggregator's "now" comes from EventBridge tick, not clock.

---

## §7 — IAM permission graph

Who can do what to what. Every arrow is a policy statement.

```mermaid
flowchart LR
    subgraph Principals["Principals (IAM identities)"]
        User[IAM user<br/>smartops-cli]:::actor
        NodeRole[Node role<br/>K3s server + agent]:::pod
        LRca[Role: rca-generator]:::lambda
        LRem[Role: remediator]:::lambda
        LAgg[Role: mttr-aggregator]:::lambda
    end

    subgraph AWS_Actions["AWS resources"]
        S3[("S3<br/>smartops-lite-tf-state-‹account-id›")]:::store
        DDBLock[(DDB<br/>smartops-lite-tf-lock)]:::store
        DDBData[(DDB<br/>smartops-incidents)]:::store
        Bus{{EventBridge<br/>smartops-dev}}:::bus
        SSMSec[["SSM /smartops/dev/*<br/>slack_webhook · groq_api_key<br/>(+ optional slack_signing_secret)"]]:::secret
        SSMK3s[["SSM /smartops/dev/*<br/>kubeconfig · k3s_join_token<br/>k3s_server_url · k3s_server_instance_id"]]:::secret
        KMSKey[[KMS<br/>alias/aws/ssm]]:::secret
        CWMetrics[(CW<br/>SmartOps ns)]:::store
        CWLogs[(CW Logs<br/>/aws/lambda/*)]:::store
        ECRImg[(ECR<br/>2 repos)]:::store
    end

    %% User (via CLI + Terraform)
    User -->|"* (admin for TF)"| S3
    User -->|"* (admin for TF)"| DDBLock

    %% Node role
    NodeRole -->|"events:PutEvents (1 ARN)"| Bus
    NodeRole -->|"ecr:GetAuthorizationToken<br/>ecr:BatchGet* / GetDownload*"| ECRImg
    NodeRole -->|"ssm:PutParameter<br/>(these 4 ARNs only)"| SSMK3s
    NodeRole -->|"ssm:GetParameter(s)<br/>/smartops/dev/*"| SSMSec
    NodeRole -->|"kms:Decrypt<br/>(via kms:ViaService=ssm)"| KMSKey

    %% RCA Lambda role
    LRca -->|"dynamodb:PutItem/UpdateItem/GetItem<br/>(1 table ARN)"| DDBData
    LRca -->|"ssm:GetParameters<br/>(2 param ARNs)"| SSMSec
    LRca -->|"kms:Decrypt<br/>(via kms:ViaService=ssm)"| KMSKey
    LRca -->|"logs:CreateLogGroup/Stream<br/>PutLogEvents"| CWLogs

    %% Remediator role
    LRem -->|"dynamodb:UpdateItem<br/>GetItem"| DDBData
    LRem -->|"events:PutEvents<br/>(1 bus ARN)"| Bus
    LRem -->|"ssm:GetParameter<br/>(signing_secret only)"| SSMSec
    LRem -->|"kms:Decrypt<br/>(kms:ViaService=ssm)"| KMSKey
    LRem -->|"logs:*"| CWLogs

    %% Aggregator role
    LAgg -->|"dynamodb:Scan"| DDBData
    LAgg -->|"cloudwatch:PutMetricData<br/>(Condition: cloudwatch:namespace=SmartOps)"| CWMetrics
    LAgg -->|"logs:*"| CWLogs

    classDef actor  fill:#fff8dc,stroke:#c8a417,color:#333;
    classDef pod    fill:#e6f2ff,stroke:#2563eb,color:#111;
    classDef lambda fill:#fef3c7,stroke:#d97706,color:#111;
    classDef bus    fill:#f3e8ff,stroke:#7c3aed,color:#111;
    classDef store  fill:#ecfdf5,stroke:#059669,color:#111;
    classDef secret fill:#fee2e2,stroke:#dc2626,color:#111;
```

**Least-privilege audit.**
- **RCA Lambda cannot delete DDB rows.** Only PutItem/UpdateItem/GetItem.
- **RCA Lambda cannot write to any other DDB table.** ARN-scoped.
- **Remediator cannot read the Groq API key.** SSM path is exactly `signing_secret`, not `groq_api_key`.
- **Aggregator cannot write to non-SmartOps CloudWatch namespaces.** `cloudwatch:namespace` condition.
- **Every Lambda's KMS Decrypt is scoped via `kms:ViaService`** — only via SSM. Prevents cross-service key abuse.
- **Node compromise blast radius = `events:PutEvents` on one bus + ECR pull + read of every `/smartops/dev/*` parameter (including the Slack webhook and Groq key) + Session Manager (`AmazonSSMManagedInstanceCore`).** The broad parameter read is the main reason per-pod IAM (IRSA) is on the upgrade path.

---

## §8 — EventBridge routing

Every event pattern and its target.

```mermaid
flowchart LR
    subgraph Sources["Event sources"]
        Ctrl[smartops-controller]:::pod
        Rem[remediator Lambda]:::lambda
        AWS[AWS internal<br/>scheduler]:::store
    end

    subgraph Bus["EventBridge — custom bus 'smartops-dev'"]
        Rule1["Rule smartops-lite-incident-detected<br/>event pattern:<br/>{source: smartops.controller,<br/> detail-type: IncidentDetected}"]:::bus
        NoRule["No rule for<br/>source: smartops.remediator<br/>(Module 7.1 deferred —<br/>event is accepted, then dropped)"]:::store
    end

    subgraph Default["EventBridge — default bus"]
        Rule2["Rule smartops-lite-mttr-aggregate<br/>schedule expression:<br/>rate(5 minutes)"]:::bus
    end

    subgraph Targets["Rule targets"]
        Rca[rca-generator Lambda]:::lambda
        Agg[mttr-aggregator Lambda]:::lambda
    end

    Ctrl -->|"PutEvents<br/>{source: smartops.controller,<br/> detail-type: IncidentDetected,<br/> Detail: {schema 1.0}}"| Rule1
    AWS -->|"internal tick<br/>{time: ISO8601}"| Rule2
    Rem -.->|"PutEvents RemediationRequested<br/>(only after an Ack)"| NoRule

    Rule1 --> Rca
    Rule2 --> Agg

    classDef pod    fill:#e6f2ff,stroke:#2563eb,color:#111;
    classDef lambda fill:#fef3c7,stroke:#d97706,color:#111;
    classDef bus    fill:#f3e8ff,stroke:#7c3aed,color:#111;
    classDef store  fill:#ecfdf5,stroke:#059669,color:#111;
```

Schedule rules can only run on the default bus, which is why the aggregator's rule isn't on `smartops-dev` (see the comment above `aws_cloudwatch_event_rule.mttr_schedule` in `infra/envs/dev/main.tf`).

**IncidentDetected event shape (schema 1.0)** — what `make chaos-crash` produces. Field names come from `Incident.to_detail()` in `controller/src/smartops_controller/detector.py`; IDs, names and times are placeholders.

```json
{
  "version": "0",
  "id": "<eventbridge-generated-uuid>",
  "detail-type": "IncidentDetected",
  "source": "smartops.controller",
  "account": "<account-id>",
  "time": "2026-09-25T05:52:10Z",
  "region": "ap-south-1",
  "resources": [],
  "detail": {
    "schemaVersion": "1.0",
    "incidentId": "<uuid4>",
    "namespace": "demo",
    "podName": "app-crashy-app-<hash>-<id>",
    "podUid": "<pod-uid>",
    "containerName": "crashy",
    "reason": "Error",
    "restartCount": 1,
    "nodeName": "<node-name>",
    "zone": "ap-south-1a",
    "timestamp": "2026-09-25T05:52:10Z",
    "message": "Error",
    "exitCode": 1,
    "labels": { "app.kubernetes.io/name": "crashy-app", "...": "..." }
  }
}
```

`reason` is `Error` rather than `CrashLoopBackOff` because the detector reports the more specific terminated reason (non-zero exit) when it has one.

---

## §9 — Module dependency graph

The 13 shipped modules + their coupling.

```mermaid
flowchart TB
    M0[Module 0<br/>Setup + backend<br/>+ secrets]:::setup
    M1[Module 1<br/>Terraform + VPC<br/>+ single-node K3s]:::infra
    M2[Module 2<br/>Multi-node K3s<br/>+ agent in AZ-b]:::infra
    M3[Module 3<br/>crashy-app<br/>+ Docker + Helm + ECR]:::infra
    M31[Module 3.1<br/>Dev container<br/>+ local kind]:::optional
    M4[Module 4<br/>Controller<br/>+ EventBridge]:::infra
    M5[Module 5<br/>RCA Lambda<br/>+ DDB + Slack]:::infra
    M6[Module 6<br/>Groq LLM<br/>+ Block Kit]:::infra
    M7[Module 7<br/>Remediator<br/>+ HMAC + Function URL]:::infra
    M8[Module 8<br/>CI/CD<br/>+ Dependabot + Trivy]:::infra
    M9[Module 9<br/>MTTR aggregator<br/>+ Grafana JSON]:::infra
    M10[Module 10<br/>Chaos runner<br/>+ demo script]:::infra
    M11[Module 11<br/>README polish<br/>+ Loom script]:::polish
    M12[Module 12<br/>Interview prep<br/>+ retro + release]:::polish

    M0 --> M1
    M1 --> M2
    M2 --> M3
    M3 --> M31
    M3 --> M4
    M4 --> M5
    M5 --> M6
    M6 --> M7
    M7 --> M9
    M9 --> M10
    M10 --> M11
    M11 --> M12
    M5 -.->|"could ship anytime after M5"| M8

    classDef setup    fill:#fef3c7,stroke:#d97706,color:#111;
    classDef infra    fill:#e6f2ff,stroke:#2563eb,color:#111;
    classDef optional fill:#f3e8ff,stroke:#7c3aed,color:#111,stroke-dasharray: 5 5;
    classDef polish   fill:#ecfdf5,stroke:#059669,color:#111;
```

**Read this.**
- **Blue = infrastructure/functional.** Every one builds on the previous.
- **Green = polish + narrative.** README, Loom, interview prep, retro, release.
- **Purple dashed = optional.** Module 3.1 (devcontainer + kind) — reviewers with no AWS.
- **M8 (CI/CD) hangs off M5.** Independent of the M5 → M6 → M7 chain; could have shipped anytime after tests existed.

---

## §10 — Free-tier headroom (cost visual)

Every AWS service we use, with headroom to the free-tier ceiling.

```mermaid
flowchart LR
    subgraph Compute["Compute + Storage"]
        EC2["EC2 t3.micro<br/>2 × 720hr = 1440hr/mo<br/>❌ exceeds 750hr ceiling"]:::warn
        EC2eod["EC2 with make eod nightly<br/>2 × 8hr × 20 days = 320hr<br/>✅ 57% headroom"]:::ok
        EBS["EBS gp3<br/>2 × 15 GB = 30/30 GB<br/>✅ 0% headroom (by design)"]:::edge
        S3["S3 tf-state<br/>< 1 MB / 5 GB<br/>✅ 99%+"]:::ok
        Lam["Lambda invocations<br/>~2k / 1M mo<br/>✅ 99.8%"]:::ok
    end

    subgraph Data["Data plane"]
        DDBStor["DDB storage<br/>< 1 MB / 25 GB<br/>✅ 99%+"]:::ok
        DDBWCU["DDB WCU (on-demand)<br/>~1 avg / 25<br/>✅ 96%"]:::ok
        DDBRCU["DDB RCU<br/>~1 avg / 25<br/>✅ 96%"]:::ok
    end

    subgraph Obs["Observability"]
        Metrics["CloudWatch metrics<br/>5 / 10 series<br/>✅ 50%"]:::edge
        LogsIng["CloudWatch Logs ingest<br/>~50 MB / 5 GB<br/>✅ 99%"]:::ok
        LogsStore["CloudWatch Logs storage<br/>< 100 MB / 5 GB<br/>✅ 98%"]:::ok
    end

    subgraph Events["Events + secrets"]
        EB["EventBridge<br/>~5k events / mo<br/>✅ effectively $0"]:::ok
        SSMAPI["SSM API calls<br/>~500 / 10k<br/>✅ 95%"]:::ok
        KMS["KMS Decrypt calls<br/>~500 / 20k<br/>✅ 97.5%"]:::ok
        ECR["ECR storage<br/>~200 / 500 MB<br/>✅ 60%"]:::edge
    end

    classDef ok    fill:#dcfce7,stroke:#16a34a,color:#111;
    classDef edge  fill:#fef3c7,stroke:#d97706,color:#111;
    classDef warn  fill:#fee2e2,stroke:#dc2626,color:#111;
```

**Reading this diagram.**
- 🟢 **Green** = safe, >50% headroom.
- 🟡 **Yellow** = near ceiling (~50-100% usage) — needs discipline (metrics count, EBS size, ECR image count).
- 🔴 **Red** = exceeds ceiling if left unmanaged — **`make eod` nightly is the only reason we stay green on EC2**.

**What actually happened.** The recorded run used an AWS account on the **Free plan**, where usage is drawn from credits and nothing is charged to the card; $0 was billed. The ceilings above are the classic free-tier limits and still show where the pressure points are. The only paid API calls in the repo are the Cost Explorer ones (`make cost`, `make status`, `SHOW_COST=true make demo`, $0.01 each), and none of the recorded steps use them.

**Interview answer.** "Free tier for real, not by hand-waving. The only ceiling I actively manage is EC2 hours — nightly `make eod` teardown keeps 2 × 24hr from becoming 1440 hr/month. Everything else has >50% headroom. Total demo cost: $0.00 - $0.05/month."

---

## §11 — Teardown decision tree (eod vs nuke)

The two-tier teardown model + when to run each.

```mermaid
flowchart TB
    Start["End of dev session?"]:::actor
    Q1{"Project done?<br/>(portfolio shipped,<br/>moving on)"}:::actor
    EOD["make eod (type YES)<br/>~2 min<br/>DESTROYS workload:<br/>EC2, EBS, Lambdas,<br/>VPC, DDB, ECR, EventBridge<br/><br/>KEEPS permanent:<br/>S3 state, DDB lock,<br/>SSM params, IAM user"]:::store
    Nuke["make nuke (type NUKE)<br/>~5 min<br/>DESTROYS everything<br/>including secrets +<br/>state bucket + IAM user<br/><br/>To come back: new IAM user<br/>+ access key, then<br/>make bootstrap-backend<br/>+ make put-secrets"]:::secret
    Cost1["cost when idle:<br/>< $0.05/mo (SSM + S3)"]:::ok
    Cost2["cost when idle:<br/>$0.00/mo"]:::ok

    Start --> Q1
    Q1 -->|"no — coming back tomorrow"| EOD
    Q1 -->|"yes — project's over"| Nuke
    EOD --> Cost1
    Nuke --> Cost2

    Cost1 -.->|"next session:<br/>INSTALL.md §5"| Start
    Cost2 -.->|"weeks later:<br/>INSTALL.md §1.1, §3, §4, §5"| Start

    classDef actor  fill:#fff8dc,stroke:#c8a417,color:#333;
    classDef store  fill:#ecfdf5,stroke:#059669,color:#111;
    classDef secret fill:#fee2e2,stroke:#dc2626,color:#111;
    classDef ok     fill:#dcfce7,stroke:#16a34a,color:#111;
```

**Interview answer.** "Two-tier teardown. `make eod` at end of every session — destroys workload, keeps permanent shared infra for $0.05/mo. `make nuke` only when the project is actually over — kills everything, back to $0."

`make eod` ends by running `check-orphans.sh`; don't close the laptop until it prints `No orphaned billable resources.` The recorded run ended with `make eod`; `make nuke` wasn't run.

---

## §12 — Directory map

Where every diagram lives in the repo.

```mermaid
flowchart LR
    subgraph Root["smartops-lite/"]
        R1[README.md]
        R2[docs/INSTALL.md<br/>docs/REFERENCE.md<br/>docs/END-TO-END.md ← this doc]
    end

    subgraph DocsD["docs/diagrams/"]
        D1[architecture.mmd<br/>← §2 master<br/>+ 10 more .mmd sources]
    end

    subgraph DocsA["docs/adr/"]
        A1[000-rejected-alternatives.md]
        A2[001-k3s-vs-eks.md]
        A3[002-ai-backend-choice.md]
        A4[003-log-pipeline-choice.md]
    end

    subgraph DocsM["docs/modules/"]
        M1[01-terraform-infra.md ... 12-interview-retro-release.md<br/>← per-module runbooks]
    end

    R1 -->|"links"| R2
    R2 -->|"cross-refs"| DocsD
    R2 -->|"decisions"| DocsA
    R2 -->|"execution"| DocsM

    classDef default fill:#f9fafb,stroke:#374151,color:#111;
```

---

## Rendering all diagrams to PNG

You already saw one workflow in `docs/diagrams/architecture.mmd`. To render every diagram in this file as a PNG:

```bash
# One-time
npm install -g @mermaid-js/mermaid-cli

# For a single diagram — extract, save as tmp.mmd, render:
npx @mermaid-js/mermaid-cli -i tmp.mmd -o out.png -w 1600 -H 900 --theme dark

# Or, GitHub renders every ```mermaid block natively — no export needed for repo browsing.
# For LinkedIn / slides, paste each block into https://mermaid.live/ → Actions → PNG.
```

Every diagram in this doc is written to render cleanly on both light and dark GitHub themes. Colors are muted so accessibility (contrast ratio ≥ 4.5:1) holds.

---

## What to read next

- **Running it yourself** → [`docs/INSTALL.md`](INSTALL.md) — accounts, deploy, demo, teardown, troubleshooting.
- **Contributors** → [`docs/modules/`](modules/) — module-by-module implementation runbooks.
- **Decision archaeologists** → [`docs/adr/`](adr/) — why we picked what we picked.

---

**Last verified against code:** 2026-10-20 (SSM parameter names, IAM statements, EventBridge rules and buses, RCA status values, event field names, log group names, LLM settings), and against the recorded AWS run of 25 Sep 2026.
