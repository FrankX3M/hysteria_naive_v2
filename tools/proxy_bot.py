#!/usr/bin/env python3
"""proxy-bot — Telegram-обвязка над `proxy-admin`.

Бот НЕ содержит бизнес-логики: каждая команда — вызов proxy-admin (список аргументов,
без shell=True), результат — JSON. Работает от пользователя proxyadmin; операции, требующие
root (изменение пользователей, рестарты, бэкап, статус docker), идут через
`sudo -n /usr/local/bin/proxy-admin ...` — единственная строка в /etc/sudoers.d/proxyadmin.

Доступ: TG_ADMIN_IDS (список user id) — кто может управлять; TG_CHAT_ID — куда шлются
уведомления watchdog/backup. Это разные вещи (п.26): бот работает и в группе.
Неавторизованные обращения логируются — это единственный сигнал, что токен утёк.
"""
from __future__ import annotations

import html
import json
import logging
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ParseMode
from telegram.ext import Application, CallbackQueryHandler, CommandHandler, ContextTypes

sys.path.insert(0, str(Path(__file__).resolve().parent))
from proxy_admin import NAME_RE, Config, Paths  # noqa: E402

logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("proxy-bot")

ADMIN_BIN = os.environ.get("PROXY_ADMIN_BIN", "/usr/local/bin/proxy-admin")
ROOT_COMMANDS = {"add", "del", "enable", "disable", "rotate", "restart", "status", "backup", "apply", "watchdog"}

PATHS = Paths()
CFG = Config(PATHS)
ADMIN_IDS = set(CFG.tg_admin_ids)

HELP = (
    "🤖 <b>Proxy Manager</b>\n\n"
    "/status — состояние сервера\n"
    "/users — список пользователей\n"
    "/adduser &lt;имя&gt; [заметка] — добавить\n"
    "/deluser &lt;имя&gt; — удалить\n"
    "/enable &lt;имя&gt; / /disable &lt;имя&gt; — вкл/выкл (мгновенно, без обрыва других)\n"
    "/links &lt;имя&gt; — ссылки и client.yaml\n"
    "/qr &lt;имя&gt; — QR-коды\n"
    "/rotate &lt;имя&gt; | all — ротация паролей\n"
    "/backup — зашифрованный бэкап в чат\n"
    "/restart — перезапустить сервисы (рвёт сессии!)\n"
    "/whoami — ваш user id\n"
)


def is_admin(update: Update) -> bool:
    uid = update.effective_user.id if update.effective_user else None
    if uid in ADMIN_IDS:
        return True
    chat = update.effective_chat.id if update.effective_chat else None
    text = (update.effective_message.text if update.effective_message else None) or (
        update.callback_query.data if update.callback_query else "")
    log.warning("UNAUTHORIZED user=%s chat=%s text=%r", uid, chat, text)
    return False


def admin_cmd(*argv: str) -> dict:
    """Запуск proxy-admin; root-команды — через sudo -n. Возвращает JSON или {'error': ...}."""
    cmd = [ADMIN_BIN, "--json", *argv]
    if argv and argv[0] in ROOT_COMMANDS:
        cmd = ["sudo", "-n", *cmd]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return {"error": "таймаут выполнения"}
    if r.returncode != 0:
        return {"error": (r.stderr or r.stdout).strip()[-1500:] or f"код {r.returncode}"}
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": "некорректный ответ proxy-admin: " + r.stdout[-500:]}


def esc(s: str) -> str:
    return html.escape(str(s), quote=False)


def name_arg(ctx: ContextTypes.DEFAULT_TYPE) -> str | None:
    if not ctx.args:
        return None
    n = ctx.args[0].lower()
    return n if NAME_RE.fullmatch(n) else None


async def reply(update: Update, text: str, **kw) -> None:
    msg = update.effective_message
    for i in range(0, len(text), 4000):
        await msg.reply_text(text[i:i + 4000], parse_mode=ParseMode.HTML, **({} if i else kw))


