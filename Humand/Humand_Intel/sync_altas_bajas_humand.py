"""
Sincroniza altas y bajas de NAVILUX y BURBUTEK (Intelisis) hacia Humand:

  1. ALTAS: empleados activos que no tienen cuenta en Humand -> se crean;
     cuentas INACTIVE se reactivan.
  2. BAJAS (deshabilitar): empleados con Estatus='BAJA' en NAVILUX/BURBUTEK que
     siguen ACTIVOS en Humand -> se deshabilitan, y se registra la fecha.
  3. BAJAS (eliminar): empleados deshabilitados hace 30+ días -> se
     eliminan de Humand definitivamente.

Por seguridad, todo corre en modo SOLO LECTURA (--dry-run, que es el
default) a menos que se pase --confirmar explícitamente. La eliminación
(paso 3) es irreversible.

Uso:
    python sync_altas_bajas_humand.py                  (dry-run, no cambia nada)
    python sync_altas_bajas_humand.py --confirmar       (ejecuta de verdad)
    python sync_altas_bajas_humand.py --solo-altas --confirmar
    python sync_altas_bajas_humand.py --solo-bajas --confirmar
    python sync_altas_bajas_humand.py --solo-eliminar --confirmar
"""

import os
import argparse
import datetime
import time
import requests
import pyodbc
from dotenv import load_dotenv

load_dotenv()

DB_SERVER = os.environ["DB_SERVER"]
DB_PORT = os.environ.get("DB_PORT", "1433")
DB_NAME = os.environ["DB_NAME"]  # Base de conexión; NAVILUX y BURBUTEK son bases consultadas.
DB_USER = os.environ["DB_USER"]
DB_PASS = os.environ["DB_PASS"]

HUMAND_API_KEY = os.environ["HUMAND_API_KEY"]
HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "Authorization": f"Basic {HUMAND_API_KEY}",
}
BASE_URL = "https://api-prod.humand.co/public/api/v1"

EMPRESAS = {"NAVILUX": "Navitek", "BURBUTEK": "Burbutek"}
DIAS_ANTES_DE_ELIMINAR = 30


def obtener_conexion():
    conn_str = (
        f"DRIVER={{ODBC Driver 17 for SQL Server}};"
        f"SERVER={DB_SERVER},{DB_PORT};DATABASE={DB_NAME};"
        f"UID={DB_USER};PWD={DB_PASS}"
    )
    return pyodbc.connect(conn_str)


# =========================================================
# Catálogos
# =========================================================

def obtener_activos_empresa(cursor, empresa):
    if empresa not in EMPRESAS:
        raise ValueError(f"Empresa no configurada: {empresa}")
    cursor.execute(
        f"""
        SELECT Personal, Nombre, ApellidoPaterno, ApellidoMaterno, FechaAlta, FechaNacimiento,
               eMail, Departamento, ReportaA, Puesto
        FROM [{empresa}].dbo.Personal
        WHERE Estatus IS NULL OR Estatus <> 'BAJA'
        """
    )
    empleados = {}
    for row in cursor.fetchall():
        clave = str(row.Personal).strip().zfill(6)
        empleados[clave] = {
            "nombre": row.Nombre,
            "apellidoPaterno": row.ApellidoPaterno,
            "apellidoMaterno": row.ApellidoMaterno,
            "fechaAlta": row.FechaAlta,
            "fechaNacimiento": row.FechaNacimiento,
            "email": row.eMail,
            "departamento": row.Departamento,
            "reportaA": str(row.ReportaA).strip().zfill(6) if row.ReportaA else None,
            "puesto": row.Puesto,
            "empresa": empresa,
        }
    return empleados


def obtener_activos_todas_empresas(cursor):
    empleados = {}
    for empresa in EMPRESAS:
        for clave, datos in obtener_activos_empresa(cursor, empresa).items():
            if clave in empleados:
                raise RuntimeError(f"employeeInternalId duplicado {clave} en {empleados[clave]['empresa']} y {empresa}.")
            empleados[clave] = datos
    return empleados


