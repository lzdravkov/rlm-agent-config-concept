/**
 * AgentAdvisorServiceTest
 * -----------------------
 * Deterministic coverage for the guided-selling agent bridge.
 *
 * Test strategy:
 *  - The agent invocation is DETERMINISTICALLY mocked through AgentAdvisorService's
 *    @TestVisible AgentGateway seam (a JSON-envelope answer, a plain-text answer, the
 *    generic-failure string, a blank answer, an echoed session id, and a throwing
 *    gateway). NO test invokes the live Revenue_Quote_Management agent — so the suite
 *    burns no Einstein credits and does not depend on a live agent session.
 *  - The error contract is asserted exactly: blank question, hard invocation failure, and
 *    the soft "generic failure" / empty-answer paths all come back in the DTO with
 *    isSuccess=false and a message — askAgent NEVER throws.
 *  - Pure helpers (context-block build, envelope parse, generic-failure detection) are
 *    unit-tested directly through their @TestVisible entry points.
 *
 * The RealAgentGateway is intentionally NOT exercised (it would hit the live action);
 * mirrors how ConfigExtractionServiceTest leaves RealLlmGateway unexercised.
 */
@IsTest
private class AgentAdvisorServiceTest {

    // Representative context ids (syntactically plausible; never queried — the gateway is mocked).
    private static final String QUOTE_ID = '0Q0g8000000AbcdCAE';
    private static final String QLI_ID   = '0QLg8000001RYgDGAW';

    // =====================================================================
    // Mock agent gateways
    // =====================================================================

    /** Returns a fixed envelope + session id, and records what it was asked. */
    private class CannedAgentGateway implements AgentAdvisorService.AgentGateway {
        String cannedResponse;
        String cannedSessionId;
        String lastUserMessage;   // captured for context-block assertions
        String lastSessionId;     // captured for multi-turn assertions
        CannedAgentGateway(String cannedResponse, String cannedSessionId) {
            this.cannedResponse = cannedResponse;
            this.cannedSessionId = cannedSessionId;
        }
        public AgentAdvisorService.AgentRawResponse invoke(String userMessage, String sessionId) {
            this.lastUserMessage = userMessage;
            this.lastSessionId = sessionId;
            return new AgentAdvisorService.AgentRawResponse(cannedResponse, cannedSessionId);
        }
    }

    /** Simulates a hard invocation failure (empty/failed action result). */
    private class ThrowingAgentGateway implements AgentAdvisorService.AgentGateway {
        public AgentAdvisorService.AgentRawResponse invoke(String userMessage, String sessionId) {
            throw new AgentAdvisorService.AgentAdvisorException('Simulated agent invocation failure');
        }
    }

    // =====================================================================
    // Input guard
    // =====================================================================

    @IsTest
    static void blankQuestion_returnsError() {
        Test.startTest();
        AgentAdvisorService.AgentAnswer a =
            AgentAdvisorService.askAgent('   ', QUOTE_ID, QLI_ID, null);
        Test.stopTest();

        System.assertEquals(false, a.isSuccess);
        System.assertEquals('question is required', a.errorMessage);
        System.assertEquals(null, a.answerText);
    }

    // =====================================================================
    // Happy path — JSON envelope answer
    // =====================================================================

    @IsTest
    static void jsonEnvelopeAnswer_isParsedToText() {
        AgentAdvisorService.agentGateway = new CannedAgentGateway(
            '{"type":"Text","value":"COP is continuous power; PRP is prime power."}',
            'sess-123');

        Test.startTest();
        AgentAdvisorService.AgentAnswer a = AgentAdvisorService.askAgent(
            'tell me more about the duty rating options', QUOTE_ID, QLI_ID, null);
        Test.stopTest();

        System.assertEquals(true, a.isSuccess, 'unexpected error: ' + a.errorMessage);
        System.assertEquals('COP is continuous power; PRP is prime power.', a.answerText);
        System.assertEquals('sess-123', a.sessionId, 'session id must be carried back');
        System.assertEquals(null, a.errorMessage);
    }

