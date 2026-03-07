{{ config(alias='FCT_ORDER_REVENUE_STAR') }}

with orders as (
    select *
    from {{ ref('edp_in_orders') }}
),
items as (
    select
      order_id,
      sum(line_total) as item_revenue,
      count(*) as item_rows
    from {{ ref('edp_in_order_items') }}
    group by 1
),
dim_customers as (
    select customer_sk, customer_id
    from {{ ref('edp_core_dim_customers') }}
),
dim_order_status as (
    select status_sk, order_status
    from {{ ref('edp_core_dim_order_status') }}
)
select
  orders.order_id,
  dim_customers.customer_sk,
  dim_order_status.status_sk,
  orders.customer_id,
  orders.order_status,
  orders.item_count,
  orders.order_total,
  coalesce(items.item_revenue, 0) as item_revenue,
  coalesce(items.item_rows, 0) as item_rows,
  orders.order_value_band,
  orders.order_created_at,
  orders.load_batch,
  current_timestamp() as modeled_at
from orders
left join items using (order_id)
left join dim_customers
  on orders.customer_id = dim_customers.customer_id
left join dim_order_status
  on orders.order_status = dim_order_status.order_status
