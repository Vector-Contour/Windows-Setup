@echo off
rem Step 3: snapshot after you have set the PC up. Opens an admin PowerShell window.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0capture-state.ps1\" -Label after'"
