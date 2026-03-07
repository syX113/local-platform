{{ config(alias='DIM_CUSTOMERS') }}

select
  md5(customer_id) as customer_sk,
  customer_id,
  min(order_created_at) as first_order_at,
  max(order_created_at) as latest_order_at,
  count(*) as order_count
from {{ ref('edp_in_orders') }}
group by 1, 2
