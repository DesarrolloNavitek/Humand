@echo off
cd /d "%~dp0"
echo ===== %date% %time% ===== >> log_eliminaciones.txt
python sync_altas_bajas_humand.py --solo-eliminar --confirmar >> log_eliminaciones.txt 2>&1
echo. >> log_eliminaciones.txt
