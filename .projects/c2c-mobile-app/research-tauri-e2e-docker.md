# Tauri E2E in Docker — M5 Harness Research

**Filed**: 2026-04-23 by Cairn-Vigil (coordinator1) via research subagent.
**Relevant to**: [spec.md](spec.md) §5 Testing, §7 Milestones (M5 = "Dockerized E2E harness").
**Status**: pre-M5 research; feeds design decisions before M5 kicks off.

## TL;DR

Ship M5 as a **hybrid**:

- **Desktop E2E** → Docker on GitHub Actions `ubuntu-latest`, stack: `xvfb` + `webkit2gtk-driver` + `tauri-driver` + WebdriverIO.
- **Android E2E** → `ReactiveCircus/android-emulator-runner` on the bare Linux runner (NOT nested in Docker — KVM isn't supported inside Docker-in-Docker on GH-hosted). Drive with **Maestro** (YAML flows).
- **iOS** → defer E2E out of M5; ship a `macos-latest` build-fail-fast job + manual QA for v1.
- **Relay-in-tests** → sidecar container running real OCaml relay binary.

## Desktop-in-Docker — verdict: YES, mature

**Stack**: `tauri-driver` (Rust binary) → `WebKitWebDriver` (apt package `webkit2gtk-driver`) → WebdriverIO test runner. This is the official Tauri recipe.

**Reference images**:
- `ivangabriele/docker-tauri` (daily-updated base, Debian bookworm + Rust + Node + tauri-driver). Marked "testing" for v2. May want to author our own from `debian:bookworm-slim` for reproducibility.

**Dockerfile key lines**:
```dockerfile
FROM rust:1-bookworm
RUN apt-get update && apt-get install -y \
    libwebkit2gtk-4.1-dev libayatana-appindicator3-dev \
    webkit2gtk-driver xvfb \
    libgtk-3-dev librsvg2-dev build-essential curl file \
    fonts-liberation xclip
RUN cargo install tauri-driver --locked
# run tests: xvfb-run -a yarn test   (WDIO spawns tauri-driver per session)
```

**WDIO config shape**: `onPrepare` (build Tauri binary), `beforeSession` (spawn `tauri-driver`), `afterSession` (kill it).

**Pin**: Tauri v2 requires **webkit2gtk 4.1** → Ubuntu 22.04+ / Debian bookworm. 20.04/bullseye is stuck on 4.0 (Tauri v1 only).

**Gotchas**: clipboard tests need `xclip`; text-layout-stable screenshot asserts need `fonts-liberation`.

## Android emulator — verdict: run on bare runner, not in Docker

Nested KVM is not supported on GitHub's standard hosted runners. Docker-in-Docker Android emulator images (`budtmo/docker-android`, `google/android-emulator-container-scripts`, HQarroum, etc.) will either refuse to boot or run software-only at minutes-per-tap flake rates.

**Chosen path**: `ReactiveCircus/android-emulator-runner` GitHub Action — de-facto standard, gets KVM directly on the bare runner.

**UI driver**: **Maestro** (YAML flows, cross-platform, lower flake than Appium for this scope). Appium is the fallback when deep native hooks are needed.

**QR pairing (spec §3.1 QR flow requirement)**:
- Use emulator **virtual scene camera**.
- Replace `poster.png` in the AVD's scene assets with the target QR PNG before the scan step.
- Emulator renders the PNG on the virtual wall; the real camera pipeline picks it up — no camera mocking in app code.
- Appium has a documented virtual-scene image-injection workflow. Maestro `runScript` can shell out (`adb emu avd ...` + file swap).

**Timing**: GH `ubuntu-latest` AVD boot ≈ 2-4 min for x86_64 API 33. Acceptable for M5. If flake bites later: larger runners, self-hosted with udev rules + `--device /dev/kvm`.

## iOS — escape hatch

Docker is off the table (Apple tooling = macOS only). WKWebView has no official WebDriver, so standard Tauri E2E is unavailable on iOS regardless.

Three realistic options:
1. **Defer iOS E2E out of M5.** iOS smoke + manual QA for v1. **Recommended.**
2. `tauri-plugin-webdriver-automation` (in-app debug HTTP server; not WebDriver-standard, but automatable) on `macos-latest` + simulator.
3. `danielraffel/tauri-webdriver` (community macOS WebDriver for Tauri) — young, low community.

**For M5**: option (1) + a `macos-latest` job that builds the iOS bundle with `tauri-action` so we fail fast on build breakage. UI E2E waits for v2.

## Missing pieces / open risks before M5

- **Relay in tests**: real relay in sidecar container vs lightweight mock? Real gives more coverage + bakes OCaml build into image. Recommend: separate image for the OCaml relay, compose the two.
- **Tauri v2 + webkit2gtk 4.1 pin**: `ivangabriele/docker-tauri` bookworm tag still "testing" — verify before depending; may want custom Dockerfile.
- **Maestro + Tauri webview hit-testing**: Tauri mobile renders in a single native webview. Maestro finds elements by accessibility IDs; confirm Tauri webview surfaces a11y nodes to the OS (generally yes on Android via WebView, but spike before committing).
- **QR injection timing**: swap `poster.png`, then wait for emulator scene re-render; add settle delay.
- **CI cost discipline**: keep most mobile logic in unit tests (Rust + TS). Emulator job should be smoke-only (~3-5 flows) to stay under GH Actions free tier.
- **Clipboard / IME / fonts** inside xvfb for desktop tests — install `xclip` + `fonts-liberation` per Dockerfile above.

## Reference links

- [Tauri WebDriver CI guide (official, Ubuntu workflow)](https://v2.tauri.app/develop/tests/webdriver/ci/)
- [ivangabriele/docker-tauri — daily-updated Tauri Docker images](https://github.com/ivangabriele/docker-tauri)
- [ReactiveCircus/android-emulator-runner — KVM-accelerated Android on GH Actions](https://github.com/ReactiveCircus/android-emulator-runner)
- [Maestro — cross-platform mobile E2E (YAML flows)](https://github.com/mobile-dev-inc/Maestro)
- [Appium virtual-scene camera injection (QR-code pattern)](https://medium.com/@khaled.sayed.ramadan/appium-camera-automation-using-virtual-scene-images-step-by-step-79af99841775)
- [tauri-apps discussion #10123 — mobile E2E state](https://github.com/tauri-apps/tauri/discussions/10123)

## Recommendation feeding back into [spec.md](spec.md) §5

Update §5 when M5 is planned:
- Desktop E2E line is already roughly right ("isolated Docker environment … Tauri-mobile debug build. Driven by `tauri-driver` or `webdriverio`").
- Android E2E needs a correction: emulator runs on the **bare Linux runner**, not inside Docker. Relay/broker stays in Docker sidecar. Maestro preferred over Appium for v1 flows.
- Add explicit iOS deferral line: "iOS E2E deferred; M5 ships a build-fail-fast job only; UI E2E revisited in v2."
- Add QR-injection note: "QR pairing test uses emulator virtual-scene poster swap (not in-app camera mock)."