def obtener_bajas_empresa(cursor, empresa):
    if empresa not in EMPRESAS:
        raise ValueError(f"Empresa no configurada: {empresa}")
    cursor.execute(
        f"""
        SELECT Personal, Nombre, ApellidoPaterno, ApellidoMaterno
        FROM [{empresa}].dbo.Personal
        WHERE Estatus = 'BAJA'
        """
    )
    empleados = {}
    for row in cursor.fetchall():
        clave = str(row.Personal).strip().zfill(6)
        empleados[clave] = {"nombre": f"{row.Nombre} {row.ApellidoPaterno} {row.ApellidoMaterno or ''}".strip(), "empresa": empresa}
    return empleados


def obtener_bajas_todas_empresas(cursor):
    empleados = {}
    for empresa in EMPRESAS:
        for clave, datos in obtener_bajas_empresa(cursor, empresa).items():
            if clave in empleados:
                raise RuntimeError(f"employeeInternalId duplicado {clave} en {empleados[clave]['empresa']} y {empresa}.")
            empleados[clave] = datos
    return empleados


def obtener_usuarios_humand():
    """Devuelve dict: employeeInternalId -> {'status', 'id', 'departamento', 'puesto'}
    Se incluyen TODOS los usuarios, sin filtrar por segmentación -- una
    cuenta que ya existe pero sin la etiqueta 'Razón Social' correcta
    igual debe contar como 'ya existe', para no intentar crearla de nuevo.

    BUGFIX: 'count' en la respuesta de Humand NO es el total de usuarios de
    la comunidad -- es solo cuántos vienen en ESA página. El endpoint no
    trae ningún campo de total (ni 'totalPages' ni 'total'), así que la
    única forma correcta de saber cuándo parar es seguir pidiendo páginas
    hasta que venga una con MENOS elementos que el límite pedido (o vacía).
    Antes esto cortaba después de la primera página de 50 casi siempre,
    dejando fuera a cualquier empleado que no estuviera en esos primeros 50.
    """
    usuarios = {}
    page = 1
    limite = 50
    while True:
        resp = requests.get(f"{BASE_URL}/users", headers=HEADERS, params={"page": page, "limit": limite}, timeout=30)
        if resp.status_code != 200:
            raise RuntimeError(f"Error al listar usuarios: {resp.status_code} - {resp.text}")
        data = resp.json()
        pagina_usuarios = data.get("users", [])
        for u in pagina_usuarios:
            if u.get("employeeInternalId"):
                clave = str(u["employeeInternalId"]).strip().zfill(6)
                segmentaciones = u.get("segmentations", u.get("segmentation", []))
                departamento_actual = next((s.get("item") for s in segmentaciones if s.get("group") == "Departamento"), None)
                puesto_actual = next((s.get("item") for s in segmentaciones if s.get("group") == "Puesto"), None)
                usuarios[clave] = {
                    "status": u.get("status", "ACTIVE"),
                    "id": u.get("id"),
                    "departamento": departamento_actual,
                    "puesto": puesto_actual,
                }
        if len(pagina_usuarios) < limite:
            break
        page += 1
    return usuarios


# =========================================================
# 1. ALTAS
# =========================================================

