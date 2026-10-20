# Module 12 — Interview prep + project retro + v1.0 release notes

> **Build-time record.** Written while this module was built. Of the three artifacts, only [`docs/12-release-notes-v1.0.md`](../12-release-notes-v1.0.md) is in the public repo (updated after the recorded AWS run); the interview prep, retro, marketing notes and `PROJECT_CONTEXT.md` are kept outside it.

> **Scope.** Close the project. Ship three artifacts that turn the code into a portfolio narrative: an interview-prep spoken script, an honest post-mortem, and draft v1.0 release notes.
>
> **Goal.** Anyone reading the repo six months from now — recruiter, hiring engineer, or future me — can find the *why* behind every decision in one of three places: the retro (post-hoc reflection), the interview-prep (spoken defense), or the release notes (published summary).
>
> **Cost.** $0/mo. Docs only. No code, no infra, no tests.

---

## 1. Why Module 12 exists as a separate module

Modules 0-11 shipped code + tests + docs per feature. But nothing pulls it into a **portfolio narrative**. The retro, interview prep, and release notes serve three different audiences:

| Audience | Reads | Answers |
|---|---|---|
| **Recruiter (30-sec skim)** | README + release notes | "What is this? Does it work? Is it done?" |
| **Hiring engineer (5-min deep dive)** | Architecture diagram + retro §1-3 | "What decisions did they make? What did they cut?" |
| **Technical interviewer (30-min screen)** | Interview prep + module runbooks | "Can they defend the design under questioning?" |
| **Future me (6-month re-read before an interview)** | Retro + interview prep | "What was the state of the world when I made these calls?" |

Without Module 12, the fifth question ("can they defend the design?") has no rehearsal artifact and the fourth ("can I re-load the project mentally?") requires reading 15 module runbooks.

---

## 2. What Module 12 ships

### 2.1 `docs/12-interview-prep.md` — anticipated interview questions

**Structure** — 6 sections × ~40 questions total. Every question has:
- A **30-second answer** — the recruiter-screen version, said out loud.
- A **3-minute answer** — the technical follow-up, with references to specific ADRs / module runbooks / code files.

**Sections**:
1. Behavioral / project narrative — walk-me-through, elevator pitch, target user, timeline, hardest bug fixed.
2. Architecture-level — Why K3s, Why Groq, Why Node IAM, Why aggregator Lambda, walk-through of a crash-to-Slack flow, why event-driven.
3. Component deep dives — controller design, RCA Lambda internals, HMAC verification math, MTTR aggregator eligibility rules.
4. Ops / cost / security — cost monitoring, teardown model, 10× scale failure points, secret handling, CI/CD, incident-response runbook.
5. "What would you do differently" — what to add with more time, what to refactor, what got cut and why, what you learned, senior-eng critique.
6. Curveballs — why not managed AIOps, LLM hallucination, why no service mesh, timeout failure mode, why not Kyverno/OPA, biggest architectural risk, message to past-me.

**Plus**: quick-reference card (10 questions with 5-word answers, for last-minute practice), and a "what to bring to the interview" packing list.

**Design decisions:**
- **30-sec answers memorized, 3-min answers scripted.** Recruiters watch first 30 s of any answer; the 3-min version is only for when they say "tell me more". Optimizing both is the trade-off.
- **Every answer includes a specific file/line reference** where possible. "How does HMAC work?" → points at `remediator/verify.py`. Concrete beats abstract.
- **Curveballs section included.** Real interviewers ask "why NOT this managed tool" and "what's your biggest risk" and I want prepared answers, not improvised ones.

### 2.2 `docs/12-retro.md` — honest post-mortem

**Structure** — 8 sections:
1. **What worked** — 7 patterns to keep (Makefile as entry point, free-tier constraint, docs-as-source-of-truth, static-then-executable verification, reusable TF modules, devcontainer, Groq + stdlib).
2. **What didn't / hurt** — 6 pain points (Windows CRLF, Terraform `any` types, PowerShell quoting, test drift with wall-clock, Grafana Cloud IAM juggling, Loom recording still theoretical).
3. **What got cut and why** — 6 rejected features (Fluent Bit, IRSA on K3s, Bedrock, Module 7.1 executor, Module 8.1 release pipeline, Prometheus self-hosted). Each with the trade-off and where it's documented.
4. **Lessons per pillar** — 8 pillars: IaC, K8s, Serverless, Observability, Security, Docs, Testing, CI/CD. Each with a "do" list and a "don't" list.
5. **What I'd do differently on day one** — 5 concrete regrets (executable verification from day one, change-log format decided upfront, explicit TF types, `.gitattributes` before first .sh file, cost tracker with headroom column).
6. **What I'd change about scope** — would keep / would trim / would add.
7. **Numbers** — 13-row metrics table (modules, tests, LoC per language, AWS services used vs skipped, elapsed time, cost delta).
8. **Closing** — why the me-of-6-months-ago is worth hiring based on this repo.