    // =====================================================================
    // Plain-text answer (envelope not JSON) — accepted as-is
    // =====================================================================

    @IsTest
    static void plainTextAnswer_isAcceptedAsIs() {
        AgentAdvisorService.agentGateway = new CannedAgentGateway(
            'Data-center continuous is best for 24x7 IT loads.', 'sess-xyz');

        Test.startTest();
        AgentAdvisorService.AgentAnswer a = AgentAdvisorService.askAgent(
            'which duty suits a data center?', QUOTE_ID, QLI_ID, null);
        Test.stopTest();

        System.assertEquals(true, a.isSuccess, 'unexpected error: ' + a.errorMessage);
        System.assertEquals('Data-center continuous is best for 24x7 IT loads.', a.answerText);
    }

    // =====================================================================
    // Soft failure — the agent's generic "something went wrong" fallback
    // =====================================================================

    @IsTest
    static void genericFailureAnswer_isTreatedAsSoftFailure() {
        AgentAdvisorService.agentGateway = new CannedAgentGateway(
            '{"type":"Text","value":"Something went wrong. Try again."}', 'sess-err');

        Test.startTest();
        AgentAdvisorService.AgentAnswer a = AgentAdvisorService.askAgent(
            'explain duty ratings', QUOTE_ID, QLI_ID, null);
        Test.stopTest();

        System.assertEquals(false, a.isSuccess,
            'the generic fallback must NOT be surfaced as a real answer');
        System.assertEquals(null, a.answerText);
        System.assertNotEquals(null, a.errorMessage);
        System.assertEquals('sess-err', a.sessionId,
            'session id is still carried even on a soft failure so a follow-up stays in-session');
    }

    // =====================================================================
    // Soft failure — blank answer
    // =====================================================================

    @IsTest
    static void blankAnswer_isTreatedAsSoftFailure() {
        AgentAdvisorService.agentGateway = new CannedAgentGateway('   ', 'sess-blank');

        Test.startTest();
        AgentAdvisorService.AgentAnswer a = AgentAdvisorService.askAgent(
            'explain duty ratings', QUOTE_ID, QLI_ID, null);
        Test.stopTest();

        System.assertEquals(false, a.isSuccess);
        System.assertNotEquals(null, a.errorMessage);
    }

    // =====================================================================
    // Hard failure — the invocation throws
    // =====================================================================

    @IsTest
    static void invocationThrows_returnsErrorNotThrows() {
        AgentAdvisorService.agentGateway = new ThrowingAgentGateway();

        Test.startTest();
        AgentAdvisorService.AgentAnswer a = AgentAdvisorService.askAgent(
            'explain duty ratings', QUOTE_ID, QLI_ID, null);
        Test.stopTest();

        System.assertEquals(false, a.isSuccess,
            'a hard invocation failure must come back in the DTO, not thrown');
        System.assertEquals('Simulated agent invocation failure', a.errorMessage);
    }

    // =====================================================================
    // Context block + multi-turn session continuity
    // =====================================================================

    @IsTest
    static void contextBlockAndSessionId_arePassedToTheGateway() {
        CannedAgentGateway gw = new CannedAgentGateway(
            '{"type":"Text","value":"ok"}', 'sess-new');
        AgentAdvisorService.agentGateway = gw;

        Test.startTest();
        AgentAdvisorService.AgentAnswer a = AgentAdvisorService.askAgent(
            'follow-up question', QUOTE_ID, QLI_ID, 'sess-prior');
        Test.stopTest();

        System.assertEquals(true, a.isSuccess, 'unexpected error: ' + a.errorMessage);
        // The prior session id must be forwarded so the agent continues the conversation.
        System.assertEquals('sess-prior', gw.lastSessionId);
        // The message must carry the CONTEXT block AND the original question.
        System.assert(gw.lastUserMessage.contains('quoteId=' + QUOTE_ID),
            'context block must include the quote id: ' + gw.lastUserMessage);
        System.assert(gw.lastUserMessage.contains('quoteLineItemId=' + QLI_ID),
            'context block must include the line id: ' + gw.lastUserMessage);
        System.assert(gw.lastUserMessage.contains('follow-up question'),
            'the original question must be preserved: ' + gw.lastUserMessage);
    }

