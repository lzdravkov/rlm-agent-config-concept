/**
 * configChatPanel
 * ---------------
 * Embedded conversational configuration panel for the RLM product configurator.
 * This is the real replacement for the throwaway spikeConfigApply harness.
 *
 * UX FLOW (state machine — see `phase`)
 * =====================================
 *   1. LOADING_CATALOG  — @wire getAttributes + getSavedConfiguration resolve (spinner).
 *                          If getAttributes errors or the line is non-configurable we
 *                          render a disabled notice instead of the chat input.
 *   2. READY_INPUT      — rep types a free-text requirement and clicks Send.
 *   3. EXTRACTING       — imperative ConfigExtractionService.extractConfiguration
 *                          (grounded LLM extraction). No mutation. Progress indicator.
 *   4. REVIEW           — the validated proposal is rendered as an EDITABLE review card.
 *                          Nothing is applied yet. Invalid rows default to excluded.
 *   5. APPLYING         — on explicit Apply we PUBLISH each included selection as a
 *                          `valueChanged` message on the platform Lightning Message
 *                          Service channel lightning__productConfigurator_notification,
 *                          then one `updatePrices` message. This drives the managed RLM
 *                          Data Manager's OWN apply/reprice/re-render path — the same one
 *                          the native attribute panel uses — so the on-screen configurator
 *                          updates live. (Persistence is then the Data Manager's own Save.)
 *   6. RESULT           — render a lightweight confirmation of what was pushed to the
 *                          configurator, then return to READY_INPUT for a follow-up.
 *
 * WHY LMS `valueChanged` INSTEAD OF A DIRECT SAVE (2026-07-17 re-architecture)
 * ===========================================================================
 * The previous build called ConfigEngineController.applyConfiguration, which used the
 * Place Sales Transaction (PST) API as a SIDE CHANNEL to write + reprice the line in the
 * DB. That worked at the data layer but the managed configurator on screen holds its OWN
 * in-memory transaction graph and never noticed the external write — so the user saw a
 * stale "Prices don't reflect the latest selections" banner and had to click Update
 * Prices. Salesforce's guidance for third-party configurator UI is explicitly: do NOT
 * call the configurator/save APIs directly — route changes through `valueChanged` and let
 * the Data Manager own apply, reprice, re-render, and Save. This build follows that: we
 * publish INTO the Data Manager rather than writing around it.
 *
 * CONSEQUENCE — no synchronous price delta / diff. Publish is fire-and-forget: unlike the
 * PST call it returns no ApplyResult, and nothing is persisted until the user hits Save in
 * the native configurator. So the old price-movement + requested-vs-persisted result card
 * (which depended on PST's synchronous return + an immediate DB readback) is intentionally
 * replaced by a "pushed to the configurator" confirmation. The native panel — which now
 * reflects the change live — is the source of truth for the resulting values and price.
 *
 * VALUECHANGED PAYLOAD CONTRACT (confirmed from a live native emission)
 * ====================================================================
 *   { action: "valueChanged",
 *     data: [{ key: ["<quoteLineItemId>"], field: "AttributeField",
 *              attributeId: "<0tj…>", value: "<0v6… | number | text>" }] }
 * For a PICKLIST, `value` is the AttributePicklistValue Id (0v6), NOT the label — hence
 * the ConfigLmsGroundingService label->id lookup. For Number/Text, `value` is the raw value.
 *
 * GROUNDING: ConfigEngineController.getAttributes is the single source of truth for the
 * legal attribute developerNames and picklist values (used by the extraction service and
 * the review-card editors). ConfigLmsGroundingService additionally supplies the 0tj
 * attributeId and picklist label->0v6-Id map needed to build the `valueChanged` payload.
 *
 * Both ids (quoteId / quoteLineItemId) arrive from Flow variables — identical bindings to
 * spikeConfigApply so this drops into RenderDraw_Product_Configurator_Flow the same way.
 */
import { LightningElement, api, wire } from 'lwc';
import { publish, MessageContext } from 'lightning/messageService';
// Platform channel that is a COMMAND BUS INTO the managed RLM Data Manager. Publishing
// `valueChanged` here drives the SAME code path the native attribute panel uses when a
// user edits a field, so the on-screen configurator applies/reprices/re-renders natively.
import NotificationMessageChannel from '@salesforce/messageChannel/lightning__productConfigurator_notification';
import getAttributes from '@salesforce/apex/ConfigEngineController.getAttributes';
import getSavedConfiguration from '@salesforce/apex/ConfigEngineController.getSavedConfiguration';
// LMS-publish grounding: per attribute, its AttributeDefinition Id (0tj) and, for
// picklists, a label -> AttributePicklistValue Id (0v6) map — the exact `value` the
// Data Manager expects for a picklist `valueChanged`.
import getLmsGrounding from '@salesforce/apex/ConfigLmsGroundingService.getLmsGrounding';
import extractConfiguration from '@salesforce/apex/ConfigExtractionService.extractConfiguration';
// Guided-selling / Q&A bridge (2026-07-19). Forwards an INFORMATIONAL question to the real
// Revenue Management agent and returns its answer as text. Insight-only — it never applies a
// configuration (the LMS-publish path below remains the sole apply route). See
// AgentAdvisorService.cls and 06-open-questions-and-decisions.md (D8–D11).
import askAgent from '@salesforce/apex/AgentAdvisorService.askAgent';
// PST side-channel apply — REPLACED by the LMS `valueChanged` publish path below
// (2026-07-17). Kept as a commented reference so the previous behavior is easy to
// restore if the LMS path is ever reverted.
// import applyConfiguration from '@salesforce/apex/ConfigEngineController.applyConfiguration';

