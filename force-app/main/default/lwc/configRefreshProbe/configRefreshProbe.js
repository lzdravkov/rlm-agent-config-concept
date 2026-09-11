import { LightningElement, api, wire } from "lwc";
import {
    subscribe,
    unsubscribe,
    publish,
    MessageContext
} from "lightning/messageService";
// The managed RLM configurator's documented notification channel. The reference
// renderDraw3DConfigurationPrototype LWC imports this same channel and deploys
// cleanly, so we know it exists and is importable in this org.
import CONFIGURATOR_NOTIFICATION from "@salesforce/messageChannel/lightning__productConfigurator_notification";

/**
 * configRefreshProbe — THROWAWAY DIAGNOSTIC (Spike 1 / Gate 1).
 *
 * Purpose: determine, empirically and in the live org, whether the managed
 * runtime_industries_cfg configurator can be made to re-read the DB after our
 * side-channel PlaceSalesTransaction apply (the "screen doesn't refresh" problem
 * / dataManager in-memory desync).
 *
 * It does two things on the SAME Flow screen as the managed configurator, so it
 * shares the page-scoped Lightning Message Service bus with the managed
 * dataManager:
 *
 *   1. SUBSCRIBES to lightning__productConfigurator_notification and logs every
 *      inbound payload. This captures the REAL message contract the native panel
 *      emits when a user edits an attribute in the native UI (the key unknown —
 *      we have no documentation of the inbound "reload" shape, if one exists).
 *
 *   2. PUBLISHES candidate "reload"/"valueChanged" payloads on that same channel
 *      via buttons, so we can observe whether the managed panel reacts (re-reads
 *      the DB / re-renders) to anything we send.
 *
 * DELETE THIS COMPONENT once Gate 1 is decided. It is not part of the shipping
 * POC — it exists only to answer the refresh question.
 */
export default class ConfigRefreshProbe extends LightningElement {
    // Bound in the flow to the same context refs as the managed dataManager, so
    // the synthesized "valueChanged" payloads can carry a plausible line id.
    @api quoteId;
    @api quoteLineItemId;

    @wire(MessageContext)
    messageContext;

    _subscription = null;
    _seq = 0;

    // Rendered log of inbound messages, newest first.
    logEntries = [];

    // The most recent raw inbound message object, so we can "echo" it straight
    // back out as a publish candidate.
    _lastInbound = null;

    connectedCallback() {
        this.subscribeToChannel();
        this.pushLog(
            "PROBE",
            `Subscribed to lightning__productConfigurator_notification. quoteLineItemId=${this.quoteLineItemId}`
        );
    }

    disconnectedCallback() {
        if (this._subscription) {
            unsubscribe(this._subscription);
            this._subscription = null;
        }
    }

    subscribeToChannel() {
        if (this._subscription) {
            return;
        }
        this._subscription = subscribe(
            this.messageContext,
            CONFIGURATOR_NOTIFICATION,
            (message) => this.handleInbound(message),
            { scope: undefined }
        );
    }

    handleInbound(message) {
        // LMS payloads from the managed panel came back as "{}" under plain
        // JSON.stringify — that flattens non-enumerable / getter-backed / proxy
        // properties, which is almost certainly hiding the real shape. So we
        // introspect the message several ways and log ALL of them.
        this._lastInbound = message;
        this.pushLog("IN ", this.describe(message));
    }

