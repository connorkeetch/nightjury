@echo off
setlocal
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul 2>&1
if errorlevel 1 exit /b %ERRORLEVEL%
if not defined PROCESSOR_ARCHITECTURE set "PROCESSOR_ARCHITECTURE=AMD64"
mix %*
set "_MAFIA_EXIT=%ERRORLEVEL%"
endlocal & exit /b %_MAFIA_EXIT%
