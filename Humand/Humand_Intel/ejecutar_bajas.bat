@echo off
cd /d "%~dp0"
echo ===== %date% %time% ===== >> log_bajas.txt
python sync_altas_bajas_humand.py --solo-bajas --confirmar >> log_bajas.txt 2>&1
echo. >> log_bajas.txt
