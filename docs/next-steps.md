# Next Steps

## Short-Term

1. Make the autonomous 20-turn conversation stable without further steering.
2. Improve command ergonomics for agent-generated Bash.
3. Add a conversation watcher that measures turn growth directly from transcripts.

## Medium-Term

1. Consider an OCaml implementation for the final binaries.
2. Add explicit peer restrictions and safer targeting rules.
3. Add transcript diff / tail helpers for easier monitoring.

## Alternative Paths Worth Exploring

1. `stream-json` based controlled sessions
2. per-session socket runtimes such as `claude-commander`
3. any future Claude-native inject API if one appears
