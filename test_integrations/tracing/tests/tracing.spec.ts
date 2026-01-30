import { test, expect } from "@playwright/test";
import {
  clearLoggedEvents,
  getLoggedEvents,
  waitForEvents,
  validateSpanHierarchy,
  getDirectChildSpans,
  type TransactionWithSpans,
  type Span,
} from "./helpers";

test.describe("Tracing", () => {
  test.beforeEach(() => {
    clearLoggedEvents();
  });

  test("validates basic tracing functionality", async ({ page }) => {
    await page.goto("/");

    await expect(page.locator("h1")).toContainText("Svelte Mini App");
    await expect(page.locator("button#trigger-error-btn")).toBeVisible();

    await page.click("button#trigger-error-btn");

    await expect(page.locator(".result")).toContainText("Error:");
    await page.waitForTimeout(2000);

    const logged = getLoggedEvents();
    expect(logged.event_count).toBeGreaterThan(0);

    const errorEvents = logged.events.filter((event) => event.exception);
    expect(errorEvents.length).toBeGreaterThan(0);

    const errorEvent = errorEvents[errorEvents.length - 1];
    const exceptionValues = errorEvent.exception;
    expect(exceptionValues).toBeDefined();
    expect(exceptionValues!.length).toBeGreaterThan(0);
    expect(exceptionValues![0].type).toBe("ArithmeticError");

    const transactionEvents = logged.events.filter(
      (event) => event.type === "transaction"
    );
    expect(transactionEvents.length).toBeGreaterThan(0);

    const errorTransactions = transactionEvents.filter(
      (event) =>
        event.transaction?.includes("error") ||
        event.transaction?.includes("GET")
    );

    errorTransactions.forEach((transaction) => {
      const traceContext = transaction.contexts?.trace;
      expect(traceContext).toBeDefined();
      expect(traceContext?.trace_id).toBeDefined();
      expect(traceContext?.trace_id).toMatch(/^[a-f0-9]{32}$/);
      expect(traceContext?.span_id).toBeDefined();
      expect(traceContext?.span_id).toMatch(/^[a-f0-9]{16}$/);
      expect(traceContext?.op).toBe("http.server");

      const traceData = traceContext?.data as Record<string, any> | undefined;
      expect(traceData).toBeDefined();
      expect(traceData?.["http.request.method"]).toBe("GET");
      expect(traceData?.["http.route"]).toBe("/error");
      expect(traceData?.["phoenix.action"]).toBe("api_error");
    });
  });

  test.describe("OpenTelemetry trace propagation", () => {
    test("validates trace IDs are properly generated for backend requests", async ({
      page,
    }) => {
      await page.goto("/");

      await expect(page.locator("h1")).toContainText("Svelte Mini App");
      await expect(page.locator("button#trigger-error-btn")).toBeVisible();

      await page.click("button#trigger-error-btn");

      await expect(page.locator(".result")).toContainText("Error:");

      await page.waitForTimeout(2000);

      const logged = getLoggedEvents();

      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );
      expect(transactionEvents.length).toBeGreaterThan(0);

      const errorTransaction = transactionEvents.find(
        (event) =>
          event.transaction?.includes("/error") ||
          event.transaction?.includes("GET")
      );
      expect(errorTransaction).toBeDefined();

      const traceContext = errorTransaction!.contexts?.trace;
      expect(traceContext).toBeDefined();
      expect(traceContext?.trace_id).toMatch(/^[a-f0-9]{32}$/);
      expect(traceContext?.span_id).toMatch(/^[a-f0-9]{16}$/);
      expect(traceContext?.op).toBe("http.server");
    });

    test("validates distributed tracing across multiple requests", async ({
      page,
    }) => {
      await page.goto("/");

      await expect(page.locator("h1")).toContainText("Svelte Mini App");

      for (let i = 0; i < 3; i++) {
        await page.click("button#trigger-error-btn");
        await page.waitForTimeout(100);
      }

      await expect(page.locator(".result")).toContainText("Error:");

      await page.waitForTimeout(2000);

      const logged = getLoggedEvents();

      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );

      const errorTransactions = transactionEvents.filter((event) =>
        event.transaction?.includes("/error")
      );

      expect(errorTransactions.length).toBeGreaterThanOrEqual(3);

      const traceIds = errorTransactions
        .map((t) => t.contexts?.trace?.trace_id)
        .filter(Boolean);
      expect(traceIds.length).toBeGreaterThanOrEqual(3);

      traceIds.forEach((traceId) => {
        expect(traceId).toMatch(/^[a-f0-9]{32}$/);
      });

      const uniqueTraceIds = [...new Set(traceIds)];
      expect(uniqueTraceIds.length).toBe(1);

      errorTransactions.forEach((transaction) => {
        const parentSpanId = transaction.contexts?.trace?.parent_span_id;
        expect(parentSpanId).toBeDefined();
        expect(parentSpanId).toMatch(/^[a-f0-9]{16}$/);
      });
    });

    test("validates child span data is preserved in distributed tracing", async ({
      page,
    }) => {
      await page.goto("/");

      await expect(page.locator("h1")).toContainText("Svelte Mini App");

      await page.evaluate(async () => {
        const response = await fetch("http://localhost:4000/api/data", {
          method: "GET",
          headers: {
            "Content-Type": "application/json",
          },
        });
        return response.json();
      });

      await page.waitForTimeout(2000);

      const logged = getLoggedEvents();

      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );
      expect(transactionEvents.length).toBeGreaterThan(0);

      const dataTransactions = transactionEvents.filter(
        (event) =>
          event.transaction?.includes("/api/data") ||
          event.transaction?.includes("fetch_data") ||
          (event.contexts?.trace?.data as any)?.["http.route"] === "/api/data"
      );

      expect(dataTransactions.length).toBeGreaterThan(0);

      const dataTransaction = dataTransactions[0];
      expect(dataTransaction.contexts?.trace?.parent_span_id).toBeDefined();
      expect(dataTransaction.contexts?.trace?.parent_span_id).toMatch(
        /^[a-f0-9]{16}$/
      );

      const spans = (dataTransaction as any).spans;
      expect(spans).toBeDefined();
      expect(spans.length).toBeGreaterThan(0);

      spans.forEach((span: any) => {
        expect(span.span_id).toBeDefined();
        expect(span.span_id).toMatch(/^[a-f0-9]{16}$/);
        expect(span.trace_id).toBeDefined();
        expect(span.trace_id).toMatch(/^[a-f0-9]{32}$/);
        expect(span.op).toBeDefined();
        expect(span.description).toBeDefined();

        expect(span.data).toBeDefined();
        expect(typeof span.data).toBe("object");

        expect(span.data["otel.kind"]).toBeDefined();
      });

      const dbSpans = spans.filter((span: any) => span.op === "db");
      expect(dbSpans.length).toBeGreaterThan(0);

      dbSpans.forEach((dbSpan: any) => {
        expect(dbSpan.data["db.system"]).toBeDefined();

        expect(dbSpan.description).toBeDefined();
        expect(dbSpan.description.length).toBeGreaterThan(0);

        expect(dbSpan.description).toMatch(/SELECT/i);

        expect(dbSpan.data["db.statement"]).toBeDefined();
        expect(dbSpan.data["db.statement"]).toMatch(/SELECT/i);
      });
    });
  });

  test.describe("LiveView tracing", () => {
    const PHOENIX_URL = process.env.SENTRY_E2E_PHOENIX_APP_URL || "http://localhost:4000";

    test("generates transaction for LiveView page mount with valid trace context", async ({ page }) => {
      await page.goto(`${PHOENIX_URL}/tracing-test`);

      await expect(page.locator("#tracing-test-live h1")).toContainText("LiveView Tracing Test");
      await expect(page.locator("#counter-value")).toHaveText("0");

      const logged = await waitForEvents(
        (events) =>
          events.events.some(
            (e) =>
              e.type === "transaction" &&
              ((e.contexts?.trace?.data as any)?.["url.path"] === "/tracing-test" ||
                e.transaction?.includes("/tracing-test"))
          ),
        { timeout: 10000 }
      );

      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );
      expect(transactionEvents.length).toBeGreaterThan(0);

      const mountTransactions = transactionEvents.filter(
        (event) =>
          event.transaction?.includes("/tracing-test") ||
          (event.contexts?.trace?.data as any)?.["http.route"] === "/tracing-test" ||
          (event.contexts?.trace?.data as any)?.["url.path"] === "/tracing-test"
      );

      expect(mountTransactions.length).toBeGreaterThan(0);

      const mountTransaction = mountTransactions[0] as TransactionWithSpans;
      const traceContext = mountTransaction.contexts?.trace;
      expect(traceContext).toBeDefined();
      expect(traceContext?.trace_id).toMatch(/^[a-f0-9]{32}$/);
      expect(traceContext?.span_id).toMatch(/^[a-f0-9]{16}$/);
      expect(traceContext?.op).toBe("http.server");

      expect(mountTransaction.spans).toBeDefined();
      expect(mountTransaction.spans!.length).toBeGreaterThan(0);

      const hierarchyResult = validateSpanHierarchy(mountTransaction);
      expect(hierarchyResult.errors).toEqual([]);
      expect(hierarchyResult.valid).toBe(true);

      for (const span of mountTransaction.spans!) {
        expect(span.trace_id).toBe(traceContext?.trace_id);
      }
    });

    test("LiveView WebSocket connection creates transaction with valid trace context", async ({ page }) => {
      await page.goto(`${PHOENIX_URL}/tracing-test`);

      await expect(page.locator("#tracing-test-live h1")).toContainText("LiveView Tracing Test");
      await expect(page.locator("#increment-btn")).toBeVisible();

      await page.click("#increment-btn");
      await expect(page.locator("#counter-value")).toHaveText("1");

      const logged = await waitForEvents(
        (events) =>
          events.events.some(
            (e) =>
              e.type === "transaction" &&
              (e.contexts?.trace?.data as any)?.["url.path"]?.includes("/live/websocket")
          ),
        { timeout: 10000 }
      );

      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );

      const websocketTransactions = transactionEvents.filter(
        (event) =>
          (event.contexts?.trace?.data as any)?.["url.path"]?.includes("/live/websocket")
      ) as TransactionWithSpans[];

      expect(websocketTransactions.length).toBeGreaterThan(0);

      for (const transaction of websocketTransactions) {
        const traceContext = transaction.contexts?.trace;
        expect(traceContext).toBeDefined();
        expect(traceContext?.trace_id).toMatch(/^[a-f0-9]{32}$/);
        expect(traceContext?.span_id).toMatch(/^[a-f0-9]{16}$/);

        const hierarchyResult = validateSpanHierarchy(transaction);
        expect(hierarchyResult.errors).toEqual([]);
        expect(hierarchyResult.valid).toBe(true);
      }
    });

    test("LiveView page mount has child spans, WebSocket transactions are independent", async ({ page }) => {
      await page.goto(`${PHOENIX_URL}/tracing-test`);

      await expect(page.locator("#tracing-test-live h1")).toContainText("LiveView Tracing Test");
      await expect(page.locator("#counter-value")).toHaveText("0");

      await page.click("#increment-btn");
      await expect(page.locator("#counter-value")).toHaveText("1");

      const logged = await waitForEvents(
        (events) => {
          const transactions = events.events.filter((e) => e.type === "transaction");
          const hasMount = transactions.some(
            (e) =>
              (e.contexts?.trace?.data as any)?.["url.path"] === "/tracing-test" ||
              e.transaction?.includes("/tracing-test")
          );
          const hasWebsocket = transactions.some(
            (e) => (e.contexts?.trace?.data as any)?.["url.path"]?.includes("/live/websocket")
          );
          return hasMount && hasWebsocket;
        },
        { timeout: 10000 }
      );

      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );

      const mountTransactions = transactionEvents.filter(
        (event) =>
          event.transaction?.includes("/tracing-test") ||
          (event.contexts?.trace?.data as any)?.["url.path"] === "/tracing-test"
      ) as TransactionWithSpans[];

      const websocketTransactions = transactionEvents.filter(
        (event) =>
          (event.contexts?.trace?.data as any)?.["url.path"]?.includes("/live/websocket")
      ) as TransactionWithSpans[];

      expect(mountTransactions.length).toBeGreaterThan(0);
      expect(websocketTransactions.length).toBeGreaterThan(0);

      const mountTransaction = mountTransactions[0];
      const websocketTransaction = websocketTransactions[0];

      const mountTraceId = mountTransaction.contexts?.trace?.trace_id;
      const mountSpanId = mountTransaction.contexts?.trace?.span_id;
      const wsTraceContext = websocketTransaction.contexts?.trace;

      expect(mountTraceId).toMatch(/^[a-f0-9]{32}$/);
      expect(mountSpanId).toMatch(/^[a-f0-9]{16}$/);
      expect(wsTraceContext?.trace_id).toMatch(/^[a-f0-9]{32}$/);
      expect(wsTraceContext?.span_id).toMatch(/^[a-f0-9]{16}$/);

      // Mount transaction should have child spans
      expect(mountTransaction.spans).toBeDefined();
      expect(mountTransaction.spans!.length).toBeGreaterThan(0);
      const mountHierarchy = validateSpanHierarchy(mountTransaction);
      expect(mountHierarchy.errors).toEqual([]);

      // WebSocket hierarchy must be valid (may have 0 spans for simple events)
      const wsHierarchy = validateSpanHierarchy(websocketTransaction);
      expect(wsHierarchy.errors).toEqual([]);
    });

    test("LiveView handles navigation (handle_params) creates valid transactions", async ({ page }) => {
      await page.goto(`${PHOENIX_URL}/tracing-test`);

      await expect(page.locator("#tracing-test-live h1")).toContainText("LiveView Tracing Test");
      await expect(page.locator("#params-link")).toBeVisible();

      await page.click("#params-link");

      await expect(page.locator("#last-action")).toHaveText("handle_params:param_change");

      const logged = await waitForEvents(
        (events) => events.events.filter((e) => e.type === "transaction").length >= 1,
        { timeout: 10000 }
      );

      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      ) as TransactionWithSpans[];

      expect(transactionEvents.length).toBeGreaterThan(0);

      for (const transaction of transactionEvents) {
        const traceContext = transaction.contexts?.trace;
        expect(traceContext).toBeDefined();
        expect(traceContext?.trace_id).toMatch(/^[a-f0-9]{32}$/);
        expect(traceContext?.span_id).toMatch(/^[a-f0-9]{16}$/);

        const hierarchyResult = validateSpanHierarchy(transaction);
        expect(hierarchyResult.errors).toEqual([]);
        expect(hierarchyResult.valid).toBe(true);
      }
    });

    test("LiveView events produce transactions with properly nested DB spans", async ({ page }) => {
      await page.goto(`${PHOENIX_URL}/tracing-test`);

      await expect(page.locator("#tracing-test-live h1")).toContainText("LiveView Tracing Test");

      await page.click("#increment-btn");
      await expect(page.locator("#counter-value")).toHaveText("1");

      await page.click("#increment-btn");
      await expect(page.locator("#counter-value")).toHaveText("2");

      await page.click("#fetch-data-btn");
      await expect(page.locator("#last-action")).toHaveText("fetch_data");
      await expect(page.locator("#data-value")).toBeVisible();

      const logged = await waitForEvents(
        (events) =>
          events.events.some(
            (e) =>
              e.type === "transaction" &&
              (e as TransactionWithSpans).spans?.some((s: Span) => s.op === "db")
          ),
        { timeout: 10000 }
      );

      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );

      expect(transactionEvents.length).toBeGreaterThan(0);

      const transactionsWithDbSpans = transactionEvents.filter((t) => {
        const spans = (t as TransactionWithSpans).spans || [];
        return spans.some((s: Span) => s.op === "db");
      }) as TransactionWithSpans[];

      expect(transactionsWithDbSpans.length).toBeGreaterThan(0);

      const transaction = transactionsWithDbSpans[0];
      const traceContext = transaction.contexts?.trace;
      const rootSpanId = traceContext?.span_id;
      const traceId = traceContext?.trace_id;

      const hierarchyResult = validateSpanHierarchy(transaction);
      expect(hierarchyResult.errors).toEqual([]);
      expect(hierarchyResult.valid).toBe(true);

      const dbSpans = transaction.spans!.filter((s: Span) => s.op === "db");
      expect(dbSpans.length).toBeGreaterThan(0);

      for (const dbSpan of dbSpans) {
        expect(dbSpan.span_id).toMatch(/^[a-f0-9]{16}$/);
        expect(dbSpan.trace_id).toBe(traceId);
        expect(dbSpan.parent_span_id).toBeDefined();
        expect(dbSpan.parent_span_id).toMatch(/^[a-f0-9]{16}$/);

        const validParentIds = new Set([rootSpanId, ...transaction.spans!.map((s) => s.span_id)]);
        expect(validParentIds.has(dbSpan.parent_span_id!)).toBe(true);
      }

      const directChildren = getDirectChildSpans(transaction);
      expect(directChildren.length).toBeGreaterThan(0);
    });

    test("LiveView handle_event records transaction with Ecto spans in correct hierarchy", async ({ page }) => {
      await page.goto(`${PHOENIX_URL}/tracing-test`);
      await expect(page.locator("#tracing-test-live h1")).toContainText("LiveView Tracing Test");

      await expect(page.locator("#fetch-data-btn")).toBeVisible();

      clearLoggedEvents();

      await page.click("#fetch-data-btn");
      await expect(page.locator("#last-action")).toHaveText("fetch_data", { timeout: 10000 });
      await expect(page.locator("#data-value")).toBeVisible();

      const logged = await waitForEvents(
        (events) =>
          events.events.some(
            (e) =>
              e.type === "transaction" &&
              (e as TransactionWithSpans).spans?.some((s: Span) => s.op === "db")
          ),
        { timeout: 10000 }
      );

      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );

      expect(transactionEvents.length).toBeGreaterThan(0);

      const transactionsWithDbSpans = transactionEvents.filter((t) => {
        const spans = (t as TransactionWithSpans).spans || [];
        return spans.some((s: Span) => s.op === "db");
      }) as TransactionWithSpans[];

      expect(transactionsWithDbSpans.length).toBeGreaterThan(0);

      const dbTransaction = transactionsWithDbSpans[0];
      const traceContext = dbTransaction.contexts?.trace;
      expect(traceContext).toBeDefined();

      // Validate complete span hierarchy
      const hierarchyResult = validateSpanHierarchy(dbTransaction);
      expect(hierarchyResult.errors).toEqual([]);
      expect(hierarchyResult.valid).toBe(true);
      expect(hierarchyResult.spanCount).toBeGreaterThan(0);
      expect(hierarchyResult.orphanedSpans).toEqual([]);

      const dbSpans = dbTransaction.spans!.filter((s: Span) => s.op === "db");
      expect(dbSpans.length).toBeGreaterThan(0);

      const dbSpan = dbSpans[0];
      expect(dbSpan.span_id).toMatch(/^[a-f0-9]{16}$/);
      expect(dbSpan.trace_id).toMatch(/^[a-f0-9]{32}$/);
      expect(dbSpan.parent_span_id).toBeDefined();
      expect(dbSpan.parent_span_id).toMatch(/^[a-f0-9]{16}$/);
      expect(dbSpan.op).toBe("db");

      expect(dbSpan.trace_id).toBe(traceContext?.trace_id);

      const allSpanIds = new Set([
        traceContext?.span_id,
        ...dbTransaction.spans!.map((s) => s.span_id),
      ]);
      expect(allSpanIds.has(dbSpan.parent_span_id!)).toBe(true);
    });
  });
});
