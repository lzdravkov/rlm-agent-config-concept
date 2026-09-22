# Project Journal — RLM Conversational Product Configurator

> **Purpose.** A rolling, chronological record of what we built, why, and how to
> revert. This is the single narrative to point back to if we need to undo work.
> As of 2026-09-11 the project is **git-backed** (private repo, branch `rlm-config-agent-v2`), so **git is the
> primary rollback path**. Earlier work (through 2026-07-20) predates git — for those change points the dated
> `backups/` folders remain the only revert path; see [Backups & Revert Protocol](#backups--revert-protocol).
>
> Newest entries at the top of the [Change Log](#change-log). Append, don't rewrite.

---

## What this project is

An **Agentforce-style conversational configuration panel** embedded inside the
Salesforce Revenue Cloud (RLM) product configurator. A sales rep types a free-text
requirement (e.g. *"~1500 kW, data-center continuous duty, low-voltage"*) into a chat
panel that sits in the right-hand column of the configurator screen. The panel maps
that text to the product's real configuration attributes, shows an **editable review
card**, and — on Apply — pushes the selections into the managed configurator so it
applies, reprices, and re-renders natively.

**Reference org:** `rlm_agent_config_concept` (trial: `trailsignup-e01123b28c25c6`).
**Canonical test data:** Quote `0Q0g80000017wQ5CAI` ("New Quote For Infinitech"),
root configurable line `0QLg8000001RYgDGAW` (**FESBA Generator Set**, `01tg80000047iP9AAI`).

---

## Architecture at a glance

```
Rep free-text
     │
     ▼
configChatPanel (LWC)  ──(imperative)──►  ConfigExtractionService.extractConfiguration
     │                                        │  grounded LLM extraction (Einstein) + validation
     │                                        │  grounding source: ConfigEngineController.getAttributes
     │  ◄── ProposedField[] (editable review card) ──┘
     │
     │  Apply (explicit click)
     ▼
publish(valueChanged ×N, then updatePrices)  ──►  lightning__productConfigurator_notification
                                                    (platform LMS channel = command bus INTO
                                                     the managed RLM Data Manager)
                                                          │
                                                          ▼
                                          Managed Data Manager applies → reprices → re-renders
                                          (persistence is the native configurator's own Save)

grounding for the publish payload:
ConfigLmsGroundingService.getLmsGrounding  ──►  attributeId (0tj) + picklist label→AttributePicklistValue Id (0v6)
```

### Key architectural decisions (and why)

1. **Apply publishes `valueChanged` on the managed LMS channel — it does NOT write via PST.**
   The earlier build wrote+repriced through the Place Sales Transaction (PST) API as a
   side channel. That worked at the data layer, but the on-screen managed configurator
   holds its **own in-memory transaction graph** and never noticed the external write —
   so the rep saw a stale *"Prices don't reflect the latest selections"* banner and had
   to click Update Prices. Salesforce's guidance for third-party configurator UI is
   explicitly: **don't call the configurator/save APIs directly — route changes through
   `valueChanged`** and let the Data Manager own apply/reprice/re-render/Save. We publish
   INTO the Data Manager rather than writing around it.

2. **`valueChanged` payload contract (confirmed from a live native emission + DB readback):**
   ```json
   { "action": "valueChanged",
     "data": [{ "key": ["<quoteLineItemId>"], "field": "AttributeField",
                "attributeId": "<0tj… AttributeDefinition Id>",
                "value": "<0v6… AttributePicklistValue Id | raw number | text>" }] }
   ```
   - **Picklist** → `value` is the **AttributePicklistValue Id (0v6)**, NOT the label.
     (Verified in DB: `Duty Rating = Data Center Continuous (DCC)` stores both the label
     in `AttributeValue` and `0v6g8000000FQArAAO` in `AttributePicklistValueId`.)
   - **Number** → `value` is the **raw magnitude** as a string (verified: `FB_Full Load
     Required (kW) = 1500.0`, `Reserve Capacity (kW) = 375.0`, no picklist Id).
   - **Text** → raw string. **Checkbox** → boolean (inferred, not yet live-verified).
   - After all `valueChanged` messages, one `{ "action": "updatePrices" }` triggers reprice
     (harmless no-op if Instant Pricing is already on).

3. **Publish ordering: Numbers first, then Picklists.** Mirrors the proven PST two-step
   sequencing. A Number attribute drives BOM component selection (e.g. `requiredKW` picks
   the FESBA unit); publishing a Picklist first can let the duty-rating rule derive/override
   the Number. `Array.sort` is stable in LWC-target browsers, so intra-group order holds.

4. **Fire-and-forget consequence — no synchronous price delta.** `publish()` returns
   nothing and is a no-op if there's no subscriber. So the old price-movement / diff result
   card was intentionally replaced with a **"Sent to the configurator"** confirmation whose
   copy is **conditional** ("*If the configurator is open on this line…*") — it must not
   claim certainty the publish had an effect. The native panel is the source of truth.

5. **Grounding is the single source of truth; the LLM is never trusted.** Every value the
   LLM returns is re-validated against `getAttributes` (legal developerNames + picklist
   values). A hallucinated attribute or illegal picklist value cannot reach the review card.
   The LLM path has a **deterministic keyword+regex fallback** (`confidence='low'`) if the
   Einstein callout fails/returns junk.

---

## Component inventory

### Ours — safe to modify (authored for this POC)

| Component | Type | Role |
|---|---|---|
| `configChatPanel` | LWC | The live conversational panel. **This is the POC deliverable.** |
| `ConfigEngineController` | Apex | `@AuraEnabled` orchestration: `getAttributes`, `getSavedConfiguration`, `applyConfiguration` (PST path — now **bypassed** by the LMS publish, import commented out in the LWC). **May read; do not change its logic.** |
| `ConfigExtractionService` | Apex | Grounded LLM extraction → validated `ProposedField[]`. LLM routed through an injectable `LlmGateway` seam. |
| `ConfigLmsGroundingService` | Apex | Supplies `attributeId` (0tj) + picklist **label→0v6-Id** map for the publish payload. Includes a per-attribute `ambiguousLabels` collision guard. |
| `*Test` classes | Apex | `SeeAllData=true` against the live line; run separately (deploy-time gate is silently skipped in this org). |

### Protected — DO NOT MODIFY / DELETE (back a live NGA Agentforce agent or the reference flow)

| Component | Why protected |
|---|---|
| `ProductAttributeService` | Live invocable service behind the NGA Agentforce agent. Emits picklist label = `Name ?? Code`; exposes `attributeId`. **Our grounding keys on the SAME `Name ?? Code` expression** so the label→Id join has zero drift. |
| `ProductAttributeSaveService` | Live invocable (label→Id keyed on `Value`, sets `AttributePicklistValueId`). |
| `ProductAttributeReadService`, `QuoteLineItemLookupService` | Live invocables. |
| `renderDraw3DConfigurationPrototype` (LWC) | Reference "Rosetta Stone" for the LMS channel + subscribe/publish/MessageContext wiring. Do not delete/overwrite. |
| `RenderDraw_Product_Configurator_Flow` (Flow) | The reference configurator flow. Do not delete/overwrite. |

### Diagnostic / throwaway (scheduled for retirement)

| Component | Status |
|---|---|
| `configRefreshProbe` (LWC) | Diagnostic that subscribes+logs the LMS channel. **Kept in place** to capture failure cause if the DM ever rejects an inbound publish. Retire only after sustained confidence. |
| `spikeConfigApply` (LWC) | Earlier throwaway harness, replaced by `configChatPanel`. Referenced only in a **comment** in the agent flow. |

### Flow wiring (confirmed)

- The **live** panel is embedded as screen component **`c:configChatPanel`** (field
  `S00_ConfigChatPanel`) inside **`Agent_Product_Configurator_Flow`**, in the right-hand
  column above the native `pricingSummary`. Inputs: `quoteId`, `quoteLineItemId` from Flow
  variables. (This is the "Agent Product Configurator Flow" tab in the org.)
- `RenderDraw_Product_Configurator_Flow` embeds `renderDraw3DConfigurationPrototype` (the reference).

---

## Verification status (as of 2026-07-17)

**✅ Core mechanism proven end-to-end via a live click + debug logs + DB readback.**

Debug log timeline of a real session (times PDT, all on quote `0Q0g80000017wQ5CAI`):

| Time | Log entry point | Meaning |
|---|---|---|
| 16:11:18 | `getAttributes` + `getSavedConfiguration` + `getLmsGrounding` | Panel load; new grounding wire fires |
| 16:11:32 | `ConfigExtractionService.extractConfiguration` | LLM extraction (real Einstein callout ~723ms — **not** fallback) |
| **16:11:35** | **`Configure for Quote…`** → **`Get context price…`** | **Apply #1 — DM re-renders + reprices (~1.3s)** |
| 16:11:45 | `extractConfiguration` again | Second requirement |
| **16:11:48** | **`Configure for Quote…`** → **`Get context price…`** | **Apply #2 — re-render + reprice (~1.7s)** |

- The two `Configure for Quote → Get context price` pairs are the managed Data Manager
  reacting to our inbound publish. **This closed the one empirical unknown:** the DM acts
  on a publish that originates from our component, not just from its native panel.
- Caveat: `Configure for Quote` is **managed-namespace** code, so its internals are not in
  the Apex log. We can't see our JSON payload in a log (it's a client-side LMS event) — the
  effect was confirmed by DB readback instead.
- Test suite: `ConfigLmsGroundingServiceTest` — **5/5 pass, 92% coverage.** Includes a
  cross-service label-set equality test (getAttributes ↔ getLmsGrounding) and an
  `ambiguousLabels` shape test.

---

## Open feature requests (received 2026-07-17)

> **All items in this list are now BUILT & DEPLOYED.** Kept for provenance; see the Change
> Log for the shipping entries. No open build items remain from this batch.

1. ~~**Guided-selling Q&A ("tell me more about the duty rating options").**~~
   ✅ **BUILT & DEPLOYED 2026-07-19; intent routing hardened & VERIFIED WORKING LIVE 2026-07-20.**
   Today the panel only *extracts* a configuration; a question like "tell me more about the
   duty rating options" returned *"I could not confidently map that…"*. The user showed that
   the standalone **Revenue Management Agentforce agent** answers exactly this. **Delivered:**
   `AgentAdvisorService` wraps the existing agent via `generateAiAgentResponse` (no new agent,
   no OAuth), reached from the panel as an insight-only turn (D9). **Routing:** originally a
   phrase-based heuristic gate, then hardened so the **grounded extraction call itself classifies
   intent** (`CONFIGURE | ASK`) — advice questions route to the agent instead of greedily
   auto-applying a picklist word. Confirmed working in a live rep test on 2026-07-20 (e.g.
   *"what do you recommend for a data center and why"* and *"how much full load do I need for a
   large data center"* now get reasoned agent answers, not an auto-applied DCC). See the
   2026-07-20 and 2026-07-19 Change Log entries.

2. ~~**Auto-apply (skip the confirmation click).**~~ ✅ **BUILT 2026-07-17.**
   Delivered as a rep-controllable **Auto-apply** toggle (Flow default `autoApplyDefault`),
   with a strict "clean proposal only" gate that degrades to the review card on anything
   invalid/ambiguous/low-confidence. See Change Log.

---

## Backups & Revert Protocol

**There is no git here. To revert, copy files back from the relevant backup folder.**

### Backup index

| Folder | Created | Snapshot of |
|---|---|---|
| `backups/2026-07-17_pre-guided-selling-and-autoapply/` | 2026-07-17 | State AFTER the LMS-publish rebuild + review-fix hardening (card copy made conditional, `ambiguousLabels` collision guard, cross-service join test) and BEFORE guided-selling / auto-apply work. **Last-known-good, fully verified live.** |
| `backups/2026-07-19_pre-guided-selling-build/` | 2026-07-19 | `configChatPanel` bundle BEFORE the guided-selling wiring. |
| `backups/2026-07-19_llm-intent-routing/` | 2026-07-20 | **Post-change** snapshot of the LLM-intent-classification work: `ConfigExtractionService`(+Test) `.cls`/`.cls-meta.xml` and the full `configChatPanel` bundle. (To roll *back* this change, restore `ConfigExtractionService`/`Test` + `configChatPanel.js` from `2026-07-19_pre-guided-selling-build` / the extraction service from the 07-17 snapshot as appropriate.) |

Contents of that backup (17 files):
- `lwc/configChatPanel/` — all 4 bundle files (`.js`, `.html`, `.css`, `.js-meta.xml`)
- `classes/` — `ConfigLmsGroundingService`, `ConfigExtractionService`, `ConfigEngineController`
  and their `*Test` counterparts (`.cls` + `.cls-meta.xml` each)
- `flows/Agent_Product_Configurator_Flow.flow-meta.xml`

### To revert a file

```bash
# Example: restore the panel JS to the last-known-good snapshot
cp "backups/2026-07-17_pre-guided-selling-and-autoapply/lwc/configChatPanel/configChatPanel.js" \
   "force-app/main/default/lwc/configChatPanel/configChatPanel.js"
# then redeploy:
sf project deploy start --source-dir force-app/main/default/lwc/configChatPanel
```

### Org quirks (operational notes)

- Always `export SF_AUTOUPDATE_DISABLE=true` before `sf` commands.
- The **deploy-time test gate is silently skipped** in this org — run
  `sf apex run test --class-names <Test>` **separately** to actually validate.
- `sf … --json` output is prefixed with a CLI update warning line; strip everything
  before the first `{` when parsing (`raw[raw.find('{'):]`).
- `QuoteLineItemAttribute` value fields (this org): `AttributeValue` (string) +
  `AttributePicklistValueId` (reference). There is no `TextValue`/`NumberValue`.

---

## Change Log

*(Newest first. Each entry: date, what changed, why, files, verification, backup ref.)*

### 2026-09-11 — Pre-persist conversational configuration + new guided-selling agent (`Revenue_Product_Advisor`)
- **Ask (the bug):** conversational configuration worked only when a **persisted** `QuoteLineItem` (`0QL…`)
  existed (open a saved line → Configure). Launching **Configure directly from the product catalog** failed with
  `QuoteLineItem not found: ref_8afefb1f_…` because on the catalog path the RLM Configurator hands the flow a
  **transient in-memory node reference** (`ref_<uuid>`) — not a queryable record. The whole read/grounding layer
  was keyed to a `0QL…` Id. Goal: configure **before** the line is persisted, and route the guided-selling (Q&A)
  turn to a **new, purpose-built agent** for the pre-persist case, leaving `Revenue_Quote_Management` untouched.
- **Target org — NEW CLONE.** All work here landed on **`rlm-agent-config-v2`** (a clone of the original;
  org `00DgK00000Zok57UAB`, trial `trailsignup-802b9f3fe5ee02`, API v67.0), **not** the original
  `rlm_agent_config_concept`. **Re-captured clone fixtures** (Ids differ from the original org):
  FESBA Generator Set product **`01tgK00000EPnyuQAD`** (ProductClassification `BasedOnId = 11BgK00000h2GWCUA2`),
  live Quote **`0Q0gK000002dwcTSAQ`** ("New Quote For Infinitech").
- **Root cause (confirmed by code + live-org SOQL):** the fix is a **read/grounding change, not an apply change**.
  The apply path already publishes `key: [this.quoteLineItemId]` — i.e. against whatever `transactionLineId` holds,
  which *is* the `ref_…` node key the LMS `valueChanged` contract expects. What blocked pre-persist was that empty
  grounding (QLI wires firing with a `ref_…` → error/empty) made every row fail with "no configurator mapping." So:
  **when the line is transient, ground off the product** (`S01_DataManager.rootProductId`, already resolved in the
  flow) instead of the nonexistent persisted line.
- **What changed (by stage):**
  1. **Detection + product routing (stops the crash).** `configChatPanel` gained `@api rootProductId`, a synchronous
     `get _isPrePersist()` (true when `quoteLineItemId` is present/blank but does **not** start with `0QL`), and
     **reactive-param wire gating** via `_qliParam` (`undefined` pre-persist → suppresses the QLI wires) and
     `_productParam` (`undefined` post-persist → suppresses the product wires). An `undefined` reactive `$param`
     never invokes its `@wire`, so the QLI wires can no longer fire with a `ref_…`. New `rootProductId` LWC property
     in the meta; new `S01_DataManager.rootProductId → S00_ConfigChatPanel.rootProductId` binding deployed as a new
     **active** version of `Agent_Product_Configurator_Flow`.
  2. **Product grounding — new SOQL service (zero-drift).** New `ProductConfigGroundingService` (`with sharing`,
     cacheable, never-throws-to-wire) with `getAttributesForProduct(productId)` / `getLmsGroundingForProduct(productId)`
     returning the **existing DTO types** (`ConfigEngineController.AttributesResult` / `ConfigLmsGroundingService.LmsGroundingResult`)
     so the LWC and `_buildValueChangedItem` need no new shape handling. Correctness invariant carried over verbatim:
     picklist label = **`Name ?? Code`** (NOT `Value`) + the ambiguous-label collision guard, so the pre-persist
     catalog is identical to the saved-line catalog the moment the line is saved. `@TestVisible CatalogReader` seam
     for deterministic tests. LWC re-points: the QLI and product variants of each wire funnel into shared handlers
     (`_applyCatalog` / `_applyLmsGrounding`). Chose **SOQL over the Connect API** deliberately: only the identical
     `Name ?? Code` SOQL expression guarantees no label drift (Connect API returns a different shape); documented the
     Connect API as the authoritative fallback if scope diverges beyond FESBA.
  3. **Extraction re-point.** `ConfigExtractionService.extractConfiguration` now takes `(requirementText,
     quoteLineItemId, productId)` (plus a non-annotated 2-arg overload delegating `productId=null`, since only one
     overload may be `@AuraEnabled`). New private `resolveCatalog(qli, productId)`: `groundingOverride` if set → else
     product-based when the line is transient/blank and `productId` present → else `getAttributes(qli)`. Guard message
     changed to *"quoteLineItemId or productId is required."* All prompt/validation logic untouched.
  4. **Pre-persist apply + invalidation.** Apply is unchanged (already keys on the `ref_…` node ref, preserves
     Numbers-first-then-Picklists ordering, one `updatePrices`). Added **proposal invalidation**: when
     `quoteLineItemId` changes (a deselect/reselect mints a new `ref_…`), any pending proposal is cleared and the
     phase resets to `READY`, so a stale ref is never published.
  5. **LMS subscribe (robustness).** `configChatPanel` — previously publish-only — now **subscribes** to
     `lightning__productConfigurator_notification` (pattern proven in `configRefreshProbe` /
     `renderDraw3DConfigurationPrototype`): subscribe in `connectedCallback` guarded on `_subscription` +
     `messageContext`, unsubscribe in `disconnectedCallback`. Inbound messages are a second, robust trigger for the
     ref-change invalidation above.
  6. **New agent + `AgentAdvisorService` parameterization.** New **insight-only NGA Employee agent**
     `Revenue_Product_Advisor` (`aiAuthoringBundles/`, one `system:` persona + one `topic:` with scope/instructions +
     **zero data actions / zero GenAiFunction** — a `@utils.transition`-only advice topic). It answers product/attribute
     advice purely from a CONTEXT block passed in `userMessage`, so it never needs a persisted Quote/QLI.
     `AgentAdvisorService` now selects the agent per turn: added `PREPERSIST_AGENT_API_NAME = 'Revenue_Product_Advisor'`,
     changed the `AgentGateway.invoke` seam to `invoke(userMessage, sessionId, agentApiName)`, added `productId` to
     `askAgent` (5-arg `@AuraEnabled` + 4-arg non-annotated overload). When the line is transient/blank and `productId`
     is present → `Revenue_Product_Advisor` with a product-shaped CONTEXT block (`buildProductContextMessage` →
     `formatProductContext`); otherwise the existing quote/line path to `Revenue_Quote_Management`, **unchanged**.
- **Key findings (settle the plan's open [verify]s):**
  - **NGA vs Legacy.** The new agent is authored the **NGA** way — `aiAuthoringBundles/` **only**. `bots/`,
    `genAiPlanners/`, `genAiFunctions/`, `genAiPlugins/`, `genAiPlannerBundles/` must **never** be committed (legacy
    Bot metadata). `sf agent publish authoring-bundle` / `sf agent create` are forbidden (they force Agent Builder
    1.0). Correct path: author `.agent` → `sf agent validate authoring-bundle` → `sf project deploy start
    --source-dir` → **USER activates in Agent Builder 2.0 UI** → retrieve back.
  - **Invocability RESOLVED (supersedes the old "NGA isn't Apex-invocable" hedge).** The working
    `Revenue_Quote_Management` carries BOTH a runtime **`BotDefinition`** (Type=InternalCopilot, session-invoked,
    **zero** Einstein Agent Users) AND a `GenAiPlannerBundle`. Apex `createCustomAction('generateAiAgentResponse',
    '<apiName>')` works **after** UI activation creates the runtime Bot — **no source-committed Bot/BotVersion
    needed.** This org runs its Employee Agents session-based with **no dedicated Einstein Agent User**, so the new
    bundle omits `default_agent_user` (validation passed without it; the agent user is assigned at UI activation).
  - **`.agent` = TAB-ONLY indentation.** Agent Builder 2.0 rejects space-indented `.agent` files with
    `PARSE_EXCEPTION` even when `sf agent validate` passes. Added editor protection: `.editorconfig` `[*.agent]`
    (`indent_style = tab`) + `.vscode/settings.json` `[agentscript]` (`insertSpaces:false`, `formatOnSave:false`,
    `formatOnPaste:false`, `detectIndentation:false`).
- **Files:**
  - New: `classes/ProductConfigGroundingService.cls` (+ `-meta`) + `ProductConfigGroundingServiceTest.cls`;
    `aiAuthoringBundles/Revenue_Product_Advisor/{Revenue_Product_Advisor.agent, .bundle-meta.xml}`;
    `.editorconfig`; `.vscode/settings.json` `[agentscript]` block.
  - Modified: `lwc/configChatPanel/configChatPanel.js` (+ `.js-meta.xml`), `classes/ConfigExtractionService.cls`
    (+ Test), `classes/AgentAdvisorService.cls` (+ Test), `flows/Agent_Product_Configurator_Flow.flow-meta.xml`
    (new active version).
  - Reference-only (NOT modified): `ConfigLmsGroundingService` (label/shape source), the four protected engine
    services, `renderDraw3DConfigurationPrototype`, `RenderDraw_Product_Configurator_Flow`, `Revenue_Quote_Management`.
- **Verification:**
  - Apex/LWC/Flow + the new agent bundle all **deployed clean** to `rlm-agent-config-v2`. `sf agent validate
    authoring-bundle` → success; `sf project deploy start` → both `AiAuthoringBundle` components Created.
  - New/modified **seam-based tests all pass**: `ConfigExtractionServiceTest`, `AgentAdvisorServiceTest`,
    `ProductConfigGroundingServiceTest` (28 tests) — 0 failures. Per-class coverage: ConfigExtractionService 87%,
    AgentAdvisorService 84%, ProductConfigGroundingService 92%, ConfigLmsGroundingService 92%.
  - **Full-suite (`RunLocalTests`) note — no regression from this work.** 167 tests, 14 failures. **All 14 are
    pre-existing / environment-dependent, not caused by these changes:** 8 are *live-data* tests in
    `ConfigEngineControllerTest` (5) and `ConfigLmsGroundingServiceTest` (3) that **hardcode the ORIGINAL org's line
    Id `0QLg8000001RYgDGAW`** (absent in the clone → `QuoteLineItem not found`); the other 6 are unrelated subsystems
    (`RLM_MFG_OrderToServiceContractTest`, `RLM_RampScheduleValidatorTest`). The org-wide 25% figure reflects many
    untested `RLM_*` classes across the whole org, not the deployed feature. **Follow-up offered:** re-point the
    stale live-data tests to the clone's fixtures (needs a persisted clone `0QL` line Id) — deferred, out of this
    plan's scope, touches reference/protected test classes.
- **Outstanding — USER-SIDE GATES (not attempted autonomously):**
  1. **Activate `Revenue_Product_Advisor`** in Agent Builder 2.0 (Setup → Agents): set type = **Employee**, assign
     the agent user if prompted, **Activate**. The runtime Bot (and thus Apex invocability) only exists after this.
     Then smoke-test `generateAiAgentResponse` for the API name (mirror the 2026-07-19 test on the existing agent).
  2. **Interactive `ref_` LMS spike (Stage 0):** on a catalog-launched screen, confirm the Data Manager **accepts a
     `valueChanged` whose `key` is `["ref_…"]`** (the one remaining apply assumption). Code is in place; this is a
     live-click confirmation.
- **Revert:** project is now **git-backed** (branch `rlm-config-agent-v2`) — revert via git, not `backups/`. No
  functional behavior on the persisted-line path changed (overloads preserve the old signatures).

### 2026-07-20 — LLM intent classification in extraction (D11 follow-up shipped; heuristic gate was leaking)
- **Bug (found in live retest of the heuristic gate):** the phrase-based `_looksLikeQuestion` gate missed real
  questions whose wording it didn't enumerate. Logs proved *"tell me how much full load do I need for a large data
  center"* fell straight through to extraction (`ConfigExtractionService.extractConfiguration` + `EinsteinLLM` ran
  at 02:24:50) → "large data center" greedily matched **DCC** → auto-applied. "tell me *more*" is a marker but
  "tell me *how much*" isn't; "how" mid-sentence isn't an opener; no "?". Word-list routing is whack-a-mole.
  *(The companion message "what do you recommend…and why" DID match the deployed markers — that failure was a
  stale browser bundle, not a code gap; the LLM-intent fix below makes the routing robust regardless of cache.)*
- **Fix (the deferred D11 follow-up, now built):** intent classification moved **into the grounded extraction
  callout itself** — no extra round trip. `buildGroundedPrompt` now asks the model to (1) classify the message
  `CONFIGURE | ASK` and (2) map fields only if CONFIGURE, returning `{"intent":..,"fields":{devName:value}}`.
  `ExtractionResult.intent` carries it back; on **ASK the service skips field validation entirely** (no
  proposedFields), so a picklist word inside a question can never become an applied change. The LWC routes
  `res.intent === 'ASK'` → `_askAgentFallback`.
- **Robustness / back-compat:** `readFields` tolerates BOTH the new nested shape and a legacy flat
  `{devName:value}` object; an absent/unrecognized intent **defaults to CONFIGURE** (a misread directive still gets
  the reversible, rep-reviewed config path — never silently swallow a real config request); the deterministic
  keyword **fallback always reports CONFIGURE** (it can't reason about intent). The `_looksLikeQuestion` heuristic
  is **kept as a free pre-filter** so obvious questions skip the Einstein callout; LLM intent is the backstop.
- **Files:** [ConfigExtractionService.cls](force-app/main/default/classes/ConfigExtractionService.cls) (`intent`
  constants + DTO field, `readIntent`/`readFields`, rewritten `buildGroundedPrompt`, ASK-skips-validation branch);
  [ConfigExtractionServiceTest.cls](force-app/main/default/classes/ConfigExtractionServiceTest.cls) (+6 tests:
  new-shape configure, ASK-skips-fields, missing-intent-defaults-configure, fallback-reports-configure,
  `readIntent`, `readFields`); [configChatPanel.js](force-app/main/default/lwc/configChatPanel/configChatPanel.js)
  (`res.intent === 'ASK'` route in `_handleExtractionResult`); D11 follow-up marked BUILT in
  [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md).
- **Deploy & verify:** deployed to `rlm_agent_config_concept` → **Succeeded**. `ConfigExtractionServiceTest` =
  **24 tests, 100% pass**; `ConfigExtractionService` coverage **87%** (clears the 75% production-org gate).
  **✅ Confirmed working in a live rep test (2026-07-20):** advice questions now route to the agent for a reasoned
  answer instead of auto-applying a picklist match.
- **Backup:** `backups/2026-07-19_llm-intent-routing/` (post-change snapshot of the two Apex classes + the LWC).
- **Ops note:** after any LWC redeploy the rep must **HARD-REFRESH the flow tab** (Cmd+Shift+R / close+reopen the
  configurator) — LWC bundles cache aggressively, and a stale tab was what made the earlier heuristic fix look
  unfixed. (This bit us during this change; noted here so future redeploys start with a refresh.)

### 2026-07-19 — Intent gate: advice questions route to the agent BEFORE extraction (D11 revised)
- **Bug (found in live test):** *"what do you recommend for a data center"* and *"which would you recommend for a
  large hospital"* were being treated as **config directives**, not questions. Extraction is greedy — "data
  center" matches the DutyRating picklist value **Data Center Continuous (DCC)** — so it mapped ≥1 attribute and,
  with **auto-apply now on**, silently applied DCC instead of letting the agent give a reasoned recommendation
  (the native agent, per the reference screenshots, answers these properly).
- **Fix:** added a conservative phrase-based intent gate `_looksLikeQuestion(text)` that runs in `handleSend`
  **before** `extractConfiguration`. Advice/recommendation/opinion markers ("recommend", "suggest", "which
  should/would you", "what's best for", "help me choose", "should I", "tell me more", "explain", …), interrogative
  openers (what/which/why/how/is/are/can/would/should…), and a trailing "?" route straight to `_askAgentFallback`.
  Everything else falls through to the unchanged extraction path (which keeps its own zero-mapped agent fallback).
  **Pure LWC change** — no Apex, no LLM call, no added latency/cost.
- **Verified routing** against the screenshot messages: the two "recommend" questions + "tell me more…" now →
  agent; the config directives ("~1500 kW, data-center continuous…", "lets do prp for duty rating", "set duty
  rating to DCC") still → extraction.
- **Post-recommendation UX (confirmed):** the agent's answer is shown as a chat reply; nothing is auto-applied from
  it — the rep types a directive to apply. Preserves the D9 insight/apply separation.
- **Follow-up noted (deferred):** move intent into the extraction LLM call (`ExtractionResult.intent` = CONFIGURE |
  ASK) for phrasings the heuristic misses — an Apex redeploy + test update, Phase-2 hardening, not blocking.
- **Files:** [configChatPanel.js](force-app/main/default/lwc/configChatPanel/configChatPanel.js) (new
  `_looksLikeQuestion`, gate in `handleSend`); D11 rewritten in
  [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md).
- **Deploy:** `configChatPanel` LWC only → **Succeeded**. No test run required.

### 2026-07-19 — Live-test verification + auto-apply-on-by-default & gated confirmation card
- **Live test of guided-selling (ask 1) — PASSED.** With debug tracing on the test user (`RLM_Spike_Debug`
  level, `USER_DEBUG` flag), a real configurator session exercised the agent path end-to-end. Two
  `AgentAdvisorService.askAgent` invocations captured in Apex logs (`07Lg8000005lMbhEAE`, `07Lg8000005lMgXEAU`),
  both **Success**: `createCustomAction` → `invoke()` → `isSuccess()=true` → `fromOutputs` → `parseAgentResponse`
  (JSON deserialize) → `isGenericFailure`. **Multi-turn confirmed** — turn 2's log shows `setInvocationParameter`
  called twice (userMessage + sessionId), proving the in-memory `_agentSessionId` is forwarded. Latency **7.2s /
  3.9s** inside `invoke()` (in the predicted ~8–9s band). **0 SOQL / 0 DML / 0 callouts** consumed (the agent
  action is metered outside the Apex callout counter). The live agent path is verified healthy — the suite was
  entirely mocked before this.
- **UX change (per user feedback):** auto-apply is now **ON by default**, and the itemized *"Sent to the
  configurator"* card is **hidden by default** — a clean auto-apply now confirms via the assistant chat line
  alone and returns straight to the composer for the next message. The card can be re-enabled per screen via a
  new Flow variable.
- **Files — [configChatPanel.js](force-app/main/default/lwc/configChatPanel/configChatPanel.js) +
  [.js-meta.xml](force-app/main/default/lwc/configChatPanel/configChatPanel.js-meta.xml):**
  - `autoApplyDefault` now defaults **true**. Because LWC forbids a public Boolean defaulting to true (LWC1099),
    it's exposed via an `@api` getter/setter over a private `_autoApplyDefault` backing field (default-true holds
    when the Flow leaves it unset; a Flow assignment still wins). Meta `default="true"`.
  - New `@api showSentToConfigurator` (plain Boolean, default **false**). `showResultCard` now also requires this
    flag; `_handleApplySuccess` drops straight to `READY` (not `RESULT`) when the card is hidden, since there's no
    Continue button in that case. Meta property added with a description.
- **Deploy:** `configChatPanel` LWC only (no Apex touched) → **Succeeded**. No test run required.
- **Debug tracing:** stale expired `USER_DEBUG` flag removed; fresh 24h flag `7tfg8000003aQ8jAAE` created on the
  test user (`005g8000006PWMDAA4`) with the existing `RLM_Spike_Debug` level (Apex=FINE, Callout=INFO, DB=FINE,
  System=DEBUG). Expires 2026-07-21 ~02:02 UTC.

### 2026-07-19 — Guided-selling (ask 1): BUILT & DEPLOYED (extract-first → agent-fallback)
- **What:** Implemented the guided-selling Q&A feature per D8–D11. A rep's informational question ("tell me more
  about the duty rating options") that the config engine can't map now gets forwarded to the real Revenue
  Management agent and answered inline — replacing the old dead-end *"I could not map that"* message.
- **D11 resolved = extract-first, agent-fallback.** No new UI, no mode switch. The panel runs the existing
  extraction first; only when it maps **zero** attributes does it route the same text to the agent as a question.
- **New Apex — [AgentAdvisorService.cls](force-app/main/default/classes/AgentAdvisorService.cls)** (`@AuraEnabled askAgent`):
  wraps `createCustomAction('generateAiAgentResponse','Revenue_Quote_Management')` behind an injectable
  **`AgentGateway`** seam (mirrors `ConfigExtractionService.LlmGateway`), prepends the
  `CONTEXT: quoteId=… quoteLineItemId=…` block, parses the `{"type":"Text","value":"…"}` envelope to plain text,
  carries `sessionId` for multi-turn, and treats the known `isSuccess=true` + *"Something went wrong"* generic
  fallback (and empty answers) as a **soft failure** (friendly message, never surfaced as a real answer).
  **Never throws** to the LWC (same DTO error contract as the extraction service). Insight-only — no DML, no
  publish, no apply (D9).
- **New test — [AgentAdvisorServiceTest.cls](force-app/main/default/classes/AgentAdvisorServiceTest.cls):**
  12 tests, all green, **79% coverage** on the service (clears the 75% production-org gate). Mocks the
  `AgentGateway` so it burns **no Einstein credits** and needs no live session. The only uncovered lines are the
  thin `RealAgentGateway.invoke` bits that require a live `Invocable.Action.Result` (no constructor) — the pure
  interpretation logic was split into `@TestVisible` statics (`fromOutputs`, `joinErrors`) that ARE covered.
- **Panel wiring — [configChatPanel.js](force-app/main/default/lwc/configChatPanel/configChatPanel.js):** new
  `ASKING` phase + `isAsking`/`busyLabel` = "Asking the assistant…"; `_agentSessionId` held in memory;
  `_askAgentFallback()` added; the zero-mapped branch of `_handleExtractionResult` now calls it. The
  **extract-and-apply path (review card, auto-apply, LMS publish) is completely untouched.** HTML needed no
  structural change — it already binds `{isBusy}`/`{busyLabel}`.
- **Deploy:** Apex via `sf project deploy start` (2 components, 0 errors) with `AgentAdvisorServiceTest` green at
  79%; LWC bundle deployed (1 component, 0 errors). Target org `rlm_agent_config_concept`.
- **Gotcha fixed mid-build:** first test run reported 3 failures — `NullPointerException: Argument 3 cannot be
  null` — because success-path asserts passed a null `errorMessage` as the (non-nullable) assert *message* arg.
  Fixed to `'unexpected error: ' + a.errorMessage`. Also learned `sf project deploy … --tests` reports
  `numberTestsCompleted: 0` on this org; running `sf apex run test` afterward is what actually surfaces
  pass/fail + coverage.
- **Backup:** `backups/2026-07-19_pre-guided-selling-build/` (configChatPanel bundle, pre-change) — the rollback path.
- **Still pending:** a **live rep test** in the configurator flow (confirm a real question returns a grounded
  agent answer, and observe true end-to-end latency for the "thinking…" state).

### 2026-07-19 — Guided-selling (ask 1): architecture decided (no clone; agent=insight/engine=apply)
- **What:** Planning-only session that turned the 2026-07-19 smoke-test discovery into an agreed design.
  Recorded as **D8–D11** in [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md).
- **Decisions (all resolved except routing):**
  - **D8 — do NOT clone the agent.** Cloning adds overhead for explanations (planner routes to
    `ProductConfiguration` regardless) and is *harmful* for config (the clone's `Configure_Product_Attributes`
    writes via PST — the stale-screen path we abandoned). A clone is a **local copy, not a live reference**
    (two agents to maintain) and only pays off if we needed to *change* the agent's behavior — we don't, to call it.
  - **D9 — architecture = agent for insight, our engine for apply.** Two strictly separated turns; the agent's
    PST config action never touches the live embedded configurator.
  - **D10 — build shape fixed:** one new `@AuraEnabled` wrapper (+ mocked test) around
    `createCustomAction('generateAiAgentResponse','Revenue_Quote_Management')`; context passed as a prepended
    `CONTEXT: quoteId=… quoteLineItemId=…` block using the panel's `@api` inputs; `sessionId` held in-memory for
    multi-turn; wrapper handles the ~8–9s wait, the `isSuccess=true`+"Something went wrong" fallback, and log truncation.
  - **D11 — turn routing = STILL OPEN.** Recommend **extract-first, agent-fallback** (run existing extraction; if it
    maps nothing, send the text to the agent as a question). This is the **one gate** before the guided-selling build.
- **Why table cloning:** confirmed the `ProductConfiguration` topic's config action is PST-based
  ([07 §2](07-discovered-engine.md)) — reusing it for the write reintroduces the exact desync bug the LMS design fixed.
- **Files:** `06-open-questions-and-decisions.md` (added Part 1b / D8–D11, updated header + decision order). No code.
- **Verification:** n/a (planning only). **No functional code, metadata, or records changed this session.**

#### ▶ RESUME HERE (next session)
> **Superseded by the 2026-07-19 "BUILT & DEPLOYED" entry at the top of the log.** D11 was confirmed
> (extract-first, agent-fallback) and the guided-selling feature was built, tested (79%), and deployed.
1. **Live rep test — guided-selling (ask 1):** open the configurator flow on the FESBA line
   (`0QLg8000001RYgDGAW`), ask a question the engine can't map ("tell me more about the duty rating options"),
   confirm a grounded agent answer renders inline (not the dead-end message), and observe real end-to-end latency
   for the "Asking the assistant…" state. Try a follow-up to confirm multi-turn `sessionId` continuity.
2. **Live rep test — auto-apply toggle (ask 2, built 2026-07-17):** still pending.
3. **Deferred cleanups (unchanged):** `configRefreshProbe` LWC + its flow node retirement;
   `revenue_transactionNotification` refs.
- **Reminder:** `Agent0.md` is intentionally excluded from these doc updates per the user's instruction.

### 2026-07-19 — Guided-selling (ask 1): agent IS Apex-invocable — earlier "blocker" REFUTED
- **Headline:** The existing **Revenue Management Agent** (`Revenue_Quote_Management`,
  `0Xxg8000001B9dhCAC`, `Type=InternalCopilot` / `AgentforceEmployeeAgent`) **can be invoked
  synchronously from plain Apex** via the standard **`generateAiAgentResponse`** custom invocable
  action — **no new agent, no REST Agent API (`einstein/ai-agent/v1`), no OAuth, no External
  Client App, no named credential.** This **refutes** the 2026-07-17 "publish a new API-enabled
  Service Agent + OAuth" plan below (kept for history, now superseded).
- **How it was proven (Tier-1 smoke test — disposable, read-only w.r.t. our project):** ran
  anonymous Apex against the live org. Result: **`isSuccess=true`**, a `sessionId` was returned,
  and the agent replied in natural language — it ran its **real `ProductConfiguration` topic**
  (the reply referenced the QuoteLineItem / attributes / configuration, not a canned message).
  No persistent records created; only an ephemeral agent session (~24h TTL). Scaffolding removed
  after the run.
- **The two earlier premises that were WRONG:**
  - ❌ *"`generateAiAgentResponse` is Legacy-Bot-only, so it can't invoke this NGA/Employee agent."*
    — FALSE for this agent. It is registered as a `GENERATE_AI_AGENT_RESPONSE` invocable action
    (confirmed via REST action discovery) and was invoked successfully from Apex.
  - ❌ *"Invoking a full agent from Apex needs the REST Agent API + OAuth plumbing that doesn't exist."*
    — Not for this path. The invocable action runs **in-session, in the running user's context.**
- **Verified invocation contract (from REST action discovery on THIS org's agent + the live call):**
  - **Factory:** `Invocable.Action.createCustomAction('generateAiAgentResponse', 'Revenue_Quote_Management')`
    — arg 2 is the **agent API/developer name**, NOT a botId. (Using `createStandardAction`, or
    passing `botId`/`inputText`/`versionString`, fails with
    `NullPointerException: Specify a name for the generateAiAgentResponse custom invocable action type`.)
  - **Inputs:** `userMessage` (String, **required**), `sessionId` (String, optional — pass to continue
    a conversation), `VoiceCallId` (String, optional). No `versionString`, no `botId`, no `language`.
  - **Outputs:** `agentResponse` (String — a JSON blob `{"type":"Text","value":"…"}` that must be
    **parsed** for the text), `sessionId` (String — persist for multi-turn).
- **The real remaining design question — CONTEXT passing:** the bare probe question ("tell me more
  about the duty rating options") returned *"…the QuoteLineItem ID provided is not valid or not found.
  Could you confirm the product…"* — i.e. the agent's actions need to know **which quote line** the rep
  is configuring. Two build-time options: (a) **prepend a context block** into `userMessage`
  (e.g. `CONTEXT: quoteId=… quoteLineItemId=…\n<question>`, the pattern the email agent already uses);
  (b) reuse the panel's live `@api quoteId` / `quoteLineItemId`. Not a blocker — the next decision.
- **Consequence for the build:** guided-selling (ask 1) becomes a **single `@AuraEnabled` Apex wrapper**
  around `createCustomAction(...)` that `configChatPanel` calls for an *informational* turn, passing
  quote/line context in the message. **No manual Setup / security-config work required.**
- **Caveats to carry into the build:** (i) the reply is **natural-language text**, not typed JSON —
  correct for a guided-selling answer, but do NOT route the extract-and-apply turn through this path
  (that keeps its grounded-LLM extraction). (ii) Each call **consumes Einstein Requests/credits** —
  watch the trial entitlement. (iii) A known platform failure mode returns a generic *"Something went
  wrong. Try again."* even when `isSuccess=true` — handle it in the wrapper. (iv) Debug logs **truncate
  at the agent-callout boundary** — capture results structurally (e.g. a thrown `exceptionMessage`),
  not from trailing `System.debug`.
- **No functional code changed** (validation only). Numbered docs 02/03/04/07 annotated with this correction.

### 2026-07-17 — Guided-selling (ask 1): agent reachability investigation + corrected finding
> ⚠️ **SUPERSEDED 2026-07-19.** The "new API-enabled Service Agent + Agent API + OAuth" plan in
> this entry was **refuted** by a live smoke test — the existing agent is directly Apex-invocable
> via `generateAiAgentResponse`. See the **2026-07-19** entry at the top. Kept below for history.
- **Decision so far:** ask 1 = **invoke the real Agentforce agent**; and, given the blocker
  below, **publish a new API-enabled agent (Service Agent) reusing the same topic** — the
  user will do the Setup, I write the click-by-click guide + build the panel integration.
  *(Guide NOT yet written; integration NOT yet built. This entry is the checkpoint to resume from.)*
- **CORRECTION to the earlier "0 BotDefinitions" finding (that was wrong):** there are **3
  BotDefinitions**. The agent in the screenshot is **`Revenue_Quote_Management` — "Revenue
  Management Agent"** (`0Xxg8000001B9dhCAC`), and it is **live: v4 Active** (v1–v3 Inactive).
- **THE BLOCKER (why "just wire OAuth" won't work):** that agent's **`Type = InternalCopilot`**
  — an employee-facing Einstein Copilot that runs *inside* the Salesforce UI runtime. The public
  **Agent API** (`einstein/ai-agent/v1`) is designed to invoke **external Agentforce Service
  Agents** over REST via an API connection + OAuth; an InternalCopilot is not exposed on that
  public surface the same way. Supporting infra is also entirely absent:
  - **13 connected apps**, none an Agent-API OAuth app (they're b2bma/Demo Wizard/Pardot/
    Mixpanel/XDO/Q_Passport integrations).
  - **7 named credentials**, none pointing at an agent/einstein endpoint (all `Endpoint = None`).
- **What IS reusable (confirmed, so a new agent is a clone not a rebuild):**
  - Planner "brain": **`Revenue_Quote_Management_v2_v3_v4`** (`16jg8000000f3ZsAAI`, "Revenue
    Quote Management v4") — also a base `Revenue_Quote_Management` (`16jg8000000f3ZpAAI`).
  - Topic: **`ProductConfiguration`** (and a `_v4_Hu000000kJEu` variant) — this is the topic
    that answers "tell me more about the duty rating options."
  - Key actions on that topic (reuse verbatim): **`Configure_Product_Attributes`**,
    **`Get_Product_Attribute_Options`**, **`Get_QuoteLineItem_from_Quote`** (each also has a
    `_v4_Hu000000DE2X` variant). `Get_Product_Attribute_Options` is the same capability our
    grounding already leans on — so the agent's answer set is aligned with our catalog.
- **RESUME PLAN for ask 1 (next session):**
  1. Write the click-by-click Setup guide: (a) in Agent Builder, create/publish an **Agentforce
     (Service) Agent** that reuses the `ProductConfiguration` topic + the 3 actions above;
     (b) enable its **Agent API / connection**; (c) create the **connected app** (OAuth:
     client-credentials or JWT, scopes incl. `chatbot_api`/`api`/`sfap_api` as required);
     (d) create a **named credential** to the agent endpoint (`.../einstein/ai-agent/v1`).
  2. Build a panel **"question / guided-selling" turn**: detect an informational ask (vs. an
     extract-and-apply ask), call the agent via the named credential from Apex, render the
     answer as an assistant turn. Keep the existing extract/apply path untouched.
  - **Open sub-question to resolve at build time:** session lifecycle for the Agent API
    (start-session → send-message → keep sessionId) and how to pass quote/line context.
- **No functional code changed for ask 1** (investigation only).

### 2026-07-17 — Built the auto-apply toggle (ask 2)
- **What:** Added a rep-controllable **Auto-apply** mode to `configChatPanel`, seeded by a
  new Flow input `autoApplyDefault` (Boolean, default false).
  - **Flow default:** admin sets the screen's starting mode via `autoApplyDefault`.
  - **In-panel toggle:** rep flips auto ⇄ review per session (above the composer). The
    switch governs how the *next* extraction is handled — it never retroactively applies an
    already-rendered card. `autoApply` is copied from `autoApplyDefault` once in
    `connectedCallback` so a rep flip doesn't fight Flow re-hydration.
  - **Auto-apply path:** when ON *and* the proposal is clean, `_handleExtractionResult`
    calls `handleApply()` directly (skips the review card) → normal `APPLYING → RESULT`.
  - **Safety — strict "clean" gate (`_autoApplyBlockReason`):** auto-apply fires ONLY if the
    extraction came from the LLM (not the keyword fallback), ≥1 row exists, **every** row is
    valid, and **every** row grounds cleanly (reuses `_buildValueChangedItem`, so ambiguous
    labels / missing attributeId / unrecognized picklist values all block). Any failure
    **degrades to the manual review card** with a reason shown to the rep — the existing
    "never silently guess / never silently drop a value / no partial publish" guarantees are
    preserved. No change to the publish payload contract or ordering.
- **Files:** `configChatPanel.js`, `configChatPanel.html`, `configChatPanel.js-meta.xml`.
- **Verification:** LWC bundle deployed clean (1/1). No Apex touched. Live rep test pending.
- **Backup ref:** revert from `backups/2026-07-17_pre-guided-selling-and-autoapply/`.
- **Note:** ask 1 (guided-selling agent reuse) NOT built — ~~blocked on Agent API infra (below)~~.
  ⚠️ **The "Agent API infra blocker" was refuted 2026-07-19** — the agent is directly Apex-invocable.
  See the 2026-07-19 entry at the top.

### 2026-07-17 — Feature decisions + agent-invocation feasibility finding
> ⚠️ **The "Gap for the chosen path" below (needs Agent API + OAuth) was REFUTED 2026-07-19.**
> The existing agent is invocable from Apex via `generateAiAgentResponse` with no OAuth. See the
> 2026-07-19 entry at the top. Kept below for history.
- **Decision (ask 1 — guided selling):** **Invoke the real Agentforce agent** (not our own
  LLM re-implementation) so the panel reuses the exact Revenue Management agent's answers.
- **Decision (ask 2 — auto-apply):** **Add a toggle** (auto-apply vs. current review-first
  flow), rep/flow-selectable per session. Both paths kept.
- **Feasibility finding (org discovery):**
  - No `BotDefinition` rows, but **4 `GenAiPlannerDefinition`s** exist. The Revenue
    Management agent in the screenshot is almost certainly
    **`Revenue_Quote_Management_v2_v3_v4`** (Id `16jg8000000f3ZsAAI`, "Revenue Quote Management v4").
  - Relevant topic exists: **`ProductConfiguration`** GenAiPlugin (and a `_v4` variant) —
    this is what answers "tell me more about the duty rating options."
  - **Gap for the chosen path:** invoking a full agent from Apex/LWC uses the **Agent API**
    (REST `einstein/ai-agent/v1`), which requires OAuth plumbing that **does not yet exist**
    here: no Agent-API connected app, and none of the 7 named credentials point to an agent
    endpoint. Provisioning a connected app + OAuth + named credential is a **manual Setup
    task that touches live security config** → flagged to the user before building.
- **No functional code changed in this step** (discovery only).

### 2026-07-17 — Journal + backup created (gate before next features)
- **What:** Created this journal and `backups/2026-07-17_pre-guided-selling-and-autoapply/`.
- **Why:** User asked for a documented, revertible checkpoint before building
  guided-selling Q&A and auto-apply. No functional code changed in this step.
- **Verification:** Backup verified — 17 files copied.

### 2026-07-17 — Review-fix hardening on the LMS apply path
- **What:**
  (a) Success-card copy made **conditional** ("*If the configurator is open on this line…*")
      so it never overstates that a fire-and-forget publish took effect.
  (b) **Duplicate-label collision guard:** `ConfigLmsGroundingService` now computes
      per-attribute `ambiguousLabels` (labels mapping to >1 `AttributePicklistValue` Id);
      the LWC blocks Apply only on a row whose *selected* value is ambiguous (surgical, not
      global) and tells the rep to set it directly in the configurator.
  (c) Added a **cross-service label-set equality** test (getAttributes ↔ getLmsGrounding)
      and an `ambiguousLabels` shape test.
- **Why:** Code-review findings (2 MEDIUM + 1 MEDIUM/LOW). The conditional copy specifically
  protects the acceptance test from a false positive.
- **Files:** `ConfigLmsGroundingService.cls`, `ConfigLmsGroundingServiceTest.cls`,
  `configChatPanel.js`, `configChatPanel.html`.
- **Verification:** 5/5 tests pass, 92% coverage; both deploys clean; live click confirmed
  the round trip (see Verification status).

### 2026-07-17 — Re-architecture: Apply publishes `valueChanged` (replaces PST write)
- **What:** Rebuilt the Apply path to publish `valueChanged` (+ `updatePrices`) on
  `lightning__productConfigurator_notification` INTO the managed Data Manager, replacing the
  PST-based `applyConfiguration` write. Added `ConfigLmsGroundingService` for the label→0v6-Id
  + attributeId grounding. Removed the PST price-delta/diff result card (fire-and-forget has
  no synchronous result) in favour of a confirmation card.
- **Why:** Original feedback item (c): after applying, the screen did not refresh to show the
  latest values — the managed configurator ignored the external PST write. Publishing INTO the
  DM drives its native apply/reprice/re-render path, which fixes the stale-screen problem.
- **Files:** `ConfigLmsGroundingService(.cls/-meta/Test)`, `configChatPanel.js`, `configChatPanel.html`.
- **Verification:** Deployed clean; tests pass; live click + logs confirmed apply+reprice.
