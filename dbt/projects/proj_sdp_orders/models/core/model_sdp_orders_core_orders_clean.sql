{{ config(alias='T_ORDERS_CLEAN') }}

select
  cast(order_id as varchar) as order_id,
  cast(customer_id as varchar) as customer_id,
  cast(item_count as number(38, 0)) as item_count,
  cast(order_total as number(38, 2)) as order_total,
  cast(load_batch as varchar) as load_batch,
  upper(trim(cast(status as varchar))) as order_status,
  to_timestamp_ntz(order_created_at) as order_created_at,
  case
    when cast(order_total as number(38, 2)) >= 150 then 'HIGH'
    when cast(order_total as number(38, 2)) >= 75 then 'MEDIUM'
    else 'LOW'
  end as order_value_band,
  current_timestamp() as cleaned_at
from {{ source('source_sdp_orders_inbound', 'EXT_ORDERS_RAW') }}
