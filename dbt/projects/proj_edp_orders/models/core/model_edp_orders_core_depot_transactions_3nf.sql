{{ config(
    database=env_var('SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE'),
    schema=env_var('SNOWFLAKE_EDP_CORE_SCHEMA', 'CORE'),
    materialized='table',
    alias='T_DEPOT_TRANSACTIONS_3NF'
) }}

select
  transaction_id,
  customer_id,
  depot_code,
  transaction_type,
  amount,
  amount_band,
  transaction_at,
  load_batch
from {{ ref('model_edp_orders_inbound_depot_transactions_grain') }}
