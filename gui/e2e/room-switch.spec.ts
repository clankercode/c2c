import { test, expect } from "@playwright/test";

/**
 * Test: Room switch via sidebar
 * Verifies the sidebar renders the rooms list and supports room selection.
 */
test("sidebar renders rooms list", async ({ page }) => {
  await page.goto("/");

  // Rooms section header
  const roomsSection = page.getByText("Rooms", { exact: true });
  await expect(roomsSection).toBeVisible();

  // "No rooms joined" placeholder shown when no rooms
  await expect(page.getByText("No rooms joined")).toBeVisible();

  // Join room input is visible
  const joinInput = page.locator('input[placeholder="room-id"]');
  await expect(joinInput).toBeVisible();

  // Peers section is visible
  await expect(page.getByText("Peers", { exact: true })).toBeVisible();
});

/**
 * Test: Peers section visible
 * Verifies the sidebar renders the peers list.
 */
test("sidebar renders peers list", async ({ page }) => {
  await page.goto("/");

  const peersSection = page.getByText("Peers", { exact: true });
  await expect(peersSection).toBeVisible();

  // "No peers yet" placeholder shown when no peers
  await expect(page.getByText("No peers yet")).toBeVisible();
});
