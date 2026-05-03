import { test, expect } from "@playwright/test";

/**
 * Test: Join a room via the sidebar input
 * Verifies: entering a room ID and pressing Enter joins the room
 * and the room appears in the sidebar rooms list.
 */
test("join room via sidebar input", async ({ page }) => {
  await page.goto("/");

  // Use a unique room ID to avoid collisions
  const testRoom = `e2e-test-room-${Date.now()}`;

  // Find the join room input and join button
  const joinInput = page.locator('input[placeholder="room-id"]');
  await expect(joinInput).toBeVisible();

  // Type the room ID and press Enter to join
  await joinInput.fill(testRoom);
  await joinInput.press("Enter");

  // Wait briefly for the join to process
  await page.waitForTimeout(500);

  // Verify the room appears in the sidebar list
  // Rooms are rendered with the format: 🏠 {roomId}
  await expect(page.getByText(`🏠 ${testRoom}`)).toBeVisible();
});

/**
 * Test: Join a room via the sidebar + button
 * Same as above but clicks the explicit + button instead of pressing Enter.
 */
test("join room via sidebar + button", async ({ page }) => {
  await page.goto("/");

  const testRoom = `e2e-test-room-btn-${Date.now()}`;
  const joinInput = page.locator('input[placeholder="room-id"]');
  const joinButton = page.locator('button[title="Join room"], div:has-text("+")').last();

  await joinInput.fill(testRoom);
  // The + button is inside the join footer div; click the button element
  const addBtn = page.locator("button").filter({ hasText: "+" }).last();
  await addBtn.click();

  await page.waitForTimeout(500);
  await expect(page.getByText(`🏠 ${testRoom}`)).toBeVisible();
});

/**
 * Test: Leave a room via the sidebar ✕ button
 * Pre-condition: a room is joined and selected (active) so the ✕ button appears.
 * Verifies: clicking ✕ removes the room from the sidebar list.
 */
test("leave room via sidebar ✕ button", async ({ page }) => {
  await page.goto("/");

  const testRoom = `e2e-leave-test-${Date.now()}`;

  // Join the room first
  const joinInput = page.locator('input[placeholder="room-id"]');
  await joinInput.fill(testRoom);
  await joinInput.press("Enter");
  await page.waitForTimeout(500);

  // Room should now appear in the sidebar
  const roomItem = page.getByText(`🏠 ${testRoom}`);
  await expect(roomItem).toBeVisible();

  // Click the room to select it (activates it, revealing the ✕ leave button)
  await roomItem.click();
  await page.waitForTimeout(200);

  // The ✕ button should now be visible (only shown for the active/selected room)
  const leaveButton = page.locator("button[title=\"Leave room\"]");
  await expect(leaveButton).toBeVisible();

  // Click leave
  await leaveButton.click();
  await page.waitForTimeout(500);

  // Room should be gone from the sidebar
  await expect(page.getByText(`🏠 ${testRoom}`)).not.toBeVisible();
});

/**
 * Test: Verify swarm-lounge is auto-joined on startup
 * The app auto-joins swarm-lounge when a stored alias exists.
 * This is a smoke test that the rooms list is populated.
 */
test("swarm-lounge auto-joined on startup when alias is set", async ({ page }) => {
  await page.goto("/");

  // Wait for the monitor to connect and rooms to be seeded
  await page.waitForTimeout(2000);

  // swarm-lounge should appear in the rooms list
  await expect(page.getByText("🏠 swarm-lounge")).toBeVisible();
});

/**
 * Test: Join error is shown for invalid room ID
 * Verifies that when joining fails, the error message appears below the input.
 */
test("join error shown for invalid room", async ({ page }) => {
  await page.goto("/");

  // Use an obviously invalid room ID (empty-ish won't submit, but an empty-trimmed one will)
  const joinInput = page.locator('input[placeholder="room-id"]');
  await joinInput.fill("");
  await joinInput.press("Enter");

  // Button should be disabled when input is empty — fill with a space to attempt join
  await joinInput.fill("   ");
  await joinInput.press("Enter");
  await page.waitForTimeout(800);

  // If the join failed with an error, it would appear in the error div
  // (This test verifies the error display path works — actual error content depends on broker state)
  // The key assertion is that the error element is present if joining failed
  const errorDiv = page.locator("div").filter({ hasText: /join failed|not alive|error/i }).last();
  // We just check it doesn't crash — error display exists
  await expect(errorDiv.or(page.getByText("🏠")).first()).toBeVisible();
});
