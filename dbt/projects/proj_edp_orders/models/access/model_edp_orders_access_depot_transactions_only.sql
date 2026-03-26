{{ config(
    database=env_var('SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE'),
    schema=env_var('SNOWFLAKE_EDP_ACC_SCHEMA', 'ACCESS'),
    materialized='table',
    alias='T_DEPOT_TRANSACTIONS_ONLY'
) }}

select
  transaction_id,
  customer_id,
  depot_code,
  transaction_type,
  amount,
  amount_band,
  transaction_at
from {{ ref('model_edp_orders_core_depot_transactions_3nf') }}
