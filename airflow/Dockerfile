ARG AIRFLOW_IMAGE=apache/airflow:2.10.5-python3.11
FROM ${AIRFLOW_IMAGE}

ARG AIRFLOW_VERSION=2.10.5
ARG PYTHON_VERSION=3.11

COPY airflow/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt" \
    -r /tmp/requirements.txt

COPY dlt/requirements.txt /tmp/dlt-requirements.txt
COPY dbt/requirements.txt /tmp/dbt-requirements.txt
RUN python -m venv /home/airflow/dlt-runtime \
    && /home/airflow/dlt-runtime/bin/pip install --no-cache-dir --upgrade pip \
    && /home/airflow/dlt-runtime/bin/pip install --no-cache-dir \
    -r /tmp/dlt-requirements.txt
RUN python -m venv /home/airflow/dbt-runtime \
    && /home/airflow/dbt-runtime/bin/pip install --no-cache-dir --upgrade pip \
    && /home/airflow/dbt-runtime/bin/pip install --no-cache-dir \
    -r /tmp/dbt-requirements.txt

USER airflow
COPY airflow/dags /opt/airflow/dags
COPY airflow/init-airflow.sh /opt/platform/airflow/init-airflow.sh
COPY postgres/source-init /opt/platform/postgres/source-init
