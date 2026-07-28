{{ config(alias='T_DEPOT_TRANSACTIONS_CLEAN') }}

select
  cast(transaction_id as varchar) as transaction_id,
  cast(customer_id as varchar) as customer_id,
  cast(amount as number(12, 2)) as amount,
  cast(load_batch as varchar) as load_batch,
  upper(trim(cast(depot_code as varchar))) as depot_code,
  upper(trim(cast(transaction_type as varchar))) as transaction_type,
  to_timestamp_ntz(transaction_at) as transaction_at,
  to_timestamp_ntz(loaded_at) as loaded_at,
  case
    when cast(amount as number(12, 2)) >= 70 then 'HIGH'
    when cast(amount as number(12, 2)) >= 40 then 'MEDIUM'
    else 'LOW'
  end as amount_band,
  current_timestamp() as cleaned_at
from {{ source('source_sdp_depot_transactions_inbound', 'EXT_DEPOT_TRANSACTIONS_RAW') }}
