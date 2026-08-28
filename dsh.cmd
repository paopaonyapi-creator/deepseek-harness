@echo off
REM dsh - DeepSeek Harness CLI wrapper for CMD
REM Calls the built dsh CLI from the repo root.
REM Faster than pnpm dsh because it uses the pre-built JavaScript.

set "SCRIPT_DIR=%~dp0"
set "BIN_PATH=%SCRIPT_DIR%apps\cli\lib\bin.js"

if not exist "%BIN_PATH%" (
    echo Error: dsh built binary not found at %BIN_PATH%
    echo Run 'pnpm run build' in the repo root first.
    exit /b 1
)

node "%BIN_PATH%" %*
exit /b %ERRORLEVEL%