def procesar_altas(cursor, conn, activos_navilux, usuarios_humand, confirmar):
    faltantes = sorted(set(activos_navilux) - set(usuarios_humand))
    inactivos = sorted(
        clave for clave in (set(activos_navilux) & set(usuarios_humand))
        if usuarios_humand[clave]["status"] == "INACTIVE"
    )
    print(f"\n=== ALTAS: {len(faltantes)} sin cuenta; {len(inactivos)} cuentas INACTIVE para reingreso ===")

    for clave in inactivos:
        d = activos_navilux[clave]
        nombre = d["nombre"] or clave
        if not confirmar:
            print(f"  [DRY-RUN] Reactivaría {clave} - {nombre} ({EMPRESAS[d['empresa']]}) y actualizaría sus segmentaciones.")
            continue
        try:
            resp = requests.post(f"{BASE_URL}/users/{clave}/reactivate", headers=HEADERS, json={}, timeout=30)
            print(f"  {clave} - reactivar -> {resp.status_code} {resp.text}")
            if resp.status_code not in (200, 204):
                continue
            # Cancela la eliminación pendiente asociada a una baja anterior.
            cursor.execute("DELETE FROM Humand.dbo.HumandBajasPendientes WHERE employeeInternalId = ?", clave)
            conn.commit()
            segmentaciones = [{"group": "Razón Social", "item": EMPRESAS[d["empresa"]]}]
            for grupo, valor in (("Departamento", d["departamento"]), ("Puesto", d["puesto"])):
                if valor:
                    segmentaciones.append({"group": grupo, "item": valor})
            seg_resp = requests.patch(
                f"{BASE_URL}/users/{clave}/segmentations", headers=HEADERS,
                json={"segmentation": segmentaciones}, timeout=30,
            )
            print(f"  {clave} - segmentaciones de reingreso -> {seg_resp.status_code} {seg_resp.text}")
        except requests.exceptions.RequestException as req_error:
            print(f"  {clave} -> [ERROR DE RED] {req_error}")

    for clave in faltantes:
        d = activos_navilux[clave]

        faltantes_requeridos = []
        if not d["email"]:
            faltantes_requeridos.append("email")
        if not d["fechaNacimiento"]:
            faltantes_requeridos.append("fecha de nacimiento")
        if not d["fechaAlta"]:
            faltantes_requeridos.append("fecha de ingreso")

        if faltantes_requeridos:
            print(f"  [OMITIDO] {clave} {d['nombre']} -- falta: {', '.join(faltantes_requeridos)}.")
            continue

        payload = {
            "employeeInternalId": clave,
            "email": d["email"],
            # Contraseña fija para todas las altas nuevas (decisión de negocio) --
            # se comunica directo a la persona, ella la cambia cuando quiera.
            "password": "Navitek2026*",
            "firstName": d["nombre"] or "",
            "lastName": f"{d['apellidoPaterno'] or ''} {d['apellidoMaterno'] or ''}".strip(),
            "segmentation": [{"group": "Razón Social", "item": EMPRESAS[d["empresa"]]}],
            "hiringDate": d["fechaAlta"].strftime("%Y-%m-%d"),
            "birthdate": d["fechaNacimiento"].strftime("%Y-%m-%d"),
        }

        if d["departamento"]:
            payload["segmentation"].append({"group": "Departamento", "item": d["departamento"]})
        else:
            print(f"  [AVISO] {clave} {d['nombre']} -- sin Departamento en {d['empresa']}, se crea sin esa segmentación.")

        if d["reportaA"]:
            payload["relationships"] = [{"name": "BOSS", "employeeInternalId": d["reportaA"]}]
        else:
            print(f"  [AVISO] {clave} {d['nombre']} -- sin ReportaA en {d['empresa']}, se crea sin jefe asignado.")

        if not confirmar:
            print(f"  [DRY-RUN] Crearía a {clave} - {payload['firstName']} {payload['lastName']} ({d['email']}) "
                  f"| Depto: {d['departamento'] or '-'} | Jefe: {d['reportaA'] or '-'}")
            continue

        try:
            resp = requests.post(f"{BASE_URL}/users", headers=HEADERS, json=payload, timeout=30)

            if resp.status_code == 404 and "SEGMENTATION_ITEM_NOT_FOUND" in resp.text and "Departamento" in resp.text:
                print(f"  {clave} -> {resp.status_code} {resp.text}")
                print(f"    -> El departamento '{d['departamento']}' no existe como segmentación en Humand todavía "
                      f"(hay que crearlo ahí manualmente). Reintentando SIN esa etiqueta para no perder el alta...")
                payload["segmentation"] = [s for s in payload["segmentation"] if s["group"] != "Departamento"]
                resp = requests.post(f"{BASE_URL}/users", headers=HEADERS, json=payload, timeout=30)

            print(f"  {clave} -> {resp.status_code} {resp.text}")

        except requests.exceptions.RequestException as req_error:
            print(f"  {clave} -> [ERROR DE RED] {req_error} -- se omite esta corrida, vuelve a correr el script "
                  f"para reintentar (si ya se creó del lado de Humand pese al timeout, la próxima corrida lo "
                  f"detectará como 'ya existe' y no lo va a duplicar).")