// Phase constants for the state machine.
const PHASE = {
    LOADING: 'LOADING_CATALOG',
    NON_CONFIG: 'NON_CONFIGURABLE',
    READY: 'READY_INPUT',
    EXTRACTING: 'EXTRACTING',
    // Guided-selling turn: the message was routed to the agent as a question and we're
    // awaiting its (slow, ~8–9s) answer. Distinct from EXTRACTING so the "thinking…"
    // label can say we're asking the assistant rather than mapping attributes.
    ASKING: 'ASKING',
    REVIEW: 'REVIEW',
    APPLYING: 'APPLYING',
    RESULT: 'RESULT'
};

export default class ConfigChatPanel extends LightningElement {
    // --- Flow-provided context (same names/bindings as spikeConfigApply) ---
    @api quoteId;
    @api quoteLineItemId;

    // Flow-set STARTING mode for auto-apply (see js-meta.xml). This only seeds the
    // in-panel toggle's initial value; the rep can flip it per session afterwards.
    //
    // Defaults to TRUE (2026-07-19, per user feedback): a clean, high-confidence proposal
    // is applied automatically without a manual click. Anything invalid, ambiguous, or from
    // the keyword fallback still degrades to the review card.
    //
    // NOTE — WHY A GETTER/SETTER, NOT A PLAIN @api FIELD: LWC forbids a public Boolean
    // property from defaulting to true (LWC1099 — an absent boolean attribute must read as
    // false). The documented workaround for a default-true Flow input is to expose the @api
    // via accessors over a private backing field. When the Flow leaves the property unset the
    // setter is never called, so the `true` default holds; when the Flow assigns it, the
    // assigned value wins.
    _autoApplyDefault = true;
    @api
    get autoApplyDefault() {
        return this._autoApplyDefault;
    }
    set autoApplyDefault(value) {
        this._autoApplyDefault = value;
    }

    // Flow-set flag that gates the "Sent to the configurator" confirmation card
    // (2026-07-19, per user feedback). The card is HIDDEN by default; it renders ONLY when a
    // Flow variable explicitly sets this to true. Auto-apply otherwise confirms purely via
    // the assistant chat line ("Sent N changes to the configurator…"), which reads cleaner in
    // the hands-free auto-apply flow. Set it true in the Flow to bring the explicit itemized
    // card back for a given screen. Plain @api Boolean (default false) is allowed here.
    @api showSentToConfigurator = false;

    // --- State machine ---
    phase = PHASE.LOADING;

    // --- Auto-apply mode (rep-controllable; seeded from autoApplyDefault) ---
    // When true, a CLEAN, high-confidence proposal is published to the configurator
    // automatically (no manual Apply click). "Clean" is strict — see
    // _proposalIsCleanForAutoApply: LLM-sourced, every row valid AND unambiguously
    // groundable. Anything less always degrades to the manual review card, so the
    // existing "never silently guess / never silently drop a value" guarantees hold.
    autoApply = false;

    // --- Grounding catalog (from @wire getAttributes) ---
    productName;                 // review-card / header label
    catalogAttributes = [];      // List<AttributeOption>
    catalogError;                // getAttributes.errorMessage (grounding failure)
    hasConfigurableAttributes = false;
    _catalogInitialized = false; // guard so we only bootstrap the greeting once

    // --- LMS-publish grounding (from @wire getLmsGrounding) ---
    // developerName -> { attributeId (0tj), dataType, labelToValueId {label: 0v6 Id} }.
    // Used by handleApply to translate a reviewed selection into a valueChanged payload.
    _lmsGroundingByDev = {};
    _lmsGroundingError; // non-fatal: apply falls back to a clear message if this is unset

    // --- Saved (currently persisted) configuration, for the current-config chip ---
    _wiredSavedConfig;           // raw wire result — kept so refreshApex can re-pull it
    currentConfigItems = [];     // [{ key, label, value }] merged by developerName

    // --- Conversation transcript ---
    _msgSeq = 0;
    messages = [];               // [{ id, cssClass, roleLabel, text, showText }]

    // --- Composer ---
    requirementText = '';
    _lastRequirement = '';       // remembered for the EXTRACTION retry affordance

    // --- Guided-selling (agent Q&A) session ---
    // Agent session id for multi-turn continuity, held IN MEMORY only for the POC (no
    // persistence across a page reload). Seeded/refreshed from each askAgent response so a
    // follow-up question stays in the same agent conversation.
    _agentSessionId;

    // --- Review card (local editable copy of the proposal) ---
    reviewFields = [];           // editable rows (see buildReviewRow)
    unmappedNotes = [];          // [{ id, text }] muted "ignored" list
    extractionMethod;            // 'LLM' | 'FALLBACK'
    extractionErrorMessage;      // set when extraction returned isSuccess=false

    // --- Apply result (LMS publish is fire-and-forget: no price/diff to render) ---
    appliedItems = [];           // [{ id, label, value, isPriceImpacting }] pushed this apply
    applyErrorMessage;           // set only when a payload could not be built (no publish sent)

    // =====================================================================
    // WIRES
    // =====================================================================

    // LMS publish context. Required by publish() to emit on the notification channel.
    @wire(MessageContext)
    messageContext;

