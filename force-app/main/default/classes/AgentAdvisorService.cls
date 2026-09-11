/**
 * AgentAdvisorService
 * -------------------
 * Guided-selling / Q&A bridge for the RLM conversational configuration panel.
 *
 * ROLE IN THE UX  (see 06-open-questions-and-decisions.md, D8–D11)
 * ==============
 * The panel's existing engine (ConfigExtractionService + the LMS-publish apply path) only
 * knows how to turn a requirement into a *configuration change*. When a rep asks an
 * INFORMATIONAL question instead — "tell me more about the duty rating options", "which
 * option suits a hospital?" — extraction maps nothing and the rep hit a dead end.
 *
 * This service fills that gap by forwarding the question to the org's REAL Revenue
 * Management Agentforce agent (`Revenue_Quote_Management`) and returning its answer as
 * plain text. It is INSIGHT-ONLY: it performs no DML, publishes nothing to the
 * configurator, and never applies a configuration. The engine remains the sole apply path
 * (D9: agent = insight, engine = apply). The agent's own PST-based config action is
 * deliberately NOT used here — that would desync the live configurator (07 §4.4).
 *
 * HOW THE AGENT IS INVOKED  (verified by the 2026-07-19 smoke test)
 * ========================
 * The agent is reached synchronously from Apex through the CUSTOM invocable action
 * `generateAiAgentResponse`, targeted at the agent by its API/developer name:
 *     Invocable.Action.createCustomAction('generateAiAgentResponse', 'Revenue_Quote_Management')
 * Inputs : userMessage (String, required), sessionId (String, optional — multi-turn).
 * Outputs: agentResponse (String, a JSON envelope {"type":"Text","value":"…"} that MUST be
 *          parsed to text) and sessionId (String, echoed/created for the next turn).
 * No OAuth, no External Client App, no Named Credential — the running user's session is used.
 *
 * CONTEXT GROUNDING
 * =================
 * The agent's topic actions need the quote/line context (a bare probe answered
 * "the QuoteLineItem ID … is not valid or not found"). We prepend a compact CONTEXT block
 * to the question — CONTEXT: quoteId=… quoteLineItemId=…\n\n<question> — mirroring the
 * proven email-agent context-block pattern. The panel supplies the ids from its existing
 * @api quoteId / quoteLineItemId.
 *
 * ERROR CONTRACT (mirrors ConfigExtractionService / ConfigEngineController)
 * ==============
 * This method NEVER throws to the LWC's imperative call. Everything comes back in the DTO:
 *   - blank question                                     -> isSuccess=false + errorMessage
 *   - action invocation failure / thrown exception       -> caught -> isSuccess=false + errorMessage
 *   - the agent's known generic "Something went wrong.
 *     Try again." fallback (returned WITH isSuccess=true) -> treated as a soft failure:
 *     isSuccess=false + a friendly errorMessage, so the panel never renders that string
 *     as if it were a real answer.
 * On success: isSuccess=true, answerText populated, sessionId carried for the next turn.
 *
 * PLATFORM NOTES
 * ==============
 * - Latency: the full planner→topic→action path is ~8–9s P75; the LWC shows a "thinking…"
 *   state (this call is synchronous and simply takes that long).
 * - Debug-log truncation at the agent-callout boundary is a known quirk — results are
 *   captured STRUCTURALLY (the DTO), never via a trailing System.debug.
 *
 * SECURITY: `with sharing` so the running rep's record-level sharing is honored. Touches
 * none of the four protected engine services and does not call ConfigEngineController.
 *
 * TESTABILITY: the agent invocation is routed through the injectable AgentGateway seam
 * (mirrors ConfigExtractionService.LlmGateway) so tests supply deterministic responses and
 * never invoke the live agent — no Einstein credits burned, no live session dependency.
 */
