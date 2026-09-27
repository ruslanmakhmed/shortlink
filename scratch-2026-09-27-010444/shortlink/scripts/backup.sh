#!/usr/bin/env bash
# Дамп базы в архив с датой в имени + удаление архивов старше N дней.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
TARGET="compose"
DIR="${ROOT}/backups"
KEEP_DAYS=""
NAMESPACE="shortlink"

usage() {
  cat <<USAGE
Использование: $(basename "$0") --keep-days N [параметры]

Снимает pg_dump базы shortlink в <dir>/shortlink-ГГГГММДД-ЧЧММСС.sql.gz
и удаляет архивы старше N дней.

Параметры:
  --keep-days N     сколько дней хранить архивы (обязательный)
  --target T        compose | k8s — откуда снимать дамп (по умолчанию ${TARGET})
  --dir DIR         каталог для архивов (по умолчанию ${DIR})
  --namespace NS    namespace для --target k8s (по умолчанию ${NAMESPACE})
  -h, --help        эта справка

Восстановление: см. docs/RUNBOOK.md, раздел «Резервная копия».
Коды возврата: 0 — успех; 1 — ошибка аргументов/нет зависимостей; 2 — дамп не снят.
USAGE
}

die() { local code=$1; shift; echo "ОШИБКА: $*" >&2; exit "$code"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-days)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || die 1 "--keep-days требует целое число"
      KEEP_DAYS=$2; shift 2 ;;
    --target)
      [[ $# -ge 2 && ( "$2" == compose || "$2" == k8s ) ]] || die 1 "--target: compose или k8s"
      TARGET=$2; shift 2 ;;
    --dir) [[ $# -ge 2 ]] || die 1 "--dir требует значение"; DIR=$2; shift 2 ;;
    --namespace) [[ $# -ge 2 ]] || die 1 "--namespace требует значение"; NAMESPACE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die 1 "неизвестный аргумент: $1" ;;
  esac
done
[[ -n "${KEEP_DAYS}" ]] || { usage >&2; die 1 "не задан --keep-days"; }

mkdir -p "${DIR}"
archive="${DIR}/shortlink-$(date +%Y%m%d-%H%M%S).sql.gz"
tmp="${archive}.part"
trap 'rm -f "${tmp}"' EXIT

# pg_dump выполняется внутри контейнера базы: там есть и утилита, и переменные с именем базы.
# Одинарные кавычки намеренные: переменные раскрывает shell внутри контейнера, а не наш.
# shellcheck disable=SC2016
dump_cmd='pg_dump --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"'
case "${TARGET}" in
  compose)
    command -v docker >/dev/null 2>&1 || die 1 "не найдена команда docker"
    docker compose -f "${ROOT}/compose/docker-compose.yml" exec -T db sh -c "${dump_cmd}" | gzip > "${tmp}" \
      || die 2 "pg_dump через docker compose не удался" ;;
  k8s)
    command -v kubectl >/dev/null 2>&1 || die 1 "не найдена команда kubectl"
    kubectl -n "${NAMESPACE}" exec postgres-0 -- sh -c "${dump_cmd}" | gzip > "${tmp}" \
      || die 2 "pg_dump через kubectl не удался" ;;
esac
mv "${tmp}" "${archive}"
echo "Снят дамп: ${archive} ($(du -h "${archive}" | cut -f1))"

deleted=$(find "${DIR}" -maxdepth 1 -name 'shortlink-*.sql.gz' -mtime +"${KEEP_DAYS}" -print -delete | wc -l)
echo "Удалено архивов старше ${KEEP_DAYS} дн.: ${deleted// /}"
