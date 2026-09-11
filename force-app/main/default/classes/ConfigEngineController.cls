/**
 * ConfigEngineController
 * ----------------------
 * Thin @AuraEnabled orchestration layer that lets a Lightning Web Component (and,
 * by extension, a Flow screen embedded in the Agentforce product-configurator flow)
 * drive the EXISTING Revenue Cloud attribute-configuration engine.
 *
 * DESIGN INTENT
 * =============
 * The four backing services (ProductAttributeService, ProductAttributeSaveService,
 * ProductAttributeReadService, QuoteLineItemLookupService) already implement all of
 * the business logic — attribute discovery, the two-step Place Sales Transaction
 * (PST) save/reprice, and the post-save readback. They are @InvocableMethods marked
 * `public static` and live in the SAME namespace as this controller, so we call them
 * DIRECTLY. We deliberately add ZERO new engine logic here; this class only:
 *   1. shapes the invocable Input/Output objects into @AuraEnabled DTOs the LWC can read,
 *   2. observes the price side-effect that PST commits (the SaveOutput carries no price), and
 *   3. diffs "what the rep asked for" vs "what was actually persisted" to surface the
 *      engine's documented silent corrections (e.g. DutyRating=DCC forcing requiredKW=1500).
 *
 * We do NOT modify the four services — they back a live NGA Agentforce agent.
 *
 * SECURITY: `with sharing` so the running rep's record-level sharing is enforced on
 * this controller's own SOQL. (The engine's internal SOQL/DML runs in system context
 * and is out of our control, so this controller's queries are the enforcement seam.)
 * Class-access permission is enforced only on this entry-point class; the four
 * downstream services need no separate Apex-class grant.
 */
