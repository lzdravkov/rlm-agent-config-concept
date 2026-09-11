# Agentforce-Powered RLM Product Configurator — Planning Package

> **Status:** ⚙️ **BUILT & DEPLOYED** to `rlm_agent_config_concept` (as of 2026-07-20) · **Original plan date:** 2026-07-17 · **Author of source idea:** Lyudmil Zdravkov (Principal SE)
>
> This package validates and re-plans the [source Slack canvas](https://salesforce.enterprise.slack.com/docs/T01G0063H29/F0BJ3L6A9NW)
> ("POC Plan: Agentforce-Powered RLM Product Configurator"). It tests the canvas's assumptions against
> official Salesforce documentation, the Revenue Lifecycle Management Developer Guide, internal RLM skills,
> and internal Slack; pokes holes in the plan; and lays out a corrected, executable architecture.
>
> **This document (01–07) is the PLANNING/RESEARCH package — its findings still hold, but its forward-looking
> "before we build" framing is now historical.** The POC has since been built: the `configChatPanel` LWC + the
> extraction/grounding/agent-advisor Apex are live in `rlm_agent_config_concept`, with the
> **conversational configuration turn** (grounded extraction → review/auto-apply → LMS publish) and the
> **guided-selling turn** (LLM intent classification routes advice questions to the real Revenue Management
> agent) both verified working. **For current build state, decisions, and findings see
> [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) (rolling change log) and
> [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md) (D8–D11).**

---

## ⚡ Update (2026-07-17) — the target org already contains a working engine, now runtime-verified

After enabling Agentforce in the target org `rlm_agent_config_concept`, discovery found that **most of the
hard server-side work already exists** there: a product-agnostic configuration engine
(`ProductAttributeService` / `ProductAttributeSaveService` / …) that does runtime metadata discovery, PST
persistence with correct picklist-ID handling, two-step Number/Picklist sequencing, and repricing — plus a
working NGA agent + `ProductConfiguration` topic. **Two live agent runs then proved it end-to-end**, including
the hard **DCC + 1500 kW two-step-PST conflict** ([07 §8](07-discovered-engine.md)). This resolves several
"critical gaps" outright. **Two corrections came out of testing:** the save service **returns no price** and
**hardcodes its validation verdict**, so *surfacing* price and CML corrections are small **new build items**
(post-save re-query / diff), and the agent's spoken price is **ungrounded**. **Your chosen direction: reuse the
engine and build the embedded-LWC experience the canvas envisioned** (chat panel inside the Product Configurator
flow + grounded NL→fields extraction on top). The project is now **much smaller and lower-risk** than the
original plan — the surviving high risk is the **in-session** re-render (Spike 1). Note two hard constraints: the
trial org is **production-type at 0% Apex coverage** (tests needed to deploy) and **expires 2026-08-17**. Full
detail: [07-discovered-engine.md](07-discovered-engine.md); revised plan: [05-project-plan.md](05-project-plan.md);
resolved decisions: [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md).

> Docs 01–04 below describe the *pre-discovery* analysis (still valid as the reasoning trail and the gap
> catalogue). Where they differ from docs 05–07, **07 and the revised 05/06 win.**

---

## The one-paragraph verdict

The canvas's **premise is correct** — the RLM Product Configurator genuinely *is* a customizable Screen Flow
("Default Product Configurator Flow"), and you *can* embed a custom LWC chat panel inside it. But **the
mechanics the canvas describes for wiring the pieces together are largely wrong**, and several would not work
against a real attribute-driven configurator. The three showstoppers, each independently confirmed by
multiple research streams:

1. **Config fields are product-attribute metadata, not Flow variables.** The `LWC → @api output → Flow
   variable → field` data flow in the canvas does not apply. Attributes are rendered by a managed
   component ("Product Attributes") fed by a hidden "Data Manager" component, and are written via a specific
   API — not by assigning Flow variables.
2. **There is no `FlowNavigate` event that "re-renders the current screen."** That mechanism does not exist.
   Flow navigation *always* moves you off the screen. The in-place update the canvas wants is achieved by
   **Flow reactivity** and/or **Lightning Message Service (LMS) events** to the Data Manager.
3. **An LWC cannot call the Agent API directly** (blocked by CORS), and the agent does **not** return
   structured JSON by default (it returns conversational text). A server-side Apex hop and a deliberate
   structured-output design are required.

The idea is buildable and worth a POC — but with a different architecture than the one drawn. This package
provides that architecture, a corrected phased plan, and the decisions I need from you.

---

## Read in this order

| # | Document | What it gives you |
|---|----------|-------------------|
| 1 | [01-executive-summary.md](01-executive-summary.md) | Verdict, corrected architecture at a glance, recommended path, go/no-go |
| 2 | [02-research-findings.md](02-research-findings.md) | Every canvas assumption tested against docs — verdicts + sources |
| 3 | [03-gap-analysis.md](03-gap-analysis.md) | The holes, ranked by severity, each with impact + concrete fix |
| 4 | [04-corrected-architecture.md](04-corrected-architecture.md) | Three viable options (A/B/C), the recommended design, data flow, components |
| 5 | [05-project-plan.md](05-project-plan.md) | **Revised (reuse-engine) phased plan**, 2 spikes, decision gates, scope + success criteria |
| 6 | [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md) | Decisions — which are now resolved by discovery, which still need you |
| 7 | [07-discovered-engine.md](07-discovered-engine.md) | **What already exists in the org** — the engine, the real product model, gap-by-gap status |

> **New reader, short on time:** read this page → [07](07-discovered-engine.md) → [05](05-project-plan.md) →
> [06](06-open-questions-and-decisions.md). Docs 02–04 are the supporting research/gap analysis.

---

## What I need from you before we execute

A short list — details in [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md):

1. **Confirm the target org + product.** Which sandbox has RLM Product Configurator enabled, and which
   configurable product (the canvas implies a generator: Duty Rating / kW / Voltage / Max dB) will we test against?
2. **Pick the extraction engine** — full Agentforce agent vs. a Prompt Template vs. a direct Einstein/Gateway
   model call. My recommendation and the trade-offs are in docs 1 and 4.
3. **Pick the UI-update mechanism** — LMS-to-Data-Manager (works *inside* the managed configurator) vs. a
   fully custom configurator UI on the Configurator REST/wire APIs. Trade-offs in doc 4.
4. **Accept revised success criteria** — the "< 5 second round trip" target is not realistic; see doc 3.
5. **Decide whether "persist + reprice" is in the POC** — the canvas puts price recalculation out of scope,
   but if we actually *save* attributes it is unavoidable. See doc 3 (Gap 6).

---

## How this package was produced (auditability)

Six parallel research streams searched official Salesforce Help, the RLM Developer Guide, internal code
search, the `rlm-product-configurator` / `rlm-pricing` / `rlm-agentforce` skills, and internal Slack; three
adversarial critique passes then tried to break the resulting plan. All three critiques converged on the same
critical findings independently, which raises confidence. Sources and confidence levels are carried through
each document. Claims resting on model knowledge rather than a documented source are marked **[verify]** and
are exactly what the Phase 0/1 spikes are designed to confirm before we commit build effort.
