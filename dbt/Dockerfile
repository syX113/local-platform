FROM python:3.11-slim

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    DBT_PROFILES_DIR=/opt/platform/dbt/profiles

WORKDIR /opt/platform

COPY dbt/requirements.txt /tmp/requirements.txt
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash git \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --upgrade pip \
    && pip install -r /tmp/requirements.txt

COPY dbt /opt/platform/dbt
COPY snowflake /opt/platform/snowflake

CMD ["dbt", "--version"]

