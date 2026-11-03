@echo off
rem Step 1: snapshot of the fresh PC. Opens an admin PowerShell window.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0capture-state.ps1\" -Label before'"
