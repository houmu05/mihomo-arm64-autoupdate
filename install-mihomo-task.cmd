@echo off
REM install-mihomo-task.cmd — 注册「每周自动更新 mihomo 内核」计划任务（双击或命令行入口）
REM 用法: install-mihomo-task.cmd <auto-update-mihomo.sh 的路径> [WSL 发行版]
REM   例:  install-mihomo-task.cmd F:\mihomo\auto-update-mihomo.sh Debian
setlocal

if "%~1"=="" (
  echo Usage: %~nx0 ^<path-to-auto-update-mihomo.sh^> [wsl-distro]
  echo   e.g. %~nx0 F:\mihomo\auto-update-mihomo.sh Debian
  echo.
  echo Run this file from Windows, not from inside WSL.
  pause
  exit /b 2
)

set "DISTRO=%~2"
if "%DISTRO%"=="" set "DISTRO=Debian"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-mihomo-task.ps1" -ScriptPath "%~1" -Distro "%DISTRO%"
if errorlevel 1 (
  echo.
  echo Registration failed.
  echo Run this file from Windows, not from WSL.
  pause
  exit /b 1
)
echo.
echo Registration completed.
pause
