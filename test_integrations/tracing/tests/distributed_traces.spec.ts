import { test, expect } from "@playwright/test";
import {
  clearLoggedEvents,
  waitForEvents,
  type SentryEvent,
  type TransactionWithSpans,
} from "./helpers";

const PHOENIX_URL = process.env.SENTRY_E2E_PHOENIX_APP_URL;
if (!PHOENIX_URL) {
  throw new Error(
    "Required environment variable SENTRY_E2E_PHOENIX_APP_URL is not set."
  );
}

const UPSTREAM_TRACE_ID = "1f2e3d4c5b6a79881f2e3d4c5b6a7988";
const UPSTREAM_SPAN_ID = "a1b2c3d4e5f60718";

function transactions(events: SentryEvent[]): TransactionWithSpans[] {
  return events.filter(
    (e) => e.type === "transaction"
  ) as TransactionWithSpans[];
}

function findByName(
  events: SentryEvent[],
  name: string
): TransactionWithSpans | undefined {
  return transactions(events).find((t) => t.transaction === name);
}

function findByRoute(
  events: SentryEvent[],
  route: string
): TransactionWithSpans | undefined {
  return transactions(events).find(
    (t) => t.contexts?.trace?.data?.["http.route"] === route
  );
}

test.describe("Trace continued from an upstream service", () => {
  test.beforeEach(() => {
    clearLoggedEvents();
  });

  test("background work is reported as a segment of the upstream trace", async ({
    page,
  }) => {
    await page.setExtraHTTPHeaders({
      traceparent: `00-${UPSTREAM_TRACE_ID}-${UPSTREAM_SPAN_ID}-01`,
    });

    await page.goto(`${PHOENIX_URL}/distributed-traces/handoff`);

    const logged = await waitForEvents((l) =>
      Boolean(
        findByRoute(l.events, "/distributed-traces/handoff") &&
          findByName(l.events, "sync.run")
      )
    );

    const requestTx = findByRoute(
      logged.events,
      "/distributed-traces/handoff"
    );
    const syncTx = findByName(logged.events, "sync.run");

    expect(requestTx).toBeDefined();
    expect(
      syncTx,
      "background sync continuing the upstream trace was not reported"
    ).toBeDefined();

    // The request span already worked before the fix: it is kind: :server with
    // an http.request.method attribute, so the old heuristic promoted it.
    expect(requestTx!.contexts?.trace?.trace_id).toBe(UPSTREAM_TRACE_ID);
    expect(requestTx!.contexts?.trace?.parent_span_id).toBe(UPSTREAM_SPAN_ID);

    // The background sync is a plain internal span whose parent belongs to the
    // upstream service, which is what used to be dropped.
    const syncTrace = syncTx!.contexts?.trace;
    expect(syncTrace?.trace_id).toBe(UPSTREAM_TRACE_ID);
    expect(syncTrace?.parent_span_id).toBe(UPSTREAM_SPAN_ID);
    expect(syncTrace?.op).toBe("sync.run");

    const dbSpan = (syncTx!.spans ?? []).find((s) => s.op === "db");
    expect(dbSpan, "instrumented db span missing from the sync").toBeDefined();
    expect(dbSpan!.parent_span_id).toBe(syncTrace?.span_id);
    expect(dbSpan!.trace_id).toBe(UPSTREAM_TRACE_ID);

    // The upstream context is inherited by every span of the local subtree, so
    // a promotion rule that keyed off it alone would report each span as its
    // own transaction instead of nesting them under the sync.
    const dbTransactions = transactions(logged.events).filter(
      (t) => t.contexts?.trace?.op === "db"
    );

    expect(
      dbTransactions,
      "instrumented child spans were promoted to their own transactions"
    ).toHaveLength(0);
  });

  test("the scenario page triggers the handoff on its own", async ({ page }) => {
    await page.goto(`${PHOENIX_URL}/distributed-traces`);

    await expect(page.locator("h1")).toContainText(
      "Distributed trace scenarios"
    );

    await page.click("a#handoff");
    await expect(page.locator("#result")).toContainText("upstream: 00-");

    const result = await page.locator("#result").textContent();
    const traceId = result!.match(/upstream: 00-([0-9a-f]{32})-/)![1];

    const logged = await waitForEvents((l) =>
      transactions(l.events).some(
        (t) =>
          t.transaction === "sync.run" &&
          t.contexts?.trace?.trace_id === traceId
      )
    );

    const syncTx = transactions(logged.events).find(
      (t) => t.transaction === "sync.run"
    );

    expect(
      syncTx,
      "clicking the scenario link did not produce a reported sync"
    ).toBeDefined();
    expect(syncTx!.contexts?.trace?.trace_id).toBe(traceId);
  });
});
