use role "${SNOWFLAKE_ROLE}";
use warehouse "${SNOWFLAKE_WAREHOUSE}";

create or replace transient schema "${SNOWFLAKE_EDP_DATABASE}"."${SNOWFLAKE_CLONE_SCHEMA}"
  clone "${SNOWFLAKE_EDP_DATABASE}"."${SNOWFLAKE_EDP_CORE_SCHEMA}";

show tables in schema "${SNOWFLAKE_EDP_DATABASE}"."${SNOWFLAKE_CLONE_SCHEMA}";

drop schema if exists "${SNOWFLAKE_EDP_DATABASE}"."${SNOWFLAKE_CLONE_SCHEMA}";
