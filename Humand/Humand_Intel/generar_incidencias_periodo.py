"""
Genera el archivo "Incidencias [Semana/Quincena] X.xlsx" automáticamente,
replicando el formato de columnas que ya usa el analista de nómina.

IMPORTANTE - Alcance de este script:
    Solo llena las columnas cuya fórmula ya fue CONFIRMADA:
      - FALTAS (U) y FALTAS ($$) = SD x días de falta
      - RETARDO_MAYOR (U), RETARDO_MENOR (U)  [unidades, sin $]
      - INCAPACIDAD EG/MATERNIDAD/RIESGO T. (U)  [unidades, sin $]
      - VACACIONES (U)  [unidades, sin $]
    Todas las demás columnas (Premio, montos de retardo, prima vacacional,
    horas extra, etc.) se dejan en 0 porque su fórmula NO está confirmada
    todavía. No se debe usar este archivo para pagar nómina hasta que se
    verifiquen esas fórmulas.

Uso:
    python generar_incidencias_periodo.py --tipo SEMANAL --inicio 2026-06-22 --fin 2026-06-28
    python generar_incidencias_periodo.py --tipo QUINCENAL --inicio 2026-06-01 --fin 2026-06-15
"""

import os
import argparse
import datetime
import pyodbc
import openpyxl
from openpyxl.styles import Font, Alignment, PatternFill
from dotenv import load_dotenv

load_dotenv()

DB_SERVER = os.environ["DB_SERVER"]
DB_PORT = os.environ.get("DB_PORT", "1433")
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PASS = os.environ["DB_PASS"]

# Confirmado con RH: las faltas SIN justificar (sin incidencia aprobada) se
# descuentan a SD x días x factor -- el factor depende del tipo de nómina
# (ya NO es 1.4 fijo, eso quedó obsoleto). Todas las filas 'FALTA' en dbo.Humand
# son injustificadas por diseño: si el día tenía incidencia aprobada, se
# clasifica como JUSTIFICADO, no FALTA.
FACTOR_FALTA_INJUSTIFICADA = {
    "SEMANAL": 1.16,
    "QUINCENAL": 1.20,
}

# Encabezados EXACTOS tal como vienen en Incidencias_Semana_26_2026.xlsx / Incidencias_Quincena_2026_11.xlsx
COLUMNAS = [
    "EMPLEADO", "NOMBRE", "UBICACIÓN", "DEPARTAMENTO", "PUESTO", "FECHA DE INGRESO",
    "Antigüedad", "años", "SD", "SUELDO", "DIAS PAGADOS", "PREMIO", "PREMIO $",
    "VACACIONES (U)", "VACACIONES  ($$)", "DIAS QUE CORRESPONDEN", "% PRIMA VACACIONAL",
    "PRIMA VACACIONAL", "PRIMA GRAVADA", "PRIMA EXENTA",
    "T. EXTRA HORA EXTRA MANUAL (U)", "T. EXTRA ($$)", "SUPLENCIAS (U)", "SUPLENCIAS ($$)",
    "PRIMA DOMINICAL DÍAS", "PRIMA DOMINICAL ($)", "PRIMA GRAVADA", "PRIMA EXENTA",
    "DIAS P SDO (RETROACTIVO)", "DIAS P SDO (RETROACTIVO) $",
    "FALTAS (U)", "FALTAS ($$)", "FALTA SANCION (U)", "FALTA SANCION ($)",
    "PERMISO EN HORAS (U)", "PERMISO EN HORAS ($$)",
    "RETARDO_MAYOR_U", "RETARDO_MENOR_U",
    "INCAPACIDAD     E.G (U)", "INCAPACIDAD E.G ($$)",
    "INCAPACIDAD MATERNIDAD (U)", "INCAPACIDAD MATERNIDAD ($$)",
    "INCAPACIDAD R. TRABAJO (U)", "INCAPACIDAD R. TRABAJO ($$)",
    "OTRAS DEDUCCIIONES ($$)", "LIQ. CAJA AHORRO", "PRESTAMO CAJA DE AHORRO ($$)",
    "APOYO POR MATRIMONIO  ($$)", "PERMISO POR MATRIMONIO (U)", "PERMISO POR MATRIMONIO($$)",
    "PERMISO POR PATERNIDAD (U)", "PERMISO POR PATERNIDAD($$)",
    "PERMISO DEFUNCION (U)", "PERMISO POR DEFUNCION ($$)", "APOYO DEFUNCION ($$)",
    "UTILES ESCOLARES $$", "APOYO POR ALUMBRAMIENTO", "DEVOLUC DESC VARI ($$)",
    "DIFERENCIAS FONACOT", "BONO REFERIDOS", "OPTICA",
    "PREMIO DE ANTIGÜEDAD DIAS", "PREMIO DE ANTIGÜEDAD      ($$$)",
    "DÍAS ECONOMICOS DIAS", "DÍAS ECONOMICOS      ($$$)",
    "ANIVERSARIO SINDICAL $$", "PREMIO ASISTENCIA MENSUAL", "COMPENSACION",
    "CUOTA SINDICAL EXTRAORDINARIA", "BONO ANUAL",
]

