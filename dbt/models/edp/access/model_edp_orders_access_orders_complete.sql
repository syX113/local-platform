{{ config(alias='T_ORDERS_COMPLETE') }}

select
  order_id,
  customer_id,
  customer_sk,
  status_sk,
  order_status,
  item_count,
  order_total,
  item_revenue,
  item_rows,
  order_value_band,
  order_created_at,
  load_batch,
  modeled_at
from {{ ref('model_edp_orders_core_fct_order_revenue_star') }}
