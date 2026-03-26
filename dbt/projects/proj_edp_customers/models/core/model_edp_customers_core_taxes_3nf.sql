{{ config(
    database=env_var('SNOWFLAKE_EDP_TAXES_DATABASE'),
    schema=env_var('SNOWFLAKE_EDP_CORE_SCHEMA', 'CORE'),
    materialized='table',
    alias='T_TAXES_3NF'
) }}

select
  tax_code,
  tax_name,
  jurisdiction,
  rate,
  rate_band,
  effective_at,
  load_batch
from {{ ref('model_edp_customers_inbound_taxes_grain') }}
