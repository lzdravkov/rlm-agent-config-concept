/**
 * ConfigEngineControllerTest
 * --------------------------
 * Test strategy (per the evidence-based feasibility probe for THIS org):
 *
 *  - SeeAllData=true against the known-good, live quote (0Q0g80000017wQ5CAI /
 *    root line 0QLg8000001RYgDGAW). The probe empirically proved the real Place
 *    Sales Transaction (PST) engine RUNS in a test context here, so the happy
 *    path exercises the real ProductAttributeSaveService end-to-end — no PST stub
 *    needed. We re-submit the CURRENT value (requiredKW=1500) so the live quote is
 *    not meaningfully mutated, and we accept either PST outcome (assert the wrapper
 *    returned a structured result) so the test is not brittle to engine behavior.
 *
 *  - Deterministic branch coverage of the SAVE_FAILED and SAVE_EXCEPTION paths is
 *    achieved by injecting mock SaveGateway implementations through the controller's
 *    @TestVisible seam, rather than trying to make the real engine reject something.
 *
 *  - Pure-logic helpers (diff, numeric-aware equality, null-safe subtraction) are
 *    unit-tested directly and deterministically.
 *
 * Coverage target: ConfigEngineController >= 75% (the deploy gate). Under
 * RunSpecifiedTests only this class must clear the bar; the four backing services
 * are not in this deploy package.
 *
 * DATA-DEPENDENCY CAVEAT: the SeeAllData=true methods rely on the live quote and its
 * attributes continuing to exist. That quote backs the live NGA agent and is stable,
 * but this coupling is intentional and noted.
 */
@IsTest(SeeAllData=true)
private class ConfigEngineControllerTest {

    // Known-good seeded records in this org.
    private static final Id LIVE_QUOTE_ID = '0Q0g80000017wQ5CAI';
    private static final Id LIVE_ROOT_QLI_ID = '0QLg8000001RYgDGAW';

    // ---------------------------------------------------------------------
    // Mock gateways for deterministic failure/exception coverage
    // ---------------------------------------------------------------------

    /** Returns a canned SaveOutput without ever touching the real PST. */
    private class MockSaveGateway implements ConfigEngineController.SaveGateway {
        private ProductAttributeSaveService.SaveOutput canned;
        MockSaveGateway(ProductAttributeSaveService.SaveOutput canned) {
            this.canned = canned;
        }
        public List<ProductAttributeSaveService.SaveOutput> save(
                List<ProductAttributeSaveService.SaveInput> inputs) {
            return new List<ProductAttributeSaveService.SaveOutput>{ canned };
        }
    }

    /** Simulates the engine throwing (e.g. a PST platform/limit exception). */
    private class ThrowingSaveGateway implements ConfigEngineController.SaveGateway {
        public List<ProductAttributeSaveService.SaveOutput> save(
                List<ProductAttributeSaveService.SaveInput> inputs) {
            throw new CalloutException('Simulated PST failure');
        }
    }

    private static ProductAttributeSaveService.SaveOutput makeSaveOutput(
            Boolean success, String savedJson, String err) {
        ProductAttributeSaveService.SaveOutput so =
            new ProductAttributeSaveService.SaveOutput();
        so.isSuccess = success;
        so.isValid = true;
        so.savedAttributesJson = savedJson;
        so.validationErrorsJson = '[]';
        so.errorMessage = err;
        return so;
    }

    // =====================================================================
    // getAttributes
    // =====================================================================

    @IsTest
    static void getAttributes_blankId_returnsError() {
        Test.startTest();
        ConfigEngineController.AttributesResult r =
            ConfigEngineController.getAttributes('');
        Test.stopTest();

        System.assertEquals('quoteLineItemId is required', r.errorMessage,
            'Blank id should return a guard error, not throw');
        System.assertEquals(false, r.hasConfigurableAttributes);
        System.assertNotEquals(null, r.attributes, 'attributes must never be null');
        System.assertEquals(0, r.attributes.size());
    }

    @IsTest
    static void getAttributes_liveLine_returnsConfigurableAttributes() {
        Test.startTest();
        ConfigEngineController.AttributesResult r =
            ConfigEngineController.getAttributes(LIVE_ROOT_QLI_ID);
        Test.stopTest();

        System.assertNotEquals(null, r, 'Result should not be null');
        System.assertEquals(null, r.errorMessage,
            'Live configurable line should not error: ' + r.errorMessage);
        System.assertEquals(true, r.hasConfigurableAttributes,
            'Root generator-set line should have configurable attributes');
        System.assert(r.attributes.size() > 0, 'Expected parsed attribute options');
        // Spot-check the DTO was populated from attributesJson.
        ConfigEngineController.AttributeOption first = r.attributes[0];
        System.assertNotEquals(null, first.developerName,
            'developerName should be mapped from attributesJson');
    }

