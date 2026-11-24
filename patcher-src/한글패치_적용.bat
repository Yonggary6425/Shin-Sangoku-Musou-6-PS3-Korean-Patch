@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0data\hanpatch.ps1" -Mode apply -GameRoot "%~1"
pause
