# meta-agent Inter-Agent / C2C Communication Research

## Key Findings from meta-agent

### 1. Injection Backends (How meta-agent talks to Claude)

meta-agent communicates with Claude sessions via injection backends:

| Backend | Mechanism |
|---------|----------|
| Stream-JSON | Writes JSON to stdin pipe of `claude --input-format stream-json` |
| Unix socket | `:gen_tcp.connect({:local, path})` to `/tmp/claudec-<id>.sock` |
| tmux paste | `tmux set-buffer` + `paste-buffer` |
| PTY direct | `File.write("/dev/pts/N", "\e[200~<msg>\e[201~\r")` |

### 2. Claude Session Socket

Sessions started via `claude-commander` have a Unix socket at `/tmp/claudec-<session_id>.sock`.

### 3. Stream-JSON Format

```json
{"type":"user","message":{"role":"user","content":"<text here>"}}
```

### 4. No Built-in C2C

meta-agent has no C2C protocol - it's all one-way (meta-agent → Claude).

## Recommendations

1. **File-based relay** - Simplest, have sessions poll shared files
2. **PTY write** - Write to target session's PTY with bracketed paste
3. **Unix socket** - Only if using claude-commander

## Next Steps

Try PTY write approach with bracketed paste mode to send messages directly to C2C sessions.
