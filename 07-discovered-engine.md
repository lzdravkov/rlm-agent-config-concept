# 07 · Discovered Engine — What Already Exists in the Target Org

> **This doc changes the whole project.** After enabling Agentforce in `rlm_agent_config_concept`, discovery
> revealed the org already contains a **complete, well-architected, product-agnostic configuration engine** —
> not just an agent. A large share of what docs [03](03-gap-analysis.md)/[04](04-corrected-architecture.md)/
> [05](05-project-plan.md) proposed to *build* already exists and is now **runtime-verified** against the exact
> generator scenario in the canvas.
>
> Everything below was read from retrieved metadata/Apex **and confirmed by two live agent runs** on
> **2026-07-17** (see [§8](#8-runtime-verification--two-live-agent-runs)). Treat it as the new baseline.
>
> **Verification status (2026-07-17):** the engine is **runtime-verified on `FESBA Generator Set` for two
> scenarios** — a simple change (DutyRating→DCC at 500 kW) and the hard two-step-PST conflict case (DCC + 1500 kW).
> It is **not** verified on any other product, and two facts below correct earlier drafts of this doc:
> **(a)** the save service returns **no pricing data** (§3, §7); **(b)** the real root attribute list is the 10 in
> §5 (earlier phantom attributes removed).

---

## 1. The org

| Fact | Value |
|------|-------|
| Alias | `rlm_agent_config_concept` (project default org) |
| Type | **Trial org, Enterprise Edition, `IsSandbox=false`** → a **production-type** org. Consequence: Apex deploys require **≥75% coverage + all tests green**; there are **0 Apex classes with tests today (0% coverage)**, so deploying the `@AuraEnabled` wrappers needs tests shipped alongside them and a `RunSpecifiedTests`-scoped deploy. |
| Expiry | **2026-08-17** (~1 month out). Gates the whole timeline — see [Decision D7](06-open-questions-and-decisions.md). |
| API version | **v67.0** → clears the v59+/FlowRuntimeV3 prereq ([Gap 21](03-gap-analysis.md) resolved) |
| Agent present | `Revenue_Quote_Management` — **NGA Agentforce agent** (`agentType=AgentforceEmployeeAgent`, template `quotingAI__QuotingEmployeeAgent`, `agentDSLEnabled=false`) |

**Agent type consequence:** it's an NGA agent, so `generateAiAgentResponse` (Legacy-Bot-only) **cannot** invoke it
from Apex ([Gap 13](03-gap-analysis.md) confirmed). Irrelevant to the chosen path, which never calls the agent
from server code — but it rules out any "have Apex talk to the existing agent" design.

> ⚠️ **CORRECTION (2026-07-19) — this "cannot invoke from Apex" claim is REFUTED.** A live smoke
> test invoked this exact agent (`Revenue_Quote_Management`, `0Xxg8000001B9dhCAC`, `Type=InternalCopilot`)
> synchronously from anonymous Apex via **`generateAiAgentResponse`** — `isSuccess=true`, real
> `ProductConfiguration`-topic reply, no OAuth/Agent-API/new-agent needed. The "Legacy-Bot-only"
> restriction did **not** apply here: the agent is registered as a `GENERATE_AI_AGENT_RESPONSE`
> custom invocable action. Contract: `Invocable.Action.createCustomAction('generateAiAgentResponse',
> 'Revenue_Quote_Management')`, input `userMessage` (+ optional `sessionId`), output `agentResponse`
> (JSON `{"type":"Text","value":"…"}`) + `sessionId`. So a "have Apex talk to the existing agent"
> design **is** viable — it's now the recommended path for the guided-selling turn. See the
> **2026-07-19** entry in [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md).

---

## 2. The configuration engine (the real find)

### Agent topic — `ProductConfiguration` (GenAiPlugin)
Guides a rep through step-by-step config of **any** configurable product on a quote: pull attributes → present →
validate against the CML constraint model → loop until valid → confirm → save. 8 planner instructions enforce
"never hardcode attribute names/values — always fetch at runtime" and correct ID handling (`0QL…` vs `0Q0…`).

### Four agent actions (GenAiFunction → autolaunched Flow → Apex)

| Action | Backing Apex | What it does |
|--------|--------------|--------------|
| `Get_QuoteLineItem_from_Quote` | `QuoteLineItemLookupService` | Partial product-name → `QuoteLineItem` Id (LIKE match) |
| `Get_Product_Attribute_Options` | `ProductAttributeService` | Runtime attribute discovery for a product |
| `Configure_Product_Attributes` | `ProductAttributeSaveService` | **Save + validate + reprice** via PST |
| `Save_Product_Configuration` | `ProductAttributeReadService` | Mark complete; read-back summary |

Each Flow is a thin wrapper (`invocationTargetType=flow`) over an `@InvocableMethod`.

---

## 3. How each critical gap is *already* handled

Reading the Apex line-by-line against [03-gap-analysis.md](03-gap-analysis.md):

| Gap | Status in existing engine | Evidence |
|-----|---------------------------|----------|
| **Gap 8** — runtime metadata discovery (no hard-coding) | ✅ **Solved** | `ProductAttributeService`: `QuoteLineItem → Product2.BasedOnId (ProductClassification) → ProductClassificationAttr → AttributeDefinition → AttributePicklistValue`. Filters `Status='Active' AND IsReadOnly=false AND IsHidden=false`. Returns `name/developerName/dataType/isRequired/isPriceImpacting/picklistValues`. |
| **Gap 5** — picklist silent-revert (missing `AttributePicklistValueId`) | ✅ **Solved** | `ProductAttributeSaveService`: builds a `value→Id` map from `AttributePicklistValue` and sets **both** `AttributeValue` and `AttributePicklistValueId` in the PST payload; **re-queries QLIA after save** to report the *actual* persisted value, not the input. |
| **Gap 15** — two-step PST for Number + Picklist | ✅ **Solved** | Splits selections into `numberSelections` (PST call 1) and `picklistSelections` (PST call 2). Comment documents the exact `DCC + 1500 kW` conflict: Number first lets the BOM resolver upgrade the component (FESBA_900→FESBA_1500), Picklist second applies duty-rating refinements. |
| **Gap 6** — persistence reprices | ✅ **Reprices** / ⚠️ **but returns no price** | PST runs with `PricingPreferenceEnum.SYSTEM` + `ConfigurationExecutionEnum.SYSTEM` ("Configure for Quote with root product"): saves QLIA, re-runs BOM, reprices. **Correction to earlier drafts:** the save service's `SaveOutput` has **only 5 fields — `isSuccess`, `isValid`, `savedAttributesJson`, `validationErrorsJson`, `errorMessage`. It returns *no* pricing at all** (no unitPrice/totalPrice/grandTotal). The repricing happens in the DB; surfacing the new price is a **NEW build item** (re-query the QLI/Quote after save), not a reuse. See [§3.1](#31-the-pricing-gap-corrected) and [§8](#8-runtime-verification--two-live-agent-runs). |
| **Gap E5** — `getSessionId()` null in agent Apex | ✅ **Dodged deliberately** | `ProductAttributeService` header: uses SOQL via `ProductClassificationAttr` "to avoid a PCM REST callout, which avoids the `UserInfo.getSessionId()` null-session issue in Agentforce execution contexts." Runtime-confirmed: engine runs fine in the no-UI-session agent context. |
| **Gap 14** — validate against config rules before/at save | 🟡 **CML runs, but result not surfaced** | PST evaluates the constraint model and silently auto-corrects (proven: DCC + 1500 kW recalculated derived kW and swapped the BOM child). **But** the save service **hardcodes `isValid = true` and always returns `validationErrorsJson = '[]'`** — it never reads a validation verdict back from PST. So CML *corrections* happen but are **invisible to the caller**. Surfacing "we changed X because Y" is a **build item**, done by diffing the post-save readback against the requested values. |

**Net:** the hardest, most failure-prone server-side work — runtime attribute discovery, picklist-ID resolution,
two-step PST sequencing, persistence, and repricing — is done and **now runtime-proven** (§8). The two things the
engine does *not* give us are **(a) the resulting price** and **(b) a surfaced validation/correction verdict** —
both are small post-save read-backs we build, not engine work.

### 3.1 The pricing gap (corrected)

An earlier draft of this doc claimed the save service "returns full pricing." **It does not.** Reading
`ProductAttributeSaveService.SaveOutput` (lines 45–60): the only fields are `isSuccess`, `isValid`,
`savedAttributesJson`, `validationErrorsJson`, `errorMessage`. There is **no pricing field**.

What this means for the POC:
- The engine **does** reprice in the database (PST with `PricingPreferenceEnum.SYSTEM`). Runtime-proven: the
  Quote `GrandTotal` moved to **$59,005** after the 1500 kW run.
- But to **show** the rep a price, our controller must **re-query** the QLI/Quote (`ListPrice/UnitPrice/TotalPrice`,
  `Quote.GrandTotal`) *after* the save returns. That post-save price read-back is **new build**, not reuse.
- **Do not trust the agent's spoken price.** In the live runs the NGA agent stated "$49,450 / $44,505" — which is
  the **unchanged root-line price**, identical across the 500 kW and 1500 kW runs. The price actually changed via
  **added/swapped BOM child lines** (e.g. the `FESBA 1500kW` model line at $2,500), which roll up to the Quote
  total. Because the save service returns no price, the agent has nothing grounded to quote — its number is
  ungrounded. Our LWC must surface the **re-queried** price, not narrate one. (See [§8](#8-runtime-verification--two-live-agent-runs).)

---

## 4. What the existing engine does *not* do (the delta for our POC)

The engine is **chat-native and save-based**. Our chosen POC ("reuse engine, build embedded LWC") differs on
two axes, and these define the remaining build:

1. **Not LWC-callable.** All four services are **`@InvocableMethod` only — none are `@AuraEnabled`.** An LWC
   cannot call them directly. → We need thin `@AuraEnabled` wrappers (or refactor shared logic that both the
   invocable and an `@AuraEnabled` controller call). **This is now build item #1.**
2. **No one-shot NL extraction.** The agent takes selections conversationally, one/few at a time; there is **no**
   "type 'prime power, 500 kW, 220/380V' → all fields at once" extraction step. → We still build the grounded
   NL→structured-fields extraction ([04 §4](04-corrected-architecture.md), Decision D2). The engine's
   `Get_Product_Attribute_Options` output is *perfect grounding input* for it (gives the exact `developerName`s
   and valid picklist values to constrain the model).
3. **It always persists + reprices (PST).** There is no "live preview without saving." → For the reuse path,
   **Decision D5 effectively resolves to "persist"** — the engine's whole value is the correct PST/pricing it
   already does. "Live-preview-only" would mean *not* using the save service, which throws away the main reason
   to reuse. (See the revised D5 in [06](06-open-questions-and-decisions.md).)
4. **In-place UI re-render is still unproven — and calling PST from a live configurator session carries a
   session-desync risk.** The engine persists via PST; whether the **standard Product Attributes component on the
   same configurator flow screen visibly re-renders** to show those persisted values (without a reload) is still
   the open question — this is the surviving **Spike 1** ([03 Gap 18](03-gap-analysis.md)). Two runtime-proven runs
   confirm the engine works **from the agent chat context** (no open configurator UI). They do **not** prove it is
   safe to call PST **while the configurator flow is open in the browser**: the runtime configurator holds its
   own in-memory transaction graph (`dataManager`), and a side-channel PST write could leave that graph stale
   (values change in the DB but the on-screen `dataManager` doesn't know). The managed runtime is also documented
   to expect **LMS** as the integration channel, not direct Save APIs. **Spike 1 must test the in-session case
   specifically** — persist via the wrapped service *while the flow is open* and observe whether the components
   reconcile, go stale, or error. If they go stale, the apply path becomes **LMS-preview-then-persist**
   ([D-new](06-open-questions-and-decisions.md)) rather than direct PST.

---

## 5. The real product model (grounding "answer key")

Confirmed by SOQL against the org (`ProductClassificationAttr` for `Generator Set PC` +
`AttributePicklistValue`), **re-verified 2026-07-17**. This replaces an earlier draft that listed phantom
attributes (`gc_desiredKw`, `gc_runningKw`, `Total_Power_Required_kW`, and `powerkW`-as-root) — **none of those
are on the root classification**; the corrected list is below.

- **Top-level configurable product:** `FESBA Generator Set` — Id `01tg80000047iP9AAI`, `Type=Bundle`,
  `ConfigureDuringSale=Allowed`, classification **`Generator Set PC`** (`11Bg800000F7lfuEAB`).
- **BOM models:** `FESBA 900kW / 1200kW / 1500kW / 1750kW / 2500kW` (`Model PC`), `Main Alternator` variants
  (Standby/Prime/Continuous/DCC), `Voltage PC` options (220/380 … 7976/13800), switchgear, misc.

### Root classification attributes — all 10 (the answer key)

| # | Label | DeveloperName | DataType | ReadOnly | Discoverable? |
|---|-------|---------------|----------|----------|---------------|
| 1 | Application/Emission Certification | `applicationEmissionCertification` | Picklist | no | ✅ |
| 2 | FB_max dB level | `dBMax` | Number | no | ✅ |
| 3 | Duty Rating | `DutyRating` | Picklist | no | ✅ |
| 4 | FB_Full Load Required (kW) | `requiredKW` | Number | no | ✅ |
| 5 | Reserve Capacity (kW) | `reserveCapacityKW` | Number | **yes** | ❌ system-derived |
| 6 | Seismic Certification | `seismicCertification` | Picklist | no | ✅ |
| 7 | Special Application | `specialApplication` | Picklist | no | ✅ |
| 8 | Standards and Compliance | `standardsAndCompliance` | Picklist | no | ✅ |
| 9 | Surge Load (kW) | `surgeLoadKW` | Number | **yes** | ❌ system-derived |
| 10 | FB_Voltage | `Voltage` | Picklist | no | ✅ |

**8 discoverable, 2 read-only derived.** `ProductAttributeService` filters `IsReadOnly=false`, so
`reserveCapacityKW` and `surgeLoadKW` are (correctly) **not** offered for extraction — the engine computes them.
This is exactly what the live run showed: submitting `requiredKW=1500` caused the BOM to recalculate
`reserveCapacityKW 125→375` and `surgeLoadKW 625→1875` on its own.

### Picklist values (the real ones)

| Attribute | Valid values |
|-----------|--------------|
| `DutyRating` | `Continuous Power (COP)`, `Data Center Continuous (DCC)`, `Emergency Standby Power (ESP)`, `Prime Power (PRP)` |
| `Voltage` | `220/380`, `240/416`, `255/440`, `277/480`, `347/600`, `2400/4160`, `7200/12470`, `7621/13200`, `7976/13800` |
| `applicationEmissionCertification` | `Install-US-Stat`, `Install-OutsideUS` |
| `seismicCertification` | `IBC Seismic Certification`, `OSHPD Seismic Certification` |
| `specialApplication` | `Motor Starting`, `None - Standard` |
| `standardsAndCompliance` | `Certification-CSA`, `Listing-UL 2200` |

> The **real** DutyRating values are the four above (not "PRP/COP/ESP/SBY" as guessed in
> [04](04-corrected-architecture.md)'s sample JSON) — the hallucination-risk that grounding + validation
> ([Gap 11](03-gap-analysis.md)) exists to catch.

### Name vs Value — the portability trap (confirmed not to bite *this* product, but latent)

For **every** FESBA picklist above, `Name == Value == Code == DisplayValue` (verified). **But** the two services
disagree internally on which field they read/write:
- `ProductAttributeService` (discovery) emits the picklist **`Name`** (line 127) — what the model/user sees.
- `ProductAttributeSaveService` (save) keys its `value→Id` map on the picklist **`Value`** (line 118) — what it
  matches the submitted string against.

On FESBA this is harmless because Name==Value. On any product where they differ (a real counterexample exists
elsewhere in this org — a Fuel Cell "Certificate" with `Name='CSA_C22.2'` but `Value='UL2200 & CSA C22.2'`), the
discovered string won't match the save map, `AttributePicklistValueId` won't be set, and the picklist will
**silently revert** ([Gap 5](03-gap-analysis.md)). **For the "scalable to other products" requirement, align both
services on the same field** (recommend `Value`, or return both Name+Value from discovery and submit `Value`).

### `powerkW` is a BOM-child attribute, not root

`powerkW` (Picklist) lives on the **FESBA model child line** (e.g. `FESBA 1500kW`, QLI `0QLg8000001RZVlGAO`), not on
the root classification. The live 1500 kW run upgraded it `900→1500` on the child as the BOM resolved. It is not a
field the extraction step targets; it's an *output* of the engine's BOM logic.

---

## 6. Other prototypes already in the org (context, not dependencies)

- **`renderDraw3DConfigurationPrototype`** (LWC) + **`RenderDraw_Product_Configurator_Flow`** (Flow) — someone
  has prototyped a **custom configurator UI** (likely the 3D-visualization angle the canvas listed out of scope).
  Not a dependency for our POC, but proves Option C (custom UI on the Configurator API) is already being explored
  here — useful fallback context if Spike 1 fails.
- 45 total LWCs, 59 flows, other RLM agents (`Billing_Employee_Assistance`, `Sales_Planning`) — unrelated.

---

## 7. Implication summary

| Original plan assumed we'd build… | Reality |
|-----------------------------------|---------|
| Metadata-discovery service (Gap 8) | ✅ Exists (`ProductAttributeService`) — wrap for LWC |
| PST persistence w/ picklist-ID handling (Gap 5) | ✅ Exists (`ProductAttributeSaveService`) — wrap for LWC |
| Two-step PST sequencing (Gap 15) | ✅ Exists **+ runtime-proven** (DCC + 1500 kW, §8) |
| Price surfacing (Gap 6) | ⚠️ **Half** — engine reprices in DB, but the save service returns **no price**. Re-querying QLI/Quote to *show* the price is **new build**. |
| CML validation surfacing (Gap 14) | ⚠️ **Half** — CML runs + auto-corrects, but the service hardcodes `isValid=true`/`errors=[]`. Surfacing corrections is **new build** (diff readback vs request). |
| Grounded NL→fields extraction (Gaps 4, 7, 11) | ❌ **Still to build** — but grounding data comes free from `Get_Product_Attribute_Options` |
| Embedded LWC + in-place update via LMS (Gaps 1, 2, 18) | ❌ **Still to build + Spike** — the core remaining risk |
| Review/edit UX, audit log (Gaps 10, 19) | ❌ Still to build |

The project shrinks from "build the whole stack" to **"build a thin extraction + embedded chat LWC on top of a
proven engine, add price/validation surfacing, and prove the in-configurator re-render."** See revised
[05-project-plan.md](05-project-plan.md).

---

## 8. Runtime verification — two live agent runs (2026-07-17)

The engine had been read but never run (0 QLIAs existed at discovery). We enabled a persisted debug trace on the
authenticated user and ran the NGA agent end-to-end twice against quote `0Q0g80000017wQ5CAI` (root FESBA line
`0QLg8000001RYgDGAW`). Both runs converted "read but unproven" into **proven**.

### Run 1 — simple change (DutyRating → DCC, kW left at 500)
- Engine ran end-to-end; `DutyRating` persisted with a valid `AttributePicklistValueId` (`0v6g8000000FQArAAO`) —
  **no silent revert** (Gap 5 handling works live).
- Root FESBA line priced List `49450` / Unit `49450` / Total `44505`.
- Cost: **CPU 2322 ms, 3 SOQL, 0 DML** in the save transaction.
- Discovered attributes span **root + BOM children** (e.g. `FB_Voltage` present on multiple child QLIs).

### Run 2 — the conflict case (DCC + 1500 kW) — **two-step PST proven**
This is the exact scenario the save service's comment is written for. It worked correctly:
- `requiredKW = 1500.0` persisted on the root — **no revert** (the single-call failure mode was avoided).
- The BOM child `powerkW` upgraded **900 → 1500** (`pvId …FQAlAAO → …FQAKAA4`); the `FESBA 1500kW` child line
  (`0QLg8000001RZVlGAO`, L26, $2,500) was added and the 900 kW child removed.
- System-derived numbers recalculated: `reserveCapacityKW 125 → 375`, `surgeLoadKW 625 → 1875`.
- `DutyRating = DCC` retained through the whole sequence.
- Cost: **CPU 4252 ms, 3 SOQL, 0 DML**; ~10 s wall-clock for the persist+reprice alone.

### The high-value finding for the demo narrative: **the agent's spoken price is ungrounded**
The agent stated **"$49,450 / $44,505" in *both* runs** — word-for-word identical, even though Run 2 materially
changed the configuration. That number is the **unchanged root-line price**; the actual change flowed through
**BOM child lines**, moving the Quote **`GrandTotal` to $59,005** (`TotalPrice` also 59,005). Because the save
service returns no price (§3.1), the agent has nothing grounded to say and is echoing stale context. **Design
implication:** our LWC must display a **re-queried** price (root line + Quote total, and ideally the added/removed
child lines), never a model-narrated one. This is both a correctness fix and a strong demo talking point ("here's
why grounding matters").

> A ~$1,400 mid-refresh discrepancy was seen once (a screenshot showed $57,605 while the settled total is
> $59,005) — most likely tax/rollup recalc timing. Worth pinning down during Spike 1, not a blocker.

### Performance signal
Persist + reprice **alone** is ~2.3 s (simple) to ~4.3 s CPU / ~10 s wall-clock (conflict case) — already close to
the old "<5s end-to-end" wish. This is why [05](05-project-plan.md) keeps **suggest** and **apply** as separate
user actions and sets a **measured P75** target rather than a flat number.

### What is still NOT proven by these runs
- Everything ran in the **agent chat context** (no configurator UI open). The **in-configurator re-render /
  in-session PST** behavior is still **Spike 1** (§4 item 4).
- Only `FESBA Generator Set` was exercised. **Multi-product scale** (esp. the Name-vs-Value trap, §5) is untested.
- No `@AuraEnabled` path was exercised — the services ran as invocable methods via the agent.
