{{ config(alias='T_CUSTOMERS_3NF') }}

select
  customer_id,
  order_count,
  total_order_value,
  first_order_at,
  latest_order_at,
  latest_load_batch
from {{ ref('model_edp_orders_inbound_orders_customer_grain') }}
