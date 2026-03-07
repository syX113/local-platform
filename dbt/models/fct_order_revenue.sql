{{ config(materialized='table') }}

with orders as (
    select *
    from {{ ref('stg_raw_orders') }}
),
items as (
    select
        cast(order_id as varchar) as order_id,
        sum(cast(line_total as number(38, 2))) as item_revenue,
        count(*) as item_rows
    from {{ source('lakehouse', 'raw_order_items') }}
    group by 1
)
select
    orders.order_id,
    orders.customer_id,
    orders.status,
    orders.order_created_at,
    orders.order_total,
    coalesce(items.item_revenue, 0) as item_revenue,
    coalesce(items.item_rows, 0) as item_rows,
    current_timestamp() as modeled_at
from orders
left join items using (order_id)

