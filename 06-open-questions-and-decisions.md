# 06 · Open Questions & Decisions

> **Updated 2026-07-17** after org discovery ([07-discovered-engine.md](07-discovered-engine.md)), **two live
> agent runs that verified the engine** ([07 §8](07-discovered-engine.md)), and your direction (**reuse engine,
> build embedded LWC**). Several decisions below are now **resolved** by what we found. Resolved ones are marked
> ✅; the ones still needing your input are marked ⬜.
>
> **Two runtime corrections since the last update:** the save service **returns no price** and **hardcodes its
> validation verdict** — so price/correction surfacing are small NEW build items (not free reuse), and the agent's
> spoken price is **ungrounded** (design the LWC to show a re-queried price). This tightens D5 and adds detail to
> Q9–Q11 below.
>
> **2026-07-19 addition — guided-selling / ask 1.** A live smoke test proved the existing agent is invocable from
> Apex ([PROJECT-JOURNAL.md](PROJECT-JOURNAL.md), 2026-07-19). That reframed ask 1 from an infrastructure problem
> into an architecture choice, now captured as **D8–D11** below. **D8–D10 are resolved; D11 (turn routing) is the
> one open item to confirm before building.**

Two lists: **decisions** (they change what we build) and **open questions the spikes will answer**.

---

## Part 1 — Decisions

### ✅ D1 · Target org & product — RESOLVED
**Org:** `rlm_agent_config_concept` (your project default; API v67.0; Agentforce enabled — a **trial org**, note
expiry). **Product:** **`FESBA Generator Set`** (`01tg80000047iP9AAI`), attributes `DutyRating` (Picklist:
COP/DCC/ESP/PRP), `requiredKW` + other kW Numbers. Full grounding data in [07 §5](07-discovered-engine.md).
*Residual:* stand up / confirm a quote with a FESBA line to test against (Phase 0).

### ✅ D3 · Direction — RESOLVED (you chose: reuse engine, build embedded LWC)
We reuse the existing engine's server-side services and build the **embedded chat panel inside the Product
Configurator flow** — the canvas experience. Not "demo the agent as-is," not "enhance the chat agent."

### ⬜ D2 · Extraction engine — STILL OPEN (narrowed further by testing)
Because we reuse the engine and never call the existing **NGA** agent from Apex ([Gap 13](03-gap-analysis.md)
confirmed the NGA agent isn't Apex-invocable), this is purely: **which grounded model call** does the one-shot
NL→fields extraction? **What testing settled:** on this org's Apex path, `ConnectApi.EinsteinLLM` returns
**markdown-fenced free text — no native structured/JSON output** — and only the **`PromptBuilderPreview`** app
name resolves (no `GenAiPromptTemplate` metadata exists yet). So "structured output" here means **we fence-strip +
validate in Apex against the discovered metadata**, not a schema-guaranteed response. **Recommendation:** grounded
prompt (Prompt Builder template, swappable model, lean fast) + Apex fence-strip + validate; **confirm the exact
entitled model in Spike 2.** See [04 §4](04-corrected-architecture.md).

### ✅ D4 · Interaction model — RESOLVED by the reuse choice
**Auto-apply-with-review**, applying through the existing engine. The engine is save-based, so "advisor-only /
no write" would mean not using it — contradicting your choice. So: agent suggests → rep reviews/edits → Apply
calls the engine (persists + reprices). Review step stays mandatory precisely because Apply is real.

### ✅ D5 · Persistence + repricing — RESOLVED to "persist" (by the reuse choice), with a pricing caveat
The engine's whole value is that it **already** persists correctly (picklist IDs, two-step PST, post-save
readback) **and reprices** — now **runtime-proven** on both a simple change and the DCC + 1500 kW conflict
([07 §8](07-discovered-engine.md)). So persistence + repricing is **in scope** and *already solved*.
**Caveat (corrected):** the save service **does not return the price** — repricing happens in the DB, but to
*show* it we **re-query** the QLI/Quote after save (small new build, [07 §3.1](07-discovered-engine.md)). And
**do not surface the agent's spoken price** — it was proven ungrounded (identical across both runs while the real
`GrandTotal` moved to $59,005). *(Spike 1 may still add an LMS live-preview step before the persisting Apply —
see D-new.)*

