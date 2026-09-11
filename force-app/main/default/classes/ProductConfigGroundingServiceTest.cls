/**
 * ProductConfigGroundingServiceTest
 * ---------------------------------
 * Coverage for the PRODUCT-based (pre-persist) grounding twin of getAttributes /
 * getLmsGrounding.
 *
 * Test strategy (mirrors ConfigLmsGroundingServiceTest / ConfigExtractionServiceTest):
 *  - The SOQL is DETERMINISTICALLY replaced through the @TestVisible CatalogReader seam
 *    with a fully controlled synthetic ProductCatalog. This lets every branch of the
 *    interpretation logic be asserted exactly with NO live data:
 *      * label = Name ?? Code (Code fallback when Name is blank)
 *      * product/classification exclusion filtering
 *      * ambiguous-label detection (a label on >1 value under one picklist)
 *      * number/non-picklist attributes (picklistValues / picklistValueIds null)
 *      * not-configurable (basedOnId null) and blank-input guards
 *  - The REAL reader's unknown-product early return is covered without SeeAllData.
 *  - ONE @IsTest(SeeAllData=true) cross-check proves ZERO DRIFT against the live FESBA
 *    classification: getAttributesForProduct(product) must yield the SAME attribute
 *    developerName set and the SAME picklist label sets as
 *    ConfigEngineController.getAttributes(<a QLI on that product>). It is org-resilient:
 *    it looks the fixture up by name and SKIPS (returns) if absent, so it never hard-fails
 *    in a scratch org lacking the data while still exercising RealCatalogReader here.
 */
@IsTest
private class ProductConfigGroundingServiceTest {

    // ---- fabricated 15-char Ids (no 18-char checksum validation to worry about) ----
    private static Integer idCounter = 1;
    private static Id fakeId(String prefix) {
        String s = String.valueOf(idCounter++);
        return Id.valueOf(prefix + '0'.repeat(12 - s.length()) + s);
    }

    // =====================================================================
    // Mock reader
    // =====================================================================
    /** Returns a canned ProductCatalog regardless of the productId argument. */
    private class MockCatalogReader implements ProductConfigGroundingService.CatalogReader {
        private ProductConfigGroundingService.ProductCatalog cat;
        MockCatalogReader(ProductConfigGroundingService.ProductCatalog cat) { this.cat = cat; }
        public ProductConfigGroundingService.ProductCatalog read(String productId) { return cat; }
    }

    // ---- synthetic-row builders ----
    private static ProductConfigGroundingService.ClassAttr attr(
            String dev, String name, String dataType, Id attributeId, Id picklistId) {
        ProductConfigGroundingService.ClassAttr a = new ProductConfigGroundingService.ClassAttr();
        a.developerName = dev;
        a.name = name;
        a.dataType = dataType;
        a.isRequired = false;
        a.isPriceImpacting = false;
        a.attributeId = attributeId;
        a.picklistId = picklistId;
        return a;
    }

    private static ProductConfigGroundingService.PickValue pick(
            Id valueId, String name, String code, Id picklistId) {
        ProductConfigGroundingService.PickValue v = new ProductConfigGroundingService.PickValue();
        v.valueId = valueId;
        v.name = name;
        v.code = code;
        v.picklistId = picklistId;
        return v;
    }

    /**
     * A representative catalog: one picklist attr (with a Name??Code-fallback value and an
     * excluded value), one Number attr, and one picklist attr with a duplicate label.
     */
    private static ProductConfigGroundingService.ProductCatalog sampleCatalog() {
        Id p1 = fakeId('0v5');   // DutyRating picklist
        Id p2 = fakeId('0v5');   // ambiguous picklist
        Id dccId = fakeId('0v6');
        Id copId = fakeId('0v6');
        Id exclId = fakeId('0v6');
        Id dupAId = fakeId('0v6');
        Id dupBId = fakeId('0v6');
        Id uniqId = fakeId('0v6');

        ProductConfigGroundingService.ProductCatalog cat =
            new ProductConfigGroundingService.ProductCatalog();
        cat.productName = 'Test Generator';
        cat.basedOnId = fakeId('11B');

        cat.attributes.add(attr('DutyRating', 'Duty Rating', 'Picklist', fakeId('0tj'), p1));
        cat.attributes.add(attr('requiredKW', 'Full Load (kW)', 'Number', fakeId('0tj'), null));
        cat.attributes.add(attr('specialApplication', 'Special App', 'Picklist', fakeId('0tj'), p2));

        // p1: a normal Name, a Name-blank value (Code fallback), and an EXCLUDED value.
        cat.picklistValues.add(pick(dccId, 'Data Center Continuous (DCC)', 'DCC', p1));
        cat.picklistValues.add(pick(copId, null, 'COP', p1)); // label must fall back to Code
        cat.picklistValues.add(pick(exclId, 'Excluded One', 'EXC', p1));
        // p2: two values sharing a label (ambiguous) + one unique.
        cat.picklistValues.add(pick(dupAId, 'Dup', 'D1', p2));
        cat.picklistValues.add(pick(dupBId, 'Dup', 'D2', p2));
        cat.picklistValues.add(pick(uniqId, 'Unique', 'U1', p2));

        cat.excludedValueIds.add(exclId); // remove "Excluded One"
        return cat;
    }

