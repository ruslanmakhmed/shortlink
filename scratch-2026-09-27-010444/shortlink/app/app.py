"""Shortlink: сервис коротких ссылок. Все настройки — из переменных окружения."""
import json
import logging
import os
import secrets
import signal
import string
import sys
import threading
import time
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg2


def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        sys.exit(f"missing required environment variable {name}")
    return value


def db_password():
    # Пароль можно передать напрямую или файлом (Docker secrets в Compose).
    path = os.environ.get("DB_PASSWORD_FILE")
    if path:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    return env("DB_PASSWORD")


PORT = int(env("APP_PORT", "8080"))
VERSION = env("APP_VERSION", "dev")  # зашивается в образ при сборке (--build-arg VERSION)
DSN = {
    "host": env("DB_HOST"),
    "port": int(env("DB_PORT", "5432")),
    "dbname": env("DB_NAME"),
    "user": env("DB_USER"),
    "password": db_password(),
    "connect_timeout": 2,
}
logging.basicConfig(stream=sys.stdout, level=env("LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("shortlink")

METRICS = {"links_created": 0, "redirects": 0, "redirects_not_found": 0, "db_up": 0}
LOCK = threading.Lock()
SCHEMA = ("CREATE TABLE IF NOT EXISTS links (code TEXT PRIMARY KEY, url TEXT NOT NULL,"
          " hits BIGINT NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT now())")


def inc(name, value=1):
    with LOCK:
        METRICS[name] += value


def query(sql, args=(), fetch=False):
    # Соединение на запрос: при падении базы приложение не держит мёртвый пул,
    # а после её возврата само начинает работать. `with conn` — это транзакция,
    # закрывает соединение closing().
    with closing(psycopg2.connect(**DSN)) as conn, conn, conn.cursor() as cur:
        cur.execute(SCHEMA)
        cur.execute(sql, args)
        return cur.fetchone() if fetch else None


def rss_bytes():
    try:
        with open("/proc/self/statm", encoding="ascii") as f:
            return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")
    except OSError:
        return 0


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body=b"", ctype="application/json", headers=None):
        self.send_response(code)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, code, obj):
        self.send(code, json.dumps(obj).encode())

    def do_GET(self):
        if self.path == "/healthz":
            return self.send_json(200, {"status": "alive", "version": VERSION})
        if self.path == "/readyz":
            try:
                query("SELECT 1")
                METRICS["db_up"] = 1
                return self.send_json(200, {"status": "ready"})
            except psycopg2.Error as exc:
                METRICS["db_up"] = 0
                log.warning("database is not available: %s", " ".join(str(exc).split()))
                return self.send_json(503, {"status": "database unavailable"})
        if self.path == "/metrics":
            return self.send(200, render_metrics().encode(), "text/plain; version=0.0.4")
        if self.path.startswith("/r/"):
            row = query("UPDATE links SET hits = hits + 1 WHERE code = %s RETURNING url",
                        (self.path[3:],), fetch=True)
            if row is None:
                inc("redirects_not_found")
                return self.send_json(404, {"error": "not found"})
            inc("redirects")
            return self.send(302, headers={"Location": row[0]})
        return self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/links":
            return self.send_json(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            url = json.loads(self.rfile.read(length))["url"]
        except (ValueError, KeyError, TypeError):
            return self.send_json(400, {"error": 'expected JSON {"url": "..."}'})
        if not isinstance(url, str) or not url.startswith(("http://", "https://")):
            return self.send_json(400, {"error": "url must start with http:// or https://"})
        alphabet = string.ascii_letters + string.digits
        for _ in range(5):
            code = "".join(secrets.choice(alphabet) for _ in range(6))
            try:
                query("INSERT INTO links (code, url) VALUES (%s, %s)", (code, url))
                inc("links_created")
                return self.send_json(201, {"code": code})
            except psycopg2.errors.UniqueViolation:
                continue
        return self.send_json(500, {"error": "could not generate unique code"})

    def handle_one_request(self):
        # Одна строка лога на запрос: метод, путь, код ответа, время.
        start = time.monotonic()
        self._code = 0
        try:
            super().handle_one_request()
        except psycopg2.Error as exc:
            log.error("database error: %s", " ".join(str(exc).split()))
            self.send_json(503, {"error": "database unavailable"})
        if self._code:
            log.info("%s %s %d %.1fms", self.command, self.path, self._code,
                     (time.monotonic() - start) * 1000)

    def send_response(self, code, message=None):
        self._code = code
        super().send_response(code, message)

    def log_message(self, *args):
        pass  # стандартный лог заменён своим форматом выше


def render_metrics():
    lines = []
    for name, kind, help_text, value in (
        ("shortlink_links_created_total", "counter", "Сколько ссылок создано", METRICS["links_created"]),
        ("shortlink_redirects_total", "counter", "Успешные переходы", METRICS["redirects"]),
        ("shortlink_redirects_not_found_total", "counter", "Переходы по несуществующему коду",
         METRICS["redirects_not_found"]),
        ("shortlink_db_up", "gauge", "1 если последняя проверка /readyz дошла до базы", METRICS["db_up"]),
        ("process_resident_memory_bytes", "gauge", "Резидентная память процесса", rss_bytes()),
    ):
        lines += [f"# HELP {name} {help_text}", f"# TYPE {name} {kind}", f"{name} {value}"]
    lines += ["# HELP shortlink_build_info Версия запущенного образа", "# TYPE shortlink_build_info gauge",
              f'shortlink_build_info{{version="{VERSION}"}} 1']
    return "\n".join(lines) + "\n"


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    # В контейнере процесс — PID 1: без своего обработчика SIGTERM игнорируется,
    # и docker stop / удаление пода ждут таймаут, а потом убивают через SIGKILL.
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    log.info("shortlink %s listening on :%d, database %s:%s/%s", VERSION, PORT, DSN["host"], DSN["port"], DSN["dbname"])
    server.serve_forever()
    log.info("stopped")


if __name__ == "__main__":
    main()
