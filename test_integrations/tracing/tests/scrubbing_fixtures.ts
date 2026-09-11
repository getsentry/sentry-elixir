import type { SentryEvent } from "./helpers";

export const PLACEHOLDER = "*********";

export interface ProbeValues {
  pathSecret: string;
  queryToken: string;
  queryApiKey: string;
  upperCasePassword: string;
  substringPassword: string;
  configuredKey: string;
  password: string;
  benign: string;
}

export function probeValues(runId: string): ProbeValues {
  return {
    pathSecret: `pathsecret-${runId}`,
    queryToken: `qtoken-${runId}`,
    queryApiKey: `apikey-${runId}`,
    upperCasePassword: `upper-${runId}`,
    substringPassword: `substr-${runId}`,
    configuredKey: `cfgref-${runId}`,
    password: `pwd-${runId}`,
    benign: `keepme-${runId}`,
  };
}

function query(pairs: Array<[string, string] | [string]>): string {
  return pairs.map((pair) => pair.join("=")).join("&");
}

export function scrubbedQuery(values: ProbeValues, runId: string): string {
  return query([
    ["token", PLACEHOLDER],
    ["api_key", PLACEHOLDER],
    ["PASSWORD", PLACEHOLDER],
    ["user_password", PLACEHOLDER],
    ["internal_ref", PLACEHOLDER],
    ["password", PLACEHOLDER],
    ["keep", values.benign],
    ["note", "a%20b~c"],
    ["flag"],
    ["e2e_run", runId],
  ]);
}

export function demoPagePath(values: ProbeValues, runId: string): string {
  return `/scrubbing-demo?path_secret=${values.pathSecret}&${probeQuery(values, runId)}`;
}

function probeQuery(values: ProbeValues, runId: string): string {
  return query([
    ["token", values.queryToken],
    ["api_key", values.queryApiKey],
    ["PASSWORD", values.upperCasePassword],
    ["user_password", values.substringPassword],
    ["internal_ref", values.configuredKey],
    ["password", values.password],
    ["keep", values.benign],
    ["note", "a%20b~c"],
    ["flag"],
    ["e2e_run", runId],
  ]);
}

const CONN_FIELD_PATTERNS = {
  request_path: /request_path: "([^"]*)"/,
  path_info: /path_info: (\[[^\]]*\])/,
  path_params: /path_params: (%\{[^}]*\})/,
  query_string: /query_string: "([^"]*)"/,
  script_name: /script_name: (\[[^\]]*\])/,
} as const;

export interface ConnFields {
  requestPath: string;
  pathInfo: string[];
  pathParams: string;
  queryString: string;
  scriptName: string[];
}

function capture(value: string, field: keyof typeof CONN_FIELD_PATTERNS): string {
  const match = value.match(CONN_FIELD_PATTERNS[field]);

  if (!match) {
    throw new Error(
      `could not read ${field} out of the reported conn — has the inspect format changed?\n${value}`
    );
  }

  return match[1];
}

function members(list: string): string[] {
  return Array.from(list.matchAll(/"([^"]*)"/g), (match) => match[1]);
}

export function connFields(event: Record<string, any>): ConnFields {
  const value: string = event?.exception?.[0]?.value ?? "";

  return {
    requestPath: capture(value, "request_path"),
    pathInfo: members(capture(value, "path_info")),
    pathParams: capture(value, "path_params"),
    queryString: capture(value, "query_string"),
    scriptName: members(capture(value, "script_name")),
  };
}

export function isScrubbingEvent(event: SentryEvent): boolean {
  const anyEvent = event as Record<string, any>;
  return anyEvent?.exception?.[0]?.type === "Phoenix.ActionClauseError";
}
