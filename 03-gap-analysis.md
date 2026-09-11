# 03 · Gap Analysis — Holes in the Canvas Plan

Ranked by severity. Each gap: what the canvas assumes, why it's wrong/incomplete, what breaks if unaddressed,
and the concrete fix. All three adversarial critique passes (technical-feasibility, RLM-domain,
product/UX/delivery) independently surfaced the CRITICAL items below — that convergence is itself a signal.

Severity key: 🔴 **Critical** (blocks the plan) · 🟠 **High** (breaks in real use / misses a success criterion)
· 🟡 **Medium** (quality, portability, or UX) · ⚪ **Low** (hygiene / prerequisite).

---

## 🔴 Critical — these block the canvas architecture as written

### Gap 1 — `FlowNavigate` cannot re-render the current screen
- **Canvas:** "Apply → LWC fires `FlowNavigate` → Flow **re-renders the current screen** with values, no reload."
- **Reality:** No such event. Flow navigation *always* leaves the screen; the pattern doesn't exist
  ([02 §D1](02-research-findings.md)).
- **If unaddressed:** clicking Apply navigates away (or errors on the last screen). The core interaction never
  works. Also, firing attribute-change + navigation together is a documented race-condition anti-pattern (§D3).
- **Fix:** In-place updates come from **`FlowAttributeChangeEvent` reactivity** *and*, inside the managed
  configurator, from **LMS `VALUE_CHANGE` events to the Data Manager**. No navigation on Apply.

### Gap 2 — Config fields are attribute metadata, not Flow variables
- **Canvas:** "LWC maps JSON → `@api` output properties → **Flow variables** → fields populate."
- **Reality:** Fields are **`AttributeDefinition`-driven** and rendered by the managed Product Attributes
  component fed by the hidden Data Manager. Setting Flow variables does **not** update them
  ([02 §B1](02-research-findings.md)).
- **If unaddressed:** the LWC "succeeds," Apply is clicked, and **nothing changes** in the attribute fields.
- **Fix:** Communicate with the Data Manager via **LMS `VALUE_CHANGE`** (Option B), or build a custom UI on the
  **Configurator API** (Option C). Requires runtime attribute-metadata discovery (see Gap 8).

### Gap 3 — LWC cannot call the Agent API directly (CORS)
- **Canvas:** "The LWC calls the Agentforce Agent API directly and gets back JSON."
- **Reality:** **CORS-blocked** from Lightning domains; a server hop is mandatory
  ([02 §E1](02-research-findings.md)).
- **If unaddressed:** every agent call fails in-browser; zero functionality.
- **Fix:** **LWC → imperative Apex → model/agent.** If using an agent, `generateAiAgentResponse` (~~Legacy Bot
  only, **not** NGA~~ — **but see 2026-07-19 correction under Gap 13: it invoked this org's NGA/Employee agent
  successfully**). Recommended for the *extract-and-apply* turn: Apex → `ConnectApi.EinsteinLLM` / Gateway
  structured output (see Gap 7 & doc 4); use `generateAiAgentResponse` for the *guided-selling* turn.

### Gap 4 — Agent returns conversational text, not structured JSON
- **Canvas:** agent returns `{DutyRating, FullLoadKW, Voltage, MaxDB}`.
- **Reality:** `outputText` is natural language; typed output needs a `GenAiFunction outputSchema` or a
  schema-enforced model call, **plus** Apex parsing/validation/retry ([02 §E3, §F2](02-research-findings.md)).
- **If unaddressed:** brittle regex parsing; missing/hallucinated fields; failure rate that spikes on real
  phrasing.
- **Fix:** Use **structured outputs** (`response_format` + JSON schema, `strict:true`) and **validate in Apex**
  against the product's real metadata before returning to the LWC.

### Gap 5 — Persisting attributes requires PST, with a picklist silent-failure trap
- **Canvas:** treats "populate field" and "value is saved" as the same thing.
- **Reality:** Persistence is **PST-only** (DML fails). For picklists, PST needs **both** `AttributeValue` **and**
  `AttributePicklistValueId`; a missing ID makes PST report success while the value **silently reverts**
  ([02 §C3, §C4](02-research-findings.md)).
