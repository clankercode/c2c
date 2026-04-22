from __future__ import annotations

import sys


print("READY", flush=True)
for line in sys.stdin:
    text = line.rstrip("\n")
    if text == "/quit":
        print("BYE", flush=True)
        break
    print(f"ECHO: {text}", flush=True)
