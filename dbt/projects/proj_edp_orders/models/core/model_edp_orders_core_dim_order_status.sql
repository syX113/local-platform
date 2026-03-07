{{ config(alias='DIM_ORDER_STATUS') }}

select
  md5(order_status) as status_sk,
  order_status,
  count(*) as order_count
from {{ ref('model_edp_orders_core_orders_3nf') }}
group by 1, 2
