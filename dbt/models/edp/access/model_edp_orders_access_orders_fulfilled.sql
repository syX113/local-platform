{{ config(alias='T_ORDERS_FULFILLED') }}

select
  order_id,
  customer_id,
  order_status,
  order_total,
  item_revenue,
  order_created_at
from {{ ref('model_edp_orders_core_fct_order_revenue_star') }}
where order_status in ('PAID', 'SHIPPED')
