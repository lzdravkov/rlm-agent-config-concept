# 01 · Executive Summary

**Project:** Agentforce-powered natural-language assist embedded in the RLM Product Configurator
**Goal (unchanged from canvas):** Let a user describe requirements in plain language and have the relevant
configuration attributes pre-populated in the configurator, with the user reviewing before committing.

> **⚙️ Status update (2026-07-20): the POC is BUILT & DEPLOYED and verified working** in
> `rlm_agent_config_concept`. This summary captured the *pre-build* feasibility verdict; every "recommend / spike /
> go-no-go" note below has since been acted on. The corrected architecture in §2 is what was built. Both turns are
> live: the **configuration turn** (grounded extraction → review/auto-apply → LMS `valueChanged` publish) and the
> **guided-selling turn** (the real Revenue Management agent, reached via an Apex wrapper, with intent routing).
> **Current state and findings live in [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) and
> [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md).**

---

## 1. Is the idea feasible? — Yes, but not as drawn

| Canvas premise | Verdict | Note |
|----------------|---------|------|
| RLM configurator is an editable Screen Flow | ✅ **Confirmed** | "Default Product Configurator Flow", cloned via Setup → Flows → Save As |
| A custom LWC can be embedded in it | ✅ **Confirmed** | Supported as a "third-party configurator UI component" |
| Config fields are Flow variables the LWC can set via `@api` outputs | ❌ **Refuted** | They are **product-attribute metadata**, updated via LMS events / PST API |
| "`FlowNavigate` re-renders the current screen" | ❌ **Refuted** | No such event/behavior; use **reactivity** + **LMS**, not navigation |
| LWC calls the Agent API directly and gets JSON back | ❌ **Refuted** | **CORS-blocked**; agent returns **text**, not typed JSON — needs Apex hop + structured-output design |
| Price recalculation is out of scope | ⚠️ **Incoherent if we persist** | Saving attributes via PST **atomically re-runs pricing**; can't be excluded once we save |
| Round trip < 5 seconds | ❌ **Unrealistic** | Agent P75 ≈ 8–9s; with save+pricing, plan for 10–15s or change the pattern |

**Bottom line:** the vision is achievable and worth a POC. The canvas is best treated as a *vision doc*; the
*architecture* needs to be replaced. Nothing here kills the project — but building the drawn architecture
literally would fail at the integration layer before demoing any value.

---

## 2. Corrected architecture at a glance

```
User types requirement in chat-panel LWC (embedded in Product Configurator Flow)
        │
        ▼  (imperative Apex call — NOT a direct browser→API call)
Apex controller
   • loads the product's REAL attribute metadata (AttributeDefinition + AttributePicklistValue)
   • grounds the model prompt with valid attribute API names + allowed picklist values
   • invokes the extraction engine  ── recommended: Prompt Template / Einstein LLM (ConnectApi.EinsteinLLM)
        │                              (a full conversational Agent is optional / Phase 2)
        ▼
   • receives + validates structured output against the metadata (reject/fuzzy-match invalid values)
   • returns a typed suggestion set to the LWC
        │
        ▼
Chat-panel LWC shows a REVIEW panel (proposed values, editable, with any price/constraint warnings)
        │  user clicks "Apply"
        ▼
LWC publishes LMS VALUE_CHANGE event(s) to the configurator Data Manager  ── in-place UI update, no reload
        │  (and, to persist, Apex calls PlaceSalesTransactionExecutor — which re-runs BOM rules + pricing)
        ▼
Configurator fields update reactively; user reviews price impact; saves normally
```

**What changed vs. the canvas, in one line each:**
- **Agent invocation:** direct LWC→API ➜ **LWC→Apex→model**, with prompt grounded in real metadata.
- **Structured output:** "agent returns JSON" ➜ **explicit structured-output/schema + Apex-side validation**.
- **UI update:** `FlowNavigate` re-render ➜ **LMS events to Data Manager** (and/or Flow reactivity).
- **Field write / persistence:** set Flow variables ➜ **LMS for live UI**, **PST API to save** (pricing runs).
- **UX:** one-click "Apply" ➜ **suggest → review/edit → apply**, because AI values touch price and validity.