public with sharing class AgentAdvisorService {

    // The agent's API / developer name (arg 2 of createCustomAction). Verified identity:
    // Bot Id 0Xxg8000001B9dhCAC, Type = InternalCopilot / AgentforceEmployeeAgent.
    @TestVisible
    private static final String AGENT_API_NAME = 'Revenue_Quote_Management';

    // The standard CUSTOM invocable action that manages an agent session.
    @TestVisible
    private static final String AGENT_ACTION_NAME = 'generateAiAgentResponse';

    // Known generic fallback the agent returns (WITH isSuccess=true) when it cannot answer.
    // Matched case-insensitively as a substring so we never surface it as a real answer.
    @TestVisible
    private static final String GENERIC_FAILURE_MARKER = 'something went wrong';

    // Friendly message shown when the agent returns its generic failure or an empty answer.
    private static final String FRIENDLY_UNAVAILABLE =
        'The assistant could not answer that just now. Please rephrase your question, or set '
        + 'the value directly in the configurator.';

    // =========================================================================
    // AGENT GATEWAY SEAM
    // =========================================================================
    // The agent invocation is routed through this injectable seam so tests can supply
    // deterministic responses (a JSON answer, plain text, the generic-failure string, a
    // blank answer, or a thrown failure) WITHOUT invoking the live agent. Production uses
    // RealAgentGateway, which performs the single createCustomAction(...).invoke() call.
    public interface AgentGateway {
        /**
         * @param userMessage the (context-prefixed) message to send to the agent
         * @param sessionId   the prior session id for multi-turn continuity, or null/blank
         * @return the raw agent response (envelope + session id)
         * @throws AgentAdvisorException on a hard invocation failure (empty/failed result)
         */
        AgentRawResponse invoke(String userMessage, String sessionId);
    }

    /** Raw, unparsed output of one agent invocation. */
    public class AgentRawResponse {
        public String agentResponse; // JSON envelope {"type":"Text","value":"…"} OR plain text
        public String sessionId;     // echoed/created session id for the next turn
        public AgentRawResponse(String agentResponse, String sessionId) {
            this.agentResponse = agentResponse;
            this.sessionId = sessionId;
        }
    }

    /**
     * Real implementation: one createCustomAction('generateAiAgentResponse', agentName)
     * invoke(). The method body is kept DELIBERATELY THIN — only the lines that genuinely
     * require a live `Invocable.Action.Result` (which has no constructor, so it cannot be
     * built in a test) live here. All pure interpretation logic is delegated to the
     * @TestVisible statics below, which operate on plain data types and ARE unit-tested.
     * Not exercised by the service tests (they inject a mock gateway) — mirrors RealLlmGateway.
     */
    @TestVisible
    private class RealAgentGateway implements AgentGateway {
        public AgentRawResponse invoke(String userMessage, String sessionId) {
            // Verified contract (2026-07-19 smoke test): the CUSTOM action's TYPE is
            // 'generateAiAgentResponse' and its NAME is the agent's API/developer name.
            Invocable.Action action =
                Invocable.Action.createCustomAction(AGENT_ACTION_NAME, AGENT_API_NAME);
            action.setInvocationParameter('userMessage', userMessage);
            // Pass sessionId only when we have one, so the first turn creates a session.
            if (String.isNotBlank(sessionId)) {
                action.setInvocationParameter('sessionId', sessionId);
            }

            List<Invocable.Action.Result> results = action.invoke();

            if (results == null || results.isEmpty()) {
                throw new AgentAdvisorException('The assistant returned no response.');
            }
            Invocable.Action.Result res = results[0];
            if (!res.isSuccess()) {
                // Flatten the (untestable) Error list to plain strings, then delegate.
                List<String> msgs = new List<String>();
                if (res.getErrors() != null) {
                    for (Invocable.Action.Error e : res.getErrors()) {
                        if (e != null) {
                            msgs.add(e.getMessage());
                        }
                    }
                }
                throw new AgentAdvisorException(joinErrors(msgs));
            }
            return fromOutputs(res.getOutputParameters());
        }
    }

    /**
     * Builds an AgentRawResponse from the action's output-parameter map. Pure + null-safe,
     * so it is unit-tested directly with a synthetic map (no live action needed).
     */
    @TestVisible
    private static AgentRawResponse fromOutputs(Map<String, Object> out) {
        String agentResponse = (out == null) ? null : (String) out.get('agentResponse');
        String newSessionId  = (out == null) ? null : (String) out.get('sessionId');
        return new AgentRawResponse(agentResponse, newSessionId);
    }

    /**
     * Joins the action-level error messages into one string for the DTO, ignoring blanks
     * and falling back to a generic message when there is nothing specific. Pure, so it is
     * unit-tested directly.
     */
    @TestVisible
    private static String joinErrors(List<String> msgs) {
        List<String> nonBlank = new List<String>();
        if (msgs != null) {
            for (String m : msgs) {
                if (String.isNotBlank(m)) {
                    nonBlank.add(m);
                }
            }
        }
        return nonBlank.isEmpty()
            ? 'The assistant call failed without a specific error.'
            : String.join(nonBlank, '; ');
    }

    /** Default is the real gateway; @TestVisible so tests can inject a mock. */
    @TestVisible
    private static AgentGateway agentGateway = new RealAgentGateway();

    // =========================================================================
    // DTO — every field the LWC reads must be @AuraEnabled
    // =========================================================================

    /** Full result of an askAgent call. */
    public class AgentAnswer {
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public String  answerText;   // parsed plain-text answer (null on failure)
        @AuraEnabled public String  sessionId;    // carry into the next turn for continuity
        @AuraEnabled public String  errorMessage; // null on success
    }

    // =========================================================================
    // ENTRY POINT
    // =========================================================================
    /**
     * Forwards a rep's informational question to the Revenue Management agent and returns
     * its answer as text.
     *
     * cacheable MUST be false: this makes an agent invocation (a callout-like action) and
     * the answer is non-deterministic per question. No DML is performed.
     *
     * @param question         the rep's free-text question (already determined to be Q&A,
     *                         not a configuration requirement — see D11 routing in the LWC)
     * @param quoteId          parent Quote Id, for the CONTEXT block (may be blank)
     * @param quoteLineItemId  root configurable QLI Id, for the CONTEXT block (may be blank)
     * @param sessionId        prior agent session id for multi-turn continuity, or null
     * @return AgentAnswer — always a structured result, never a thrown exception
     */
    @AuraEnabled(cacheable=false)
    public static AgentAnswer askAgent(String question,
                                       String quoteId,
                                       String quoteLineItemId,
                                       String sessionId) {
        AgentAnswer a = new AgentAnswer();

        // --- 1. Input guard (return-with-error, do not throw) ------------------
        if (String.isBlank(question)) {
            a.isSuccess = false;
            a.errorMessage = 'question is required';
            return a;
        }

        try {
            // --- 2. Ground the question with the quote/line CONTEXT block ------
            String userMessage = buildContextMessage(question, quoteId, quoteLineItemId);

            // --- 3. Invoke the agent through the injectable seam --------------
            AgentRawResponse raw = agentGateway.invoke(userMessage, sessionId);

            // Carry the session id forward even if the answer turns out unusable, so a
            // follow-up stays in the same conversation.
            a.sessionId = (raw != null) ? raw.sessionId : sessionId;

            // --- 4. Parse the envelope to plain text --------------------------
            String answer = (raw == null) ? null : parseAgentResponse(raw.agentResponse);

            // --- 5. Soft-failure handling: empty answer or the generic fallback
            if (String.isBlank(answer) || isGenericFailure(answer)) {
                a.isSuccess = false;
                a.errorMessage = FRIENDLY_UNAVAILABLE;
                return a;
            }

            a.answerText = answer.trim();
            a.isSuccess = true;
            return a;

        } catch (Exception e) {
            // Any hard failure (action invoke threw, empty/failed result) is reported, not thrown.
            a.isSuccess = false;
            a.errorMessage = e.getMessage();
            return a;
        }
    }

    // =========================================================================
    // CONTEXT BLOCK
    // =========================================================================
    /**
     * Prepends a compact CONTEXT block so the agent's topic actions can resolve the quote
     * and line without the rep having to name them. Blank ids are omitted rather than
     * emitted as empty pairs. Mirrors the proven email-agent context-block pattern (D10).
     *   CONTEXT: quoteId=<id> quoteLineItemId=<id>
     *
     *   <question>
     */
    @TestVisible
    private static String buildContextMessage(String question, String quoteId, String quoteLineItemId) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(quoteId)) {
            parts.add('quoteId=' + quoteId);
        }
        if (String.isNotBlank(quoteLineItemId)) {
            parts.add('quoteLineItemId=' + quoteLineItemId);
        }
        if (parts.isEmpty()) {
            return question; // no context available — send the bare question
        }
        return 'CONTEXT: ' + String.join(parts, ' ') + '\n\n' + question;
    }

    // =========================================================================
    // RESPONSE PARSING
    // =========================================================================
    /**
     * Extracts plain text from the agent's response. The verified envelope is
     * {"type":"Text","value":"…"} — we return the "value". Defensive on shape:
     *   - a JSON object with a "value" key -> that value's string form;
     *   - anything that does not parse as such (already plain text, or an unexpected
     *     shape) -> the raw string, trimmed.
     * Never throws; a parse failure just means "treat it as plain text".
     */
    @TestVisible
    private static String parseAgentResponse(String agentResponse) {
        if (String.isBlank(agentResponse)) {
            return null;
        }
        String trimmed = agentResponse.trim();
        try {
            Object parsed = JSON.deserializeUntyped(trimmed);
            if (parsed instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) parsed;
                Object val = m.get('value');
                if (val != null) {
                    return String.valueOf(val);
                }
            }
        } catch (Exception ignored) {
            // Not JSON — fall through and treat the whole thing as the answer text.
        }
        return trimmed;
    }

    /**
     * True when the answer is the agent's known generic fallback ("Something went wrong.
     * Try again."), which it returns WITH a successful invocation. Matched case-insensitively
     * as a substring so we catch minor wording variants.
     */
    @TestVisible
    private static Boolean isGenericFailure(String answer) {
        if (String.isBlank(answer)) {
            return false;
        }
        return answer.toLowerCase().contains(GENERIC_FAILURE_MARKER);
    }

    /** Internal failure marker for a hard agent-invocation problem. */
    public class AgentAdvisorException extends Exception {}
}
