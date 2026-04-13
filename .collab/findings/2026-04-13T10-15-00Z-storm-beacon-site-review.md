# Site Visual Review — c2c.im

- **Time:** 2026-04-13T10:15:00Z
- **Reporter:** storm-beacon
- **Method:** Playwright browser automation, both light and dark mode
- **Severity:** minor fix found and resolved

## Review Summary

Reviewed `https://c2c.im` and `https://c2c.im/overview/` after storm-ember's
CSS redesign (commit 5d9db5d). Site uses minima with a custom dark terminal
theme (deep `#0d1117` bg, `#00d97e` green accents, blue inline code, left-bordered
code blocks).

## Light Mode

CSS is correct. Playwright defaults to `prefers-color-scheme: light`, which
showed the light-mode overrides: white background, dark green `#006633` accents,
readable dark text. Light mode is clean and professional.

## Dark Mode

Forced dark mode via JS variable overrides. Dark theme looks sharp:
- Near-black background (`#0d1117`)
- Green headers, green accents, green left-border on code blocks
- Readable light body text (`#c9d1d9`)
- Agent quick-start callout box renders with dark green background and bright
  green text — clearly distinct from body content
- Navigation header is nearly black (`#010409`) with green site title

## Bug Found and Fixed

**Duplicate h1 on home page** (commit `c478ddb`):
- Root cause: minima `home` layout auto-renders `page.title` as `h1.page-heading`.
  `index.md` also had a `# c2c` heading at the top of the content body.
  Both h1 elements had `display: inline-block` in the CSS, so they appeared
  on the same line: "c2c — Instant Messaging for AI Agentsc2c".
- Fix 1: Removed the duplicate `# c2c` markdown heading from `index.md`.
- Fix 2: Changed `h1 { display: inline-block }` to `display: block; width: fit-content`
  so the green underline stays tight to the text without making h1 elements flow inline.

## Remaining Observations

- **Navigation**: all 6 pages appear in the header (Home, Overview, Commands,
  Architecture, Per-Client Delivery, Known Issues, Next Steps). Labels are clear.
- **Content accuracy**: index.md agent quick-start now covers all 5 clients with
  correct setup and restart instructions.
- **Per-client delivery page**: `https://c2c.im/client-delivery/` is live with
  ASCII delivery diagrams for all 5 clients.
- **Screenshots saved**: `.collab/screenshots/c2c-im-home-dark-viewport-2026-04-13.png`
  and `.collab/screenshots/c2c-im-overview-dark-2026-04-13.png`.

## Status

All agents who can run Playwright should do a quick review of the live site to
sign off on the redesign. Max will make the final call on criterion #7.
Screenshots are in `.collab/screenshots/`.
