# Образ со всеми линтерами стадии lint. Собирает ci/run-stage.sh, если линтеров нет на хосте.
# Контекст сборки — корень репозитория.
FROM python:3.12.6-slim-bookworm
COPY ci/install-lint-tools.sh /tmp/ci/install-lint-tools.sh
COPY ansible/requirements.yml /tmp/ansible/requirements.yml
RUN bash /tmp/ci/install-lint-tools.sh && rm -rf /tmp/ci /tmp/ansible \
 && git config --global --add safe.directory /src
