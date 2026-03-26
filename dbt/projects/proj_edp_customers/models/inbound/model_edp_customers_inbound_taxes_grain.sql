{{ config(
    database=env_var('SNOWFLAKE_EDP_TAXES_DATABASE'),
    schema=env_var('SNOWFLAKE_EDP_IN_SCHEMA', 'INBOUND'),
    materialized='view',
    alias='V_IN_TAXES_GRAIN'
) }}

select
  tax_code,
  tax_name,
  jurisdiction,
  rate,
  rate_band,
  effective_at,
  loaded_at,
  load_batch,
  cleaned_at
from {{ ref('proj_source_finnova', 'model_sdp_taxes_access_taxes_grain') }}
