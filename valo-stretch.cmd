@echo off
setlocal EnableExtensions
REM ===========================================================================
REM  valo-stretch.cmd - launcher for valo-true-stretch
REM
REM  Double-click             ->  Play Valorant with the stretch profile:
REM                               apply resolution + disable monitor, launch
REM                               Valorant, and revert automatically on exit.
REM
REM  valo-stretch toggle           Just toggle the display on/off (no game)
REM  valo-stretch 1920x1080        One-off toggle at a specific resolution
REM  valo-stretch setdefault WxH   Save the default resolution
REM  valo-stretch status           Show settings and current state
REM  valo-stretch install          Set up no-prompt toggling (one UAC prompt)
REM  valo-stretch uninstall        Remove the task + shortcut
REM  valo-stretch help             Show this help
REM
REM  Change the resolution any time by editing config.txt.
REM ===========================================================================

set "SCRIPT=%~dp0Toggle-MonitorAndResolution.ps1"
set "PSEXE=powershell.exe -NoProfile -ExecutionPolicy Bypass -File"

REM Detect double-click so we can keep the window open at the end.
set "PAUSE_AT_END="
echo %cmdcmdline% | findstr /i /c:"%~nx0" >nul && set "PAUSE_AT_END=1"

if not exist "%SCRIPT%" (
    echo ERROR: Cannot find "%SCRIPT%".
    echo Keep valo-stretch.cmd next to Toggle-MonitorAndResolution.ps1.
    goto :end
)

set "CMD=%~1"

if /i "%CMD%"==""           goto :play
if /i "%CMD%"=="play"       goto :play
if /i "%CMD%"=="toggle"     goto :toggle
if /i "%CMD%"=="status"     goto :status
if /i "%CMD%"=="setdefault" goto :setdefault
if /i "%CMD%"=="install"    goto :install
if /i "%CMD%"=="uninstall"  goto :uninstall
if /i "%CMD%"=="help"       goto :usage
if /i "%CMD%"=="-h"         goto :usage
if /i "%CMD%"=="/?"         goto :usage

REM Is the first arg a WIDTHxHEIGHT resolution?
echo %CMD%| findstr /r "^[1-9][0-9][0-9][0-9]*x[1-9][0-9][0-9][0-9]*$" >nul
if not errorlevel 1 goto :resolution

echo Unknown command "%CMD%".
echo.
goto :usage

:play
%PSEXE% "%SCRIPT%" -Play
goto :end

:toggle
%PSEXE% "%SCRIPT%"
goto :end

:resolution
%PSEXE% "%SCRIPT%" -Resolution %CMD%
goto :end

:status
%PSEXE% "%SCRIPT%" -Status
goto :end

:setdefault
if "%~2"=="" (
    echo Usage: valo-stretch setdefault 1280x1024
    goto :end
)
%PSEXE% "%SCRIPT%" -SetDefault -Resolution %~2
goto :end

:install
%PSEXE% "%SCRIPT%" -Install
goto :end

:uninstall
%PSEXE% "%SCRIPT%" -Uninstall
goto :end

:usage
echo valo-true-stretch - Valorant stretched-resolution toggle
echo.
echo   (double-click^)              Play Valorant with the stretch profile
echo   valo-stretch toggle         Toggle the display on/off (no game^)
echo   valo-stretch 1920x1080      One-off toggle at a specific resolution
echo   valo-stretch setdefault WxH Save the default resolution
echo   valo-stretch status         Show settings and current state
echo   valo-stretch install        Set up no-prompt toggling (one UAC prompt^)
echo   valo-stretch uninstall      Remove the task + shortcut
echo   valo-stretch help           Show this help
echo.
echo   Change the resolution any time by editing config.txt.
goto :end

:end
if defined PAUSE_AT_END pause
endlocal