public with sharing class ConfigEngineController {

    // =========================================================================
    // SAVE GATEWAY SEAM
    // =========================================================================
    // The save path ultimately runs the Place Sales Transaction API, which mutates
    // the DB and reprices. In a normal (SeeAllData=true) test the real PST DOES run
    // against the live quote — but to also cover the failure/exception branches
    // DETERMINISTICALLY (without relying on the engine actually rejecting something),
    // we route the save call through this injectable seam. Production uses the real
    // gateway, which simply forwards to ProductAttributeSaveService; tests can swap in
    // a mock that returns a canned SaveOutput or throws.
    public interface SaveGateway {
        List<ProductAttributeSaveService.SaveOutput> save(
            List<ProductAttributeSaveService.SaveInput> inputs);
    }

    /** Real implementation: forwards to the existing invocable engine, unchanged. */
    @TestVisible
    private class RealSaveGateway implements SaveGateway {
        public List<ProductAttributeSaveService.SaveOutput> save(
                List<ProductAttributeSaveService.SaveInput> inputs) {
            return ProductAttributeSaveService.saveAttributeSelections(inputs);
        }
    }

    /** Default is the real engine; @TestVisible so tests can inject a mock. */
    @TestVisible
    private static SaveGateway saveGateway = new RealSaveGateway();

    // =========================================================================
    // DTOs — every field the LWC reads must be @AuraEnabled
    // =========================================================================

    /** One parsed entry from ProductAttributeService.attributesJson. */
    public class AttributeOption {
        @AuraEnabled public String  name;             // human label (AttributeDefinition.Name)
        @AuraEnabled public String  developerName;    // key used when saving selections
        @AuraEnabled public String  dataType;         // Picklist | Number | Checkbox | ...
        @AuraEnabled public Boolean isRequired;
        @AuraEnabled public Boolean isPriceImpacting;
        @AuraEnabled public String  attributeId;
        @AuraEnabled public List<String> picklistValues; // null for non-Picklist types
    }

    /** Result of getAttributes: the configurable attribute catalog for one QLI. */
    public class AttributesResult {
        @AuraEnabled public String  productName;
        @AuraEnabled public Boolean hasConfigurableAttributes;
        @AuraEnabled public List<AttributeOption> attributes; // never null; [] if none
        @AuraEnabled public String  errorMessage;             // null on success
    }

    /** A point-in-time price snapshot of the QLI and its parent Quote. */
    public class PriceSnapshot {
        @AuraEnabled public Decimal listPrice;        // QLI.ListPrice
        @AuraEnabled public Decimal unitPrice;        // QLI.UnitPrice
        @AuraEnabled public Decimal lineTotal;        // QLI.TotalPrice  (the ROOT line)
        @AuraEnabled public Decimal quoteTotal;       // Quote.TotalPrice
        @AuraEnabled public Decimal quoteGrandTotal;  // Quote.GrandTotal (authoritative rollup)
    }

    /**
     * Price movement, after − before.
     * NOTE (the E8 trap): PST with ConfigurationExecutionEnum.SYSTEM re-evaluates the
     * BOM and reprices the CHILD lines; the rollup lands on Quote.GrandTotal, NOT
     * necessarily on the root QLI.TotalPrice. So quoteGrandTotalDelta is the
     * authoritative "did the price move" figure; lineTotalDelta is context only and
     * can legitimately be 0 while the grand total jumps.
     */
    public class PriceDelta {
        @AuraEnabled public Decimal lineTotalDelta;        // context only
        @AuraEnabled public Decimal quoteGrandTotalDelta;  // authoritative
    }

    /** One submitted attribute, reconciled against what the engine actually persisted. */
    public class DiffEntry {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  requested; // value the rep submitted
        @AuraEnabled public String  actual;    // value read back from the DB post-save
        @AuraEnabled public Boolean changed;   // true = engine silently corrected the request
    }

    /** Full result of an applyConfiguration call. */
    public class ApplyResult {
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public String  errorMessage;         // null on success
        @AuraEnabled public String  savedAttributesJson;  // passthrough from SaveOutput readback
        @AuraEnabled public PriceSnapshot priceBefore;
        @AuraEnabled public PriceSnapshot priceAfter;     // null when isSuccess=false
        @AuraEnabled public PriceDelta    priceDelta;     // null when isSuccess=false
        @AuraEnabled public List<DiffEntry> diffs;        // never null; [] on failure
    }

    /** Result of getSavedConfiguration: the currently persisted attribute values. */
    public class SavedConfigResult {
        @AuraEnabled public String configurationSummary;
        @AuraEnabled public String savedAttributesJson;
        @AuraEnabled public String errorMessage;
    }

    // =========================================================================
    // getAttributes — read the configurable attribute catalog for a QLI
    // =========================================================================
    /**
     * Delegates to ProductAttributeService (SOQL only, NO DML) → safe to cache with
     * Lightning Data Service. Returns errors in the DTO (never throws) so a @wire in
     * the LWC does not hard-fail.
     *
     * @param quoteLineItemId  the QuoteLineItem to inspect
     * @return AttributesResult with the parsed, structured attribute list
     */
    @AuraEnabled(cacheable=true)
    public static AttributesResult getAttributes(String quoteLineItemId) {
        AttributesResult r = new AttributesResult();
        r.attributes = new List<AttributeOption>();
        r.hasConfigurableAttributes = false;

        if (String.isBlank(quoteLineItemId)) {
            r.errorMessage = 'quoteLineItemId is required';
            return r;
        }

        try {
            ProductAttributeService.GetAttributeOptionsInput inp =
                new ProductAttributeService.GetAttributeOptionsInput();
            inp.quoteLineItemId = quoteLineItemId;

            // Single-element bulk call into the invocable service (no SOQL in a loop here).
            ProductAttributeService.GetAttributeOptionsOutput out =
                ProductAttributeService.getProductAttributeOptions(
                    new List<ProductAttributeService.GetAttributeOptionsInput>{ inp })[0];

            r.productName = out.productName;
            r.hasConfigurableAttributes = out.hasConfigurableAttributes == true;
            r.errorMessage = out.errorMessage;

            // The service already handles the null-BasedOnId case: it returns
            // hasConfigurableAttributes=false and attributesJson='[]', so an
            // unconfigurable product simply yields an empty attribute list here.
            if (String.isNotBlank(out.attributesJson)) {
                // JSON keys are 1:1 with AttributeOption field names, so a typed
                // deserialize maps cleanly (missing picklistValues → null).
                r.attributes = (List<AttributeOption>) JSON.deserialize(
                    out.attributesJson, List<AttributeOption>.class);
            }
        } catch (Exception e) {
            // Return-with-error, not throw, to keep @wire resilient.
            r.errorMessage = e.getMessage();
            r.attributes = new List<AttributeOption>();
        }
        return r;
    }

    // =========================================================================
    // applyConfiguration — save selections, reprice, observe result
    // =========================================================================
    /**
     * MUST be cacheable=false: this runs two synchronous PST graph executions (BOM
     * re-eval + full repricing) which perform DML. @AuraEnabled(cacheable=true) is
     * illegal on a method that does DML and would also serve stale state, so the LWC
     * calls this imperatively on user submit.
     *
     * Flow:
     *   1. guard blank inputs
     *   2. capture the pre-save price (1 SOQL; also validates the QLI + BasedOnId)
     *   3. delegate the save to the engine via the seam
     *   4. on failure: report the engine error, skip the post-save price query
     *   5. on success: capture post-save price (1 SOQL), compute deltas, build the diff
     *
     * The SaveOutput carries NO price (only isSuccess/isValid/savedAttributesJson/
     * validationErrorsJson/errorMessage), so we must observe the price side-effect
     * ourselves by re-querying the DB after PST commits — that is why steps 2 and 5 exist.
     *
     * @param quoteId                 parent Quote Id (required by the save engine)
     * @param quoteLineItemId         the line being configured
     * @param attributeSelectionsJson JSON object devName -> value
     */
    @AuraEnabled(cacheable=false)
    public static ApplyResult applyConfiguration(String quoteId,
                                                 String quoteLineItemId,
                                                 String attributeSelectionsJson) {
        ApplyResult r = new ApplyResult();
        r.diffs = new List<DiffEntry>();

        // 1. Input guard — return-with-error (do not throw) for expected bad input.
        if (String.isBlank(quoteId)
                || String.isBlank(quoteLineItemId)
                || String.isBlank(attributeSelectionsJson)) {
            r.isSuccess = false;
            r.errorMessage = 'quoteId, quoteLineItemId, and attributeSelectionsJson are all required';
            return r;
        }

        try {
            // 2. Pre-save price snapshot. This query ALSO resolves Product2.BasedOnId
            //    so we can refuse to reprice a non-configurable line (E4 guard).
            PriceQuery pq = queryPrice(quoteLineItemId);
            if (!pq.found) {
                r.isSuccess = false;
                r.errorMessage = 'QuoteLineItem not found: ' + quoteLineItemId;
                return r;
            }
            if (pq.basedOnId == null) {
                // No ProductClassification → nothing to configure/reprice. Refuse early
                // rather than firing a pointless (and possibly harmful) PST.
                r.isSuccess = false;
                r.errorMessage = 'Product is not configurable (no product classification): '
                    + quoteLineItemId;
                return r;
            }
            r.priceBefore = pq.snapshot;

            // 3. Delegate the save to the engine (two-step PST) via the seam.
            ProductAttributeSaveService.SaveInput inp =
                new ProductAttributeSaveService.SaveInput();
            inp.quoteId = quoteId;
            inp.quoteLineItemId = quoteLineItemId;
            inp.attributeSelectionsJson = attributeSelectionsJson;

            ProductAttributeSaveService.SaveOutput so = saveGateway.save(
                new List<ProductAttributeSaveService.SaveInput>{ inp })[0];

            // 4. Save failure: report the engine's error and STOP. Nothing changed, so
            //    we skip the post-save price query to conserve governor limits.
            if (so == null || so.isSuccess != true) {
                r.isSuccess = false;
                r.errorMessage = (so != null) ? so.errorMessage : 'No response from save engine';
                r.savedAttributesJson = (so != null) ? so.savedAttributesJson : null;
                r.priceAfter = null;
                r.priceDelta = null;
                return r; // diffs already [] from initialization
            }

            // 5. Success path.
            r.isSuccess = true;
            r.savedAttributesJson = so.savedAttributesJson;

            // 5a. Post-save price snapshot (second and final SOQL for pricing).
            PriceQuery afterPq = queryPrice(quoteLineItemId);
            r.priceAfter = afterPq.snapshot;

            // 5b. Deltas. quoteGrandTotalDelta is authoritative (see PriceDelta note);
            //     lineTotalDelta is context only and may legitimately be 0.
            PriceDelta d = new PriceDelta();
            d.lineTotalDelta = nullSafeMinus(
                r.priceAfter.lineTotal, r.priceBefore.lineTotal);
            d.quoteGrandTotalDelta = nullSafeMinus(
                r.priceAfter.quoteGrandTotal, r.priceBefore.quoteGrandTotal);
            r.priceDelta = d;

            // 5c. Validation diff — reuse the engine's post-save readback (0 extra SOQL).
            r.diffs = buildDiffs(attributeSelectionsJson, so.savedAttributesJson);

        } catch (Exception e) {
            // Any unexpected failure (incl. PST platform/limit exceptions surfacing here)
            // is reported in the DTO so the LWC can render it, rather than throwing.
            r.isSuccess = false;
            r.errorMessage = e.getMessage();
            r.priceAfter = null;
            r.priceDelta = null;
            r.diffs = new List<DiffEntry>();
        }
        return r;
    }

    // =========================================================================
    // getSavedConfiguration — read the currently persisted attribute values
    // =========================================================================
    /**
     * Delegates to ProductAttributeReadService (SOQL only, NO DML) → cacheable. The
     * LWC calls refreshApex() on this after an applyConfiguration to re-pull state.
     */
    @AuraEnabled(cacheable=true)
    public static SavedConfigResult getSavedConfiguration(String quoteLineItemId) {
        SavedConfigResult r = new SavedConfigResult();

        if (String.isBlank(quoteLineItemId)) {
            r.errorMessage = 'quoteLineItemId is required';
            return r;
        }

        try {
            ProductAttributeReadService.ReadInput inp =
                new ProductAttributeReadService.ReadInput();
            inp.quoteLineItemId = quoteLineItemId;

            ProductAttributeReadService.ReadOutput out =
                ProductAttributeReadService.getSavedAttributeValues(
                    new List<ProductAttributeReadService.ReadInput>{ inp })[0];

            r.configurationSummary = out.configurationSummary;
            r.savedAttributesJson  = out.savedAttributesJson;
            r.errorMessage         = out.errorMessage;
        } catch (Exception e) {
            r.errorMessage = e.getMessage();
        }
        return r;
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /** Internal carrier for the price query so we can also return found/basedOnId. */
    @TestVisible
    private class PriceQuery {
        Boolean found = false;
        Id basedOnId;               // Product2.BasedOnId (null => not configurable)
        PriceSnapshot snapshot = new PriceSnapshot();
    }

    /**
     * Captures the line + parent-Quote price in ONE selective SOQL by traversing the
     * Quote relationship (no separate Quote query). WHERE Id = :qliId is fully
     * selective. Also returns Product2.BasedOnId so the caller can guard a
     * non-configurable line without an extra query.
     */
    @TestVisible
    private static PriceQuery queryPrice(Id qliId) {
        PriceQuery pq = new PriceQuery();
        List<QuoteLineItem> rows = [
            SELECT ListPrice, UnitPrice, TotalPrice,
                   Product2.BasedOnId,
                   Quote.TotalPrice, Quote.GrandTotal
            FROM QuoteLineItem
            WHERE Id = :qliId
            LIMIT 1
        ];
        if (!rows.isEmpty()) {
            QuoteLineItem q = rows[0];
            pq.found = true;
            pq.basedOnId = (q.Product2 != null) ? q.Product2.BasedOnId : null;
            pq.snapshot.listPrice = q.ListPrice;
            pq.snapshot.unitPrice = q.UnitPrice;
            pq.snapshot.lineTotal = q.TotalPrice;
            pq.snapshot.quoteTotal      = (q.Quote != null) ? q.Quote.TotalPrice : null;
            pq.snapshot.quoteGrandTotal = (q.Quote != null) ? q.Quote.GrandTotal : null;
        }
        return pq;
    }

    /** after − before, tolerant of nulls (returns null if either operand is null). */
    @TestVisible
    private static Decimal nullSafeMinus(Decimal after, Decimal before) {
        if (after == null || before == null) return null;
        return after - before;
    }

    /**
     * Builds the requested-vs-persisted diff by comparing the submitted selections
     * against the engine's post-save DB readback (so.savedAttributesJson). Reusing
     * the readback costs 0 extra SOQL and is exactly scoped to the submitted
     * attributes — which is the diff set that matters for "did my request get
     * silently corrected" (e.g. DutyRating=DCC forcing requiredKW to 1500). All
     * comparison happens over in-memory maps (no SOQL/DML in the loop).
     */
    @TestVisible
    private static List<DiffEntry> buildDiffs(String requestedJson, String savedJson) {
        List<DiffEntry> diffs = new List<DiffEntry>();

        Map<String, Object> requested =
            (Map<String, Object>) JSON.deserializeUntyped(requestedJson);
        Map<String, Object> actual = String.isBlank(savedJson)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(savedJson);

        for (String devName : requested.keySet()) {
            DiffEntry e = new DiffEntry();
            e.developerName = devName;
            e.requested = toStr(requested.get(devName));
            e.actual    = toStr(actual.get(devName));
            e.changed   = !valuesEqual(e.requested, e.actual);
            diffs.add(e);
        }
        return diffs;
    }

    /** Null-safe String coercion of a deserialized JSON value. */
    private static String toStr(Object o) {
        return (o == null) ? null : String.valueOf(o);
    }

    /**
     * Equality that treats "1500" and "1500.000000" as equal (numeric compare when
     * both parse as Decimal) and otherwise does a trimmed, case-insensitive string
     * compare. This prevents spurious "changed" flags from formatting-only readback
     * differences. Two nulls are equal; one null is not.
     */
    @TestVisible
    private static Boolean valuesEqual(String a, String b) {
        if (a == null && b == null) return true;
        if (a == null || b == null) return false;

        Decimal da = tryDecimal(a);
        Decimal db = tryDecimal(b);
        if (da != null && db != null) {
            return da == db;
        }
        return a.trim().equalsIgnoreCase(b.trim());
    }

    /** Returns the Decimal value of s, or null if s is not numeric. */
    private static Decimal tryDecimal(String s) {
        try {
            return Decimal.valueOf(s.trim());
        } catch (Exception e) {
            return null;
        }
    }
}
