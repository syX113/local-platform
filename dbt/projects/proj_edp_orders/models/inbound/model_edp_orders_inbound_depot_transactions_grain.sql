{{ config(
    database=env_var('SNOWFLAKE_EDP_DEPOT_TRANSACTIONS_DATABASE'),
    schema=env_var('SNOWFLAKE_EDP_IN_SCHEMA', 'INBOUND'),
    materialized='view',
    alias='V_IN_DEPOT_TRANSACTIONS_GRAIN'
) }}

select
  transaction_id,
  customer_id,
  depot_code,
  transaction_type,
  amount,
  amount_band,
  transaction_at,
  loaded_at,
  load_batch,
  cleaned_at
from {{ ref('proj_source_finnova', 'model_sdp_depot_transactions_access_transactions_grain') }}
