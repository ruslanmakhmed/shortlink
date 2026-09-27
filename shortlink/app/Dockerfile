# syntax=docker/dockerfile:1
# Стадия 1: ставим зависимости в отдельный venv. pip и его кэш в итоговый образ не попадают.
FROM python:3.12.6-slim-bookworm AS build
RUN python -m venv /venv
# Сначала только requirements.txt: правка app.py не сбрасывает кэш слоя с зависимостями.
COPY requirements.txt .
RUN /venv/bin/pip install --no-cache-dir -r requirements.txt

# Стадия 2: тонкий рантайм — slim-образ + готовый venv + код.
# Alpine не берём: у psycopg2-binary нет стабильных колёс под musl, пришлось бы компилировать.
FROM python:3.12.6-slim-bookworm
# Версия = git-тег; передаёт ci/run-stage.sh build. Видна в /healthz и метрике shortlink_build_info.
ARG VERSION=dev
ENV APP_VERSION=$VERSION \
    PATH=/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /venv /venv
COPY app.py /app/app.py
WORKDIR /app
USER 10001:10001
EXPOSE 8080
# curl в slim-образе нет, проверяем стандартной библиотекой Python.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.environ.get('APP_PORT', '8080'), timeout=2)"]
CMD ["python", "app.py"]