    /**
     * Grounding source. cacheable — safe because getAttributes is SOQL-only.
     * Never hard-fails: errors come back in AttributesResult.errorMessage.
     */
    @wire(getAttributes, { quoteLineItemId: '$quoteLineItemId' })
    wiredAttributes({ data, error }) {
        if (data) {
            this.productName = data.productName;
            this.catalogAttributes = data.attributes || [];
            this.hasConfigurableAttributes = data.hasConfigurableAttributes === true;
            this.catalogError = data.errorMessage;
            this._bootstrapAfterCatalog();
            this._recomputeCurrentConfig();
        } else if (error) {
            // Transport-level wire failure (rare for this cacheable read).
            this.catalogError = this._readError(error);
            this.hasConfigurableAttributes = false;
            this._bootstrapAfterCatalog();
        }
    }

    /**
     * Currently persisted values. cacheable; we keep the raw wire result so we can
     * refreshApex() it after an apply to re-pull the post-save state.
     */
    @wire(getSavedConfiguration, { quoteLineItemId: '$quoteLineItemId' })
    wiredSaved(result) {
        this._wiredSavedConfig = result;
        this._recomputeCurrentConfig();
    }

    /**
     * LMS-publish grounding: attributeId (0tj) + picklist label->valueId (0v6) per
     * attribute. cacheable (SOQL-only). Indexed by developerName so handleApply can
     * translate each reviewed selection into the exact `valueChanged` payload the Data
     * Manager expects. A failure here is non-fatal at wire time — it only blocks Apply,
     * with a clear message, so extraction/review still work.
     */
    @wire(getLmsGrounding, { quoteLineItemId: '$quoteLineItemId' })
    wiredLmsGrounding({ data, error }) {
        if (data) {
            this._lmsGroundingError = data.errorMessage;
            const byDev = {};
            (data.attributes || []).forEach((a) => {
                const labelToValueId = {};
                (a.picklistValueIds || []).forEach((pv) => {
                    labelToValueId[pv.label] = pv.valueId;
                });
                byDev[a.developerName] = {
                    attributeId: a.attributeId,
                    dataType: a.dataType,
                    labelToValueId,
                    // Labels that map to >1 value Id — publishing one of these would
                    // silently guess. Kept as a Set for O(1) membership checks at Apply.
                    ambiguousLabels: new Set(a.ambiguousLabels || [])
                };
            });
            this._lmsGroundingByDev = byDev;
        } else if (error) {
            this._lmsGroundingError = this._readError(error);
            this._lmsGroundingByDev = {};
        }
    }

    // =====================================================================
    // LIFECYCLE
    // =====================================================================

    /**
     * Seed the session's auto-apply mode from the Flow-set default exactly once, after
     * the framework has assigned all @api properties. We copy into a mutable `autoApply`
     * (rather than binding the toggle directly to the @api prop) so a rep's per-session
     * flip never has to fight Flow's re-hydration of the input value.
     */
    connectedCallback() {
        this.autoApply = this.autoApplyDefault === true;
    }

    // =====================================================================
    // CATALOG BOOTSTRAP
    // =====================================================================

    /**
     * Runs once after the grounding catalog first resolves. Decides between the
     * non-configurable notice and the interactive chat, and seeds the greeting.
     */
    _bootstrapAfterCatalog() {
        if (this._catalogInitialized) {
            return;
        }
        this._catalogInitialized = true;

        if (this.catalogError || !this.hasConfigurableAttributes) {
            this.phase = PHASE.NON_CONFIG;
            return;
        }

        this.phase = PHASE.READY;
        const product = this.productName ? ` for "${this.productName}"` : '';
        this._pushAssistant(
            `Describe what you need${product} and I'll map it to this generator's attributes. ` +
            `For example: "~1500 kW, data-center continuous duty, low-voltage".`
        );
    }

    /**
     * Merges the saved attribute JSON (developerName -> persisted value) against the
     * catalog labels to render a friendly "current configuration" summary chip list.
     */
    _recomputeCurrentConfig() {
        const saved =
            this._wiredSavedConfig &&
            this._wiredSavedConfig.data &&
            this._wiredSavedConfig.data.savedAttributesJson;

        if (!saved) {
            this.currentConfigItems = [];
            return;
        }

        let parsed;
        try {
            parsed = JSON.parse(saved);
        } catch (e) {
            this.currentConfigItems = [];
            return;
        }

        // developerName -> human label from the catalog (falls back to the raw key).
        const labelByDev = {};
        (this.catalogAttributes || []).forEach((a) => {
            labelByDev[a.developerName] = a.name || a.developerName;
        });

        this.currentConfigItems = Object.keys(parsed)
            .filter((k) => parsed[k] !== null && parsed[k] !== undefined && `${parsed[k]}` !== '')
            .map((k) => ({
                key: k,
                label: labelByDev[k] || k,
                value: `${parsed[k]}`
            }));
    }

    // =====================================================================
    // COMPOSER / SEND -> EXTRACT
    // =====================================================================

    /**
     * Rep flips the auto-apply mode for this session. Purely a mode switch — it does
     * NOT retroactively apply an already-rendered review card; it governs how the NEXT
     * extraction result is handled. Safe to toggle at any interactive phase.
     */
    handleAutoApplyToggle(event) {
        this.autoApply = event.target.checked === true;
    }

    handleInputChange(event) {
        this.requirementText = event.target.value;
    }

    /** Enter key in the input sends, matching a chat affordance. */
    handleInputKeyup(event) {
        if (event.key === 'Enter' && !this.sendDisabled) {
            this.handleSend();
        }
    }