# =========================================================
# 2. BAJAS -- deshabilitar
# =========================================================

def procesar_bajas_deshabilitar(cursor, conn, bajas_navilux, usuarios_humand, confirmar):
    # BUGFIX: antes solo se buscaba status == "ACTIVE", dejando fuera cuentas
    # en otros estados que también deberían deshabilitarse -- como
    # "UNCLAIMED" (cuenta creada pero la persona nunca la activó/inició
    # sesión). Se invierte la condición: cualquier estado que NO sea ya
    # "INACTIVE" necesita pasar por deshabilitar.
    a_deshabilitar = [
        clave for clave in bajas_navilux
        if clave in usuarios_humand and usuarios_humand[clave]["status"] != "INACTIVE"
    ]
    print(f"\n=== BAJAS A DESHABILITAR: {len(a_deshabilitar)} empleado(s) ===")

    hoy = datetime.date.today()
    for clave in a_deshabilitar:
        datos_baja = bajas_navilux[clave]
        nombre = datos_baja["nombre"]
        if not confirmar:
            print(f"  [DRY-RUN] Deshabilitaría a {clave} - {nombre}")
            continue

        resp = requests.post(
            f"{BASE_URL}/users/{clave}/deactivate",
            headers=HEADERS,
            json={"deactivationReason": "RESIGNATION"},
            timeout=30,
        )
        print(f"  {clave} - {nombre} -> {resp.status_code}")

        if resp.status_code == 204:
            fecha_programada = hoy + datetime.timedelta(days=DIAS_ANTES_DE_ELIMINAR)
            cursor.execute(
                """
                MERGE Humand.dbo.HumandBajasPendientes AS destino
                USING (SELECT ? AS employeeInternalId) AS origen
                ON destino.employeeInternalId = origen.employeeInternalId
                WHEN MATCHED THEN UPDATE SET fechaDeshabilitado = ?, fechaEliminacionProgramada = ?, nombreColaborador = ?
                WHEN NOT MATCHED THEN INSERT (employeeInternalId, nombreColaborador, fechaDeshabilitado, fechaEliminacionProgramada)
                    VALUES (?, ?, ?, ?);
                """,
                clave,
                hoy, fecha_programada, nombre,
                clave, nombre, hoy, fecha_programada,
            )
            conn.commit()


# =========================================================
# 3. BAJAS -- eliminar tras 30 días
# =========================================================

def procesar_eliminaciones(cursor, conn, confirmar):
    cursor.execute(
        """
        SELECT employeeInternalId, nombreColaborador, fechaDeshabilitado, fechaEliminacionProgramada
        FROM Humand.dbo.HumandBajasPendientes
        WHERE eliminado = 0 AND fechaEliminacionProgramada <= CAST(GETDATE() AS DATE)
        """
    )
    pendientes = cursor.fetchall()
    print(f"\n=== ELIMINACIONES (30+ días deshabilitado): {len(pendientes)} empleado(s) ===")

    for row in pendientes:
        clave = row.employeeInternalId
        if not confirmar:
            print(f"  [DRY-RUN] Eliminaría a {clave} - {row.nombreColaborador} "
                  f"(deshabilitado desde {row.fechaDeshabilitado})")
            continue

        resp = requests.delete(f"{BASE_URL}/users/{clave}", headers=HEADERS, timeout=30)
        print(f"  {clave} - {row.nombreColaborador} -> {resp.status_code}")

        if resp.status_code == 204:
            cursor.execute(
                "UPDATE Humand.dbo.HumandBajasPendientes SET eliminado = 1, fechaEliminado = GETDATE() WHERE employeeInternalId = ?",
                clave,
            )
            conn.commit()


# =========================================================
# Main
# =========================================================

# =========================================================
# 4. BARRIDO -- actualizar Departamento/Puesto de quienes YA existen
# =========================================================