    private static void inject(ProductConfigGroundingService.ProductCatalog cat) {
        ProductConfigGroundingService.reader = new MockCatalogReader(cat);
    }

    // =====================================================================
    // getAttributesForProduct
    // =====================================================================

    @IsTest
    static void getAttributes_mapsLabelsExclusionsAndTypes() {
        inject(sampleCatalog());

        Test.startTest();
        ConfigEngineController.AttributesResult r =
            ProductConfigGroundingService.getAttributesForProduct(fakeId('01t'));
        Test.stopTest();

        System.assertEquals(null, r.errorMessage, 'no error expected');
        System.assertEquals('Test Generator', r.productName);
        System.assertEquals(true, r.hasConfigurableAttributes);
        System.assertEquals(3, r.attributes.size(), 'all three attributes returned');

        Map<String, ConfigEngineController.AttributeOption> byDev =
            new Map<String, ConfigEngineController.AttributeOption>();
        for (ConfigEngineController.AttributeOption o : r.attributes) {
            byDev.put(o.developerName, o);
        }

        // Picklist with Name??Code fallback and an exclusion applied.
        ConfigEngineController.AttributeOption duty = byDev.get('DutyRating');
        System.assertEquals('Picklist', duty.dataType);
        Set<String> dutyLabels = new Set<String>(duty.picklistValues);
        System.assert(dutyLabels.contains('Data Center Continuous (DCC)'), 'Name label present');
        System.assert(dutyLabels.contains('COP'), 'Code fallback used when Name is blank');
        System.assert(!dutyLabels.contains('Excluded One'), 'excluded value removed');
        System.assertEquals(2, duty.picklistValues.size(), 'exactly the two non-excluded values');

        // Number attribute -> picklistValues null (matches getAttributes).
        ConfigEngineController.AttributeOption kw = byDev.get('requiredKW');
        System.assertEquals('Number', kw.dataType);
        System.assertEquals(null, kw.picklistValues, 'number attr has no picklist values');
    }

    @IsTest
    static void getAttributes_notConfigurable_returnsEmptyNoError() {
        ProductConfigGroundingService.ProductCatalog cat =
            new ProductConfigGroundingService.ProductCatalog();
        cat.productName = 'Simple Product';
        cat.basedOnId = null; // not classification-based
        inject(cat);

        ConfigEngineController.AttributesResult r =
            ProductConfigGroundingService.getAttributesForProduct(fakeId('01t'));

        System.assertEquals(null, r.errorMessage);
        System.assertEquals('Simple Product', r.productName);
        System.assertEquals(false, r.hasConfigurableAttributes);
        System.assert(r.attributes.isEmpty());
    }

    @IsTest
    static void getAttributes_blankProduct_returnsError() {
        ConfigEngineController.AttributesResult r =
            ProductConfigGroundingService.getAttributesForProduct('');
        System.assertEquals('productId is required', r.errorMessage);
        System.assertEquals(false, r.hasConfigurableAttributes);
    }

    // =====================================================================
    // getLmsGroundingForProduct
    // =====================================================================

    @IsTest
    static void getLmsGrounding_buildsLabelToIdAndFlagsAmbiguity() {
        inject(sampleCatalog());

        Test.startTest();
        ProductConfigGroundingService.LmsGroundingResult r =
            ProductConfigGroundingService.getLmsGroundingForProduct(fakeId('01t'));
        Test.stopTest();

        System.assertEquals(null, r.errorMessage);
        System.assertEquals(3, r.attributes.size());

        Map<String, ConfigLmsGroundingService.LmsAttributeGrounding> byDev =
            new Map<String, ConfigLmsGroundingService.LmsAttributeGrounding>();
        for (ConfigLmsGroundingService.LmsAttributeGrounding g : r.attributes) {
            byDev.put(g.developerName, g);
        }

        // DutyRating: label->valueId join, exclusion removed, no ambiguity.
        ConfigLmsGroundingService.LmsAttributeGrounding duty = byDev.get('DutyRating');
        System.assertNotEquals(null, duty.attributeId, 'attributeId (0tj) carried');
        System.assertEquals(2, duty.picklistValueIds.size(), 'excluded value dropped');
        Map<String, String> label2id = new Map<String, String>();
        for (ConfigLmsGroundingService.PicklistValueId pvi : duty.picklistValueIds) {
            label2id.put(pvi.label, pvi.valueId);
        }
        System.assert(label2id.containsKey('Data Center Continuous (DCC)'));
        System.assert(label2id.containsKey('COP'), 'Code-fallback label mapped to its Id');
        System.assert(!label2id.containsKey('Excluded One'));
        System.assertEquals(0, duty.ambiguousLabels.size(), 'all labels unique');

        // specialApplication: "Dup" appears twice -> flagged ambiguous.
        ConfigLmsGroundingService.LmsAttributeGrounding sp = byDev.get('specialApplication');
        System.assertEquals(1, sp.ambiguousLabels.size());
        System.assertEquals('Dup', sp.ambiguousLabels[0]);

        // Number attribute -> no picklist grounding.
        ConfigLmsGroundingService.LmsAttributeGrounding kw = byDev.get('requiredKW');
        System.assertEquals(null, kw.picklistValueIds, 'number attr has no picklist value ids');
        System.assertEquals(null, kw.ambiguousLabels);
    }

