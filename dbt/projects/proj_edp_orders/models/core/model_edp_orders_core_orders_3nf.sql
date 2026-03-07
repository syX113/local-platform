{{ config(alias='T_ORDERS_3NF') }}

select
  order_id,
  customer_id,
  order_status,
  item_count,
  order_total,
  order_value_band,
  order_created_at,
  load_batch
from {{ ref('model_edp_orders_inbound_orders_order_grain') }}
