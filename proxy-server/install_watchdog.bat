@echo off
REM TranslateGram Watchdog — NSSM Service Installer
REM Fully unregisters any existing service, then registers and starts fresh.
REM The watchdog checks backend health every cycle and restarts it if frozen.
REM Run as Administrator.

setlocal

set SERVICE_NAME=TranslateGramWatchdog
set SCRIPT_DIR=%~dp0
REM Remove trailing backslash to avoid quoting issues
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%
set VENV_DIR=%SCRIPT_DIR%\venv
set NSSM=%SCRIPT_DIR%\nssm.exe
set PYTHON=%VENV_DIR%\Scripts\python.exe
set WATCHDOG_PY=%SCRIPT_DIR%\watchdog.py
set LOG_DIR=%SCRIPT_DIR%\logs

REM Check nssm exists
if not exist "%NSSM%" (
    echo ERROR: nssm.exe not found at %NSSM%
    pause
    exit /b 1
)

REM --- FULL CLEANUP ---
echo Stopping and removing existing %SERVICE_NAME% service...
sc stop %SERVICE_NAME% >nul 2>&1
timeout /t 2 /nobreak >nul
sc delete %SERVICE_NAME% >nul 2>&1
timeout /t 2 /nobreak >nul
echo Done.

REM Create logs directory
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

REM Ensure venv exists (should have been created by install_backend.bat)
if not exist "%VENV_DIR%" (
    echo Creating virtual environment...
    python -m venv "%VENV_DIR%"
)

REM --- FRESH INSTALL ---
echo.
echo Installing %SERVICE_NAME% service...
"%NSSM%" install %SERVICE_NAME% "%PYTHON%"
"%NSSM%" set %SERVICE_NAME% AppParameters -u "%WATCHDOG_PY%"
"%NSSM%" set %SERVICE_NAME% AppDirectory "%SCRIPT_DIR%"
"%NSSM%" set %SERVICE_NAME% DisplayName "TranslateGram Watchdog"
"%NSSM%" set %SERVICE_NAME% Description "Health monitor for TranslateGram backend"

REM Logging
"%NSSM%" set %SERVICE_NAME% AppStdout "%LOG_DIR%\watchdog_stdout.log"
"%NSSM%" set %SERVICE_NAME% AppStderr "%LOG_DIR%\watchdog_stderr.log"
"%NSSM%" set %SERVICE_NAME% AppRotateFiles 1
"%NSSM%" set %SERVICE_NAME% AppRotateBytes 1048576

REM Auto-start on boot, restart on ANY exit (this is the cycle mechanism).
REM AppRestartDelay sets the gap between watchdog passes — 15s gives the backend
REM room to finish a cold start (pydantic/FastAPI import chain is slow) before
REM the next health probe. Previous value (0) caused tight restart loops that
REM killed the backend mid-startup.
"%NSSM%" set %SERVICE_NAME% Start SERVICE_AUTO_START
"%NSSM%" set %SERVICE_NAME% AppExit Default Restart
"%NSSM%" set %SERVICE_NAME% AppRestartDelay 15000

REM Start the service
echo.
echo Starting %SERVICE_NAME%...
"%NSSM%" start %SERVICE_NAME%

echo.
echo Service %SERVICE_NAME% installed and started.
echo Cycle: sleep 30s, check /health with 3 retries, exit, NSSM waits 15s, repeat.
echo.
pause
