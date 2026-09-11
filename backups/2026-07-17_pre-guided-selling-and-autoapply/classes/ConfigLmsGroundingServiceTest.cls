/**
 * ConfigLmsGroundingServiceTest
 * -----------------------------
 * Test strategy mirrors ConfigEngineControllerTest: SeeAllData=true against the
 * known-good live line (root QLI 0QLg8000001RYgDGAW on quote 0Q0g80000017wQ5CAI),
 * which carries a mix of Picklist and Number attributes. The service is SOQL-only
 * (no DML, no PST), so the live read is safe and non-mutating.
 *
 * We assert the two correctness properties the LMS publish path depends on:
 *   1. Every returned attribute has a non-blank attributeId (0tj AttributeDefinition Id).
 *   2. Picklist attributes carry a non-empty label→valueId list whose valueIds are
 *      AttributePicklistValue Ids (0v6 key prefix), and whose labels match the catalog.
 *      Non-picklist attributes carry no picklistValueIds.
 *
 * DATA-DEPENDENCY CAVEAT: same as ConfigEngineControllerTest — relies on the stable
 * live quote/line continuing to exist. Intentional and noted.
 */
@IsTest(SeeAllData=true)
private class ConfigLmsGroundingServiceTest {

    private static final Id LIVE_ROOT_QLI_ID = '0QLg8000001RYgDGAW';

    @IsTest
    static void getLmsGrounding_blankId_returnsError() {
        Test.startTest();
        ConfigLmsGroundingService.LmsGroundingResult r =
            ConfigLmsGroundingService.getLmsGrounding('');
        Test.stopTest();

        System.assertEquals('quoteLineItemId is required', r.errorMessage,
            'Blank id should return a guard error, not throw');
        System.assertNotEquals(null, r.attributes, 'attributes must never be null');
        System.assertEquals(0, r.attributes.size());
    }

    @IsTest
    static void getLmsGrounding_liveLine_returnsAttributeIdsAndPicklistValueIds() {
        Test.startTest();
        ConfigLmsGroundingService.LmsGroundingResult r =
            ConfigLmsGroundingService.getLmsGrounding(LIVE_ROOT_QLI_ID);
        Test.stopTest();

        System.assertEquals(null, r.errorMessage,
            'Live configurable line should not error: ' + r.errorMessage);
        System.assert(r.attributes.size() > 0,
            'Expected grounding for the live line attributes');

        Boolean sawPicklist = false;
        Boolean sawNonPicklist = false;

        for (ConfigLmsGroundingService.LmsAttributeGrounding g : r.attributes) {
            System.assertNotEquals(null, g.developerName, 'developerName must be set');
            System.assert(String.isNotBlank(g.attributeId),
                'attributeId (0tj) must be set for ' + g.developerName);
            System.assert(((String) g.attributeId).startsWith('0tj'),
                'attributeId should be an AttributeDefinition Id: ' + g.attributeId);

            if ('Picklist'.equalsIgnoreCase(g.dataType)) {
                sawPicklist = true;
                System.assertNotEquals(null, g.picklistValueIds,
                    'Picklist ' + g.developerName + ' must carry a value-id list');
                System.assert(g.picklistValueIds.size() > 0,
                    'Picklist ' + g.developerName + ' must have at least one legal value');
                for (ConfigLmsGroundingService.PicklistValueId pvi : g.picklistValueIds) {
                    System.assert(String.isNotBlank(pvi.label),
                        'Each picklist value must expose a label');
                    System.assert(String.isNotBlank(pvi.valueId)
                            && pvi.valueId.startsWith('0v6'),
                        'valueId must be an AttributePicklistValue Id (0v6): ' + pvi.valueId);
                }
            } else {
                sawNonPicklist = true;
                System.assertEquals(null, g.picklistValueIds,
                    'Non-picklist ' + g.developerName + ' should carry no value-id list');
            }
        }

        System.assert(sawPicklist,
            'Live line is expected to have at least one Picklist attribute (e.g. DutyRating)');
        System.assert(sawNonPicklist,
            'Live line is expected to have at least one Number attribute (e.g. requiredKW)');
    }

    @IsTest
    static void getLmsGrounding_dutyRating_mapsLabelToKnownValueId() {
        // Ground truth confirmed in the org: DutyRating (0tjg8000000ETqDAAW) contains
        // "Data Center Continuous (DCC)" = AttributePicklistValue 0v6g8000000FQArAAO.
        Test.startTest();
        ConfigLmsGroundingService.LmsGroundingResult r =
            ConfigLmsGroundingService.getLmsGrounding(LIVE_ROOT_QLI_ID);
        Test.stopTest();

        ConfigLmsGroundingService.LmsAttributeGrounding duty;
        for (ConfigLmsGroundingService.LmsAttributeGrounding g : r.attributes) {
            if ('DutyRating'.equals(g.developerName)) {
                duty = g;
                break;
            }
        }

        System.assertNotEquals(null, duty, 'DutyRating grounding should be present');
        System.assertEquals('0tjg8000000ETqDAAW', duty.attributeId,
            'DutyRating attributeId should match the known AttributeDefinition Id');

        Map<String, String> idByLabel = new Map<String, String>();
        for (ConfigLmsGroundingService.PicklistValueId pvi : duty.picklistValueIds) {
            idByLabel.put(pvi.label, pvi.valueId);
        }
        System.assert(idByLabel.containsKey('Data Center Continuous (DCC)'),
            'DCC label should be present in the label->id map');
        System.assertEquals('0v6g8000000FQArAAO',
            idByLabel.get('Data Center Continuous (DCC)'),
            'DCC label must map to its known AttributePicklistValue Id');
    }

