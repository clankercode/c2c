import { test, expect } from "@playwright/test";

/**
 * Test: Permissions panel — no badge when no pending permissions
 * Verifies the permissions panel doesn't show a badge when there are no pending permissions.
 */
test("permissions panel hidden when no pending permissions", async ({ page }) => {
  await page.goto("/");

  // When no pending permissions, the PermissionBadge should not render (count=0 → null)
  // The badge is a <span> with text like "1 permission" — it should not exist
  // Look for the badge text pattern (singular or plural)
  const badge = page.locator("span").filter({ hasText: /^\d+ permission/ });
  await expect(badge).toHaveCount(0);
});

/**
 * Test: Permissions panel — no badge text when there are no pending permissions
 * Verifies that "permission" count badge text is absent from the UI when pending=0.
 */
test("no permission badge text when no pending permissions", async ({ page }) => {
  await page.goto("/");

  // The permission badge only shows when there are pending permissions.
  // With 0 pending, no badge should be visible in the header or as a standalone badge.
  // This checks the app loaded cleanly and the permissions panel correctly
  // suppressed itself when there is nothing to approve.
  await expect(page.getByText("c2c")).toBeVisible();
  // Verify no pending permission badge is present (would show "1 permission" or "N permissions")
  await expect(page.locator("text=/\\d+ permission/")).toHaveCount(0);
});
