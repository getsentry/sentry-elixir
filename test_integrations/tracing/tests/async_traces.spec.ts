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

function transactions(events: SentryEvent[]): TransactionWithSpans[] {
  return events.filter(
    (e) => e.type === "transaction"
  ) as TransactionWithSpans[];
}

function findByRoute(
  events: SentryEvent[],
  route: string
): TransactionWithSpans | undefined {
  return transactions(events).find(
    (t) => t.contexts?.trace?.data?.["http.route"] === route
  );
}

function findByName(
  events: SentryEvent[],
  name: string
): TransactionWithSpans | undefined {
  return transactions(events).find((t) => t.transaction === name);
}

test.describe("Async trace continuation", () => {
  test.beforeEach(() => {
    clearLoggedEvents();
  });

  test("work outliving the request is reported as a linked follow-up transaction", async ({
    page,
  }) => {
    await page.goto(`${PHOENIX_URL}/async-traces/in-flight`);

    const logged = await waitForEvents((l) =>
      Boolean(
        findByRoute(l.events, "/async-traces/in-flight") &&
          findByName(l.events, "deliver_report")
      )
    );

    const requestTx = findByRoute(logged.events, "/async-traces/in-flight");
    const followUpTx = findByName(logged.events, "deliver_report");

    expect(requestTx).toBeDefined();
    expect(followUpTx).toBeDefined();

    const requestTrace = requestTx!.contexts?.trace;
    expect(requestTrace?.op).toBe("http.server");

    const requestSpans = requestTx!.spans ?? [];
    for (const span of requestSpans) {
      expect(span.timestamp, `span ${span.description} has no end timestamp`)
        .toBeTruthy();
    }
    expect(requestSpans.map((s) => s.description)).not.toContain(
      "deliver_report"
    );

    const followUpTrace = followUpTx!.contexts?.trace;
    expect(followUpTrace?.trace_id).toBe(requestTrace?.trace_id);
    expect(followUpTrace?.parent_span_id).toBe(requestTrace?.span_id);
    expect(followUpTrace?.data?.["sentry.parent_span_already_sent"]).toBe(
      true
    );
  });

  test("late work from a nested span is reported as a linked follow-up transaction", async ({
    page,
  }) => {
    await page.goto(`${PHOENIX_URL}/async-traces/nested`);

    const logged = await waitForEvents((l) =>
      Boolean(
        findByRoute(l.events, "/async-traces/nested") &&
          findByName(l.events, "finalize_batch")
      )
    );

    const requestTx = findByRoute(logged.events, "/async-traces/nested");
    const followUpTx = findByName(logged.events, "finalize_batch");

    expect(requestTx).toBeDefined();
    expect(followUpTx).toBeDefined();

    const requestSpans = requestTx!.spans ?? [];
    const batchSpan = requestSpans.find(
      (s) => s.description === "process_batch"
    );
    const dbSpan = requestSpans.find((s) => s.op === "db");

    expect(batchSpan).toBeDefined();
    expect(dbSpan).toBeDefined();
    expect(dbSpan!.parent_span_id).toBe(batchSpan!.span_id);

    const followUpTrace = followUpTx!.contexts?.trace;
    expect(followUpTrace?.trace_id).toBe(
      requestTx!.contexts?.trace?.trace_id
    );
    expect(followUpTrace?.parent_span_id).toBe(batchSpan!.span_id);
    expect(followUpTrace?.data?.["sentry.parent_span_already_sent"]).toBe(
      true
    );
  });

  test("scenario index page links to both scenarios", async ({ page }) => {
    await page.goto(`${PHOENIX_URL}/async-traces`);

    await expect(page.locator("h1")).toContainText("Async trace scenarios");
    await expect(page.locator("a#in-flight")).toBeVisible();
    await expect(page.locator("a#nested")).toBeVisible();
  });
});