- **If unaddressed:** demo appears to work on text fields; **picklist attributes (Duty Rating, Voltage) silently
  fail** — the worst kind of bug (success toast, no change, no error).
- **Fix:** Resolve `AttributePicklistValueId` from metadata for every picklist value; include both fields in the
  PST payload; **re-query after save to confirm** and surface a real error if it reverts.

### Gap 6 — "Price recalculation out of scope" is incoherent if we persist
- **Canvas:** explicitly lists price recalc as out of scope.
- **Reality:** PST **atomically re-runs pricing**; price-impacting attributes (very likely kW / Duty Rating)
  trigger `AttributeBasedAdjustment` rules. You can't save without repricing; `applyPricing:false` breaks BOM
  application too ([02 §C3](02-research-findings.md)).
- **If unaddressed:** either the config doesn't save correctly, or the Grand Total changes unexpectedly and the
  agent never explains it → support escalations, lost trust.
- **Fix:** Either (a) **POC stays "live-preview only"** — inject values into the session via LMS, do **not** PST,
  so no persistence/pricing (cleanest way to honor "no repricing" at POC), or (b) **persist and make price a
  first-class, explained outcome** ("Prime Power at 500 kW → +$X"). Decide explicitly (see doc 6, Decision D5).

---

## 🟠 High — will break in real use or miss a stated goal

### Gap 7 — Full conversational Agent is the wrong/heavy tool for one-shot extraction
- One sentence → 4 fields doesn't need planner/topic/action orchestration; the agent adds latency, cost,
  non-determinism, and test difficulty ([02 §F1](02-research-findings.md)).
- **Fix:** Grounded **Prompt Template / `ConnectApi.EinsteinLLM` / Gateway** structured-output call for the POC;
  keep a full agent as an explicit Phase 2 option for multi-turn dialog.

### Gap 8 — No attribute-metadata mapping strategy (API names + picklist value IDs)
- Canvas field names are display labels; real ones are `DeveloperName`/`Code`, and picklists need value IDs.
  Hard-coding breaks across products/orgs ([02 §B3, §C4](02-research-findings.md)).
- **Fix:** Apex **metadata-discovery service** — query `AttributeDefinition` (+ `AttributePicklistValue`) for the
  product at runtime, cache per transaction, expose a `{label → {devName, dataType, picklistValues[]}}` map to
  both the prompt (for grounding) and the write path.

### Gap 9 — < 5s round trip is unrealistic
- Agent P75 ≈ 8–9s; even a grounded prompt call + validation + LMS (+ optional PST/pricing) won't reliably beat
  5s ([02 §E4](02-research-findings.md)).
- **Fix:** Revise the criterion to **P75 ≤ ~10s** (grounded prompt path) with an explicit loading state; treat
  <5s as a non-goal. Measure real latency in Spike 2 and set the number from data.

### Gap 10 — No review / edit / undo before applying AI values
- Canvas is one-click Apply. AI values affect validity and price; users must be able to inspect and reject.
- **Fix:** **Suggest → Review (editable, with warnings) → Apply.** Cache pre-apply values to offer "revert."

### Gap 11 — No grounding → hallucinated attribute values
- Without injecting allowed values, the model returns things like "Voltage: 240V" when the picklist is
  `120/208 · 220/380 · 230/400` ([02 §F3](02-research-findings.md)).
- **Fix:** Grounded prompt (Gap 8 map) + validate output against `AttributePicklistValue`; fuzzy-match with user
  confirmation, or reject with a helpful message.

### Gap 12 — No agent/extraction evaluation strategy
- "Maps ≥4 fields" has no accuracy bar and no test set; a cherry-picked demo sentence proves nothing.
- **Fix:** Build a **≥50–100 prompt eval set** (abbreviations, partial specs, ambiguous, invalid values).
  Measure: % ≥N valid fields, % valid picklist values, P50/P95 latency, human acceptance. Set gates
  (e.g. ≥85% ≥3 valid fields, ≥95% valid picklist values).

### Gap 13 — Legacy Bot vs NGA agent not specified (only relevant if agent-first)
- `generateAiAgentResponse` supports **Legacy Bot only**; building an NGA `.agent` then wiring it to Apex fails
  ([02 §E2](02-research-findings.md)).
- **Fix:** If we go agent-first, use a **Legacy Bot**. If we use the recommended `EinsteinLLM`/Gateway path, this
  gap disappears.

