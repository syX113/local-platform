{{ config(alias='ORDERS') }}

select
  order_id,
  customer_id,
  order_status,
  item_count,
  order_total,
  order_value_band,
  order_created_at,
  load_batch,
  current_timestamp() as published_at
from {{ ref('sdp_core_orders') }}
