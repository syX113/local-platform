{{ config(alias='T_CUSTOMER_ORDER_SUMMARY') }}

select
  customer_id,
  count(*) as order_count,
  sum(order_total) as total_order_value,
  min(order_created_at) as first_order_at,
  max(order_created_at) as latest_order_at,
  max(load_batch) as latest_load_batch
from {{ ref('model_sdp_orders_core_orders_clean') }}
group by 1
