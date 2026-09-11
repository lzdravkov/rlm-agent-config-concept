/**
 * ConfigExtractionService
 * -----------------------
 * Grounded natural-language -> validated attribute-selection extraction for the RLM
 * conversational product-configuration panel.
 *
 * ROLE IN THE UX
 * ==============
 * A rep types a free-text requirement (e.g. "~1500 kW, data-center continuous duty,
 * low-voltage"). This service turns that text into a list of PROPOSED attribute
 * selections that the LWC renders as an editable review card. It applies NOTHING —
 * there is no DML here. The rep reviews/edits/rejects, and only an explicit Apply
 * (ConfigEngineController.applyConfiguration) ever persists+reprices.
 *
 * GROUNDING = the single source of truth
 * =======================================
 * The complete catalog of legal attribute developerNames and, for picklists, the
 * exact legal picklist values, comes from ONE call to
 * ConfigEngineController.getAttributes(quoteLineItemId). That catalog is used BOTH as:
 *   (a) the prompt seed  — we tell the LLM exactly which developerNames/values exist, and
 *   (b) the validation corpus — every value the LLM (or the fallback) returns is
 *       re-checked against the catalog before it can reach the review card.
 * The model is NEVER trusted to have obeyed the prompt: any attribute name not in the
 * catalog, or any picklist value not in that attribute's picklistValues, is dropped or
 * flagged. This makes it structurally impossible for the LLM to inject a fake attribute
 * or a fake picklist value.
 *
 * TWO EXTRACTION PATHS
 * ====================
 *   1. LLM path (primary): one ConnectApi.EinsteinLLM.generateMessages callout with a
 *      tight "return ONLY raw JSON" grounded prompt (~0.7-0.8s on this org). Defensive
 *      fence-strip + JSON parse + per-key validation.
 *   2. FALLBACK path (safety net): a deterministic keyword+regex mapper built FROM the
 *      same catalog. Used only when the LLM callout throws, returns blank, or produces
 *      unparseable text. Grounded by construction; surfaced as confidence='low'.
 *
 * ERROR CONTRACT (mirrors ConfigEngineController)
 * ===============================================
 * This method NEVER throws to the LWC's imperative call. Expected problems come back
 * in the DTO:
 *   - blank inputs / grounding error / non-configurable line  -> isSuccess=false + errorMessage
 *   - LLM callout failure / empty text / JSON parse failure   -> caught, auto-switch to
 *     FALLBACK, still isSuccess=true (the LLM failure is recorded as an unmappedNote)
 *   - only a catastrophic unexpected exception in the outer try sets isSuccess=false.
 *
 * GOVERNOR NOTE
 * =============
 * Exactly ONE generateMessages invocation per extraction (no looping). getAttributes is
 * SOQL-only + cacheable. The whole thing runs inside a single synchronous @AuraEnabled
 * action.
 *
 * SECURITY: `with sharing` so the running rep's record-level sharing is enforced on the
 * grounding read (delegated through ConfigEngineController).
 */
