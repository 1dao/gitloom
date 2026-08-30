@echo off
REM Start gitloom. Config comes from gitloom.cfg (and gitloom.local.cfg, which
REM is loaded first and wins); override any key on the command line, e.g.
REM   start.bat LISTEN_PORT=9000 ANON_READ=0
cd /d "%~dp0"
bin\xnet.exe main.lua %*
