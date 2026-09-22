"""
Sincroniza fichajes de Humand hacia la tabla `Humand` en NVTEST (Intelisis),
clasificando cada marcaje según el Reglamento de Asistencia (tolerancias,
retardo menor/mayor, salida anticipada, comida por duración, promotores,
e incidencias/justificaciones).

Flujo:
    1. Lee la última fecha de corrida exitosa (tabla HumandSyncControl).
    2. Trae empleados de Humand (GET /users, filtrados a Navitek) y los cruza
       con Intelisis.Personal (PeriodoTipo, Puesto -> promotor o no).
    3. Trae incidencias aprobadas de Intelisis.IncidenciaHumand para el rango.
    4. Trae day-summaries de Humand (fichajes + horario asignado) para el
       rango [última corrida, hoy], partiendo el rango en bloques de máximo
       31 días (límite de la API de Humand para este endpoint).
    5. Clasifica cada marcaje del día según corresponda:
        - Si hay incidencia aprobada ese día -> JUSTIFICADO (sin retardos).
        - Si es promotor -> visitas a cliente (sin retardos).
        - Si es oficina/planta -> ENTRADA / SALIDA_COMIDA / REGRESO_COMIDA / SALIDA,
          con la comida evaluada por duración (no por horario fijo).
    6. Inserta en dbo.Humand, deduplicando por entryIdHumand.
    7. Actualiza HumandSyncControl con la nueva marca de tiempo.

Requiere: pip install -r requirements.txt (incluye tzdata para Windows)
Se ejecuta cada 30 minutos vía Programador de tareas.
"""

import os
import time
import shutil
import subprocess
import json as jsonlib
import logging
import datetime
from zoneinfo import ZoneInfo
from urllib.parse import urlencode

import pyodbc
import requests
from dotenv import load_dotenv

import generar_incidencias_periodo as gip

load_dotenv()

HUMAND_API_KEY = os.environ["HUMAND_API_KEY"]
DB_SERVER = os.environ["DB_SERVER"]
DB_PORT = os.environ.get("DB_PORT", "1433")
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PASS = os.environ["DB_PASS"]

HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "Authorization": f"Basic {HUMAND_API_KEY}",
}

BASE_URL = "https://api-prod.humand.co/public/api/v1"
ZONA_HORARIA_LOCAL = ZoneInfo("America/Mexico_City")

MAX_INTENTOS_HTTP = 4
TIMEOUT_SEGUNDOS = 30
TAMANO_LOTE_EMPLEADOS = 25  # cuántos employeeIds mandamos por llamada a day-summaries
MAX_DIAS_POR_RANGO = 31     # límite de la API de Humand para day-summaries

# --- Tolerancias según Reglamento de Asistencia ---
TOLERANCIA_MINUTOS = 10       # Artículo 1: 10 min de tolerancia en entrada y comida
LIMITE_RETARDO_MENOR = 30     # Artículo 3: 11-30 min = retardo menor

# Si la desviación es mayor a esto, lo más probable es un cambio de turno no
# registrado (sobre todo en fechas antes del 22-jul-2026, donde usamos el
# horario fijo semanal de respaldo) -- NO se autoclasifica como retardo real,
# se marca aparte para revisión manual.
DESVIACION_MAXIMA_RAZONABLE_MIN = 240  # 4 horas
DURACION_COMIDA_MINUTOS = 60  # 1 hora de comida (Artículo 1); la tolerancia se aplica sobre el exceso de esta duración

# Punto 3.2 (regla de negocio): con 3 checadas, si el hueco entre la 2da y la
# 3ra es MENOR a este umbral, se interpreta como "salió y regresó de comer"
# (checada 3 = REGRESO_COMIDA, con alerta de que faltó la SALIDA final).
# Si es MAYOR O IGUAL, se interpreta como que en realidad ya no regresó de
# comer (checada 3 = SALIDA real, con alerta de que faltó el REGRESO_COMIDA).
UMBRAL_COMIDA_MAX_PARA_REGRESO_MIN = 120


def combinar_clasificacion(base: str, alerta: str) -> str:
    """Combina la clasificación normal (ej. RETRASO_COMIDA_MENOR) con una
    alerta de checada faltante (ej. OLVIDO_CHECAR_SALIDA) en un solo valor,
    separadas por '|' para poder distinguirlas después con LIKE si hace falta."""
    if not base:
        return alerta
    if not alerta:
        return base
    return f"{base}|{alerta}"

RAZON_SOCIAL_OBJETIVO = "Navitek"  # Esta API Key tiene acceso a varias razones sociales (ej. también 'Burbutek')
PALABRAS_CLAVE_PROMOTOR = ("PROMOTOR", "VENDEDOR")  # Si Personal.Puesto contiene alguna de estas, se clasifica como visitas, no como oficina

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("sync_intelisis")


def es_de_navitek(usuario: dict) -> bool:
    for seg in usuario.get("segmentations", []):
        if seg.get("group") == "Razón Social" and seg.get("item") == RAZON_SOCIAL_OBJETIVO:
            return True
    return False


def dividir_rango_fechas(fecha_inicio: datetime.date, fecha_fin: datetime.date, max_dias: int = MAX_DIAS_POR_RANGO):
    """Parte un rango de fechas en bloques de a lo más `max_dias` días (límite de la API)."""
    bloques = []
    actual = fecha_inicio
    while actual <= fecha_fin:
        fin_bloque = min(fecha_fin, actual + datetime.timedelta(days=max_dias - 1))
        bloques.append((actual, fin_bloque))
        actual = fin_bloque + datetime.timedelta(days=1)
    return bloques


# =========================================================
# HTTP con reintentos (+ respaldo curl.exe ante fallas de requests)
# =========================================================

CODIGOS_REINTENTABLES = {429, 500, 502, 503, 504}
CURL_DISPONIBLE = shutil.which("curl") is not None


class RespuestaCurl:
    """Envoltorio mínimo para que la respuesta de curl se use igual que una de requests."""
    def __init__(self, status_code, text):
        self.status_code = status_code
        self.text = text

    def json(self):
        return jsonlib.loads(self.text)


def solicitar_via_curl(metodo, url, headers=None, params=None, timeout=30):
    """Respaldo usando curl.exe, que en Windows usa schannel y maneja bien la
    renegociación TLS que algunas redes corporativas fuerzan (a diferencia de
    urllib3/OpenSSL, que a veces se queda colgado ahí)."""
    if params:
        url = f"{url}?{urlencode(params)}"

    cmd = ["curl", "-s", "-X", metodo, "--max-time", str(timeout)]
    for k, v in (headers or {}).items():
        cmd += ["-H", f"{k}: {v}"]
    cmd += ["-w", "\n%{http_code}", url]

    resultado = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10)
    salida = resultado.stdout
    if "\n" not in salida:
        raise RuntimeError(f"curl.exe no devolvió una respuesta interpretable: {resultado.stderr}")

    cuerpo, status_code_str = salida.rsplit("\n", 1)
    try:
        status_code = int(status_code_str.strip())
    except ValueError:
        status_code = 0
    return RespuestaCurl(status_code, cuerpo)