public with sharing class ConfigExtractionService {

    // The additionalConfig.applicationName value empirically proven to make
    // ConnectApi.EinsteinLLM.generateMessages succeed on this trial org.
    @TestVisible
    private static final String LLM_APP_NAME = 'PromptBuilderPreview';

    // Confidence labels emitted on ProposedField.
    private static final String CONF_HIGH = 'high';
    private static final String CONF_LOW  = 'low';

    // extractionMethod labels.
    private static final String METHOD_LLM      = 'LLM';
    private static final String METHOD_FALLBACK = 'FALLBACK';

    // intent labels (2026-07-19). The grounded LLM call now ALSO classifies whether the
    // message is an advice/recommendation QUESTION vs. a configuration DIRECTIVE, so the
    // panel can forward questions to the agent instead of greedily mapping picklist words
    // out of a question (see 06-open-questions-and-decisions.md, D11 follow-up).
    private static final String INTENT_ASK       = 'ASK';
    private static final String INTENT_CONFIGURE = 'CONFIGURE';

    // Known dataType strings (dataType is a bare String in the catalog, not an enum).
    private static final String DT_PICKLIST = 'Picklist';
    private static final String DT_NUMBER   = 'Number';
    private static final String DT_CHECKBOX = 'Checkbox';

    // =========================================================================
    // LLM GATEWAY SEAM
    // =========================================================================
    // The LLM callout is routed through this injectable seam so tests can supply
    // deterministic responses (clean JSON, fenced JSON, garbage, or a thrown
    // exception) WITHOUT depending on a live, non-deterministic Einstein callout.
    // Production uses RealLlmGateway, which performs the single ConnectApi call.
    public interface LlmGateway {
        /** @return the raw model text (generations[0].text), or throws on transport failure. */
        String generate(String prompt);
    }

    /** Real implementation: one ConnectApi.EinsteinLLM.generateMessages callout. */
    @TestVisible
    private class RealLlmGateway implements LlmGateway {
        public String generate(String prompt) {
            ConnectApi.EinsteinLlmAdditionalConfigInput cfg =
                new ConnectApi.EinsteinLlmAdditionalConfigInput();
            cfg.applicationName = LLM_APP_NAME;

            ConnectApi.EinsteinLlmGenerationsInput input =
                new ConnectApi.EinsteinLlmGenerationsInput();
            input.promptTextorId = prompt;
            input.additionalConfig = cfg;

            ConnectApi.EinsteinLlmGenerationsOutput output =
                ConnectApi.EinsteinLLM.generateMessages(input);

            if (output == null || output.generations == null || output.generations.isEmpty()) {
                return null; // caller treats null/blank as an LLM failure -> fallback
            }
            return output.generations[0].text;
        }
    }

    /** Default is the real gateway; @TestVisible so tests can inject a mock. */
    @TestVisible
    private static LlmGateway llmGateway = new RealLlmGateway();

    // =========================================================================
    // GROUNDING SEAM
    // =========================================================================
    // Production grounds off ConfigEngineController.getAttributes. That method is a
    // plain static, so to let tests exercise validation against a fully controlled
    // synthetic catalog (a real Picklist attribute with known values, a Number attr,
    // etc.) — and to simulate the grounding-error / non-configurable branches
    // deterministically — a test can set this override. When non-null it is used
    // verbatim instead of calling getAttributes. Production leaves it null.
    @TestVisible
    private static ConfigEngineController.AttributesResult groundingOverride = null;

    // =========================================================================
    // DTOs — every field the LWC reads must be @AuraEnabled
    // =========================================================================

    /** One proposed attribute selection for the editable review card. */
    public class ProposedField {
        @AuraEnabled public String  developerName;   // catalog key (used later in applyConfiguration)
        @AuraEnabled public String  label;           // human label (AttributeOption.name)
        @AuraEnabled public String  dataType;        // Picklist | Number | Checkbox | ...
        @AuraEnabled public Boolean isPicklist;      // convenience flag for the combobox
        @AuraEnabled public List<String> picklistValues; // passthrough for the combobox; null for non-picklist
        @AuraEnabled public String  proposedValue;   // validated/canonicalized value
        @AuraEnabled public Boolean isValid;         // false => value failed validation; LWC defaults row to excluded
        @AuraEnabled public Boolean isPriceImpacting;// hint which edits move price
        @AuraEnabled public String  confidence;      // 'high' (LLM/exact match) | 'low' (fallback)
        @AuraEnabled public String  note;            // per-field rationale
    }

    /** Full result of an extractConfiguration call. */
    public class ExtractionResult {
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public String  errorMessage;      // null on success
        @AuraEnabled public String  extractionMethod;  // 'LLM' | 'FALLBACK'
        // 'ASK' | 'CONFIGURE' (2026-07-19). The LLM's own classification of the message.
        // The LWC routes ASK straight to the Revenue Management agent (an advice question),
        // and CONFIGURE to the review/apply path. The keyword FALLBACK cannot reason about
        // intent, so it always reports CONFIGURE — its deterministic mapping is unchanged.
        @AuraEnabled public String  intent;
        @AuraEnabled public String  productName;       // echoed from getAttributes (review-card header)
        @AuraEnabled public List<ProposedField> proposedFields; // never null; [] if nothing mapped
        @AuraEnabled public List<String> unmappedNotes;         // dropped/invalid/low-confidence notes

        ExtractionResult() {
            this.proposedFields = new List<ProposedField>();
            this.unmappedNotes  = new List<String>();
        }
    }

    // =========================================================================
    // ENTRY POINT
    // =========================================================================
    /**
     * Extracts a validated, proposed attribute configuration from free text.
     *
     * cacheable MUST be false: the LLM callout is illegal on a cacheable method, and
     * the output is non-deterministic per free-text input. No DML is performed.
     *
     * @param requirementText  the rep's free-text requirement
     * @param quoteLineItemId  the root configurable QLI Id (grounding source)
     * @return ExtractionResult — always a structured result, never a thrown exception
     */
    @AuraEnabled(cacheable=false)
    public static ExtractionResult extractConfiguration(String requirementText,
                                                        String quoteLineItemId) {
        ExtractionResult r = new ExtractionResult();

        // --- 1. Input guards (return-with-error, do not throw) -----------------
        if (String.isBlank(requirementText)) {
            r.isSuccess = false;
            r.errorMessage = 'requirementText is required';
            return r;
        }
        if (String.isBlank(quoteLineItemId)) {
            r.isSuccess = false;
            r.errorMessage = 'quoteLineItemId is required';
            return r;
        }

        try {
            // --- 2. Grounding: one call into the existing controller ----------
            ConfigEngineController.AttributesResult catalog = (groundingOverride != null)
                ? groundingOverride
                : ConfigEngineController.getAttributes(quoteLineItemId);

            // Short-circuit: never call the LLM for a line we cannot ground.
            if (catalog == null) {
                r.isSuccess = false;
                r.errorMessage = 'Grounding failed: no attribute catalog returned';
                return r;
            }
            if (String.isNotBlank(catalog.errorMessage)) {
                r.isSuccess = false;
                r.errorMessage = catalog.errorMessage; // pass through getAttributes text
                return r;
            }
            r.productName = catalog.productName;

            List<ConfigEngineController.AttributeOption> attrs =
                (catalog.attributes != null)
                    ? catalog.attributes
                    : new List<ConfigEngineController.AttributeOption>();

            if (catalog.hasConfigurableAttributes != true || attrs.isEmpty()) {
                r.isSuccess = false;
                r.errorMessage = 'This line has no configurable attributes to extract into.';
                return r;
            }

            // Build the validation index: lowercased developerName -> canonical option.
            Map<String, ConfigEngineController.AttributeOption> byDevLower =
                new Map<String, ConfigEngineController.AttributeOption>();
            for (ConfigEngineController.AttributeOption a : attrs) {
                if (String.isNotBlank(a.developerName)) {
                    byDevLower.put(a.developerName.toLowerCase(), a);
                }
            }

            // --- 3. LLM path (with automatic FALLBACK on any failure) ---------
            Map<String, Object> rawExtraction = null;
            Boolean usedFallback = false;

            try {
                String prompt = buildGroundedPrompt(requirementText, attrs);
                String llmText = llmGateway.generate(prompt);

                if (String.isBlank(llmText)) {
                    throw new ExtractionException('LLM returned empty text');
                }
                String cleaned = stripFences(llmText);
                // JSON.deserializeUntyped throws on malformed JSON -> caught below.
                Object parsed = JSON.deserializeUntyped(cleaned);
                if (!(parsed instanceof Map<String, Object>)) {
                    throw new ExtractionException('LLM output was not a JSON object');
                }
                // Split the response into its intent + the devName->value field map,
                // tolerating BOTH the new {"intent":..,"fields":{..}} shape and a legacy
                // bare {devName:value} object (older prompts / partial model compliance).
                Map<String, Object> parsedMap = (Map<String, Object>) parsed;
                r.intent = readIntent(parsedMap);
                rawExtraction = readFields(parsedMap);
                r.extractionMethod = METHOD_LLM;
            } catch (Exception llmErr) {
                // Any LLM-side failure (callout exception, limit, blank, parse error) is
                // NON-fatal: record it and fall back to the deterministic mapper.
                usedFallback = true;
                r.extractionMethod = METHOD_FALLBACK;
                // The keyword fallback cannot reason about intent — it only pattern-matches
                // catalog words — so it always treats the message as a configuration
                // directive. (Advice questions that reach here degrade to the review path,
                // exactly as they did before this enhancement.)
                r.intent = INTENT_CONFIGURE;
                r.unmappedNotes.add(
                    'LLM extraction unavailable (' + llmErr.getMessage()
                    + '); used deterministic keyword fallback.');
                rawExtraction = fallbackExtract(requirementText, attrs);
            }

            // --- 4. Validate every extracted key against the catalog ----------
            // For an ASK we skip field validation entirely: the LWC forwards the message to
            // the agent and never renders a review card, so any greedily-mapped picklist
            // words in the question must NOT become proposed fields. proposedFields stays [].
            if (!INTENT_ASK.equalsIgnoreCase(r.intent)) {
                String confidence = usedFallback ? CONF_LOW : CONF_HIGH;
                validateAndBuild(rawExtraction, byDevLower, confidence, r);
            }

            r.isSuccess = true;
            return r;

        } catch (Exception e) {
            // Only a truly unexpected failure lands here. Report, do not throw.
            r.isSuccess = false;
            r.errorMessage = e.getMessage();
            return r;
        }
    }

    // =========================================================================
    // RESPONSE SHAPE READERS (tolerant of new + legacy JSON)
    // =========================================================================
    /**
     * Reads the classified intent from a parsed LLM response. Recognizes only the two
     * legal labels (case-insensitively); anything else — including a legacy response with
     * no "intent" key at all — defaults to CONFIGURE. Defaulting to CONFIGURE is the safe
     * choice: a misclassified directive still gets the (reversible, rep-reviewable) config
     * path, whereas defaulting to ASK would silently swallow a real configuration request.
     */
    @TestVisible
    private static String readIntent(Map<String, Object> parsed) {
        if (parsed == null) return INTENT_CONFIGURE;
        Object raw = parsed.get('intent');
        String val = (raw == null) ? '' : String.valueOf(raw).trim();
        return INTENT_ASK.equalsIgnoreCase(val) ? INTENT_ASK : INTENT_CONFIGURE;
    }

    /**
     * Extracts the devName->value field map from a parsed LLM response, tolerating BOTH
     * shapes so a prompt/model change never breaks extraction:
     *   - NEW:    {"intent":"CONFIGURE","fields":{"requiredKW":"1500", ...}}  -> the inner map
     *   - LEGACY: {"requiredKW":"1500", ...}                                   -> the object itself
     * When a "fields" key exists and is itself an object we use it; otherwise we treat the
     * whole object as the field map (minus the reserved "intent" key, so it can't be
     * mistaken for an attribute). Never returns null.
     */
    @TestVisible
    private static Map<String, Object> readFields(Map<String, Object> parsed) {
        if (parsed == null) return new Map<String, Object>();

        Object fieldsRaw = parsed.get('fields');
        if (fieldsRaw instanceof Map<String, Object>) {
            return (Map<String, Object>) fieldsRaw;
        }

        // Legacy / flat shape: the object itself is the field map. Strip the reserved
        // "intent" key so it is never validated as an attribute developerName.
        Map<String, Object> flat = new Map<String, Object>(parsed);
        flat.remove('intent');
        flat.remove('fields'); // present-but-not-an-object; not a real attribute
        return flat;
    }

    // =========================================================================
    // PROMPT CONSTRUCTION
    // =========================================================================
    /**
     * Builds ONE grounded prompt that does TWO jobs in a single callout (no extra round
     * trip): (1) CLASSIFY the message as a configuration directive vs. an advice question,
     * and (2) for a directive, map it to catalog attributes. Per attribute it embeds
     * developerName, human name, dataType, and (for Picklist) the exact legal values.
     *
     * Response contract: raw JSON {"intent":"ASK|CONFIGURE","fields":{devName:value,...}}.
     * The catalog is still re-validated afterwards regardless of what the model returns,
     * and readIntent/readFields tolerate a legacy flat {devName:value} object too.
     *
     * WHY intent lives in the extraction call (2026-07-19): extraction is greedy on
     * picklist words — an advice question like "what do you recommend for a data center"
     * still contains "data center", which the mapper would match to a DutyRating value and
     * (with auto-apply on) silently apply. A word-list heuristic in the LWC missed
     * phrasings like "how much load do I need for a large data center". Letting the same
     * grounded model that already reads the message decide directive-vs-question is far
     * more robust than enumerating question phrasings.
     */
    @TestVisible
    private static String buildGroundedPrompt(
            String requirementText,
            List<ConfigEngineController.AttributeOption> attrs) {

        List<String> lines = new List<String>();
        lines.add('You help a sales rep configure a product. Do TWO things and return ONE raw JSON object.');
        lines.add('');
        lines.add('1. CLASSIFY the message as exactly one intent:');
        lines.add('   - "CONFIGURE": the rep is stating requirements/values to set '
            + '(e.g. "~1500 kW, data-center continuous duty, low-voltage", "set duty rating to prime").');
        lines.add('   - "ASK": the rep is asking for advice, a recommendation, an opinion, an '
            + 'explanation, or any question expecting a spoken answer rather than a value to apply '
            + '(e.g. "what do you recommend for a data center and why", "how much load do I need for a '
            + 'large data center", "which duty rating suits a hospital?"). When the message merely '
            + 'MENTIONS a term that resembles an attribute value but is asking about it rather than '
            + 'selecting it, that is ASK, not CONFIGURE.');
        lines.add('');
        lines.add('2. If (and only if) the intent is CONFIGURE, map the requirement to attributes below.');
        lines.add('   Use ONLY these developerNames. For picklist attributes use ONLY the listed values verbatim.');
        lines.add('   Omit any attribute you cannot confidently determine. For an ASK, return "fields": {}.');
        lines.add('');
        lines.add('Return ONLY raw JSON of the form: {"intent":"CONFIGURE|ASK","fields":{"developerName":"value"}}.');
        lines.add('No markdown, no code fences, no commentary.');
        lines.add('');
        lines.add('Attributes:');
        for (ConfigEngineController.AttributeOption a : attrs) {
            String line = '- ' + a.developerName + ' (name: ' + a.name + ', type: ' + a.dataType + ')';
            if (DT_PICKLIST.equalsIgnoreCase(a.dataType)
                    && a.picklistValues != null && !a.picklistValues.isEmpty()) {
                line += ' allowed values: [' + String.join(a.picklistValues, ', ') + ']';
            }
            lines.add(line);
        }
        lines.add('');
        lines.add('Message: "' + requirementText + '"');
        return String.join(lines, '\n');
    }

    // =========================================================================
    // FENCE STRIP
    // =========================================================================
    /**
     * Defensive fence-strip run on EVERY LLM response. A tight prompt usually returns
     * clean JSON, but a verbose one can wrap it in ```json ... ``` fences. Cheap to run
     * and avoids intermittent parse failures.
     */
    @TestVisible
    private static String stripFences(String text) {
        if (text == null) return null;
        return text.trim()
            .replaceAll('(?s)^```[a-zA-Z]*\\s*', '')  // leading ```lang
            .replaceAll('(?s)\\s*```\\s*$', '')        // trailing ```
            .trim();
    }

    // =========================================================================
    // VALIDATION — the critical correctness property
    // =========================================================================
    /**
     * For each key/value the extractor returned:
     *   - drop it entirely (+ unmappedNote) if the key is not a real developerName;
     *   - otherwise validate by dataType:
     *       Picklist : case-insensitive match against picklistValues -> emit the CANONICAL
     *                  catalog string; if no match, emit the field flagged isValid=false
     *                  (+ unmappedNote) so the rep sees it rather than it vanishing;
     *       Number   : must parse as Decimal, else emit isValid=false (+ unmappedNote);
     *       Checkbox : coerce true/false, else emit isValid=false (+ unmappedNote);
     *       other    : treated as free-text, accepted as-is (isValid=true).
     * Because we only ever emit developerNames drawn from the catalog, a hallucinated
     * attribute can never reach the review card.
     */
    @TestVisible
    private static void validateAndBuild(
            Map<String, Object> extraction,
            Map<String, ConfigEngineController.AttributeOption> byDevLower,
            String confidence,
            ExtractionResult r) {

        if (extraction == null) return;

        for (String rawKey : extraction.keySet()) {
            if (String.isBlank(rawKey)) continue;
            String rawValue = toStr(extraction.get(rawKey));

            // ---- key validation: reject anything not in the catalog ----------
            ConfigEngineController.AttributeOption attr = byDevLower.get(rawKey.toLowerCase());
            if (attr == null) {
                r.unmappedNotes.add(
                    'ignored ' + rawKey + '=' + rawValue
                    + ' — not a real attribute on this product');
                continue;
            }

            if (String.isBlank(rawValue)) {
                r.unmappedNotes.add(
                    'ignored ' + attr.developerName + ' — no value provided by extractor');
                continue;
            }

            ProposedField pf = newProposedField(attr, confidence);
            String dt = (attr.dataType == null) ? '' : attr.dataType;

            if (DT_PICKLIST.equalsIgnoreCase(dt)) {
                String canonical = matchPicklist(rawValue, attr.picklistValues);
                if (canonical != null) {
                    pf.proposedValue = canonical;
                    pf.isValid = true;
                    pf.note = 'matched picklist value ' + canonical;
                } else {
                    pf.proposedValue = rawValue;
                    pf.isValid = false;
                    pf.note = 'value "' + rawValue + '" is not a legal picklist value';
                    r.unmappedNotes.add(
                        'dropped ' + attr.developerName + '=' + rawValue
                        + ' — not a legal picklist value');
                }
            } else if (DT_NUMBER.equalsIgnoreCase(dt)) {
                Decimal d = tryDecimal(rawValue);
                if (d != null) {
                    pf.proposedValue = String.valueOf(d);
                    pf.isValid = true;
                    pf.note = 'parsed numeric value ' + pf.proposedValue;
                } else {
                    pf.proposedValue = rawValue;
                    pf.isValid = false;
                    pf.note = 'value "' + rawValue + '" is not numeric';
                    r.unmappedNotes.add(
                        'dropped ' + attr.developerName + '=' + rawValue
                        + ' — not a numeric value');
                }
            } else if (DT_CHECKBOX.equalsIgnoreCase(dt)) {
                Boolean b = coerceBoolean(rawValue);
                if (b != null) {
                    pf.proposedValue = String.valueOf(b);
                    pf.isValid = true;
                    pf.note = 'coerced boolean value ' + pf.proposedValue;
                } else {
                    pf.proposedValue = rawValue;
                    pf.isValid = false;
                    pf.note = 'value "' + rawValue + '" is not a boolean';
                    r.unmappedNotes.add(
                        'dropped ' + attr.developerName + '=' + rawValue
                        + ' — not a boolean value');
                }
            } else {
                // Unknown dataType -> free-text, accept as-is.
                pf.proposedValue = rawValue;
                pf.isValid = true;
                pf.note = 'accepted free-text value';
            }

            r.proposedFields.add(pf);
        }
    }

    /** Builds a ProposedField pre-populated from the catalog metadata. */
    private static ProposedField newProposedField(
            ConfigEngineController.AttributeOption attr, String confidence) {
        ProposedField pf = new ProposedField();
        pf.developerName    = attr.developerName;
        pf.label            = attr.name;
        pf.dataType         = attr.dataType;
        pf.isPicklist       = DT_PICKLIST.equalsIgnoreCase(
                                  attr.dataType == null ? '' : attr.dataType);
        pf.picklistValues   = pf.isPicklist ? attr.picklistValues : null;
        pf.isPriceImpacting = attr.isPriceImpacting == true;
        pf.confidence       = confidence;
        return pf;
    }

    /**
     * Case-insensitive match of a proposed value against the legal picklist values.
     * @return the CANONICAL catalog string on match; null if no legal value matches.
     */
    @TestVisible
    private static String matchPicklist(String value, List<String> picklistValues) {
        if (value == null || picklistValues == null) return null;
        String needle = value.trim();
        for (String legal : picklistValues) {
            if (legal != null && legal.trim().equalsIgnoreCase(needle)) {
                return legal; // emit the canonical catalog spelling
            }
        }
        return null;
    }

    // =========================================================================
    // FALLBACK MAPPER — deterministic, grounded by construction
    // =========================================================================
    /**
     * Used only when the LLM path fails. Produces the SAME shape the LLM path would
     * (a devName -> value map) so it flows through the identical validation. Everything
     * it emits is drawn from the catalog, so it cannot inject a fake attribute/value.
     *
     * Strategy:
     *   - Number attributes: regex the requirement for a magnitude sitting next to a
     *     keyword hint derived from the attribute's name/developerName (e.g. a number
     *     immediately followed by "kw").
     *   - Picklist attributes: token-subset match each legal value against the
     *     requirement (camelCase/space split), so "data center continuous" resolves to
     *     the catalog value "DataCenterContinuous".
     * Weaker on paraphrase than the LLM, hence surfaced as confidence='low'.
     */
    @TestVisible
    private static Map<String, Object> fallbackExtract(
            String requirementText,
            List<ConfigEngineController.AttributeOption> attrs) {

        Map<String, Object> result = new Map<String, Object>();
        String lower = requirementText.toLowerCase();

        for (ConfigEngineController.AttributeOption a : attrs) {
            String dt = (a.dataType == null) ? '' : a.dataType;

            if (DT_NUMBER.equalsIgnoreCase(dt)) {
                Decimal num = extractNumberFor(lower, a);
                if (num != null) {
                    result.put(a.developerName, num);
                }
            } else if (DT_PICKLIST.equalsIgnoreCase(dt)
                    && a.picklistValues != null) {
                String matched = matchPicklistByTokens(lower, a.picklistValues);
                if (matched != null) {
                    result.put(a.developerName, matched);
                }
            }
            // Checkbox / free-text are not inferred by the keyword fallback.
        }
        return result;
    }

    /**
     * Finds a numeric magnitude in the requirement that sits next to a keyword hint for
     * this Number attribute. Hints are the lowercased word tokens of the attribute's
     * developerName (camelCase-split) and name (length >= 2). Matches "<number><hint>"
     * or "<hint><number>" with a small gap, tolerating '~', commas and decimals.
     */
    @TestVisible
    private static Decimal extractNumberFor(
            String lowerText, ConfigEngineController.AttributeOption a) {

        Set<String> hints = new Set<String>();
        for (String tok : tokenize(a.developerName)) {
            if (tok.length() >= 2) hints.add(tok);
        }
        for (String tok : tokenize(a.name)) {
            if (tok.length() >= 2) hints.add(tok);
        }
        if (hints.isEmpty()) return null;

        String hintAlt = String.join(new List<String>(hints), '|');
        // number (optionally ~-prefixed, with commas/decimals) directly before a hint,
        // e.g. "1500 kw" / "~1,500kw"
        Pattern pNumHint = Pattern.compile(
            '(?i)~?\\s*(\\d[\\d,\\.]*)\\s*(?:' + hintAlt + ')');
        Matcher m = pNumHint.matcher(lowerText);
        if (m.find()) {
            return tryDecimal(m.group(1).replace(',', ''));
        }
        // hint directly before a number, e.g. "kw 1500" / "requiredkw: 1500"
        Pattern pHintNum = Pattern.compile(
            '(?i)(?:' + hintAlt + ')[^\\d]{0,8}(\\d[\\d,\\.]*)');
        Matcher m2 = pHintNum.matcher(lowerText);
        if (m2.find()) {
            return tryDecimal(m2.group(1).replace(',', ''));
        }
        return null;
    }

    /**
     * Token-subset match: a legal picklist value matches the requirement if ALL of its
     * word tokens (camelCase/space split) appear in the requirement text. Returns the
     * canonical value with the MOST tokens matched (most specific wins), or null.
     */
    @TestVisible
    private static String matchPicklistByTokens(String lowerText, List<String> picklistValues) {
        String best = null;
        Integer bestTokenCount = 0;
        for (String legal : picklistValues) {
            if (String.isBlank(legal)) continue;
            List<String> toks = tokenize(legal);
            if (toks.isEmpty()) continue;
            Boolean allPresent = true;
            for (String tok : toks) {
                // Require token length >= 2 to avoid trivial single-letter false hits.
                if (tok.length() < 2 || !lowerText.contains(tok)) {
                    allPresent = false;
                    break;
                }
            }
            if (allPresent && toks.size() > bestTokenCount) {
                best = legal;
                bestTokenCount = toks.size();
            }
        }
        return best;
    }

    /**
     * Splits a developerName / label / picklist value into lowercased word tokens:
     * splits on non-alphanumerics AND camelCase boundaries.
     * "DataCenterContinuous" -> [data, center, continuous]; "requiredKW" -> [required, kw].
     */
    @TestVisible
    private static List<String> tokenize(String s) {
        List<String> out = new List<String>();
        if (String.isBlank(s)) return out;
        // Insert a space at lower->Upper and letter->digit / digit->letter boundaries.
        String spaced = s
            .replaceAll('([a-z])([A-Z])', '$1 $2')
            .replaceAll('([A-Za-z])([0-9])', '$1 $2')
            .replaceAll('([0-9])([A-Za-z])', '$1 $2');
        for (String part : spaced.toLowerCase().split('[^a-z0-9]+')) {
            if (String.isNotBlank(part)) out.add(part);
        }
        return out;
    }

    // =========================================================================
    // Small null-safe helpers
    // =========================================================================

    /** Null-safe String coercion of a deserialized JSON value. */
    private static String toStr(Object o) {
        return (o == null) ? null : String.valueOf(o);
    }

    /** Returns the Decimal value of s, or null if s is not numeric. */
    @TestVisible
    private static Decimal tryDecimal(String s) {
        if (String.isBlank(s)) return null;
        try {
            return Decimal.valueOf(s.trim());
        } catch (Exception e) {
            return null;
        }
    }

    /** Coerces common truthy/falsy strings to Boolean; null if not coercible. */
    @TestVisible
    private static Boolean coerceBoolean(String s) {
        if (String.isBlank(s)) return null;
        String v = s.trim().toLowerCase();
        if (v == 'true' || v == 'yes' || v == '1')  return true;
        if (v == 'false' || v == 'no' || v == '0')  return false;
        return null;
    }

    /** Internal marker exception used to route LLM-side failures into the fallback. */
    public class ExtractionException extends Exception {}
}
