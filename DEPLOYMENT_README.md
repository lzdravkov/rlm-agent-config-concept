# Deployment Guide — RLM Conversational Product Configurator

> **What this is.** A repeatable, step-by-step guide to deploying this POC (Apex + LWC + Flow + the
> `Revenue_Product_Advisor` Agentforce agent) into a target org. It reflects the **as-built** deploy process used
> for `rlm-agent-config-v2` on 2026-09-11.
>
> For *how the pieces fit together* see [ARCHITECTURE.md](ARCHITECTURE.md); for the *chronological build log +
> revert history* see [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md).

---

## 0. TL;DR (deploy to an already-prepared org)

```bash
# Set your target org alias once
ORG=rlm-agent-config-v2

# 1. Apex (ships tests — production-type orgs enforce the 75% coverage gate)
sf project deploy start \
  --source-dir force-app/main/default/classes \
  -l RunSpecifiedTests \
  --tests ConfigExtractionServiceTest --tests AgentAdvisorServiceTest --tests ProductConfigGroundingServiceTest \
  -o "$ORG" --wait 10

# 2. LWC  (then HARD-REFRESH the flow tab in the browser — see §6 gotchas)
sf project deploy start --source-dir force-app/main/default/lwc -o "$ORG" --wait 10

# 3. Flow (deploys a NEW ACTIVE version of Agent_Product_Configurator_Flow)
sf project deploy start --source-dir force-app/main/default/flows -o "$ORG" --wait 10

# 4. Agent bundle (NGA) — validate, then deploy
sf agent validate authoring-bundle --api-name Revenue_Product_Advisor -o "$ORG"
sf project deploy start --source-dir force-app/main/default/aiAuthoringBundles/Revenue_Product_Advisor -o "$ORG" --wait 10
```

**Then two manual, user-side steps that no CLI can do (see §5):**
1. **Activate `Revenue_Product_Advisor`** in Agent Builder 2.0 (Setup → Agents) — this creates the runtime Bot
   that makes the agent Apex-invocable.
2. **Live-confirm** the configurator apply on a pre-persist (`ref_…`) line.

> ⚠️ This repo deploys **on top of** an org that already has the RLM engine, the four protected engine services,
> and the existing `Revenue_Quote_Management` agent. It is **not** a from-scratch org build. See §2.

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Salesforce CLI (`sf`) | v2.x. `sf --version`. The `sf agent …` commands require a recent CLI. |
| Authenticated target org | `sf org login web -a <alias>`; confirm with `sf org display -o <alias>`. |
| Revenue Cloud (RLM) enabled | Product catalog, Product Configurator, and the managed **Data Manager** must be provisioned. |
| API v67.0+ | `sfdx-project.json` pins `sourceApiVersion: 67.0`; the NGA authoring-bundle floor is v65. |
| Agentforce / Einstein enabled | `enableEinsteinGptPlatform` + `enableAgentPlatform` must be ON in the org (see §2 — these are **not** in source). |
| Node (for LWC tooling, optional) | Only needed if running Jest locally; not required to deploy. |

**Org type matters.** The reference org is a **production-type** org (`IsSandbox=false`), so every Apex deploy
**must ship tests and clear the ≥75% coverage gate**. Sandboxes/scratch orgs can deploy without tests, but always
deploy with tests here to stay honest with the production path.

---

## 2. What must already exist in the target org (NOT in this repo)

This repo contains only the POC-authored components. The following are **dependencies that must pre-exist** — a
deploy into an org lacking them will fail to compile or will error at runtime:

- **Protected engine services** — `ProductAttributeService`, `ProductAttributeSaveService`,
  `ProductAttributeReadService`, `QuoteLineItemLookupService`. `ConfigEngineController` /
  `ConfigLmsGroundingService` call these; they are live in the org and are **not** committed here.
- **The existing agent** — `Revenue_Quote_Management` (NGA Employee agent: `BotDefinition` Type=InternalCopilot +
  `GenAiPlannerBundle`). `AgentAdvisorService` invokes it by API name for the **persisted-line** Q&A turn.
