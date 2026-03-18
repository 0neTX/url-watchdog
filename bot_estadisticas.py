"""
bot_estadisticas.py
===================
Bot principal de estadísticas de grupo para Telegram.

Funcionalidades:
  1. Escucha todos los mensajes nuevos en el grupo y actualiza la BD SQLite.
  2. Tarea programada diaria (10:00 AM UTC) que envía al grupo el Top 5
     de usuarios con más mensajes, formateado en Markdown.

Requisitos:
  - pip install "python-telegram-bot[job-queue]" python-dotenv
  - Base de datos inicializada con init_historial.py (o vacía: se crea sola)
  - Archivo .env con: BOT_TOKEN, GRUPO_ID

Uso:
  python bot_estadisticas.py
"""

import logging
import sqlite3
import os
from datetime import datetime, time, timezone

from dotenv import load_dotenv
from telegram import Update
from telegram.ext import (
    Application,
    ContextTypes,
    MessageHandler,
    filters,
)

# ---------------------------------------------------------------------------
# Configuración de logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Variables de entorno
# ---------------------------------------------------------------------------

load_dotenv()

BOT_TOKEN = os.getenv("BOT_TOKEN")
GRUPO_ID  = int(os.getenv("GRUPO_ID"))
DB_PATH   = "estadisticas_grupo.db"

# Hora UTC a la que se enviará el resumen diario (10:00 AM UTC)
HORA_REPORTE = time(hour=10, minute=0, second=0, tzinfo=timezone.utc)


# ---------------------------------------------------------------------------
# Base de datos
# ---------------------------------------------------------------------------

def get_conn() -> sqlite3.Connection:
    """Abre la conexión a la BD y habilita el modo WAL para concurrencia."""
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
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


# Conexión global reutilizable durante toda la vida del bot
_conn: sqlite3.Connection = get_conn()


def registrar_mensaje(user_id: int,
                      nombre: str,
                      username: str | None,
                      fecha: datetime) -> None:
    """
    Inserta al usuario si no existe; si existe suma 1 a total_mensajes
    y actualiza nombre, username y la fecha del último mensaje.
    """
    fecha_str = fecha.isoformat()
    _conn.execute("""
        INSERT INTO usuarios (user_id, nombre, username, total_mensajes, ultimo_mensaje)
        VALUES (?, ?, ?, 1, ?)
        ON CONFLICT(user_id) DO UPDATE SET
            nombre         = excluded.nombre,
            username       = excluded.username,
            total_mensajes = total_mensajes + 1,
            ultimo_mensaje = excluded.ultimo_mensaje
    """, (user_id, nombre, username, fecha_str))
    _conn.commit()


def obtener_top5() -> list[tuple[int, str, str | None, int, str | None]]:
    """Devuelve los 5 usuarios con más mensajes ordenados de mayor a menor."""
    cur = _conn.execute("""
        SELECT user_id, nombre, username, total_mensajes, ultimo_mensaje
        FROM   usuarios
        ORDER  BY total_mensajes DESC
        LIMIT  5
    """)
    return cur.fetchall()


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

async def handler_mensaje(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """
    Se dispara con cada mensaje de texto en el grupo.
    Actualiza la BD con los datos del remitente.
    """
    msg = update.effective_message
    user = update.effective_user

    # Ignorar mensajes reenviados de canales (sender es None) o bots
    if user is None or user.is_bot:
        return

    nombre = (
        f"{user.first_name or ''} {user.last_name or ''}".strip()
        or str(user.id)
    )
    username = user.username  # None si el usuario no tiene @alias
    fecha    = msg.date        # datetime UTC provisto por Telegram

    registrar_mensaje(user.id, nombre, username, fecha)
    logger.debug(f"Mensaje registrado: {nombre} (id={user.id})")


# ---------------------------------------------------------------------------
# Tarea programada: resumen diario
# ---------------------------------------------------------------------------

async def enviar_resumen_diario(context: ContextTypes.DEFAULT_TYPE) -> None:
    """
    Job que se ejecuta una vez al día.
    Lee el Top 5 de la BD y envía un mensaje formateado al grupo.
    """
    top5 = obtener_top5()

    if not top5:
        logger.info("Sin datos para el resumen diario.")
        return

    ahora = datetime.now(tz=timezone.utc).strftime("%d/%m/%Y")
    lineas = [f"📊 *Estadísticas del grupo* — {ahora}\n"]

    medallas = ["🥇", "🥈", "🥉", "4️⃣", "5️⃣"]

    for posicion, (user_id, nombre, username, total, ultimo) in enumerate(top5):
        # Escapar caracteres especiales de MarkdownV2 en el nombre
        nombre_safe = (
            nombre
            .replace("_", "\\_")
            .replace("*", "\\*")
            .replace("[", "\\[")
            .replace("`", "\\`")
        )
        alias = f"@{username}" if username else f"id:{user_id}"
        lineas.append(
            f"{medallas[posicion]} *{nombre_safe}* ({alias})\n"
            f"   └ {total:,} mensajes"
        )

    lineas.append(f"\n_Actualizado cada día a las 10:00 UTC_")
    texto = "\n".join(lineas)

    await context.bot.send_message(
        chat_id=GRUPO_ID,
        text=texto,
        parse_mode="Markdown",
    )
    logger.info("Resumen diario enviado al grupo.")


# ---------------------------------------------------------------------------
# Punto de entrada
# ---------------------------------------------------------------------------

def main() -> None:
    if not BOT_TOKEN:
        raise ValueError("BOT_TOKEN no encontrado en el archivo .env")

    # Construir la Application (incluye JobQueue gracias al extra [job-queue])
    app = Application.builder().token(BOT_TOKEN).build()

    # Registrar handler: escucha TODOS los mensajes de texto en grupos
    app.add_handler(
        MessageHandler(
            filters.TEXT & filters.ChatType.GROUPS,
            handler_mensaje,
        )
    )

    # Programar tarea diaria a las HORA_REPORTE UTC
    job_queue = app.job_queue
    job_queue.run_daily(
        callback=enviar_resumen_diario,
        time=HORA_REPORTE,
        name="resumen_diario",
    )
    logger.info(f"Tarea diaria programada para las {HORA_REPORTE} UTC")

    logger.info("Bot iniciado. Esperando mensajes...")
    # run_polling arranca el event loop y bloquea hasta Ctrl+C
    app.run_polling(allowed_updates=Update.ALL_TYPES)

    # Cerrar la BD al detener el bot
    _conn.close()
    logger.info("BD cerrada. Bot detenido.")


if __name__ == "__main__":
    main()
