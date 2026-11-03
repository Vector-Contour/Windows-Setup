@echo off
rem Step 4: compare the two snapshots and write the report.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0compare-state.ps1\" -Before \"%~dp0snapshot-before-*\" -After \"%~dp0snapshot-after-*\"'"
