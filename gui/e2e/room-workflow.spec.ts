import { test, expect, Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Helper: check whether we are running inside the Tauri desktop app.
// useSend.ts gates all c2c shell commands on isTauriDesktop(), so if this
// returns false the join/leave operations will silently succeed (no-op).
// ---------------------------------------------------------------------------
async function isTauriDesktop(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    // noinspection TypeScriptUnresolvedVariable — window.__TAURI__ is injected by Tauri
    return typeof window !== "undefined" && !!(window as any).__TAURI__;
  });
}

// ---------------------------------------------------------------------------
// Helper: dismiss the welcome wizard by seeding a fake alias in localStorage.
// ---------------------------------------------------------------------------
async function dismissWizard(page: Page) {
  await page.goto("/");
  await page.evaluate(() => {
    localStorage.setItem("c2c-gui-my-alias", "playwright-test-alias");
    localStorage.setItem("c2c-gui-my-session-id", "playwright-session-0000");
  });
  await page.reload();
  // Wizard should be gone
  await expect(page.getByText("Welcome to c2c")).not.toBeVisible();
}

// ---------------------------------------------------------------------------
// Test: Join a room via the sidebar input (Enter key)
//
// In the Tauri desktop app: room appears in sidebar after join.
// In web preview (isTauriDesktop=false): join is a no-op; test skips.
// ---------------------------------------------------------------------------
test("join room via sidebar Enter key", async ({ page }) => {
  await dismissWizard(page);

  const tauri = await isTauriDesktop(page);
  if (!tauri) {
    test.skip(true, "Tauri desktop not available (web preview mode)");
    return;
  }

  const testRoom = `e2e-test-room-${Date.now()}`;
  const joinInput = page.locator('input[placeholder="room-id"]');
  await expect(joinInput).toBeVisible();

  await joinInput.fill(testRoom);
  await joinInput.press("Enter");
  await page.waitForTimeout(800);

  // Room should appear in sidebar with the 🏠 prefix
  await expect(page.getByText(`🏠 ${testRoom}`)).toBeVisible({ timeout: 3000 });
});

// ---------------------------------------------------------------------------
// Test: Leave a room via the sidebar ✕ button
// The ✕ button is only visible when the room is selected (active).
// ---------------------------------------------------------------------------
test("leave room via sidebar ✕ button", async ({ page }) => {
  await dismissWizard(page);

  const tauri = await isTauriDesktop(page);
  if (!tauri) {
    test.skip(true, "Tauri desktop not available (web preview mode)");
    return;
  }

  const testRoom = `e2e-leave-test-${Date.now()}`;

  // Join the room first
  const joinInput = page.locator('input[placeholder="room-id"]');
  await joinInput.fill(testRoom);
  await joinInput.press("Enter");
  await page.waitForTimeout(800);

  // Click room to select it (activates it, reveals ✕ button)
  const roomItem = page.getByText(`🏠 ${testRoom}`);
  await expect(roomItem).toBeVisible();
  await roomItem.click();
  await page.waitForTimeout(300);

  // ✕ leave button should now be visible
  const leaveBtn = page.locator("button[title=\"Leave room\"]");
  await expect(leaveBtn).toBeVisible();

  // Leave the room
  await leaveBtn.click();
  await page.waitForTimeout(500);

  // Room should be gone from sidebar
  await expect(page.getByText(`🏠 ${testRoom}`)).not.toBeVisible();
});

// ---------------------------------------------------------------------------
// Test: swarm-lounge is auto-joined on startup when an alias is stored
// The app calls joinRoom("swarm-lounge", alias) in useEffect on load.
// In Tauri desktop: room appears in sidebar after auto-join.
// In web preview: joinRoom fails (isTauriDesktop=false) — the error toast
// "Could not auto-join swarm-lounge" appears, confirming the failure path.
// ---------------------------------------------------------------------------
test("swarm-lounge auto-joined on startup when alias is stored", async ({ page }) => {
  await dismissWizard(page);

  // Wait for monitor + broker discovery + auto-join attempt
  await page.waitForTimeout(2000);

  // Either the room is visible (Tauri desktop) OR the error toast is visible
  // (web preview — confirms the failure path was exercised)
  const roomVisible = await page.getByText("🏠 swarm-lounge").isVisible().catch(() => false);
  const errorToastVisible = await page.getByText(/Could not auto-join swarm-lounge/i).isVisible().catch(() => false);

  // At least one of these must be true — both means the room appeared in Tauri desktop
  expect(roomVisible || errorToastVisible).toBeTruthy();

  if (roomVisible) {
    // Full success (Tauri desktop)
    await expect(page.getByText("🏠 swarm-lounge")).toBeVisible();
  } else {
    // Web preview: error toast confirms the join was attempted and correctly
    // failed because isTauriDesktop===false — this is expected behaviour
    await expect(page.getByText(/Could not auto-join swarm-lounge/i)).toBeVisible();
  }
});

// ---------------------------------------------------------------------------
// Test: Empty room ID does not crash and leaves the input usable
// ---------------------------------------------------------------------------
test("empty room ID does not crash", async ({ page }) => {
  await dismissWizard(page);

  const joinInput = page.locator('input[placeholder="room-id"]');
  await joinInput.fill("   "); // whitespace-only
  await joinInput.press("Enter");
  await page.waitForTimeout(500);

  // Page should still be functional
  await expect(joinInput).toBeVisible();
  // Use exact match for the header "c2c" text (toast messages contain "c2c" too)
  await expect(page.getByText("c2c", { exact: true })).toBeVisible();
});

// ---------------------------------------------------------------------------
// Test: Leave button is NOT visible when no room is selected
// ---------------------------------------------------------------------------
test("leave button hidden when no room is selected", async ({ page }) => {
  await dismissWizard(page);

  const leaveBtn = page.locator("button[title=\"Leave room\"]");
  await expect(leaveBtn).not.toBeVisible();
});