# Columnas que SÍ llenamos con datos reales (el resto queda en 0)
COLUMNAS_CONFIRMADAS = {
    "UBICACIÓN",
    "FALTAS (U)", "FALTAS ($$)",
    "RETARDO_MAYOR_U", "RETARDO_MENOR_U",
    "VACACIONES (U)",
    "INCAPACIDAD     E.G (U)", "INCAPACIDAD MATERNIDAD (U)", "INCAPACIDAD R. TRABAJO (U)",
    "FALTA SANCION (U)", "FALTA SANCION ($)",
}


# =========================================================
# Mapeo COLUMNAS (nombres "bonitos" del Excel) -> nombres válidos de columna SQL
# Se genera una sola vez, en orden, resolviendo duplicados (ej. "PRIMA GRAVADA"
# aparece 2 veces en el Excel original) agregando sufijo _2, _3, etc.
# =========================================================
import re


def _sanitizar_nombre_sql(nombre: str, usados: dict) -> str:
    limpio = re.sub(r"[^0-9A-Za-zÀ-ÿ]+", "_", nombre).strip("_")
    limpio = re.sub(r"_+", "_", limpio)
    if not limpio:
        limpio = "COL"
    if limpio[0].isdigit():
        limpio = "C_" + limpio
    if limpio not in usados:
        usados[limpio] = 1
        return limpio
    usados[limpio] += 1
    return f"{limpio}_{usados[limpio]}"


def _construir_mapa_columnas_sql():
    """Lista posicional (no diccionario) porque COLUMNAS tiene nombres
    duplicados (ej. 'PRIMA GRAVADA' aparece 2 veces) -- un diccionario
    colapsaría ambas apariciones en una sola."""
    usados = {}
    return [_sanitizar_nombre_sql(col, usados) for col in COLUMNAS]


NOMBRES_SQL = _construir_mapa_columnas_sql()  # misma longitud y orden que COLUMNAS
IDX_EMPLEADO = COLUMNAS.index("EMPLEADO")

# Columnas de texto/fecha (todo lo demás se trata como numérico FLOAT)
COLUMNAS_TEXTO = {"EMPLEADO", "NOMBRE", "UBICACIÓN", "DEPARTAMENTO", "PUESTO", "Antigüedad"}
COLUMNAS_FECHA = {"FECHA DE INGRESO"}


def crear_tabla_reporte_si_no_existe(cursor, conn):
    """Crea dbo.ReporteIncidenciasPeriodo con TODAS las columnas del Excel,
    si todavía no existe. No borra ni modifica una tabla ya existente."""
    cursor.execute("SELECT OBJECT_ID('dbo.ReporteIncidenciasPeriodo', 'U')")
    if cursor.fetchone()[0] is not None:
        return

    definiciones = [
        "id INT IDENTITY(1,1) PRIMARY KEY",
        "Periodo VARCHAR(10) NOT NULL",
        "TipoNomina VARCHAR(20) NOT NULL",
        "FechaInicio DATE NOT NULL",
        "FechaFin DATE NOT NULL",
    ]
    for col, nombre_sql in zip(COLUMNAS, NOMBRES_SQL):
        if col in COLUMNAS_TEXTO:
            tipo_sql = "NVARCHAR(255)"
        elif col in COLUMNAS_FECHA:
            tipo_sql = "DATE"
        else:
            tipo_sql = "FLOAT"
        definiciones.append(f"[{nombre_sql}] {tipo_sql} NULL")
    definiciones.append("GeneradoEn DATETIME2 DEFAULT GETDATE()")
    definiciones.append(
        f"CONSTRAINT UQ_ReporteIncidenciasPeriodo UNIQUE (Periodo, TipoNomina, [{NOMBRES_SQL[IDX_EMPLEADO]}])"
    )

    sql_create = "CREATE TABLE dbo.ReporteIncidenciasPeriodo (\n    " + ",\n    ".join(definiciones) + "\n)"
    cursor.execute(sql_create)
    conn.commit()
    print("Tabla dbo.ReporteIncidenciasPeriodo creada.")


