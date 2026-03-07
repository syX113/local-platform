use role ${SNOWFLAKE_ROLE};

create warehouse if not exists ${SNOWFLAKE_WAREHOUSE}
  warehouse_size = 'XSMALL'
  auto_suspend = 60
  auto_resume = true;

create database if not exists ${SNOWFLAKE_TARGET_DATABASE};
create schema if not exists ${SNOWFLAKE_TARGET_DATABASE}.${SNOWFLAKE_TARGET_SCHEMA};

