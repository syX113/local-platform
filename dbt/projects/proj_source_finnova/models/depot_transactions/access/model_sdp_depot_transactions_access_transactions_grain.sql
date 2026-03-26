{{ config(alias='T_DEPOT_TRANSACTIONS_GRAIN') }}

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
from {{ ref('model_sdp_depot_transactions_core_transactions_clean') }}
