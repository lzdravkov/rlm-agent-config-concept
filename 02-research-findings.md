# 02 · Research Findings

Every load-bearing assumption in the canvas, tested against official Salesforce documentation, the Revenue
Lifecycle Management Developer Guide, internal code search, the RLM skills (`rlm-product-configurator`,
`rlm-pricing`, `rlm-agentforce`), and internal Slack. Verdicts are **confirmed / partly-true / refuted /
uncertain**. Confidence and sources are given so you can audit any line.

> Legend — **✅ confirmed · 🟡 partly-true · ❌ refuted · ❔ uncertain**. **[verify]** = rests on model
> knowledge or a single source; a spike should confirm it before we rely on it.

---

## A. The RLM Product Configurator platform

### A1. "The RLM configurator is a Screen Flow the team can edit" — ✅ Confirmed (high)
Salesforce ships a **Default Product Configurator Flow**. Admins clone it (Setup → Flows → *Save As*) and edit
it in Flow Builder to change layout, attribute display, categorization, and to add custom components. The flow
contains standard managed components: **Product Attributes, Option Groups, Prices, Summary, Messages,** and a
hidden **Data Manager**.
*Source:* Help — "Explore the Product Configurator Flow" and "Clone the Default Product Configurator Flow"
(`help.salesforce.com/s/articleView?id=ind.product_configurator_explore_the_product_configurator_flow.htm`).

### A2. "It's the same thing as OmniStudio / Industries CPQ" — ❌ Refuted (high)
The **RLM Product Configurator** (Revenue Cloud / Revenue Lifecycle Management, native metadata-driven,
API v60+/2024+) is a **different product** from **Industries CPQ** (OmniStudio/Vlocity, OmniScript-based,
`vlocity_cmt` package). Different data model, different UI framework. Any pattern borrowed from OmniStudio CPQ
does not transfer. *Source:* internal transition docs ("Revenue Cloud is now Revenue Management"), Slack
#industries-cpq.

### A3. How the configurator is launched — ✅ Confirmed (high)
Launched from a **quote/order line item** via the **Configure** quick action; it opens in a modal/full-page
context with a transaction context, **not** embedded in the quote page itself. This matters for the "chat panel
*alongside* config fields" UX — the panel lives **inside the configurator flow screen**, which is the correct
place to embed it. *Source:* Help — "Launch the Product Configurator".

---

## B. What the "config fields" actually are

### B1. "Config fields are Flow variables the LWC can set via `@api` outputs" — ❌ Refuted (high)
This is the **single most consequential correction.** Config fields are **product attributes** defined as
**`AttributeDefinition`** metadata (with data types: picklist, number, text, …), grouped by attribute
categories, rendered at runtime by the managed **Product Attributes** component. They are **not** declared as
Flow variables. The **Data Manager** component "stores product data in a hidden component and uses flow events
to distribute the data to other configurator components on the flow screen." So the LWC cannot populate fields
by setting Flow variables — it must speak the Data Manager's event protocol.
*Source:* Help — Product Configurator flow component docs; RLM Developer Guide (Product Configurator).

### B2. Attribute values live on `QuoteLineItemAttribute` (and `OrderItemAttribute`) — ✅ Confirmed (high)
Runtime attribute values are stored as **`QuoteLineItemAttribute`** records linked to `QuoteLineItem` and to
`AttributeDefinition`. For **picklist** attributes the value carries **both** `AttributeValue` (display text)
**and** `AttributePicklistValueId` (FK to `AttributePicklistValue`). *Source:* `rlm-product-configurator`
skill; internal Order Data Shape doc.

### B3. Attribute **API names ≠ display labels** — ❌ canvas field names are placeholders (high)
The canvas JSON uses friendly labels (`DutyRating`, `FullLoadKW`, `Voltage`, `MaxDB`). Real attributes are
addressed by **`AttributeDefinition.DeveloperName` / `Code`** (e.g. `requiredKW`, `ATTR_DUTY_RATING`). The LWC
must **discover** these at runtime by querying `AttributeDefinition WHERE Product2Id = :productId`, and for
picklists query `AttributePicklistValue` to resolve value → ID. Hard-coded mappings work in a demo and break
across products/orgs. *Source:* `rlm-product-configurator` skill; Slack #c026zm52tt6.

---

## C. Embedding a custom LWC & writing attribute values

