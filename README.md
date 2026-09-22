# RLM Conversational Product Configurator (POC)

> An Agentforce-powered **natural-language configuration panel** for the Salesforce Revenue Cloud (RLM)
> Product Configurator. Proof-of-concept — reuses the org's existing, managed configuration engine rather
> than replacing it.

---

## What this component does

The deliverable is a Lightning Web Component (`c:configChatPanel`) embedded in the right-hand column of the
RLM Product Configurator via a screen flow. A sales rep types free text; the panel classifies intent per
message and does one of two things:

- **Configuration turn** — *"~1500 kW, data-center continuous duty, low-voltage"* → a grounded Einstein LLM
  call maps the text to the product's **real** configuration attributes (validated against the catalog),
  shows an editable review card (or auto-applies a clean proposal), and publishes the selections into the
  managed configurator so it **applies, reprices, and re-renders natively**.
- **Guided-selling turn** — *"what do you recommend for a data center and why?"* → forwards the question to a
  live Revenue Management Agentforce (NGA) agent and renders its reasoned answer as chat. **Nothing is applied.**

**Two launch paths** are supported:

1. **Persisted line** (`0QL…`) — open a saved quote line → Configure. Grounds off the persisted `QuoteLineItem`.
2. **Pre-persist** — Configure directly from the product catalog (before Save), where only a transient
   `ref_<uuid>` configurator node exists. The panel detects this (`_isPrePersist`) and grounds off the
   **product's** classification instead (`ProductConfigGroundingService`).

Intent routing also selects the agent: pre-persist guided-selling turns go to the insight-only
`Revenue_Product_Advisor`; persisted-line turns go to the existing `Revenue_Quote_Management` agent
(the dual-agent bridge in `AgentAdvisorService`).

> **Dependencies (must pre-exist in the org):** the RLM engine + four protected engine services, the
> `Revenue_Quote_Management` agent, and Agentforce/Einstein platform settings. This repo deploys **on top of**
> a prepared org — it is not a from-scratch build. See [DEPLOYMENT_README.md](DEPLOYMENT_README.md) §2.

---

## How to use it

> **Audience:** a sales rep (or someone demoing) driving the panel in the browser. This assumes the feature is
> already deployed **and** the `Revenue_Product_Advisor` agent has been activated in Agent Builder 2.0
> (see [DEPLOYMENT_README.md](DEPLOYMENT_README.md) §5). After any redeploy of the LWC, **hard-refresh** the tab
> (Cmd+Shift+R) — the browser caches the old bundle aggressively.

### 1. Open the configurator with the panel

There are two ways in, and the panel adapts automatically:

- **From a saved quote line (persisted path):** open a Quote → open a configurable line (e.g. **FESBA Generator
  Set**) → **Configure**. The panel grounds off the saved `QuoteLineItem`.
- **From the product catalog (pre-persist path):** browse Catalogs → the configurable product →
  **Configure (before Save)**. There's no saved line yet (only a transient `ref_…` node); the panel detects this
  and grounds off the **product** instead. Everything below works the same.

The chat panel sits in the **right-hand column** next to the native configurator. The native panel remains the
source of truth for the resulting values and price.

### 2. Configure by typing a requirement

Type what you want in plain language and hit **Send**. Examples:

> *"~1500 kW, data-center continuous duty, low-voltage"*
> *"standby duty, 480V"*

What happens:

1. The panel maps your text to the product's **real** attributes and validates every value against the catalog —
   hallucinated attributes are dropped, illegal picklist values are flagged.
2. You get one of two outcomes:
   - **Review card** — an editable list of proposed attribute changes. Toggle rows on/off, adjust values, then
     click **Apply**.
   - **Auto-apply** — if auto-apply is on *and* the proposal is clean (every row valid and unambiguous), it skips
     the card and applies directly.
3. On **Apply**, the selections publish into the managed configurator, which **applies, reprices, and re-renders
   natively** on the left. Persisting the change is still the native configurator's **Save**.

> **Ambiguity is blocked, not guessed.** If a value maps to more than one catalog entry, the panel refuses that
> row (and drops auto-apply to manual review) rather than silently picking one.

### 3. Ask for advice (guided selling)

Ask a question instead of stating a requirement, and the panel routes it to a live Agentforce agent and shows the
answer as chat. Examples:

> *"What duty rating do you recommend for a data center, and why?"*
> *"How much full-load capacity do I need for a large data center?"*

- **Nothing is applied** on a question turn — it's insight only, even if your question happens to contain words
  that look like attribute values ("data center", "480V", …).
- Follow-up questions stay in the same agent conversation for the session (not persisted across a page reload).
- Expect roughly **8–9s** for an agent answer; a progress state is shown while it works.

### 4. How the panel tells the two apart

