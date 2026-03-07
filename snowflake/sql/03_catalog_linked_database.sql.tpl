use role "${SNOWFLAKE_ROLE}";

create or replace database "${SNOWFLAKE_SDP_DATABASE}"
  linked_catalog = (
    catalog = '${SNOWFLAKE_CATALOG_INTEGRATION}'
  );

select system$get_catalog_linked_database_config('${SNOWFLAKE_SDP_DATABASE}');
select system$catalog_link_status('${SNOWFLAKE_SDP_DATABASE}');
