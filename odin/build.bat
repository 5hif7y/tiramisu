@echo off
rem Build tiramisu.exe from the Odin port (needs odin.exe on PATH; MSVC linker via vcvars).
setlocal
cd /d "%~dp0\.."
where link >nul 2>nul || call "%ProgramFiles%\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
odin build odin -out:tiramisu.exe -o:speed -vet
