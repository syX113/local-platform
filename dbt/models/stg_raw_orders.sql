select
  cast(order_id as varchar) as order_id,
  cast(customer_id as varchar) as customer_id,
  cast(status as varchar) as status,
  cast(item_count as number(38, 0)) as item_count,
  cast(order_total as number(38, 2)) as order_total,
  to_timestamp_ntz(order_created_at) as order_created_at,
  cast(load_batch as varchar) as load_batch
from {{ source('lakehouse', 'raw_orders') }}

