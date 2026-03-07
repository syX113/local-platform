use role ${SNOWFLAKE_ROLE};

create database if not exists ${SNOWFLAKE_RAW_DATABASE}
  linked_catalog = (
    catalog = '${SNOWFLAKE_CATALOG_INTEGRATION}'
  );

select system$get_catalog_linked_database_config('${SNOWFLAKE_RAW_DATABASE}');
select system$catalog_link_status('${SNOWFLAKE_RAW_DATABASE}');