    // =====================================================================
    // Direct unit tests of pure helpers
    // =====================================================================

    @IsTest
    static void helper_buildContextMessage() {
        // Both ids present -> full CONTEXT block, then a blank line, then the question.
        String withBoth = AgentAdvisorService.buildContextMessage('q?', QUOTE_ID, QLI_ID);
        System.assert(withBoth.startsWith('CONTEXT: '), withBoth);
        System.assert(withBoth.contains('quoteId=' + QUOTE_ID), withBoth);
        System.assert(withBoth.contains('quoteLineItemId=' + QLI_ID), withBoth);
        System.assert(withBoth.endsWith('q?'), withBoth);

        // Only the line id present -> only that pair is emitted.
        String qliOnly = AgentAdvisorService.buildContextMessage('q?', '', QLI_ID);
        System.assert(qliOnly.contains('quoteLineItemId=' + QLI_ID), qliOnly);
        System.assert(!qliOnly.contains('quoteId='), qliOnly);

        // No ids -> the bare question, no CONTEXT prefix.
        String bare = AgentAdvisorService.buildContextMessage('q?', null, '  ');
        System.assertEquals('q?', bare);
    }

    @IsTest
    static void helper_parseAgentResponse() {
        // Envelope -> value.
        System.assertEquals('hello',
            AgentAdvisorService.parseAgentResponse('{"type":"Text","value":"hello"}'));
        // Plain text -> returned trimmed.
        System.assertEquals('just text',
            AgentAdvisorService.parseAgentResponse('  just text  '));
        // JSON object with no "value" key -> treated as plain text (the raw JSON string).
        System.assertEquals('{"type":"Text"}',
            AgentAdvisorService.parseAgentResponse('{"type":"Text"}'));
        // Blank / null -> null.
        System.assertEquals(null, AgentAdvisorService.parseAgentResponse('   '));
        System.assertEquals(null, AgentAdvisorService.parseAgentResponse(null));
    }

    @IsTest
    static void helper_fromOutputs() {
        // Populated output map -> both fields extracted.
        Map<String, Object> out = new Map<String, Object>{
            'agentResponse' => '{"type":"Text","value":"hi"}',
            'sessionId' => 'sess-1'
        };
        AgentAdvisorService.AgentRawResponse r = AgentAdvisorService.fromOutputs(out);
        System.assertEquals('{"type":"Text","value":"hi"}', r.agentResponse);
        System.assertEquals('sess-1', r.sessionId);

        // Null map -> both fields null (no NPE).
        AgentAdvisorService.AgentRawResponse rNull = AgentAdvisorService.fromOutputs(null);
        System.assertEquals(null, rNull.agentResponse);
        System.assertEquals(null, rNull.sessionId);
    }

    @IsTest
    static void helper_joinErrors() {
        // Blanks/nulls are dropped; the rest are joined.
        System.assertEquals('a; b',
            AgentAdvisorService.joinErrors(new List<String>{ 'a', null, '  ', 'b' }));
        // Empty / all-blank -> the generic fallback message.
        System.assert(
            AgentAdvisorService.joinErrors(new List<String>{ '  ', null })
                .contains('without a specific error'));
        System.assert(
            AgentAdvisorService.joinErrors(null).contains('without a specific error'));
    }

    @IsTest
    static void helper_isGenericFailure() {
        System.assertEquals(true,
            AgentAdvisorService.isGenericFailure('Something went wrong. Try again.'));
        System.assertEquals(true,
            AgentAdvisorService.isGenericFailure('SOMETHING WENT WRONG'),
            'match is case-insensitive');
        System.assertEquals(false,
            AgentAdvisorService.isGenericFailure('COP is continuous power.'));
        System.assertEquals(false,
            AgentAdvisorService.isGenericFailure(null));
    }
}