    /**
     * Send a message. Appends the rep turn, then ROUTES it:
     *
     *   INTENT GATE (2026-07-19, D11 revised) — BEFORE extraction, a lightweight heuristic
     *   decides whether the message is an ADVICE/QUESTION ("what do you recommend for a data
     *   center?", "which duty rating suits a hospital?") vs. a CONFIGURATION DIRECTIVE
     *   ("~1500 kW, data-center continuous, low-voltage").
     *
     *   The gate exists because extraction is greedy: "data center" in a *question* still
     *   matches the DutyRating picklist value "Data Center Continuous (DCC)", so the old
     *   extract-first router mapped ≥1 attribute and — with auto-apply on — silently APPLIED
     *   a config change instead of letting the agent give a reasoned recommendation. The gate
     *   sends advice-phrased messages to the agent up front; everything else takes the
     *   existing extraction path (which still has its own zero-mapped agent fallback).
     *
     * extractConfiguration never throws — expected errors come back in the DTO.
     */
    async handleSend() {
        const text = (this.requirementText || '').trim();
        if (!text) {
            return;
        }

        // Reset any prior proposal / result so the transcript reads cleanly.
        this._clearProposal();
        this._clearResult();

        this._lastRequirement = text;
        this._pushRep(text);
        this.requirementText = '';

        // INTENT GATE: advice/question phrasing goes straight to the agent, bypassing the
        // greedy extractor entirely. _askAgentFallback owns the ASKING phase + READY return.
        if (this._looksLikeQuestion(text)) {
            this._askAgentFallback(text);
            return;
        }

        this.phase = PHASE.EXTRACTING;

        try {
            const res = await extractConfiguration({
                requirementText: text,
                quoteLineItemId: this.quoteLineItemId
            });
            this._handleExtractionResult(res);
        } catch (e) {
            // extractConfiguration is documented as never-throws, but be defensive.
            this.extractionErrorMessage = this._readError(e);
            this._pushAssistant('Sorry — extraction failed unexpectedly. ' + this.extractionErrorMessage);
            this.phase = PHASE.READY;
        }
    }

    /**
     * Heuristic intent classifier: true when a message reads as ADVICE-SEEKING / a QUESTION
     * rather than a configuration directive, so it should be routed to the agent up front.
     *
     * Deliberately conservative and phrase-based (no LLM call — zero added latency/cost):
     * it looks for explicit recommendation/opinion markers and interrogatives. A directive
     * like "set duty rating to DCC" or "~1500 kW, low-voltage" matches none of these and
     * falls through to extraction, preserving the config path. This is the fast POC fix;
     * a follow-up may move intent detection into the extraction LLM call for messages whose
     * phrasing this doesn't catch (see 06-open-questions-and-decisions.md, D11 revised).
     *
     * NOTE on the trailing "?": a bare "?" is a strong question signal, but a directive
     * occasionally ends in one ("1500 kW?"). We treat "?" as a question ONLY when the message
     * also lacks obvious directive shape; in practice the advice markers below carry the load,
     * and "?" is a backstop.
     */
    _looksLikeQuestion(text) {
        const t = ` ${text.toLowerCase().trim()} `;

        // Explicit advice / recommendation / opinion markers — the primary signal.
        const ADVICE_MARKERS = [
            'recommend', 'suggest', 'advise', 'advice',
            'which one', 'which option', 'which duty', 'which is', 'which would', 'which should',
            'what do you', 'what would you', 'what should', "what's best", 'what is best',
            'what should i', 'best for', 'best suited', 'best option', 'suited for',
            'help me choose', 'help me pick', 'help me decide',
            'should i', 'do you think', 'is it better', 'better to',
            'tell me more', 'explain', 'what are the', 'what is the difference',
            'difference between', 'how do i choose', 'how should i'
        ];
        // A marker anywhere in the (space-padded) message routes to the agent. Padding on
        // both ends means single-word markers like "explain" match at the start/end too.
        if (ADVICE_MARKERS.some((m) => t.includes(m))) {
            return true;
        }

        // Interrogative openers ("what/which/why/how/is/are/can/would/should ...").
        const trimmed = text.toLowerCase().trim();
        const QUESTION_OPENERS = [
            'what ', 'which ', 'why ', 'how ', 'who ', 'when ', 'where ',
            'is ', 'are ', 'can ', 'could ', 'would ', 'should ', 'do ', 'does '
        ];
        if (QUESTION_OPENERS.some((o) => trimmed.startsWith(o))) {
            return true;
        }

        // Trailing question mark as a backstop.
        if (trimmed.endsWith('?')) {
            return true;
        }

        return false;
    }

    /** Retry the last requirement after an extraction error. */
    handleRetry() {
        if (!this._lastRequirement) {
            return;
        }
        this.requirementText = this._lastRequirement;
        this.handleSend();
    }

