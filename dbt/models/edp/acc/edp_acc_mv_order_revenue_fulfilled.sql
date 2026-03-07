{{ config(alias='MV_ORDER_REVENUE_FULFILLED') }}

select
  order_id,
  customer_id,
  customer_sk,
  status_sk,
  order_status,
  order_total,
  item_revenue,
  item_rows,
  order_value_band,
  order_created_at
from {{ ref('edp_core_fct_order_revenue_star') }}
where order_status in ('PAID', 'SHIPPED')
