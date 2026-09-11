# 04 · Corrected Architecture

This replaces the canvas's data flow with one that works against the real, attribute-driven RLM Product
Configurator. It presents **three options**, a **recommendation**, the **end-to-end flow**, the **component
inventory**, and the **contracts** each piece must honor.

---

## 1. The two independent decisions

The architecture is really two orthogonal choices. Don't conflate them.

**Decision A — how does the LWC get structured fields from natural language?**
- **A1. Full Agentforce agent** (~~Legacy Bot~~ — **any type; see 2026-07-19 note below**) via
  `generateAiAgentResponse` from Apex.
- **A2. Grounded Prompt Template / model call** via `ConnectApi.EinsteinLLM` or Gateway structured output. ✅ *recommended for POC*

> ⚠️ **UPDATE (2026-07-19):** A1 and A2 are **no longer mutually exclusive** — the build now uses **both, for
> different turns.** A live smoke test proved the existing NGA/Employee agent is invocable from Apex via
> `generateAiAgentResponse` (no Legacy Bot, no OAuth). Plan: **A2** (grounded `EinsteinLLM`) stays the engine
> for the deterministic *extract-and-apply* turn; **A1** (the real agent) powers the *guided-selling / Q&A* turn.
> See [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) (2026-07-19).

**Decision B — how do suggested values get into the configurator UI (and optionally saved)?**
- **B-opt-A. Flow reactivity only** — works *only* if target fields are standard Flow components (they aren't, in the managed configurator). ❌ not viable inside managed UI
- **B-opt-B. LMS → Data Manager** — inject values into the standard managed configurator. ✅ *recommended*
- **B-opt-C. Custom configurator UI on Configurator API + LWC wire adapter** — full control, more build. *fallback*

> Recommended combination for the POC: **A2 + B-opt-B**. Rationale in [01 §3](01-executive-summary.md).

---

## 2. Recommended end-to-end flow (A2 + B-opt-B)

```
┌─────────────────────────── Product Configurator Screen Flow (cloned) ───────────────────────────┐
│                                                                                                  │
│   [ Standard: Product Attributes ]        [ Custom LWC: rlmConfigAssistant (chat panel) ]        │
│   [ Standard: Data Manager (hidden) ]              │  1. user types requirement                  │
│                    ▲                               │                                             │
│                    │ 5. LMS VALUE_CHANGE           ▼  2. imperative Apex call                     │
│                    │      (in-place update)   ┌──────────────────────────────┐                   │
│                    └──────────────────────────│  Apex: ConfigAssistantCtrl   │                   │
│                                               │  a. discover attr metadata   │──► AttributeDefinition
│                                               │     (+ picklist value IDs)   │    AttributePicklistValue (SOQL)
│                                               │  b. ground prompt w/ allowed │                   │
│                                               │     values + API names       │                   │
│                                               │  c. call EinsteinLLM /        │──► Einstein/Gateway
│                                               │     Gateway (JSON schema)     │    (structured output)
│                                               │  d. validate output vs meta  │                   │
│                                               │  e. (opt) Run Config Rules   │──► Constraint/Config rules
│                                               │  f. return typed suggestions │                   │
│                                               └──────────────────────────────┘                   │
│   3. LWC shows REVIEW panel (editable, warnings, price note)                                     │
│   4. user clicks Apply ─────────────────────────────────────────────────────────────────────────┤
│                                                                                                  │
│   6. (ONLY if persisting) Apex → PlaceSalesTransactionExecutor  ──► saves QLIA + BOM + PRICING   │
│      then re-query to confirm no silent revert; surface price delta in the panel                 │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Why the Apex hop is non-negotiable:** it solves CORS (Gap 3), lets us **ground** the prompt in real metadata
(Gap 8/11), **validate** output server-side (Gap 4), and keep secrets/session handling off the client.

**Live-preview vs persist:** step 5 (LMS) updates the *session* UI without saving; step 6 (PST) *persists* and
*reprices*. The POC can stop at step 5 to legitimately keep "no repricing" (Decision D5, doc 6). If we persist,
Gaps 5/6/15 apply in full.

---

## 3. Options compared

### Option A — Flow reactivity only ❌ (documented here to explain why it's rejected)
Fire `FlowAttributeChangeEvent`; standard reactive components update in place.
**Fails because** the configurator's fields are the **managed Product Attributes component**, not standard Flow
inputs bound to variables ([02 §B1, §D2](02-research-findings.md)). Reactivity is still used *within* our own
LWC, but it can't drive the managed attribute fields. Keep only if we build entirely custom fields (→ that's
Option C).

### Option B — LMS → Data Manager ✅ recommended
Custom LWC publishes `VALUE_CHANGE` LMS events; the Data Manager applies them to the standard components.
- **Pros:** keeps the **standard managed configurator UI**; least reinvention; the documented, supported
  third-party extension path ([02 §C1, §C2](02-research-findings.md)).
- **Cons/risks:** whether the standard Product Attributes component **visibly reflects** every LMS update is
  **[verify]** — the crux of Spike 1. Must respect "component must not call Save APIs directly."
- **Persistence:** still via PST (Apex), separate from the LMS live update.

### Option C — Custom configurator UI on Configurator API + LWC wire adapter (fallback)
Build the attribute UI ourselves using the Configurator REST/wire API (Configure / Update Nodes / …).
- **Pros:** total control over rendering, reactivity, and update semantics; no dependence on the managed
  component reacting to LMS.
- **Cons:** significantly more build; we re-implement attribute rendering, categories, option groups, messages;
  higher maintenance. Reserve for when B is proven insufficient in Spike 1.

| Dimension | A (reactivity only) | **B (LMS → Data Manager)** | C (custom UI on Config API) |
|-----------|--------------------|----------------------------|-----------------------------|
| Works with managed attribute fields | ❌ No | ✅ Yes (pending Spike 1) | ✅ Yes (we render them) |
| Build effort | Low | **Medium** | High |
| Keeps standard configurator UX | n/a | ✅ | ❌ (rebuilt) |
| Reflect-update risk | — | 🟡 verify in Spike 1 | 🟢 controlled |
| Recommended | No | **Yes** | Fallback |

---

## 4. Extraction engine comparison (Decision A)

| | A1 · Full Agent (Legacy Bot) | **A2 · Grounded Prompt / EinsteinLLM / Gateway** |
|--|------------------------------|--------------------------------------------------|
| Fit for one-shot NL→fields | Overkill | ✅ Purpose-fit |
| Structured output | `outputText` text → parse; or `GenAiFunction outputSchema` | ✅ `response_format` + JSON schema, `strict:true` |
| Latency | Highest (planner+topic+action, P75 ≈ 8–9s) | Lower (single call) |
| Determinism / testability | Non-deterministic routing; harder | ✅ More deterministic; easy to eval |
| Multi-turn dialog | ✅ Native | ➖ Add later if needed |
| Invocation from Apex | `generateAiAgentResponse` (~~Legacy Bot only~~ — **invoked this org's NGA agent OK, 2026-07-19**) | `ConnectApi.EinsteinLLM` / Gateway |
| **POC pick** | Phase 2 option | ✅ **Recommended** |

Both still require **Apex-side validation + grounding** — the model must be constrained to the product's real
attribute API names and allowed picklist values ([02 §F3](02-research-findings.md)).

---

## 5. Component inventory (recommended build)

| Component | Type | Responsibility |
|-----------|------|----------------|
| `rlmConfigAssistant` | Custom **LWC** (third-party configurator UI component) | Chat input, calls Apex, renders **review/edit** panel, publishes **LMS `VALUE_CHANGE`** on Apply, loading/error states, revert |
| `ConfigAssistantController` | **Apex** (`@AuraEnabled`) | Orchestrates: metadata discovery → prompt grounding → model call → validation → (opt) Run Config Rules → return typed suggestions |
| `AttributeMetadataService` | **Apex** | Query `AttributeDefinition` + `AttributePicklistValue` for the product; cache; expose `{label→{devName,dataType,picklistValues[]}}` |
| `ExtractionService` | **Apex** | Wrap `ConnectApi.EinsteinLLM` / Gateway with JSON-schema structured output + retry; parse + type-coerce |
| `SuggestionValidator` | **Apex** | Validate each field vs metadata (valid picklist value? in range? known attribute?), fuzzy-match, flag |
| `AttributePersistenceService` | **Apex** (only if persisting) | Build PST payload incl. `AttributePicklistValueId`; two-step sequencing (Number then Picklist); re-query to confirm; return price delta |
| `AgentConfigLog__c` | **Custom object** | Audit: NL input, model output, applied values, accepted/edited, user, timestamps |
| Cloned **Product Configurator Flow** | **Flow** | Hosts standard components + `rlmConfigAssistant`; set API v59+, "Revisited Screen Values → Refresh inputs" |

---

## 6. Key contracts (get these right and the rest follows)

**LWC ⇄ Apex (suggestion request):**
```jsonc
// request
{ "quoteLineItemId": "0QL...", "product2Id": "01t...", "utterance": "prime power, 500kW, max 90dB, 220/380V" }
// response (typed, already validated server-side)
{ "suggestions": [
    { "attributeDeveloperName": "ATTR_DUTY_RATING", "dataType": "Picklist",
      "value": "Prime Power (PRP)", "attributePicklistValueId": "0tj...",
      "valid": true, "confidence": "high" },
    { "attributeDeveloperName": "requiredKW", "dataType": "Number", "value": 500, "valid": true, "confidence": "high" }
  ],
  "unmapped": ["max 90dB → no matching attribute"], "warnings": [], "latencyMs": 1840 }
```

**LWC → Data Manager (LMS `VALUE_CHANGE`, on Apply):** payload per [02 §C2](02-research-findings.md) — must
carry `attributeId` and, for picklists, the resolved value; bulk array for multiple attributes.

**Apex → PST (only if persisting):** include `AttributeValue` **and** `AttributePicklistValueId` for picklists;
sequence Number-then-Picklist if they conflict; **re-query `QuoteLineItemAttribute` after** to detect silent
revert ([02 §C3–C5](02-research-findings.md)).

**Model structured-output schema:** enumerate allowed picklist values *inline* per field so the schema itself
constrains output; `strict:true`, `additionalProperties:false`.

---

## 7. Non-functionals & platform constraints to honor

- **Governor limits:** metadata SOQL is light, but cache per transaction; PST is heavy — one (or two) calls per
  Apply, never per keystroke.
- **Latency budget (grounded-prompt path, illustrative):** model 1–3s + validation <0.2s + LMS <0.1s
  (+ PST/pricing 1–3s if persisting). Plan **P75 ≤ ~10s**, show progress.
- **Org prereqs:** RLM + Product Configurator enabled; API v59+; FlowRuntimeV3 on; target product fully modeled.
- **Security:** Apex hop keeps calls server-side; respect FLS/CRUD on attribute + quote objects; the
  third-party LWC **must not** call Save APIs directly (LMS only).
- **`getSessionId()` null in agent Apex** ([02 §E5](02-research-findings.md)) — a reason the LWC→Apex→model path
  is cleaner than agent-first; if we ever go agent-first, avoid session-authed callouts inside the agent.