You don't flag your intent — the panel decides per message. A fast heuristic catches obvious questions (advice
words, question openers, a trailing "?"), and the same grounded LLM call that does extraction also classifies
**CONFIGURE vs ASK** as a backstop. If intent is ever unclear, it defaults to the **reviewable configuration
path** (never a silent apply), so a misread directive is always something you can see and confirm. See
[ARCHITECTURE.md §4](ARCHITECTURE.md) for the full routing design.

---

## Table of contents

### Start here
| Doc | What it covers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | **The as-built architecture** — how the pieces fit together and why. System diagram, both launch paths, intent routing. Start here to understand the component. |
| [DEPLOYMENT_README.md](DEPLOYMENT_README.md) | Repeatable, step-by-step **deploy guide** — order, tests/coverage gate, agent activation, gotchas, rollback. |
| [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md) | Chronological **build log + revert history** — what changed, when, and how to undo it. |

### Planning package (how we got here)
| Doc | What it covers |
|---|---|
| [PROJECT-PLAN.md](PROJECT-PLAN.md) | Top-level planning package index for the POC. |
| [01-executive-summary.md](01-executive-summary.md) | Executive summary — the pitch and the outcome. |
| [02-research-findings.md](02-research-findings.md) | Research findings from investigating the RLM configurator. |
| [03-gap-analysis.md](03-gap-analysis.md) | Gap analysis — holes in the original ("canvas") plan. |
| [04-corrected-architecture.md](04-corrected-architecture.md) | Corrected architecture after discovering the existing engine. |
| [05-project-plan.md](05-project-plan.md) | Revised project plan — the reuse-engine path. |
| [06-open-questions-and-decisions.md](06-open-questions-and-decisions.md) | Key decisions and their rationale. |
| [07-discovered-engine.md](07-discovered-engine.md) | The discovered engine — what already exists in the target org. |
| [Agent0.md](Agent0.md) | Discovery log from the initial exploration. |

---

## Source layout

```
force-app/main/default/
  classes/
    ConfigEngineController.cls          # thin @AuraEnabled over the protected engine (read/apply)
    ConfigExtractionService.cls         # grounded NL→fields extraction + intent classification (CONFIGURE|ASK, +productId)
    ConfigLmsGroundingService.cls       # attributeId + picklist label→0v6-Id map (persisted path)
    ProductConfigGroundingService.cls   # pre-persist grounding off the PRODUCT (catalog Configure)
    AgentAdvisorService.cls             # dual-agent bridge (Revenue_Product_Advisor | Revenue_Quote_Management)
    *Test.cls                           # deploy-gate coverage (seam-based, no live Einstein/agent credits)
  lwc/
    configChatPanel/                    # THE deliverable — pre-persist aware, LMS publish+subscribe
    configRefreshProbe/ spikeConfigApply/ renderDraw3DConfigurationPrototype/   # diagnostic / spike / reference
  flows/
    Agent_Product_Configurator_Flow.flow-meta.xml       # OURS — embeds configChatPanel
    RenderDraw_Product_Configurator_Flow.flow-meta.xml  # reference flow (protected; unchanged)
  aiAuthoringBundles/
    Revenue_Product_Advisor/            # NGA insight-only agent (.agent + .bundle-meta.xml)
```

---

## Deploy (quick pointer)

Full instructions — including the production coverage gate, agent activation, and gotchas — are in
[DEPLOYMENT_README.md](DEPLOYMENT_README.md). The staged order is:

1. **Apex** (with the three seam-based test suites — production orgs enforce the ≥75% coverage gate)
2. **LWC** — then **hard-refresh** the flow tab (aggressive browser caching)
3. **Flow** — deploys a new active version of `Agent_Product_Configurator_Flow`
4. **Agent bundle** (NGA) — `sf agent validate` then `sf project deploy start`; **never** `sf agent publish`/`create`
   (those create un-upgradeable legacy Bot 1.0 metadata)

Then two manual, user-side steps: **activate** `Revenue_Product_Advisor` in Agent Builder 2.0, and
**live-confirm** the pre-persist apply on a `ref_…` line.

---

## Salesforce DX reference

This is a standard Salesforce DX project (API v67.0, `sourceApiVersion` pinned in `sfdx-project.json`).

Common commands:

- `sf org login web -a <alias>` — authorize an org
- `sf project deploy start --source-dir <dir> -o <alias>` — deploy metadata
- `sf project retrieve start --source-dir <dir> -o <alias>` — retrieve metadata
- `sf apex run test --tests <TestClass> --code-coverage -o <alias>` — run Apex tests with coverage
- `sf agent validate authoring-bundle --api-name <name> -o <alias>` — validate an NGA agent bundle

For the base DX toolchain see the [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/) and the [Salesforce CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/).
