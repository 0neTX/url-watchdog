"""
init_historial.py
=================
Script de inicialización — se ejecuta UNA SOLA VEZ.

Usa Telethon (userbot) para leer TODO el historial de mensajes del grupo
y poblar la base de datos SQLite 'estadisticas_grupo.db' con el conteo
de mensajes y la fecha del último mensaje de cada usuario.

Requisitos:
  - pip install telethon python-dotenv
  - Archivo .env con: API_ID, API_HASH, BOT_TOKEN, GRUPO_ID

Uso:
  python init_historial.py
  (La primera ejecución pedirá tu número de teléfono y el código de Telegram)
"""

import asyncio
import sqlite3
import os
from datetime import datetime

from dotenv import load_dotenv
from telethon import TelegramClient
from telethon.tl.types import User

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

load_dotenv()

API_ID   = int(os.getenv("API_ID"))
API_HASH = os.getenv("API_HASH")
GRUPO_ID = int(os.getenv("GRUPO_ID"))

DB_PATH      = "estadisticas_grupo.db"
SESSION_NAME = "sesion_admin"      # Nombre del archivo de sesión Telethon (.session)


# ---------------------------------------------------------------------------
# Base de datos
# ---------------------------------------------------------------------------

def init_db() -> sqlite3.Connection:
    """Crea (o abre) la BD y garantiza que la tabla 'usuarios' exista."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS usuarios (
            user_id        INTEGER PRIMARY KEY,
            nombre         TEXT    NOT NULL DEFAULT '',
            username       TEXT    DEFAULT NULL,
            total_mensajes INTEGER NOT NULL DEFAULT 0,
            ultimo_mensaje TEXT    DEFAULT NULL
        )
    """)
    conn.commit()
    return conn


def upsert_usuario(conn: sqlite3.Connection,
                   user_id: int,
                   nombre: str,
                   username: str | None,
                   fecha: datetime) -> None:
    """
    Inserta el usuario si no existe o actualiza sus contadores.
    Suma 1 al total de mensajes y actualiza el último mensaje solo si
    la fecha recibida es más reciente que la almacenada.
    """
    fecha_str = fecha.isoformat()
    conn.execute("""
        INSERT INTO usuarios (user_id, nombre, username, total_mensajes, ultimo_mensaje)
        VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(user_id) DO UPDATE SET
            nombre         = excluded.nombre,
            username       = excluded.username,
            total_mensajes = total_mensajes + 1,
            ultimo_mensaje = CASE
                WHEN ultimo_mensaje IS NULL
                     OR excluded.ultimo_mensaje > ultimo_mensaje
                THEN excluded.ultimo_mensaje
                ELSE ultimo_mensaje
            END
    """, (user_id, nombre, username, fecha_str))


# ---------------------------------------------------------------------------
# Lógica principal
# ---------------------------------------------------------------------------

async def leer_historial(client: TelegramClient, conn: sqlite3.Connection) -> None:
    """Itera por todos los mensajes del grupo y actualiza la BD."""

    total_mensajes = 0
    total_usuarios: set[int] = set()

    print(f"[INFO] Leyendo historial del grupo {GRUPO_ID}...")
    print("[INFO] Esto puede tardar varios minutos dependiendo del tamaño del grupo.")

    # iter_messages descarga los mensajes en lotes, respetando los límites de Telegram.
    async for mensaje in client.iter_messages(GRUPO_ID, reverse=True):

        # Ignorar mensajes de sistema (sin remitente humano) y de bots
        if not mensaje.sender or not isinstance(mensaje.sender, User):
            continue
        if mensaje.sender.bot:
            continue
        # Solo contar mensajes de texto (ignorar stickers, fotos sin caption, etc.)
        if mensaje.text is None and mensaje.message is None:
            continue

        remitente: User = mensaje.sender
        user_id  = remitente.id
        nombre   = (
            f"{remitente.first_name or ''} {remitente.last_name or ''}".strip()
            or str(user_id)
        )
        username = remitente.username  # None si no tiene @alias
        fecha    = mensaje.date        # datetime con timezone UTC

        upsert_usuario(conn, user_id, nombre, username, fecha)

        total_mensajes += 1
        total_usuarios.add(user_id)

        # Guardar en BD cada 500 mensajes para no perder progreso
        if total_mensajes % 500 == 0:
            conn.commit()
            print(f"  → {total_mensajes:,} mensajes procesados "
                  f"({len(total_usuarios):,} usuarios únicos)...")

    # Commit final
    conn.commit()
    print(f"\n[OK] Historial completado.")
    print(f"     Mensajes procesados : {total_mensajes:,}")
    print(f"     Usuarios únicos     : {len(total_usuarios):,}")


async def main() -> None:
    conn = init_db()
    print(f"[INFO] Base de datos lista: {DB_PATH}")

    async with TelegramClient(SESSION_NAME, API_ID, API_HASH) as client:
        me = await client.get_me()
        print(f"[INFO] Sesión iniciada como: {me.first_name} (id={me.id})")
        await leer_historial(client, conn)

    conn.close()
    print("[INFO] Conexión a la BD cerrada. ¡Listo para usar bot_estadisticas.py!")


if __name__ == "__main__":
    asyncio.run(main())
