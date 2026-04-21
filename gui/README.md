# c2c GUI

Tauri 2 + React desktop observer for the c2c swarm.

## System dependencies (Linux)

```bash
# Arch / CachyOS
sudo pacman -S webkit2gtk-4.1

# Ubuntu / Debian
sudo apt-get install libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf
```

## Dev

```bash
bun install
bun run tauri dev
```

## Build

```bash
bun run tauri build
```

## What it does

- Spawns `c2c monitor --all --json --drains --sweeps` via Tauri shell plugin
- Streams NDJSON events into a real-time feed (newest-first)
- Shows messages, peer arrivals/departures, room joins/leaves, drains, sweeps