def solicitar_con_reintentos(metodo, url, headers=None, params=None, **kwargs):
    ultimo_error = None
    resp = None
    for intento in range(1, MAX_INTENTOS_HTTP + 1):
        try:
            resp = requests.request(metodo, url, headers=headers, params=params, timeout=TIMEOUT_SEGUNDOS, **kwargs)
            if resp.status_code in CODIGOS_REINTENTABLES and intento < MAX_INTENTOS_HTTP:
                espera = 2 ** intento
                log.warning(
                    f"Intento {intento}/{MAX_INTENTOS_HTTP}: el servidor respondió "
                    f"{resp.status_code} (temporal). Reintentando en {espera}s..."
                )
                time.sleep(espera)
                continue
            return resp
        except requests.exceptions.RequestException as e:
            ultimo_error = e
            log.warning(f"Intento {intento}/{MAX_INTENTOS_HTTP} con requests falló ({e}).")

            if intento == MAX_INTENTOS_HTTP and CURL_DISPONIBLE:
                log.warning("Agotados los reintentos con requests. Probando con curl.exe como respaldo...")
                try:
                    return solicitar_via_curl(metodo, url, headers=headers, params=params, timeout=TIMEOUT_SEGUNDOS)
                except Exception as curl_error:
                    log.error(f"curl.exe también falló: {curl_error}")
            else:
                espera = 2 ** intento
                log.warning(f"Reintentando en {espera}s...")
                time.sleep(espera)
    if ultimo_error:
        raise ultimo_error
    return resp


def obtener_conexion():
    conn_str = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER={DB_SERVER},{DB_PORT};DATABASE={DB_NAME};"
        f"UID={DB_USER};PWD={DB_PASS}"
    )
    return pyodbc.connect(conn_str)


# =========================================================
# 1. Control de corridas (sync incremental)
# =========================================================

def obtener_ultima_ejecucion(cursor) -> datetime.datetime:
    cursor.execute(
        "SELECT TOP 1 ultimaEjecucionUtc FROM dbo.HumandSyncControl ORDER BY id DESC"
    )
    fila = cursor.fetchone()
    if fila is None:
        return datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)
    return fila[0].replace(tzinfo=datetime.timezone.utc)


def registrar_ejecucion(cursor, conn, registros_procesados: int):
    ahora_utc = datetime.datetime.now(datetime.timezone.utc)
    cursor.execute(
        "INSERT INTO dbo.HumandSyncControl (ultimaEjecucionUtc, registrosProcesados) VALUES (?, ?)",
        ahora_utc.replace(tzinfo=None),
        registros_procesados,
    )
    conn.commit()
    log.info(f"Corrida registrada: {ahora_utc.isoformat()} | {registros_procesados} registros procesados.")


# =========================================================
# 2. Empleados: Humand (GET /users) + Intelisis (Personal + Incidencias)
# =========================================================

LIMITE_MAXIMO_PAGINAS_USUARIOS = 50  # ~2,500 usuarios; si se supera, algo anda mal con el alcance del API Key


