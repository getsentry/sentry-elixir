import { expect } from "@playwright/test";
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

export function expectValidSampleRand(sampleRand: string | undefined): void {
  expect(sampleRand).toBeDefined();
  expect(sampleRand).toMatch(/^\d+\.\d+$/);

  const value = parseFloat(sampleRand!);
  expect(value).toBeGreaterThanOrEqual(0.0);
  expect(value).toBeLessThan(1.0);
}

export function expectDscInEnvelopeHeaders() {
  const { envelopes } = getLoggedEvents();

  const envelopesWithDsc = envelopes.filter(
    (envelope) => envelope.headers?.trace
  );

  expect(envelopesWithDsc.length).toBeGreaterThan(0);

  const dscMetadata = envelopesWithDsc.map(
    (envelope) => envelope.headers.trace
  );

  const envelopesWithSampleRand = dscMetadata.filter((dsc) => dsc?.sample_rand);
  expect(envelopesWithSampleRand.length).toBeGreaterThan(0);

  envelopesWithSampleRand.forEach((dsc) => {
    expectValidSampleRand(dsc?.sample_rand);
  });

  return dscMetadata;
}

export function getHttpServerTransactionsWithHeaders(): SentryEvent[] {
  const { events } = getLoggedEvents();

  const transactionEvents = events.filter(
    (event) => event.type === "transaction"
  );
  expect(transactionEvents.length).toBeGreaterThan(0);

  const httpServerTransactions = transactionEvents.filter(
    (event) => event.contexts?.trace?.op === "http.server"
  );
  expect(httpServerTransactions.length).toBeGreaterThan(0);

  const transactionsWithHeaders = httpServerTransactions.filter(
    (transaction) => {
      const headers = transaction.request?.headers;
      return headers && (headers["Sentry-Trace"] || headers["sentry-trace"]);
    }
  );
  expect(transactionsWithHeaders.length).toBeGreaterThan(0);

  return transactionsWithHeaders;
}
