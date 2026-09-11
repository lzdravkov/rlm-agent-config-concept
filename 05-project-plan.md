# 05 · Revised Project Plan (Reuse-Engine Path)

> **Rewritten 2026-07-17** after org discovery ([07-discovered-engine.md](07-discovered-engine.md)) and your
> direction: **reuse the existing configuration engine, build the embedded-LWC experience** the canvas
> envisioned. This is a much smaller, lower-risk project than the original build-everything plan, because the
> hard server-side work (PST persistence, picklist-ID handling, two-step sequencing, repricing, runtime metadata
> discovery) **already exists and is now runtime-verified** in `rlm_agent_config_concept`.
>
> **Verification update (2026-07-17):** two live agent runs proved the engine end-to-end — a simple change and
> the hard **DCC + 1500 kW two-step-PST conflict** ([07 §8](07-discovered-engine.md)). Two corrections to the
> earlier plan followed: the save service **returns no price** and **hardcodes its validation verdict**, so
> **surfacing price and surfacing CML corrections are small NEW build items** (post-save re-query / diff), not
> free reuse.

**Chosen direction:** *Reuse engine, build embedded LWC.* Chat panel embedded **inside** the Product
Configurator flow screen; grounded NL→fields extraction on top; apply via the existing engine (which persists +
reprices); prove in-configurator re-render.

**Target:** org `rlm_agent_config_concept`, product **`FESBA Generator Set`** (`01tg80000047iP9AAI`),
attributes `DutyRating` (Picklist: COP/DCC/ESP/PRP) + `requiredKW` and other kW Numbers.

---

## What changed from the pre-discovery plan

| Was going to build | Now |
|--------------------|-----|
| Metadata-discovery service | ♻️ **Reuse** `ProductAttributeService` (wrap for LWC) — *runtime-proven* |
| PST persistence + picklist-ID + two-step + reprice | ♻️ **Reuse** `ProductAttributeSaveService` (wrap for LWC) — *two-step proven on DCC + 1500 kW* |
| Suggestion→save→readback | ♻️ **Reuse** `ProductAttributeReadService` |
| Grounded NL→structured extraction | 🔨 **Build** (new — the core IP of *this* POC) |
| Embedded chat LWC + review/edit + LMS in-place update | 🔨 **Build** (the canvas experience) |
| `@AuraEnabled` access to the engine | 🔨 **Build** (thin wrappers — services are invocable-only today) |
| **Price surfacing** (re-query QLI/Quote after save) | 🔨 **Build (small, new)** — save service returns no price ([07 §3.1](07-discovered-engine.md)) |
| **Validation/correction surfacing** (diff readback vs request) | 🔨 **Build (small, new)** — service hardcodes `isValid=true`/`errors=[]` |
| **Picklist Name↔Value alignment** (for multi-product scale) | 🔨 **Build (small)** — services disagree on field; latent silent-revert off FESBA ([07 §5](07-discovered-engine.md)) |
| Audit log | 🔨 **Build** (small) |

---

## Guiding principles

1. **Don't rebuild the engine — wrap it.** Every server-side capability we need already exists as tested Apex.
   Our job is a thin extraction layer + an embedded UI, not a re-implementation.
2. **Ground the model in the engine's own output.** `Get_Product_Attribute_Options` returns the exact
   `developerName`s and valid picklist values — feed that straight into the extraction prompt as grounding.
   No hard-coded attribute lists, ever.
3. **Human in the loop.** Suggest → review/edit → apply. Never auto-commit a revenue-affecting, repriced config
   silently — especially since Apply here *does* persist and reprice.
4. **De-risk the one thing still unknown first.** The only surviving high risk is whether the standard
   configurator UI visibly re-renders after our apply. Spike it before building the full UX.

---

## Phase 0 — Foundations (mostly already satisfied)

- [x] Org confirmed: `rlm_agent_config_concept`, API **v67.0**, Agentforce on. ([07 §1](07-discovered-engine.md))
- [x] Engine confirmed present, read, **and runtime-verified end-to-end** (two agent runs). ([07 §2–3, §8](07-discovered-engine.md))
- [x] Target product + **authoritative 10-attribute answer key** + real picklist values captured. ([07 §5](07-discovered-engine.md))
- [x] Test quote with a `FESBA Generator Set` line exists and is configured: `0Q0g80000017wQ5CAI`, root line
      `0QLg8000001RYgDGAW` (currently DCC + 1500 kW, GrandTotal $59,005).
