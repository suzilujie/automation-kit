@echo off
rem AutomationKit launcher. Plain ASCII, goto based, no nested if blocks.
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
if errorlevel 1 goto failed
goto done

:failed
echo.
echo [FAIL] AutomationKit did not start. Read the messages above.
pause
exit /b 1

:done
echo.
echo [DONE] AutomationKit is running at http://localhost:5678
pause
exit /b 0