### C1. Custom LWCs can be embedded — as "third-party configurator UI components" — ✅ Confirmed (high)
Documented extension point: **"Third-Party Configurator UI Component Integration into First-Party
Configurator."** The custom component is dragged into the cloned configurator flow. **Key constraint:** it must
communicate with the Data Manager via **Lightning Message Service (LMS) events**, and it **must not** directly
call the configurator API or any Save APIs. *Source:* Help — "Create a Third-Party Configurator UI Component."

### C2. The write API for a live session is the LMS `VALUE_CHANGE` event — ✅ Confirmed (high)
To set an attribute from a custom component, publish an LMS event with a payload shaped like:
```jsonc
{ "action": "valueChanged",
  "data": [ { "key": ["nodeId"], "field": "<ATTRIBUTE_FIELD>",
             "attributeId": "0tj...", "value": "<newValue>" } ] }
```
Bulk updates (multiple attributes in one message) are supported. Spring '26 extended LMS updates to editable
**Sales Transaction Item** fields (incl. custom fields, Quantity, Unit Price). *Source:* Help — third-party
configurator LMS docs; Spring '26 release notes.

### C3. Persisting attributes requires **PlaceSalesTransactionExecutor (PST)**, not DML — ✅ Confirmed (high)
Live LMS updates change the in-session UI/state; **persisting** attribute values is done through **PST**, the
only API that **atomically** (1) saves `QuoteLineItemAttribute`, (2) applies **BOM/bundle rules**, and (3)
**re-runs pricing** when `applyPricing: true`. **Standard DML fails** ("Argument must be of internal sObject
type"). *Source:* `rlm-product-configurator` + `rlm-pricing` skills.

### C4. **Picklist silent-failure trap** — ✅ Confirmed (high)
A PST payload for a picklist attribute **must include both** `AttributeValue` **and** `AttributePicklistValueId`.
If the ID is missing, **PST returns `internalSuccess: true` but the value silently reverts.** This is the
classic "works in demo, mysteriously fails in real config" trap. *Source:* `rlm-product-configurator` skill.

### C5. **Two-step PST sequencing** for Number + Picklist — ✅ Confirmed (high) **[verify on target product]**
Saving Number attributes (e.g. kW) and Picklist attributes (e.g. Duty Rating) in **one** PST call can conflict:
picklist BOM rules lock component structure and block the number-driven component swap. Documented fix:
sequence two calls — `executePst(numberAttributes)` then `executePst(picklistAttributes)`. Relevant because the
canvas's own 4 fields mix both types. *Source:* `rlm-product-configurator` skill (`pst-two-step-pattern`).

### C6. Constraint / configuration rules run automatically on update — ✅ Confirmed (high)
`ProductConfigurationRule` (Business Rules Engine) and/or **Constraint Models (CML)** evaluate on each update;
they can require/exclude/hide/disable and can **auto-correct** ("peelable") values. A **Run Config Rules
Action** invocable can validate a proposed set **without** saving — useful to pre-check agent suggestions before
Apply. Spring '26 adds **non-blocking** behavior (queue several changes before the constraint engine processes
them). *Source:* Help — Configuration Rules; `rlm-product-configurator` skill; Spring '26 release notes.

### C7. Alternative: a fully custom configurator UI on the **Configurator API + LWC wire adapter** — ✅ (high)
Spring '26: "Use a wire adapter with a Lightning web component to access Configurator API … build a custom
configurator UI and incorporate existing first-party configurator UI components as needed." REST verbs:
Configure, Add Nodes, **Update Nodes**, Delete Nodes. This is the escape hatch (Option C) if embedding inside
the managed UI proves too restrictive. *Source:* Spring '26 release notes ("Configurator API + LWC").

---

## D. The "re-render the screen" mechanism

### D1. "`FlowNavigate` re-renders the current screen" — ❌ Refuted (high)
There is no such event/behavior. The real events are **`FlowNavigationNextEvent`** / **`FlowNavigationBackEvent`**
(move between screens or exit), **`FlowNavigationPauseEvent`**, **`FlowNavigationFinishEvent`**, and
**`FlowAttributeChangeEvent`** (request a variable change → drives reactivity). Docs: "Navigation immediately
moves the user away from the current screen." Firing a navigation event from the last screen errors. *Source:*
LWC Dev Guide — "Best Practices for Reactivity"; Help — Reactive Screen Components.

