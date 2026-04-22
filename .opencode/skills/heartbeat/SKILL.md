---
name: heartbeat
description: how to use the 'monitor' plugin/tool to create a heartbeat.
---
# Heartbeat Skill

Goal: use `monitor` to set you up with a heartbeat prompt. 

1. list your active monitors; if you already have a heartbeat one, update it if the following configuration differs. 
2. create a heartbeat monitor or update existing: 
  - Trigger type: 'idle'
  - Command and args: `heartbeat <duration> "<message>"`
  - send_only_latest: true

Default heartbeat tick duration: `4.1m`. 
Note: `heartbeat` accepts durations as ints or floats and the suffixes h, m, s, ms.

Heartbeat Message: Continue available work, drive completion of goals, and if without tasks, offer help to your colleages and ask for any incomplete tasks. Also, brainstorm how to make the codebase better.

If `heartbeat` is not available, use something like `bash -c "while sleep 246; do echo "<message>"; done`.

Note: A timer of <5min is recommended because most AI cache expiry is ~5 min.
