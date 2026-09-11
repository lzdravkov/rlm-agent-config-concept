/**
 * ConfigLmsGroundingService
 * -------------------------
 * Read-only @AuraEnabled grounding for the LMS ("publish valueChanged into the
 * managed Data Manager") apply path of the configChatPanel LWC.
 *
 * WHY THIS CLASS EXISTS
 * =====================
 * The embedded chat panel applies a rep's configuration by PUBLISHING on the
 * platform Lightning Message Service channel
 *   lightning__productConfigurator_notification
 * with the exact payload the managed RLM configurator itself emits when a user
 * edits an attribute in its native panel:
 *
 *   { action: "valueChanged",
 *     data: [{ key: ["<quoteLineItemId>"],
 *              field: "AttributeField",
 *              attributeId: "<0tj… AttributeDefinition Id>",
 *              value: "<0v6… AttributePicklistValue Id | raw number | text>" }] }
 *
 * Two facts about that payload were confirmed by capturing a LIVE native emission:
 *   1. `attributeId` is the AttributeDefinition Id (0tj prefix).
 *   2. For a PICKLIST, `value` is the AttributePicklistValue **Id** (0v6 prefix) —
 *      NOT the display label. (For Number/Text it is the raw magnitude/string.)
 *
 * The existing grounding the LWC already has (ConfigEngineController.getAttributes)
 * exposes `attributeId` but exposes picklist values only as LABEL STRINGS — it has
 * no way to translate a chosen picklist label into the 0v6 Id the Data Manager
 * expects. This class fills exactly that gap, and nothing more.
 *
 * WHAT IT RETURNS
 * ===============
 * Per configurable attribute ON THE LINE: its developerName, its AttributeDefinition
 * Id (0tj), its dataType, and — for picklists — a label→valueId list mapping each
 * legal picklist LABEL to its AttributePicklistValue Id (0v6).
 *
 * LABEL-KEY CONSISTENCY (the correctness property)
 * ================================================
 * The LWC's picklist selection value is canonicalized upstream against the label
 * strings emitted by ProductAttributeService, which builds each label as
 *   AttributePicklistValue.Name ?? AttributePicklistValue.Code
 * (see ProductAttributeService.fetchAttributeOptions). To guarantee the LWC's chosen
 * label joins to the correct Id with ZERO drift, this class keys its label→Id map on
 * the SAME expression (Name ?? Code). Do not switch this to `Value`: the two services
 * would then key on different strings and the join could silently miss.
 *
 * SCOPE / SAFETY
 * ==============
 *   - SOQL-only, no DML → @AuraEnabled(cacheable=true), same contract as getAttributes.
 *   - Reads the line's OWN QuoteLineItemAttribute rows (line-precise), so it reflects
 *     exactly the attributes the native panel is showing for this line.
 *   - Never throws to the wire: expected problems come back in errorMessage.
 *   - Does NOT modify or depend on the four protected invocable services, and adds no
 *     engine/business logic — it is a pure read that mirrors their resolution shape.
 *   - `with sharing`: the running rep's record-level sharing is enforced on the read.
 */
