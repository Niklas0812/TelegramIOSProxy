"""TranslateGram Watchdog — health check monitor running as a separate NSSM service.

Lifecycle (bullet-proofed against slow cold starts):
1. Wait STARTUP_DELAY_SECONDS so the backend has time to fully start
   (pydantic/FastAPI import chain can easily take 15+ seconds on Windows).
2. Try the /health endpoint with HEALTH_RETRIES passes, HEALTH_RETRY_DELAY
   seconds apart — tolerates transient timeouts without triggering restarts.
3. If ALL passes fail, call `nssm restart` with a generous timeout so the
   restart subprocess itself isn't killed mid-operation.
4. Always exit cleanly. NSSM restarts this watchdog service (with a delay
   configured in install_watchdog.bat) — that is the outer cycle.

Uses only stdlib — no pip dependencies required.
"""

import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

HEALTH_URL = "https://telegramtranslation.duckdns.org/health"

# Per-attempt HTTP timeout — some Windows/OpenSSL DNS lookups are slow, and
# /health itself can pause briefly under load. 10s is comfortably higher than
# anything a healthy backend needs.
HEALTH_TIMEOUT_SECONDS = 10

# How long to wait on boot before the first health check. Backend cold start
# on Windows (venv, uvicorn, FastAPI pydantic v1 compat probe) can take 15-25s.
# The previous value of 5s caused false negatives that triggered restart loops.
STARTUP_DELAY_SECONDS = 30

# Retry budget before declaring the backend dead. 3 x (10s timeout + 3s gap)
# = up to ~39s, which tolerates a transient hang without escalating.
HEALTH_RETRIES = 3
HEALTH_RETRY_DELAY = 3

# Generous timeout for `nssm restart`. The restart blocks until the backend
# service transitions — on Windows this can include a stop+start cycle with
# multi-second waits for TCP TIME_WAIT. If the subprocess is killed mid-way
# we leave the service in an inconsistent state, which is exactly what was
# happening before.
NSSM_RESTART_TIMEOUT_SECONDS = 90

BACKEND_SERVICE_NAME = "TranslateGramBackend"
NSSM_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nssm.exe")

# Script-owned log file, written directly by Python. We do NOT rely on NSSM's
# stdout capture (AppStdout) because that pipe gets wedged on Windows when the
# service cycles rapidly or a previous python.exe leaves a stale handle. Writing
# directly from Python gives deterministic evidence of whether the script ran.
LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "watchdog_script.log")


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] [watchdog] {msg}\n"
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        # Never let logging failure crash the watchdog — its job is to check
        # the backend, not to log perfectly.
        pass
    # Also emit to stdout so manual `python watchdog.py` runs are interactive.
    try:
        print(f"[watchdog] {msg}", flush=True)
    except Exception:
        pass


def check_health_once() -> bool:
    try:
        req = urllib.request.Request(HEALTH_URL, method="GET")
        with urllib.request.urlopen(req, timeout=HEALTH_TIMEOUT_SECONDS) as resp:
            return resp.status == 200
    except Exception as e:
        log(f"health check failed: {type(e).__name__}: {e}")
        return False


def check_health() -> bool:
    """Retry a few times to absorb transient hiccups before concluding death."""
    for attempt in range(1, HEALTH_RETRIES + 1):
        if check_health_once():
            if attempt > 1:
                log(f"health OK on attempt {attempt}/{HEALTH_RETRIES}")
            return True
        if attempt < HEALTH_RETRIES:
            time.sleep(HEALTH_RETRY_DELAY)
    return False


def restart_backend() -> None:
    log(f"restarting {BACKEND_SERVICE_NAME} via NSSM (timeout={NSSM_RESTART_TIMEOUT_SECONDS}s)")
    try:
        result = subprocess.run(
            [NSSM_PATH, "restart", BACKEND_SERVICE_NAME],
            timeout=NSSM_RESTART_TIMEOUT_SECONDS,
            capture_output=True,
            text=True,
        )
        log(f"nssm restart exited rc={result.returncode}")
        if result.stdout:
            log(f"nssm stdout: {result.stdout.strip()}")
        if result.stderr:
            log(f"nssm stderr: {result.stderr.strip()}")
    except subprocess.TimeoutExpired:
        # Don't try a harder-kill — leaving NSSM's in-flight restart alone is
        # safer than racing it. The outer cycle will check again on next pass.
        log("nssm restart timed out — leaving NSSM to finish; will re-check next cycle")
    except Exception as e:
        log(f"nssm restart raised {type(e).__name__}: {e}")


def main() -> None:
    log(f"starting: sleep {STARTUP_DELAY_SECONDS}s, then check {HEALTH_URL}")
    time.sleep(STARTUP_DELAY_SECONDS)

    if check_health():
        log("backend healthy — exiting 0")
        sys.exit(0)
    else:
        log(f"backend unhealthy after {HEALTH_RETRIES} attempts — triggering restart")
        restart_backend()
        sys.exit(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        # NSSM raises SIGINT-equivalent when stopping the service (e.g. during
        # reinstall). Exit quietly instead of filling stderr with tracebacks.
        log("interrupted during cycle — exiting quietly")
        sys.exit(0)