def guardar_fila_completa_en_sql(cursor, conn, periodo, tipo_nomina, fecha_inicio, fecha_fin, fila: dict):
    """Guarda (o actualiza) la fila completa de un empleado -- las 72 columnas
    tal cual salen en el Excel -- en dbo.ReporteIncidenciasPeriodo."""
    nombres_sql = NOMBRES_SQL
    valores = [fila[c] for c in COLUMNAS]

    set_clause = ", ".join(f"[{n}] = ?" for n in nombres_sql)
    insert_cols = ", ".join(f"[{n}]" for n in nombres_sql)
    insert_placeholders = ", ".join("?" for _ in nombres_sql)
    empleado_col = NOMBRES_SQL[IDX_EMPLEADO]

    sql = f"""
        MERGE dbo.ReporteIncidenciasPeriodo AS destino
        USING (SELECT ? AS Periodo, ? AS TipoNomina, ? AS Empleado) AS origen
        ON destino.Periodo = origen.Periodo AND destino.TipoNomina = origen.TipoNomina
           AND destino.[{empleado_col}] = origen.Empleado
        WHEN MATCHED THEN UPDATE SET FechaInicio = ?, FechaFin = ?, {set_clause}, GeneradoEn = GETDATE()
        WHEN NOT MATCHED THEN INSERT (Periodo, TipoNomina, FechaInicio, FechaFin, {insert_cols})
            VALUES (?, ?, ?, ?, {insert_placeholders});
    """
    parametros = (
        [periodo, tipo_nomina, fila["EMPLEADO"]]
        + [fecha_inicio, fecha_fin] + valores
        + [periodo, tipo_nomina, fecha_inicio, fecha_fin] + valores
    )
    cursor.execute(sql, parametros)


def obtener_conexion():
    conn_str = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER={DB_SERVER},{DB_PORT};DATABASE={DB_NAME};"
        f"UID={DB_USER};PWD={DB_PASS}"
    )
    return pyodbc.connect(conn_str)


def calcular_antiguedad(fecha_alta, fecha_referencia: datetime.date) -> str:
    if fecha_alta is None:
        return ""
    if isinstance(fecha_alta, datetime.datetime):
        fecha_alta = fecha_alta.date()
    dias_totales = (fecha_referencia - fecha_alta).days
    anios = dias_totales // 365
    resto = dias_totales % 365
    meses = resto // 30
    dias = resto % 30
    return f"{anios}años{meses}meses{dias}dias"


def obtener_empleados(cursor):
    """Trae la info base de cada empleado activo desde Intelisis.Personal,
    incluyendo la ubicación real (nombre de sucursal) vía Personal.SucursalTrabajo."""
    cursor.execute(
        """
        SELECT p.Personal, p.Nombre, p.ApellidoPaterno, p.ApellidoMaterno, p.Departamento, p.Puesto,
               p.FechaAlta, p.SueldoDiario, p.SueldoMensual, p.PeriodoTipo,
               p.SucursalTrabajo, s.Nombre AS UbicacionNombre
        FROM dbo.Personal p
        LEFT JOIN dbo.Sucursal s ON s.Sucursal = p.SucursalTrabajo
        WHERE p.Estatus IS NULL OR p.Estatus <> 'BAJA'
        """
    )
    empleados = {}
    for row in cursor.fetchall():
        personal_id = str(row.Personal).strip().zfill(6)
        nombre_completo = f"{row.ApellidoPaterno or ''} {row.ApellidoMaterno or ''} {row.Nombre or ''}".strip()
        ubicacion = f"{row.SucursalTrabajo} {row.UbicacionNombre}".strip() if row.UbicacionNombre else None
        empleados[personal_id] = {
            "nombre": nombre_completo,
            "departamento": row.Departamento,
            "puesto": row.Puesto,
            "ubicacion": ubicacion,
            "fecha_alta": row.FechaAlta,
            "sd": float(row.SueldoDiario) if row.SueldoDiario else 0,
            "sueldo": float(row.SueldoMensual) if row.SueldoMensual else 0,
            "tipo_nomina": (row.PeriodoTipo or "").strip().upper(),
        }
    return empleados