- [x] Cloned configurator flow exists: **`Agent_Product_Configurator_Flow`** (Draft/inactive; carries all managed
      `runtime_industries_cfg:*` components). You'll activate it + set it as the default product configurator.
- [ ] **Confirm an entitled extraction model** in the org (`ConnectApi.EinsteinLLM` / Prompt Builder / Gateway)
      and pick it. (Decision **D2**) — *hole-poking confirmed `ConnectApi.EinsteinLLM` returns markdown-fenced
      free text, no structured output on this org's Apex path, and only the `PromptBuilderPreview` app name works.
      Plan: fence-strip + Apex-validate; confirm the exact model in Spike 2.*
- [ ] ⚠️ **Set up an Apex test baseline before any deploy.** This is a **production-type org** (`IsSandbox=false`)
      with **0% coverage today**, so deploying the `@AuraEnabled` wrappers requires ≥75% coverage + green tests.
      Write tests alongside the wrappers; deploy with `RunSpecifiedTests`. ([07 §1](07-discovered-engine.md))

**Gate 0:** model chosen + FESBA quote line confirmed (done) + a plan for the test baseline needed to deploy Apex
into this production-type org.

---

## Phase 1 — Validation spikes (de-risking)

Two spikes now (extraction accuracy + in-configurator re-render). Latency is lower-risk than before because we
know the exact server path, but we still measure it.

### Spike 1 — Does the standard configurator UI re-render after our apply, **while the flow is open**? *(the surviving high risk — [03 Gap 18](03-gap-analysis.md))*
Because the reuse path **persists via PST**, "apply" changes the DB + reprices. The engine is proven from the
**agent chat context** ([07 §8](07-discovered-engine.md)) — but *not* while the configurator UI is open, where the
runtime holds its own in-memory transaction graph (`dataManager`). A side-channel PST write could leave that graph
**stale** (DB changes, on-screen state doesn't). This spike is specifically the **in-session** case:
- Embed a trivial LWC in **`Agent_Product_Configurator_Flow`** that calls the (wrapped) save service for one
  attribute **while the flow is open in the browser**.
- **Observe three things:** (1) do the standard **Product Attributes** / **Prices** components visibly reflect the
  new value + **re-queried** price **in place**? (2) does the on-screen `dataManager` graph **reconcile** or go
  stale (e.g. a later manual edit clobbers the PST write, or vice-versa)? (3) any error from concurrent
  transaction graphs.
- Also test the **LMS `VALUE_CHANGE`** route ([04 Option B](04-corrected-architecture.md)) to update the session
  UI *before/instead of* a full save — the managed runtime is documented to expect **LMS** as the integration
  channel, not direct Save APIs, so this may be the *only* clean path.
- **Gate 1:**
  - ✅ re-renders + reconciles cleanly after PST → embed our chat LWC directly in the configurator flow, apply =
    direct PST persist ([D-new](06-open-questions-and-decisions.md) option a).
  - 🟡 only reflects/reconciles via LMS, not after a raw PST → apply = **LMS-preview then explicit save**; sequence
    carefully ([D-new](06-open-questions-and-decisions.md) option b).
  - ❌ won't reflect / graph desyncs → pivot to **Option C** (custom UI on the Configurator API — the org already
    has `renderDraw3DConfigurationPrototype` exploring this) or **advisor-only** (agent suggests, rep selects in the
    standard UI). Re-scope.

### Spike 2 — Extraction accuracy on realistic input *(Gaps 11, 12)*
- Build a **~50-prompt eval set** for the FESBA generator (abbreviations, partial specs, ambiguity, invalid
  values, multi-field: "prime power ~500 kW, low reserve"). Answer key = the real attribute/picklist values in
  [07 §5](07-discovered-engine.md).
- Ground the model with `Get_Product_Attribute_Options` output; measure % ≥3 valid fields, % valid picklist
  values, hallucination rate, P50/P95 latency of the model call.
- **Gate 2:** ≥85% ≥3 valid fields, ≥95% valid picklist values → proceed; else tune grounding/prompt or narrow
  fields.

