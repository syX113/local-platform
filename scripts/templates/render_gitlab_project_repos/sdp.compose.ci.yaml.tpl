services:
  airflow-init:
    volumes: !reset []

  airflow-webserver:
    volumes: !reset []

  airflow-scheduler:
    volumes: !override
      - airflow-logs:/opt/airflow/logs

  dlt-extractor:
    volumes: !reset []

  dbt-executor:
    volumes: !reset []