def obtener_faltas(cursor, fecha_inicio, fecha_fin):
    """
    Cuenta las filas de FALTA que ya sintetizó sync_humand_intelisis.py
    (día laboral según Humand, sin marcaje, sin incidencia que lo justifique).
    Ya no se infieren aquí "días sin marcaje" a ciegas, porque eso contaba
    también los descansos como falta.
    """
    cursor.execute(
        """
        SELECT employeeId, COUNT(*) AS dias_falta
        FROM dbo.Humand
        WHERE fecha BETWEEN ? AND ? AND clasificacion = 'FALTA'
        GROUP BY employeeId
        """,
        fecha_inicio, fecha_fin,
    )
    faltas = {}
    for row in cursor.fetchall():
        faltas[row.employeeId] = row.dias_falta
    return faltas


def obtener_retardos(cursor, fecha_inicio, fecha_fin):
    cursor.execute(
        """
        SELECT employeeId,
               SUM(CASE WHEN tipoMarcaje='ENTRADA' AND clasificacion='RETARDO_MAYOR' THEN 1 ELSE 0 END) AS mayores,
               SUM(CASE WHEN clasificacion IN ('RETARDO_MENOR') THEN 1 ELSE 0 END) AS menores
        FROM dbo.Humand
        WHERE fecha BETWEEN ? AND ?
        GROUP BY employeeId
        """,
        fecha_inicio, fecha_fin,
    )
    resultado = {}
    for row in cursor.fetchall():
        resultado[row.employeeId] = {"mayores": row.mayores or 0, "menores": row.menores or 0}
    return resultado


def obtener_incidencias_por_tipo(cursor, fecha_inicio, fecha_fin):
    cursor.execute(
        """
        SELECT Personal, TipoIncidencia, FechaInicio, FechaFin
        FROM dbo.IncidenciaHumand
        WHERE Estatus = 'APROBADO' AND FechaFin >= ? AND FechaInicio <= ?
        """,
        fecha_inicio, fecha_fin,
    )
    resultado = {}
    for row in cursor.fetchall():
        clave = str(row.Personal).strip().zfill(6)
        ini = max(row.FechaInicio, fecha_inicio)
        fin = min(row.FechaFin, fecha_fin)
        n_dias = (fin - ini).days + 1
        resultado.setdefault(clave, {})
        resultado[clave][row.TipoIncidencia] = resultado[clave].get(row.TipoIncidencia, 0) + n_dias
    return resultado


def guardar_en_sql(cursor, conn, periodo, tipo_nomina, fecha_inicio, fecha_fin, personal_id, datos, faltas, faltas_monto, retardo_mayor, retardo_menor, inc_eg, inc_mat, inc_acc, vac):
    cursor.execute(
        """
        MERGE dbo.IncidenciasPeriodoNomina AS destino
        USING (SELECT ? AS Periodo, ? AS TipoNomina, ? AS EmployeeId) AS origen
        ON destino.Periodo = origen.Periodo AND destino.TipoNomina = origen.TipoNomina AND destino.EmployeeId = origen.EmployeeId
        WHEN MATCHED THEN UPDATE SET
            FechaInicio = ?, FechaFin = ?, NombreColaborador = ?, Departamento = ?, Puesto = ?, SueldoDiario = ?,
            FaltasU = ?, FaltasMonto = ?, RetardoMayorU = ?, RetardoMenorU = ?,
            IncapacidadEnfermedadU = ?, IncapacidadMaternidadU = ?, IncapacidadAccidenteU = ?, VacacionesU = ?,
            GeneradoEn = GETDATE()
        WHEN NOT MATCHED THEN INSERT (
            Periodo, TipoNomina, FechaInicio, FechaFin, EmployeeId, NombreColaborador, Departamento, Puesto, SueldoDiario,
            FaltasU, FaltasMonto, RetardoMayorU, RetardoMenorU,
            IncapacidadEnfermedadU, IncapacidadMaternidadU, IncapacidadAccidenteU, VacacionesU
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """,
        periodo, tipo_nomina, personal_id,
        fecha_inicio, fecha_fin, datos["nombre"], datos["departamento"], datos["puesto"], datos["sd"],
        faltas, faltas_monto, retardo_mayor, retardo_menor, inc_eg, inc_mat, inc_acc, vac,
        periodo, tipo_nomina, fecha_inicio, fecha_fin, personal_id, datos["nombre"], datos["departamento"], datos["puesto"], datos["sd"],
        faltas, faltas_monto, retardo_mayor, retardo_menor, inc_eg, inc_mat, inc_acc, vac,
    )