### ⬜ D6 · Accept revised success criteria — STILL OPEN
OK to drop "<5s" for a **measured P75 (≤ ~12s on the persisting path) + visible progress**, plus accuracy gates
(≥85% ≥3 valid fields; ≥95% valid picklist values)? See [05](05-project-plan.md) criteria table.

### ⬜ D-new · Apply = direct persist, or LMS-preview-then-persist?
Given the engine persists on apply, do you want: **(a)** Apply immediately calls the save service (simplest,
one round trip, reprices), or **(b)** Apply first pushes values into the session UI via **LMS** for a live
preview, then a separate "Save" persists? (b) is nicer UX but depends on Spike 1 showing LMS drives the standard
component. **My lean:** start with (a); add (b) if Spike 1 shows it's clean.

### ⬜ D7 · Timeline / gating — STILL OPEN (now with a hard deadline)
The build is now **much smaller** (wrap + extract + embed + small price/validation surfacing, not
build-the-stack). Two hard constraints now shape the schedule: **(1) the trial org expires 2026-08-17** (~1 month)
and **(2) it's a production-type org at 0% coverage**, so the first deploy needs Apex tests. Recommendation: run
the two Phase 1 spikes first, gate the full build on them, and **do the spikes now** while the org is healthy.
Comfortable with that? Do you want a migration plan to a fresh org as a hedge against expiry?

---

## Part 1b — Guided-selling decisions (ask 1, added 2026-07-19)

