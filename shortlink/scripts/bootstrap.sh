#!/usr/bin/env bash
# Поднимает локальный стек (приложение + PostgreSQL) с нуля на чистом стенде.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly COMPOSE_DIR="${ROOT}/compose"
TIMEOUT=60

usage() {
  cat <<USAGE
Использование: $(basename "$0") [--timeout СЕК] [-h|--help]

Поднимает локальный стек shortlink:
  1. проверяет зависимости (docker, docker compose, curl, openssl);
  2. создаёт compose/.env из .env.example и пароль базы в compose/secrets/, если их нет;
  3. собирает образ и запускает стек;
  4. ждёт готовности /readyz и делает проверочный запрос (создание ссылки + переход).

Параметры:
  --timeout СЕК  сколько ждать готовности (по умолчанию ${TIMEOUT})
  -h, --help     эта справка

Коды возврата: 0 — стек готов; 1 — ошибка аргументов; 2 — нет зависимостей;
               3 — стек не стал готов за отведённое время; 4 — проверочный запрос не прошёл.
USAGE
}

die() { local code=$1; shift; echo "ОШИБКА: $*" >&2; exit "$code"; }
log() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || die 1 "--timeout требует число секунд"
      TIMEOUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die 1 "неизвестный аргумент: $1" ;;
  esac
done

log "Проверяю зависимости"
for cmd in docker curl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || die 2 "не найдена команда '$cmd'"
done
docker compose version >/dev/null 2>&1 || die 2 "нет плагина 'docker compose'"
docker info >/dev/null 2>&1 || die 2 "Docker daemon недоступен (запущен? есть права?)"

if [[ ! -f "${COMPOSE_DIR}/.env" ]]; then
  log "Создаю compose/.env из .env.example"
  cp "${COMPOSE_DIR}/.env.example" "${COMPOSE_DIR}/.env"
fi

if [[ ! -s "${COMPOSE_DIR}/secrets/db_password.txt" ]]; then
  log "Генерирую пароль базы в compose/secrets/db_password.txt"
  mkdir -p "${COMPOSE_DIR}/secrets"
  (umask 077 && openssl rand -hex 24 > "${COMPOSE_DIR}/secrets/db_password.txt")
fi

# HOST_PORT может быть пустым в .env — тогда дефолт 8080, как в docker-compose.yml.
HOST_PORT=$(grep -E '^HOST_PORT=' "${COMPOSE_DIR}/.env" | cut -d= -f2- || true)
readonly BASE_URL="http://127.0.0.1:${HOST_PORT:-8080}"

log "Собираю образ и запускаю стек"
docker compose --project-directory "${COMPOSE_DIR}" -f "${COMPOSE_DIR}/docker-compose.yml" up -d --build

log "Жду готовности ${BASE_URL}/readyz (до ${TIMEOUT} с)"
deadline=$((SECONDS + TIMEOUT))
until curl -fsS -o /dev/null "${BASE_URL}/readyz" 2>/dev/null; do
  (( SECONDS < deadline )) || die 3 "стек не готов за ${TIMEOUT} с; смотрите: docker compose -f compose/docker-compose.yml logs"
  sleep 2
done

log "Проверочный запрос"
response=$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d '{"url": "https://example.com/bootstrap-check"}' "${BASE_URL}/api/links") \
  || die 4 "POST /api/links не прошёл"
code=$(sed -E 's/.*"code": *"([^"]+)".*/\1/' <<<"${response}")
status=$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/r/${code}") || die 4 "GET /r/${code} не прошёл"
[[ "${status}" == "302" ]] || die 4 "ожидали 302 на /r/${code}, получили ${status}"

log "Готово: ${BASE_URL}/r/${code} -> https://example.com/bootstrap-check"