def obtener_casos_revisar_horario(cursor, fecha_inicio, fecha_fin):
    """Marcajes con desviación tan grande que probablemente sea un cambio de
    turno no registrado (no un retardo real) -- para revisión manual de RH."""
    cursor.execute(
        """
        SELECT employeeId, nombreColaborador, fecha, tipoMarcaje, horaFichaje,
               horarioAsignadoIn, horarioAsignadoOut, minutosDesviacion
        FROM dbo.Humand
        WHERE fecha BETWEEN ? AND ? AND clasificacion = 'REVISAR_HORARIO'
        ORDER BY employeeId, fecha
        """,
        fecha_inicio, fecha_fin,
    )
    return cursor.fetchall()


def obtener_empleados_sin_personal(cursor, fecha_inicio, fecha_fin):
    """
    Empleados con checadas reales en Humand que NO existen en Intelisis.Personal.
    No se les puede calcular nada en pesos (no hay SueldoDiario/PeriodoTipo),
    pero no deben desaparecer sin explicación -> se listan aparte.
    """
    cursor.execute(
        """
        SELECT h.employeeId, MAX(h.nombreColaborador) AS nombre,
               COUNT(DISTINCT h.fecha) AS dias_con_actividad,
               SUM(CASE WHEN h.clasificacion = 'FALTA' THEN 1 ELSE 0 END) AS faltas,
               SUM(CASE WHEN h.tipoMarcaje = 'ENTRADA' AND h.clasificacion = 'RETARDO_MAYOR' THEN 1 ELSE 0 END) AS retardos_mayores,
               SUM(CASE WHEN h.clasificacion = 'RETARDO_MENOR' THEN 1 ELSE 0 END) AS retardos_menores
        FROM dbo.Humand h
        LEFT JOIN dbo.Personal p ON p.Personal = h.employeeId OR CAST(p.Personal AS VARCHAR) = h.employeeId
        WHERE h.fecha BETWEEN ? AND ? AND p.Personal IS NULL
        GROUP BY h.employeeId
        ORDER BY h.employeeId
        """,
        fecha_inicio, fecha_fin,
    )
    return cursor.fetchall()


def actualizar_solo_sql(tipo_nomina_filtro, fecha_inicio, fecha_fin, periodo):
    """
    Recalcula y guarda en SQL (IncidenciasPeriodoNomina + ReporteIncidenciasPeriodo)
    para un periodo, SIN generar un archivo Excel visible para el usuario -- se
    usa desde sync_humand_intelisis.py para mantener las tablas actualizadas
    automáticamente en cada corrida. Reutiliza generar_excel() completa (mismo
    cálculo ya probado), mandando la salida a un archivo temporal descartable.
    """
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".xlsx", delete=False) as tmp:
        ruta_temporal = tmp.name
    try:
        generar_excel(tipo_nomina_filtro, fecha_inicio, fecha_fin, ruta_temporal, periodo=periodo)
    finally:
        if os.path.exists(ruta_temporal):
            os.remove(ruta_temporal)


