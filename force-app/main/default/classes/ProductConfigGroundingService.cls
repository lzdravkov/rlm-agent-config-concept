/**
 * ProductConfigGroundingService
 * -----------------------------
 * PRODUCT-based (pre-persist) grounding for the configChatPanel LWC, mirroring — with
 * ZERO drift — the two QLI-based reads the panel uses for a persisted line:
 *   ConfigEngineController.getAttributes   (the configurable-attribute catalog)
 *   ConfigLmsGroundingService.getLmsGrounding (the attributeId + picklist label->0v6-Id map)
 *
 * WHY THIS CLASS EXISTS
 * =====================
 * When a rep clicks "Configure" from the PRODUCT CATALOG (before saving the line), the RLM
 * Product Configurator hands the flow a TRANSIENT in-memory node reference
 * (`ref_<uuid>`) as the transactionLineId — NOT a persisted QuoteLineItem (`0QL…`). The
 * panel's QLI-keyed reads then fail:
 *   - getAttributes -> ProductAttributeService errors ("QuoteLineItem not found: ref_…")
 *   - getLmsGrounding SOQLs `QuoteLineItemAttribute WHERE QuoteLineItemId = :ref_` -> empty
 * so the panel cannot render the catalog or build a valueChanged payload, and the rep hits
 * the "not found" dead end.
 *
 * This class supplies the SAME two result shapes grounded off the PRODUCT
 * (`S01_DataManager.rootProductId`, already resolved in the flow) via its
 * ProductClassification, so the panel behaves identically pre- and post-persist. The apply
 * path is unchanged: it already publishes `key: ["<transactionLineId>"]` (the `ref_…` node
 * key the LMS `valueChanged` contract expects) — only the READ layer needed a product
 * source. See the approved plan and ARCHITECTURE.md §6.
 *
 * ZERO-DRIFT PROPERTY (the load-bearing correctness requirement)
 * ==============================================================
 * A proposal built pre-persist must ground to the SAME attribute developerNames and the
 * SAME picklist label->0v6-Id join as the persisted path, so behaviour is identical the
 * moment the line is saved. This is guaranteed by resolving off the SAME chain the
 * protected ProductAttributeService walks —
 *   Product2.BasedOnId (ProductClassification) -> ProductClassificationAttr
 *   -> AttributeDefinition -> AttributePicklistValue
 * — and by building every picklist label with the IDENTICAL expression
 *   AttributePicklistValue.Name ?? AttributePicklistValue.Code
 * (see ConfigLmsGroundingService line ~176; do NOT switch this to `Value`). Validated
 * against the live FESBA classification: getAttributesForProduct(product) reproduces the
 * exact label sets AND ordering that getAttributes(savedLine) emits (see the SeeAllData
 * cross-check in ProductConfigGroundingServiceTest).
 *
 * SCOPE / EXCLUSIONS / OVERRIDES
 * ==============================
 *   - The discoverable-attribute filter mirrors the engine: Status='Active' AND
 *     IsReadOnly=false AND IsHidden=false (all fields live directly on
 *     ProductClassificationAttr — verified by describe).
 *   - Product/classification-scoped picklist exclusions are removed via
 *     AttrPicklistExcludedValue, whose AttributeId is polymorphic to
 *     [ProductClassificationAttr, ProductAttributeDefinition]; we scope by the UNION of
 *     this product's classification-attr Ids and its ProductAttributeDefinition Ids.
 *     (FESBA has zero exclusions today — the filter is correct-by-construction for other
 *     products.)
 *   - A product-scoped ProductAttributeDefinition OVERRIDE layer exists (e.g. FESBA's
 *     DutyRating). For FESBA the classification picklist already matches the authoritative
 *     output, so we do not special-case it. If a future product's product-scoped picklist
 *     diverges from its classification picklist, the authoritative fallback is the Connect
 *     API `/connect/cpq/products/{productId}` (documented in the plan as the escape hatch;
 *     it is a callout, returns a different label shape, and would reintroduce drift — hence
 *     SOQL is preferred while the classification path holds).
 *
 * SAFETY / TESTABILITY
 * ====================
 *   - SOQL-only, no DML -> @AuraEnabled(cacheable=true), same contract as the QLI reads.
 *   - Never throws to the wire: expected problems come back in errorMessage.
 *   - Returns the EXISTING DTO shapes (ConfigEngineController.AttributesResult /
 *     AttributeOption, and ConfigLmsGroundingService.LmsAttributeGrounding /
 *     PicklistValueId) so the LWC and _buildValueChangedItem need no new shape handling.
 *   - All SOQL is isolated behind the injectable CatalogReader seam (mirrors
 *     ConfigExtractionService.LlmGateway / AgentAdvisorService.AgentGateway) so branch
 *     logic (label mapping, Name??Code, exclusions, ambiguity) is unit-tested with
 *     synthetic rows and no live data.
 *   - `with sharing`: the running rep's record-level sharing is enforced on the read.
 *   - Does NOT modify or depend on the four protected invocable services.
 */
