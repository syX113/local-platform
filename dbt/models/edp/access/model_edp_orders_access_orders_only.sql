{{ config(alias='T_ORDERS_ONLY') }}

select
  order_id,
  customer_id,
  order_status,
  order_total,
  order_created_at
from {{ ref('model_edp_orders_core_fct_order_revenue_star') }}
