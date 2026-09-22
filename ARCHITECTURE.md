# Architecture — RLM Conversational Product Configurator

> **Status:** ⚙️ **BUILT & DEPLOYED** · original POC on `rlm_agent_config_concept` (2026-07-20); **pre-persist
> enhancement + new guided-selling agent** on the clone `rlm-agent-config-v2` (2026-09-11). **As of:** 2026-09-11
>
> This is the **final, as-built architecture** of the POC — a single reference for how the pieces
> fit together and why. It reflects the deployed state, not the original plan. For the *chronological*
> narrative (what changed, when, and how to revert) see [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md); for the
> *decisions and their rationale* see [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md);
> for the *discovered engine internals* see [07-discovered-engine.md](07-discovered-engine.md).
>
> **Two launch paths.** The panel now works both from a **persisted** quote line (`0QL…`, open a saved line →
> Configure) *and* **pre-persist** directly from the product catalog (Configure before Save, where only a transient
> `ref_<uuid>` configurator node exists). See [§3.3 Pre-persist path](#33-pre-persist-path-catalog-configure-before-save).

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

**Reference org (original POC):** `rlm_agent_config_concept` (trial: `trailsignup-e01123b28c25c6`, API v67.0).
Canonical test data: Quote `0Q0g80000017wQ5CAI`, root configurable line `0QLg8000001RYgDGAW`
(**FESBA Generator Set**, `01tg80000047iP9AAI`).

**Active org (pre-persist enhancement):** `rlm-agent-config-v2` — a **clone** (org `00DgK00000Zok57UAB`, trial
`trailsignup-802b9f3fe5ee02`, API v67.0). **Clone fixtures differ from the original** and are the ones the
2026-09-11 work was validated against: FESBA Generator Set product **`01tgK00000EPnyuQAD`**
(ProductClassification `BasedOnId = 11BgK00000h2GWCUA2`), Quote **`0Q0gK000002dwcTSAQ`**.
> ⚠️ Several *live-data* tests in `ConfigEngineControllerTest` / `ConfigLmsGroundingServiceTest` still hardcode the
> **original** line Id `0QLg8000001RYgDGAW` and therefore **fail on the clone** (`QuoteLineItem not found`). This is
> stale-fixture drift, not a regression — see [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) (2026-09-11 entry).

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

### 3.3 Pre-persist path (catalog "Configure" before Save)

When a rep clicks **Configure directly from the product catalog**, the RLM Configurator hands the flow a
**transient in-memory node reference** (`ref_<uuid>`) as `transactionLineId` — there is no `0QL…` record yet
(it is minted, with its `QuoteLineItemAttribute` rows, only on the native Save). The panel detects this and
**grounds off the product instead of the (nonexistent) line**. Everything downstream is unchanged.

1. **Detect (synchronous, no callout).** `configChatPanel._isPrePersist` is true when `quoteLineItemId` is
   absent/blank or does **not** start with `0QL`. The flow also passes `rootProductId`
   (`S01_DataManager.rootProductId → S00_ConfigChatPanel.rootProductId`).
2. **Route the wires by an `undefined` reactive param.** `_qliParam` returns `undefined` pre-persist (so the QLI
   wires **never fire with a `ref_…`** — this alone removes the crash) and `_productParam` returns `undefined`
   post-persist. LWC suppresses any `@wire` whose reactive `$param` is `undefined`, so exactly one variant of each
   pair runs. The QLI and product variants funnel into the **same handlers** (`_applyCatalog` / `_applyLmsGrounding`).
3. **Ground off the product.** `ProductConfigGroundingService.getAttributesForProduct` / `getLmsGroundingForProduct`
   return the **same DTO types** as the persisted path, built with the **identical `Name ?? Code` label expression**
   (zero drift — see [§6.7](#6-key-architectural-decisions-and-why)). `ConfigExtractionService.extractConfiguration`
   takes an added `productId` and grounds through `resolveCatalog(qli, productId)`.
4. **Apply is unchanged.** `handleApply` already keys `valueChanged` on `this.quoteLineItemId` — pre-persist that
   *is* the `ref_…` node key the LMS contract expects. Same Numbers-first-then-Picklists ordering, same single
   `updatePrices`. Added **invalidation**: if the ref changes (deselect/reselect mints a new `ref_…`), any pending
   proposal is cleared and the phase resets to `READY` so a stale ref is never published. The panel also
   **subscribes** to the LMS channel (was publish-only) as a second trigger for this invalidation.
5. **Guided-selling routes to a *different* agent.** Pre-persist Q&A goes to **`Revenue_Product_Advisor`** (an
   insight-only agent that needs no persisted record) instead of `Revenue_Quote_Management`. See
   [§5 Components](#5-components) and [§6.8](#6-key-architectural-decisions-and-why).

> **One remaining live [verify]:** that the Data Manager **accepts a `valueChanged` whose `key` is `["ref_…"]`**
> pre-persist. Code is in place; this is a live-click confirmation (Stage 0 spike), not a code change.

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
| [`configChatPanel`](force-app/main/default/lwc/configChatPanel/) | LWC | **The POC deliverable.** State machine (LOADING → READY → EXTRACTING/ASKING → REVIEW → APPLYING → RESULT), intent routing, review card, auto-apply, LMS publish, agent Q&A. **Pre-persist aware:** `@api rootProductId`, `_isPrePersist`, `_qliParam`/`_productParam` wire gating, ref-change invalidation. Now **subscribes** to the LMS channel too (was publish-only). |
| [`ProductConfigGroundingService`](force-app/main/default/classes/ProductConfigGroundingService.cls) | Apex | **Pre-persist grounding.** `getAttributesForProduct` / `getLmsGroundingForProduct` return the **same DTO types** as the persisted path, built by SOQL off the product's classification with the **identical `Name ?? Code`** label expression (zero drift) + the same `ambiguousLabels` guard. `@TestVisible CatalogReader` seam. Never throws to the wire. |
| [`ConfigExtractionService`](force-app/main/default/classes/ConfigExtractionService.cls) | Apex | Grounded NL→validated-fields extraction **+ intent classification** in one Einstein callout. Now takes `productId` (`resolveCatalog` routes to product- vs line-grounding; 2-arg overload preserved). Injectable `LlmGateway` seam for tests; deterministic keyword fallback. |
| [`ConfigLmsGroundingService`](force-app/main/default/classes/ConfigLmsGroundingService.cls) | Apex | Supplies `attributeId` (0tj) + picklist **label→0v6-Id** map for the `valueChanged` payload. Per-attribute `ambiguousLabels` collision guard. **(Reference for the product service's label/shape; not modified.)** |
| [`AgentAdvisorService`](force-app/main/default/classes/AgentAdvisorService.cls) | Apex | `@AuraEnabled` wrapper over the `generateAiAgentResponse` invocable custom action. **Dual-agent:** selects `Revenue_Product_Advisor` (pre-persist, product CONTEXT) vs `Revenue_Quote_Management` (persisted line) per turn; `AgentGateway.invoke(userMessage, sessionId, agentApiName)` seam; `productId` added to `askAgent` (4-arg overload preserved). Insight-only — never applies a config. |
| [`ConfigEngineController`](force-app/main/default/classes/ConfigEngineController.cls) | Apex | Thin `@AuraEnabled` orchestration over the protected engine: `getAttributes`, `getSavedConfiguration`, `applyConfiguration` (PST path — now **bypassed** by the LMS publish). **May read; do not change its logic.** |
| `*Test` classes | Apex | Deploy-gate coverage, all mocking their gateway/reader seams (no live Einstein/agent credits). Pre-persist work: `ProductConfigGroundingServiceTest`, extended `ConfigExtractionServiceTest` / `AgentAdvisorServiceTest` — all pass. Coverage: ConfigExtractionService 87%, AgentAdvisorService 84%, ProductConfigGroundingService 92%, ConfigLmsGroundingService 92%. |

### Agentforce agents (guided-selling turn)

Two agents back the Q&A turn; the panel picks one per turn by whether the line is persisted.

| Agent | Metadata | Role |
|---|---|---|
| `Revenue_Quote_Management` | (existing NGA agent — `BotDefinition` Type=InternalCopilot + `GenAiPlannerBundle`) | Persisted-line Q&A. Its topic actions require a real Quote/QuoteLineItem. **Left entirely untouched.** |
| [`Revenue_Product_Advisor`](force-app/main/default/aiAuthoringBundles/Revenue_Product_Advisor/) | **NEW** — NGA `aiAuthoringBundles/` (`.agent` + `.bundle-meta.xml`) | **Pre-persist Q&A.** Insight-only Employee agent: one `system:` persona + one advice `topic:` with **zero data actions / zero `GenAiFunction`**. Grounds purely on the CONTEXT block passed in `userMessage`, so it needs no persisted record. |

**NGA authoring facts (2026-09-11):** author `aiAuthoringBundles/` **only** — never commit `bots/`,
`genAiPlanners/`, `genAiFunctions/`, `genAiPlugins/`, `genAiPlannerBundles/` (all legacy Bot 1.0). Flow:
`.agent` (**tab-only** indentation — Agent Builder 2.0 rejects spaces with `PARSE_EXCEPTION`) → `sf agent validate
authoring-bundle` → `sf project deploy start --source-dir` → **USER activates in Agent Builder 2.0 UI** (sets
Employee type, assigns agent user if prompted, Activates) → retrieve back. Apex invocability
(`createCustomAction('generateAiAgentResponse', '<apiName>')`) works **after** UI activation creates the runtime
Bot — no source-committed Bot/BotVersion needed. This org runs its Employee Agents session-based with **no
dedicated Einstein Agent User**, so the bundle omits `default_agent_user` (validation passed without it). Editor
tab-protection lives in `.editorconfig` `[*.agent]` and `.vscode/settings.json` `[agentscript]`.

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

7. **Pre-persist grounds off the product via SOQL, not the Connect API — for zero drift.** The load-bearing
   correctness property is that a proposal built pre-persist grounds to the *same* attribute developerNames and the
   *same* picklist label→`0v6`-Id join as the persisted path, so behaviour is identical the moment the line is saved.
   The persisted path resolves labels as `Name ?? Code`; only a SOQL path using the **identical `Name ?? Code`
   expression** guarantees no drift. `/connect/cpq/products/{productId}` is a callout returning a different shape
   (`displayValue`/`name`/`code`) that would reintroduce label drift and is harder to unit-test — documented as the
   authoritative fallback if scope diverges beyond FESBA. The reactive-param wire gating (an `undefined` `$param`
   suppresses its `@wire`) means the crash-causing QLI wires simply never fire on a `ref_…`.

8. **A separate agent for the pre-persist Q&A turn — the existing agent is never touched.** `Revenue_Quote_Management`'s
   topic actions require a persisted Quote/QLI (a bare pre-persist probe returns "QuoteLineItem … not found"), so the
   catalog turn needs its own agent. `Revenue_Product_Advisor` is **insight-only** (zero data actions), grounded purely
   on the CONTEXT text we pass, so it needs no record. Selection is by line state in `AgentAdvisorService`; the
   persisted-line path is byte-for-byte unchanged (preserved via non-annotated overloads).

---

## 7. Constraints & operational notes

- **Production-type org at the 75% coverage gate.** `IsSandbox=false`, so any Apex deploy must ship with tests and
  clear ≥75% coverage. All service tests mock their gateway seams (no live Einstein/agent dependency, no credits).
- **LWC caches aggressively.** After any `configChatPanel` redeploy, the rep must **hard-refresh** the flow tab
  (Cmd+Shift+R / close+reopen) or the browser keeps running the old bundle. (This masked a fix once during the
  build.)
- **Rollback path.** As of 2026-09-11 the project is **git-backed** (private repo, branch `rlm-config-agent-v2`) —
  git is the primary revert path. Pre-git change points (through 2026-07-20) are snapshotted under dated `backups/`
  folders; see the [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) Backups & Revert Protocol.
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