> **Latency note (now measured, not estimated):** the persist+reprice step alone measured **CPU 2322 ms** (simple
> change) to **4252 ms** (DCC + 1500 kW conflict), **~10 s wall-clock** for the conflict case
> ([07 §8](07-discovered-engine.md)) — and that's *before* adding the model-extraction call (1–3 s) and the
> post-save price re-query. So the **persist path by itself brushes the old "<5s" wish.** This is why apply is a
> separate, progress-indicated user action and why criterion 8 is a **measured P75**, not a flat number. Confirm
> the full end-to-end P75 in the spikes.

**Phase 1 deliverable:** spike report → confirms the embed mechanism (Gate 1) + the accuracy/latency numbers.
This is the real go/no-go for the full build.

---

## Phase 2 — Core build (thin layer on the proven engine)

In dependency order:

- [ ] **`ConfigEngineController` (`@AuraEnabled`)** — thin wrappers exposing the existing services to LWC.
      Prefer refactoring each service's core into a shared method both the `@InvocableMethod` and an
      `@AuraEnabled` method call (avoid duplicating logic). Covers: get attributes, save selections, read saved.
      *(This is the #1 build item — the services are invocable-only today; [07 §4](07-discovered-engine.md).)*
      **Ship Apex tests with it** — production-type org, 0% coverage today, ≥75% required to deploy ([07 §1](07-discovered-engine.md)).
- [ ] **Price surfacing (new).** After the wrapped save returns, **re-query** the root QLI (`ListPrice/UnitPrice/
      TotalPrice`), the added/removed BOM child lines, and `Quote.GrandTotal`, and return them — the save service
      returns **no** price ([07 §3.1](07-discovered-engine.md)). The LWC shows this re-queried price, never a
      model-narrated one (the agent's spoken price was proven ungrounded — [07 §8](07-discovered-engine.md)).
- [ ] **Validation/correction surfacing (new).** The save service hardcodes `isValid=true`/`errors=[]`, so CML
      auto-corrections are invisible. **Diff the post-save readback against the requested values** to detect and
      explain "we changed X→Y because the configurator resolved it" (e.g. derived `reserveCapacityKW`/`surgeLoadKW`).
- [ ] **`ExtractionService` (`@AuraEnabled` or called by the controller)** — grounded model call with JSON-schema
      structured output + retry + type coercion; grounding built from `ProductAttributeService` output. (Gaps 4, 7, 11)
- [ ] **`SuggestionValidator`** — validate each field against the discovered metadata (valid picklist value? in
      range? known `developerName`?); fuzzy-match near-misses; confidence flags. (Gaps 11, 14)
- [ ] **`rlmConfigAssistant` LWC** — chat input → calls controller (discover → extract → validate) → **review/edit
      panel** (proposed values, warnings, price-impact note) → on **Apply**, call the wrapped save service
      (persists + reprices) and/or publish **LMS `VALUE_CHANGE`** per Gate 1 outcome; loading/progress, error
      handling, revert. (Gaps 1, 10, 17)
- [ ] Embed the LWC in the cloned configurator flow; set **"Revisited Screen Values → Refresh inputs."** (Gap 16)
- [ ] **`AgentConfigLog__c`** + logging on every suggest/apply (NL input, model output, applied values,
      accepted/edited, resulting price). (Gap 19)

> Note we do **not** build persistence, pricing, picklist-ID resolution, two-step PST, or metadata discovery —
> the engine already does all of it. We *call* it.

---

## Phase 3 — Hardening, eval & demo

- [ ] Full eval set end-to-end (NL → suggestions → review → apply → persisted + repriced → confirmed).
- [ ] Error paths: model timeout/malformed JSON, unmapped fields, invalid picklist value, **CML validation
      failure returned by the engine** (`isValid=false` + `validationErrorsJson`), PST error, latency
      degradation. (Gaps 4, 5, 11, 14, 17)
- [ ] UX pass: loading/progress, review/edit affordances, **price-change explanation using our re-queried
      `UnitPrice`/`TotalPrice`/`Quote.GrandTotal`** (not the save service — it returns none; [07 §3.1](07-discovered-engine.md)),
      revert. (Gaps 10, 17, 6)
- [ ] Latency measured vs the Gate 2 number under realistic data.
- [ ] Demo script (happy path + one graceful failure — e.g. a DCC + kW conflict the CML corrects — to show
      trustworthiness).
- [ ] "Path to production" doc: governance/approvals (Gap 22), multi-product generalization (engine is already
      product-agnostic — lean on that), multi-turn (could route through the existing NGA agent later), security
      review, and moving off a trial org.

---

## Revised scope

### In scope
- Chat-panel LWC embedded in the cloned Product Configurator Flow for `FESBA Generator Set`.
- Grounded NL→structured extraction (new), grounded in the engine's runtime attribute output.
- **Review/edit** step before applying.
- Apply via the **existing engine** (persist + reprice); in-configurator re-render proven in Spike 1.
- `@AuraEnabled` wrappers over the existing services.
- Error/latency handling; audit logging.

### Out of scope (POC)
- 3D visualization (separate `renderDraw3DConfigurationPrototype` prototype); keystroke-by-keystroke updates;
  multi-line/multi-product; multi-turn dialog (could later route to the existing NGA agent); production approval
  workflows (named as a follow-up, Gap 22); rebuilding any engine capability.

---

## Revised success criteria

| # | Criterion | Target |
|---|-----------|--------|
| 1 | User types a NL requirement in the embedded panel | ✔ |
| 2 | Extraction maps ≥3 **valid** attributes on realistic phrasing | **≥85%** of eval prompts |
| 3 | Suggested values valid against real metadata (no hallucinated picklist values applied) | **≥95%** valid |
| 4 | User can **review and edit/reject** before anything is applied | ✔ |
| 5 | On Apply, target fields + **price** update **in place** (no browser reload) | ✔ (Spike 1 confirms mechanism) |
| 6 | Applied values are **provably persisted** (engine already re-queries QLIA post-save) | ✔ *(runtime-proven)* |
| 7 | Price impact is **surfaced and explained** using our **re-queried** QLI/Quote pricing (not the save service) | ✔ |
| 8 | End-to-end **P75 latency** | **≤ ~12s** with visible progress (finalized in Spike; persist alone measured ~2.3–4.3 s CPU / ~10 s wall) |
| 9 | Every suggest/apply is **audit-logged** | ✔ |

> "No reload" = LMS/reactivity or post-PST re-render (Spike 1), not navigation. "<5s" is dropped in favor of
> measured P75. Criterion 6 is runtime-proven (the engine's post-save QLIA readback works live — [07 §8](07-discovered-engine.md)).
> Criterion 7 is a **small new build** (post-save price re-query), because the save service returns no price.

---

## Risk register (updated for reuse path)

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Configurator UI won't re-render / **`dataManager` graph goes stale** after an in-session PST | Medium | High | **Spike 1 (in-session)** → LMS-preview-then-persist, else Option C (custom UI, already prototyped here) / advisor-only |
| Extraction accuracy too low on real phrasing | Medium | Medium | **Spike 2**; ground in engine output; validate; narrow fields |
| **No structured output** on this org's `ConnectApi.EinsteinLLM` Apex path (returns fenced free text) | High (confirmed) | Medium | Fence-strip + Apex-validate against the discovered metadata; only `PromptBuilderPreview` app works; confirm model in Spike 2 |
| Apply reprices → unexpected total surprises the rep; **agent's spoken price is ungrounded** | Medium | Medium | Surface a **re-queried** price (not the save service, not the agent's words); review step before apply ([07 §3.1, §8](07-discovered-engine.md)) |
| **Deploying Apex into a production-type org (0% coverage)** blocks the build | High | High | Write tests with the wrappers; deploy via `RunSpecifiedTests`; budget for it in Phase 2 |
| **Trial-org expiry 2026-08-17** (~1 month) | High | High | Gate/sequence the work against it (D7); metadata is deployable to a fresh org if needed |
| **Name≠Value picklist silent-revert** on products other than FESBA | Medium | Medium | Align both services on one field (recommend `Value`); test a second product before claiming multi-product scale ([07 §5](07-discovered-engine.md)) |
| Wrapping services introduces divergence from invocable logic | Low | Medium | Refactor shared core method; don't fork logic |
| CML auto-corrects a combo **silently** (`isValid` hardcoded true) | Medium | Medium | Diff post-save readback vs request to detect + explain the correction; show in review panel |
