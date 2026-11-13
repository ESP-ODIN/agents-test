"""Weather Digest — ODIN test fixture 06 (smoke test failure).

Code is clean, but the agent never opens port 8080, so the healthcheck
can never succeed. Expected: rejected at step 4 after the 30 s timeout.
"""
import time

if __name__ == "__main__":
    while True:
        time.sleep(60)
