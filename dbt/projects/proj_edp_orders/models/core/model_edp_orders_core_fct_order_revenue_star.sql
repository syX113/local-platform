{{ config(alias='FCT_ORDER_REVENUE_STAR') }}

with orders as (
  select *
  from {{ ref('model_edp_orders_core_orders_3nf') }}
),
items as (
  select
    order_id,
    count(*) as item_rows,
    sum(line_total) as item_revenue
  from {{ ref('model_edp_orders_core_order_lines_3nf') }}
  group by 1
),
dim_customers as (
  select
    customer_id,
    customer_sk
  from {{ ref('model_edp_orders_core_dim_customers') }}
),
dim_order_status as (
  select
    order_status,
    status_sk
  from {{ ref('model_edp_orders_core_dim_order_status') }}
)
select
  orders.order_id,
  orders.customer_id,
  orders.order_status,
  orders.item_count,
  orders.order_total,
  orders.order_value_band,
  orders.order_created_at,
  orders.load_batch,
  dim_customers.customer_sk,
  dim_order_status.status_sk,
  coalesce(items.item_rows, 0) as item_rows,
  coalesce(items.item_revenue, 0) as item_revenue,
  current_timestamp() as modeled_at
from orders
left join items
  on orders.order_id = items.order_id
left join dim_customers
  on orders.customer_id = dim_customers.customer_id
left join dim_order_status
  on orders.order_status = dim_order_status.order_status
