#!/usr/bin/env bash
# Ставит линтеры для стадии lint (Debian/Ubuntu, под root). Используется в ci/lint.Dockerfile
# и в задании lint в .gitlab-ci.yml — версии одинаковые везде.
set -euo pipefail

readonly KUBECTL_VERSION="v1.30.4"
readonly KUBECONFORM_VERSION="v0.6.7"
readonly PROMETHEUS_VERSION="2.54.1"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Использование: $(basename "$0")  — установить shellcheck, yamllint, ansible-lint, kubectl, kubeconform, promtool"
  exit 0
fi
[[ $# -eq 0 ]] || { echo "ОШИБКА: скрипт не принимает аргументов" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || { echo "ОШИБКА: нужен root" >&2; exit 1; }

arch=$(dpkg --print-architecture)  # amd64 | arm64
apt-get update -qq
apt-get install -y -qq --no-install-recommends curl ca-certificates git >/dev/null
rm -rf /var/lib/apt/lists/*

pip install --no-cache-dir -q shellcheck-py==0.10.0.1 yamllint==1.35.1 ansible-core==2.17.4 ansible-lint==24.9.2
ansible-galaxy collection install -r "$(dirname "$0")/../ansible/requirements.yml" -p /usr/share/ansible/collections

curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"
chmod +x /usr/local/bin/kubectl
curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${arch}.tar.gz" \
  | tar -xz -C /usr/local/bin kubeconform
curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-${arch}.tar.gz" \
  | tar -xz -C /usr/local/bin --strip-components=1 "prometheus-${PROMETHEUS_VERSION}.linux-${arch}/promtool"
