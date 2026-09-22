@echo off
cd /d "%~dp0"
echo ===== %date% %time% ===== >> log_altas.txt
python sync_altas_bajas_humand.py --solo-altas --confirmar >> log_altas.txt 2>&1
echo. >> log_altas.txt