def generar_excel(tipo_nomina_filtro, fecha_inicio, fecha_fin, ruta_salida, periodo=None):
    conn = obtener_conexion()
    cursor = conn.cursor()

    if periodo:
        crear_tabla_reporte_si_no_existe(cursor, conn)

    empleados = obtener_empleados(cursor)
    faltas_por_empleado = obtener_faltas(cursor, fecha_inicio, fecha_fin)
    retardos = obtener_retardos(cursor, fecha_inicio, fecha_fin)
    incidencias = obtener_incidencias_por_tipo(cursor, fecha_inicio, fecha_fin)

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Incidencias"

    # Encabezado
    for col_idx, nombre_col in enumerate(COLUMNAS, start=1):
        celda = ws.cell(row=1, column=col_idx, value=nombre_col)
        celda.font = Font(bold=True)
        if nombre_col in COLUMNAS_CONFIRMADAS:
            celda.fill = PatternFill("solid", fgColor="C6E0B4")  # verde: confirmado
        else:
            celda.fill = PatternFill("solid", fgColor="F2F2F2")  # gris: NO confirmado, queda en 0

    fila_actual = 2
    for personal_id, datos in sorted(empleados.items()):
        if tipo_nomina_filtro and datos["tipo_nomina"] != tipo_nomina_filtro:
            continue

        fila = {c: 0 for c in COLUMNAS}
        fila["EMPLEADO"] = personal_id
        fila["NOMBRE"] = datos["nombre"]
        fila["UBICACIÓN"] = datos["ubicacion"]
        fila["DEPARTAMENTO"] = datos["departamento"]
        fila["PUESTO"] = datos["puesto"]
        fila["FECHA DE INGRESO"] = datos["fecha_alta"]
        fila["Antigüedad"] = calcular_antiguedad(datos["fecha_alta"], fecha_fin)
        fila["SD"] = datos["sd"]
        fila["SUELDO"] = datos["sueldo"]

        # --- Faltas: ya vienen contadas de dbo.Humand (clasificacion='FALTA'),
        # sintetizadas por sync_humand_intelisis.py usando el calendario laboral real de Humand ---
        faltas = faltas_por_empleado.get(personal_id, 0)
        fila["FALTAS (U)"] = faltas
        fila["FALTAS ($$)"] = round(faltas * datos["sd"] * FACTOR_FALTA_INJUSTIFICADA[datos["tipo_nomina"]], 2)

        # --- Retardos (solo unidades, $ sin confirmar) ---
        r = retardos.get(personal_id, {"mayores": 0, "menores": 0})
        fila["RETARDO_MAYOR_U"] = r["mayores"]
        fila["RETARDO_MENOR_U"] = r["menores"]

        # --- Incapacidades y permisos (solo unidades) ---
        inc = incidencias.get(personal_id, {})
        inc_eg = inc.get("INCAPACIDAD_ENFERMEDAD", 0)
        inc_mat = inc.get("INCAPACIDAD_MATERNIDAD", 0)
        inc_acc = inc.get("INCAPACIDAD_ACCIDENTE", 0)
        vac = inc.get("VACACIONES", 0)
        fila["INCAPACIDAD     E.G (U)"] = inc_eg
        fila["INCAPACIDAD MATERNIDAD (U)"] = inc_mat
        fila["INCAPACIDAD R. TRABAJO (U)"] = inc_acc
        fila["VACACIONES (U)"] = vac

        # --- Permiso sin goce: única incidencia "justificada" que sí descuenta,
        #     confirmado: SD x días x 1 (INCAPACIDAD/VACACIONES/PERMISO_CON_GOCE no descuentan)
        permiso_sin_goce = inc.get("PERMISO_SIN_GOCE", 0)
        fila["FALTA SANCION (U)"] = permiso_sin_goce
        fila["FALTA SANCION ($)"] = round(permiso_sin_goce * datos["sd"], 2)

        if periodo:
            guardar_en_sql(
                cursor, conn, periodo, tipo_nomina_filtro, fecha_inicio, fecha_fin, personal_id, datos,
                faltas, fila["FALTAS ($$)"], r["mayores"], r["menores"], inc_eg, inc_mat, inc_acc, vac,
            )
            guardar_fila_completa_en_sql(cursor, conn, periodo, tipo_nomina_filtro, fecha_inicio, fecha_fin, fila)

        for col_idx, nombre_col in enumerate(COLUMNAS, start=1):
            ws.cell(row=fila_actual, column=col_idx, value=fila[nombre_col])
        fila_actual += 1

    if periodo:
        conn.commit()
        print(f"Datos también guardados en dbo.IncidenciasPeriodoNomina y dbo.ReporteIncidenciasPeriodo (Periodo={periodo}).")

    # --- Hoja 2: empleados con checadas reales pero SIN alta en Personal ---
    sin_personal = obtener_empleados_sin_personal(cursor, fecha_inicio, fecha_fin)
    ws2 = wb.create_sheet("Sin Alta en Personal")
    headers2 = ["Código", "Nombre (de Humand)", "Días con actividad", "Faltas", "Retardos Mayores", "Retardos Menores"]
    for col_idx, h in enumerate(headers2, start=1):
        celda = ws2.cell(row=1, column=col_idx, value=h)
        celda.font = Font(bold=True)
        celda.fill = PatternFill("solid", fgColor="FFC7CE")  # rojo claro: requiere atención
    for r_idx, fila_sp in enumerate(sin_personal, start=2):
        ws2.cell(row=r_idx, column=1, value=fila_sp.employeeId)
        ws2.cell(row=r_idx, column=2, value=fila_sp.nombre)
        ws2.cell(row=r_idx, column=3, value=fila_sp.dias_con_actividad)
        ws2.cell(row=r_idx, column=4, value=fila_sp.faltas)
        ws2.cell(row=r_idx, column=5, value=fila_sp.retardos_mayores)
        ws2.cell(row=r_idx, column=6, value=fila_sp.retardos_menores)
    for col_idx, ancho in enumerate([12, 35, 14, 10, 16, 16], start=1):
        ws2.column_dimensions[openpyxl.utils.get_column_letter(col_idx)].width = ancho
    if sin_personal:
        print(f"ATENCIÓN: {len(sin_personal)} código(s) con checadas pero sin alta en Personal (ver hoja 'Sin Alta en Personal').")

    # --- Hoja 3: marcajes con desviación absurda (probable cambio de turno no registrado) ---
    revisar = obtener_casos_revisar_horario(cursor, fecha_inicio, fecha_fin)
    ws3 = wb.create_sheet("Revisar Horario")
    headers3 = ["Código", "Nombre", "Fecha", "Marcaje", "Hora Real", "Horario Esperado In", "Horario Esperado Out", "Desviación (min)"]
    for col_idx, h in enumerate(headers3, start=1):
        celda = ws3.cell(row=1, column=col_idx, value=h)
        celda.font = Font(bold=True)
        celda.fill = PatternFill("solid", fgColor="FFEB9C")  # amarillo: revisar, no es un error confirmado
    for r_idx, fila_r in enumerate(revisar, start=2):
        ws3.cell(row=r_idx, column=1, value=fila_r.employeeId)
        ws3.cell(row=r_idx, column=2, value=fila_r.nombreColaborador)
        ws3.cell(row=r_idx, column=3, value=fila_r.fecha)
        ws3.cell(row=r_idx, column=4, value=fila_r.tipoMarcaje)
        ws3.cell(row=r_idx, column=5, value=fila_r.horaFichaje)
        ws3.cell(row=r_idx, column=6, value=fila_r.horarioAsignadoIn)
        ws3.cell(row=r_idx, column=7, value=fila_r.horarioAsignadoOut)
        ws3.cell(row=r_idx, column=8, value=fila_r.minutosDesviacion)
    for col_idx, ancho in enumerate([12, 30, 12, 16, 20, 18, 18, 16], start=1):
        ws3.column_dimensions[openpyxl.utils.get_column_letter(col_idx)].width = ancho
    if revisar:
        print(f"ATENCIÓN: {len(revisar)} marcaje(s) con desviación >4h, probable cambio de turno no registrado (ver hoja 'Revisar Horario').")

    cursor.close()
    conn.close()

    # Ajuste de ancho de columnas
    for col_idx in range(1, len(COLUMNAS) + 1):
        ws.column_dimensions[openpyxl.utils.get_column_letter(col_idx)].width = 14

    ws.freeze_panes = "A2"

    wb.save(ruta_salida)
    print(f"Archivo generado: {ruta_salida}")
    print(f"Filas de empleados: {fila_actual - 2}")
    print("Verde = columna con fórmula confirmada. Gris = columna en 0, fórmula NO confirmada todavía.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--tipo", choices=["SEMANAL", "QUINCENAL"], required=True)
    parser.add_argument("--inicio", required=True, help="YYYY-MM-DD")
    parser.add_argument("--fin", required=True, help="YYYY-MM-DD")
    parser.add_argument("--salida", default=None)
    parser.add_argument("--periodo", default=None, help="Ej. 'Q-13' o 'S-26'. Si se da, también guarda en dbo.IncidenciasPeriodoNomina")
    args = parser.parse_args()

    fecha_inicio = datetime.date.fromisoformat(args.inicio)
    fecha_fin = datetime.date.fromisoformat(args.fin)
    ruta_salida = args.salida or f"Incidencias_{args.tipo}_{args.inicio}_a_{args.fin}.xlsx"

    generar_excel(args.tipo, fecha_inicio, fecha_fin, ruta_salida, periodo=args.periodo)