def links_text(l: dict) -> str:
    import yaml
    y = yaml.safe_dump(l["hysteria2_client_yaml"], sort_keys=False).rstrip()
    return (
        f"👤 <b>{esc(l['name'])}</b> ({'активен' if l['enabled'] else 'отключён'})\n\n"
        f"🔵 <b>Hysteria2</b> (port hopping через mport):\n<code>{esc(l['hysteria2'])}</code>\n\n"
        f"🔵 <b>Hysteria2 client.yaml</b>:\n<pre>{esc(y)}</pre>\n\n"
        f"🟠 <b>NaiveProxy</b>:\n<code>{esc(l['naiveproxy'])}</code>\n\n"
        f"ℹ️ {esc(l['notes'])}"
    )


# ── Команды ───────────────────────────────────────────────────────────
async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return
    await reply(update, HELP)


async def cmd_whoami(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    u = update.effective_user
    await reply(update, f"user id: <code>{u.id}</code>, chat id: <code>{update.effective_chat.id}</code>"
                        f"{' — администратор' if u.id in ADMIN_IDS else ''}")


def status_markup() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([[InlineKeyboardButton("🔄 Обновить", callback_data="status"),
                                  InlineKeyboardButton("🔁 Рестарт", callback_data="restart_ask")]])


async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return
    from proxy_admin import format_status
    s = admin_cmd("status")
    if "error" in s:
        await reply(update, f"⚠️ {esc(s['error'])}"); return
    await reply(update, format_status(s), reply_markup=status_markup())


async def cmd_users(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return
    r = admin_cmd("list")
    if "error" in r:
        await reply(update, f"⚠️ {esc(r['error'])}"); return
    lines = [f"{'🟢' if u['enabled'] else '🔴'} <code>{esc(n)}</code>" + (f" — {esc(u['note'])}" if u.get("note") else "")
             for n, u in r["users"].items()]
    await reply(update, "👥 <b>Пользователи</b> (Hysteria2 + NaiveProxy)\n\n" + ("\n".join(lines) or "пусто"))


async def cmd_adduser(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return
    name = name_arg(ctx)
    if not name:
        await reply(update, "Использование: /adduser &lt;имя&gt; [заметка]  (имя: a-z 0-9 _ -, до 32 символов)"); return
    note = " ".join(ctx.args[1:])[:100]
    r = admin_cmd("add", name, "--note", note)
    if "error" in r:
        await reply(update, f"⚠️ {esc(r['error'])}"); return
    await reply(update, f"✅ Пользователь <code>{esc(name)}</code> добавлен\n\n" + links_text(r["links"]))


async def simple_user_cmd(update: Update, ctx: ContextTypes.DEFAULT_TYPE, cmd: str, ok_text: str) -> None:
    if not is_admin(update):
        return
    name = name_arg(ctx)
    if not name:
        await reply(update, f"Использование: /{ {'del': 'deluser'}.get(cmd, cmd)} &lt;имя&gt;"); return
    r = admin_cmd(cmd, name)
    await reply(update, f"⚠️ {esc(r['error'])}" if "error" in r else ok_text.format(name=esc(name)))


async def cmd_deluser(u, c): await simple_user_cmd(u, c, "del", "🗑 Пользователь <code>{name}</code> удалён")
async def cmd_enable(u, c):  await simple_user_cmd(u, c, "enable", "🟢 Пользователь <code>{name}</code> включён")
async def cmd_disable(u, c): await simple_user_cmd(u, c, "disable", "🔴 Пользователь <code>{name}</code> отключён (Hysteria2 — мгновенно)")


async def cmd_links(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return
    name = name_arg(ctx)
    if not name:
        await reply(update, "Использование: /links &lt;имя&gt;"); return
    r = admin_cmd("links", name)
    await reply(update, f"⚠️ {esc(r['error'])}" if "error" in r else links_text(r))


async def cmd_qr(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return
    name = name_arg(ctx)
    if not name:
        await reply(update, "Использование: /qr &lt;имя&gt;"); return
    with tempfile.TemporaryDirectory() as d:
        r = admin_cmd("qr", name, "--out", d)
        if "error" in r:
            await reply(update, f"⚠️ {esc(r['error'])}"); return
        for key, label in (("hysteria2", "🔵 Hysteria2 (mport = port hopping)"), ("naiveproxy", "🟠 NaiveProxy")):
            with open(r["files"][key], "rb") as f:
                await update.effective_message.reply_photo(
                    f, caption=f"<b>{label}</b>\n<code>{esc(r['links'][key])}</code>", parse_mode=ParseMode.HTML)


async def cmd_rotate(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return
    target = (ctx.args[0].lower() if ctx.args else "")
    if target != "all" and not (target and NAME_RE.fullmatch(target)):
        await reply(update, "Использование: /rotate &lt;имя&gt; или /rotate all"); return
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("✅ Да", callback_data=f"rotate:{target}"),
                                InlineKeyboardButton("❌ Отмена", callback_data="cancel")]])
    await reply(update, f"⚠️ Ротировать пароли: <b>{esc(target)}</b>? Старые ссылки перестанут работать "
                        f"(NaiveProxy перезапустится).", reply_markup=kb)


async def cmd_backup(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return
    await reply(update, "📦 Создаю зашифрованный бэкап…")
    r = admin_cmd("backup")
    await reply(update, f"⚠️ {esc(r['error'])}" if "error" in r else f"✅ Бэкап отправлен: <code>{esc(Path(r['file']).name)}</code>")


async def cmd_restart(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_admin(update):
        return
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("✅ Да", callback_data="restart"),
                                InlineKeyboardButton("❌ Отмена", callback_data="cancel")]])
    await reply(update, "🔁 Перезапустить Hysteria2 и NaiveProxy? Все активные сессии оборвутся.", reply_markup=kb)


async def on_callback(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    q = update.callback_query
    await q.answer()
    if not is_admin(update):
        return
    data = q.data or ""
    if data == "status":
        from proxy_admin import format_status
        s = admin_cmd("status")
        text = f"⚠️ {esc(s['error'])}" if "error" in s else format_status(s)
        try:
            await q.edit_message_text(text, parse_mode=ParseMode.HTML, reply_markup=status_markup())
        except Exception:  # noqa: BLE001 — «message is not modified»
            pass
    elif data == "restart_ask":
        kb = InlineKeyboardMarkup([[InlineKeyboardButton("✅ Да", callback_data="restart"),
                                    InlineKeyboardButton("❌ Отмена", callback_data="cancel")]])
        await q.edit_message_text("🔁 Перезапустить сервисы? Все сессии оборвутся.", reply_markup=kb)
    elif data == "restart":
        await q.edit_message_text("🔁 Перезапускаю…")
        r = admin_cmd("restart")
        await q.edit_message_text(f"⚠️ {esc(r['error'])}" if "error" in r else "✅ Сервисы перезапущены", parse_mode=ParseMode.HTML)
    elif data.startswith("rotate:"):
        target = data.split(":", 1)[1]
        await q.edit_message_text("🔄 Ротирую…")
        r = admin_cmd("rotate", "--all") if target == "all" else admin_cmd("rotate", target)
        if "error" in r:
            await q.edit_message_text(f"⚠️ {esc(r['error'])}", parse_mode=ParseMode.HTML)
        else:
            await q.edit_message_text(f"✅ Пароли обновлены: {esc(', '.join(r['rotated']))}", parse_mode=ParseMode.HTML)
            for l in r["links"].values():
                await q.message.reply_text(links_text(l), parse_mode=ParseMode.HTML)
    elif data == "cancel":
        await q.edit_message_text("❌ Отменено")


def main() -> int:
    if not CFG.tg_token:
        log.error("TG_TOKEN не задан в %s", PATHS.secrets_env)
        return 1
    if not ADMIN_IDS:
        log.error("TG_ADMIN_IDS пуст — бот никому не будет отвечать")
        return 1
    app = Application.builder().token(CFG.tg_token).build()
    for cmd, h in [("start", cmd_start), ("help", cmd_start), ("status", cmd_status), ("users", cmd_users),
                   ("adduser", cmd_adduser), ("deluser", cmd_deluser), ("enable", cmd_enable),
                   ("disable", cmd_disable), ("links", cmd_links), ("qr", cmd_qr), ("rotate", cmd_rotate),
                   ("backup", cmd_backup), ("restart", cmd_restart), ("whoami", cmd_whoami)]:
        app.add_handler(CommandHandler(cmd, h))
    app.add_handler(CallbackQueryHandler(on_callback))
    log.info("proxy-bot started; admins=%s notify_chat=%s", sorted(ADMIN_IDS), CFG.tg_chat_id)
    app.run_polling(drop_pending_updates=True, allowed_updates=Update.ALL_TYPES)
    return 0


if __name__ == "__main__":
    sys.exit(main())
