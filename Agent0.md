# Agent0 — Discovery Log

> **Ownership:** This file is maintained exclusively by Agent0. Other agents should
> treat it as a **read-only source of grounding**. Do not edit; consume the findings here
> to stay aligned with verified discoveries about this org and the headless-agent effort.

**Project:** rlm-agent-config-concept
**Default org:** `rlm_agent_config_concept`
**Started:** 2026-07-19
**Objective:** Enable the Revenue Management agent to be driven headlessly from a custom
component (LWC) on the Salesforce platform, accessed via API. Determine whether an
External Client App (ECA) is required as a first step.

---

## Constraints (from user)

- **No changes to the demo org** for now — discovery/testing only. No metadata deploys,
  no config edits. Invoking an agent (which creates a transient conversation session) is
  acceptable as a read-only test since it alters no configuration.
- Another agent is working in this repo in the background — coordinate via this file.

---

## Verified findings

### Target agent
| Property | Value |
|---|---|
| Developer Name | `Revenue_Quote_Management` |
| Master Label | "Revenue Management Agent" |
| BotDefinition Id | `0Xxg8000001B9dhCAC` |
| Type | **`InternalCopilot`** (modern Agentforce employee agent) |
| Active version | **v4** (BotVersion Id `0X9g8000001Ppq2CAC`); v1–v3 Inactive |
| Planner bundle | `Revenue_Quote_Management_v2_v3_v4` (GenAiPlannerDefinition `16jg8000000f3ZsAAI`) |

Other agents in org (not targets): `Billing_Employee_Assistance`, `Sales_Planning`.

### Architecture decision context
- Custom component will run **on-platform, in a logged-in user session** (per user).
- `InternalCopilot` + BotVersion-backed + GenAiPlannerDefinition = an Agentforce agent
  that sits between the "classic Einstein Bot" and "NGA `.agent`" cases.

### Two candidate headless paths
| Route | ECA needed? | Notes |
|---|---|---|
| LWC → Apex → `generateAiAgentResponse` invocable | **No** | Keys off BotVersion; unverified for `InternalCopilot`. Use `versionString "1.0.0"`. |
| LWC → Apex → Agentforce Agent API (`einstein/ai-agent/v1`) | **Yes** | Officially supported headless interface; session-aware; server-to-server callout. |

---

## Test log

### Test 1 — Does `generateAiAgentResponse` accept the `InternalCopilot` agent?
- **Goal:** Determine if the cheap, no-ECA Apex route is viable.
- **Method:** Anonymous Apex via standard invocable action; then verified against the
  REST Actions API (`/services/data/v67.0/actions/standard`).
- **Result: NEGATIVE — route not available.**
  - Anonymous Apex `Invocable.Action.createStandardAction('generateAiAgentResponse')`
    → `NullPointerException: "Specify a name for the generateAiAgentResponse custom
    invocable action type."` (i.e., the action type is not registered.)
  - REST describe `actions/standard/generateAiAgentResponse`
    → `{"errorCode":"NOT_FOUND","message":"Invalid Action Type: generateAiAgentResponse"}`.
  - Enumerated all **344** standard actions in the org: **none** invoke an agent/bot
    conversationally. Only agent-adjacent actions are `getAgentContext` and
    `getAgentContextDetails` (context retrieval, not invocation).
- **Conclusion:** `generateAiAgentResponse` is Legacy-Bot-only and is not present in this
  org (v67.0). The target agent is `InternalCopilot` (Agentforce), not a Legacy Bot, so
  the no-ECA Apex-invocable route is **ruled out**.

---

## DECISION

**An External Client App (ECA) IS required.** The supported headless path for this
`InternalCopilot` agent is the **Agentforce Agent API** (`einstein/ai-agent/v1`), which
is OAuth-authenticated and therefore needs an ECA. Answer to the original question
("Should I create an ECA first?") = **YES.**

