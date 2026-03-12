FROM python:3.11-slim

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

WORKDIR /opt/platform

COPY dlt/requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip \
    && pip install -r /tmp/requirements.txt

COPY dlt /opt/platform/dlt

ENTRYPOINT ["/bin/sh", "/opt/platform/dlt/entrypoint.sh"]
