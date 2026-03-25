name: ${COMPOSE_PROJECT_NAME:-proj-sdp-local}

x-common-env: &common-env
  PLATFORM_DOCKER_NETWORK: ${PLATFORM_DOCKER_NETWORK:-local-platform-net}
  AWS_ACCESS_KEY_ID: ${OBJECT_STORE_ACCESS_KEY_ID}
  AWS_SECRET_ACCESS_KEY: ${OBJECT_STORE_SECRET_ACCESS_KEY}
  AWS_DEFAULT_REGION: ${OBJECT_STORE_REGION}
  AWS_REGION: ${OBJECT_STORE_REGION}
  PYICEBERG_MAX_WORKERS: "1"
  MINIO_ROOT_USER: ${MINIO_ROOT_USER}
  MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
  MINIO_BUCKET: ${MINIO_BUCKET}
  MINIO_PREFIX: ${MINIO_PREFIX}
  MINIO_ENDPOINT: ${MINIO_ENDPOINT}
  MINIO_PUBLIC_ENDPOINT: ${MINIO_PUBLIC_ENDPOINT}
  MINIO_USE_SSL: ${MINIO_USE_SSL}
  MINIO_REGION: ${MINIO_REGION}
  OBJECT_STORE_TYPE: ${OBJECT_STORE_TYPE}
  OBJECT_STORE_BUCKET: ${OBJECT_STORE_BUCKET}
  OBJECT_STORE_ACCESS_KEY_ID: ${OBJECT_STORE_ACCESS_KEY_ID}
  OBJECT_STORE_SECRET_ACCESS_KEY: ${OBJECT_STORE_SECRET_ACCESS_KEY}
  OBJECT_STORE_ENDPOINT_URL: ${OBJECT_STORE_ENDPOINT_URL}
  OBJECT_STORE_REGION: ${OBJECT_STORE_REGION}
  OBJECT_STORE_USE_SSL: ${OBJECT_STORE_USE_SSL}
  DLT_PIPELINE_NAME: ${DLT_PIPELINE_NAME}
  DLT_REFRESH_MODE: ${DLT_REFRESH_MODE}
  ICEBERG_CATALOG_NAME: ${ICEBERG_CATALOG_NAME}
  ICEBERG_NAMESPACE: ${ICEBERG_NAMESPACE}
  ICEBERG_CATALOG_TYPE: ${ICEBERG_CATALOG_TYPE}
  ICEBERG_SQL_URI: ${ICEBERG_SQL_URI}
  SOURCE_POSTGRES_HOST: ${SOURCE_POSTGRES_HOST}
  SOURCE_POSTGRES_PORT: ${SOURCE_POSTGRES_PORT}
  SOURCE_POSTGRES_DB: ${SOURCE_POSTGRES_DB}
  SOURCE_POSTGRES_USER: ${SOURCE_POSTGRES_USER}
  SOURCE_POSTGRES_PASSWORD: ${SOURCE_POSTGRES_PASSWORD}
  SOURCE_POSTGRES_SCHEMA: ${SOURCE_POSTGRES_SCHEMA}
  OPEN_CATALOG_URI: ${OPEN_CATALOG_URI}
  OPEN_CATALOG_NAME: ${OPEN_CATALOG_NAME}
  OPEN_CATALOG_CLIENT_ID: ${OPEN_CATALOG_CLIENT_ID}
  OPEN_CATALOG_CLIENT_SECRET: ${OPEN_CATALOG_CLIENT_SECRET}
  OPEN_CATALOG_SCOPE: ${OPEN_CATALOG_SCOPE}
  OPEN_CATALOG_ACCESS_DELEGATION: ${OPEN_CATALOG_ACCESS_DELEGATION}
  SNOWFLAKE_ACCOUNT: ${SNOWFLAKE_ACCOUNT}
  SNOWFLAKE_USER: ${SNOWFLAKE_USER}
  SNOWFLAKE_PASSWORD: ${SNOWFLAKE_PASSWORD}
  SNOWFLAKE_ROLE: ${SNOWFLAKE_ROLE}
  SNOWFLAKE_WAREHOUSE: ${SNOWFLAKE_WAREHOUSE}
  SNOWFLAKE_CONTROL_DATABASE: ${SNOWFLAKE_CONTROL_DATABASE:-LOCAL_PLATFORM_CONTROL}
  SNOWFLAKE_CONTROL_SCHEMA: ${SNOWFLAKE_CONTROL_SCHEMA:-OPERATIONS}
  SNOWFLAKE_DBT_STAGE: ${SNOWFLAKE_DBT_STAGE:-DBT_PROJECT_STAGE}
  SNOWFLAKE_SDP_DATABASE: ${SNOWFLAKE_SDP_DATABASE}
  SNOWFLAKE_SDP_IN_SCHEMA: ${SNOWFLAKE_SDP_IN_SCHEMA}
  SNOWFLAKE_SDP_CORE_SCHEMA: ${SNOWFLAKE_SDP_CORE_SCHEMA}
  SNOWFLAKE_SDP_ACC_SCHEMA: ${SNOWFLAKE_SDP_ACC_SCHEMA}
  SNOWFLAKE_SDP_CUSTOMERS_DATABASE: ${SNOWFLAKE_SDP_CUSTOMERS_DATABASE}
  SNOWFLAKE_SDP_DBT_PROJECT: ${SNOWFLAKE_SDP_DBT_PROJECT:-DEV_DBT_PROJECT_SOURCE_FINNOVA}
  SNOWFLAKE_EDP_DATABASE: ${SNOWFLAKE_EDP_DATABASE}
  SNOWFLAKE_EDP_CUSTOMERS_DATABASE: ${SNOWFLAKE_EDP_CUSTOMERS_DATABASE}
  SNOWFLAKE_EDP_IN_SCHEMA: ${SNOWFLAKE_EDP_IN_SCHEMA}
  SNOWFLAKE_EDP_CORE_SCHEMA: ${SNOWFLAKE_EDP_CORE_SCHEMA}
  SNOWFLAKE_EDP_ACC_SCHEMA: ${SNOWFLAKE_EDP_ACC_SCHEMA}
  SNOWFLAKE_EDP_DBT_PROJECT: ${SNOWFLAKE_EDP_DBT_PROJECT:-DEV_DBT_PROJECT_EDP_ORDERS}
  SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT: ${SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT:-DEV_DBT_PROJECT_EDP_CUSTOMERS}
  SNOWFLAKE_CATALOG_INTEGRATION: ${SNOWFLAKE_CATALOG_INTEGRATION}
  SNOWFLAKE_CLONE_SCHEMA: ${SNOWFLAKE_CLONE_SCHEMA}
  SNOWFLAKE_LOCAL_RAW_SYNC: ${SNOWFLAKE_LOCAL_RAW_SYNC}
  SNOW_DBT_TARGET_NAME: ${SNOW_DBT_TARGET_NAME:-dev}
  DBT_THREADS: ${DBT_THREADS}