- **Agentforce baseline settings** — `EinsteinGpt` (`enableEinsteinGptPlatform=true`) and `AgentPlatform`
  (`enableAgentPlatform=true`). There is **no `settings/` folder in this repo** — these were enabled directly in
  the org. If deploying to a fresh org, enable them first (Setup → Einstein / Agentforce, or add the settings
  metadata) *before* step 4.
- **A configurable product with a classification** — e.g. FESBA Generator Set. Grounding reads
  `ProductClassificationAttr` + `AttributePicklistValue` off the product's `BasedOnId` classification.

---

## 3. Source layout (what deploys, what's reference-only)

```
force-app/main/default/
  classes/
    ConfigEngineController.cls            # thin @AuraEnabled over the protected engine (read/apply)
    ConfigExtractionService.cls           # grounded NL→fields extraction + intent classification (+productId)
    ConfigLmsGroundingService.cls         # attributeId + picklist label→0v6-Id map (persisted path)
    ProductConfigGroundingService.cls     # NEW — pre-persist grounding off the PRODUCT (zero-drift SOQL)
    AgentAdvisorService.cls               # dual-agent bridge (Revenue_Product_Advisor | Revenue_Quote_Management)
    *Test.cls                             # deploy-gate coverage (seam-based, no live Einstein/agent credits)
  lwc/
    configChatPanel/                      # THE deliverable — pre-persist aware, LMS publish+subscribe
    configRefreshProbe/  spikeConfigApply/ renderDraw3DConfigurationPrototype/   # diagnostic / spike / reference
  flows/
    Agent_Product_Configurator_Flow.flow-meta.xml   # OURS — embeds configChatPanel; deploy = new active version
    RenderDraw_Product_Configurator_Flow.flow-meta.xml   # reference flow (protected; unchanged)
  aiAuthoringBundles/
    Revenue_Product_Advisor/              # NEW — NGA insight-only agent (.agent + .bundle-meta.xml)
```

**Do NOT modify / redeploy as changes:** the four protected engine services (not in repo),
`renderDraw3DConfigurationPrototype`, `RenderDraw_Product_Configurator_Flow`, and the `Revenue_Quote_Management`
agent. `ConfigLmsGroundingService` and `ConfigEngineController` are reference for this feature and were not changed
in the pre-persist work — no need to redeploy them unless you actually edit them.

---

## 4. Deploy order (and why it matters)

Deploy in this sequence; each step is independently verifiable.

### Step 1 — Apex (with tests)

```bash
sf project deploy start \
  --source-dir force-app/main/default/classes \
  -l RunSpecifiedTests \
  --tests ConfigExtractionServiceTest --tests AgentAdvisorServiceTest --tests ProductConfigGroundingServiceTest \
  -o "$ORG" --wait 10
```

- These three **seam-based** suites pass deterministically and cover the changed classes
  (ProductConfigGroundingService 92%, ConfigExtractionService 87%, AgentAdvisorService 84%).
- **Do NOT add `ConfigEngineControllerTest` or `ConfigLmsGroundingServiceTest` to `--tests` on a clone/new org.**
  They are **live-data** tests that hardcode the original org's line Id `0QLg8000001RYgDGAW`; they fail with
  `QuoteLineItem not found` on any org that doesn't have that exact record, which would block the deploy. Re-point
  their fixtures first (see §7) if you need them.
- **Known CLI quirk:** if `deploy … -l RunSpecifiedTests` reports tests **Skipped** (Passing 0 / Failing 0) because
  the components were unchanged, run the tests explicitly to confirm coverage:
  ```bash
  sf apex run test \
    --tests ConfigExtractionServiceTest --tests AgentAdvisorServiceTest --tests ProductConfigGroundingServiceTest \
    --code-coverage --result-format human -o "$ORG" --wait 20
  ```

### Step 2 — LWC

```bash
sf project deploy start --source-dir force-app/main/default/lwc -o "$ORG" --wait 10
```

> **After every LWC redeploy, HARD-REFRESH the flow tab** (Cmd+Shift+R, or close+reopen the tab). The browser caches
> the old bundle aggressively and will keep running it — this has masked a fix before.

### Step 3 — Flow

```bash
sf project deploy start --source-dir force-app/main/default/flows -o "$ORG" --wait 10
```

