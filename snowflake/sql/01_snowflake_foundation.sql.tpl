use role "${SNOWFLAKE_ROLE}";

create warehouse if not exists "${SNOWFLAKE_WAREHOUSE}"
  warehouse_size = 'XSMALL'
  auto_suspend = 60
  auto_resume = true;

create database if not exists "${SNOWFLAKE_SDP_DATABASE}";
create schema if not exists "${SNOWFLAKE_SDP_DATABASE}"."${SNOWFLAKE_SDP_IN_SCHEMA}";
create schema if not exists "${SNOWFLAKE_SDP_DATABASE}"."${SNOWFLAKE_SDP_CORE_SCHEMA}";
create schema if not exists "${SNOWFLAKE_SDP_DATABASE}"."${SNOWFLAKE_SDP_ACC_SCHEMA}";

create database if not exists "${SNOWFLAKE_EDP_DATABASE}";
create schema if not exists "${SNOWFLAKE_EDP_DATABASE}"."${SNOWFLAKE_EDP_IN_SCHEMA}";
create schema if not exists "${SNOWFLAKE_EDP_DATABASE}"."${SNOWFLAKE_EDP_CORE_SCHEMA}";
create schema if not exists "${SNOWFLAKE_EDP_DATABASE}"."${SNOWFLAKE_EDP_ACC_SCHEMA}";
