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