---

## 3. Recommended path

**Extraction engine — recommend a grounded Prompt Template / Einstein LLM call, not a full Agent (for the POC).**
The task is one-shot NL→structured-fields extraction. A full Agentforce agent adds planner/topic/action
overhead, non-deterministic routing, higher latency, and harder testing — with no multi-turn payoff at POC
stage. A grounded prompt call gives strict schema output, lower latency, and deterministic, testable behavior.
*Keep a full agent as a Phase 2 option* if you later want multi-turn dialog ("actually make it 600kW", "find a
quieter option"). **Caveat [verify]:** invocable prompt actions return text that still needs parsing; enforce
JSON with structured-output mode and validate in Apex.

**UI-update mechanism — recommend LMS-to-Data-Manager (Option B),** which lets us keep the *standard* managed
configurator UI and inject values into it. Fall back to a **fully custom configurator UI on the Configurator
REST/wire APIs (Option C)** only if the LMS path can't drive the standard Product Attributes component the way
we need. Building on plain Flow reactivity alone (Option A) is the simplest but only works if the target fields
are standard Flow screen components — which, in the managed configurator, they are **not**. See
[04-corrected-architecture.md](04-corrected-architecture.md).

**Sequence — spike the three riskiest unknowns before committing to a full build:**
1. Can a custom LWC drive the standard Product Attributes component via LMS `VALUE_CHANGE`? (highest risk)
2. What is the *real* end-to-end latency (model + validation + LMS + optional PST/pricing) on the target product?
3. What is extraction accuracy on realistic, messy phrasing (not the cherry-picked demo sentence)?

Each spike has a **kill/continue gate**. If spike 1 fails, we pivot to Option C or to an "advisor-only" mode
(agent suggests, user selects manually) — still valuable, far cheaper.

---

## 4. Revised scope & success criteria (headline)

- **In:** chat panel LWC in the configurator flow; grounded extraction to a typed suggestion set;
  **review/edit** step; in-place field update via LMS for the 4 target attributes; validation of suggestions
  against real metadata; basic error/latency handling; audit log of AI-applied values.
- **Newly in (was out):** **price impact is acknowledged and surfaced** if we persist; **metadata mapping**
  (attribute API names + picklist value IDs) is core, not incidental.
- **Realistic success criteria:** ≥85% of realistic prompts map ≥3 valid attributes; applied values are
  **provably persisted** (re-query confirms, no silent revert); **P75 end-to-end ≤ ~10s** with a loading state,
  not < 5s; user can review and reject before anything is applied.

Full detail in [05-project-plan.md](05-project-plan.md).

---

## 5. Go / no-go — ✅ went, and built

**Original recommendation (2026-07-17): GO to a validation phase (Phase 0/1 spikes), not directly to full build.**
The concept is credible and differentiated, the platform supports the required extension points, and the corrected
architecture is well-understood. The risk was concentrated in three testable unknowns; a ~1–2 week spike retires
most of it cheaply. Committing to the *canvas's* architecture as written would be a no-go — it would not function.

**Outcome (2026-07-20):** the three unknowns were retired and the POC was built on the corrected architecture, not
the canvas's. What resolved them:
- **Spike 1 (LMS drives the standard component):** ✅ confirmed — Apply publishes `valueChanged` on
  `lightning__productConfigurator_notification` and the managed Data Manager applies/reprices/re-renders natively.
  This is why the build **publishes into** the configurator rather than writing via PST around it.
- **Latency:** the agent turn runs ~8–9s P75 (matches the <5s refutation); the success bar was reset to a
  measured P75 with a visible progress state.
- **Extraction accuracy + routing:** grounded extraction validates every value against real metadata, and — the
  latest enhancement — the **same grounded call now classifies intent** (`CONFIGURE | ASK`), so advice questions
  route to the agent instead of greedily auto-applying a picklist word. See
  [06 · D11](06-open-questions-and-decisions.md) and the [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) change log.