- Deploying `Agent_Product_Configurator_Flow` creates a **new active version**. The pre-persist work added the
  `S01_DataManager.rootProductId → S00_ConfigChatPanel.rootProductId` input binding.

### Step 4 — Agent bundle (NGA / Agent Builder 2.0)

```bash
# Validate first (catches DSL / indentation errors before deploy)
sf agent validate authoring-bundle --api-name Revenue_Product_Advisor -o "$ORG"

# Deploy the authoring bundle metadata
sf project deploy start \
  --source-dir force-app/main/default/aiAuthoringBundles/Revenue_Product_Advisor \
  -o "$ORG" --wait 10
```

- **NEVER run `sf agent publish authoring-bundle` or `sf agent create`.** Both create **legacy** Bot 1.0 metadata
  (`bots/`, `genAiPlanners/`, `genAiFunctions/`, `genAiPlugins/`) that cannot be upgraded to NGA. Deploy the bundle
  with `sf project deploy start` only.
- Deploying the bundle creates the `AiAuthoringBundle` metadata **but does not create a runtime agent** — no Bot,
  no User, nothing activated. Activation is the manual step in §5.

---

## 5. Post-deploy — manual steps no CLI can do

### 5a. Activate the agent (Agent Builder 2.0 UI)

1. Setup → **Agents** (Agent Studio). `Revenue_Product_Advisor` appears with an NGA (arrow) icon.
2. Open it, set the **agent type = Employee**, assign an agent user **only if prompted** (this org runs Employee
   agents session-based with **no dedicated Einstein Agent User**, so the bundle intentionally commits no
   `default_agent_user`).
3. Click **Activate**. The runtime `BotDefinition` is created here — this is what makes the agent invocable from
   Apex via `createCustomAction('generateAiAgentResponse', 'Revenue_Product_Advisor')`.
4. **Retrieve the bundle back to source** to capture any UI-side changes, then check the `config:` block is still
   tab-indented (the org can reintroduce spaces on retrieve):
   ```bash
   sf project retrieve start --source-dir force-app/main/default/aiAuthoringBundles/Revenue_Product_Advisor -o "$ORG" --wait 10
   ```

### 5b. Smoke-test the agent

```bash
SID=$(sf agent preview start --authoring-bundle Revenue_Product_Advisor -o "$ORG" --json 2>/dev/null | jq -r '.result.sessionId')
sf agent preview send --session-id "$SID" --authoring-bundle Revenue_Product_Advisor \
  --utterance "CONTEXT: productId=01t... productName=FESBA Generator Set attributes=[DutyRating (Picklist): Standby, DataCenterContinuous; requiredKW (Number)]

what duty rating do you recommend for a data center and why?" -o "$ORG" --json
sf agent preview end --session-id "$SID" --authoring-bundle Revenue_Product_Advisor -o "$ORG" --json
```

Expect a grounded recommendation that spells the picklist value exactly as in CONTEXT and applies nothing.

### 5c. Live-confirm the pre-persist apply (`ref_` spike)

Browse Catalogs → the configurable product → **Configure (before Save)** → confirm the panel loads (no
"QuoteLineItem not found"), type a requirement, Apply, and verify the native configurator updates + reprices. This
confirms the Data Manager accepts a `valueChanged` whose `key` is `["ref_…"]` — the one apply assumption that can
only be checked live.

---

## 6. Gotchas & platform constraints

- **`.agent` files are TAB-ONLY.** Agent Builder 2.0 rejects space-indented `.agent` files with `PARSE_EXCEPTION`
  even when `sf agent validate` passes. Editor protection is committed: `.editorconfig` `[*.agent]` +
  `.vscode/settings.json` `[agentscript]` (`insertSpaces:false`, `formatOnSave:false`, `formatOnPaste:false`).
  Keep these; do not let an editor reformat the file. Verify with: `grep -nP '^ ' Revenue_Product_Advisor.agent`
  (must return nothing).
- **LWC caching** — hard-refresh after every LWC deploy (§4 Step 2).
- **Transient `ref_` lines** — pre-persist, `quoteLineItemId` is a `ref_<uuid>` node id, not a `0QL…` record. The
  panel detects this (`_isPrePersist`) and grounds off `rootProductId`; the QLI wires are suppressed via an
  `undefined` reactive param so they never fire with a `ref_`.
