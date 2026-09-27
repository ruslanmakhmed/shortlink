# RUNBOOK

Все команды выполняются из корня репозитория. Кластер: `kubectl config current-context` → `k3d-shortlink`.

## Выкат новой версии

```bash
git switch main && git pull
git tag -a v1.1.0 -m "v1.1.0: <что изменилось>" && git push origin v1.1.0
./ci/run-stage.sh build           # образ localhost:5000/shortlink:v1.1.0
./ci/run-stage.sh push
./ci/run-stage.sh deploy          # apply + ожидание rollout status
```

Наблюдать в соседнем терминале:

```bash
kubectl -n shortlink get pods -w                       # новые поды появляются по одному (maxSurge 1), старые уходят после готовности новых (maxUnavailable 0)
kubectl -n shortlink get rs                            # новый ReplicaSet растёт, старый уменьшается до 0 — но не удаляется
kubectl -n shortlink rollout history deployment/shortlink
curl -s --resolve shortlink.local:8081:127.0.0.1 http://shortlink.local:8081/healthz   # "version": "v1.1.0"
```

## Откат

```bash
kubectl -n shortlink rollout history deployment/shortlink            # список ревизий и change-cause
kubectl -n shortlink rollout undo deployment/shortlink                # на предыдущую ревизию
kubectl -n shortlink rollout undo deployment/shortlink --to-revision=<N>
kubectl -n shortlink rollout status deployment/shortlink
curl -s --resolve shortlink.local:8081:127.0.0.1 http://shortlink.local:8081/healthz   # версия снова старая
```

Откат быстрый, потому что старый ReplicaSet никуда не делся: Kubernetes просто снова масштабирует его вверх. Образ уже лежит на узлах, пересобирать и заново пушить ничего не нужно.
Откат через `undo` — оперативная мера. После него в Git нужно зафиксировать, какая версия работает (повторный `deploy` с нужным `IMAGE_TAG` или новый тег с исправлением), иначе следующий deploy вернёт сломанную версию.

Выкат без нового тега (например, для репетиции): `IMAGE_TAG=v1.1.0 ./ci/run-stage.sh deploy`.

## Логи

```bash
kubectl -n shortlink logs deploy/shortlink --tail=50 -f             # один из подов
kubectl -n shortlink logs -l app=shortlink --tail=20 --prefix       # все поды приложения
kubectl -n shortlink logs <под> --previous                          # логи упавшего контейнера до перезапуска
kubectl -n shortlink logs postgres-0 --tail=50
kubectl -n shortlink get events --sort-by=.lastTimestamp | tail -20
docker compose -f compose/docker-compose.yml logs -f app            # локальный стек
```

## Резервная копия

Снятие:

```bash
./scripts/backup.sh --target k8s --keep-days 7        # кластер -> backups/shortlink-*.sql.gz
./scripts/backup.sh --target compose --keep-days 7    # локальный стек
```

Восстановление (дамп снят с `--clean --if-exists`, поэтому таблицы пересоздаются):

```bash
F=backups/shortlink-<дата>.sql.gz
# кластер
gunzip -c "$F" | kubectl -n shortlink exec -i postgres-0 -- sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB"'
# локальный стек
gunzip -c "$F" | docker compose -f compose/docker-compose.yml exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB"'
# проверка
kubectl -n shortlink exec postgres-0 -- sh -c 'psql -U "$POSTGRES_USER" "$POSTGRES_DB" -c "select count(*) from links"'
```

## Масштабирование

```bash
kubectl -n shortlink scale deployment/shortlink --replicas=4     # оперативно
kubectl -n shortlink get pods -l app=shortlink -o wide
```

`scale` действует до следующего `deploy`: тот применит `replicas: 2` из `k8s/app.yaml`. Постоянное изменение — правка `k8s/app.yaml` через ветку и запрос на слияние.
База масштабируется только вертикально (`resources` в `k8s/postgres.yaml`). Реплики PostgreSQL в проект не входят.

## Полное пересоздание

```bash
k3d cluster delete shortlink
k3d cluster create --config k8s/k3d-cluster.yaml
./ci/run-stage.sh build && ./ci/run-stage.sh push && ./ci/run-stage.sh deploy
```

При удалении кластера удаляется и реестр `shortlink-registry`, поэтому образ собирается и пушится заново.

## Журнал выполнения

Сюда записываются реальные прогоны: дата, команды, что увидели. Заполняется при выполнении, а не задним числом.

### Обновление vX → vY — <дата>

- Команды:
- Что было видно в `get pods -w` / `get rs`:
- Сколько заняло:
- Были ли ошибки у клиентов во время выката (цикл `curl` в соседнем терминале):

### Откат vY → vX — <дата>

- Команды:
- Ревизия до и после (`rollout history`):
- Сколько заняло и почему так быстро:
