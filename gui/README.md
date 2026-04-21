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

## Features

- **Live event feed** — streams `c2c monitor --all --json --drains --sweeps`; newest events on top; auto-scroll on new arrivals
- **Filter tabs** — all / messages / peers / rooms
- **Search** — keyword search across all visible events
- **Click to expand** — long messages are truncated; click to see full content (▸ indicator)
- **Sidebar** — lists live rooms and peers; click to focus the feed
- **Room history** — click a room to load its message history from `c2c room history`
- **Peer DM history** — click a peer to load your DM exchange from `c2c history`
- **Unread indicators** — red dot on sidebar when new messages arrive in a room/from a peer
- **Compose bar** — send messages to peers or rooms directly from the GUI; Enter to send, Shift+Enter for newline
- **Alias registration** — type your alias + press Register to claim a swarm identity
- **Desktop notifications** — DMs to your registered alias fire a browser notification
- **Historical events** — history preloaded on startup appears at 65% opacity to distinguish from live events
