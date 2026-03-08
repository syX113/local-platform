{{ config(alias='DIM_CUSTOMERS') }}

select
  customer_id,
  first_order_at,
  latest_order_at,
  order_count,
  total_order_value,
  md5(customer_id) as customer_sk
from {{ ref('model_edp_orders_core_customers_3nf') }}