> ⚠️ **CORRECTION (2026-07-19) — the "Legacy Bot only" premise is REFUTED for this org's agent.** A live
> smoke test invoked the existing `Revenue_Quote_Management` agent (`Type=InternalCopilot` /
> `AgentforceEmployeeAgent`) synchronously from Apex via `generateAiAgentResponse` — `isSuccess=true`,
> real topic-driven reply, no OAuth or REST Agent API. The action targets the agent by its
> **API/developer name** through `Invocable.Action.createCustomAction('generateAiAgentResponse', '<agentName>')`;
> input `userMessage`, output `agentResponse`. This reopens the "agent-first" option **without** requiring a
> Legacy Bot. (The skill's "Legacy-Bot-only" note reflects an older action variant; it did not hold here.)
> Details + verified contract in [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) (2026-07-19).

### Gap 14 — No validation of suggestions against constraint rules before Apply
- Constraint/config rules auto-run on save and can reject or "peel" values; the canvas has no pre-check
  ([02 §C6](02-research-findings.md)).
- **Fix:** Optionally call **Run Config Rules Action** on the proposed set before Apply; show violations in the
  review panel ("220/380V requires Max dB ≤ 85; adjusting").

---

## 🟡 Medium — portability, correctness under real catalogs, UX polish

### Gap 15 — Two-step PST sequencing for Number + Picklist (only if we persist)
- Mixing kW (Number) and Duty Rating (Picklist) in one PST can conflict; sequence two calls
  ([02 §C5](02-research-findings.md)). Adds latency; verify on the target product.

### Gap 16 — Revisited-screen value persistence gotcha
- "Preserve all other field values" depends on the screen's "Revisited Screen Values" setting; default can wipe
  user entries on Back→Next ([02 §D4](02-research-findings.md)). Set to "Refresh inputs…"; test the full journey.

### Gap 17 — No async / loading-state UX
- With ~8–12s latency, a silent button invites double-clicks and "it's broken" perceptions.
- **Fix:** Disable Apply on click; show staged progress ("Analyzing… Validating… Updating…"); consider streaming.

### Gap 18 — Standard Product Attributes component may not visibly react to LMS updates
- **[verify]** It's not documented whether the standard component *re-renders* on every third-party LMS update or
  whether third-party components are meant to *replace* it. This is exactly Spike 1's job.
- **Fix:** Spike it. If it won't reflect updates, pivot to **Option C** (custom UI on Configurator API) or an
  **advisor-only** UX (agent suggests; user selects in the standard UI).

### Gap 19 — No audit trail for AI-applied configuration
- For revenue-affecting quotes, who/what set a value (and from what NL input) matters for support & compliance.
- **Fix:** Log to a custom object: quote/line IDs, raw NL input, model output, applied values, user-accepted vs
  edited, timestamp, session id.

### Gap 20 — Product-catalog prerequisites assumed to exist
- The plan presumes `AttributeDefinition`s, picklist values, and BOM rules for the target product already exist.
- **Fix:** Add a **prerequisite checklist**; confirm the target product is fully modeled before build (doc 6).

---

## ⚪ Low — hygiene

### Gap 21 — Org prerequisites unverified
- Reactivity needs **API v59+** and **FlowRuntimeV3** enabled; the configurator + RLM features must be enabled in
  the target org ([02 §D2](02-research-findings.md)). Verify in Setup before Phase 1.

### Gap 22 — Governance / approvals for high-value AI-driven quotes
- Auto-populating a $100k generator config may need to respect existing approval policy.
- **Fix:** Out of scope for POC is fine, but **name it** as a production consideration; don't let a demo pattern
  imply it's production-ready.

---

## Severity roll-up

| Severity | Count | Gap #s |
|----------|-------|--------|
| 🔴 Critical | 6 | 1, 2, 3, 4, 5, 6 |
| 🟠 High | 8 | 7, 8, 9, 10, 11, 12, 13, 14 |
| 🟡 Medium | 6 | 15, 16, 17, 18, 19, 20 |
| ⚪ Low | 2 | 21, 22 |

The six critical gaps are all in the canvas's **integration mechanics**, not its **vision** — which is why the
recommendation is *re-architect and spike*, not *abandon*.