### Recommended target architecture (not yet built — no org changes made)
```
LWC (holds sessionId in component state for multi-turn)
  └── @AuraEnabled Apex controller (runs in user session)
        └── Named Credential  ──►  ECA (Client Credentials flow, run-as integration user)
              └── Agentforce Agent API  /einstein/ai-agent/v1/agents/{botId}/sessions
                                        /einstein/ai-agent/v1/sessions/{sessionId}/messages
```
- `botId` = `0Xxg8000001B9dhCAC` (Revenue_Quote_Management).
- ECA scopes to plan for: `chatbot_api` + `api` (+ `sfap_api` depending on Agent API enablement).
- `UserInfo.getSessionId()` is NOT usable here — auth is via the ECA/Named Credential,
  not the user session.

## BUILD LOG — External Client App (2026-07-19)

**User authorized the build.** Created ECA `RevenueAgent_Headless` for the Client
Credentials (server-to-server) flow to reach the Agent API.

### Source files created (under `force-app/main/default/`)
| File | Type | Deployed? |
|---|---|---|
| `externalClientApps/RevenueAgent_Headless.eca-meta.xml` | ExternalClientApplication | ✅ Yes |
| `extlClntAppGlobalOauthSets/RevenueAgent_Headless.ecaGlblOauth-meta.xml` | ExtlClntAppGlobalOauthSettings | ✅ Yes |
| `extlClntAppOauthSettings/RevenueAgent_Headless.ecaOauth-meta.xml` | ExtlClntAppOauthSettings | ✅ Yes |
| `extlClntAppOauthPolicies/RevenueAgent_Headless.ecaOauthPlcy-meta.xml` | ExtlClntAppOauthConfigurablePolicies | ⛔ NOT deployed — needs run-as user (UI) |

Successful deploy ID: `0Afg8000008lgKACAY` (3 components).

### Config decisions
- **Flow:** Client Credentials (confidential client). PKCE off, secret required.
- **Scopes (metadata token names):** `Chatbot, Api, SFApiPlatform, RefreshToken`.
  - Runtime equivalents: chatbot_api / api / sfap_api / refresh_token.
- **Callback URL:** `https://login.salesforce.com/services/oauth2/callback` (placeholder;
  no interactive redirect in client_credentials).

### Validation gotchas discovered (grounding for other agents)
1. **Scopes use metadata token names, not runtime strings.** `chatbot_api` etc. are
   rejected. Full valid list for THIS org (from deploy validator):
   `Basic, OfflineAccess, DataCloudUserClaims, Email, Address, CDPSegment, Chatbot,
   CustomApplications, Full, Profile, CDP, CDPProfile, RefreshToken, Phone, PwdlessLogin,
   Interaction, Pardot, CDPIngest, CDPIdentityResolution, CustomPermissions,
   ForgotPassword, UserRegistration, OpenID, Chatter, Wave, SFApiPlatform, SCRT, Web,
   EinsteinGPT, Lightning, Content, CDPCalculatedInsight, Eclair, Api, MCP, CDPQuery`.
2. **`ipRelaxation` / `refreshTokenPolicy` / `sessionTimeout` are NOT valid** in the
   `.ecaOauthPlcy` (OAuth policies) file — they belong in the general `.ecaPlcy`
   (`ExtlClntAppConfigurablePolicies`) file. OAuth policies file holds only flow toggles.
3. **Client Credentials "Run As" execution user cannot be set via metadata** — it
   references a specific User record and fails deploy with "Enter a valid execution user
   for the OAuth client credentials flow." → Must be set in the UI.

---

## REMAINING STEPS FOR USER (UI)
1. **Setup → External Client App Manager → Revenue Agent Headless → Policies → OAuth
   Policies → enable Client Credentials Flow and set the "Run As" integration user.**
   (This is what blocks the `.ecaOauthPlcy` file from deploying. Alternatively, after
   setting the run-as user, that file can be redeployed.)
2. Retrieve the **Consumer Key & Secret** (App Manager → the ECA → Settings/OAuth) for
   the Named Credential.
3. Confirm the **Agent API is enabled** for the org / run-as user.

## STILL TO BUILD (next phase, not started)
- **Named Credential** → ECA (client_credentials) pointing at the Agent API host.
- **@AuraEnabled Apex controller** (create session → post message → return response;
  persist sessionId).
- **LWC** that calls the controller and holds `sessionId` in component state for
  multi-turn.
- Target agent botId for Agent API calls: `0Xxg8000001B9dhCAC`.
