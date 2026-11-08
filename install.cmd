@echo off
rem Create a matching <exe>.config for every NVCleanstall*.exe in this folder.
rem The CLR only reads AppDomainManager settings from <exe filename>.config, so a
rem renamed portable build (NVCleanstall_1.19.0.exe) needs its own copy.
rem Usage: install.cmd [-nopause]
setlocal EnableExtensions
cd /d "%~dp0"

set "NOPAUSE=0"
if /i "%~1"=="-nopause" set "NOPAUSE=1"

set "TEMPLATE=%~dp0NVCleanstall.exe.config"
if not exist "%TEMPLATE%" (
    echo [ERROR] Missing config template: %TEMPLATE%
    set "RESULT=1"
    goto :end
)

rem A config that names NvcChs while the DLL is absent stops the host from starting
rem at all (TypeLoadException), so never write one without the payload present.
if not exist "%~dp0NvcChs.dll" (
    echo [ERROR] NvcChs.dll is missing next to install.cmd.
    echo         A config without it stops NVCleanstall from starting.
    echo         Extract the whole zip into this folder first.
    set "RESULT=1"
    goto :end
)
if not exist "%~dp0zh-CN.txt" echo [WARN] zh-CN.txt is missing; the UI will stay in English.

set "RESULT=0"
set "SEEN=0"
for %%F in ("%~dp0NVCleanstall*.exe") do if exist "%%~fF" call :ensure "%%~fF"
if "%SEEN%"=="0" (
    echo [ERROR] No NVCleanstall*.exe found in %~dp0
    set "RESULT=1"
    goto :end
)
echo Done.
goto :end

:ensure
set "SEEN=1"
set "CFG=%~1.config"
rem NVCleanstall.exe's config IS the template; copying a file onto itself fails.
if /i "%CFG%"=="%TEMPLATE%" goto :eof
if not exist "%CFG%" (
    copy /y "%TEMPLATE%" "%CFG%" >nul
    if errorlevel 1 (echo [ERROR] Could not create %CFG% & set "RESULT=1") else (echo Created: %CFG%)
    goto :eof
)
findstr /c:"appDomainManagerType" "%CFG%" >nul 2>nul
if errorlevel 1 (
    echo [SKIP] %CFG% exists and is not this patch; left untouched.
    goto :eof
)
copy /y "%TEMPLATE%" "%CFG%" >nul
if errorlevel 1 (echo [ERROR] Could not update %CFG% & set "RESULT=1") else (echo Updated: %CFG%)
goto :eof

:end
if "%NOPAUSE%"=="0" pause
exit /b %RESULT%
