/**
 * ConfigExtractionServiceTest
 * ---------------------------
 * Deterministic coverage for the grounded NL -> validated-selection extractor.
 *
 * Test strategy:
 *  - The LLM callout is DETERMINISTICALLY mocked through ConfigExtractionService's
 *    @TestVisible LlmGateway seam (clean JSON, fenced JSON, garbage, non-object, blank,
 *    and a throwing gateway). No test depends on a live, non-deterministic Einstein call.
 *  - The grounding catalog is supplied through the @TestVisible groundingOverride seam
 *    with a fully controlled synthetic catalog (a Number attr, two Picklist attrs, a
 *    Checkbox attr, and a free-text attr). This lets the VALIDATION property be asserted
 *    exactly: hallucinated attribute names and illegal picklist values are dropped/flagged,
 *    valid values survive and are canonicalized.
 *  - The real ConfigEngineController.getAttributes grounding branch (override == null) is
 *    covered with a non-existent QLI, which returns a non-configurable catalog — no
 *    SeeAllData and no live-record dependency required.
 *  - Pure helpers (fence-strip, tokenize, picklist matching, number extraction, boolean
 *    coercion, prompt build) are unit-tested directly.
 *
 * Not @IsTest(SeeAllData=true): the seams make live data unnecessary, keeping the suite
 * fast and non-brittle.
 */
@IsTest
private class ConfigExtractionServiceTest {

    // A syntactically valid QLI Id that does not exist in the org (for the real
    // getAttributes grounding branch — returns non-configurable, no records touched).
    private static final Id FAKE_QLI = '0QLg8000001RYgDGAW'.left(15) + '999';

    // =====================================================================
    // Mock LLM gateways
    // =====================================================================

    /** Returns a fixed string as the model output. */
    private class CannedLlmGateway implements ConfigExtractionService.LlmGateway {
        private String canned;
        CannedLlmGateway(String canned) { this.canned = canned; }
        public String generate(String prompt) { return canned; }
    }

    /** Simulates a transport/limit failure from the Einstein callout. */
    private class ThrowingLlmGateway implements ConfigExtractionService.LlmGateway {
        public String generate(String prompt) {
            throw new CalloutException('Simulated Einstein callout failure');
        }
    }

    // =====================================================================
    // Synthetic grounding catalog
    // =====================================================================

    private static ConfigEngineController.AttributeOption opt(
            String devName, String name, String dataType,
            Boolean priceImpacting, List<String> picklistValues) {
        ConfigEngineController.AttributeOption a = new ConfigEngineController.AttributeOption();
        a.developerName    = devName;
        a.name             = name;
        a.dataType         = dataType;
        a.isRequired       = false;
        a.isPriceImpacting = priceImpacting;
        a.attributeId      = '0tt000000000000AAA';
        a.picklistValues   = picklistValues;
        return a;
    }

    /**
     * Builds a controlled catalog:
     *   requiredKW    Number
     *   DutyRating    Picklist [Standby, Prime, DataCenterContinuous]
     *   voltageClass  Picklist [LowVoltage, MediumVoltage]
     *   emergencyMode Checkbox
     *   installNotes  Text (free-text / unknown dataType)
     */
    private static ConfigEngineController.AttributesResult syntheticCatalog() {
        ConfigEngineController.AttributesResult r = new ConfigEngineController.AttributesResult();
        r.productName = 'FESBA Generator Set';
        r.hasConfigurableAttributes = true;
        r.errorMessage = null;
        r.attributes = new List<ConfigEngineController.AttributeOption>{
            opt('requiredKW', 'Required KW', 'Number', true, null),
            opt('DutyRating', 'Duty Rating', 'Picklist', true,
                new List<String>{ 'Standby', 'Prime', 'DataCenterContinuous' }),
            opt('voltageClass', 'Voltage Class', 'Picklist', false,
                new List<String>{ 'LowVoltage', 'MediumVoltage' }),
            opt('emergencyMode', 'Emergency Mode', 'Checkbox', false, null),
            opt('installNotes', 'Install Notes', 'Text', false, null)
        };
        return r;
    }

    // =====================================================================
    // Input guards
    // =====================================================================

