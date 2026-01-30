import fs from "fs";
import path from "path";

const DEBUG_LOG_PATH = path.join(
  process.cwd(),
  "..",
  "phoenix_app",
  "tmp",
  "sentry_debug_events.log"
);

export interface SentryEvent {
  type?: string;
  transaction?: string;
  exception?: Array<{
    type: string;
    value: string;
  }>;
  contexts?: {
    trace?: {
      trace_id?: string;
      span_id?: string;
      parent_span_id?: string;
      op?: string;
      data?: Record<string, any>;
    };
  };
  _meta?: {
    dsc?: {
      sample_rand?: string;
    };
  };
  request?: {
    headers?: Record<string, string>;
  };
}

export interface SentryEnvelope {
  headers: {
    trace?: {
      trace_id?: string;
      sample_rate?: string;
      sample_rand?: string;
      sampled?: string;
      environment?: string;
      public_key?: string;
      [key: string]: any;
    };
  };
  items: SentryEvent[];
}

export interface LoggedEvents {
  events: SentryEvent[];
  envelopes: SentryEnvelope[];
  event_count: number;
}

export function getLoggedEvents(): LoggedEvents {
  const events: SentryEvent[] = [];
  const envelopes: SentryEnvelope[] = [];

  if (!fs.existsSync(DEBUG_LOG_PATH)) {
    return { events: [], envelopes: [], event_count: 0 };
  }

  const content = fs.readFileSync(DEBUG_LOG_PATH, "utf-8");
  const lines = content
    .trim()
    .split("\n")
    .filter((line) => line.trim());

  for (const line of lines) {
    try {
      const data = JSON.parse(line);

      // Check if it's an envelope format
      if (data.headers) {
        envelopes.push(data as SentryEnvelope);
        if (data.items) {
          events.push(...data.items);
        }
      } else {
        // Individual event
        events.push(data as SentryEvent);
      }
    } catch (e) {
      // Skip malformed lines
    }
  }

  return { events, envelopes, event_count: events.length };
}

export function clearLoggedEvents(): void {
  if (fs.existsSync(DEBUG_LOG_PATH)) {
    fs.writeFileSync(DEBUG_LOG_PATH, "");
  }
}

/**
 * Poll for events matching a condition until found or timeout.
 * Replaces flaky waitForTimeout calls with deterministic polling.
 */
export async function waitForEvents(
  predicate: (events: LoggedEvents) => boolean,
  options: { timeout?: number; interval?: number } = {}
): Promise<LoggedEvents> {
  const { timeout = 10000, interval = 200 } = options;
  const startTime = Date.now();

  while (Date.now() - startTime < timeout) {
    const logged = getLoggedEvents();
    if (predicate(logged)) {
      return logged;
    }
    await new Promise((resolve) => setTimeout(resolve, interval));
  }

  // Return final state even if predicate not satisfied (let test assertions fail with actual data)
  return getLoggedEvents();
}

/**
 * Wait for a specific number of transactions to be logged.
 */
export async function waitForTransactions(
  minCount: number,
  options: { timeout?: number; interval?: number } = {}
): Promise<SentryEvent[]> {
  const logged = await waitForEvents(
    (events) =>
      events.events.filter((e) => e.type === "transaction").length >= minCount,
    options
  );
  return logged.events.filter((e) => e.type === "transaction");
}

export interface Span {
  span_id: string;
  trace_id: string;
  parent_span_id?: string;
  op?: string;
  description?: string;
  data?: Record<string, any>;
}

export interface TransactionWithSpans extends SentryEvent {
  spans?: Span[];
}

/**
 * Validates that all spans in a transaction have valid parent references.
 * Returns an object with validation results and any errors found.
 */
export function validateSpanHierarchy(transaction: TransactionWithSpans): {
  valid: boolean;
  rootSpanId: string | undefined;
  traceId: string | undefined;
  errors: string[];
  spanCount: number;
  orphanedSpans: Span[];
} {
  const errors: string[] = [];
  const orphanedSpans: Span[] = [];
  const traceContext = transaction.contexts?.trace;
  const rootSpanId = traceContext?.span_id;
  const traceId = traceContext?.trace_id;
  const spans = transaction.spans || [];

  // Collect all valid span IDs in this transaction (including root)
  const validSpanIds = new Set<string>();
  if (rootSpanId) {
    validSpanIds.add(rootSpanId);
  }
  for (const span of spans) {
    if (span.span_id) {
      validSpanIds.add(span.span_id);
    }
  }

  // Validate each span
  for (const span of spans) {
    // All spans must have the same trace_id
    if (span.trace_id !== traceId) {
      errors.push(
        `Span ${span.span_id} has trace_id ${span.trace_id}, expected ${traceId}`
      );
    }

    // All spans must have a parent_span_id that exists in this transaction
    if (!span.parent_span_id) {
      errors.push(`Span ${span.span_id} (${span.op}) has no parent_span_id`);
      orphanedSpans.push(span);
    } else if (!validSpanIds.has(span.parent_span_id)) {
      errors.push(
        `Span ${span.span_id} (${span.op}) has parent_span_id ${span.parent_span_id} which does not exist in transaction`
      );
      orphanedSpans.push(span);
    }
  }

  return {
    valid: errors.length === 0,
    rootSpanId,
    traceId,
    errors,
    spanCount: spans.length,
    orphanedSpans,
  };
}

/**
 * Checks if a span is a direct child of the root transaction span.
 */
export function isDirectChildOfRoot(
  span: Span,
  transaction: TransactionWithSpans
): boolean {
  const rootSpanId = transaction.contexts?.trace?.span_id;
  return span.parent_span_id === rootSpanId;
}

/**
 * Gets all spans that are direct children of the root span.
 */
export function getDirectChildSpans(
  transaction: TransactionWithSpans
): Span[] {
  const rootSpanId = transaction.contexts?.trace?.span_id;
  const spans = transaction.spans || [];
  return spans.filter((span) => span.parent_span_id === rootSpanId);
}

/**
 * Builds a map of parent_span_id -> child spans for hierarchy traversal.
 */
export function buildSpanTree(
  transaction: TransactionWithSpans
): Map<string, Span[]> {
  const tree = new Map<string, Span[]>();
  const spans = transaction.spans || [];

  for (const span of spans) {
    const parentId = span.parent_span_id || "root";
    if (!tree.has(parentId)) {
      tree.set(parentId, []);
    }
    tree.get(parentId)!.push(span);
  }

  return tree;
}
