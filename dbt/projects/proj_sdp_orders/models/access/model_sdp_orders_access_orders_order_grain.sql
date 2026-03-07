{{ config(alias='T_ORDERS_ORDER_GRAIN') }}

select
  order_id,
  customer_id,
  order_status,
  item_count,
  order_total,
  order_value_band,
  order_created_at,
  load_batch,
  cleaned_at
from {{ ref('model_sdp_orders_core_orders_clean') }}
