# shortlink

Сервис коротких ссылок: принимает длинный URL, возвращает короткий код, по коду делает редирект и считает переходы.
Приложение — ~180 строк на Python (стандартная библиотека + драйвер PostgreSQL), данные хранятся в PostgreSQL.
Вокруг него: контейнер, локальный стек Compose, Ansible-роль для фронтового узла с nginx, кластер Kubernetes (k3d), конвейер lint → build → push → deploy и мониторинг Prometheus + Grafana.

## Что с чем разговаривает

```
                         Kubernetes (k3d, namespace shortlink)
  curl ──► :8081 ──► traefik Ingress ──► Service shortlink:8080 ──► Pod shortlink ×2 ──► Service postgres:5432 ──► postgres-0 (PVC 1Gi)
             │        (shortlink.local)                                  ▲    │ /metrics
             │                                                          │    ▼
             └──► grafana.local / prometheus.local ──► Grafana ──► Prometheus (namespace monitoring)
                                                                      │  └─► cAdvisor kubelet (память подов)
                                                                      └─ алерты: alerts.yml

  Реестр образов: localhost:5000 с хоста = shortlink-registry:5000 изнутри кластера
  Ansible-узел: клиент ──► nginx :80 (шаблон, /metrics под паролем) ──► backend host:port из переменных группы
  Docker-стенд: compose: app (:8080) ──► db (PostgreSQL, том pgdata); свой реестр registry:2 на :5000
```

## Структура

| Каталог | Что внутри |
|---|---|
| `app/` | `app.py`, `requirements.txt`, `Dockerfile`, `.dockerignore` |
| `compose/` | `docker-compose.yml` (приложение + база), `registry.yml` (свой реестр), `.env.example` |
| `scripts/` | `bootstrap.sh`, `healthcheck.sh`, `backup.sh` |
| `ansible/` | `site.yml`, инвентарь с группами `staging`/`production`, роль `shortlink`, `vault.yml` (Ansible Vault) |
| `k8s/` | `k3d-cluster.yaml`, Kustomize: namespace, ConfigMap, PostgreSQL StatefulSet, Deployment, Service, Ingress |
| `monitoring/` | Prometheus (+RBAC), правила алертов, Grafana с провижинингом, `grafana/dashboard.json` |
| `ci/` | `run-stage.sh` (стадии конвейера), образ и установщик линтеров |
| `.gitlab-ci.yml` | конвейер GitLab: вызывает `ci/run-stage.sh` |
| `docs/` | `RUNBOOK.md`, `INCIDENT.md`, `DECISIONS.md`, `CLOUD.md` |

## API

```bash
curl -s -X POST -H 'Content-Type: application/json' -d '{"url": "https://example.com"}' http://127.0.0.1:8080/api/links   # {"code": "aB3xY9"}
curl -si http://127.0.0.1:8080/r/aB3xY9      # 302, Location: https://example.com; нет кода — 404
curl -s  http://127.0.0.1:8080/healthz       # 200, пока процесс жив ({"status":"alive","version":"v1.0.0"})
curl -s  http://127.0.0.1:8080/readyz        # 200 — база отвечает, 503 — нет
curl -s  http://127.0.0.1:8080/metrics       # метрики Prometheus
```

## 1. Локальный стек (стенд Docker)

```bash
git clone <URL репозитория> shortlink && cd shortlink
./scripts/bootstrap.sh
```

`bootstrap.sh` проверяет зависимости, создаёт `compose/.env` и случайный пароль базы в `compose/secrets/db_password.txt`, собирает образ, поднимает стек, ждёт `/readyz` и делает проверочный запрос.

Проверка «данные переживают перезапуск»:

```bash
CODE=$(curl -s -X POST -d '{"url":"https://example.com"}' http://127.0.0.1:8080/api/links | sed -E 's/.*"code": *"([^"]+)".*/\1/')
docker compose -f compose/docker-compose.yml down        # без -v: том pgdata остаётся
docker compose -f compose/docker-compose.yml up -d
./scripts/healthcheck.sh                                 # ждём, пока всё OK
curl -si http://127.0.0.1:8080/r/$CODE | head -3         # всё ещё 302
```

Свой реестр и стадии конвейера:

```bash
docker compose -f compose/registry.yml up -d
./ci/run-stage.sh lint      # без локальных линтеров сам соберёт образ с ними
./ci/run-stage.sh build
./ci/run-stage.sh push      # push в localhost:5000 + удаление локального образа + pull обратно
```

Обслуживание:

```bash
./scripts/healthcheck.sh            # 0 — всё хорошо, 2 — есть проблемы (в stderr)
./scripts/backup.sh --keep-days 7   # backups/shortlink-ГГГГММДД-ЧЧММСС.sql.gz
```

## 2. Подготовка узла (стенд Ansible)

```bash
cd shortlink/ansible
ansible-galaxy collection install -r requirements.yml
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519   # ключ служебного пользователя deploy
read -rs -p 'Пароль Ansible Vault: ' VP && echo "$VP" > .vault_pass && chmod 600 .vault_pass && unset VP
# адреса узлов и пользователь стенда — в inventory/hosts.yml
ansible all -m ping
ansible-playbook site.yml --vault-password-file .vault_pass                  # первый прогон
ansible-playbook site.yml --vault-password-file .vault_pass                  # второй: changed=0
ansible-playbook site.yml --vault-password-file .vault_pass --check          # без падений
ansible-lint
```

Пароль от `vault.yml` в репозитории не хранится: `.vault_pass` в `.gitignore`. Посмотреть или изменить: `ansible-vault view|edit|rekey inventory/group_vars/all/vault.yml`.

