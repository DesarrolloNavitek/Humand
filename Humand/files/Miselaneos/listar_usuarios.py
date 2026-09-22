"""
Lista los usuarios de Humand para obtener un employeeId real y válido,
que puedas usar en las pruebas de sync_humand.py.

Uso:
    python listar_usuarios.py
"""

import os
import time
import requests
from dotenv import load_dotenv

load_dotenv()

HUMAND_API_KEY = os.environ["HUMAND_API_KEY"]

HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "Authorization": f"Basic {HUMAND_API_KEY}",
}

URL = "https://api-prod.humand.co/public/api/v1/users"
PARAMS = {"limit": 50, "offset": 0}

MAX_INTENTOS = 4
TIMEOUT_SEGUNDOS = 30


def solicitar_con_reintentos(metodo, url, **kwargs):
    """
    Hace la petición con reintentos y backoff exponencial.
    Ayuda a mitigar el timeout intermitente causado por renegociación TLS
    en redes con inspección SSL (firewall/antivirus corporativo).
    """
    ultimo_error = None
    for intento in range(1, MAX_INTENTOS + 1):
        try:
            print(f"Intento {intento}/{MAX_INTENTOS}...")
            return requests.request(metodo, url, timeout=TIMEOUT_SEGUNDOS, **kwargs)
        except requests.exceptions.RequestException as e:
            ultimo_error = e
            espera = 2 ** intento  # 2, 4, 8, 16 segundos
            print(f"  Falló ({e}). Reintentando en {espera}s...")
            time.sleep(espera)
    raise ultimo_error


def listar_usuarios():
    try:
        respuesta = solicitar_con_reintentos("GET", URL, headers=HEADERS, params=PARAMS)

        if respuesta.status_code != 200:
            print(f"Error {respuesta.status_code}: {respuesta.text}")
            return

        data = respuesta.json()

        # La API de Humand devuelve: {"count": N, "users": [...]}
        usuarios = data.get("users") or data.get("data") or data.get("items") or data

        if not isinstance(usuarios, list):
            print("Respuesta inesperada, aquí está el JSON crudo para revisar:")
            print(data)
            return

        print(f"Se encontraron {len(usuarios)} usuarios:\n")
        for u in usuarios:
            uid = u.get("id")
            nombre = (u.get("firstName", "") + " " + u.get("lastName", "")).strip()
            internal_id = u.get("employeeInternalId")
            status = u.get("status")
            print(f"id={uid}  |  status={status}  |  employeeInternalId={internal_id}  |  nombre={nombre}")

    except requests.exceptions.RequestException as e:
        print(f"Error de red: {e}")


if __name__ == "__main__":
    listar_usuarios()