    /**
     * Turns an ExtractionResult into the transcript + editable review card.
     * isSuccess=false is a grounding/guard error -> assistant error turn (still interactive).
     */
    _handleExtractionResult(res) {
        this.extractionMethod = res && res.extractionMethod;

        if (!res || res.isSuccess !== true) {
            this.extractionErrorMessage = (res && res.errorMessage) || 'Extraction failed.';
            this._pushAssistant('I could not map that: ' + this.extractionErrorMessage);
            this.phase = PHASE.READY; // EXTRACTION_ERROR — stays interactive, retry available
            return;
        }

        // LLM INTENT ROUTING (2026-07-19, D11 follow-up). The grounded extraction call now
        // classifies the message itself: intent 'ASK' means it read as an advice question
        // (e.g. "how much load do I need for a large data center") rather than a directive,
        // even if greedy picklist matching could have mapped a word out of it. Forward it to
        // the agent — this is the robust backstop for phrasings the up-front heuristic gate
        // (_looksLikeQuestion) doesn't catch. The service returns no proposedFields for an
        // ASK, so there is nothing to review.
        if (res.intent === 'ASK') {
            this._askAgentFallback(this._lastRequirement);
            return;
        }

        const proposed = res.proposedFields || [];
        this.unmappedNotes = (res.unmappedNotes || []).map((n, i) => ({ id: `note-${i}`, text: n }));

        if (proposed.length === 0) {
            // EXTRACT-FIRST, AGENT-FALLBACK ROUTING (D11).
            // Extraction confidently mapped ZERO attributes — this is exactly the
            // "tell me more about the duty rating options" case the config engine can't
            // serve. Rather than the old dead-end "I could not map that", forward the same
            // text to the Revenue Management agent as an informational question. The
            // extraction-internal "ignored" notes are dropped here: they describe why the
            // config engine couldn't map the text, which is noise next to a conversational
            // answer.
            this.unmappedNotes = [];
            this._askAgentFallback(this._lastRequirement);
            return;
        }

        // Copy into a LOCAL editable array so edits never mutate the wired/DTO data.
        this.reviewFields = proposed.map((pf, i) => this.buildReviewRow(pf, i));

        // AUTO-APPLY branch. When the rep has auto-apply on AND the proposal is
        // unambiguously safe (LLM-sourced, every row valid and groundable), skip the
        // review card and publish straight to the configurator. Otherwise ALWAYS fall
        // back to manual review — auto-apply must never silently push a guessed,
        // low-confidence, or partially-invalid change.
        if (this.autoApply) {
            const block = this._autoApplyBlockReason();
            if (!block) {
                this._pushAssistant(
                    `Here's what I mapped — applying automatically (auto-apply is on).`
                );
                // handleApply publishes the included+valid rows (all of them, since the
                // proposal is clean) and drives the phase to APPLYING -> RESULT itself.
                this.handleApply();
                return;
            }
            // Not safe to auto-apply — explain why and drop to review for a manual click.
            this._pushAssistant(
                `Here's what I mapped. Auto-apply is on, but this needs a quick review first `
                + `(${block}). Check the values below, then Apply.`
            );
            this.phase = PHASE.REVIEW;
            return;
        }

        const method = this.extractionMethod === 'FALLBACK'
            ? ' (keyword fallback — the LLM was unavailable, please double-check)'
            : '';
        this._pushAssistant(
            `Here's what I mapped${method}. Review and edit below, then Apply to save and reprice.`
        );
        this.phase = PHASE.REVIEW;
    }

    // =====================================================================
    // GUIDED-SELLING TURN (agent Q&A) — the extract-first / agent-fallback path
    // =====================================================================

    /**
     * Forward an informational question to the Revenue Management agent and render its
     * answer as an assistant text turn. This is INSIGHT-ONLY: no review card, no apply —
     * the agent's answer is conversational, not a configuration proposal (D9). Reached
     * only when extraction mapped nothing (D11 routing) so the message is treated as a
     * question rather than a configuration requirement.
     *
     * askAgent follows the same never-throws contract as extraction: expected problems
     * (blank, generic-failure, empty answer, invocation failure) come back as
     * isSuccess=false + errorMessage, which we surface as a graceful assistant message.
     * The returned sessionId is held in memory so a follow-up stays in the same
     * conversation.
     */
    async _askAgentFallback(question) {
        this.phase = PHASE.ASKING;
        try {
            const res = await askAgent({
                question,
                quoteId: this.quoteId,
                quoteLineItemId: this.quoteLineItemId,
                sessionId: this._agentSessionId
            });

            // Carry the session id forward even on a soft failure so a retry/follow-up
            // continues the same agent conversation.
            if (res && res.sessionId) {
                this._agentSessionId = res.sessionId;
            }

            if (res && res.isSuccess === true && res.answerText) {
                this._pushAssistant(res.answerText);
            } else {
                const msg = (res && res.errorMessage)
                    || 'The assistant could not answer that just now.';
                this._pushAssistant(msg);
            }
        } catch (e) {
            // askAgent is documented as never-throws, but be defensive (transport error).
            this._pushAssistant(
                'Sorry — the assistant could not be reached. ' + this._readError(e)
            );
        }
        // Whether answered or not, return to idle for the next message.
        this.phase = PHASE.READY;
    }

    /**
     * Returns a short human reason the current proposal must NOT be auto-applied, or
     * null/'' when it is clean enough to publish without a manual review click.
     *
     * Auto-apply is intentionally conservative — it only fires when EVERY guarantee the
     * manual review card enforces is already satisfied up front:
     *   - the extraction came from the LLM, not the low-confidence keyword fallback;
     *   - at least one row exists and every row is valid (no illegal picklist value,
     *     no blank/non-numeric number);
     *   - every row is unambiguously groundable for the LMS publish (known attributeId,
     *     a single AttributePicklistValue Id per picklist label — reuses the exact
     *     _buildValueChangedItem checks handleApply would run).
     * Any failure returns a reason string so the rep sees WHY it dropped to review.
     */
    _autoApplyBlockReason() {
        if (this.extractionMethod === 'FALLBACK') {
            return 'the LLM was unavailable, so this used a keyword fallback';
        }
        const rows = this.reviewFields || [];
        if (rows.length === 0) {
            return 'nothing was mapped';
        }
        if (rows.some((f) => !f.isValid)) {
            return 'one or more values need attention';
        }
        // Every row must build a valueChanged item cleanly (catches ambiguous labels,
        // missing configurator mapping, unrecognized picklist values).
        const ungroundable = rows.find((f) => this._buildValueChangedItem(f).error);
        if (ungroundable) {
            return `"${ungroundable.label}" can't be mapped to the configurator automatically`;
        }
        return null;
    }

