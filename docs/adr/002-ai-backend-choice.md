# ADR-002: AI backend — Groq default, Bedrock optional, Ollama fallback

**Status:** Accepted, then narrowed during Module 6 — see "As built" below
**Date:** 2026-08-04
**Deciders:** dhanym

> **As built (v1.0).** Only the Groq path was implemented. The RCA Lambda calls Groq's OpenAI-compatible API directly with stdlib `urllib` (`lambdas/rca-generator/src/rca_generator/rca_llm.py`), with a 10 s timeout and a 200-token cap. There is no `AI_BACKEND` switch and no Bedrock or Ollama client. CI stays hermetic by stubbing `urllib` in the tests instead. On any Groq failure the incident is still stored and posted with fallback text (`rcaSource = fallback`). The model is the Terraform variable `llm_model`; Groq retired `llama-3.3-70b-versatile` during the first AWS run, and the default is now `qwen/qwen3.8-27b`. The rest of this ADR is the original decision record, kept for context.

## Context

SmartOps-Lite's core value-add is a GenAI-generated Root Cause Analysis (RCA) for K8s pod failures. This requires an LLM. The project has three constraints:

1. **Zero-dollar AWS spend**.
2. **AWS story is primary** — the resume needs to say "used AWS Bedrock" credibly.
3. **CI unit tests must not depend on network / external APIs** — flaky CI ruins the story.

## Decision

Implement AI backend as a **strategy pattern** with three implementations:

| Backend | Model | Cost | Role |
|---|---|---|---|
| **Groq** | Llama 3 70B | Free tier (30 req/min) | **Default** in prod Lambda |
| **Bedrock** | Claude 3 Haiku | ~$0.15 for whole project | **Optional** — enable for comparison screenshot |
| **Ollama** | phi-3-mini or tinyllama (3B–4B) | $0 (local) | **CI unit tests + author-offline mode** |

Selection is via env var: `AI_BACKEND=groq | bedrock | ollama`.

## Rationale

### Why Groq as default

- **Free tier: no credit card, no risk of surprise bill.**
- Blazing fast — 500+ tokens/sec on Llama 3 70B; RCAs return in <2 s.
- Same JSON-output capability as Bedrock (both support structured outputs).
- Author signs up in 60 seconds; API key goes to SSM Parameter Store.

### Why Bedrock as optional

- **Resume/interview credibility.** *"I evaluated Bedrock against Groq, chose Groq for this project on cost grounds, and documented the trade-off"* is a stronger interview answer than *"I used Groq."*
- Bedrock's Claude 3 Haiku is genuinely excellent at structured JSON output — good for a comparison screenshot in the README.
- Total spend if used for the whole month would be ~$0.15 (500 RCAs × 1000 tokens × $0.25/M input). Trivial, but the author has some AWS free-trial credits which cover this.

### Why Ollama for CI

- CI runs on GitHub Actions; using Groq/Bedrock in CI means:
    - flaky tests when rate limits are hit,
    - API keys shared with GH secrets (small but real security surface),
    - test runs cost money if using Bedrock.
- Ollama runs a tiny model (phi-3-mini, ~2 GB) locally in the CI runner or in a service container.
- The tests don't care about *quality* of RCA — only that the response parses as valid `RCAResponse` schema.

### Strategy pattern

```python
class AIBackend(Protocol):
    def generate_rca(self, prompt: str, context: dict) -> RCAResponse: ...

# lambdas/shared/ai_backend/groq_backend.py
class GroqBackend:
    def generate_rca(self, prompt, context):
        # calls Groq API with structured output mode
        ...

# lambdas/shared/ai_backend/bedrock_backend.py
class BedrockBackend:
    def generate_rca(self, prompt, context):
        # calls bedrock-runtime.invoke_model
        ...

# lambdas/shared/ai_backend/ollama_backend.py
class OllamaBackend:
    def generate_rca(self, prompt, context):
        # calls http://localhost:11434/api/chat
        ...

def get_backend() -> AIBackend:
    match os.environ["AI_BACKEND"]:
        case "groq":    return GroqBackend(api_key=...)
        case "bedrock": return BedrockBackend(model_id="anthropic.claude-3-haiku")
        case "ollama":  return OllamaBackend(model="phi3")
        case _: raise ValueError(...)
```

This is one of the most demonstrable **system-design patterns** in the whole project (Open/Closed Principle, Strategy pattern) and shows up in every senior interview.

## Response schema (`RCAResponse` — same across all backends)

```python
class RCAResponse(BaseModel):
    likely_cause: str          # 1-2 sentence hypothesis
    evidence: list[str]        # log lines / events supporting the hypothesis
    severity: Literal["low", "medium", "high", "critical"]
    suggested_action: str      # what a human should do
    auto_remediation_key: str | None  # e.g., "oomkilled_bump_memory" or None
    confidence: float          # 0.0 – 1.0
    ai_latency_ms: int
```

Enforced via pydantic; if the model returns invalid JSON we retry once with a "please output valid JSON" reminder, then fall back to a canned "AI failed — see logs" response.

## Consequences

### Positive
- Zero cost by default; Bedrock story available for interviews.
- CI stays deterministic and offline-capable.
- Swapping backends is a `terraform apply` env-var change.
- Interview answer for "how would you avoid vendor lock-in on LLMs?" is *literally the code*.

### Negative
- Three backend implementations = 3× the surface area to maintain.
- Groq free-tier rate limits (~30 req/min) could bite during chaos-test bursts.
- Ollama local model quality is much lower — CI tests only assert schema, not RCA correctness.

### Mitigations
- Rate-limit the RCA Lambda (SQS-based backpressure, or `x-ratelimit-remaining` header awareness).
- CI tests use mock responses for correctness; only schema-parse tests use Ollama.
- If Groq drops the free tier, we swap to Gemini free-tier or Together.ai — same interface.

## References

- [Groq API pricing](https://groq.com/pricing/) (free tier confirmed Aug 2026)
- [Bedrock pricing](https://aws.amazon.com/bedrock/pricing/)
- [Ollama](https://ollama.com/) — local LLM runtime
- Pydantic v2 docs for JSON schema validation
