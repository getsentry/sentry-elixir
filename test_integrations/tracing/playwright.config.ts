import { defineConfig, devices } from "@playwright/test";

const PHOENIX_URL =
  process.env.SENTRY_E2E_PHOENIX_APP_URL || "http://localhost:4000";
const SVELTE_URL =
  process.env.SENTRY_E2E_SVELTE_APP_URL || "http://localhost:4001";

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

  webServer: [
    {
      command:
        'cd ../phoenix_app && rm -f tmp/sentry_debug_events.log && SENTRY_E2E_TEST_MODE=true SENTRY_DSN="https://user:secret@sentry.localdomain/42" mix phx.server',
      url: `${PHOENIX_URL}/health`,
      reuseExistingServer: !process.env.CI,
      timeout: 30000,
    },
    {
      command:
        'cd svelte_mini && SENTRY_DSN="https://user:secret@sentry.localdomain/42" SENTRY_E2E_PHOENIX_APP_URL="http://localhost:4000" SENTRY_E2E_SVELTE_APP_PORT=4001 npm run dev',
      url: `${SVELTE_URL}/health`,
      reuseExistingServer: !process.env.CI,
      timeout: 30000,
    },
  ],
});
