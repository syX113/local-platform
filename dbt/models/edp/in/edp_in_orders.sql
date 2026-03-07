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
  published_at as sdp_published_at
from {{ ref('sdp_acc_orders') }}