- **Production coverage gate** — each deployed Apex class needs ≥75% coverage from the tests you specify, and those
  tests must pass. That's why §4 specifies only the passing seam-based suites.
- **No secrets in source** — the repo is intentionally **private**. Do not commit org auth (`.sf/`, `.sfdx/` are
  gitignored), client secrets, or `.env`. External-credential secrets are entered on the principal in the org, not
  in metadata.

---

## 7. Deploying to a NEW / clone org (fixture drift)

Record Ids differ between orgs. When deploying to a clone or a fresh org:

- **Re-capture fixtures.** The live/`SeeAllData` tests reference specific records. The clone `rlm-agent-config-v2`
  uses: FESBA product `01tgK00000EPnyuQAD` (classification `11BgK00000h2GWCUA2`), Quote `0Q0gK000002dwcTSAQ`.
- **Live-data tests will fail until re-pointed.** `ConfigEngineControllerTest` and `ConfigLmsGroundingServiceTest`
  hardcode the *original* org's line Id `0QLg8000001RYgDGAW`. On any other org they fail (`QuoteLineItem not
  found`). This is stale-fixture drift, **not** a code regression. To make the full suite green, re-point those
  tests to a persisted `0QL…` configurable line in the target org (or exclude them from the deploy test set as in
  §4).
- **Enable Agentforce/Einstein settings** and confirm the protected engine + `Revenue_Quote_Management` agent exist
  (§2) before deploying.

---

## 8. Verify the whole deploy

```bash
# Focused: the changed feature classes (should all pass)
sf apex run test \
  --tests ConfigExtractionServiceTest --tests AgentAdvisorServiceTest --tests ProductConfigGroundingServiceTest \
  --code-coverage --result-format human -o "$ORG" --wait 20

# Full local suite (expect the known live-data + unrelated RLM_* failures on a clone — see §7)
sf apex run test -l RunLocalTests --code-coverage --result-format human -o "$ORG" --wait 20
```

Then walk the end-to-end script in [ARCHITECTURE.md](ARCHITECTURE.md) §3 / the plan's verification steps: catalog
Configure (pre-persist) → configuration turn → guided-selling turn → persisted-line non-regression.

---

## 9. Rollback

The project is **git-backed** (private repo, branch `rlm-config-agent-v2`).

- **Revert source:** `git revert <sha>` or check out a prior commit, then redeploy the affected `--source-dir`.
- **Flow:** deploying an older flow definition creates another new active version; the configurator picks up the
  active version. There is no destructive delete needed.
- **Agent:** deactivate `Revenue_Product_Advisor` in Agent Builder 2.0, or delete the `AiAuthoringBundle` via a
  destructive change set if it must be removed. `AgentAdvisorService` still compiles either way (the agent name is a
  string), but the pre-persist Q&A turn will error at runtime until the agent is active again.
- Change points before 2026-07-20 predate git — see the `backups/` folders referenced in
  [PROJECT-JOURNAL.md](PROJECT-JOURNAL.md).

---

## 10. Command reference (copy/paste)

```bash
ORG=<your-org-alias>

# Deploy everything under force-app in one shot (tests included)
sf project deploy start --source-dir force-app \
  -l RunSpecifiedTests \
  --tests ConfigExtractionServiceTest --tests AgentAdvisorServiceTest --tests ProductConfigGroundingServiceTest \
  -o "$ORG" --wait 20

# Validate the agent bundle
sf agent validate authoring-bundle --api-name Revenue_Product_Advisor -o "$ORG"

# Retrieve the agent bundle back after UI activation
sf project retrieve start --source-dir force-app/main/default/aiAuthoringBundles/Revenue_Product_Advisor -o "$ORG" --wait 10

# Confirm the org + API version
sf org display -o "$ORG"
```

> Note: deploying the whole `force-app` folder (§10 first command) also deploys the reference LWCs/flows and the
> unchanged reference Apex — harmless, but the staged per-directory order in §4 is preferred for a clean, verifiable
> rollout (and lets you hard-refresh between the LWC and Flow steps).
