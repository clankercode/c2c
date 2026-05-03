import { test, expect } from "@playwright/test";

/**
 * Test: Compose Bar UI presence
 * Verifies the compose bar is present in the DOM with expected sub-elements.
 */
test("compose bar renders with expected elements", async ({ page }) => {
  await page.goto("/");

  // Header should be visible
  await expect(page.getByText("c2c")).toBeVisible();

  // Compose bar should be visible (at the bottom of the app)
  const composeArea = page.locator('textarea[placeholder*="message"]');
  await expect(composeArea).toBeVisible();

  // The "to" input should be present
  const toInput = page.locator('input[placeholder*="alias or room-id"]');
  await expect(toInput).toBeVisible();

  // Send button should be present
  const sendBtn = page.getByRole("button", { name: "Send" });
  await expect(sendBtn).toBeVisible();

  // Send button should be disabled when no target/message is filled
  await expect(sendBtn).toBeDisabled();
});

/**
 * Test: Room sidebar section visible
 * Verifies the sidebar shows Rooms and Peers sections.
 */
test("sidebar shows rooms and peers sections", async ({ page }) => {
  await page.goto("/");

  // Sidebar sections
  await expect(page.getByText("Rooms")).toBeVisible();
  await expect(page.getByText("Peers")).toBeVisible();

  // Join room input should be present
  const joinInput = page.locator('input[placeholder="room-id"]');
  await expect(joinInput).toBeVisible();
});
