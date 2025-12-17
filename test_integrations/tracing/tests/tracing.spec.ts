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
});