def obtener_empleados_humand() -> list:
    empleados = []
    page = 1
    total_paginas = None

    while True:
        log.info(f"Consultando página {page} de usuarios de Humand...")
        resp = solicitar_con_reintentos(
            "GET", f"{BASE_URL}/users",
            headers=HEADERS, params={"limit": 50, "page": page},
        )
        if resp.status_code != 200:
            raise RuntimeError(f"Error al listar usuarios de Humand: {resp.status_code} - {resp.text}")

        data = resp.json()
        usuarios = data.get("users", [])

        if total_paginas is None:
            total_registros = data.get("count", len(usuarios))
            total_paginas = max(1, -(-total_registros // 50))
            log.info(f"Total de usuarios reportado por Humand (todas las comunidades): {total_registros} ({total_paginas} páginas)")

            if total_paginas > LIMITE_MAXIMO_PAGINAS_USUARIOS:
                raise RuntimeError(
                    f"ALERTA: Humand reportó {total_registros} usuarios ({total_paginas} páginas), "
                    f"muy por encima del límite esperado ({LIMITE_MAXIMO_PAGINAS_USUARIOS} páginas / "
                    f"~{LIMITE_MAXIMO_PAGINAS_USUARIOS * 50} usuarios). Esto sugiere que el API Key tiene "
                    f"acceso a datos fuera del alcance de Navitek. Se detiene el proceso — "
                    f"verifica el alcance del API Key con soporte de Humand antes de continuar."
                )

        empleados.extend(usuarios)

        if page >= total_paginas or not usuarios:
            break
        page += 1

    de_navitek = [u for u in empleados if es_de_navitek(u)]
    log.info(f"Empleados totales (todas las comunidades): {len(empleados)} | {RAZON_SOCIAL_OBJETIVO}: {len(de_navitek)}.")
    return de_navitek


def obtener_personal_intelisis(cursor) -> dict:
    cursor.execute(
        "SELECT Personal, PeriodoTipo, Estatus, Puesto, Sindicato FROM dbo.Personal WHERE Estatus IS NULL OR Estatus <> 'BAJA'"
    )
    mapa = {}
    for row in cursor.fetchall():
        personal_id, periodo_tipo, estatus, puesto, sindicato = row[0], row[1], row[2], row[3], row[4]
        clave = str(personal_id).strip().zfill(6)
        periodo_normalizado = periodo_tipo.strip().upper() if periodo_tipo else None
        es_promotor = bool(puesto) and any(palabra in puesto.upper() for palabra in PALABRAS_CLAVE_PROMOTOR)
        es_sindicalizado = bool(sindicato) and sindicato.strip().upper() == "SINDICALIZADO"
        mapa[clave] = {
            "personalId": personal_id,
            "periodoTipo": periodo_normalizado,
            "estatus": estatus,
            "puesto": puesto,
            "esPromotor": es_promotor,
            "esSindicalizado": es_sindicalizado,
        }
    log.info(f"Empleados encontrados en Intelisis.Personal (excluyendo BAJA): {len(mapa)}")
    return mapa


def obtener_horario_historico(cursor) -> dict:
    """
    Respaldo de horario fijo por día de la semana, para fechas en las que
    Humand todavía no tenía turnos configurados (antes del 22 de julio 2026).
    Devuelve: {employeeId: {diaSemana(1-7): (horaEntrada, horaSalida)}}
    """
    cursor.execute("SELECT employeeId, diaSemana, horaEntrada, horaSalida FROM dbo.HorarioHistorico")
    mapa = {}
    for row in cursor.fetchall():
        mapa.setdefault(row.employeeId, {})[row.diaSemana] = (row.horaEntrada, row.horaSalida)
    log.info(f"Horario histórico de respaldo cargado: {len(mapa)} empleados.")
    return mapa


def obtener_catalogo_rotativo(cursor) -> dict:
    """
    Catálogo de turnos rotativos por empleado (cargado desde Rotativo.xlsx
    vía cargar_rotativo_excel.py). A diferencia de obtener_catalogo_turnos
    (plano, toda la empresa), este es específico por empleado + día de la
    semana, porque el mismo "Team"/"Área" puede tener varios turnos válidos
    ese día (matutino/vespertino/nocturno) y el colaborador puede rotar
    entre ellos de un día a otro según lo asigne su supervisor.
    Devuelve: {employeeInternalId: {diaSemana(1-7): [(horaEntrada, horaSalida), ...]}}
    """
    cursor.execute(
        """
        SELECT re.Clave, tc.DiaSemana, tc.HoraEntrada, tc.HoraSalida
        FROM dbo.RotativoEmpleados re
        JOIN dbo.RotativoTurnoCatalogo tc
          ON tc.Hoja = re.Hoja
        """
    )
    mapa = {}
    for row in cursor.fetchall():
        mapa.setdefault(row.Clave, {}).setdefault(row.DiaSemana, []).append((row.HoraEntrada, row.HoraSalida))
    log.info(f"Catálogo de turnos rotativos cargado: {len(mapa)} empleados.")
    return mapa


def obtener_catalogo_turnos(cursor) -> list:
    """
    Catálogo de todos los turnos reales que existen en la empresa (matutino,
    vespertino, nocturno, etc.), sacado de los horarios distintos que ya
    tiene asignados la plantilla en HorarioHistorico. Se usa para detectar
    a qué turno se cambió un colaborador un día en particular.
    """
    cursor.execute(
        """
        SELECT DISTINCT horaEntrada, horaSalida
        FROM dbo.HorarioHistorico
        WHERE horaEntrada IS NOT NULL AND horaSalida IS NOT NULL
        """
    )
    catalogo = [(row.horaEntrada, row.horaSalida) for row in cursor.fetchall()]
    log.info(f"Catálogo de turnos detectados en la empresa: {len(catalogo)} distintos -> {catalogo}")
    return catalogo


def _hora_str_a_minutos(hhmm: str) -> int:
    hora, minuto = map(int, hhmm.split(":"))
    return hora * 60 + minuto


def detectar_turno_por_hora_real(hora_real: datetime.datetime, catalogo_turnos: list, umbral_min: int = LIMITE_RETARDO_MENOR):
    """
    Busca en el catálogo el turno cuya hora de entrada esté más cerca de la
    hora real del marcaje (considerando el 'wrap-around' de medianoche para
    turnos nocturnos). Si el mejor candidato está dentro del umbral normal
    de tolerancia, se acepta como el turno real de ese día.
    Devuelve (horaEntrada, horaSalida, diferencia_min) o (None, None, None)
    si ningún turno conocido explica razonablemente la hora real.
    """
    if not catalogo_turnos:
        return None, None, None

    minutos_real = hora_real.hour * 60 + hora_real.minute
    mejor = None
    mejor_diff = None
    for entrada_str, salida_str in catalogo_turnos:
        entrada_min = _hora_str_a_minutos(entrada_str)
        diff_directa = abs(minutos_real - entrada_min)
        diff = min(diff_directa, 1440 - diff_directa)  # por si el turno cruza medianoche
        if mejor_diff is None or diff < mejor_diff:
            mejor_diff = diff
            mejor = (entrada_str, salida_str)

    if mejor is not None and mejor_diff <= umbral_min:
        return mejor[0], mejor[1], mejor_diff
    return None, None, None


# Mapeo: nombre de la política en Humand -> nuestro tipo interno de incidencia
MAPA_POLICY_A_TIPO_INTERNO = {
    "Vacaciones": "VACACIONES",
    "Licencia por maternidad": "INCAPACIDAD_MATERNIDAD",
    "Incapacidad por Enfermedad General": "INCAPACIDAD_ENFERMEDAD",
    "Incapacidad por Riesgo de Trabajo": "INCAPACIDAD_ACCIDENTE",
    "Permiso con Goce de Sueldo": "PERMISO_CON_GOCE",
    "Permiso sin Goce de Sueldo": "PERMISO_SIN_GOCE",
}


def sincronizar_incidencias_desde_humand(cursor, conn, fecha_inicio: str, fecha_fin: str):
    """
    Trae las solicitudes de tiempo libre APROBADAS de Humand para el rango
    dado, y las sincroniza (MERGE) hacia dbo.IncidenciaHumand -- para que
    RH ya no tenga que capturarlas a mano, se jalan solas en cada corrida.
    """
    page = 1
    total_sincronizadas = 0
    while True:
        resp = solicitar_con_reintentos(
            "GET", f"{BASE_URL}/time-off/requests",
            headers=HEADERS,
            params={"states": "APPROVED", "fromDate": fecha_inicio, "toDate": fecha_fin, "page": page, "limit": 50},
        )
        if resp.status_code != 200:
            log.error(f"Error consultando time-off/requests: {resp.status_code} - {resp.text}")
            break

        data = resp.json()
        items = data.get("items", [])

        for item in items:
            issuer = item.get("issuer") or {}
            employee_internal_id = issuer.get("employeeInternalId")
            policy_type_name = (item.get("policyType") or {}).get("name")
            tipo_interno = MAPA_POLICY_A_TIPO_INTERNO.get(policy_type_name)
            fecha_ini = (item.get("from") or {}).get("date")
            fecha_fin_req = (item.get("to") or {}).get("date")
            humand_request_id = item.get("id")

            if not (employee_internal_id and tipo_interno and fecha_ini and fecha_fin_req and humand_request_id):
                log.warning(f"Solicitud de Humand con datos incompletos, se omite: {item.get('id')}")
                continue

            try:
                cursor.execute(
                    """
                    MERGE dbo.IncidenciaHumand AS destino
                    USING (SELECT ? AS HumandRequestId) AS origen
                    ON destino.HumandRequestId = origen.HumandRequestId
                    WHEN MATCHED THEN UPDATE SET
                        Personal = ?, TipoIncidencia = ?, FechaInicio = ?, FechaFin = ?, Estatus = 'APROBADO'
                    WHEN NOT MATCHED THEN INSERT
                        (Personal, TipoIncidencia, FechaInicio, FechaFin, Estatus, Comentario, CapturadoPor, HumandRequestId)
                        VALUES (?, ?, ?, ?, 'APROBADO', 'Sincronizado automáticamente desde Humand', 'sync_humand_intelisis.py', ?);
                    """,
                    humand_request_id,
                    employee_internal_id, tipo_interno, fecha_ini, fecha_fin_req,
                    employee_internal_id, tipo_interno, fecha_ini, fecha_fin_req, humand_request_id,
                )
                total_sincronizadas += 1
            except pyodbc.Error as e:
                log.warning(f"No se pudo sincronizar la incidencia {humand_request_id}: {e}")

        if page >= data.get("totalPages", 1) or not items:
            break
        page += 1

    conn.commit()
    log.info(f"Incidencias sincronizadas desde Humand (time-off/requests): {total_sincronizadas}")


def obtener_dias_especiales(cursor, fecha_inicio: str, fecha_fin: str) -> dict:
    """
    Días que NO deben contar como falta aunque no haya checada ni incidencia
    formal (home office anunciado, cierre de planta, puente, etc.).
    Devuelve: {(employeeId o None): set(fechas)}
        - employeeId=None significa que aplica a TODA la empresa ese día.
    """
    cursor.execute(
        "SELECT fecha, employeeId FROM dbo.DiasEspeciales WHERE fecha BETWEEN ? AND ?",
        fecha_inicio, fecha_fin,
    )
    mapa = {}
    for row in cursor.fetchall():
        clave = row.employeeId  # puede ser None
        mapa.setdefault(clave, set()).add(row.fecha)
    return mapa


def es_dia_especial(dias_especiales: dict, employee_internal_id: str, fecha: datetime.date) -> bool:
    if fecha in dias_especiales.get(None, set()):  # aplica a toda la empresa
        return True
    if fecha in dias_especiales.get(employee_internal_id, set()):  # aplica solo a este empleado
        return True
    return False


def obtener_incidencias_aprobadas(cursor, fecha_inicio: str, fecha_fin: str) -> dict:
    cursor.execute(
        """
        SELECT Personal, TipoIncidencia, FechaInicio, FechaFin
        FROM dbo.IncidenciaHumand
        WHERE Estatus = 'APROBADO'
          AND FechaFin >= ?
          AND FechaInicio <= ?
        """,
        fecha_inicio,
        fecha_fin,
    )
    mapa = {}
    for row in cursor.fetchall():
        personal, tipo, fecha_ini, fecha_fin_row = row[0], row[1], row[2], row[3]
        clave = str(personal).strip().zfill(6)
        mapa.setdefault(clave, []).append((fecha_ini, fecha_fin_row, tipo))
    log.info(f"Incidencias aprobadas encontradas en el rango: {sum(len(v) for v in mapa.values())}")
    return mapa


def buscar_incidencia_del_dia(incidencias_empleado: list, fecha: datetime.date):
    if not incidencias_empleado:
        return None
    for fecha_ini, fecha_fin_row, tipo in incidencias_empleado:
        if fecha_ini <= fecha <= fecha_fin_row:
            return tipo
    return None


# =========================================================
# 3. Day summaries de Humand (fichajes + horario + horas)
# =========================================================

def obtener_day_summaries(employee_ids: list, fecha_inicio: str, fecha_fin: str) -> list:
    """Trae day-summaries para un lote de employeeIds y UN bloque de fechas (<=31 días),
    paginando hasta que la página venga vacía."""
    resultados = []
    page = 1
    MAX_PAGINAS_SEGURIDAD = 200

    while True:
        params = {
            "employeeIds": ",".join(str(e) for e in employee_ids),
            "startDate": fecha_inicio,
            "endDate": fecha_fin,
            "page": page,
            "limit": 50,
        }
        log.info(f"Consultando day-summaries: lote de {len(employee_ids)} empleados, {fecha_inicio}..{fecha_fin}, página {page}...")
        resp = solicitar_con_reintentos(
            "GET", f"{BASE_URL}/time-tracking/day-summaries",
            headers=HEADERS, params=params,
        )
        if resp.status_code != 200:
            log.error(f"Error en day-summaries (lote {employee_ids[:3]}...): {resp.status_code} - {resp.text}")
            return resultados

        data = resp.json()
        items = data.get("items", [])
        log.info(
            f"  -> count={data.get('count')} | totalPages={data.get('totalPages')} | "
            f"items en esta página: {len(items)}"
        )
        resultados.extend(items)

        if not items or page >= MAX_PAGINAS_SEGURIDAD:
            break
        page += 1

    return resultados


def guardar_raw_day_summary(cursor, conn, resumen: dict):
    """Guarda el day-summary completo tal cual, antes de cualquier clasificación."""
    employee_id = resumen.get("employeeId")
    fecha_ref = resumen.get("referenceDate")
    if not employee_id or not fecha_ref:
        return
    entries = resumen.get("entries") or []
    raw_json = jsonlib.dumps(resumen, ensure_ascii=False)
    try:
        cursor.execute(
            """
            MERGE dbo.HumandRawDaySummary AS destino
            USING (SELECT ? AS employeeId, ? AS fecha) AS origen
            ON destino.employeeId = origen.employeeId AND destino.fecha = origen.fecha
            WHEN MATCHED THEN UPDATE SET
                isWorkday = ?, hasSchedule = ?, totalEntries = ?, rawJson = ?, capturadoEn = GETDATE()
            WHEN NOT MATCHED THEN INSERT (employeeId, fecha, isWorkday, hasSchedule, totalEntries, rawJson)
                VALUES (?, ?, ?, ?, ?, ?);
            """,
            employee_id, fecha_ref,
            bool(resumen.get("isWorkday")), bool(resumen.get("hasSchedule")), len(entries), raw_json,
            employee_id, fecha_ref, bool(resumen.get("isWorkday")), bool(resumen.get("hasSchedule")), len(entries), raw_json,
        )
        conn.commit()
    except pyodbc.Error as e:
        log.warning(f"No se pudo guardar el crudo de {employee_id} / {fecha_ref}: {e}")
        conn.rollback()


def dividir_en_lotes(lista, tamano):
    for i in range(0, len(lista), tamano):
        yield lista[i:i + tamano]


# =========================================================
# 4. Clasificación según Reglamento de Asistencia
# =========================================================

def parsear_hora_utc(fecha_iso: str) -> datetime.datetime:
    dt_utc = datetime.datetime.strptime(fecha_iso, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=datetime.timezone.utc)
    return dt_utc.astimezone(ZONA_HORARIA_LOCAL)


def parsear_hora_horario(hhmm: str, fecha_referencia: datetime.date) -> datetime.datetime:
    hora, minuto = map(int, hhmm.split(":"))
    return datetime.datetime.combine(fecha_referencia, datetime.time(hora, minuto), tzinfo=ZONA_HORARIA_LOCAL)


def horas_a_reponer(minutos_tarde: float) -> int:
    """Regla sindicalizados: 11-59 min -> 1h, 1h-1h59 -> 2h, 2h-2h59 -> 3h, etc."""
    return int(minutos_tarde // 60) + 1


def clasificar_entrada_o_regreso(hora_real: datetime.datetime, hora_esperada: datetime.datetime, es_sindicalizado: bool = False):
    diferencia_min = (hora_real - hora_esperada).total_seconds() / 60
    if abs(diferencia_min) > DESVIACION_MAXIMA_RAZONABLE_MIN:
        return "REVISAR_HORARIO", round(diferencia_min)
    if diferencia_min <= TOLERANCIA_MINUTOS:
        return "A_TIEMPO", round(diferencia_min)
    if es_sindicalizado:
        # Sindicalizados no tienen retardo menor/mayor -- pasado el margen de
        # 10 min, se convierte en permiso de horas a reponer con el supervisor.
        return "PERMISO_HORAS", round(diferencia_min)
    elif diferencia_min <= LIMITE_RETARDO_MENOR:
        return "RETARDO_MENOR", round(diferencia_min)
    else:
        return "RETARDO_MAYOR", round(diferencia_min)


def clasificar_salida(hora_real: datetime.datetime, hora_esperada: datetime.datetime):
    diferencia_min = (hora_real - hora_esperada).total_seconds() / 60
    if abs(diferencia_min) > DESVIACION_MAXIMA_RAZONABLE_MIN:
        return "REVISAR_HORARIO", round(diferencia_min)
    if diferencia_min < 0:
        return "SALIDA_ANTICIPADA", round(diferencia_min)
    return "A_TIEMPO", round(diferencia_min)


def clasificar_comida_duracion(hora_salida_comer: datetime.datetime, hora_regreso: datetime.datetime, es_sindicalizado: bool = False):
    duracion_min = (hora_regreso - hora_salida_comer).total_seconds() / 60
    exceso_min = duracion_min - DURACION_COMIDA_MINUTOS
    if abs(exceso_min) > DESVIACION_MAXIMA_RAZONABLE_MIN:
        return "REVISAR_HORARIO", round(exceso_min)
    if exceso_min <= TOLERANCIA_MINUTOS:
        return "REGRESO_CORRECTO", round(exceso_min)
    if es_sindicalizado:
        return "PERMISO_HORAS", round(exceso_min)
    elif exceso_min <= LIMITE_RETARDO_MENOR:
        return "RETRASO_COMIDA_MENOR", round(exceso_min)
    else:
        return "RETRASO_COMIDA_MAYOR", round(exceso_min)


def _base_resultado(entry, employee_internal_id, secuencia, hora_real, tipo_marcaje,
                     horario_in=None, horario_out=None, minutos_desviacion=None,
                     clasificacion=None, tipo_incidencia_aplicada=None):
    return {
        "entryIdHumand": entry["id"],
        "employeeInternalId": employee_internal_id,
        "horaFichaje": hora_real,
        "tipoMarcaje": tipo_marcaje,
        "secuenciaDia": secuencia,
        "horarioAsignadoIn": horario_in,
        "horarioAsignadoOut": horario_out,
        "minutosDesviacion": minutos_desviacion,
        "clasificacion": clasificacion,
        "origenMarcaje": entry.get("source"),
        "pairId": entry.get("pairId"),
        "tipoIncidenciaAplicada": tipo_incidencia_aplicada,
    }


def construir_plan_tipos_marcaje(entries_ordenadas: list) -> list:
    """
    Decide qué representa cada checada del día según CUÁNTAS hay (punto 3.2
    de las reglas de negocio) -- ya no es puramente posicional.
    Devuelve una lista paralela a entries_ordenadas con el tipo_marcaje de
    cada posición, y (para el caso de 3 checadas) si aplica alguna alerta.
    """
    n = len(entries_ordenadas)

    if n == 0:
        return [], None
    if n == 1:
        return ["ENTRADA"], None
    if n == 2:
        return ["ENTRADA", "SALIDA"], None
    if n == 3:
        hora_2 = parsear_hora_utc(entries_ordenadas[1]["time"])
        hora_3 = parsear_hora_utc(entries_ordenadas[2]["time"])
        gap_min = (hora_3 - hora_2).total_seconds() / 60
        if gap_min < UMBRAL_COMIDA_MAX_PARA_REGRESO_MIN:
            # Sí regresó de comer, pero nunca marcó la SALIDA final
            return ["ENTRADA", "SALIDA_COMIDA", "REGRESO_COMIDA"], "OLVIDO_CHECAR_SALIDA"
        else:
            # El hueco es demasiado grande para ser comida -> ya no regresó,
            # esa 3ra checada es la SALIDA real; nunca marcó el REGRESO_COMIDA
            return ["ENTRADA", "SALIDA_COMIDA", "SALIDA"], "OLVIDO_CHECAR_REGRESO_COMIDA"

    # n >= 4: el escenario ideal, más cualquier checada extra de sobra
    plan = ["ENTRADA", "SALIDA_COMIDA", "REGRESO_COMIDA", "SALIDA"]
    for extra_idx in range(4, n):
        plan.append(f"EXTRA_{extra_idx + 1}")
    return plan, None


def clasificar_oficina(entries_ordenadas: list, time_slots: list, fecha_referencia: datetime.date,
                        employee_internal_id: str, horario_historico: dict = None, catalogo_turnos: list = None,
                        es_sindicalizado: bool = False, catalogo_rotativo: dict = None):
    horario_in = time_slots[0]["startTime"] if time_slots else None
    horario_out = time_slots[-1]["endTime"] if time_slots else None

    # Respaldo: si Humand no trae horario (fechas antes del 22-jul-2026 sin turno
    # configurado ahí), usamos el horario fijo por día de la semana del Excel.
    if not horario_in and horario_historico:
        dia_semana = fecha_referencia.isoweekday()  # 1=Lunes ... 7=Domingo
        entrada_hist, salida_hist = horario_historico.get(employee_internal_id, {}).get(dia_semana, (None, None))
        if entrada_hist and salida_hist:
            horario_in = entrada_hist
            horario_out = salida_hist

    # Detección automática de cambio de turno: si la hora real de entrada no
    # coincide con el horario "de casa" del colaborador pero SÍ coincide con
    # otro turno conocido, usamos ese turno detectado para clasificar todo el
    # día, en vez de marcarle un retardo absurdo contra un turno que no le
    # tocaba ese día. Si el colaborador tiene turno ROTATIVO (Rotativo.xlsx),
    # se usan solo los turnos válidos de SU hoja para ESE día de la semana
    # (puede rotar entre matutino/vespertino/nocturno/etc. según lo asigne su
    # supervisor) -- si no, se usa el catálogo plano de toda la empresa.
    if entries_ordenadas and horario_in:
        hora_primera_entrada = parsear_hora_utc(entries_ordenadas[0]["time"])
        hora_nominal_esperada = parsear_hora_horario(horario_in, fecha_referencia)
        diferencia_nominal = abs((hora_primera_entrada - hora_nominal_esperada).total_seconds() / 60)

        if diferencia_nominal > TOLERANCIA_MINUTOS:
            dia_semana = fecha_referencia.isoweekday()
            turnos_candidatos = None
            if catalogo_rotativo and employee_internal_id in catalogo_rotativo:
                turnos_candidatos = catalogo_rotativo[employee_internal_id].get(dia_semana)

            turno_in, turno_out, diff_turno = None, None, None
            if turnos_candidatos:
                turno_in, turno_out, diff_turno = detectar_turno_por_hora_real(hora_primera_entrada, turnos_candidatos)
            elif catalogo_turnos:
                turno_in, turno_out, diff_turno = detectar_turno_por_hora_real(hora_primera_entrada, catalogo_turnos)

            if turno_in and diff_turno < diferencia_nominal:
                log.info(
                    f"Turno detectado distinto al habitual para {employee_internal_id} el {fecha_referencia}: "
                    f"nominal {horario_in}-{horario_out} -> detectado {turno_in}-{turno_out} "
                    f"(desviación {diff_turno:.0f} min vs {diferencia_nominal:.0f} min nominal, "
                    f"{'catálogo rotativo' if turnos_candidatos else 'catálogo general'})"
                )
                horario_in, horario_out = turno_in, turno_out

    plan_tipos, alerta_dia = construir_plan_tipos_marcaje(entries_ordenadas)

    resultados = []
    for idx, entry in enumerate(entries_ordenadas):
        secuencia = idx + 1
        hora_real = parsear_hora_utc(entry["time"])
        tipo_marcaje = plan_tipos[idx]
        clasificacion, minutos_desviacion = None, None

        if tipo_marcaje == "ENTRADA":
            if horario_in:
                hora_esperada = parsear_hora_horario(horario_in, fecha_referencia)
                clasificacion, minutos_desviacion = clasificar_entrada_o_regreso(hora_real, hora_esperada, es_sindicalizado)

        elif tipo_marcaje == "REGRESO_COMIDA":
            hora_salida_comer = parsear_hora_utc(entries_ordenadas[idx - 1]["time"])
            clasificacion, minutos_desviacion = clasificar_comida_duracion(hora_salida_comer, hora_real, es_sindicalizado)
            if alerta_dia:
                clasificacion = combinar_clasificacion(clasificacion, alerta_dia)

        elif tipo_marcaje == "SALIDA":
            if horario_out:
                hora_esperada = parsear_hora_horario(horario_out, fecha_referencia)
                clasificacion, minutos_desviacion = clasificar_salida(hora_real, hora_esperada)
            # Alerta solo aplica a la SALIDA "sustituta" del caso de 3 checadas
            # con hueco grande (n==3) -- no a la SALIDA normal del día de 2 o 4.
            if alerta_dia and len(entries_ordenadas) == 3:
                clasificacion = combinar_clasificacion(clasificacion, alerta_dia)

        elif tipo_marcaje.startswith("EXTRA_"):
            log.warning(f"Marcaje extra detectado (posición {secuencia}) para entry id={entry.get('id')} el {fecha_referencia}")

        # SALIDA_COMIDA nunca lleva clasificación propia (igual que antes)

        resultados.append(_base_resultado(
            entry, employee_internal_id, secuencia, hora_real, tipo_marcaje,
            horario_in, horario_out, minutos_desviacion, clasificacion,
        ))

    return resultados


def clasificar_visitas_promotor(entries_ordenadas: list, employee_internal_id: str):
    resultados = []
    for idx, entry in enumerate(entries_ordenadas):
        secuencia = idx + 1
        hora_real = parsear_hora_utc(entry["time"])
        tipo_marcaje = "VISITA_ENTRADA" if idx % 2 == 0 else "VISITA_SALIDA"
        resultados.append(_base_resultado(entry, employee_internal_id, secuencia, hora_real, tipo_marcaje))
    return resultados


def clasificar_dia_justificado(entries_ordenadas: list, employee_internal_id: str, tipo_incidencia: str):
    etiquetas = ["ENTRADA", "SALIDA_COMIDA", "REGRESO_COMIDA", "SALIDA"]
    resultados = []
    for idx, entry in enumerate(entries_ordenadas):
        secuencia = idx + 1
        hora_real = parsear_hora_utc(entry["time"])
        tipo_marcaje = etiquetas[idx] if idx < len(etiquetas) else f"EXTRA_{secuencia}"
        resultados.append(_base_resultado(
            entry, employee_internal_id, secuencia, hora_real, tipo_marcaje,
            clasificacion="JUSTIFICADO", tipo_incidencia_aplicada=tipo_incidencia,
        ))
    return resultados


def generar_id_sintetico(employee_internal_id: str, fecha: datetime.date, sufijo_tipo: int) -> int:
    """
    Genera un ID único y negativo (para no chocar nunca con IDs reales de
    Humand, que son positivos) para las filas que nosotros sintetizamos —
    no existe un 'entry' real de Humand para ese día.

    sufijo_tipo: dígito 1-9 que distingue el TIPO de registro sintético
    (1=FALTA, 2=JUSTIFICADO, ...) para el mismo empleado/fecha, sin correr
    el número de empleado como pasaba antes al simplemente restar 1.
    """
    try:
        emp_num = int(employee_internal_id)
    except (TypeError, ValueError):
        emp_num = abs(hash(employee_internal_id)) % 100_000
    emp_num = emp_num % 100_000  # 5 dígitos, dejando el último dígito libre para sufijo_tipo
    return -(int(fecha.strftime("%Y%m%d")) * 1_000_000 + emp_num * 10 + sufijo_tipo)


def generar_id_falta_sintetico(employee_internal_id: str, fecha: datetime.date) -> int:
    return generar_id_sintetico(employee_internal_id, fecha, 1)


def crear_registro_falta(employee_internal_id: str, fecha: datetime.date) -> dict:
    hora_placeholder = datetime.datetime.combine(fecha, datetime.time(0, 0), tzinfo=ZONA_HORARIA_LOCAL)
    return {
        "entryIdHumand": generar_id_falta_sintetico(employee_internal_id, fecha),
        "employeeInternalId": employee_internal_id,
        "horaFichaje": hora_placeholder,
        "tipoMarcaje": "FALTA",
        "secuenciaDia": 1,
        "horarioAsignadoIn": None,
        "horarioAsignadoOut": None,
        "minutosDesviacion": None,
        "clasificacion": "FALTA",
        "origenMarcaje": "SISTEMA",
        "pairId": None,
        "tipoIncidenciaAplicada": None,
    }


def crear_registro_justificado_sintetico(employee_internal_id: str, fecha: datetime.date, tipo_incidencia: str) -> dict:
    """
    BUGFIX: un día con incidencia aprobada (incapacidad, permiso, vacaciones)
    normalmente NO tiene checadas -- la persona no fue a trabajar. Antes,
    esos días caían en el 'else: continue' del bucle principal y no se
    insertaba NADA (ni FALTA ni JUSTIFICADO). Este registro sintético
    asegura que el día quede reflejado como JUSTIFICADO aunque no haya
    entries reales de Humand -- mismo patrón que crear_registro_falta, pero
    restando 1 al día del mes en el ID sintético para nunca chocar con el
    ID sintético de FALTA del mismo empleado/fecha.
    """
    hora_placeholder = datetime.datetime.combine(fecha, datetime.time(0, 0), tzinfo=ZONA_HORARIA_LOCAL)
    return {
        "entryIdHumand": generar_id_sintetico(employee_internal_id, fecha, 2),
        "employeeInternalId": employee_internal_id,
        "horaFichaje": hora_placeholder,
        "tipoMarcaje": "JUSTIFICADO",
        "secuenciaDia": 1,
        "horarioAsignadoIn": None,
        "horarioAsignadoOut": None,
        "minutosDesviacion": None,
        "clasificacion": "JUSTIFICADO",
        "origenMarcaje": "SISTEMA",
        "pairId": None,
        "tipoIncidenciaAplicada": tipo_incidencia,
    }


def clasificar_marcajes_del_dia(entries: list, time_slots: list, fecha_referencia: datetime.date,
                                 employee_internal_id: str, es_promotor: bool = False,
                                 tipo_incidencia: str = None, horario_historico: dict = None,
                                 catalogo_turnos: list = None, es_sindicalizado: bool = False,
                                 catalogo_rotativo: dict = None):
    entries_ordenadas = sorted(entries, key=lambda e: e["time"])

    if tipo_incidencia:
        return clasificar_dia_justificado(entries_ordenadas, employee_internal_id, tipo_incidencia)
    if es_promotor:
        return clasificar_visitas_promotor(entries_ordenadas, employee_internal_id)
    return clasificar_oficina(entries_ordenadas, time_slots, fecha_referencia, employee_internal_id,
                               horario_historico, catalogo_turnos, es_sindicalizado, catalogo_rotativo)


# =========================================================
# 5. Escritura en SQL (con deduplicación)
# =========================================================

def eliminar_falta_sintetica_previa(cursor, conn, employee_internal_id: str, fecha: datetime.date):
    """
    BUGFIX: si en una corrida anterior se insertó una FALTA sintética para
    este empleado/día (porque Humand aún no tenía las checadas -- típico
    cuando Hikvision->Humand va con backlog), y AHORA sí llegaron checadas
    reales para ese día, hay que borrar la FALTA vieja antes de insertar los
    marcajes reales. Si no, quedan las dos: la FALTA Y las checadas juntas.
    Se identifica por clasificacion='FALTA' + origenMarcaje='SISTEMA' (nunca
    borra una FALTA real capturada por otro medio).
    """
    cursor.execute(
        """
        DELETE FROM dbo.Humand
        WHERE employeeId = ? AND fecha = ? AND clasificacion = 'FALTA' AND origenMarcaje = 'SISTEMA'
        """,
        employee_internal_id, fecha,
    )
    if cursor.rowcount > 0:
        log.warning(
            f"employeeInternalId={employee_internal_id} fecha={fecha}: se eliminó una FALTA sintética "
            f"previa (ya llegaron checadas reales para este día)."
        )
    conn.commit()


def insertar_marcaje(cursor, conn, fecha: datetime.date, nombre_colaborador: str,
                      tipo_nomina: str, registro: dict):
    try:
        cursor.execute(
            """
            INSERT INTO dbo.Humand (
                employeeId, nombreColaborador, fecha, horaFichaje, tipoMarcaje,
                secuenciaDia, horarioAsignadoIn, horarioAsignadoOut, minutosDesviacion,
                clasificacion, tipoNomina, origenMarcaje, pairId, entryIdHumand,
                tipoIncidenciaAplicada
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            registro["employeeInternalId"],
            nombre_colaborador,
            fecha,
            registro["horaFichaje"].replace(tzinfo=None),
            registro["tipoMarcaje"],
            registro["secuenciaDia"],
            registro["horarioAsignadoIn"],
            registro["horarioAsignadoOut"],
            registro["minutosDesviacion"],
            registro["clasificacion"],
            tipo_nomina,
            registro["origenMarcaje"],
            registro["pairId"],
            registro["entryIdHumand"],
            registro.get("tipoIncidenciaAplicada"),
        )
        conn.commit()
        return True
    except pyodbc.IntegrityError:
        conn.rollback()
        return False
    except pyodbc.Error as e:
        log.error(f"Error al insertar entryIdHumand={registro['entryIdHumand']}: {e}")
        conn.rollback()
        return False


# =========================================================
# Main
# =========================================================

def obtener_periodos_afectados(cursor, fecha_inicio: datetime.date, fecha_fin: datetime.date):
    """
    Detecta qué periodo(s) semanal(es) y quincenal(es) oficiales de Intelisis
    se traslapan con el rango recién sincronizado, usando los calendarios
    nativos (nvk_tb_IncidenciasSemanal / nvk_tb_IncidenciasQuincenal).
    Devuelve una lista de tuplas: (tipo_nomina, periodo_label, fecha_ini, fecha_fin)
    """
    periodos = []

    cursor.execute(
        """
        SELECT Semana, FechaDCorte, FechaACorte
        FROM dbo.nvk_tb_IncidenciasSemanal
        WHERE FechaDCorte <= ? AND FechaACorte >= ?
        """,
        fecha_fin, fecha_inicio,
    )
    for row in cursor.fetchall():
        periodos.append(("SEMANAL", f"S-{row.Semana}", row.FechaDCorte, row.FechaACorte))

    cursor.execute(
        """
        SELECT Quincena, FechaDCorte, FechaACorte
        FROM dbo.nvk_tb_IncidenciasQuincenal
        WHERE FechaDCorte <= ? AND FechaACorte >= ?
        """,
        fecha_fin, fecha_inicio,
    )
    for row in cursor.fetchall():
        periodos.append(("QUINCENAL", row.Quincena, row.FechaDCorte, row.FechaACorte))

    return periodos


def actualizar_reportes_periodo(cursor, conn, fecha_inicio: datetime.date, fecha_fin: datetime.date):
    """Recalcula dbo.IncidenciasPeriodoNomina y dbo.ReporteIncidenciasPeriodo
    para todos los periodos QUE YA TERMINARON dentro del rango recién
    sincronizado. Los periodos en curso o futuros se omiten -- evaluar días
    que todavía no pasan los marcaría a todos como falta."""
    hoy = datetime.datetime.now(ZONA_HORARIA_LOCAL).date()
    periodos = obtener_periodos_afectados(cursor, fecha_inicio, fecha_fin)
    if not periodos:
        log.info("Ningún periodo oficial (semanal/quincenal) coincide con el rango sincronizado.")
        return

    for tipo_nomina, periodo_label, p_fecha_ini, p_fecha_fin in periodos:
        if p_fecha_fin >= hoy:
            log.info(f"Periodo {periodo_label} todavía no termina ({p_fecha_fin} >= hoy {hoy}), se omite por ahora.")
            continue
        try:
            log.info(f"Actualizando reporte para {tipo_nomina} {periodo_label} ({p_fecha_ini} a {p_fecha_fin})...")
            gip.actualizar_solo_sql(tipo_nomina, p_fecha_ini, p_fecha_fin, periodo_label)
            log.info(f"Reporte {periodo_label} actualizado en dbo.ReporteIncidenciasPeriodo.")
        except Exception as e:
            log.error(f"No se pudo actualizar el reporte de {periodo_label}: {e}")


def asegurar_incidencias_completas(cursor, conn, incidencias_por_empleado: dict,
                                    fecha_inicio_dt: datetime.date, fecha_fin_dt: datetime.date,
                                    mapa_empleados: dict, personal_intelisis: dict):
    """
    BUGFIX: a veces Humand simplemente no incluye en su respuesta de
    day-summaries algunos días que están cubiertos por una incidencia recién
    aprobada (parece un delay/comportamiento interno de Humand, no algo que
    controlemos) -- así que esos días nunca llegan ni siquiera a evaluarse
    en el bucle principal. Esta función recorre explícitamente cada día de
    cada incidencia aprobada y garantiza que quede reflejado como
    JUSTIFICADO en dbo.Humand, sin depender de si Humand mandó o no el
    day-summary de ese día en particular.
    """
    total_asegurados = 0
    for employee_internal_id, incidencias in incidencias_por_empleado.items():
        nombre_colaborador = mapa_empleados.get(employee_internal_id, {}).get("nombre", "DESCONOCIDO")
        tipo_nomina = personal_intelisis.get(employee_internal_id, {}).get("periodoTipo")

        for fecha_ini, fecha_fin_incidencia, tipo in incidencias:
            fecha_ini_efectiva = max(fecha_ini, fecha_inicio_dt)
            fecha_fin_efectiva = min(fecha_fin_incidencia, fecha_fin_dt)
            if fecha_ini_efectiva > fecha_fin_efectiva:
                continue

            fecha_actual = fecha_ini_efectiva
            while fecha_actual <= fecha_fin_efectiva:
                cursor.execute(
                    """
                    SELECT COUNT(*) FROM dbo.Humand
                    WHERE employeeId = ? AND fecha = ? AND clasificacion = 'JUSTIFICADO'
                    """,
                    employee_internal_id, fecha_actual,
                )
                ya_existe = cursor.fetchone()[0] > 0

                if not ya_existe:
                    eliminar_falta_sintetica_previa(cursor, conn, employee_internal_id, fecha_actual)
                    registro = crear_registro_justificado_sintetico(employee_internal_id, fecha_actual, tipo)
                    insertar_marcaje(cursor, conn, fecha_actual, nombre_colaborador, tipo_nomina, registro)
                    total_asegurados += 1
                    log.info(
                        f"Día asegurado (no vino en day-summaries de Humand): "
                        f"{employee_internal_id} {fecha_actual} -> JUSTIFICADO ({tipo})"
                    )

                fecha_actual += datetime.timedelta(days=1)

    log.info(f"Total de días asegurados por incidencia (respaldo, no vinieron de Humand): {total_asegurados}")


def main():
    conn = obtener_conexion()
    cursor = conn.cursor()

    try:
        ultima_ejecucion = obtener_ultima_ejecucion(cursor)
        fecha_inicio_dt = ultima_ejecucion.astimezone(ZONA_HORARIA_LOCAL).date()
        fecha_fin_dt = datetime.datetime.now(ZONA_HORARIA_LOCAL).date()
        log.info(f"Sincronizando desde {fecha_inicio_dt} hasta {fecha_fin_dt}...")

        bloques_fecha = dividir_rango_fechas(fecha_inicio_dt, fecha_fin_dt)
        log.info(f"Rango dividido en {len(bloques_fecha)} bloque(s) de máximo {MAX_DIAS_POR_RANGO} días (límite de la API).")

        empleados_humand = obtener_empleados_humand()
        personal_intelisis = obtener_personal_intelisis(cursor)

        sincronizar_incidencias_desde_humand(cursor, conn, fecha_inicio_dt.isoformat(), fecha_fin_dt.isoformat())
        incidencias_por_empleado = obtener_incidencias_aprobadas(
            cursor, fecha_inicio_dt.isoformat(), fecha_fin_dt.isoformat()
        )
        horario_historico = obtener_horario_historico(cursor)
        catalogo_turnos = obtener_catalogo_turnos(cursor)
        catalogo_rotativo = obtener_catalogo_rotativo(cursor)
        dias_especiales = obtener_dias_especiales(cursor, fecha_inicio_dt.isoformat(), fecha_fin_dt.isoformat())

        mapa_empleados = {}
        internal_ids = []
        for u in empleados_humand:
            internal_id = u.get("employeeInternalId")
            if not internal_id:
                continue
            nombre = f"{u.get('firstName', '')} {u.get('lastName', '')}".strip()
            mapa_empleados[internal_id] = {"userId": u["id"], "nombre": nombre}
            internal_ids.append(internal_id)

        total_insertados = 0
        total_omitidos = 0

        for bloque_inicio, bloque_fin in bloques_fecha:
            bloque_inicio_str = bloque_inicio.isoformat()
            bloque_fin_str = bloque_fin.isoformat()
            log.info(f"=== Bloque de fechas: {bloque_inicio_str} a {bloque_fin_str} ===")

            for lote in dividir_en_lotes(internal_ids, TAMANO_LOTE_EMPLEADOS):
                resumenes = obtener_day_summaries(lote, bloque_inicio_str, bloque_fin_str)

                for resumen in resumenes:
                    guardar_raw_day_summary(cursor, conn, resumen)
                    try:
                        entries = resumen.get("entries") or []
                        time_slots = resumen.get("timeSlots") or []
                        internal_id = resumen.get("employeeId")
                        fecha_ref = datetime.date.fromisoformat(resumen["referenceDate"])
                        es_dia_laboral = bool(resumen.get("isWorkday"))
                        if not es_dia_laboral and horario_historico:
                            # Respaldo: Humand no sabe si era día laboral (sin turno asignado
                            # para fechas viejas) -> usamos el horario fijo del Excel histórico.
                            dia_semana = fecha_ref.isoweekday()
                            entrada_hist, salida_hist = horario_historico.get(internal_id, {}).get(dia_semana, (None, None))
                            if entrada_hist and salida_hist:
                                es_dia_laboral = True

                        datos_intelisis = personal_intelisis.get(internal_id, {})
                        es_promotor = datos_intelisis.get("esPromotor", False)
                        es_sindicalizado = datos_intelisis.get("esSindicalizado", False)
                        tipo_incidencia = buscar_incidencia_del_dia(
                            incidencias_por_empleado.get(internal_id), fecha_ref
                        )
                        es_especial = es_dia_especial(dias_especiales, internal_id, fecha_ref)

                        if not entries:
                            if tipo_incidencia:
                                # Día con incidencia aprobada (incapacidad/permiso/vacaciones) y
                                # SIN checadas -- lo normal, la persona no fue a trabajar. Antes
                                # esto se saltaba sin insertar nada (bug); ahora sí se refleja.
                                eliminar_falta_sintetica_previa(cursor, conn, internal_id, fecha_ref)
                                registros_clasificados = [crear_registro_justificado_sintetico(internal_id, fecha_ref, tipo_incidencia)]
                            elif es_dia_laboral and not es_promotor and not es_especial:
                                # Día laboral, sin marcaje, sin incidencia, sin excepción -> FALTA real
                                registros_clasificados = [crear_registro_falta(internal_id, fecha_ref)]
                            else:
                                continue  # descanso, día especial (home office, etc.), o promotor sin visitas: no se inserta nada
                        else:
                            # Llegaron checadas reales -- si en una corrida anterior se había
                            # sintetizado una FALTA para este empleado/día (por backlog de
                            # Hikvision->Humand), hay que borrarla antes de insertar lo real.
                            eliminar_falta_sintetica_previa(cursor, conn, internal_id, fecha_ref)
                            registros_clasificados = clasificar_marcajes_del_dia(
                                entries, time_slots, fecha_ref, internal_id,
                                es_promotor=es_promotor, tipo_incidencia=tipo_incidencia,
                                horario_historico=horario_historico, catalogo_turnos=catalogo_turnos,
                                es_sindicalizado=es_sindicalizado, catalogo_rotativo=catalogo_rotativo,
                            )
                    except Exception as e:
                        log.error(f"Error procesando resumen de {resumen.get('referenceDate')} (employeeId={resumen.get('employeeId')}): {e}")
                        continue

                    for registro in registros_clasificados:
                        internal_id = registro["employeeInternalId"]
                        datos_empleado = mapa_empleados.get(internal_id, {})
                        nombre_colaborador = datos_empleado.get("nombre", "DESCONOCIDO")

                        datos_intelisis = personal_intelisis.get(internal_id, {})
                        tipo_nomina = datos_intelisis.get("periodoTipo")

                        if not datos_intelisis:
                            log.warning(
                                f"employeeInternalId={internal_id} no encontrado en Intelisis.Personal "
                                f"(colaborador: {nombre_colaborador}). Se inserta sin tipoNomina."
                            )

                        insertado = insertar_marcaje(cursor, conn, fecha_ref, nombre_colaborador, tipo_nomina, registro)
                        if insertado:
                            total_insertados += 1
                        else:
                            total_omitidos += 1

        log.info(f"Proceso finalizado: {total_insertados} insertados, {total_omitidos} omitidos (ya existían o error).")
        registrar_ejecucion(cursor, conn, total_insertados)

        # Respaldo: asegura que TODOS los días de cada incidencia aprobada
        # queden reflejados, incluso si Humand no mandó el day-summary de
        # algún día en particular (ver docstring de la función).
        asegurar_incidencias_completas(
            cursor, conn, incidencias_por_empleado, fecha_inicio_dt, fecha_fin_dt,
            mapa_empleados, personal_intelisis,
        )

        actualizar_reportes_periodo(cursor, conn, fecha_inicio_dt, fecha_fin_dt)

    except Exception as e:
        log.exception(f"Error inesperado durante la sincronización: {e}")
    finally:
        cursor.close()
        conn.close()


if __name__ == "__main__":
    main()
