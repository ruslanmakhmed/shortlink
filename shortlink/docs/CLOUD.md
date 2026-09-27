# shortlink в AWS (письменный разбор)

Реальный аккаунт не заводился. Цены — порядок величин для региона eu-central-1 на момент написания; важна структура, а не копейки.

## Что чем заменяется

| Часть сейчас | В AWS | Почему |
|---|---|---|
| свой реестр `registry:2` | **ECR** | приватный реестр с IAM-доступом, сканирование образов, lifecycle-правила для старых тегов; включить immutable tags — тег `v1.0.0` нельзя перезаписать |
| k3d | **EKS** (managed node group из 2× t3.small в двух AZ) | те же манифесты почти без изменений; альтернатива — ECS Fargate (дешевле в обслуживании, но пришлось бы переписать k8s/ и мониторинг) |
| traefik Ingress + порт 8081 | **ALB** через AWS Load Balancer Controller (`ingressClassName: alb`) + **ACM** (бесплатный TLS) + **Route 53** | настоящий HTTPS и домен вместо `/etc/hosts` |
| PostgreSQL в StatefulSet | **RDS for PostgreSQL** (db.t4g.micro, Multi-AZ в production) | см. ниже |
| Secret, созданный скриптом | **Secrets Manager** + External Secrets Operator или CSI Secrets Store | ротация пароля RDS, аудит доступа в CloudTrail |
| Prometheus + Grafana в кластере | **Amazon Managed Service for Prometheus** + **Managed Grafana**, либо оставить свои | меньше обслуживания, история метрик переживает кластер |
| stdout + `kubectl logs` | **CloudWatch Logs** (Fluent Bit как DaemonSet) | логи переживают удалённый под |
| Ansible-узел с nginx | не нужен: его роль выполняет ALB | если нужен bastion — лучше SSM Session Manager без открытого SSH |

## База: в кластере или управляемая

**За управляемую RDS:** автоматические бэкапы и point-in-time recovery, Multi-AZ с отработкой отказа, патчи минорных версий, мониторинг из коробки. Главное: база не живёт на одном узле, как сейчас `local-path` в k3d, и её состояние не связано с жизнью кластера. Кластер можно пересоздать, данные останутся.
**Против:** дороже (Multi-AZ примерно удваивает цену), меньше контроля над версиями и расширениями, выход за пределы Kubernetes-манифестов (база описывается уже не в `k8s/`).
**Вывод:** для production — RDS. StatefulSet с EBS-томом допустим для dev-окружения, где данные не жалко.

## Доступ к облачным ресурсам без ключей в репозитории

- Под приложения получает IAM-роль через **EKS Pod Identity** (или IRSA): ServiceAccount связан с ролью, AWS SDK получает временные токены автоматически. Ключей `AWS_ACCESS_KEY_ID` нет нигде.
- Пароль к RDS лежит в Secrets Manager. Роль пода может читать только `secret/shortlink/db`. Ещё лучше — IAM-аутентификация в RDS, тогда пароля нет совсем.
- Конвейер ходит в AWS через **OIDC-федерацию** GitLab/GitHub → `AssumeRoleWithWebIdentity`: роль CI может только пушить в ECR и деплоить в конкретный кластер. Долгоживущих ключей в переменных CI нет.
- Узлы EKS тянут образы из ECR по роли узла.

## Что открыто, что закрыто

- **Открыто в интернет:** только ALB, порты 443 (и 80 с редиректом на 443). Security group ALB: 0.0.0.0/0 на 443.
- **Приватные подсети:** узлы EKS и RDS. SG узлов принимает трафик только от SG ALB. SG RDS принимает 5432 только от SG узлов.
- **API EKS:** публичный endpoint ограничен IP офиса/VPN или только private endpoint.
- **/metrics, Grafana, Prometheus:** наружу не публикуются, доступ через VPN/SSO. Сейчас в учебной версии `/metrics` виден через Ingress — в production закрыл бы.
- Исходящий трафик из приватных подсетей — через NAT Gateway; к ECR и S3 — через VPC endpoints (дешевле и без интернета).

## Порядок стоимости в месяц

| Ресурс | ~$/мес |
|---|---|
| EKS control plane | 73 |
| 2× t3.small (узлы) | 30 |
| RDS db.t4g.micro, 20 ГБ gp3 (single-AZ / Multi-AZ) | 15 / 30 |
| ALB | 20 |
| NAT Gateway (1 шт.) + трафик | 35 |
| ECR, Secrets Manager, CloudWatch Logs, Route 53 | 5–10 |
| **Итого** | **~180–200** |

Больше всего стоят управляющий слой EKS и NAT, а не само приложение. Для сервиса такого размера дешевле ECS Fargate или даже один EC2 с Docker Compose (~30–40 $/мес). EKS оправдан, когда рядом живут другие сервисы и команда уже умеет Kubernetes.
