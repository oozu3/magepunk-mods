@echo off
chcp 65001 >nul
title Sincronizar Mods - Magepunk SMP
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sincronizar.ps1"
if errorlevel 1 (
  echo.
  echo O script terminou com erro.
  pause
)