    /**
     * Builds one editable review row from a ProposedField. Invalid rows default to
     * EXCLUDED (still shown + flagged) so the rep sees rather than silently loses them.
     */
    buildReviewRow(pf, index) {
        const dt = pf.dataType || '';
        const isPicklist = pf.isPicklist === true || dt.toLowerCase() === 'picklist';
        const isNumber = dt.toLowerCase() === 'number';
        const isCheckbox = dt.toLowerCase() === 'checkbox';

        return {
            key: pf.developerName || `field-${index}`,
            developerName: pf.developerName,
            label: pf.label || pf.developerName,
            dataType: dt,
            isPicklist,
            isNumber,
            isCheckbox,
            isText: !isPicklist && !isNumber && !isCheckbox,
            // lightning-combobox options constrained to the legal picklist values.
            comboOptions: (pf.picklistValues || []).map((v) => ({ label: v, value: v })),
            picklistValues: pf.picklistValues || [],
            value: pf.proposedValue,
            checkboxValue: `${pf.proposedValue}`.toLowerCase() === 'true',
            included: pf.isValid === true, // invalid rows default OFF
            isValid: pf.isValid === true,
            isPriceImpacting: pf.isPriceImpacting === true,
            confidence: pf.confidence,
            note: pf.note
        };
    }

    // =====================================================================
    // REVIEW CARD EDITING
    // =====================================================================

    /** include/reject toggle per field. */
    handleIncludeToggle(event) {
        const key = event.target.dataset.key;
        const checked = event.target.checked;
        this.reviewFields = this.reviewFields.map((f) =>
            f.key === key ? { ...f, included: checked } : f
        );
    }

    /** Value edit for picklist (combobox), number, or text editors. */
    handleValueChange(event) {
        const key = event.target.dataset.key;
        const newValue = event.target.value;
        this.reviewFields = this.reviewFields.map((f) => {
            if (f.key !== key) {
                return f;
            }
            const updated = { ...f, value: newValue };
            updated.isValid = this._revalidate(updated, newValue);
            return updated;
        });
    }

    /** Checkbox editor edit. */
    handleCheckboxValueChange(event) {
        const key = event.target.dataset.key;
        const checked = event.target.checked;
        this.reviewFields = this.reviewFields.map((f) =>
            f.key === key
                ? { ...f, checkboxValue: checked, value: `${checked}`, isValid: true }
                : f
        );
    }

    /**
     * Local re-validation after a manual edit. Picklist editors are already constrained
     * to legal values, so this mostly keeps the isValid flag honest for number/text rows.
     */
    _revalidate(field, value) {
        const v = (value === null || value === undefined) ? '' : `${value}`;
        if (field.isPicklist) {
            return field.picklistValues.some((pv) => pv === value);
        }
        if (field.isNumber) {
            return v.trim() !== '' && !isNaN(Number(v));
        }
        if (field.isCheckbox) {
            return true;
        }
        return v.trim() !== '';
    }

    /** Discard the whole proposal without applying anything. */
    handleDiscard() {
        this._clearProposal();
        this._pushAssistant('Discarded. Describe another requirement whenever you are ready.');
        this.phase = PHASE.READY;
    }

    // =====================================================================
    // APPLY -> publish valueChanged into the managed Data Manager (LMS)
    // =====================================================================

    /**
     * Translate the INCLUDED+VALID review rows into `valueChanged` LMS messages and
     * publish them into the managed configurator, then publish one `updatePrices`.
     *
     * ORDERING — Number attributes first, then Picklist. This mirrors the proven PST
     * two-step sequencing (ProductAttributeSaveService): a Number attribute drives BOM
     * component selection (e.g. requiredKW picks the FESBA unit), and submitting the
     * Picklist first can make the duty-rating rule derive the Number from the existing
     * component and override the requested value. Publishing Numbers first lets the BOM
     * resolve, then the Picklist applies duty-rating refinements on top.
     *
     * Each publish is fire-and-forget (no ApplyResult); nothing is persisted until the
     * user hits Save in the native configurator, which now reflects the change live.
     */
    async handleApply() {
        // Submit ONLY rows that are both included and valid (defense in depth beyond the
        // applyDisabled gate): an included-but-invalid row (illegal picklist value the
        // rep toggled on, or a cleared number) must never be pushed to the Data Manager.
        const included = this.reviewFields.filter((f) => f.included && f.isValid);
        if (included.length === 0) {
            return; // Apply is disabled in this case; guard defensively.
        }

        this._clearResult();

        // Build a valueChanged payload item per row, translating picklist labels to
        // their AttributePicklistValue Ids (0v6). If ANY included row can't be grounded,
        // abort the whole apply (no partial publish) with a clear message.
        const payloadItems = [];
        const summaryItems = [];
        for (const f of included) {
            const built = this._buildValueChangedItem(f);
            if (built.error) {
                this.applyErrorMessage = built.error;
                this._pushAssistant('Could not apply: ' + built.error);
                this.phase = PHASE.REVIEW; // keep the card so the rep can adjust/retry
                return;
            }
            payloadItems.push(built.item);
            summaryItems.push({
                id: `applied-${f.key}`,
                label: f.label,
                value: f.value, // human-facing (label / number), not the 0v6 Id
                isPriceImpacting: f.isPriceImpacting === true
            });
        }

        this.phase = PHASE.APPLYING;

        try {
            // Numbers first, then picklists (see ORDERING note). Text/checkbox go with
            // the "numbers" group (they don't drive the duty-rating derivation).
            const numberFirst = payloadItems.slice().sort(
                (a, b) => this._applyRank(a) - this._applyRank(b)
            );

            // One valueChanged message per attribute change — this matches the native
            // panel's own emission granularity (one data[] entry per edit).
            numberFirst.forEach((item) => {
                publish(this.messageContext, NotificationMessageChannel, {
                    action: 'valueChanged',
                    data: [item]
                });
            });

            // Ask the Data Manager to reprice after the edits are applied. (If Instant
            // Pricing is enabled on the configurator this is a harmless no-op nudge.)
            publish(this.messageContext, NotificationMessageChannel, {
                action: 'updatePrices'
            });

            this._handleApplySuccess(summaryItems);
        } catch (e) {
            // publish() is synchronous and rarely throws, but be defensive.
            this.applyErrorMessage = this._readError(e);
            this._pushAssistant('Apply failed while publishing to the configurator: '
                + this.applyErrorMessage);
            this.phase = PHASE.REVIEW;
        }
    }

