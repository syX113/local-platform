use role ${SNOWFLAKE_ROLE};

create or replace catalog integration ${SNOWFLAKE_CATALOG_INTEGRATION}
  catalog_source = polaris
  table_format = iceberg
  catalog_namespace = '${ICEBERG_NAMESPACE}'
  rest_config = (
    catalog_uri = '${OPEN_CATALOG_URI}'
    catalog_name = '${OPEN_CATALOG_NAME}'
  )
  rest_authentication = (
    type = oauth
    oauth_client_id = '${OPEN_CATALOG_CLIENT_ID}'
    oauth_client_secret = '${OPEN_CATALOG_CLIENT_SECRET}'
    oauth_allowed_scopes = ('${OPEN_CATALOG_SCOPE}')
  )
  enabled = true;

select system$verify_catalog_integration('${SNOWFLAKE_CATALOG_INTEGRATION}');