    // =====================================================================
    // getSavedConfiguration
    // =====================================================================

    @IsTest
    static void getSavedConfiguration_blankId_returnsError() {
        Test.startTest();
        ConfigEngineController.SavedConfigResult r =
            ConfigEngineController.getSavedConfiguration(null);
        Test.stopTest();

        System.assertEquals('quoteLineItemId is required', r.errorMessage);
    }

    @IsTest
    static void getSavedConfiguration_liveLine_returnsValues() {
        Test.startTest();
        ConfigEngineController.SavedConfigResult r =
            ConfigEngineController.getSavedConfiguration(LIVE_ROOT_QLI_ID);
        Test.stopTest();

        System.assertEquals(null, r.errorMessage,
            'Read of live line should not error: ' + r.errorMessage);
        System.assertNotEquals(null, r.savedAttributesJson,
            'Persisted attributes JSON should be returned');
        System.assertNotEquals(null, r.configurationSummary);
    }

    // =====================================================================
    // applyConfiguration — guards
    // =====================================================================

    @IsTest
    static void applyConfiguration_blankInputs_returnsError() {
        Test.startTest();
        ConfigEngineController.ApplyResult r =
            ConfigEngineController.applyConfiguration('', '', '');
        Test.stopTest();

        System.assertEquals(false, r.isSuccess);
        System.assert(r.errorMessage.contains('required'),
            'Should surface a required-field guard message');
        System.assertNotEquals(null, r.diffs, 'diffs must never be null');
        System.assertEquals(0, r.diffs.size());
    }

    @IsTest
    static void applyConfiguration_qliNotFound_returnsError() {
        // A syntactically valid but non-existent QLI Id.
        Id fakeQli = '0QLg8000001RYgDGAW'.left(15) + '999';
        Test.startTest();
        ConfigEngineController.ApplyResult r = ConfigEngineController.applyConfiguration(
            LIVE_QUOTE_ID, fakeQli, '{"requiredKW":1500}');
        Test.stopTest();

        System.assertEquals(false, r.isSuccess);
        System.assert(r.errorMessage.contains('not found'),
            'Should report QLI not found: ' + r.errorMessage);
    }

    // =====================================================================
    // applyConfiguration — SAVE_FAILED (mock gateway, deterministic)
    // =====================================================================

    @IsTest
    static void applyConfiguration_saveFailure_reportsEngineError() {
        // Inject a gateway that reports failure so we do not run PST.
        ConfigEngineController.saveGateway = new MockSaveGateway(
            makeSaveOutput(false, null, 'Engine rejected the save'));

        Test.startTest();
        ConfigEngineController.ApplyResult r = ConfigEngineController.applyConfiguration(
            LIVE_QUOTE_ID, LIVE_ROOT_QLI_ID, '{"requiredKW":1500}');
        Test.stopTest();

        System.assertEquals(false, r.isSuccess);
        System.assertEquals('Engine rejected the save', r.errorMessage);
        System.assertEquals(null, r.priceAfter,
            'Failure path must skip the post-save price query');
        System.assertEquals(null, r.priceDelta);
        System.assertNotEquals(null, r.priceBefore,
            'Pre-save snapshot is captured before the save attempt');
        System.assertEquals(0, r.diffs.size());
    }

    // =====================================================================
    // applyConfiguration — SAVE_EXCEPTION (throwing gateway)
    // =====================================================================

    @IsTest
    static void applyConfiguration_saveThrows_caughtAndReported() {
        ConfigEngineController.saveGateway = new ThrowingSaveGateway();

        Test.startTest();
        ConfigEngineController.ApplyResult r = ConfigEngineController.applyConfiguration(
            LIVE_QUOTE_ID, LIVE_ROOT_QLI_ID, '{"requiredKW":1500}');
        Test.stopTest();

        System.assertEquals(false, r.isSuccess,
            'A thrown engine exception must be caught and reported, not bubbled');
        System.assert(r.errorMessage.contains('Simulated PST failure'),
            'Exception message should be surfaced: ' + r.errorMessage);
        System.assertEquals(null, r.priceAfter);
        System.assertEquals(null, r.priceDelta);
    }

    // =====================================================================
    // applyConfiguration — SUCCESS path (mock gateway + real live price query)
    // =====================================================================

