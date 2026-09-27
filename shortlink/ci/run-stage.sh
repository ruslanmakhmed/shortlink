#!/usr/bin/env bash
# Стадии конвейера. Одни и те же команды локально и в CI:
#   ./ci/run-stage.sh lint | build | push | deploy
# .gitlab-ci.yml вызывает этот же скрипт — расхождений между ними быть не может.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly IMAGE_NAME="shortlink"
# Куда пушим с хоста (свой реестр на стенде: compose/registry.yml или реестр k3d).
readonly REGISTRY="${REGISTRY:-localhost:5000}"
# Как тот же реестр виден изнутри кластера k3d (см. k8s/k3d-cluster.yaml).
readonly CLUSTER_REGISTRY="${CLUSTER_REGISTRY:-shortlink-registry:5000}"
# Имя образа в k8s/kustomization.yaml — стадия deploy подменяет его тег.
readonly BASE_IMAGE="shortlink-registry:5000/shortlink"
readonly LINT_IMAGE="shortlink-lint:local"
readonly IMAGE_TAR="${ROOT}/.build/shortlink-image.tar"

usage() {
  cat <<USAGE
Использование: $(basename "$0") <стадия>

Стадии:
  lint    shellcheck, yamllint, ansible-lint, рендер и проверка схем манифестов, promtool
  build   сборка образа ${REGISTRY}/${IMAGE_NAME}:<тег>
  push    отправка образа в реестр и контрольное скачивание обратно
  deploy  применение манифестов приложения и мониторинга к текущему кластеру kubectl

Тег образа: git-тег текущего коммита (v1.0.0), иначе короткий хеш коммита.
Переопределить: IMAGE_TAG=... $(basename "$0") <стадия>

Переменные: REGISTRY (${REGISTRY}), CLUSTER_REGISTRY (${CLUSTER_REGISTRY}), IMAGE_TAG.
Коды возврата: 0 — стадия прошла; 1 — ошибка аргументов/окружения; 2 — стадия упала.
USAGE
}

die() { local code=$1; shift; echo "ОШИБКА: $*" >&2; exit "$code"; }
log() { echo "==> $*"; }
need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die 1 "не найдена команда '$c'"; done; }

image_tag() {
  if [[ -n "${IMAGE_TAG:-}" ]]; then echo "${IMAGE_TAG}"; return; fi
  if [[ -n "${CI_COMMIT_TAG:-}" ]]; then echo "${CI_COMMIT_TAG}"; return; fi
  git -C "${ROOT}" describe --tags --exact-match 2>/dev/null || git -C "${ROOT}" rev-parse --short HEAD
}