x-airflow-build: &airflow-build
  context: .
  dockerfile: airflow/Dockerfile
  args:
    AIRFLOW_IMAGE: ${AIRFLOW_IMAGE:-apache/airflow:2.10.5-python3.11}
    AIRFLOW_VERSION: "2.10.5"
    PYTHON_VERSION: "3.11"

x-airflow-env: &airflow-env
  <<: *common-env
  AIRFLOW__CORE__EXECUTOR: LocalExecutor
  AIRFLOW__CORE__LOAD_EXAMPLES: "False"
  AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION: "True"
  AIRFLOW__WEBSERVER__EXPOSE_CONFIG: "True"
  AIRFLOW__DATABASE__SQL_ALCHEMY_CONN: postgresql+psycopg2://${AIRFLOW_METADATA_DB_USER}:${AIRFLOW_METADATA_DB_PASSWORD}@airflow-metadata-db:5432/${AIRFLOW_METADATA_DB_NAME}
  AIRFLOW__CORE__FERNET_KEY: ${AIRFLOW_FERNET_KEY}
  AIRFLOW__WEBSERVER__SECRET_KEY: ${AIRFLOW_WEBSERVER_SECRET_KEY}
  AIRFLOW_ADMIN_USERNAME: ${AIRFLOW_ADMIN_USERNAME}
  AIRFLOW_ADMIN_PASSWORD: ${AIRFLOW_ADMIN_PASSWORD}
  AIRFLOW_ADMIN_EMAIL: ${AIRFLOW_ADMIN_EMAIL}
  AIRFLOW_UID: ${AIRFLOW_UID:-50000}