public with sharing class ProductConfigGroundingService {

    private static final String DT_PICKLIST = 'Picklist';

    // =========================================================================
    // CATALOG READER SEAM
    // =========================================================================
    // All SOQL lives behind this injectable seam so tests can inject a fully controlled
    // ProductCatalog (synthetic rows) without SeeAllData. Production uses RealCatalogReader,
    // which runs the validated queries.
    public interface CatalogReader {
        /**
         * @param productId the root configurable Product2 Id (may be malformed/unknown)
         * @return a ProductCatalog; basedOnId == null means "not configurable / unknown"
         */
        ProductCatalog read(String productId);
    }

    // --- Internal raw carriers (NOT @AuraEnabled — never cross the wire) ------

    /** Raw grounding data for one product, straight off the catalog (pre-shaping). */
    public class ProductCatalog {
        public String productName;
        public Id basedOnId;                                 // ProductClassification; null => not configurable
        public List<ClassAttr> attributes = new List<ClassAttr>();
        public List<PickValue> picklistValues = new List<PickValue>(); // raw, across all referenced picklists
        public Set<Id> excludedValueIds = new Set<Id>();     // AttributePicklistValueIds excluded for this product
    }

    /** One configurable classification attribute (already filtered to discoverable). */
    public class ClassAttr {
        public String developerName;      // catalog key the LWC maps by
        public String name;               // human label (AttributeDefinition.Name)
        public String dataType;           // Picklist | Number | Checkbox | ...
        public Boolean isRequired;        // from ProductClassificationAttr
        public Boolean isPriceImpacting;  // from ProductClassificationAttr
        public Id attributeId;            // AttributeDefinition Id (0tj…) — the LMS `attributeId`
        public Id picklistId;             // AttributePicklist Id (0v5…); null for non-picklist
    }

    /** One raw picklist value row (label is built by the service, not the reader). */
    public class PickValue {
        public Id valueId;      // AttributePicklistValue.Id (0v6…) — the LMS `value`
        public String name;     // AttributePicklistValue.Name
        public String code;     // AttributePicklistValue.Code
        public Id picklistId;   // owning AttributePicklist (0v5…)
    }

    /**
     * Real implementation: the validated SOQL chain. Kept thin (data-only), so the
     * interpretation logic in the public methods is what the deterministic (mock-seam)
     * tests exercise; this reader is covered by the SeeAllData cross-check test.
     */
    @TestVisible
    private class RealCatalogReader implements CatalogReader {
        public ProductCatalog read(String productId) {
            ProductCatalog cat = new ProductCatalog();

            // 1. Product identity + classification. A malformed Id throws QueryException,
            //    which the caller catches and surfaces in errorMessage.
            List<Product2> ps = [
                SELECT Id, Name, BasedOnId FROM Product2 WHERE Id = :productId LIMIT 1
            ];
            if (ps.isEmpty()) {
                return cat; // unknown product -> basedOnId null -> treated as not configurable
            }
            cat.productName = ps[0].Name;
            cat.basedOnId = ps[0].BasedOnId;
            if (cat.basedOnId == null) {
                return cat; // not a configurable (classification-based) product
            }

            // 2. Discoverable classification attributes (mirror the engine's filter).
            Set<Id> picklistIds = new Set<Id>();
            Set<Id> scopeIds = new Set<Id>(); // for the polymorphic exclusion scope
            for (ProductClassificationAttr a : [
                SELECT Id, AttributeDefinitionId,
                       AttributeDefinition.DeveloperName, AttributeDefinition.Name,
                       AttributeDefinition.DataType, AttributeDefinition.PicklistId,
                       IsRequired, IsPriceImpacting
                FROM   ProductClassificationAttr
                WHERE  ProductClassificationId = :cat.basedOnId
                  AND  Status = 'Active' AND IsReadOnly = false AND IsHidden = false
            ]) {
                scopeIds.add(a.Id);
                ClassAttr ca = new ClassAttr();
                ca.developerName    = (a.AttributeDefinition != null) ? a.AttributeDefinition.DeveloperName : null;
                ca.name             = (a.AttributeDefinition != null) ? a.AttributeDefinition.Name : null;
                ca.dataType         = (a.AttributeDefinition != null) ? a.AttributeDefinition.DataType : null;
                ca.isRequired       = a.IsRequired;
                ca.isPriceImpacting = a.IsPriceImpacting;
                ca.attributeId      = a.AttributeDefinitionId;
                ca.picklistId       = (a.AttributeDefinition != null) ? a.AttributeDefinition.PicklistId : null;
                if (ca.picklistId != null) {
                    picklistIds.add(ca.picklistId);
                }
                cat.attributes.add(ca);
            }

            // 3. Union product-scoped assignment records into the exclusion scope
            //    (AttrPicklistExcludedValue.AttributeId can point at either object).
            for (ProductAttributeDefinition pad : [
                SELECT Id FROM ProductAttributeDefinition WHERE Product2Id = :productId
            ]) {
                scopeIds.add(pad.Id);
            }

            // 4. Legal picklist values (Name ?? Code applied by the service, not here).
            if (!picklistIds.isEmpty()) {
                for (AttributePicklistValue pv : [
                    SELECT Id, Name, Code, PicklistId
                    FROM   AttributePicklistValue
                    WHERE  PicklistId IN :picklistIds
                    ORDER BY Name ASC
                ]) {
                    PickValue v = new PickValue();
                    v.valueId    = pv.Id;
                    v.name       = pv.Name;
                    v.code       = pv.Code;
                    v.picklistId = pv.PicklistId;
                    cat.picklistValues.add(v);
                }
            }

            // 5. Product/classification-scoped exclusions.
            if (!scopeIds.isEmpty()) {
                for (AttrPicklistExcludedValue x : [
                    SELECT AttributePicklistValueId
                    FROM   AttrPicklistExcludedValue
                    WHERE  AttributeId IN :scopeIds
                ]) {
                    if (x.AttributePicklistValueId != null) {
                        cat.excludedValueIds.add(x.AttributePicklistValueId);
                    }
                }
            }
            return cat;
        }
    }

    /** Default is the real reader; @TestVisible so tests can inject a mock. */
    @TestVisible
    private static CatalogReader reader = new RealCatalogReader();

    // =========================================================================
    // LMS grounding result DTO
    // =========================================================================
    // Shape-identical (on the wire) to ConfigLmsGroundingService.LmsGroundingResult, but
    // declared here because that class's constructor is private (cannot be `new`ed from
    // another class). The element types (LmsAttributeGrounding / PicklistValueId) ARE
    // reused, so the two services stay structurally in lock-step by construction.
    public class LmsGroundingResult {
        @AuraEnabled public List<ConfigLmsGroundingService.LmsAttributeGrounding> attributes;
        @AuraEnabled public String errorMessage; // null on success
    }

    // =========================================================================
    // getAttributesForProduct — the configurable-attribute catalog for a product
    // =========================================================================
    /**
     * PRODUCT-based twin of ConfigEngineController.getAttributes. Returns the same
     * AttributesResult shape so the LWC's existing @wire handler consumes it unchanged.
     *
     * @param productId the root configurable Product2 Id (S01_DataManager.rootProductId)
     * @return AttributesResult — structured; never throws to the wire
     */
    @AuraEnabled(cacheable=true)
    public static ConfigEngineController.AttributesResult getAttributesForProduct(String productId) {
        ConfigEngineController.AttributesResult r = new ConfigEngineController.AttributesResult();
        r.attributes = new List<ConfigEngineController.AttributeOption>();
        r.hasConfigurableAttributes = false;

        if (String.isBlank(productId)) {
            r.errorMessage = 'productId is required';
            return r;
        }

        try {
            ProductCatalog cat = reader.read(productId);
            r.productName = cat.productName;

            // Not configurable (no classification) -> mirror getAttributes: empty list,
            // hasConfigurableAttributes=false, no error.
            if (cat.basedOnId == null) {
                return r;
            }

            // label list (Name ?? Code, minus exclusions, sorted) per picklist.
            Map<Id, List<String>> labelsByPicklist = buildLabelsByPicklist(cat);

            for (ClassAttr a : cat.attributes) {
                ConfigEngineController.AttributeOption o = new ConfigEngineController.AttributeOption();
                o.name             = a.name;
                o.developerName    = a.developerName;
                o.dataType         = a.dataType;
                o.isRequired       = a.isRequired;
                o.isPriceImpacting = a.isPriceImpacting;
                o.attributeId      = a.attributeId;
                // picklistValues stays null for non-picklist types (matches getAttributes).
                if (DT_PICKLIST.equalsIgnoreCase(a.dataType) && a.picklistId != null) {
                    List<String> ls = labelsByPicklist.get(a.picklistId);
                    o.picklistValues = (ls != null) ? ls : new List<String>();
                }
                r.attributes.add(o);
            }
            r.hasConfigurableAttributes = !r.attributes.isEmpty();

        } catch (Exception e) {
            // Return-with-error, not throw, to keep the @wire resilient.
            r.errorMessage = e.getMessage();
            r.attributes = new List<ConfigEngineController.AttributeOption>();
            r.hasConfigurableAttributes = false;
        }
        return r;
    }

    // =========================================================================
    // getLmsGroundingForProduct — attributeId + label->0v6-Id per attribute
    // =========================================================================
    /**
     * PRODUCT-based twin of ConfigLmsGroundingService.getLmsGrounding. Returns the same
     * per-attribute grounding shape (developerName, attributeId, dataType,
     * picklistValueIds, ambiguousLabels) so the LWC's _buildValueChangedItem needs no
     * change. Unlike the QLI-based read (which only covers attributes that already have
     * QuoteLineItemAttribute rows), this returns ALL legal classification attributes — the
     * correct superset pre-persist, where any attribute may still be set. Where an
     * attribute appears in both, the label->Id mapping is identical (same Name??Code
     * expression + same AttributePicklistValue rows), so there is no drift.
     *
     * @param productId the root configurable Product2 Id
     * @return LmsGroundingResult — structured; never throws to the wire
     */
    @AuraEnabled(cacheable=true)
    public static LmsGroundingResult getLmsGroundingForProduct(String productId) {
        LmsGroundingResult r = new LmsGroundingResult();
        r.attributes = new List<ConfigLmsGroundingService.LmsAttributeGrounding>();

        if (String.isBlank(productId)) {
            r.errorMessage = 'productId is required';
            return r;
        }

        try {
            ProductCatalog cat = reader.read(productId);
            if (cat.basedOnId == null) {
                return r; // not configurable -> empty grounding (no error)
            }

            Map<Id, List<ConfigLmsGroundingService.PicklistValueId>> valuesByPicklist =
                buildPicklistValueIds(cat);

            for (ClassAttr a : cat.attributes) {
                ConfigLmsGroundingService.LmsAttributeGrounding g =
                    new ConfigLmsGroundingService.LmsAttributeGrounding();
                g.developerName = a.developerName;
                g.attributeId   = a.attributeId;
                g.dataType      = a.dataType;

                if (DT_PICKLIST.equalsIgnoreCase(a.dataType) && a.picklistId != null) {
                    List<ConfigLmsGroundingService.PicklistValueId> vals =
                        valuesByPicklist.get(a.picklistId);
                    g.picklistValueIds = (vals != null)
                        ? vals
                        : new List<ConfigLmsGroundingService.PicklistValueId>();
                    g.ambiguousLabels = detectAmbiguousLabels(g.picklistValueIds);
                }
                // non-picklist: picklistValueIds / ambiguousLabels stay null (matches the
                // QLI-based shape) — number/text/checkbox attrs publish their raw value.
                r.attributes.add(g);
            }

        } catch (Exception e) {
            r.errorMessage = e.getMessage();
            r.attributes = new List<ConfigLmsGroundingService.LmsAttributeGrounding>();
        }
        return r;
    }

    // =========================================================================
    // Shared helpers (pure; operate on the raw ProductCatalog)
    // =========================================================================

    /** The canonical picklist label expression — MUST match ProductAttributeService. */
    @TestVisible
    private static String labelOf(String name, String code) {
        return String.isNotBlank(name) ? name : code;
    }

    /**
     * Groups legal picklist LABELS (Name ?? Code) by their PicklistId, dropping excluded
     * values. Values arrive from the reader already ordered by Name ASC; we preserve that
     * order (matches ConfigLmsGroundingService and the engine's emitted ordering).
     */
    @TestVisible
    private static Map<Id, List<String>> buildLabelsByPicklist(ProductCatalog cat) {
        Map<Id, List<String>> byPicklist = new Map<Id, List<String>>();
        for (PickValue pv : cat.picklistValues) {
            if (cat.excludedValueIds.contains(pv.valueId)) {
                continue; // excluded for this product/classification
            }
            if (!byPicklist.containsKey(pv.picklistId)) {
                byPicklist.put(pv.picklistId, new List<String>());
            }
            byPicklist.get(pv.picklistId).add(labelOf(pv.name, pv.code));
        }
        return byPicklist;
    }

    /**
     * Groups label->0v6-Id entries by PicklistId, dropping excluded values. Same ordering
     * rationale as buildLabelsByPicklist.
     */
    @TestVisible
    private static Map<Id, List<ConfigLmsGroundingService.PicklistValueId>> buildPicklistValueIds(
            ProductCatalog cat) {
        Map<Id, List<ConfigLmsGroundingService.PicklistValueId>> byPicklist =
            new Map<Id, List<ConfigLmsGroundingService.PicklistValueId>>();
        for (PickValue pv : cat.picklistValues) {
            if (cat.excludedValueIds.contains(pv.valueId)) {
                continue;
            }
            ConfigLmsGroundingService.PicklistValueId pvi =
                new ConfigLmsGroundingService.PicklistValueId();
            pvi.label   = labelOf(pv.name, pv.code);
            pvi.valueId = pv.valueId;
            if (!byPicklist.containsKey(pv.picklistId)) {
                byPicklist.put(pv.picklistId, new List<ConfigLmsGroundingService.PicklistValueId>());
            }
            byPicklist.get(pv.picklistId).add(pvi);
        }
        return byPicklist;
    }

    /**
     * Returns the labels that map to MORE THAN ONE AttributePicklistValue Id under one
     * picklist (so they cannot be resolved to a single 0v6 Id). Mirrors the guard in
     * ConfigLmsGroundingService (~lines 199-211): the LWC must refuse to publish a
     * selection whose chosen label is ambiguous rather than send a silently-wrong Id.
     * Returns [] when all labels are unique.
     */
    @TestVisible
    private static List<String> detectAmbiguousLabels(
            List<ConfigLmsGroundingService.PicklistValueId> values) {
        Map<String, Integer> countByLabel = new Map<String, Integer>();
        for (ConfigLmsGroundingService.PicklistValueId pvi : values) {
            Integer c = countByLabel.get(pvi.label);
            countByLabel.put(pvi.label, (c == null ? 0 : c) + 1);
        }
        List<String> ambiguous = new List<String>();
        for (String lbl : countByLabel.keySet()) {
            if (countByLabel.get(lbl) > 1) {
                ambiguous.add(lbl);
            }
        }
        return ambiguous;
    }
}
