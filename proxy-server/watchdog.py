"""TranslateGram Watchdog — health check monitor running as a separate NSSM service.

Lifecycle (simple, predictable, foolproof):
1. Wait 5 seconds (give backend time to be alive)
2. Send HTTP GET to /health endpoint
3. Wait max 2 seconds for response
4. If response received: backend is healthy -> exit(0). NSSM restarts -> cycle repeats.
5. If NO response: backend is frozen/down -> kill backend process -> exit(1).
   NSSM restarts both services -> backend comes back up, watchdog cycle repeats.

Uses only stdlib — no pip dependencies required.
"""

import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

HEALTH_URL = "https://telegramtranslation.duckdns.org/health"
HEALTH_TIMEOUT_SECONDS = 2
STARTUP_DELAY_SECONDS = 5
BACKEND_SERVICE_NAME = "TranslateGramBackend"
NSSM_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nssm.exe")


def check_health() -> bool:
    try:
        req = urllib.request.Request(HEALTH_URL, method="GET")
        with urllib.request.urlopen(req, timeout=HEALTH_TIMEOUT_SECONDS) as resp:
            return resp.status == 200
    except Exception:
        return False


def restart_backend() -> None:
    try:
        subprocess.run(
            [NSSM_PATH, "restart", BACKEND_SERVICE_NAME],
            timeout=10,
            capture_output=True,
        )
    except Exception:
        try:
            subprocess.run(["net", "stop", BACKEND_SERVICE_NAME], timeout=10, capture_output=True)
        except Exception:
            pass


def main() -> None:
    time.sleep(STARTUP_DELAY_SECONDS)

    if check_health():
        sys.exit(0)
    else:
        restart_backend()
        sys.exit(1)


if __name__ == "__main__":
    main()