    /**
     * Best-effort introspection of an LMS message that resists JSON.stringify.
     * Reports: typeof, JSON view, own+inherited enumerable keys, and a manual
     * key→value dump reading each property directly (which works through
     * getters/proxies that stringify silently drops).
     */
    describe(message) {
        const parts = [];
        parts.push(`typeof=${typeof message}`);

        // 1) Plain stringify (what we had before — kept for comparison).
        let json;
        try {
            json = JSON.stringify(message);
        } catch (e) {
            json = `<stringify threw: ${String(e)}>`;
        }
        parts.push(`json=${json}`);

        if (message && typeof message === "object") {
            // 2) Enumerable keys via for..in (includes inherited enumerables).
            const forInKeys = [];
            for (const k in message) {
                forInKeys.push(k);
            }
            parts.push(`forInKeys=[${forInKeys.join(",")}]`);

            // 3) Own property names (non-enumerable included).
            let ownKeys = [];
            try {
                ownKeys = Object.getOwnPropertyNames(message);
            } catch (e) {
                ownKeys = [`<err:${String(e)}>`];
            }
            parts.push(`ownKeys=[${ownKeys.join(",")}]`);

            // 4) Manual value dump — read each discovered key directly. This is
            //    the part that reveals getter/proxy-backed values stringify hides.
            const allKeys = Array.from(new Set([...forInKeys, ...ownKeys])).filter(
                (k) => k !== "constructor"
            );
            const kv = [];
            for (const k of allKeys) {
                let v;
                try {
                    v = message[k];
                    if (typeof v === "object" && v !== null) {
                        try {
                            v = JSON.stringify(v);
                        } catch (e) {
                            v = `<obj:${String(e)}>`;
                        }
                    }
                } catch (e) {
                    v = `<read err:${String(e)}>`;
                }
                kv.push(`${k}=${String(v)}`);
            }
            parts.push(`values={${kv.join("; ")}}`);
        }

        return parts.join(" | ");
    }

    pushLog(direction, text) {
        this._seq += 1;
        // Newest first so the user sees the latest without scrolling.
        this.logEntries = [
            {
                key: this._seq,
                line: `#${this._seq} [${direction}] ${text}`
            },
            ...this.logEntries
        ].slice(0, 60);
    }

    // ── Publish candidates ────────────────────────────────────────────────
    // Each button publishes a differently-shaped payload on the SAME channel
    // the native panel uses, then logs what we sent. We then watch the managed
    // panel to see if any shape triggers a re-read.

    publishAndLog(payload, label) {
        try {
            publish(this.messageContext, CONFIGURATOR_NOTIFICATION, payload);
            this.pushLog("OUT", `${label}: ${JSON.stringify(payload)}`);
        } catch (e) {
            this.pushLog("ERR", `${label} publish failed: ${String(e)}`);
        }
    }

    handlePublishRefresh() {
        // A bare "refresh" verb — cheapest possible reload nudge.
        this.publishAndLog({ action: "refresh" }, "refresh");
    }

    handlePublishReload() {
        this.publishAndLog(
            { action: "reload", transactionLineId: this.quoteLineItemId },
            "reload"
        );
    }

    handlePublishValueChanged() {
        // Mimic the shape the native panel emits on an attribute edit (per the
        // reference prototype's handler: action='valueChanged', data:[{field,...}]).
        this.publishAndLog(
            {
                action: "valueChanged",
                data: [
                    {
                        field: "AttributeField",
                        quoteLineItemId: this.quoteLineItemId
                    }
                ]
            },
            "valueChanged"
        );
    }

    handlePublishReprice() {
        // Some Revenue Cloud runtimes react to a "reprice" / "priceChanged" verb.
        this.publishAndLog(
            { action: "reprice", transactionLineId: this.quoteLineItemId },
            "reprice"
        );
    }

    handlePublishTransactionUpdated() {
        // A transaction-level "updated" nudge (mirrors the revenue_transactionNotification idea).
        this.publishAndLog(
            {
                action: "transactionUpdated",
                transactionId: this.quoteId,
                transactionLineId: this.quoteLineItemId
            },
            "transactionUpdated"
        );
    }

    handleEchoLast() {
        if (!this._lastInbound) {
            this.pushLog("ERR", "No inbound message captured yet to echo.");
            return;
        }
        // Rebuild a PLAIN object from the raw message by reading each key
        // directly (the raw message may be a proxy/getter-backed object that
        // publish() or stringify won't carry). This lets us replay the panel's
        // OWN real message shape back at it.
        const plain = {};
        const msg = this._lastInbound;
        const keys = new Set();
        for (const k in msg) {
            keys.add(k);
        }
        try {
            Object.getOwnPropertyNames(msg).forEach((k) => keys.add(k));
        } catch (e) {
            // ignore — some hosts disallow getOwnPropertyNames on proxies
        }
        keys.delete("constructor");
        keys.forEach((k) => {
            try {
                plain[k] = msg[k];
            } catch (e) {
                // skip unreadable
            }
        });
        this.publishAndLog(plain, "echo-last-inbound");
    }

    handleClear() {
        this.logEntries = [];
        this._seq = 0;
    }
}