public with sharing class ConfigLmsGroundingService {

    private static final String DT_PICKLIST = 'Picklist';

    // =========================================================================
    // DTOs — every field the LWC reads must be @AuraEnabled
    // =========================================================================

    /** One legal picklist option: its display label and its AttributePicklistValue Id. */
    public class PicklistValueId {
        @AuraEnabled public String label;   // Name ?? Code — matches ProductAttributeService
        @AuraEnabled public String valueId; // AttributePicklistValue.Id (0v6…) — the LMS `value`
    }

    /** LMS-publish grounding for one configurable attribute on the line. */
    public class LmsAttributeGrounding {
        @AuraEnabled public String developerName;                // catalog key the LWC maps by
        @AuraEnabled public String attributeId;                  // AttributeDefinition Id (0tj…) — the LMS `attributeId`
        @AuraEnabled public String dataType;                     // Picklist | Number | Checkbox | ...
        @AuraEnabled public List<PicklistValueId> picklistValueIds; // null for non-picklist
        // Labels (Name ?? Code) that appear on MORE THAN ONE AttributePicklistValue for
        // this attribute. Such a label cannot be resolved to a single 0v6 Id without
        // guessing, so the LWC must refuse to publish a selection whose chosen value is
        // one of these — silently picking the "last one wins" would send a wrong value.
        // null/empty for non-picklist attributes and for picklists with all-unique labels.
        @AuraEnabled public List<String> ambiguousLabels;
    }

    /** Full result of a getLmsGrounding call. */
    public class LmsGroundingResult {
        @AuraEnabled public List<LmsAttributeGrounding> attributes; // never null; [] if none
        @AuraEnabled public String errorMessage;                    // null on success

        LmsGroundingResult() {
            this.attributes = new List<LmsAttributeGrounding>();
        }
    }

    // =========================================================================
    // getLmsGrounding — label→0v6-Id + attributeId per attribute on the line
    // =========================================================================
    /**
     * Builds the per-attribute grounding the LWC needs to translate a reviewed
     * configuration into `valueChanged` LMS payloads.
     *
     * Resolution (2 SOQL, no DML):
     *   1. QuoteLineItemAttribute for the line → developerName, AttributeDefinitionId,
     *      DataType, PicklistId (line-precise; reflects the native panel's attributes).
     *   2. AttributePicklistValue for all referenced PicklistIds → label (Name ?? Code)
     *      → Id (0v6) map, grouped back onto each picklist attribute.
     *
     * @param quoteLineItemId  the root configurable QLI being configured
     * @return LmsGroundingResult — structured result; never throws to the wire
     */
    @AuraEnabled(cacheable=true)
    public static LmsGroundingResult getLmsGrounding(String quoteLineItemId) {
        LmsGroundingResult r = new LmsGroundingResult();

        if (String.isBlank(quoteLineItemId)) {
            r.errorMessage = 'quoteLineItemId is required';
            return r;
        }

        try {
            // --- 1. The line's own attribute rows (developerName + def type + picklist) ---
            List<QuoteLineItemAttribute> qlias = [
                SELECT AttributeDefinitionId,
                       AttributeDefinition.DeveloperName,
                       AttributeDefinition.DataType,
                       AttributeDefinition.PicklistId
                FROM   QuoteLineItemAttribute
                WHERE  QuoteLineItemId = :quoteLineItemId
            ];

            // Collect the PicklistIds we must resolve, and stage one grounding entry
            // per attribute keyed by developerName (dedupe defensively on devName).
            Set<Id> picklistIds = new Set<Id>();
            Map<String, LmsAttributeGrounding> byDev =
                new Map<String, LmsAttributeGrounding>();
            // devName -> the PicklistId whose values populate its map (picklist rows only).
            Map<String, Id> picklistIdByDev = new Map<String, Id>();

            for (QuoteLineItemAttribute qlia : qlias) {
                String devName = (qlia.AttributeDefinition != null)
                    ? qlia.AttributeDefinition.DeveloperName : null;
                if (String.isBlank(devName) || byDev.containsKey(devName)) {
                    continue;
                }

                LmsAttributeGrounding g = new LmsAttributeGrounding();
                g.developerName = devName;
                g.attributeId   = qlia.AttributeDefinitionId;
                g.dataType      = (qlia.AttributeDefinition != null)
                    ? qlia.AttributeDefinition.DataType : null;

                if (DT_PICKLIST.equalsIgnoreCase(g.dataType)
                        && qlia.AttributeDefinition.PicklistId != null) {
                    g.picklistValueIds = new List<PicklistValueId>();
                    picklistIds.add(qlia.AttributeDefinition.PicklistId);
                    picklistIdByDev.put(devName, qlia.AttributeDefinition.PicklistId);
                }

                byDev.put(devName, g);
            }

            // --- 2. Resolve label (Name ?? Code) → 0v6 Id for every referenced picklist ---
            //     Grouped by PicklistId so we can attach values to each picklist attribute.
            Map<Id, List<PicklistValueId>> valuesByPicklist =
                new Map<Id, List<PicklistValueId>>();
            if (!picklistIds.isEmpty()) {
                for (AttributePicklistValue pv : [
                    SELECT Id, Name, Code, PicklistId
                    FROM   AttributePicklistValue
                    WHERE  PicklistId IN :picklistIds
                    ORDER BY Name ASC
                ]) {
                    PicklistValueId pvi = new PicklistValueId();
                    // Match ProductAttributeService's label expression EXACTLY (Name ?? Code)
                    // so the LWC's canonicalized selection label joins to this Id.
                    pvi.label   = String.isNotBlank(pv.Name) ? pv.Name : pv.Code;
                    pvi.valueId = pv.Id;

                    if (!valuesByPicklist.containsKey(pv.PicklistId)) {
                        valuesByPicklist.put(pv.PicklistId, new List<PicklistValueId>());
                    }
                    valuesByPicklist.get(pv.PicklistId).add(pvi);
                }
            }

            // --- 3. Attach resolved values onto their picklist attributes -------------
            //     While attaching, detect DUPLICATE labels: if two AttributePicklistValues
            //     under the same picklist share a label (Name ?? Code), that label maps to
            //     two different 0v6 Ids and cannot be resolved unambiguously. We surface
            //     those labels so the LWC can block a selection on them rather than send a
            //     silently-wrong Id (a plain Map<label,Id> would just keep the last one).
            for (String devName : picklistIdByDev.keySet()) {
                Id pid = picklistIdByDev.get(devName);
                List<PicklistValueId> vals = valuesByPicklist.get(pid);
                LmsAttributeGrounding g = byDev.get(devName);
                g.picklistValueIds =
                    (vals != null) ? vals : new List<PicklistValueId>();

                // Count label occurrences; any label seen >1 time is ambiguous.
                Map<String, Integer> countByLabel = new Map<String, Integer>();
                for (PicklistValueId pvi : g.picklistValueIds) {
                    Integer c = countByLabel.get(pvi.label);
                    countByLabel.put(pvi.label, (c == null ? 0 : c) + 1);
                }
                List<String> ambiguous = new List<String>();
                for (String lbl : countByLabel.keySet()) {
                    if (countByLabel.get(lbl) > 1) {
                        ambiguous.add(lbl);
                    }
                }
                g.ambiguousLabels = ambiguous; // [] when all labels are unique
            }

            r.attributes = byDev.values();

        } catch (Exception e) {
            // Return-with-error, not throw, to keep the @wire resilient.
            r.errorMessage = e.getMessage();
            r.attributes = new List<LmsAttributeGrounding>();
        }
        return r;
    }
}
