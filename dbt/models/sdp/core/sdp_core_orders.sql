{{ config(alias='ORDERS') }}

select
  cast(order_id as varchar) as order_id,
  cast(customer_id as varchar) as customer_id,
  upper(trim(cast(status as varchar))) as order_status,
  cast(item_count as number(38, 0)) as item_count,
  cast(order_total as number(38, 2)) as order_total,
  case
    when cast(order_total as number(38, 2)) >= 150 then 'HIGH'
    when cast(order_total as number(38, 2)) >= 75 then 'MEDIUM'
    else 'LOW'
  end as order_value_band,
  to_timestamp_ntz(order_created_at) as order_created_at,
  cast(load_batch as varchar) as load_batch
from {{ source('sdp_in', 'ext_raw_orders') }}