    @IsTest
    static void blankRequirement_returnsError() {
        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('   ', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(false, r.isSuccess);
        System.assertEquals('requirementText is required', r.errorMessage);
        System.assertNotEquals(null, r.proposedFields, 'proposedFields never null');
        System.assertEquals(0, r.proposedFields.size());
    }

    @IsTest
    static void blankQli_returnsError() {
        // With BOTH the line id and productId blank there is nothing to ground on. The
        // guard message widened when the pre-persist productId path was added (a blank line
        // is now legal as long as a productId is supplied — see prePersist_* tests below).
        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('1500 kW', '');
        Test.stopTest();

        System.assertEquals(false, r.isSuccess);
        System.assertEquals('quoteLineItemId or productId is required', r.errorMessage);
    }

    // =====================================================================
    // Grounding branches
    // =====================================================================

    @IsTest
    static void realGrounding_nonConfigurableLine_shortCircuits() {
        // override == null -> real ConfigEngineController.getAttributes is called with a
        // non-existent QLI, which returns a non-configurable catalog. Must NOT call LLM.
        ConfigExtractionService.llmGateway =
            new CannedLlmGateway('{"requiredKW":"1500"}'); // would succeed if reached
        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('~1500 kW', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(false, r.isSuccess,
            'A non-configurable / unknown line must short-circuit before the LLM');
        System.assertNotEquals(null, r.errorMessage);
        System.assertEquals(0, r.proposedFields.size());
    }

    @IsTest
    static void grounding_nullResult_returnsError() {
        ConfigExtractionService.groundingOverride = null; // explicit
        // Force null by overriding with a null-attributes result path is not possible;
        // instead simulate a catalog whose errorMessage is set.
        ConfigEngineController.AttributesResult errCat =
            new ConfigEngineController.AttributesResult();
        errCat.errorMessage = 'quoteLineItemId is required';
        errCat.attributes = new List<ConfigEngineController.AttributeOption>();
        ConfigExtractionService.groundingOverride = errCat;

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('1500 kW', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(false, r.isSuccess);
        System.assertEquals('quoteLineItemId is required', r.errorMessage,
            'getAttributes error text is passed through');
    }

    @IsTest
    static void grounding_noConfigurableAttributes_returnsError() {
        ConfigEngineController.AttributesResult empty =
            new ConfigEngineController.AttributesResult();
        empty.hasConfigurableAttributes = false;
        empty.attributes = new List<ConfigEngineController.AttributeOption>();
        ConfigExtractionService.groundingOverride = empty;

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('1500 kW', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(false, r.isSuccess);
        System.assert(r.errorMessage.contains('no configurable attributes'),
            'Should explain there is nothing to extract into: ' + r.errorMessage);
    }

    // =====================================================================
    // LLM path — validation is the critical property
    // =====================================================================

    @IsTest
    static void llmPath_validatesAndCanonicalizes() {
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        // Clean JSON with: valid number, picklist needing canonicalization, ILLEGAL
        // picklist value, HALLUCINATED attribute, non-numeric number, coercible checkbox,
        // and a free-text value.
        String json =
            '{'
            + '"requiredKW":"1500",'
            + '"DutyRating":"datacentercontinuous",'   // case-diff -> canonical DataCenterContinuous
            + '"voltageClass":"HV",'                   // illegal picklist value -> flagged invalid
            + '"fuelType":"Diesel",'                   // hallucinated attr -> dropped
            + '"ampRating":"not-a-number",'            // hallucinated attr too (not in catalog)
            + '"emergencyMode":"yes",'                 // checkbox coercion -> true
            + '"installNotes":"rooftop install"'       // free-text -> accepted
            + '}';
        ConfigExtractionService.llmGateway = new CannedLlmGateway(json);

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration(
                '~1500 kW data-center continuous, HV', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess);
        System.assertEquals('LLM', r.extractionMethod);
        System.assertEquals('FESBA Generator Set', r.productName);

        Map<String, ConfigExtractionService.ProposedField> byName =
            new Map<String, ConfigExtractionService.ProposedField>();
        for (ConfigExtractionService.ProposedField p : r.proposedFields) {
            byName.put(p.developerName, p);
        }

        // Hallucinated attributes never reach the card.
        System.assert(!byName.containsKey('fuelType'), 'fuelType must be dropped');
        System.assert(!byName.containsKey('ampRating'), 'ampRating must be dropped');

        // Valid number survives.
        System.assert(byName.containsKey('requiredKW'));
        System.assertEquals(true, byName.get('requiredKW').isValid);
        System.assertEquals('1500', byName.get('requiredKW').proposedValue);
        System.assertEquals('high', byName.get('requiredKW').confidence);
        System.assertEquals(true, byName.get('requiredKW').isPriceImpacting);
        System.assertEquals(false, byName.get('requiredKW').isPicklist);

        // Picklist canonicalized to the exact catalog spelling.
        System.assert(byName.containsKey('DutyRating'));
        System.assertEquals(true, byName.get('DutyRating').isValid);
        System.assertEquals('DataCenterContinuous', byName.get('DutyRating').proposedValue,
            'Case-insensitive match must emit the canonical catalog value');
        System.assertEquals(true, byName.get('DutyRating').isPicklist);
        System.assertNotEquals(null, byName.get('DutyRating').picklistValues);

        // Illegal picklist value is EMITTED but flagged invalid (so the rep sees it).
        System.assert(byName.containsKey('voltageClass'));
        System.assertEquals(false, byName.get('voltageClass').isValid,
            'HV is not a legal voltageClass value and must be flagged invalid');

        // Checkbox coercion.
        System.assert(byName.containsKey('emergencyMode'));
        System.assertEquals(true, byName.get('emergencyMode').isValid);
        System.assertEquals('true', byName.get('emergencyMode').proposedValue);

        // Free-text accepted as-is.
        System.assert(byName.containsKey('installNotes'));
        System.assertEquals(true, byName.get('installNotes').isValid);
        System.assertEquals('rooftop install', byName.get('installNotes').proposedValue);

        // unmappedNotes should record the dropped/invalid items.
        String allNotes = String.join(r.unmappedNotes, ' | ');
        System.assert(allNotes.contains('fuelType'), 'note for hallucinated fuelType');
        System.assert(allNotes.contains('voltageClass'), 'note for illegal voltageClass');
    }

    @IsTest
    static void llmPath_newShape_configureIntent_mapsFields() {
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        // New response contract: explicit intent + nested fields object.
        String json =
            '{"intent":"CONFIGURE","fields":{"requiredKW":"1500",'
            + '"DutyRating":"DataCenterContinuous"}}';
        ConfigExtractionService.llmGateway = new CannedLlmGateway(json);

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration(
                '~1500 kW data-center continuous', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess);
        System.assertEquals('LLM', r.extractionMethod);
        System.assertEquals('CONFIGURE', r.intent, 'intent echoed from the LLM response');
        System.assertEquals(2, r.proposedFields.size(),
            'both fields from the nested "fields" object are validated');
        Map<String, ConfigExtractionService.ProposedField> byName =
            new Map<String, ConfigExtractionService.ProposedField>();
        for (ConfigExtractionService.ProposedField p : r.proposedFields) {
            byName.put(p.developerName, p);
        }
        System.assertEquals('1500', byName.get('requiredKW').proposedValue);
        System.assertEquals('DataCenterContinuous', byName.get('DutyRating').proposedValue);
    }

    @IsTest
    static void llmPath_askIntent_skipsFieldMappingEntirely() {
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        // An advice question. Even if the model greedily echoed a picklist word into
        // "fields", an ASK must yield NO proposed fields — the LWC forwards it to the agent.
        String json =
            '{"intent":"ASK","fields":{"DutyRating":"DataCenterContinuous"}}';
        ConfigExtractionService.llmGateway = new CannedLlmGateway(json);

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration(
                'what do you recommend for a data center and why', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess);
        System.assertEquals('LLM', r.extractionMethod);
        System.assertEquals('ASK', r.intent);
        System.assertEquals(0, r.proposedFields.size(),
            'ASK must not produce any proposed fields, regardless of what fields the model returned');
    }

    @IsTest
    static void llmPath_missingIntent_defaultsToConfigure() {
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        // Legacy flat object with no "intent" key -> readIntent defaults to CONFIGURE
        // and the whole object is treated as the field map (back-compat).
        ConfigExtractionService.llmGateway =
            new CannedLlmGateway('{"requiredKW":"1500"}');

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('1500 kW', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess);
        System.assertEquals('CONFIGURE', r.intent,
            'a response with no intent key defaults to CONFIGURE');
        System.assertEquals(1, r.proposedFields.size());
        System.assertEquals('1500', r.proposedFields[0].proposedValue);
    }

    @IsTest
    static void fallback_reportsConfigureIntent() {
        // When the LLM path fails, the deterministic mapper runs and intent must be
        // CONFIGURE (the fallback cannot classify a question).
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        ConfigExtractionService.llmGateway = new ThrowingLlmGateway();

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('~1500 kW', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess);
        System.assertEquals('FALLBACK', r.extractionMethod);
        System.assertEquals('CONFIGURE', r.intent,
            'the keyword fallback always reports CONFIGURE');
    }

    @IsTest
    static void helper_readIntent() {
        System.assertEquals('ASK', ConfigExtractionService.readIntent(
            new Map<String, Object>{ 'intent' => 'ASK' }));
        System.assertEquals('ASK', ConfigExtractionService.readIntent(
            new Map<String, Object>{ 'intent' => ' ask ' }),
            'trimmed + case-insensitive');
        System.assertEquals('CONFIGURE', ConfigExtractionService.readIntent(
            new Map<String, Object>{ 'intent' => 'CONFIGURE' }));
        System.assertEquals('CONFIGURE', ConfigExtractionService.readIntent(
            new Map<String, Object>{ 'requiredKW' => '1500' }),
            'no intent key -> CONFIGURE');
        System.assertEquals('CONFIGURE', ConfigExtractionService.readIntent(
            new Map<String, Object>{ 'intent' => 'gibberish' }),
            'unrecognized intent -> CONFIGURE');
        System.assertEquals('CONFIGURE', ConfigExtractionService.readIntent(null));
    }

    @IsTest
    static void helper_readFields() {
        // Nested new shape -> the inner map.
        Map<String, Object> nested = ConfigExtractionService.readFields(
            new Map<String, Object>{
                'intent' => 'CONFIGURE',
                'fields' => new Map<String, Object>{ 'requiredKW' => '1500' }
            });
        System.assertEquals(1, nested.size());
        System.assertEquals('1500', String.valueOf(nested.get('requiredKW')));

        // Legacy flat shape -> the object itself, minus reserved keys.
        Map<String, Object> flat = ConfigExtractionService.readFields(
            new Map<String, Object>{ 'requiredKW' => '2000', 'intent' => 'CONFIGURE' });
        System.assertEquals(1, flat.size(), 'reserved "intent" key stripped from a flat map');
        System.assertEquals('2000', String.valueOf(flat.get('requiredKW')));

        System.assertEquals(0, ConfigExtractionService.readFields(null).size());
    }

    @IsTest
    static void llmPath_stripsFencesBeforeParsing() {
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        String fenced = '```json\n{"requiredKW":"2000"}\n```';
        ConfigExtractionService.llmGateway = new CannedLlmGateway(fenced);

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('2000 kW', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess);
        System.assertEquals('LLM', r.extractionMethod,
            'Fenced JSON must still parse via the LLM path after fence-strip');
        System.assertEquals(1, r.proposedFields.size());
        System.assertEquals('2000', r.proposedFields[0].proposedValue);
    }

    // =====================================================================
    // FALLBACK path — LLM failures degrade gracefully
    // =====================================================================

    @IsTest
    static void llmThrows_fallsBackDeterministically() {
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        ConfigExtractionService.llmGateway = new ThrowingLlmGateway();

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration(
                '~1500 kW, data-center continuous duty, low voltage', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess,
            'LLM failure is non-fatal; fallback still succeeds');
        System.assertEquals('FALLBACK', r.extractionMethod);

        Map<String, ConfigExtractionService.ProposedField> byName =
            new Map<String, ConfigExtractionService.ProposedField>();
        for (ConfigExtractionService.ProposedField p : r.proposedFields) {
            byName.put(p.developerName, p);
        }
        // Regex number extraction.
        System.assert(byName.containsKey('requiredKW'), 'fallback should regex 1500 kW');
        System.assertEquals('1500', byName.get('requiredKW').proposedValue);
        System.assertEquals('low', byName.get('requiredKW').confidence,
            'fallback fields are low confidence');
        // Picklist token matching.
        System.assertEquals('DataCenterContinuous', byName.get('DutyRating').proposedValue);
        System.assertEquals('LowVoltage', byName.get('voltageClass').proposedValue);

        // The LLM failure is surfaced as a note, not a hard error.
        String allNotes = String.join(r.unmappedNotes, ' | ');
        System.assert(allNotes.contains('LLM extraction unavailable'),
            'LLM failure must be surfaced as an unmappedNote');
    }

    @IsTest
    static void llmBlank_fallsBack() {
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        ConfigExtractionService.llmGateway = new CannedLlmGateway('   ');

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('1500 kW', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess);
        System.assertEquals('FALLBACK', r.extractionMethod);
    }

    @IsTest
    static void llmGarbage_fallsBack() {
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        ConfigExtractionService.llmGateway =
            new CannedLlmGateway('this is not json at all {{{');

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('1500 kW', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess);
        System.assertEquals('FALLBACK', r.extractionMethod,
            'Unparseable JSON must degrade to the fallback mapper');
    }

    @IsTest
    static void llmNonObjectJson_fallsBack() {
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        // Valid JSON, but an array — not the expected object.
        ConfigExtractionService.llmGateway = new CannedLlmGateway('[1,2,3]');

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('1500 kW', FAKE_QLI);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess);
        System.assertEquals('FALLBACK', r.extractionMethod);
    }

    // =====================================================================
    // Direct unit tests of pure helpers
    // =====================================================================

    @IsTest
    static void helper_stripFences() {
        System.assertEquals('{"a":1}',
            ConfigExtractionService.stripFences('```json\n{"a":1}\n```'));
        System.assertEquals('{"a":1}',
            ConfigExtractionService.stripFences('   {"a":1}   '));
        System.assertEquals('{"a":1}',
            ConfigExtractionService.stripFences('```\n{"a":1}\n```'));
        System.assertEquals(null, ConfigExtractionService.stripFences(null));
    }

    @IsTest
    static void helper_tokenize() {
        System.assertEquals(new List<String>{ 'data', 'center', 'continuous' },
            ConfigExtractionService.tokenize('DataCenterContinuous'));
        System.assertEquals(new List<String>{ 'required', 'kw' },
            ConfigExtractionService.tokenize('requiredKW'));
        System.assertEquals(new List<String>{ 'low', 'voltage' },
            ConfigExtractionService.tokenize('Low Voltage'));
        System.assertEquals(0, ConfigExtractionService.tokenize('  ').size());
    }

    @IsTest
    static void helper_matchPicklist() {
        List<String> vals = new List<String>{ 'Standby', 'DataCenterContinuous' };
        System.assertEquals('DataCenterContinuous',
            ConfigExtractionService.matchPicklist('datacentercontinuous', vals),
            'Case-insensitive match returns canonical value');
        System.assertEquals('Standby',
            ConfigExtractionService.matchPicklist('  standby ', vals));
        System.assertEquals(null,
            ConfigExtractionService.matchPicklist('HV', vals));
        System.assertEquals(null,
            ConfigExtractionService.matchPicklist(null, vals));
    }

    @IsTest
    static void helper_extractNumberFor() {
        ConfigEngineController.AttributeOption kw =
            opt('requiredKW', 'Required KW', 'Number', true, null);
        System.assertEquals(1500,
            ConfigExtractionService.extractNumberFor('~1,500 kw for the datacenter', kw));
        System.assertEquals(2000,
            ConfigExtractionService.extractNumberFor('needs 2000kw', kw));
        System.assertEquals(null,
            ConfigExtractionService.extractNumberFor('no magnitude here', kw));
    }

    @IsTest
    static void helper_matchPicklistByTokens() {
        List<String> vals = new List<String>{ 'LowVoltage', 'MediumVoltage' };
        System.assertEquals('LowVoltage',
            ConfigExtractionService.matchPicklistByTokens('needs low voltage gear', vals));
        System.assertEquals('MediumVoltage',
            ConfigExtractionService.matchPicklistByTokens('medium voltage please', vals));
        System.assertEquals(null,
            ConfigExtractionService.matchPicklistByTokens('high pressure only', vals));
    }

    @IsTest
    static void helper_coerceBoolean_and_tryDecimal() {
        System.assertEquals(true, ConfigExtractionService.coerceBoolean('YES'));
        System.assertEquals(false, ConfigExtractionService.coerceBoolean('0'));
        System.assertEquals(null, ConfigExtractionService.coerceBoolean('maybe'));
        System.assertEquals(1500, ConfigExtractionService.tryDecimal(' 1500 '));
        System.assertEquals(null, ConfigExtractionService.tryDecimal('abc'));
        System.assertEquals(null, ConfigExtractionService.tryDecimal(null));
    }

    @IsTest
    static void helper_buildGroundedPrompt_embedsCatalog() {
        String prompt = ConfigExtractionService.buildGroundedPrompt(
            '~1500 kW low voltage', syntheticCatalog().attributes);
        System.assert(prompt.contains('requiredKW'), 'developerName seeded');
        System.assert(prompt.contains('DataCenterContinuous'),
            'picklist values seeded for grounding');
        System.assert(prompt.contains('no code fences'),
            'instruction to avoid fences present');
        System.assert(prompt.contains('~1500 kW low voltage'),
            'requirement text embedded');
        System.assert(prompt.contains('CONFIGURE') && prompt.contains('ASK'),
            'prompt instructs the model to classify intent');
    }

    // =====================================================================
    // PRE-PERSIST grounding (productId path) — Stage 2
    // =====================================================================
    // These cover resolveCatalog's routing: a NON-persisted line (blank or a transient
    // ref_ node) with a productId grounds off ProductConfigGroundingService, while a
    // persisted 0QL… line keeps using ConfigEngineController.getAttributes. The product
    // reader is injected through ProductConfigGroundingService's @TestVisible seam so no
    // live catalog data is needed and the routing decision is observable.

    // A valid-format Product2 Id that need not exist — the mock reader ignores it.
    private static final String FAKE_PRODUCT = '01t000000000001';

    // Tracks whether the product reader was consulted, so a test can assert that the
    // persisted-line path does NOT route through the product grounding service.
    private static Boolean productReaderCalled = false;

    /**
     * Canned product catalog reader. Returns a controlled ProductCatalog (one Number attr
     * and one Picklist attr) regardless of productId, and records that it was called.
     */
    private class StubProductReader implements ProductConfigGroundingService.CatalogReader {
        public ProductConfigGroundingService.ProductCatalog read(String productId) {
            productReaderCalled = true;
            return prePersistCatalog();
        }
    }

    /** Builds a minimal configurable ProductCatalog: requiredKW (Number) + DutyRating (Picklist). */
    private static ProductConfigGroundingService.ProductCatalog prePersistCatalog() {
        ProductConfigGroundingService.ProductCatalog cat =
            new ProductConfigGroundingService.ProductCatalog();
        cat.productName = 'FESBA Generator Set';
        cat.basedOnId = '11B000000000001'; // non-null => configurable

        ProductConfigGroundingService.ClassAttr kw = new ProductConfigGroundingService.ClassAttr();
        kw.developerName = 'requiredKW';
        kw.name = 'Required KW';
        kw.dataType = 'Number';
        kw.isRequired = false;
        kw.isPriceImpacting = true;
        kw.attributeId = '0tj000000000001';
        kw.picklistId = null;
        cat.attributes.add(kw);

        Id dutyPicklistId = '0v5000000000001';
        ProductConfigGroundingService.ClassAttr duty = new ProductConfigGroundingService.ClassAttr();
        duty.developerName = 'DutyRating';
        duty.name = 'Duty Rating';
        duty.dataType = 'Picklist';
        duty.isRequired = false;
        duty.isPriceImpacting = true;
        duty.attributeId = '0tj000000000002';
        duty.picklistId = dutyPicklistId;
        cat.attributes.add(duty);

        // Two legal picklist values (Name label; Code fallback path is covered in
        // ProductConfigGroundingServiceTest, so plain Names here).
        cat.picklistValues.add(pickVal('0v6000000000001', 'Standby', 'STBY', dutyPicklistId));
        cat.picklistValues.add(pickVal('0v6000000000002', 'DataCenterContinuous', 'DCC', dutyPicklistId));
        return cat;
    }

    private static ProductConfigGroundingService.PickValue pickVal(
            Id valueId, String name, String code, Id picklistId) {
        ProductConfigGroundingService.PickValue v = new ProductConfigGroundingService.PickValue();
        v.valueId = valueId;
        v.name = name;
        v.code = code;
        v.picklistId = picklistId;
        return v;
    }

    @IsTest
    static void prePersist_refLine_withProduct_groundsOffProduct() {
        // Transient ref_ line + productId, NO groundingOverride -> resolveCatalog must route
        // through ProductConfigGroundingService.getAttributesForProduct (the product reader).
        ConfigExtractionService.groundingOverride = null;
        ProductConfigGroundingService.reader = new StubProductReader();
        productReaderCalled = false;
        // A canned LLM extraction that maps a value present ONLY in the product catalog,
        // proving the product catalog (not the saved line) drove grounding + validation.
        ConfigExtractionService.llmGateway = new CannedLlmGateway(
            '{"intent":"CONFIGURE","fields":{"requiredKW":"1500","DutyRating":"DataCenterContinuous"}}');

        Test.startTest();
        ConfigExtractionService.ExtractionResult r = ConfigExtractionService.extractConfiguration(
            '~1500 kW data center continuous', 'ref_abc123def456', FAKE_PRODUCT);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess, 'pre-persist ref_ line grounds off the product');
        System.assertEquals(true, productReaderCalled, 'product reader must be consulted');
        System.assertEquals('FESBA Generator Set', r.productName, 'product name echoed');
        System.assert(!r.proposedFields.isEmpty(), 'fields mapped from the product catalog');
        Map<String, String> byDev = new Map<String, String>();
        for (ConfigExtractionService.ProposedField f : r.proposedFields) {
            byDev.put(f.developerName, f.proposedValue);
        }
        System.assertEquals('DataCenterContinuous', byDev.get('DutyRating'),
            'a value that exists only in the product catalog validated -> product grounded');
    }

    @IsTest
    static void prePersist_blankLine_withProduct_grounds() {
        // Blank line id but a productId present: the widened guard admits it and the product
        // path grounds it (catalog-launch before any transient node id has been assigned).
        ConfigExtractionService.groundingOverride = null;
        ProductConfigGroundingService.reader = new StubProductReader();
        productReaderCalled = false;
        ConfigExtractionService.llmGateway = new CannedLlmGateway(
            '{"intent":"CONFIGURE","fields":{"requiredKW":"2000"}}');

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('2000 kW', '', FAKE_PRODUCT);
        Test.stopTest();

        System.assertEquals(true, r.isSuccess, 'blank line + productId grounds off the product');
        System.assertEquals(true, productReaderCalled);
        System.assertEquals('2000', firstValue(r, 'requiredKW'));
    }

    @IsTest
    static void persistedLine_withProductId_usesSavedPath_notProduct() {
        // A persisted 0QL… line MUST keep using ConfigEngineController.getAttributes even
        // when a productId is also supplied — the product reader must NOT be consulted.
        ConfigExtractionService.groundingOverride = null;
        ProductConfigGroundingService.reader = new StubProductReader();
        productReaderCalled = false;
        ConfigExtractionService.llmGateway =
            new CannedLlmGateway('{"requiredKW":"1500"}'); // would succeed if reached

        Test.startTest();
        ConfigExtractionService.ExtractionResult r =
            ConfigExtractionService.extractConfiguration('~1500 kW', FAKE_QLI, FAKE_PRODUCT);
        Test.stopTest();

        System.assertEquals(false, productReaderCalled,
            'a persisted 0QL line must bypass the product reader (saved-line grounding)');
        // FAKE_QLI resolves to no record -> non-configurable short-circuit before the LLM.
        System.assertEquals(false, r.isSuccess);
    }

    @IsTest
    static void twoArgOverload_delegatesWithNullProduct() {
        // The non-annotated 2-arg overload must behave exactly like the 3-arg form with a
        // null productId. With groundingOverride set (saved-line semantics), both succeed.
        ConfigExtractionService.groundingOverride = syntheticCatalog();
        ConfigExtractionService.llmGateway = new CannedLlmGateway(
            '{"intent":"CONFIGURE","fields":{"requiredKW":"1500"}}');

        Test.startTest();
        ConfigExtractionService.ExtractionResult twoArg =
            ConfigExtractionService.extractConfiguration('1500 kW', FAKE_QLI);
        ConfigExtractionService.ExtractionResult threeArg =
            ConfigExtractionService.extractConfiguration('1500 kW', FAKE_QLI, null);
        Test.stopTest();

        System.assertEquals(true, twoArg.isSuccess);
        System.assertEquals(true, threeArg.isSuccess);
        System.assertEquals(twoArg.extractionMethod, threeArg.extractionMethod,
            '2-arg overload delegates to the 3-arg form with productId=null');
        System.assertEquals(firstValue(twoArg, 'requiredKW'), firstValue(threeArg, 'requiredKW'));
    }

    /** First proposedValue for a developerName, or null. */
    private static String firstValue(ConfigExtractionService.ExtractionResult r, String dev) {
        for (ConfigExtractionService.ProposedField f : r.proposedFields) {
            if (f.developerName == dev) {
                return f.proposedValue;
            }
        }
        return null;
    }
}