    /**
     * CROSS-SERVICE JOIN CONSISTENCY (the property the LMS apply path depends on).
     * The LWC canonicalizes a rep's picklist selection against the LABELS emitted by
     * ConfigEngineController.getAttributes (which sources ProductAttributeService), then
     * joins that label against getLmsGrounding's label->0v6-Id map to build the publish
     * payload. If the two services keyed their labels differently the join would silently
     * miss. This test asserts that, for every picklist attribute on the live line, the
     * label SET from getAttributes exactly matches the label set from getLmsGrounding —
     * i.e. every value the rep can pick has a resolvable Id, and vice versa.
     */
    @IsTest
    static void getLmsGrounding_picklistLabels_matchGetAttributes() {
        Test.startTest();
        ConfigEngineController.AttributesResult attrs =
            ConfigEngineController.getAttributes(LIVE_ROOT_QLI_ID);
        ConfigLmsGroundingService.LmsGroundingResult grounding =
            ConfigLmsGroundingService.getLmsGrounding(LIVE_ROOT_QLI_ID);
        Test.stopTest();

        System.assertEquals(null, attrs.errorMessage,
            'getAttributes should not error on the live line: ' + attrs.errorMessage);
        System.assertEquals(null, grounding.errorMessage,
            'getLmsGrounding should not error on the live line: ' + grounding.errorMessage);

        // Index grounding by developerName for lookup.
        Map<String, ConfigLmsGroundingService.LmsAttributeGrounding> groundByDev =
            new Map<String, ConfigLmsGroundingService.LmsAttributeGrounding>();
        for (ConfigLmsGroundingService.LmsAttributeGrounding g : grounding.attributes) {
            groundByDev.put(g.developerName, g);
        }

        Boolean assertedAtLeastOnePicklist = false;
        for (ConfigEngineController.AttributeOption opt : attrs.attributes) {
            if (!'Picklist'.equalsIgnoreCase(opt.dataType)) {
                continue;
            }
            assertedAtLeastOnePicklist = true;

            ConfigLmsGroundingService.LmsAttributeGrounding g =
                groundByDev.get(opt.developerName);
            System.assertNotEquals(null, g,
                'getLmsGrounding is missing picklist attribute ' + opt.developerName);

            // Label set from getAttributes (what the LWC can display/pick).
            Set<String> catalogLabels = new Set<String>(
                opt.picklistValues != null ? opt.picklistValues : new List<String>());

            // Label set from getLmsGrounding (what the LWC can resolve to a 0v6 Id).
            Set<String> groundingLabels = new Set<String>();
            for (ConfigLmsGroundingService.PicklistValueId pvi : g.picklistValueIds) {
                groundingLabels.add(pvi.label);
            }

            System.assertEquals(catalogLabels, groundingLabels,
                'Label sets must be identical across services for ' + opt.developerName
                + ' — a mismatch means a pickable value has no resolvable Id (or vice versa)');
        }

        System.assert(assertedAtLeastOnePicklist,
            'Live line should expose at least one picklist to cross-check');
    }

    /**
     * ambiguousLabels contract: for the live line (whose picklists have unique labels)
     * every picklist attribute exposes a non-null, EMPTY ambiguousLabels list, and no
     * label appearing in the value list is reported ambiguous. We cannot easily inject a
     * duplicate-label picklist under SeeAllData, so this asserts the safe/common case and
     * the shape the LWC relies on (a Set is built from this list; null would break that).
     */
    @IsTest
    static void getLmsGrounding_ambiguousLabels_emptyForUniqueLabels() {
        Test.startTest();
        ConfigLmsGroundingService.LmsGroundingResult r =
            ConfigLmsGroundingService.getLmsGrounding(LIVE_ROOT_QLI_ID);
        Test.stopTest();

        for (ConfigLmsGroundingService.LmsAttributeGrounding g : r.attributes) {
            if (!'Picklist'.equalsIgnoreCase(g.dataType)) {
                continue;
            }
            System.assertNotEquals(null, g.ambiguousLabels,
                'ambiguousLabels must be non-null for picklist ' + g.developerName
                + ' (the LWC builds a Set from it)');
            System.assertEquals(0, g.ambiguousLabels.size(),
                'Live picklist ' + g.developerName + ' is expected to have unique labels, '
                + 'so no label should be reported ambiguous: ' + g.ambiguousLabels);
        }
    }
}
