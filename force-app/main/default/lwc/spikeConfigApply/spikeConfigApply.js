/**
 * spikeConfigApply
 * ----------------
 * Minimal Spike 1 harness for the Agentforce product-configurator flow. Drops onto a
 * Flow screen (target lightning__FlowScreen) and receives quoteId / quoteLineItemId
 * from Flow variables. Lets a rep type one attribute value, apply it through
 * ConfigEngineController.applyConfiguration (imperative Apex — NOT cacheable, because
 * it mutates via the Place Sales Transaction engine), then renders the returned price
 * movement and the requested-vs-persisted diff.
 *
 * Intentionally single-attribute and unstyled: this exists to prove the wrapper +
 * PST round-trip works from a UI, not to be the production configurator.
 */
import { LightningElement, api } from 'lwc';
import applyConfiguration from '@salesforce/apex/ConfigEngineController.applyConfiguration';

export default class SpikeConfigApply extends LightningElement {
    // Populated by the Flow screen from Flow variables.
    @api quoteId;
    @api quoteLineItemId;

    // Which attribute (developerName) and value the rep wants to apply.
    // Defaulted to the seeded test attribute for a fast manual smoke test.
    attributeName = 'requiredKW';
    attributeValue = '';

    // UI state.
    isLoading = false;
    result;        // the ApplyResult returned by Apex
    errorMessage;  // transport-level error (thrown AuraHandledException, etc.)

    handleAttrNameChange(event) {
        this.attributeName = event.target.value;
    }

    handleValueChange(event) {
        this.attributeValue = event.target.value;
    }

    /**
     * Build the selections JSON ({devName: value}) and call the controller.
     * We call imperatively (not @wire) because this is a mutation the rep triggers.
     */
    async handleApply() {
        this.isLoading = true;
        this.result = undefined;
        this.errorMessage = undefined;

        try {
            // Single-attribute selections map; the engine accepts a devName->value object.
            const selections = {};
            selections[this.attributeName] = this.attributeValue;

            this.result = await applyConfiguration({
                quoteId: this.quoteId,
                quoteLineItemId: this.quoteLineItemId,
                attributeSelectionsJson: JSON.stringify(selections)
            });
        } catch (e) {
            // Only fires for thrown exceptions; expected business failures come back
            // inside result.errorMessage with isSuccess=false.
            this.errorMessage =
                (e && e.body && e.body.message) ? e.body.message : JSON.stringify(e);
        } finally {
            this.isLoading = false;
        }
    }

    // --- Derived getters for the template ---

    get hasResult() {
        return this.result !== undefined && this.result !== null;
    }

    get succeeded() {
        return this.hasResult && this.result.isSuccess === true;
    }

    // Authoritative price movement is the Quote grand-total delta (the root line can
    // stay flat while BOM children reprice — see controller PriceDelta note).
    get grandTotalDelta() {
        return this.hasResult && this.result.priceDelta
            ? this.result.priceDelta.quoteGrandTotalDelta
            : null;
    }

    get quoteGrandTotalAfter() {
        return this.hasResult && this.result.priceAfter
            ? this.result.priceAfter.quoteGrandTotal
            : null;
    }

    // Diff rows the template iterates over.
    get diffs() {
        return this.hasResult && this.result.diffs ? this.result.diffs : [];
    }

    get resultError() {
        return this.hasResult ? this.result.errorMessage : null;
    }
}