> Context: the panel today only *extracts a configuration*; an informational question ("tell me more about the
> duty rating options") returns *"I couldn't map that…"*. Ask 1 = fill that gap by reusing the real Revenue
> Management agent. The smoke test ([PROJECT-JOURNAL.md](PROJECT-JOURNAL.md), 2026-07-19) proved the agent is
> Apex-invocable with no OAuth/new-agent. These decisions settle *how* to wire it.

### ✅ D8 · Do NOT clone the agent — RESOLVED
We considered cloning `Revenue_Quote_Management` entirely and refactoring it for guided-selling + config. **Rejected.**
- **For explanations:** cloning is pure overhead — the planner routes to `ProductConfiguration` regardless of what
  else lives on the agent; a read-only Q&A gains nothing from owning a copy.
- **For configuration:** cloning is actively *harmful* — the agent's config action `Configure_Product_Attributes`
  writes via **PST** ([07 §2](07-discovered-engine.md)), the exact path our LMS re-architecture abandoned because
  it desyncs the open configurator ([07 §4.4](07-discovered-engine.md), Spike 1 risk).
- **Cost of a clone:** attaching a topic to a new agent makes a **local copy, not a live reference** — edits don't
  propagate, so you maintain two agents in lockstep. Planner bundle also locks on activation. Not worth it for a
  POC with a 2026-08-17 expiry. The *only* thing a clone would enable is **changing the agent's behavior** (its
  topics/instructions/actions are on the protected list and can't be edited in place) — and we don't need that to
  *call* it for answers.

### ✅ D9 · Architecture — RESOLVED: **agent = insight, our engine = apply**
Hard separation of two turns:
- **Informational / guided-selling turn** → the real agent via the `generateAiAgentResponse` Apex wrapper,
  rendered as an assistant text answer. **No review card.**
- **Configuration turn** → the existing grounded-LLM extraction + **LMS-publish** engine, **unchanged** (review
  card + auto-apply clean-gate intact).
- **The agent's PST-based `Configure_Product_Attributes` action never touches the live embedded configurator** —
  that would reintroduce the stale-screen bug our LMS design fixed, and it's non-deterministic, slower
  (P75 ≈ 8–9s), returns unstructured text, and quotes an **ungrounded price** ([07 §3.1](07-discovered-engine.md)).

### ✅ D10 · Guided-selling build shape — RESOLVED & BUILT (2026-07-19)
> **Shipped:** [AgentAdvisorService.cls](force-app/main/default/classes/AgentAdvisorService.cls) +
> [AgentAdvisorServiceTest.cls](force-app/main/default/classes/AgentAdvisorServiceTest.cls) (12 tests, **79%**
> coverage — clears the 75% gate) and the panel wiring, all deployed to `rlm_agent_config_concept`. The design
> below is exactly what was built, with one refinement: the wrapper's live-callout logic was split into an
> injectable **`AgentGateway`** seam (mirroring the `LlmGateway` seam) so the test mocks the agent and burns no
> Einstein credits; the thin bits that need a real `Invocable.Action.Result` are the only uncovered lines.
1. **One new `@AuraEnabled` Apex wrapper class (+ its test).** Wraps
   `Invocable.Action.createCustomAction('generateAiAgentResponse', 'Revenue_Quote_Management')`; sends `userMessage`;
   parses the `agentResponse` JSON (`{"type":"Text","value":"…"}`) to plain text; returns text + `sessionId`.
   **Touches none of the four protected services** and does not call `ConfigEngineController`.
2. **Context passing = prepend a context block** into `userMessage`
   (`CONTEXT: quoteId=… quoteLineItemId=…\n\n<question>`), using the panel's existing `@api quoteId` /
   `quoteLineItemId`. (Verified need: the bare probe returned *"the QuoteLineItem ID … is not valid or not found"*.)
   This mirrors the email agent's proven context-block pattern.
3. **Session continuity:** hold the returned `sessionId` in component state for multi-turn follow-ups.
   **In-memory only** for the POC (no persistence across page reload).
4. **Wrapper handles the platform quirks:** the ~8–9s "thinking…" state; the known
   `isSuccess=true` + generic *"Something went wrong. Try again."* fallback (detect → graceful message, don't
   surface as an answer); debug-log truncation at the callout boundary (capture results structurally, not via
   trailing `System.debug`).
- **Deploy note:** production-type org at 0% coverage → the wrapper's test ships with it and deploys via
  `RunSpecifiedTests`; the test **mocks** the agent call so it doesn't burn Einstein credits or depend on a live session.

### ✅ D11 · Turn routing — REVISED 2026-07-19: **intent-gate THEN extract-first, agent-fallback**
How does the panel decide a message is a **question** (→ agent) vs a **configuration requirement** (→ engine)?
Originally chose **(a)** (extract-first, agent-fallback). A live test exposed its blind spot, so we **added (c)'s
heuristic as a front gate** — the router is now a hybrid of (c) + (a).

- **Why (a) alone wasn't enough (observed 2026-07-19).** Extraction is *greedy on picklist values*. An
  advice-seeking question like *"what do you recommend for a data center"* still contains "data center", which
  matches the DutyRating picklist value **Data Center Continuous (DCC)** → extraction maps ≥1 attribute → the
  config turn fires. With **auto-apply now on by default**, that silently APPLIED DCC instead of letting the agent
  give a reasoned recommendation. The bug is that extract-first only routes to the agent on *zero* mapped
  attributes, but a question can accidentally map one.
- **(c-as-front-gate) — added & shipped.** A conservative, phrase-based heuristic (`_looksLikeQuestion` in the
  LWC) runs in `handleSend` **before** extraction. Advice/recommendation/opinion markers ("recommend", "suggest",
  "which should/would you", "what's best for", "help me choose", "should I", "tell me more", "explain", …) and
  interrogative openers / a trailing "?" route the message straight to the agent (`_askAgentFallback`).
  Everything else falls through to extraction. **Zero Apex change, no added latency/cost, no LLM call.** Tradeoff:
  a phrasing the marker list doesn't cover could still slip through to extraction — tunable, and the follow-up
  below addresses it more robustly.
- **(a) still runs behind the gate.** Non-question messages take the extraction path exactly as before, INCLUDING
  its own zero-mapped agent fallback in `_handleExtractionResult`. So there are now two routes to the agent: the
  up-front intent gate (advice phrasing) and the post-extraction fallback (mapped nothing).
- **Follow-up — BUILT & DEPLOYED 2026-07-20 (was deferred).** The heuristic front gate missed real questions
  whose phrasing it didn't enumerate (observed: *"tell me how much full load do I need for a large data center"* —
  no marker matched, so it fell through to extraction and auto-applied DCC). Fix shipped: intent detection now
  lives in the **extraction LLM call itself**. `ConfigExtractionService.buildGroundedPrompt` instructs the model to
  classify the message `CONFIGURE | ASK` and return `{"intent":..,"fields":{..}}`; `ExtractionResult.intent`
  carries it back. On `ASK`, field validation is **skipped entirely** (no proposedFields), so a greedily-matched
  picklist word in a question can't become an applied change. The LWC routes `res.intent === 'ASK'` →
  `_askAgentFallback`. Robustness details: parsing tolerates the legacy flat `{devName:value}` shape too
  (`readFields`), an unrecognized/absent intent **defaults to CONFIGURE** (a misread directive still gets the
  reversible review path; never silently swallow a config request), and the deterministic keyword **fallback always
  reports CONFIGURE** (it can't reason about intent). The `_looksLikeQuestion` heuristic is **kept as a free
  pre-filter** — obvious questions skip the callout; the LLM intent is the backstop for everything it misses.
  Deployed to `rlm_agent_config_concept`; `ConfigExtractionServiceTest` = 24 tests green, service at 87% coverage.
  > **Implemented in [configChatPanel.js](force-app/main/default/lwc/configChatPanel/configChatPanel.js):**
  > `handleSend` calls `_looksLikeQuestion(text)` first → `_askAgentFallback(...)` on a hit. The zero-mapped
  > branch of `_handleExtractionResult` still calls `_askAgentFallback(...)` as the fallback. `ASKING` phase drives
  > the "Asking the assistant…" state; `_agentSessionId` held in memory for multi-turn. Server side unchanged =
  > **`AgentAdvisorService.askAgent`** (below).
- **(b) Explicit mode UI** — an "Ask" vs "Configure" affordance. Deterministic/transparent, but adds UI and makes
  the rep self-classify every message. Not chosen.
- **Post-recommendation behavior (confirmed 2026-07-19):** the agent's answer is shown as a chat reply and nothing
  is auto-applied from it — the rep then types a directive ("set duty rating to DCC") to apply. Keeps the D9
  insight/apply separation clean; no free-text-answer parsing.

---

## Part 2 — Open questions the spikes/build will resolve

These are **[verify]** items — do not treat as settled.

### On the configurator + LMS (Spike 1)
1. Does the **standard Product Attributes component visibly re-render** on a third-party LMS `VALUE_CHANGE`, or
   are third-party components intended to **replace** it rather than feed it? (Gap 18)
2. Exact LMS payload/field semantics for **picklist** attributes in a live session — is the value ID required in
   the LMS event too, or only in PST? (Confirm against the third-party LMS doc + real behavior.)
3. Can our chat LWC and the standard attribute component **coexist on one screen**, exchanging data both ways?
4. Governor/volume limits on LMS events per session; any throttling on bulk attribute updates.

### On extraction (Spike 2)
5. Real **schema-adherence & valid-value rate** for the chosen model with grounding, on messy FESBA phrasing.
6. Best **grounding channel** for picklist values — inline in the JSON-schema enum, in the system prompt, or
   both? (Grounding data comes from the engine's `Get_Product_Attribute_Options` output.)
7. Retry policy when JSON is malformed or a field is invalid — how many retries before failing gracefully?
8. Which extraction model is **entitled in this trial org** (D2)?

### On save/pricing (engine reprices — but we build the surfacing)
9. What **price** does the rep see on apply? **Resolved mechanism:** the save service returns **no price**, so we
   **re-query** the root QLI (`ListPrice/UnitPrice/TotalPrice`), the added/removed BOM child lines, and
   `Quote.GrandTotal` after save. Runtime example: DCC + 1500 kW moved `GrandTotal` to **$59,005** while the
   root-line price stayed $49,450/$44,505 — the change was in **child lines**. Open: how much of the child-line
   breakdown do we show the rep? ([07 §3.1, §8](07-discovered-engine.md))
10. ✅ **Confirmed at runtime:** the FESBA kW (Number) + DutyRating (Picklist) combo triggers the **two-step PST**
    path and resolves correctly (1500 kW persisted, BOM swapped to the 1500kW child, no revert). (Gap 15)
11. How do we surface a **CML auto-correction**? **Resolved mechanism:** the service hardcodes `isValid=true` /
    `validationErrorsJson='[]'`, so we can't read a verdict from it — instead **diff the post-save readback against
    the requested values** to detect and explain changes (e.g. derived `reserveCapacityKW`/`surgeLoadKW`, a swapped
    BOM component). Open: wording/UX for the explanation. (Gap 14)

### On wrapping the engine (Phase 2)
12. Refactor each service's core into a shared method callable by both the existing `@InvocableMethod` and a new
    `@AuraEnabled` method — confirm no behavior divergence from what the agent uses today.
14. **Deploy blocker:** this is a **production-type org** (`IsSandbox=false`) with **0% Apex coverage**. Deploying
    the wrappers needs ≥75% coverage + green tests. Confirm we write tests alongside the wrappers and deploy with
    `RunSpecifiedTests`. ([07 §1](07-discovered-engine.md))
15. **Multi-product scale:** the two services disagree on picklist field (discovery emits `Name`, save keys on
    `Value`). Harmless on FESBA (Name==Value) but a silent-revert bug elsewhere. Align on one field before
    claiming "scalable to other configurable products," and test a second product. ([07 §5](07-discovered-engine.md))

### On governance (production, not POC)
13. Do AI-populated, revenue-affecting quotes need to respect existing **approval policy / thresholds**? What
    must the **audit log** capture to satisfy compliance? (Gaps 19, 22)

---

## Suggested decision order

1. ✅ **D1, D3, D4, D5** — resolved by discovery + your direction + runtime verification.
2. ✅ **D8, D9, D10, D11** — guided-selling: no clone; agent=insight/engine=apply; build shape fixed **and shipped**
   (2026-07-19). Turn routing = extract-first, agent-fallback, deployed. **Ask 1 is functionally complete pending a
   live rep test** (see the journal's resume block).
4. ⬜ **D2** — confirm the entitled extraction model (mechanism now known: fenced text + Apex-validate), then pick.
5. ⬜ **D6 + D-new** — agree the success bar and the apply-vs-preview UX.
6. Run the **two Phase 1 spikes** → confirm **in-session** re-render / graph reconciliation (Spike 1) +
   accuracy/latency (Spike 2).
7. ⬜ **D7** — confirm gating the (now smaller) build on spike outcomes, given the **2026-08-17 expiry** + the
   **production-org test baseline** needed to deploy.

> **Guided-selling (ask 1) is BUILT & DEPLOYED (2026-07-19).** The wrapper class + test, the context-block format,
> and the session handling (all specified in D10) shipped to `rlm_agent_config_concept`. Only remaining step:
> a **live rep test** in the configurator flow to confirm a real question ("tell me more about the duty rating
> options") now returns a grounded agent answer instead of the dead-end message.
>
> Separately, once you confirm **D2, D6, D-new, D7**, I can turn the *configuration* track into concrete tickets:
> the `@AuraEnabled` wrapper signatures (+ the Apex tests needed to deploy them into this production-type org),
> the extraction prompt + Apex-validation schema (grounded in the real 10 FESBA attributes), the ~50-prompt eval
> set with its answer key, and the **in-session** Spike 1 test harness for the embedded LWC in
> `Agent_Product_Configurator_Flow`.
