{{ config(alias='T_ORDERS_CUSTOMER_GRAIN') }}

select
  customer_id,
  order_count,
  total_order_value,
  first_order_at,
  latest_order_at,
  latest_load_batch
from {{ ref('model_sdp_orders_core_customer_order_summary') }}
