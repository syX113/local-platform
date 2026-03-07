{{ config(alias='DIM_ORDER_STATUS') }}

select
  md5(order_status) as status_sk,
  order_status,
  count(*) as order_count
from {{ ref('edp_in_orders') }}
group by 1, 2
