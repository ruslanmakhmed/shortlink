#!/usr/bin/env bash
# Проверка здоровья: /readyz, место на диске, состояние контейнеров. Пригоден для cron.
set -euo pipefail

URL="http://127.0.0.1:8080/readyz"
DISK_PATH="/"
DISK_MAX=90
CHECK_CONTAINERS=1
PROJECT="shortlink"

usage() {
  cat <<USAGE
Использование: $(basename "$0") [параметры]

Параметры:
  --url URL           адрес проверки готовности (по умолчанию ${URL})
  --disk-path PATH    какой раздел проверять (по умолчанию ${DISK_PATH})
  --disk-max ПРОЦ     порог заполнения диска в процентах (по умолчанию ${DISK_MAX})
  --project ИМЯ       compose-проект, чьи контейнеры проверять (по умолчанию ${PROJECT})
  --no-containers     не проверять контейнеры (узлы без Docker)
  -h, --help          эта справка

Коды возврата: 0 — всё хорошо; 1 — ошибка аргументов/нет зависимостей;
               2 — есть проблемы (подробности в stderr).
USAGE
}

die() { echo "ОШИБКА: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) [[ $# -ge 2 ]] || die "--url требует значение"; URL=$2; shift 2 ;;
    --disk-path) [[ $# -ge 2 ]] || die "--disk-path требует значение"; DISK_PATH=$2; shift 2 ;;
    --disk-max)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -le 100 ]] || die "--disk-max требует число 0..100"
      DISK_MAX=$2; shift 2 ;;
    --project) [[ $# -ge 2 ]] || die "--project требует значение"; PROJECT=$2; shift 2 ;;
    --no-containers) CHECK_CONTAINERS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "неизвестный аргумент: $1" ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "не найдена команда curl"
problems=0
fail() { echo "FAIL: $*" >&2; problems=$((problems + 1)); }
ok() { echo "OK:   $*"; }

# 1. Готовность приложения
status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${URL}" 2>/dev/null) || status="нет ответа"
if [[ "${status}" == "200" ]]; then ok "${URL} -> 200"; else fail "${URL} -> ${status}"; fi

# 2. Место на диске
[[ -d "${DISK_PATH}" ]] || die "нет каталога ${DISK_PATH}"
used=$(df -P "${DISK_PATH}" | awk 'NR==2 {gsub("%", "", $5); print $5}')
if (( used < DISK_MAX )); then ok "диск ${DISK_PATH} занят на ${used}%"; else fail "диск ${DISK_PATH} занят на ${used}% (порог ${DISK_MAX}%)"; fi

# 3. Контейнеры compose-проекта: все запущены и не unhealthy
if (( CHECK_CONTAINERS )); then
  command -v docker >/dev/null 2>&1 || die "не найдена команда docker (или используйте --no-containers)"
  states=$(docker ps -a --filter "label=com.docker.compose.project=${PROJECT}" \
    --format '{{.Names}} {{.State}} {{.Status}}')
  if [[ -z "${states}" ]]; then
    fail "контейнеров проекта ${PROJECT} нет"
  else
    while read -r name state rest; do
      if [[ "${state}" != "running" || "${rest}" == *"unhealthy"* ]]; then
        fail "контейнер ${name}: ${state} ${rest}"
      else
        ok "контейнер ${name}: ${rest}"
      fi
    done <<<"${states}"
  fi
fi

if (( problems > 0 )); then
  echo "Итог: проблем — ${problems}" >&2
  exit 2
fi
echo "Итог: всё в порядке"
