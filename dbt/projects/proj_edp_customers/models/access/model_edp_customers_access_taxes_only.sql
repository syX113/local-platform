{{ config(
    database=env_var('SNOWFLAKE_EDP_TAXES_DATABASE'),
    schema=env_var('SNOWFLAKE_EDP_ACC_SCHEMA', 'ACCESS'),
    materialized='table',
    alias='T_TAXES_ONLY'
) }}

select
  tax_code,
  tax_name,
  jurisdiction,
  rate,
  rate_band,
  effective_at
from {{ ref('model_edp_customers_core_taxes_3nf') }}
