@echo off
chcp 65001 >nul
title BSide Olivia Lin - Letter Feature Restore Tool
cd /d "%~dp0"

:menu
cls
echo.
echo   ============================================================
echo     BSide: Olivia Lin  (offline build)
echo     Letter feature restore tool   /   写信功能恢复工具
echo   ============================================================
echo.
echo     [1] Patch my game client     恢复写信功能（推荐）
echo     [2] Check only (no changes)  只检查，不修改
echo     [3] Rollback to original     还原成官方原版
echo     [0] Exit                     退出
echo.
set /p choice=  Choose 1 / 2 / 3 / 0 :

if "%choice%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-letters.ps1"
    echo.
    pause
    goto menu
)
if "%choice%"=="2" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-letters.ps1" -Check
    echo.
    pause
    goto menu
)
if "%choice%"=="3" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-letters.ps1" -Rollback
    echo.
    pause
    goto menu
)
if "%choice%"=="0" exit /b
goto menu