def procesar_barrido_segmentaciones(activos_navilux, usuarios_humand, confirmar):
    """Para cada empleado que YA tiene cuenta en Humand, compara su
    Departamento/Puesto actual en NAVILUX/BURBUTEK contra lo que Humand tiene
    guardado -- si cambió (o nunca se puso), lo actualiza vía PATCH
    /users/{id}/segmentations. No toca Razón Social ni nada más."""
    a_actualizar = []
    for clave, d in activos_navilux.items():
        if clave not in usuarios_humand:
            continue  # no tiene cuenta todavía -- eso lo resuelve el alta, no el barrido
        actual = usuarios_humand[clave]
        cambios = {}
        if d["departamento"] and d["departamento"] != actual.get("departamento"):
            cambios["Departamento"] = d["departamento"]
        if d["puesto"] and d["puesto"] != actual.get("puesto"):
            cambios["Puesto"] = d["puesto"]
        if cambios:
            a_actualizar.append((clave, d["nombre"], cambios))

    print(f"\n=== BARRIDO DE SEGMENTACIONES: {len(a_actualizar)} empleado(s) con Departamento/Puesto desactualizado ===")

    for clave, nombre, cambios in a_actualizar:
        descripcion_cambios = ", ".join(f"{grupo}='{valor}'" for grupo, valor in cambios.items())

        if not confirmar:
            print(f"  [DRY-RUN] Actualizaría a {clave} - {nombre}: {descripcion_cambios}")
            continue

        payload = {"segmentation": [{"group": grupo, "item": valor} for grupo, valor in cambios.items()]}
        try:
            resp = requests.patch(f"{BASE_URL}/users/{clave}/segmentations", headers=HEADERS, json=payload, timeout=30)

            if resp.status_code == 429:
                espera = int(resp.headers.get("Retry-After", 10))
                print(f"    [AVISO] Límite de tasa alcanzado, esperando {espera}s...")
                time.sleep(espera)
                resp = requests.patch(f"{BASE_URL}/users/{clave}/segmentations", headers=HEADERS, json=payload, timeout=30)

            print(f"  {clave} - {nombre}: {descripcion_cambios} -> {resp.status_code}")
            if resp.status_code == 404 and "SEGMENTATION_ITEM_NOT_FOUND" in resp.text:
                print(f"    -> [AVISO] Alguno de estos valores no existe como segmentación en Humand todavía: {resp.text}")
        except requests.exceptions.RequestException as req_error:
            print(f"  {clave} - {nombre} -> [ERROR DE RED] {req_error} -- se omite esta corrida.")


def main(confirmar, solo_altas, solo_bajas, solo_eliminar, solo_barrido):
    conn = obtener_conexion()
    cursor = conn.cursor()

    if not confirmar:
        print("*** MODO DRY-RUN: no se va a modificar nada en Humand. Usa --confirmar para ejecutar de verdad. ***")

    correr_todo = not (solo_altas or solo_bajas or solo_eliminar or solo_barrido)

    if solo_altas or correr_todo:
        activos_navilux = obtener_activos_todas_empresas(cursor)
        usuarios_humand = obtener_usuarios_humand()
        procesar_altas(cursor, conn, activos_navilux, usuarios_humand, confirmar)

    if solo_bajas or correr_todo:
        bajas_navilux = obtener_bajas_todas_empresas(cursor)
        usuarios_humand = obtener_usuarios_humand()
        procesar_bajas_deshabilitar(cursor, conn, bajas_navilux, usuarios_humand, confirmar)

    if solo_eliminar or correr_todo:
        procesar_eliminaciones(cursor, conn, confirmar)

    if solo_barrido or correr_todo:
        activos_navilux = obtener_activos_todas_empresas(cursor)
        usuarios_humand = obtener_usuarios_humand()
        procesar_barrido_segmentaciones(activos_navilux, usuarios_humand, confirmar)

    cursor.close()
    conn.close()s


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--confirmar", action="store_true", help="Ejecuta de verdad (default: dry-run)")
    parser.add_argument("--solo-altas", action="store_true")
    parser.add_argument("--solo-bajas", action="store_true")
    parser.add_argument("--solo-eliminar", action="store_true")
    parser.add_argument("--solo-barrido", action="store_true", help="Solo actualiza Departamento/Puesto de quienes ya existen")
    args = parser.parse_args()
    main(args.confirmar, args.solo_altas, args.solo_bajas, args.solo_eliminar, args.solo_barrido)
