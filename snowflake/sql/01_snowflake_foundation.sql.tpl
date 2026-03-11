use role "${SNOWFLAKE_ROLE}";

create warehouse if not exists "${SNOWFLAKE_WAREHOUSE}"
  warehouse_size = 'XSMALL'
  auto_suspend = 60
  auto_resume = true;

create database if not exists "${SNOWFLAKE_CONTROL_DATABASE}";
create schema if not exists "${SNOWFLAKE_CONTROL_DATABASE}"."${SNOWFLAKE_CONTROL_SCHEMA}";
create stage if not exists "${SNOWFLAKE_CONTROL_DATABASE}"."${SNOWFLAKE_CONTROL_SCHEMA}"."${SNOWFLAKE_DBT_STAGE}";
