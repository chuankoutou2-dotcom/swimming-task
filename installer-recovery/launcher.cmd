@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
set "SWIM_REPAIR_KIT=%~dp0"
set "SWIM_REPAIR_APPROVAL="
set "SWIM_REPAIR_PHASE=preview"
set "SWIM_REPAIR_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "SWIM_REPAIR_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%SWIM_REPAIR_POWERSHELL%" -NoLogo -NoProfile -NonInteractive -Command - < "%~dp0repair.ps1"
set "SWIM_REPAIR_RESULT=%ERRORLEVEL%"
if not "%SWIM_REPAIR_RESULT%"=="42" goto finish
set /p "SWIM_REPAIR_APPROVAL=内容を確認して実行する場合だけ REPAIR と入力: "
set "SWIM_REPAIR_PHASE=commit"
"%SWIM_REPAIR_POWERSHELL%" -NoLogo -NoProfile -NonInteractive -Command - < "%~dp0repair.ps1"
set "SWIM_REPAIR_RESULT=%ERRORLEVEL%"
:finish
echo.
pause
exit /b %SWIM_REPAIR_RESULT%
