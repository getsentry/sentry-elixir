import { defineConfig, devices } from "@playwright/test";

const PHOENIX_URL =
  process.env.SENTRY_E2E_PHOENIX_APP_URL || "http://localhost:4000";
const SVELTE_URL =
  process.env.SENTRY_E2E_SVELTE_APP_URL || "http://localhost:4001";

// When servers are started externally (e.g., in CI workflow steps), skip webServer config
const serversRunningExternally = process.env.SENTRY_E2E_SERVERS_RUNNING === "true";

export default defineConfig({
  testDir: "./tests",
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,
  reporter: "list",

  use: {
    baseURL: SVELTE_URL,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },

  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        headless: true,
      },
    },
  ],

  // Skip webServer when servers are managed externally (better CI debugging)
  ...(serversRunningExternally
    ? {}
    : {
        webServer: [
          {
            command:
              'cd ../phoenix_app && rm -f tmp/sentry_debug_events.log && SENTRY_E2E_TEST_MODE=true mix phx.server',
            url: `${PHOENIX_URL}/health`,
            reuseExistingServer: true
          },
          {
            command:
              'cd svelte_mini && SENTRY_E2E_SVELTE_APP_PORT=4001 npm run dev',
            url: `${SVELTE_URL}/health`,
            reuseExistingServer: true
          },
        ],
      }),
});