stage_lint() {
  local tools=(shellcheck yamllint ansible-lint kubectl kubeconform promtool)
  local missing=0
  for t in "${tools[@]}"; do command -v "$t" >/dev/null 2>&1 || missing=1; done
  if (( missing )); then
    # На стенде линтеров может не быть — тогда тот же скрипт запускается в образе с ними.
    need docker
    log "Линтеры не установлены локально — запускаю в контейнере ${LINT_IMAGE}"
    docker build -q -t "${LINT_IMAGE}" -f "${ROOT}/ci/lint.Dockerfile" "${ROOT}" >/dev/null
    docker run --rm -v "${ROOT}:/src" -w /src "${LINT_IMAGE}" ./ci/run-stage.sh lint
    return
  fi

  cd "${ROOT}"
  log "shellcheck"
  shellcheck scripts/*.sh ci/*.sh
  log "yamllint"
  yamllint --strict .
  log "ansible-lint"
  (cd ansible && ansible-lint)
  log "kubernetes: рендер kustomize + проверка схем (kubeconform)"
  # kubectl apply --dry-run=client требует доступ к API-серверу; kubeconform проверяет
  # манифесты по схемам Kubernetes без кластера — годится и для CI.
  for dir in k8s monitoring; do
    kubectl kustomize "${dir}" | kubeconform -strict -summary -kubernetes-version 1.30.4
  done
  log "prometheus: конфигурация и правила алертов"
  promtool check config --syntax-only monitoring/prometheus.yml
  promtool check rules monitoring/alerts.yml
}

stage_build() {
  need docker git
  local tag image
  tag=$(image_tag)
  image="${REGISTRY}/${IMAGE_NAME}:${tag}"
  log "Сборка ${image}"
  docker build --build-arg VERSION="${tag}" -t "${image}" "${ROOT}/app"
  # Образ сохраняется файлом: в CI стадия push идёт в другом задании и получает его артефактом.
  mkdir -p "$(dirname "${IMAGE_TAR}")"
  docker save -o "${IMAGE_TAR}" "${image}"
  log "Готово: ${image}"
}

stage_push() {
  need docker git curl
  local tag image
  tag=$(image_tag)
  image="${REGISTRY}/${IMAGE_NAME}:${tag}"
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    [[ -f "${IMAGE_TAR}" ]] || die 1 "образа ${image} нет — сначала стадия build"
    docker load -i "${IMAGE_TAR}"
  fi
  curl -fsS -o /dev/null "http://${REGISTRY}/v2/" \
    || die 1 "реестр ${REGISTRY} недоступен (docker compose -f compose/registry.yml up -d или k3d-кластер)"
  log "Отправка ${image}"
  docker push "${image}"
  log "Контрольное скачивание обратно"
  docker image rm "${image}" >/dev/null
  docker pull "${image}"
  log "Теги в реестре: $(curl -fsS "http://${REGISTRY}/v2/${IMAGE_NAME}/tags/list")"
}

ensure_secret() {
  # Секрет со случайным паролем создаётся один раз и в Git не попадает.
  # Повторный deploy его не трогает, иначе пароль разошёлся бы с уже инициализированной базой.
  local ns=$1 name=$2
  if kubectl -n "${ns}" get secret "${name}" >/dev/null 2>&1; then
    log "Secret ${ns}/${name} уже есть"
  else
    log "Создаю Secret ${ns}/${name} со случайным паролем"
    kubectl -n "${ns}" create secret generic "${name}" \
      --from-file=password=<(openssl rand -hex 24 | tr -d '\n')
  fi
}

stage_deploy() {
  need kubectl openssl git
  kubectl cluster-info >/dev/null 2>&1 || die 1 "нет доступа к кластеру (k3d cluster create --config k8s/k3d-cluster.yaml)"
  local tag
  tag=$(image_tag)
  # Overlay внутри репозитория (.build/ в .gitignore): kustomize принимает только относительный путь к базе.
  local overlay="${ROOT}/.build/deploy"

  kubectl apply -f "${ROOT}/k8s/namespace.yaml" -f "${ROOT}/monitoring/namespace.yaml"
  ensure_secret shortlink shortlink-db
  ensure_secret monitoring grafana-admin

  # Базовые манифесты из k8s/ + тег образа этого деплоя.
  mkdir -p "${overlay}"
  cat > "${overlay}/kustomization.yaml" <<KUST
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../k8s
images:
  - name: ${BASE_IMAGE}
    newName: ${CLUSTER_REGISTRY}/${IMAGE_NAME}
    newTag: ${tag}
KUST

  log "Деплой приложения, образ ${CLUSTER_REGISTRY}/${IMAGE_NAME}:${tag}"
  kubectl apply -k "${overlay}"
  kubectl -n shortlink annotate deployment/shortlink kubernetes.io/change-cause="deploy ${tag}" --overwrite
  kubectl -n shortlink rollout status statefulset/postgres --timeout=180s || die 2 "postgres не поднялся"
  kubectl -n shortlink rollout status deployment/shortlink --timeout=180s || die 2 "выкатка ${tag} не завершилась"

  log "Деплой мониторинга"
  kubectl apply -k "${ROOT}/monitoring"
  kubectl -n monitoring rollout status deployment/prometheus --timeout=180s || die 2 "prometheus не поднялся"
  kubectl -n monitoring rollout status deployment/grafana --timeout=180s || die 2 "grafana не поднялась"
  log "Готово: ${tag}"
}

[[ $# -eq 1 ]] || { usage >&2; exit 1; }
case "$1" in
  lint) stage_lint ;;
  build) stage_build ;;
  push) stage_push ;;
  deploy) stage_deploy ;;
  -h|--help) usage ;;
  *) usage >&2; die 1 "неизвестная стадия: $1" ;;
esac
