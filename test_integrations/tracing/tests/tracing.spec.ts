import { test, expect } from "@playwright/test";
import { clearLoggedEvents, getLoggedEvents } from "./helpers";

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

    // Wait for events to be logged
    await page.waitForTimeout(2000);

    const logged = getLoggedEvents();
    console.log("Test 1 - Total events:", logged.event_count);
    console.log(
      "Test 1 - All transactions:",
      logged.events
        .filter((e) => e.type === "transaction")
        .map((e) => e.transaction)
    );
    expect(logged.event_count).toBeGreaterThan(0);

    // Check for error events
    const errorEvents = logged.events.filter((event) => event.exception);
    expect(errorEvents.length).toBeGreaterThan(0);

    const errorEvent = errorEvents[errorEvents.length - 1];
    // In Sentry, exception is directly an array, not exception.values
    const exceptionValues = errorEvent.exception;
    expect(exceptionValues).toBeDefined();
    expect(exceptionValues!.length).toBeGreaterThan(0);
    expect(exceptionValues![0].type).toBe("ArithmeticError");

    // Check trace context
    // NOTE: Error events captured via Logger don't have trace context
    // Only transactions have trace context from OpenTelemetry

    // Check for transaction events
    const transactionEvents = logged.events.filter(
      (event) => event.type === "transaction"
    );
    expect(transactionEvents.length).toBeGreaterThan(0);

    // Validate that transactions have proper OpenTelemetry trace context
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

      // Validate OpenTelemetry semantic data
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

      // Wait for events to be logged
      await page.waitForTimeout(2000);

      const logged = getLoggedEvents();

      // Debug: log all events
      console.log("Total events:", logged.event_count);
      console.log(
        "All transactions:",
        logged.events
          .filter((e) => e.type === "transaction")
          .map((e) => e.transaction)
      );

      // Check for transaction events
      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );
      expect(transactionEvents.length).toBeGreaterThan(0);

      // Find the error transaction (transaction name is "GET /error")
      const errorTransaction = transactionEvents.find(
        (event) =>
          event.transaction?.includes("/error") ||
          event.transaction?.includes("GET")
      );
      expect(errorTransaction).toBeDefined();

      // Validate trace context
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

      // Trigger error 3 times - all should be part of the same distributed trace
      for (let i = 0; i < 3; i++) {
        await page.click("button#trigger-error-btn");
        await page.waitForTimeout(100);
      }

      await expect(page.locator(".result")).toContainText("Error:");

      // Wait for events to be logged
      await page.waitForTimeout(2000);

      const logged = getLoggedEvents();

      // Get all transaction events
      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );

      // Filter for error transactions (transaction name is "GET /error")
      const errorTransactions = transactionEvents.filter((event) =>
        event.transaction?.includes("/error")
      );

      // We should have at least 3 error transactions
      expect(errorTransactions.length).toBeGreaterThanOrEqual(3);

      // Extract trace IDs
      const traceIds = errorTransactions
        .map((t) => t.contexts?.trace?.trace_id)
        .filter(Boolean);

      // All should have valid trace IDs
      expect(traceIds.length).toBeGreaterThanOrEqual(3);
      traceIds.forEach((traceId) => {
        expect(traceId).toMatch(/^[a-f0-9]{32}$/);
      });

      // With distributed tracing, all requests from the same page load
      // should share the SAME trace ID (from the frontend)
      const uniqueTraceIds = [...new Set(traceIds)];
      expect(uniqueTraceIds.length).toBe(1);

      // All transactions should have parent_span_id set (proving they're
      // continuing a trace from the frontend, not starting new ones)
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

      // Make a request that includes database operations and nested spans
      await page.evaluate(async () => {
        const response = await fetch("http://localhost:4000/api/data", {
          method: "GET",
          headers: {
            "Content-Type": "application/json",
          },
        });
        return response.json();
      });

      // Wait for events to be logged
      await page.waitForTimeout(2000);

      const logged = getLoggedEvents();

      // Get transaction events for the /api/data endpoint
      const transactionEvents = logged.events.filter(
        (event) => event.type === "transaction"
      );
      expect(transactionEvents.length).toBeGreaterThan(0);

      // Look for transactions related to the /api/data endpoint
      // Transaction name is "GET /api/data" from OpenTelemetry Phoenix
      const dataTransactions = transactionEvents.filter(
        (event) =>
          event.transaction?.includes("/api/data") ||
          event.transaction?.includes("fetch_data") ||
          (event.contexts?.trace?.data as any)?.["http.route"] === "/api/data"
      );

      expect(dataTransactions.length).toBeGreaterThan(0);

      // Test the distributed tracing transaction
      const dataTransaction = dataTransactions[0];

      // Verify it has a parent span ID (from distributed tracing)
      expect(dataTransaction.contexts?.trace?.parent_span_id).toBeDefined();
      expect(dataTransaction.contexts?.trace?.parent_span_id).toMatch(
        /^[a-f0-9]{16}$/
      );

      // THIS IS THE KEY TEST: Verify child spans exist and have detailed data
      const spans = (dataTransaction as any).spans;
      expect(spans).toBeDefined();
      expect(spans.length).toBeGreaterThan(0);

      // Verify each span has proper structure and data
      spans.forEach((span: any) => {
        expect(span.span_id).toBeDefined();
        expect(span.span_id).toMatch(/^[a-f0-9]{16}$/);
        expect(span.trace_id).toBeDefined();
        expect(span.trace_id).toMatch(/^[a-f0-9]{32}$/);
        expect(span.op).toBeDefined();
        expect(span.description).toBeDefined();

        // Verify span has data attributes
        expect(span.data).toBeDefined();
        expect(typeof span.data).toBe("object");

        // At minimum, spans should have otel.kind
        expect(span.data["otel.kind"]).toBeDefined();
      });

      // Check for database spans specifically - they should have detailed DB info
      const dbSpans = spans.filter((span: any) => span.op === "db");
      expect(dbSpans.length).toBeGreaterThan(0);

      // Verify DB spans have detailed query information
      dbSpans.forEach((dbSpan: any) => {
        // Should have db.system
        expect(dbSpan.data["db.system"]).toBeDefined();

        // Should have SQL query in description
        expect(dbSpan.description).toBeDefined();
        expect(dbSpan.description.length).toBeGreaterThan(0);

        // For SQLite, should see SELECT queries
        expect(dbSpan.description).toMatch(/SELECT/i);

        // Should have db.statement with the actual SQL
        expect(dbSpan.data["db.statement"]).toBeDefined();
        expect(dbSpan.data["db.statement"]).toMatch(/SELECT/i);
      });
    });
  });
});