    @IsTest
    static void getLmsGrounding_notConfigurable_returnsEmptyNoError() {
        ProductConfigGroundingService.ProductCatalog cat =
            new ProductConfigGroundingService.ProductCatalog();
        cat.basedOnId = null;
        inject(cat);

        ProductConfigGroundingService.LmsGroundingResult r =
            ProductConfigGroundingService.getLmsGroundingForProduct(fakeId('01t'));

        System.assertEquals(null, r.errorMessage);
        System.assert(r.attributes.isEmpty());
    }

    @IsTest
    static void getLmsGrounding_blankProduct_returnsError() {
        ProductConfigGroundingService.LmsGroundingResult r =
            ProductConfigGroundingService.getLmsGroundingForProduct(null);
        System.assertEquals('productId is required', r.errorMessage);
    }

    // =====================================================================
    // Real reader (no SeeAllData): unknown but valid-format product Id
    // =====================================================================

    @IsTest
    static void realReader_unknownProduct_returnsNotConfigurable() {
        // Default (real) reader; a valid-format product Id that resolves to no record.
        // Exercises RealCatalogReader query 1 + the empty-result early return.
        ConfigEngineController.AttributesResult r =
            ProductConfigGroundingService.getAttributesForProduct('01t000000000001');
        System.assertEquals(null, r.errorMessage);
        System.assertEquals(false, r.hasConfigurableAttributes);
        System.assert(r.attributes.isEmpty());
    }

    // =====================================================================
    // ZERO-DRIFT cross-check against the live FESBA classification (SeeAllData)
    // =====================================================================

    @IsTest(SeeAllData=true)
    static void crossCheck_productCatalogMatchesSavedLinePath() {
        // Look the fixture up by stable name so this is scratch-org safe (skip if absent).
        List<Product2> ps = [
            SELECT Id FROM Product2
            WHERE Name = 'FESBA Generator Set' AND BasedOnId != null LIMIT 1
        ];
        if (ps.isEmpty()) {
            return; // org lacks the fixture -> nothing to cross-check
        }
        Id productId = ps[0].Id;
        List<QuoteLineItem> qs = [
            SELECT Id FROM QuoteLineItem WHERE Product2Id = :productId LIMIT 1
        ];
        if (qs.isEmpty()) {
            return; // no line on that product to compare against
        }
        Id qliId = qs[0].Id;

        Test.startTest();
        ConfigEngineController.AttributesResult prod =
            ProductConfigGroundingService.getAttributesForProduct(productId);
        ConfigEngineController.AttributesResult saved =
            ConfigEngineController.getAttributes(qliId);
        ProductConfigGroundingService.LmsGroundingResult ground =
            ProductConfigGroundingService.getLmsGroundingForProduct(productId);
        Test.stopTest();

        System.assertEquals(null, prod.errorMessage, 'product path must not error');
        System.assertEquals(null, saved.errorMessage, 'saved path must not error');

        // 1. Same attribute developerName set.
        System.assertEquals(devNames(saved), devNames(prod),
            'product-based attribute set must equal the classification (saved) set');

        // 2. Same picklist label set per attribute — the zero-drift proof.
        Map<String, Set<String>> savedLabels = labelSets(saved);
        Map<String, Set<String>> prodLabels = labelSets(prod);
        System.assertEquals(savedLabels.keySet(), prodLabels.keySet(),
            'the same attributes must expose picklist values');
        for (String dev : savedLabels.keySet()) {
            System.assertEquals(savedLabels.get(dev), prodLabels.get(dev),
                'picklist labels must match exactly for ' + dev);
        }

        // 3. Grounding returns a usable label->Id join for the product.
        System.assertEquals(null, ground.errorMessage);
        System.assert(!ground.attributes.isEmpty(), 'grounding should return attributes');
    }

    // ---- SeeAllData cross-check helpers ----
    private static Set<String> devNames(ConfigEngineController.AttributesResult r) {
        Set<String> s = new Set<String>();
        for (ConfigEngineController.AttributeOption o : r.attributes) {
            s.add(o.developerName);
        }
        return s;
    }

    private static Map<String, Set<String>> labelSets(ConfigEngineController.AttributesResult r) {
        Map<String, Set<String>> m = new Map<String, Set<String>>();
        for (ConfigEngineController.AttributeOption o : r.attributes) {
            if (o.picklistValues != null && !o.picklistValues.isEmpty()) {
                m.put(o.developerName, new Set<String>(o.picklistValues));
            }
        }
        return m;
    }
}