    @IsTest
    static void applyConfiguration_success_computesDeltaAndDiff() {
        // Mock a successful save whose readback silently corrected requiredKW to 1500
        // (the documented DutyRating=DCC override). We request 900 to force a diff.
        ConfigEngineController.saveGateway = new MockSaveGateway(
            makeSaveOutput(true, '{"requiredKW":"1500","DutyRating":"Data Center Continuous (DCC)"}', null));

        Test.startTest();
        ConfigEngineController.ApplyResult r = ConfigEngineController.applyConfiguration(
            LIVE_QUOTE_ID, LIVE_ROOT_QLI_ID,
            '{"requiredKW":900,"DutyRating":"Data Center Continuous (DCC)"}');
        Test.stopTest();

        System.assertEquals(true, r.isSuccess, 'Mocked save reports success');
        System.assertNotEquals(null, r.priceBefore, 'Pre-save snapshot from live QLI');
        System.assertNotEquals(null, r.priceAfter, 'Post-save snapshot from live QLI');
        System.assertNotEquals(null, r.priceDelta, 'Delta computed on success');

        // Diff must flag the silently-corrected requiredKW (requested 900, actual 1500)
        // and must NOT flag DutyRating (requested == actual).
        Map<String, ConfigEngineController.DiffEntry> byName =
            new Map<String, ConfigEngineController.DiffEntry>();
        for (ConfigEngineController.DiffEntry d : r.diffs) {
            byName.put(d.developerName, d);
        }
        System.assert(byName.containsKey('requiredKW'), 'requiredKW should be in diff');
        System.assertEquals(true, byName.get('requiredKW').changed,
            '900 -> 1500 is a silent correction and must be flagged changed');
        System.assertEquals(false, byName.get('DutyRating').changed,
            'DutyRating requested == actual, should not be flagged');
    }

    // =====================================================================
    // applyConfiguration — REAL PST end-to-end (covers RealSaveGateway)
    // =====================================================================

    @IsTest
    static void applyConfiguration_realEngine_runsEndToEnd() {
        // Default (real) gateway → real ProductAttributeSaveService → real PST.
        // Re-submit the current value so the live quote is not meaningfully changed.
        // The probe proved PST runs in-test; we accept either outcome so this test is
        // robust, while still covering the real forwarding gateway + orchestration.
        Test.startTest();
        ConfigEngineController.ApplyResult r = ConfigEngineController.applyConfiguration(
            LIVE_QUOTE_ID, LIVE_ROOT_QLI_ID, '{"requiredKW":1500}');
        Test.stopTest();

        System.assertNotEquals(null, r,
            'Wrapper must always return a structured result');
        System.assertNotEquals(null, r.priceBefore,
            'Pre-save snapshot is always captured for a valid configurable line');
        // isSuccess may be true (PST ran) or false (engine reported an issue); both are
        // acceptable — we are asserting the wrapper handled it, not the engine outcome.
    }

    // =====================================================================
    // Pure-logic helpers
    // =====================================================================

    @IsTest
    static void helper_valuesEqual_numericAndString() {
        System.assertEquals(true, ConfigEngineController.valuesEqual('1500', '1500.000000'),
            'Numeric values differing only in formatting are equal');
        System.assertEquals(true, ConfigEngineController.valuesEqual(' PRP ', 'prp'),
            'Strings compare trimmed and case-insensitive');
        System.assertEquals(false, ConfigEngineController.valuesEqual('900', '1500'),
            'Different numbers are not equal');
        System.assertEquals(true, ConfigEngineController.valuesEqual(null, null),
            'Two nulls are equal');
        System.assertEquals(false, ConfigEngineController.valuesEqual(null, 'x'),
            'One null is not equal');
        System.assertEquals(false, ConfigEngineController.valuesEqual('COP', 'ESP'));
    }

    @IsTest
    static void helper_nullSafeMinus() {
        System.assertEquals(9555, ConfigEngineController.nullSafeMinus(59005, 49450),
            'Delta after - before');
        System.assertEquals(null, ConfigEngineController.nullSafeMinus(null, 100));
        System.assertEquals(null, ConfigEngineController.nullSafeMinus(100, null));
    }

    @IsTest
    static void helper_buildDiffs_handlesBlankSaved() {
        // When the engine returned no readback, actual is null → everything changed.
        List<ConfigEngineController.DiffEntry> diffs =
            ConfigEngineController.buildDiffs('{"requiredKW":1500}', null);
        System.assertEquals(1, diffs.size());
        System.assertEquals('requiredKW', diffs[0].developerName);
        System.assertEquals(true, diffs[0].changed,
            'Requested value with null actual counts as changed');
        System.assertEquals(null, diffs[0].actual);
    }
}