    /**
     * Builds ONE `valueChanged` data[] entry from a review row, or returns an error if
     * the row can't be grounded (attributeId unknown, or a picklist label with no Id).
     *   { key: [quoteLineItemId], field: 'AttributeField', attributeId, value }
     */
    _buildValueChangedItem(f) {
        const g = this._lmsGroundingByDev[f.developerName];
        if (!g || !g.attributeId) {
            const detail = this._lmsGroundingError
                ? ` (${this._lmsGroundingError})`
                : '';
            return {
                error: `no configurator mapping for "${f.label}"${detail}`
            };
        }

        let value = f.value;
        if (f.isPicklist) {
            // Refuse an ambiguous label: it maps to more than one AttributePicklistValue
            // Id, so we cannot know which the rep meant. Better to block than to publish
            // a coin-flip value the Data Manager would silently accept.
            if (g.ambiguousLabels && g.ambiguousLabels.has(f.value)) {
                return {
                    error: `"${f.value}" matches more than one value for "${f.label}" `
                        + `in the configurator, so it can't be applied automatically. `
                        + `Please set this attribute directly in the configurator panel.`
                };
            }
            // The Data Manager expects the AttributePicklistValue Id, not the label.
            const valueId = g.labelToValueId[f.value];
            if (!valueId) {
                return {
                    error: `"${f.value}" is not a recognized value for "${f.label}"`
                };
            }
            value = valueId;
        } else if (f.isCheckbox) {
            // Normalize to a boolean like the native panel emits.
            value = `${f.value}`.toLowerCase() === 'true';
        }
        // Number/text: pass the raw value through (the engine parses it).

        return {
            item: {
                key: [this.quoteLineItemId],
                field: 'AttributeField',
                attributeId: g.attributeId,
                value
            }
        };
    }

    /**
     * Publish ordering rank: Number/other = 0 (first), Picklist = 1 (second).
     * Determined from the grounding dataType, which is authoritative.
     */
    _applyRank(item) {
        const g = this._groundingByAttributeId(item.attributeId);
        return g && 'Picklist'.toLowerCase() === `${g.dataType}`.toLowerCase() ? 1 : 0;
    }

    /** Reverse lookup: grounding entry by its attributeId (0tj). */
    _groundingByAttributeId(attributeId) {
        const devs = Object.keys(this._lmsGroundingByDev);
        for (const dev of devs) {
            if (this._lmsGroundingByDev[dev].attributeId === attributeId) {
                return this._lmsGroundingByDev[dev];
            }
        }
        return null;
    }

    /**
     * Success path for the LMS publish apply. There is no synchronous price/diff to
     * render (publish is fire-and-forget), so we show a lightweight confirmation of
     * what was pushed. The native configurator panel — now updated live — is the
     * source of truth for the resulting values and price.
     */
    _handleApplySuccess(summaryItems) {
        this.appliedItems = summaryItems;
        const n = summaryItems.length;
        this._pushAssistant(
            `Sent ${n} change${n === 1 ? '' : 's'} to the configurator. `
            + `The panel will update and reprice — review the result there, then Save.`
        );
        // The proposal has been pushed; clear it so a follow-up starts clean.
        this._clearProposal();
        // When the confirmation card is enabled (Flow opt-in), stay in RESULT so the card
        // renders with its Continue button. When it's hidden (the default), the chat line
        // above is the only confirmation, so drop straight back to READY for the next
        // message — there is no card, hence no Continue button to return to idle.
        this.phase = this.showSentToConfigurator === true ? PHASE.RESULT : PHASE.READY;
    }

    /** Dismiss the result card and go back to idle for a follow-up requirement. */
    handleContinue() {
        this._clearResult();
        this.phase = PHASE.READY;
    }

    // =====================================================================
    // TRANSCRIPT HELPERS
    // =====================================================================

    _pushAssistant(text) {
        this._push('assistant', 'Assistant', text);
    }

    _pushRep(text) {
        this._push('rep', 'You', text);
    }

