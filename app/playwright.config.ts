import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  // Two runs, two bundles. `pnpm test:ui` builds the OSS app and covers the
  // public flows; `pnpm test:ui:saas` sets VITE_SAAS and covers the gitignored
  // cloud UI, which starts behind a full-window sign-in gate the OSS specs know
  // nothing about. A public checkout has no `tests/ui/saas/` at all, and a
  // private one must not run it against the OSS bundle.
  testDir: process.env.VITE_SAAS ? './tests/ui/saas' : './tests/ui',
  testIgnore: process.env.VITE_SAAS ? [] : ['**/saas/**'],
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  use: { baseURL: 'http://127.0.0.1:1421', trace: 'retain-on-failure', screenshot: 'only-on-failure' },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
  webServer: { command: 'pnpm dev:ui-fixtures --host 127.0.0.1 --port 1421', url: 'http://127.0.0.1:1421', reuseExistingServer: false },
});
