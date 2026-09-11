# Architecture — RLM Conversational Product Configurator

> **Status:** ⚙️ **BUILT & DEPLOYED** to `rlm_agent_config_concept` · **As of:** 2026-07-20
>
> This is the **final, as-built architecture** of the POC — a single reference for how the pieces
> fit together and why. It reflects the deployed state, not the original plan. For the *chronological*
> narrative (what changed, when, and how to revert) see [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md); for the
> *decisions and their rationale* see [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md);
> for the *discovered engine internals* see [07-discovered-engine.md](07-discovered-engine.md).

---

## 1. What it is

An **Agentforce-style conversational configuration panel** embedded in the right-hand column of the Salesforce
Revenue Cloud (RLM) Product Configurator. A sales rep types free text; the panel does one of two things depending
on what the rep meant:

- **Configuration turn** — *"~1500 kW, data-center continuous duty, low-voltage"* → maps the text to the product's
  real configuration attributes, shows an editable review card (or auto-applies a clean proposal), and publishes
  the selections into the managed configurator so it applies, reprices, and re-renders natively.
- **Guided-selling turn** — *"what do you recommend for a data center and why?"* → forwards the question to the
  live Revenue Management Agentforce agent and renders its reasoned answer as chat. **Nothing is applied.**

The panel decides which turn to run per message (see [§4 Intent routing](#4-intent-routing--the-turn-decision)).

**Reference org:** `rlm_agent_config_concept` (trial: `trailsignup-e01123b28c25c6`, API v67.0).
**Canonical test data:** Quote `0Q0g80000017wQ5CAI`, root configurable line `0QLg8000001RYgDGAW`
(**FESBA Generator Set**, `01tg80000047iP9AAI`).

---

## 2. System diagram

```
                                   ┌──────────────────────────────────────────────┐
                                   │  Agent_Product_Configurator_Flow (Screen Flow)│
                                   │  right column: c:configChatPanel               │
                                   │  inputs: quoteId, quoteLineItemId              │
                                   └───────────────────────┬────────────────────────┘
                                                           │
                                          ┌────────────────▼─────────────────┐
                                          │        configChatPanel (LWC)      │
                                          │  state machine + intent routing   │
                                          └───┬───────────┬──────────────┬────┘
                          ┌───────────────────┘           │              └──────────────────┐
                          │ (imperative Apex)             │ (imperative Apex)                │ (imperative Apex)
                          ▼                                ▼                                  ▼
        ┌─────────────────────────────┐   ┌──────────────────────────────┐   ┌──────────────────────────────┐
        │ ConfigExtractionService     │   │ ConfigEngineController        │   │ AgentAdvisorService           │
        │ .extractConfiguration       │   │ .getAttributes                │   │ .askAgent                      │
        │                             │   │ .getSavedConfiguration        │   │                                │
        │ grounded Einstein LLM call: │   │  (read-only; grounding source)│   │ wraps invocable custom action  │
        │  • classify intent          │   └──────────────┬────────────────┘   │  generateAiAgentResponse       │
        │    (CONFIGURE | ASK)        │                  │                    │  ('Revenue_Quote_Management')  │
        │  • map fields (if CONFIGURE)│   ┌──────────────▼────────────────┐   └───────────────┬────────────────┘
        │  • validate vs. catalog     │   │ ConfigLmsGroundingService     │                   │
        └──────────────┬──────────────┘   │ .getLmsGrounding              │                   ▼
                       │                   │  attributeId (0tj) +          │        Live Revenue Management
        ProposedField[]│ / intent          │  picklist label→0v6-Id map    │        Agentforce agent (NGA)
                       │                   └──────────────┬────────────────┘        returns TEXT answer + sessionId
                       ▼                                  │
        ┌─────────────────────────────┐                  │ grounds the publish payload
        │  REVIEW card  or  AUTO-APPLY │◄─────────────────┘
        └──────────────┬──────────────┘
                       │  Apply (explicit click, or auto)
                       ▼
        publish( valueChanged ×N,  then  updatePrices )
                       │
                       ▼
        ┌───────────────────────────────────────────────────────────────────┐
        │  LMS channel: lightning__productConfigurator_notification           │
        │  (platform command bus INTO the managed RLM Data Manager)           │
        └───────────────────────────────┬───────────────────────────────────┘
                                        ▼
        ┌───────────────────────────────────────────────────────────────────┐
        │  Managed RLM Data Manager                                           │
        │   applies selections → re-runs BOM rules → reprices → re-renders    │
        │   (persistence = the native configurator's own Save)                │
        └───────────────────────────────────────────────────────────────────┘
```

---

## 3. Request flows

### 3.1 Configuration turn (extract → review/auto-apply → publish)

1. **Panel load.** Three cacheable wires resolve against `quoteLineItemId`: `getAttributes` (the grounding
   catalog + product name), `getSavedConfiguration` (the current-config chip), and `getLmsGrounding` (the
   `attributeId` + picklist label→Id map needed to build the publish payload).
2. **Send.** The rep types a requirement and hits Send. `configChatPanel.handleSend` runs the
   [intent gate](#4-intent-routing--the-turn-decision); a configuration message proceeds to extraction.
3. **Extract.** `ConfigExtractionService.extractConfiguration(requirementText, quoteLineItemId)` makes **one**
   grounded `ConnectApi.EinsteinLLM` callout. The prompt is seeded with the exact legal `developerName`s and
   picklist values from the catalog. The model returns `{"intent":"CONFIGURE","fields":{devName:value,…}}`.
4. **Validate.** Every returned key/value is re-checked against the catalog: hallucinated attributes are dropped,
   illegal picklist values are flagged, numbers/checkboxes are coerced. Output is a `ProposedField[]`. **No DML.**
5. **Review or auto-apply.**
   - **Auto-apply ON + clean proposal** (LLM-sourced, every row valid and unambiguously groundable) → skip the card
     and go straight to Apply.
   - **Otherwise** → render the editable **review card**; the rep edits/toggles rows, then clicks Apply.
6. **Apply = publish.** For each included+valid row, `configChatPanel` builds a `valueChanged` LMS message and
   publishes it on `lightning__productConfigurator_notification`, **Numbers first, then Picklists** (mirrors the
   engine's proven two-step sequencing), followed by one `updatePrices`. Publish is **fire-and-forget** — there is
   no synchronous price/diff. The managed Data Manager applies, reprices, and re-renders on screen; the native
   panel is the source of truth for the resulting values and price. Persistence is the native configurator's Save.

### 3.2 Guided-selling turn (question → agent → text answer)

1. **Send.** The intent gate classifies the message as a question (`ASK`).
2. **Ask.** `configChatPanel._askAgentFallback` calls `AgentAdvisorService.askAgent(question, quoteId,
   quoteLineItemId, sessionId)`.
3. **Wrap + invoke.** `AgentAdvisorService` prepends a context block (`CONTEXT: quoteId=… quoteLineItemId=…`) into
   `userMessage` and invokes the custom action
   `Invocable.Action.createCustomAction('generateAiAgentResponse', 'Revenue_Quote_Management')`. It parses the
   returned `agentResponse` JSON (`{"type":"Text","value":"…"}`) to plain text and detects the known
   `isSuccess=true` + generic *"Something went wrong"* fallback so it never surfaces a non-answer as an answer.
4. **Render.** The answer is shown as an assistant chat turn (no review card, no apply). The returned `sessionId`
   is held in memory so a follow-up stays in the same agent conversation (multi-turn continuity, POC = in-memory
   only, not persisted across reload).

---

## 4. Intent routing — the turn decision

The panel must decide, per message, whether the rep is **stating a requirement** (configure) or **asking a
question** (guided-selling). This is the crux of the design because extraction is **greedy on picklist values**:
an advice question like *"what do you recommend for a data center"* still contains "data center", which matches the
DutyRating value **Data Center Continuous (DCC)** — so a naive extract-first router maps ≥1 attribute and, with
auto-apply on, would **silently apply DCC** instead of answering the question.

Routing is a **two-layer design** (cheap filter first, robust classifier second):

| Layer | Where | Cost | Role |
|---|---|---|---|
| **1. Heuristic pre-filter** | `configChatPanel._looksLikeQuestion` (LWC) | Free (no callout) | Catches *obvious* questions (advice markers, interrogative openers, trailing "?") and routes them to the agent **before** any Einstein call. |
| **2. LLM intent classification** | `ConfigExtractionService` (grounded call) | Same call that already runs | The **backstop**. The grounded extraction prompt asks the model to classify `CONFIGURE \| ASK` in the *same* callout — no extra round trip. On `ASK`, field validation is **skipped entirely** (no `proposedFields`), so a greedily-matched picklist word inside a question can never become an applied change. |

**Why two layers, not one.** A phrase-based heuristic alone is whack-a-mole — it missed real phrasings like
*"tell me how much full load do I need for a large data center"* (no marker, no opener, no "?"), which then
auto-applied DCC. Moving the decision into the model that already reads the message is robust to arbitrary
phrasing. The heuristic is kept only as a **free fast-path** so clear questions skip the callout latency.

**Fail-safe defaults (in `ConfigExtractionService`):**
- An **absent or unrecognized** intent defaults to **CONFIGURE** — a misread directive still gets the reversible,
  rep-reviewed config path; the system never *silently swallows* a real configuration request as a question.
- The deterministic **keyword fallback** (used when the LLM callout fails) **always reports CONFIGURE** — it
  cannot reason about intent, so advice questions reaching it degrade to the review path exactly as before.
- Response parsing tolerates **both** the new `{"intent":…,"fields":{…}}` shape **and** a legacy flat
  `{devName:value}` object, so a prompt/model change never breaks extraction.

---

## 5. Components

### Ours — authored for this POC (safe to modify)

| Component | Type | Role |
|---|---|---|
| [`configChatPanel`](force-app/main/default/lwc/configChatPanel/) | LWC | **The POC deliverable.** State machine (LOADING → READY → EXTRACTING/ASKING → REVIEW → APPLYING → RESULT), intent routing, review card, auto-apply, LMS publish, agent Q&A. |
| [`ConfigExtractionService`](force-app/main/default/classes/ConfigExtractionService.cls) | Apex | Grounded NL→validated-fields extraction **+ intent classification** in one Einstein callout. Injectable `LlmGateway` seam for tests; deterministic keyword fallback. |
| [`ConfigLmsGroundingService`](force-app/main/default/classes/ConfigLmsGroundingService.cls) | Apex | Supplies `attributeId` (0tj) + picklist **label→0v6-Id** map for the `valueChanged` payload. Per-attribute `ambiguousLabels` collision guard. |
| [`AgentAdvisorService`](force-app/main/default/classes/AgentAdvisorService.cls) | Apex | `@AuraEnabled` wrapper over the `generateAiAgentResponse` invocable custom action. Injectable `AgentGateway` seam for tests. Insight-only — never applies a config. |
| [`ConfigEngineController`](force-app/main/default/classes/ConfigEngineController.cls) | Apex | Thin `@AuraEnabled` orchestration over the protected engine: `getAttributes`, `getSavedConfiguration`, `applyConfiguration` (PST path — now **bypassed** by the LMS publish). **May read; do not change its logic.** |
| `*Test` classes | Apex | Deploy-gate coverage. `ConfigExtractionServiceTest` = 24 tests, service at 87%. All mock their gateway seams so no live Einstein/agent credits are burned. |

### Protected — DO NOT MODIFY / DELETE

These back a **live NGA Agentforce agent** or are the reference flow. Read-only.

| Component | Why protected |
|---|---|
| `ProductAttributeService` | Live invocable behind the NGA agent. Emits picklist label = `Name ?? Code`, exposes `attributeId`. **Our grounding keys on the same `Name ?? Code` expression** so the label→Id join has zero drift. |
| `ProductAttributeSaveService` | Live invocable (label→Id keyed on `Value`, sets `AttributePicklistValueId`). |
| `ProductAttributeReadService`, `QuoteLineItemLookupService` | Live invocables. |
| `renderDraw3DConfigurationPrototype` (LWC) | Reference "Rosetta Stone" for the LMS channel + subscribe/publish/MessageContext wiring. |
| `RenderDraw_Product_Configurator_Flow` (Flow) | The reference configurator flow. |

### Diagnostic / throwaway (scheduled for retirement)

| Component | Status |
|---|---|
| `configRefreshProbe` (LWC) | Diagnostic that subscribes+logs the LMS channel. Kept to capture failure cause if the DM ever rejects an inbound publish. |
| `spikeConfigApply` (LWC) | Earlier throwaway harness, replaced by `configChatPanel`. Referenced only in a comment in the agent flow. |

---

## 6. Key architectural decisions (and why)

1. **Apply publishes `valueChanged` on the managed LMS channel — it does NOT write via PST.**
   The earlier build wrote+repriced through the Place Sales Transaction (PST) API as a side channel. That worked
   at the data layer, but the on-screen managed configurator holds its **own in-memory transaction graph** and
   never noticed the external write — the rep saw a stale *"Prices don't reflect the latest selections"* banner.
   Salesforce's guidance for third-party configurator UI is explicit: **don't call the configurator/save APIs
   directly — route changes through `valueChanged`** and let the Data Manager own apply/reprice/re-render/Save.
   We publish **into** the Data Manager rather than writing around it.

2. **`valueChanged` payload contract** (confirmed from a live native emission + DB readback):
   ```json
   { "action": "valueChanged",
     "data": [{ "key": ["<quoteLineItemId>"], "field": "AttributeField",
                "attributeId": "<0tj… AttributeDefinition Id>",
                "value": "<0v6… AttributePicklistValue Id | raw number | text>" }] }
   ```
   For a **Picklist**, `value` is the **AttributePicklistValue Id (0v6)**, NOT the label — hence the
   `ConfigLmsGroundingService` label→Id lookup. **Number/Text** = raw value; **Checkbox** = boolean.

3. **Agent = insight; our engine = apply (hard separation of two turns).** The guided-selling turn reaches the
   real agent read-only for a spoken answer; nothing it says is auto-applied. The configuration turn is the sole
   write path. We do **not** clone the agent (its config action writes via PST — the exact desync we abandoned) and
   we do **not** parse the agent's free-text answer into a configuration. See [06 · D8–D9](06-open-questions-and-decisions.md).

4. **Grounding is the single source of truth; the LLM is never trusted.** Every value the model returns is
   re-validated against `getAttributes` (legal `developerName`s + picklist values). A hallucinated attribute or
   illegal picklist value cannot reach the review card or the publish payload.

5. **Intent lives in the extraction call, not a word list.** See [§4](#4-intent-routing--the-turn-decision).

6. **Ambiguity blocks rather than guesses.** If a picklist label maps to more than one `AttributePicklistValue`
   Id, Apply refuses that row (rather than coin-flipping a value the Data Manager would silently accept), and
   auto-apply degrades the whole proposal to manual review.

---

## 7. Constraints & operational notes

- **Production-type org at the 75% coverage gate.** `IsSandbox=false`, so any Apex deploy must ship with tests and
  clear ≥75% coverage. All service tests mock their gateway seams (no live Einstein/agent dependency, no credits).
- **LWC caches aggressively.** After any `configChatPanel` redeploy, the rep must **hard-refresh** the flow tab
  (Cmd+Shift+R / close+reopen) or the browser keeps running the old bundle. (This masked a fix once during the
  build.)
- **No git — `backups/` is the only rollback path.** Each change point is snapshotted under a dated folder; see
  the [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) Backups & Revert Protocol.
- **Agent latency ~8–9s P75.** The <5s target from the original canvas was refuted; success is measured as a P75
  with a visible progress state.
- **Trial org expires 2026-08-17.** Plan any longer-lived demo accordingly.

---

## 8. Known gaps (not in POC scope)

- **Audit logging of AI-applied values** — a governance requirement for production (who applied what, when, from
  which suggestion); not built. See [06 · Q13](06-open-questions-and-decisions.md).
- **Approval-policy / threshold enforcement** on AI-populated, revenue-affecting quotes — deferred to production
  hardening.
- **Multi-product scale** — the engine's two services disagree on the picklist field (`Name` vs `Value`); harmless
  on FESBA (where they're equal) but must be aligned before claiming "scalable to any configurable product," and a
  second product should be tested. See [07 · §5](07-discovered-engine.md) and [06 · Q15](06-open-questions-and-decisions.md).
- **Session persistence** — the agent `sessionId` is in-memory only; a page reload starts a fresh conversation.

---

## 9. Where to look next

| For… | See |
|---|---|
| Chronological build log + how to revert | [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) |
| Decisions & their rationale (D1–D11) | [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md) |
| Discovered engine internals (PST, pricing, two-step sequencing) | [07-discovered-engine.md](07-discovered-engine.md) |
| Original feasibility verdict + corrected architecture | [01-executive-summary.md](01-executive-summary.md), [04-corrected-architecture.md](04-corrected-architecture.md) |
