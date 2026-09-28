@echo off
cd /d "%~dp0\..\.."
python scripts\checks\verify.py
exit /b %ERRORLEVEL%
