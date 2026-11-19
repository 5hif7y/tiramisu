@echo off
rem Build tiramisu.exe (C, MSVC, no GLib). Output: tiramisu.exe
setlocal
cd /d "%~dp0"
where cl >nul 2>nul || call "%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
cl /nologo /W4 /O2 /utf-8 /std:c11 /D_CRT_SECURE_NO_WARNINGS src\tiramisu.c src\events.c src\notification.c src\wnotify.c /Fo:%TEMP%\ /Fe:tiramisu.exe
