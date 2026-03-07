@echo off
REM TranslateGram Backend — NSSM Service Installer
REM Fully unregisters any existing service, then registers and starts fresh.
REM Run as Administrator.

setlocal

set SERVICE_NAME=TranslateGramBackend
set SCRIPT_DIR=%~dp0
REM Remove trailing backslash to avoid quoting issues
set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%
set VENV_DIR=%SCRIPT_DIR%\venv
set NSSM=%SCRIPT_DIR%\nssm.exe
set PYTHON=%VENV_DIR%\Scripts\python.exe
set MAIN_PY=%SCRIPT_DIR%\main.py
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

REM Create isolated virtual environment
if not exist "%VENV_DIR%" (
    echo Creating virtual environment...
    python -m venv "%VENV_DIR%"
    echo Installing dependencies...
    "%VENV_DIR%\Scripts\pip.exe" install -r "%SCRIPT_DIR%\requirements.txt"
)

REM --- FRESH INSTALL ---
echo.
echo Installing %SERVICE_NAME% service...
"%NSSM%" install %SERVICE_NAME% "%PYTHON%"
"%NSSM%" set %SERVICE_NAME% AppParameters -u "%MAIN_PY%"
"%NSSM%" set %SERVICE_NAME% AppDirectory "%SCRIPT_DIR%"
"%NSSM%" set %SERVICE_NAME% DisplayName "TranslateGram Backend"
"%NSSM%" set %SERVICE_NAME% Description "TranslateGram translation proxy server"

REM Logging — redirect stdout/stderr to files
"%NSSM%" set %SERVICE_NAME% AppStdout "%LOG_DIR%\backend_stdout.log"
"%NSSM%" set %SERVICE_NAME% AppStderr "%LOG_DIR%\backend_stderr.log"
"%NSSM%" set %SERVICE_NAME% AppRotateFiles 1
"%NSSM%" set %SERVICE_NAME% AppRotateBytes 10485760

REM Auto-start on boot, auto-restart on crash
"%NSSM%" set %SERVICE_NAME% Start SERVICE_AUTO_START
"%NSSM%" set %SERVICE_NAME% AppExit Default Restart
"%NSSM%" set %SERVICE_NAME% AppRestartDelay 3000

REM Start the service
echo.
echo Starting %SERVICE_NAME%...
"%NSSM%" start %SERVICE_NAME%

echo.
echo Service %SERVICE_NAME% installed and started.
echo Logs: %LOG_DIR%\backend_stdout.log
echo Test: curl http://127.0.0.1:8081/health
echo.
pause
