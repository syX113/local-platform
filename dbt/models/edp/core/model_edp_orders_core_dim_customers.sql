{{ config(alias='DIM_CUSTOMERS') }}

select
  md5(customer_id) as customer_sk,
  customer_id,
  first_order_at,
  latest_order_at,
  order_count,
  total_order_value
from {{ ref('model_edp_orders_core_customers_3nf') }}