## 3. Кластер (стенд Kubernetes)

```bash
git clone <URL репозитория> shortlink && cd shortlink
k3d cluster create --config k8s/k3d-cluster.yaml     # кластер + реестр shortlink-registry (localhost:5000), порт 8081 -> Ingress
kubectl get ingressclass                              # traefik
./ci/run-stage.sh build && ./ci/run-stage.sh push && ./ci/run-stage.sh deploy
```

Проверка снаружи через Ingress (без правки `/etc/hosts`):

```bash
H='--resolve shortlink.local:8081:127.0.0.1'
curl -s $H http://shortlink.local:8081/healthz
CODE=$(curl -s $H -X POST -d '{"url":"https://example.com"}' http://shortlink.local:8081/api/links | sed -E 's/.*"code": *"([^"]+)".*/\1/')
curl -si $H http://shortlink.local:8081/r/$CODE | head -3
```

Для браузера: `echo '127.0.0.1 shortlink.local grafana.local prometheus.local' | sudo tee -a /etc/hosts`, затем
http://grafana.local:8081 (логин `admin`, пароль: `kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.password}' | base64 -d`)
и http://prometheus.local:8081/targets (цель `shortlink` должна быть в состоянии UP).
Без браузера на стенде: `kubectl -n monitoring port-forward svc/grafana 3000:3000`.

Обновление, откат, логи, бэкап, масштабирование — [docs/RUNBOOK.md](docs/RUNBOOK.md).

## Конвейер

| Стадия | Что делает | Когда в GitLab |
|---|---|---|
| lint | shellcheck, yamllint, ansible-lint, `kubectl kustomize` + kubeconform, promtool | каждый коммит |
| build | `docker build`, тег = git-тег (`v1.0.0`) или короткий хеш | каждый коммит |
| push | push в реестр, контрольный pull | каждый коммит |
| deploy | `kubectl apply -k` с тегом образа, ожидание rollout | только тег `vX.Y.Z` и задан `KUBECONFIG` |

Локально те же стадии: `./ci/run-stage.sh lint|build|push|deploy`. `.gitlab-ci.yml` вызывает этот же скрипт.

## Переменные окружения приложения

| Имя | Назначение | По умолчанию | Обязательна |
|---|---|---|---|
| `DB_HOST` | адрес PostgreSQL (имя сервиса) | — | да |
| `DB_PORT` | порт PostgreSQL | `5432` | нет |
| `DB_NAME` | имя базы | — | да |
| `DB_USER` | пользователь базы | — | да |
| `DB_PASSWORD` | пароль базы | — | да, если нет `DB_PASSWORD_FILE` |
| `DB_PASSWORD_FILE` | путь к файлу с паролем (Docker secrets) | — | вместо `DB_PASSWORD` |
| `APP_PORT` | порт HTTP | `8080` | нет |
| `LOG_LEVEL` | `DEBUG`/`INFO`/`WARNING`/`ERROR` | `INFO` | нет |
| `APP_VERSION` | версия, зашивается в образ при сборке | `dev` | нет |

Переменные Compose (`compose/.env`): `APP_VERSION`, `HOST_PORT`, `LOG_LEVEL`, `DB_NAME`, `DB_USER`, `REGISTRY` — см. `compose/.env.example`.
Переменные конвейера: `REGISTRY` (`localhost:5000`), `CLUSTER_REGISTRY` (`shortlink-registry:5000`), `IMAGE_TAG`.

## Частые проблемы

| Симптом | Причина и что делать |
|---|---|
| `/readyz` отвечает 503, `/healthz` — 200 | Приложение не достаёт до базы. Compose: `docker compose -f compose/docker-compose.yml ps` и `logs db`. Кластер: `kubectl -n shortlink get pods,endpoints`, `kubectl -n shortlink logs postgres-0`, есть ли Secret `shortlink-db`. |
| Поды `ImagePullBackOff` | Образа с таким тегом нет в реестре или имя реестра не совпадает. `curl localhost:5000/v2/shortlink/tags/list`, `docker ps --filter name=registry` (имя должно совпадать с `CLUSTER_REGISTRY`), `kubectl -n shortlink describe pod <под>` (Events). |
| `curl http://shortlink.local:8081` — 404 от traefik или нет соединения | Не тот Host: нужен `--resolve` или запись в `/etc/hosts`. Не проброшен порт: кластер создан не из `k8s/k3d-cluster.yaml` (`docker ps` — у `k3d-shortlink-serverlb` должно быть `0.0.0.0:8081->80`). |
| Второй прогон Ansible даёт `changed` или падает на подключении | Не подключайтесь под root: роль закрывает вход root по SSH. После первого прогона можно ходить под `deploy`: `-e ansible_user=deploy`. |
| Цель `shortlink` в Prometheus не UP | http://prometheus.local:8081/targets: ошибка там. Проверьте метку `app=shortlink` у подов и имя порта `http` (`kubectl -n shortlink get pods --show-labels`). |
| После пересоздания базы — `password authentication failed` | Secret создан заново с новым паролем, а том базы старый. Либо верните старый Secret, либо удалите PVC `data-postgres-0` (данные пропадут; перед этим — `backup.sh --target k8s`). |

## Документация

- [docs/RUNBOOK.md](docs/RUNBOOK.md) — выкат, откат, логи, резервная копия, масштабирование.
- [docs/INCIDENT.md](docs/INCIDENT.md) — разборы учебных инцидентов.
- [docs/DECISIONS.md](docs/DECISIONS.md) — принятые решения и почему.
- [docs/CLOUD.md](docs/CLOUD.md) — как это выглядело бы в AWS.