**Design decisions:**
- **Honesty over polish.** Section 2 admits things worked poorly: Windows CRLF caught me 3 times, PowerShell quoting fought me, the Loom is still theoretical. Marketing docs cover "why to buy"; retros cover "what actually happened".
- **Per-pillar "do / don't" lists.** More useful than prose — a reader can skim just the pillar relevant to their interview.
- **Numbers table as ammunition.** "155 tests" is a concrete recruiter-friendly artifact; buried in prose it's forgettable.

### 2.3 `docs/12-release-notes-v1.0.md` — draft GitHub release notes

**Structure** — TL;DR + What's included (Infrastructure / K8s / Serverless / Observability / CI/CD / Docs) + Numbers + 4 design decisions + Deferred features + Upgrade path from "portfolio demo" to "production candidate" + Tagging checklist + Acknowledgements.

**Design decisions:**
- **File is a draft, not a live tag.** As of Module 12 the repo isn't on GitHub yet. Publishing the tag is a 4-command checklist at the bottom of the file, ready to execute once the repo is on GitHub.
- **Upgrade path section included.** Recruiters (and interviewers) reasonably ask "what would you do to prod-harden this?". Having a written answer with 7 concrete steps is better than an improvised "well, I'd migrate to EKS I guess...".
- **Deferred features listed explicitly.** Not shipping something is a design decision. Naming what's NOT shipped and why is more mature than pretending everything is done.

### 2.4 `README.md` status bump

Single line change — "Modules 0-10 complete" → "Modules 0-12 complete · **v1.0**". README already has all the substantive M11 content (architecture diagram, 4 design decisions, doc map, etc.).

### 2.5 `docs/REFERENCE.md` + `PROJECT_CONTEXT.md`

- REFERENCE §11 gets a Module 12 change-log row.
- REFERENCE "Currently completed" line bumped to include 12.
- PROJECT_CONTEXT §13 status line bumped to "Modules 0-12 complete".
- PROJECT_CONTEXT "Immediate next step" changes to "record the Loom" (out-of-repo action) or "post the LinkedIn / X release announcement".

---

## 3. Design decisions worth calling out

### 3.1 Three artifacts, not one

Initial temptation: write "docs/12-project-summary.md" as one big file. Rejected because:
- **Different reading contexts.** The interview prep is for read-and-speak (spoken); the retro is for read-and-reflect (analytical); the release notes are for read-and-scroll (recruiter's landing page).
- **Different maintenance cadences.** The retro is a snapshot (never updated). The interview prep gets refreshed before each interview cycle. The release notes get republished per version.

### 3.2 Interview prep has both 30-sec AND 3-min answers

**Rejected**: only 30-sec (too shallow when interviewer digs) or only 3-min (unbounded rambling under screen pressure).

**Chose**: both, structured. First bullet = 30-sec. "3 min" callout = follow-up script. Practice the 30-sec until reflex; keep the 3-min in memory as a graceful expansion.

### 3.3 Retro has "what didn't work" front and center (§2)

**Rejected**: putting "what worked" first and burying pain points at the end.

**Chose**: pain points get their own top-level section. Honest retros are more valuable to future-me than marketing retros; the interviewer's next question is often "and what didn't work?" — I want that answer to have a paper trail.

### 3.4 Release notes as a *draft* file, not a shipped tag

**Rejected**: pretending to tag `v1.0` when the repo isn't on GitHub yet.

**Chose**: draft file in the repo. Tagging + publishing is a bash checklist at the bottom, executed when the repo is actually pushed. Ships the *narrative* without shipping a fake artifact.

### 3.5 "Upgrade path" section in release notes

**Rejected**: only listing what's IN v1.0 and stopping there.

**Chose**: 7-step upgrade path from portfolio demo to production candidate. Answers the interviewer's follow-up question ("what would you do to make this real?") before it's asked.

---

## 4. Verification

- All three new files render on GitHub-flavored Markdown (code fences balanced, tables aligned, no orphan headings).
- Interview prep + retro + release notes cross-reference `docs/adr/`, `docs/modules/`, `docs/06-cost-tracker.md`, `docs/07-marketing.md` — every link resolves.
- The tagging checklist in the release notes uses commands that are already in the project (`make lint validate test`, `git tag`, `gh release create`) — no new tooling.
- Line endings LF-only.

---

## 5. What's still manual after Module 12

None of these block the code or the "does it work" story:

1. **Publish the repo to GitHub.** `make init-repo` from Module 0 handles the initial push.
2. **Record the Loom.** `docs/11-loom-script.md` has the word-for-word narration and take-checklist.
3. **Create the v1.0 tag.** 4-command checklist in `docs/12-release-notes-v1.0.md`.
4. **Post the LinkedIn / X release announcement.** Template in `docs/07-marketing.md`.
5. **First real interview.** Practice with `docs/12-interview-prep.md`.

---

## 6. Change-log

| Date | Change |
|------|--------|
| 2026-08-26 | Initial ship: `docs/12-interview-prep.md` (40 questions × 2 answer lengths), `docs/12-retro.md` (8 sections, 13-row metrics table), `docs/12-release-notes-v1.0.md` (draft GitHub Release + tagging checklist), `docs/modules/12-interview-retro-release.md` (this runbook). README status bumped to "Modules 0-12 complete · v1.0". PROJECT_CONTEXT + REFERENCE change-log rows added. **Project complete.** |