    _push(role, roleLabel, text) {
        const isRep = role === 'rep';
        this.messages = [
            ...this.messages,
            {
                id: `msg-${this._msgSeq++}`,
                cssClass: isRep
                    ? 'msg-row msg-row_rep'
                    : 'msg-row msg-row_assistant',
                bubbleClass: isRep
                    ? 'msg-bubble msg-bubble_rep slds-p-around_x-small'
                    : 'msg-bubble msg-bubble_assistant slds-p-around_x-small',
                roleLabel,
                text
            }
        ];
    }

    _clearProposal() {
        this.reviewFields = [];
        this.unmappedNotes = [];
        this.extractionErrorMessage = undefined;
    }

    _clearResult() {
        this.appliedItems = [];
        this.applyErrorMessage = undefined;
    }

    /** Uniform error-text reader for rejected promises / wire errors. */
    _readError(e) {
        if (e && e.body && e.body.message) {
            return e.body.message;
        }
        if (e && e.message) {
            return e.message;
        }
        return JSON.stringify(e);
    }

    // =====================================================================
    // DERIVED GETTERS (template)
    // =====================================================================

    get isLoadingCatalog() {
        return this.phase === PHASE.LOADING;
    }

    get isNonConfigurable() {
        return this.phase === PHASE.NON_CONFIG;
    }

    get nonConfigMessage() {
        if (this.catalogError) {
            return this.catalogError;
        }
        return 'This line has no configurable attributes, so there is nothing to configure here.';
    }

    /** The chat input is shown once the catalog is usable and while idle-ish. */
    get showComposer() {
        return (
            this.phase === PHASE.READY ||
            this.phase === PHASE.REVIEW ||
            this.phase === PHASE.RESULT
        );
    }

    /**
     * Show the auto-apply mode toggle whenever the panel is interactive (i.e. not
     * loading and not the non-configurable notice). Kept visible during REVIEW so the
     * rep can see the mode that produced the current card and change it for next time.
     */
    get showAutoApplyToggle() {
        return this.phase !== PHASE.LOADING && this.phase !== PHASE.NON_CONFIG;
    }

    get isExtracting() {
        return this.phase === PHASE.EXTRACTING;
    }

    get isApplying() {
        return this.phase === PHASE.APPLYING;
    }

    /** Guided-selling turn in flight — awaiting the agent's (slow) answer. */
    get isAsking() {
        return this.phase === PHASE.ASKING;
    }

    /** Any in-flight controller call — drives the progress region. */
    get isBusy() {
        return this.isExtracting || this.isApplying || this.isAsking;
    }

    get busyLabel() {
        if (this.isApplying) {
            return 'Sending changes to the configurator...';
        }
        if (this.isAsking) {
            return 'Asking the assistant...';
        }
        return 'Mapping to attributes...';
    }

    get showReviewCard() {
        return this.phase === PHASE.REVIEW && this.reviewFields.length > 0;
    }

    get hasUnmappedNotes() {
        return this.unmappedNotes && this.unmappedNotes.length > 0;
    }

    /**
     * Show the "Ignored" notes on their own when there are notes but NO review card
     * (e.g. a successful extraction that mapped zero fields). Without this the
     * assistant message "See the ignored items below" would point at a list that
     * only renders inside the review card — which is hidden in that case.
     */
    get showStandaloneNotes() {
        return this.hasUnmappedNotes && !this.showReviewCard;
    }

    get includedCount() {
        return this.reviewFields.filter((f) => f.included).length;
    }

    /**
     * Rows that are BOTH included AND currently valid — the only rows we will
     * actually submit. A row can be included but invalid (e.g. the rep toggled on
     * a row whose proposed picklist value was illegal, or cleared a number field),
     * and such a value must never reach the reprice engine.
     */
    get includedValidCount() {
        return this.reviewFields.filter((f) => f.included && f.isValid).length;
    }

    /**
     * True when at least one row is included but invalid — drives an inline warning
     * so the rep understands why Apply is blocked / why a row won't be submitted.
     */
    get hasIncludedInvalid() {
        return this.reviewFields.some((f) => f.included && !f.isValid);
    }

    /**
     * Apply is disabled while a call is in flight, or unless there is at least one
     * included row that is also valid. Gating on validity (not just inclusion)
     * prevents submitting an illegal picklist value or a blank/non-numeric number
     * to applyConfiguration — the app-layer guard the server would otherwise be the
     * only defense for.
     */
    get applyDisabled() {
        return this.includedValidCount === 0 || this.isBusy;
    }

    get sendDisabled() {
        return this.isBusy || !(this.requirementText || '').trim();
    }

    get reviewHeader() {
        return this.productName
            ? `Proposed configuration — ${this.productName}`
            : 'Proposed configuration';
    }

    get hasCurrentConfig() {
        return this.currentConfigItems && this.currentConfigItems.length > 0;
    }

    // --- Result card getters (LMS confirmation — no price/diff; see class header) ---

    /**
     * Show the confirmation card once we've published to the configurator. Gated on the
     * Flow-set `showSentToConfigurator` flag (2026-07-19): by default the card is hidden —
     * auto-apply confirms via the assistant chat line alone — and it only renders when the
     * Flow explicitly opts in. Beyond the flag, the presence of pushed items in the RESULT
     * phase is the signal (there is no ApplyResult to gate on, unlike the old PST card).
     */
    get showResultCard() {
        return this.showSentToConfigurator === true
            && this.phase === PHASE.RESULT
            && this.appliedItems
            && this.appliedItems.length > 0;
    }

    /** True when at least one pushed change was flagged price-impacting. */
    get anyAppliedPriceImpacting() {
        return (this.appliedItems || []).some((i) => i.isPriceImpacting);
    }
}
