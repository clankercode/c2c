import { test, expect } from "@playwright/test";

/**
 * Test 1: App Load
 * Verifies the GUI loads without crashing and shows the c2c header + connecting state.
 */
test("app loads and shows connecting status", async ({ page }) => {
  await page.goto("/");

  // Header should show c2c branding
  await expect(page.getByText("c2c")).toBeVisible();

  // Status indicator should be present (connecting/live/error)
  const statusEl = page.getByText(/\u25CF/); // ● bullet character
  await expect(statusEl).toBeVisible();
});

/**
 * Test 2: App Load — Welcome Wizard
 * On first visit (no localStorage alias), the welcome wizard should appear.
 */
test("shows welcome wizard on first visit (no stored alias)", async ({ page }) => {
  // Clear localStorage to simulate first visit
  await page.goto("/");
  await page.evaluate(() => localStorage.clear());
  await page.reload();

  // WelcomeWizard should be open
  const wizard = page.getByText("Welcome to c2c").or(page.getByText("Set your alias")).or(page.locator("input[placeholder*='alias']"));
  await expect(wizard.first()).toBeVisible();
});