services:
  airflow-metadata-db:
    image: postgres:16
    environment:
      POSTGRES_USER: ${AIRFLOW_METADATA_DB_USER}
      POSTGRES_PASSWORD: ${AIRFLOW_METADATA_DB_PASSWORD}
      POSTGRES_DB: ${AIRFLOW_METADATA_DB_NAME}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${AIRFLOW_METADATA_DB_USER} -d ${AIRFLOW_METADATA_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - platform
    ports:
      - "${AIRFLOW_METADATA_DB_PORT:-5432}:5432"
    volumes:
      - airflow-metadata-db-data:/var/lib/postgresql/data
      - ./postgres/catalog-init:/docker-entrypoint-initdb.d:ro

  source-postgres-db:
    image: postgres:16
    environment:
      POSTGRES_USER: ${SOURCE_POSTGRES_USER}
      POSTGRES_PASSWORD: ${SOURCE_POSTGRES_PASSWORD}
      POSTGRES_DB: ${SOURCE_POSTGRES_DB}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${SOURCE_POSTGRES_USER} -d ${SOURCE_POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - platform
    ports:
      - "${SOURCE_POSTGRES_EXPOSE_PORT:-5433}:5432"
    volumes:
      - source-postgres-db-data:/var/lib/postgresql/data
      - ./postgres/source-init:/docker-entrypoint-initdb.d:ro

  lakehouse-object-store:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
      MINIO_REGION_NAME: ${MINIO_REGION}
    networks:
      - platform
    ports:
      - "${MINIO_API_PORT:-9000}:9000"
      - "${MINIO_CONSOLE_PORT:-9001}:9001"
    volumes:
      - lakehouse-object-store-data:/data

  lakehouse-bucket-init:
    image: minio/mc:latest
    depends_on:
      lakehouse-object-store:
        condition: service_started
    entrypoint: ["/bin/sh", "/scripts/create-bucket.sh"]
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
      MINIO_BUCKET: ${MINIO_BUCKET}
      MINIO_ENDPOINT: ${MINIO_ENDPOINT}
    networks:
      - platform
    restart: "no"
    volumes:
      - ./minio/init:/scripts:ro

  airflow-init:
    build: *airflow-build
    image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/airflow:dev
    depends_on:
      airflow-metadata-db:
        condition: service_healthy
    environment: *airflow-env
    entrypoint: ["/bin/bash", "/opt/platform/airflow/init-airflow.sh"]
    networks:
      - platform
    restart: "no"
    user: "${AIRFLOW_UID:-50000}:0"
    volumes:
      - airflow-logs:/opt/airflow/logs
      - ./airflow/dags:/opt/airflow/dags
      - ./postgres:/opt/platform/postgres:ro

  airflow-webserver:
    build: *airflow-build
    image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/airflow:dev
    depends_on:
      airflow-metadata-db:
        condition: service_healthy
      source-postgres-db:
        condition: service_healthy
      airflow-init:
        condition: service_completed_successfully
      lakehouse-bucket-init:
        condition: service_completed_successfully
    environment: *airflow-env
    command: ["airflow", "webserver"]
    healthcheck:
      test: ["CMD-SHELL", 'python -c "import urllib.request; urllib.request.urlopen(\\"http://localhost:8080/health\\")"']
      interval: 15s
      timeout: 5s
      retries: 10
    networks:
      - platform
    ports:
      - "${AIRFLOW_PORT:-8088}:8080"
    user: "${AIRFLOW_UID:-50000}:0"
    volumes:
      - airflow-logs:/opt/airflow/logs
      - ./airflow/dags:/opt/airflow/dags
      - ./postgres:/opt/platform/postgres:ro

  airflow-scheduler:
    build: *airflow-build
    image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/airflow:dev
    depends_on:
      airflow-metadata-db:
        condition: service_healthy
      source-postgres-db:
        condition: service_healthy
      airflow-init:
        condition: service_completed_successfully
      lakehouse-bucket-init:
        condition: service_completed_successfully
    environment: *airflow-env
    command: ["airflow", "scheduler"]
    networks:
      - platform
    user: "${AIRFLOW_UID:-50000}:0"
    volumes:
      - airflow-logs:/opt/airflow/logs
      - ./airflow/dags:/opt/airflow/dags
      - ./postgres:/opt/platform/postgres:ro

  dlt-extractor:
    build:
      context: .
      dockerfile: dlt/Dockerfile
    image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/dlt-extractor:dev
    command: ["sleep", "infinity"]
    depends_on:
      airflow-metadata-db:
        condition: service_healthy
      source-postgres-db:
        condition: service_healthy
      lakehouse-bucket-init:
        condition: service_completed_successfully
    environment: *common-env
    networks:
      - platform
    profiles: ["tooling"]
    volumes:
      - ./dlt:/opt/platform/dlt

  dbt-executor:
    build:
      context: .
      dockerfile: dbt/Dockerfile
    image: ${RUNTIME_IMAGE_PREFIX:-${COMPOSE_PROJECT_NAME:-proj-sdp-local}}/dbt-executor:dev
    command: ["sleep", "infinity"]
    environment: *common-env
    networks:
      - platform
    profiles: ["tooling"]
    volumes:
      - ./dbt:/opt/platform/dbt
      - ./ci/snowflake:/opt/platform/ci/snowflake

networks:
  platform:
    name: ${PLATFORM_DOCKER_NETWORK:-local-platform-net}

volumes:
  airflow-metadata-db-data:
  source-postgres-db-data:
  lakehouse-object-store-data:
airflow-logs:
