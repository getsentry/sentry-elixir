import { test, expect, type Page } from "@playwright/test";
import { clearLoggedEvents, getLoggedEvents, waitForEvents } from "./helpers";
import {
  PLACEHOLDER,
  connFields,
  demoPagePath,
  isScrubbingEvent,
  probeValues,
  scrubbedQuery,
} from "./scrubbing_fixtures";

const PHOENIX_URL = process.env.SENTRY_E2E_PHOENIX_APP_URL;
if (!PHOENIX_URL) {
  throw new Error(
    "Required environment variable SENTRY_E2E_PHOENIX_APP_URL is not set."
  );
}

const REAL_DSN = process.env.SENTRY_E2E_REAL_DSN === "true";
const ENVIRONMENT = process.env.SENTRY_ENVIRONMENT ?? "e2e-scrubbing";

if (REAL_DSN && !process.env.SENTRY_DSN) {
  throw new Error(
    "SENTRY_E2E_REAL_DSN=true needs SENTRY_DSN set, so the app it boots reports somewhere real."
  );
}

const RUN_ID = process.env.SENTRY_E2E_RUN_ID ?? `run-${Date.now()}`;
const VALUES = probeValues(RUN_ID);
const EXPECTED_QUERY = scrubbedQuery(VALUES, RUN_ID);

async function openDemoPage(page: Page): Promise<void> {
  await page.goto(`${PHOENIX_URL}${demoPagePath(VALUES, RUN_ID)}`);
  await expect(page.locator("#scrubbing-demo h1")).toContainText(
    "Reset your password"
  );
}

async function capturedEvent(): Promise<Record<string, any>> {
  const logged = await waitForEvents(
    (events) => events.events.some(isScrubbingEvent),
    { timeout: 15000 }
  );
  const event = logged.events.find(isScrubbingEvent) as
    | Record<string, any>
    | undefined;

  expect(event, "no ActionClauseError event was captured").toBeTruthy();

  return event!;
}

async function followLink(page: Page, id: string): Promise<void> {
  await openDemoPage(page);
  await page.click(`#${id}`);
}

async function submitResetForm(page: Page): Promise<void> {
  await openDemoPage(page);

  await page.fill("#token", VALUES.queryToken);
  await page.fill("#api_key", VALUES.queryApiKey);
  await page.fill("#upper_password", VALUES.upperCasePassword);
  await page.fill("#user_password", VALUES.substringPassword);
  await page.fill("#internal_ref", VALUES.configuredKey);
  await page.fill("#password", VALUES.password);

  await page.click("#submit-reset");
}

test.describe("parameter scrubbing", () => {
  test.skip(
    REAL_DSN,
    "asserts against the local envelope log, which only exists in SENTRY_E2E_TEST_MODE"
  );

  test.beforeEach(() => {
    clearLoggedEvents();
  });

  test("derives the conn's path and query from the scrubbed URL", async ({
    page,
  }) => {
    await followLink(page, "probe-link");
    const event = await capturedEvent();
    const conn = connFields(event);

    expect(conn.requestPath).toBe(
      `/scrubbing-demo/reset-password/${PLACEHOLDER}`
    );
    expect(conn.pathInfo).toEqual([
      "scrubbing-demo",
      "reset-password",
      PLACEHOLDER,
    ]);
    expect(event.request.url).toContain(
      `/scrubbing-demo/reset-password/${PLACEHOLDER}`
    );

    expect(conn.queryString).not.toContain(VALUES.queryToken);
    expect(conn.queryString).toContain(`keep=${VALUES.benign}`);
  });

  test("rebuilds path_info against script_name behind a forward", async ({
    page,
  }) => {
    await followLink(page, "forwarded-link");
    const event = await capturedEvent();
    const conn = connFields(event);

    expect(conn.scriptName).toEqual(["scrubbing-demo", "forwarded"]);
    expect(conn.pathInfo).toEqual(["reset-password", PLACEHOLDER]);
    expect(conn.requestPath).toBe(
      `/scrubbing-demo/forwarded/reset-password/${PLACEHOLDER}`
    );

    expect(`/${[...conn.scriptName, ...conn.pathInfo].join("/")}`).toBe(
      conn.requestPath
    );
  });

  test("scrubs the secret out of path params", async ({ page }) => {
    await followLink(page, "probe-link");
    const event = await capturedEvent();
    const conn = connFields(event);

    expect(conn.pathParams).toBe(`%{"token" => "${PLACEHOLDER}"}`);
    expect(
      JSON.stringify(event),
      "the path segment survived somewhere in the event"
    ).not.toContain(VALUES.pathSecret);
  });

  test("redacts what a submitted form carries", async ({ page }) => {
    await submitResetForm(page);
    const event = await capturedEvent();
    const data = event.request.data;

    expect(data.token, "a key the spec denylist adds").toBe(PLACEHOLDER);
    expect(data.api_key, "matched as a substring of `key`").toBe(PLACEHOLDER);
    expect(data.PASSWORD, "matched case-insensitively").toBe(PLACEHOLDER);
    expect(data.user_password, "matched as a substring").toBe(PLACEHOLDER);
    expect(data.internal_ref, "sensitive only by configuration").toBe(
      PLACEHOLDER
    );
    expect(data.password, "the long-standing default key").toBe(PLACEHOLDER);

    expect(data.keep, "a benign field must survive").toBe(VALUES.benign);

    const serialized = JSON.stringify(event);
    for (const [name, value] of Object.entries(VALUES)) {
      if (name === "benign") continue;
      expect(serialized, `${name} survived scrubbing`).not.toContain(value);
    }
  });

  test("redacts the page URL the browser sends as the referer", async ({
    page,
  }) => {
    await followLink(page, "probe-link");
    const event = await capturedEvent();

    const referer = event.request.headers.referer;

    expect(referer, "the referer header was not reported at all").toBeTruthy();
    expect(referer).toContain("/scrubbing-demo?");
    expect(referer).toContain(`token=${PLACEHOLDER}`);
    expect(referer).not.toContain(VALUES.queryToken);
    expect(referer).not.toContain(VALUES.pathSecret);
    expect(referer, "a benign param should survive").toContain(
      `keep=${VALUES.benign}`
    );
  });

  test("leaves the params it keeps exactly as they were sent", async ({
    page,
  }) => {
    await followLink(page, "probe-link");
    const event = await capturedEvent();
    const conn = connFields(event);

    expect(conn.queryString).toBe(EXPECTED_QUERY);
    expect(conn.queryString, "the placeholder was form-encoded").not.toContain(
      "%2A"
    );
    expect(event.request.query_string).not.toContain("%2A");
    expect(event.request.url).not.toContain("%2A");

    expect(conn.queryString).toContain("note=a%20b~c");
    expect(conn.queryString).toContain("&flag&");

    expect(event.request.url.split("?")[1]).toBe(EXPECTED_QUERY);
  });
});

test.describe("smoke run against a real project", () => {
  test.skip(
    !REAL_DSN,
    "set SENTRY_E2E_REAL_DSN=true and boot the app with a real SENTRY_DSN"
  );

  test("sends what the page's form and links produce", async ({ page }) => {
    test.setTimeout(120000);

    clearLoggedEvents();

    await followLink(page, "probe-link");
    await followLink(page, "forwarded-link");
    await submitResetForm(page);

    expect(
      getLoggedEvents().event_count,
      "the app logged envelopes locally instead of sending them — it is not booted against a real DSN"
    ).toBe(0);

    console.log(`\nsearch Sentry for: e2e_run:${RUN_ID}`);
    console.log(`environment: ${ENVIRONMENT}\n`);
  });
});
