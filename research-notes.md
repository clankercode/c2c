# C2C Communication Research Notes

## Goal
Get two Claude sessions (C2C msg test and C2C-test-agent2) to communicate with each other via an agent-to-agent protocol.

## Sessions
- C2C msg test: PID 2002626, session e2deb862-9bf1-4f9f-92f5-3df93978b8d4, TTY pts/11, CWD /home/xertrov/tmp
- C2C-test-agent2: PID 2009124, session d5722f5b-6355-4f2f-a712-39e9a113fc06, TTY pts/19, CWD /home/xertrov/tmp

## Key Finding: Profile System

The `cc` and `cc-p` scripts manage different Claude profiles:
- `cc` uses profile "w" (stored in ~/.claude-w/)
- `cc-p` uses profile "p" (stored in ~/.claude-p/)
- Session files for C2C sessions are in ~/.claude-p/sessions/

Sessions started with profile p have their state in:
- Config: ~/.claude-p/
- State: ~/.local/state/cc-p/claude/
- Cache: ~/.cache/cc-p/

## Attempted Approaches

### 1. --resume flag
- `cc-p --resume <session-id> -p "msg"` returns "No conversation found"
- This happens even when the session is actively running
- Session files exist in ~/.claude-p/sessions/ but resume doesn't find them

### 2. TTY writing
- Writing to /dev/pts/X doesn't trigger message processing
- The TTY input goes to the terminal emulator, not to Claude's message handler
- C2C sessions don't respond to TTY input

### 3. History injection
- Tried appending to ~/.claude/history.jsonl
- Sessions don't poll or read from history during interactive session

### 4. Unix socket IPC
- All claude processes share socket pair 531398/531399
- This appears to be a central IPC hub
- Abstract socket - can't easily connect to it from external processes

### 5. Pipe IPC
- Pipes 160854/160855 are shared by all claude processes
- fd 5 is read-only (stdin), fd 4/6 are write-only (stdout)
- Can't directly write to claude's stdin from external process

### 6. SendMessage tool
- Only works for sending to teammates (sub-agents), not top-level sessions
- Cannot address arbitrary session IDs

## User Feedback
User mentioned a "test from cli" worked in the past - need to understand what mechanism was used.

## Next Steps
1. Understand what mechanism was used for the successful "test from cli"
2. Consider starting a NEW cc-p session that can act as a bridge
3. Look into whether there's a way to use MCP for inter-session messaging
4. Consider a file-based approach where sessions poll a shared directory