### D2. In-place updates come from **Flow reactivity** (`FlowAttributeChangeEvent`) — ✅ Confirmed (high)
Since Spring '24 (GA; API v59+, **FlowRuntimeV3** required), an LWC firing `FlowAttributeChangeEvent` can update
other **reactive** screen components on the **same** screen in real time — no navigation. Most standard inputs
(Text, Picklist, Number, Currency, Date, Checkbox, Radio, Data Table, Lookup) support "Full" reactivity;
Aura/Display Image/File Upload do not. **But** this only helps if the target fields are *standard Flow screen
components* — inside the managed configurator they are **the managed Product Attributes component**, which is
why we need **LMS (C2)**, not just reactivity. *Source:* Help — Reactive Screen Components; LWC Dev Guide.

### D3. Do **not** fire attribute-change and navigation events together — ✅ Confirmed (high)
Docs explicitly warn this causes race conditions ("no guarantee your component has rendered updated values
before navigation starts"). The canvas's mixed "map outputs *and* fire FlowNavigate" would be exactly this
anti-pattern. *Source:* LWC Dev Guide — Best Practices for Reactivity.

### D4. Revisited-screen value persistence has a gotcha — ✅ Confirmed (high)
On Back→Next, components with default values may show the default instead of the user's entry unless the screen's
**"Revisited Screen Values"** is set to *"Refresh inputs to incorporate changes elsewhere in the flow."* Relevant
to the canvas's "preserve all other field values" claim. *Source:* Help; Slack #flow-2018.

---

## E. Invoking the agent / model

### E1. "LWC calls the Agent API directly" — ❌ Refuted (high)
Direct browser `fetch` from a Lightning domain (`*.lightning.force.com`) to the Agent API
(`api.salesforce.com/einstein/ai-agent`) is **CORS-blocked** ("No `Access-Control-Allow-Origin` header").
External apps and in-org LWCs both hit this. A **server-side hop is required.** *Source:* Slack
#agentforce-api-runtime-support (multiple CORS threads); SFAP CORS allowlist docs.

### E2. Supported server-side paths — ✅ (high)
- **`generateAiAgentResponse`** invocable action (callable from Flow/Apex) manages a bot session and returns
  `outputText` + `sessionId`. ~~**Only supports Legacy Bot (`BotVersion`) agents — NOT NGA `.agent` agents.**~~
  > ⚠️ **CORRECTION (2026-07-19):** the "Legacy Bot only" restriction was **REFUTED** by a live smoke test —
  > this org's **NGA/Employee agent** `Revenue_Quote_Management` (`Type=InternalCopilot`) was invoked
  > successfully from anonymous Apex via `generateAiAgentResponse` (`isSuccess=true`, real topic reply,
  > **no OAuth / no REST Agent API / no new agent**). **Verified contract for this action variant:**
  > `Invocable.Action.createCustomAction('generateAiAgentResponse', '<agentApiName>')` — arg 2 is the agent's
  > **API/developer name** (not a botId); input **`userMessage`** (required) + optional `sessionId`/`VoiceCallId`;
  > output **`agentResponse`** (JSON `{"type":"Text","value":"…"}`, must be parsed) + `sessionId`. There is
  > **no** `botId`/`inputText`/`versionString`/`language` param on this variant. See
  > [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) (2026-07-19) for the full smoke-test record.
- **`ConnectApi.EinsteinLLM`** in Apex (`generateMessages` / `generateMessagesForPromptTemplate`) — call a
  prompt template or a model directly and parse JSON. Callable from LWC via imperative Apex. **(This remains the
  right path for the deterministic *extract-and-apply* turn; the agent action above is for the *guided-selling*
  turn where we want the real agent's answers.)**
- Einstein **Models API / LLM Open Connector / Gateway** with **structured outputs** (JSON schema, `strict:true`).
*Source:* `rlm-agentforce` skill; Apex Reference (`ConnectApi.EinsteinLLM`); internal Gateway structured-output docs;
**live smoke test 2026-07-19** (the `generateAiAgentResponse` correction).

### E3. Agent returns **conversational text, not typed JSON** — ❌ canvas assumption refuted (high)
`generateAiAgentResponse` returns `outputText` (natural language, sometimes wrapped `{type:'Text',value:'…'}`).
Getting typed fields requires either designing a `GenAiFunction` with an explicit `outputSchema` **or**
bypassing the agent for a **structured-output model call**. Either way, **Apex-side JSON validation + retry** is
needed. *Source:* `rlm-agentforce` skill; internal "SPIKE — Best Practices to Maximize JSON Reliability."

### E4. Latency: **< 5s is not realistic** for a conversational agent — ❌ Refuted (high)
Internal data: Agentforce **P75 ≈ 8–9s**, **P95 ≈ 15–17s** for *simple* cases; complex/RAG/multi-action reach
20–30s+ (Commerce Product Search measured P95 ≈ 34s). Add PST + pricing (≈1–3s) if we persist. A grounded
single prompt call is faster than a full agent but still not reliably sub-5s end-to-end with save.
*Source:* internal Commerce Agentforce perf analysis; multiple Slack latency threads.

### E5. `UserInfo.getSessionId()` returns **null** inside agent (GenAiFunction) Apex — ✅ (high)
Apex invoked *by* an agent cannot make session-authenticated callouts to Salesforce REST APIs. Use SOQL,
standard invocable actions, or Named Credentials instead. Affects any design that has the *agent* call back into
`/connect/…`. (Less relevant if we use the LWC→Apex→model pattern, but critical if we go agent-first.)
*Source:* `rlm-agentforce` skill.

### E6. No public "open the agent chat panel from my LWC" API — ✅ (high) **[verify roadmap]**
The internal ACC (Agentforce Conversation Client) `open()/execute()` APIs are **not exposed to external
customers**. So a fully agent-native embedded chat controlled from our LWC is not a supported public path today;
our chat UI should be **our own LWC** calling Apex. *Source:* Slack (Agentforce LEX UI channel).

---

## F. Choosing the extraction engine

### F1. A full Agent is likely **overkill** for one-shot extraction — 🟡 (medium)
Agents add planner → topic → action overhead, multiple LLM calls, non-deterministic routing, and harder
testing — valuable for multi-step/multi-turn work, wasteful for "one sentence → 4 fields." *Source:*
`structured-extraction` research; Slack agent-architecture threads.

### F2. Most reliable structured output = **schema-enforced model call** — ✅ (high)
Gateway/Models API **structured outputs** (`response_format` + JSON schema, `strict:true`,
`additionalProperties:false`) give the strongest guarantee. Prompt-template *invocable actions* return **text**
that still needs parsing — enforce the schema and validate in Apex. Internal spike guidance: prefer returning a
**typed Apex object** over asking the LLM to emit JSON where possible, to cut hallucination + conversion cost.
*Source:* internal Gateway structured-output docs; "SPIKE — JSON Reliability."

### F3. **Grounding** in real allowed values is mandatory — ✅ (high)
To avoid hallucinated attribute values, fetch valid picklist values from metadata and inject them into the
prompt ("Valid DutyRating: [PRP, COP, ESP, SBY] — only return one of these"). No automatic schema-aware picklist
grounding exists; do it explicitly in Apex. *Source:* Prompt-template grounding docs; extraction research.

---

## Consolidated assumption scorecard

| # | Canvas assumption | Verdict | Confidence |
|---|-------------------|---------|-----------|
| 1 | Configurator is an editable Screen Flow | ✅ confirmed | high |
| 2 | Custom LWC embeddable in it | ✅ confirmed | high |
| 3 | Config fields = Flow variables set via `@api` outputs | ❌ refuted (they're attribute metadata) | high |
| 4 | `FlowNavigate` re-renders current screen | ❌ refuted (no such thing) | high |
| 5 | Screen re-render preserves other field values | 🟡 conditional (reactivity/LMS, plus settings gotcha) | high |
| 6 | LWC calls Agent API directly | ❌ refuted (CORS) | high |
| 7 | Agent returns structured JSON | ❌ refuted (returns text) | high |
| 8 | Round trip < 5s | ❌ refuted (≈8–9s P75 + save) | high |
| 9 | Field names DutyRating/FullLoadKW/… are the API names | ❌ refuted (DeveloperName/Code) | high |
| 10 | Price recalc can be out of scope | ⚠️ incoherent once we persist (PST reprices) | high |
| 11 | Full Agent is the right extraction tool | 🟡 overkill for POC; prefer grounded prompt/model call | medium |
