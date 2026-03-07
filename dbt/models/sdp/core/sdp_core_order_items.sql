{{ config(alias='ORDER_ITEMS') }}

select
  cast(order_id as varchar) as order_id,
  cast(item_id as varchar) as item_id,
  cast(sku as varchar) as sku,
  cast(quantity as number(38, 0)) as quantity,
  cast(unit_price as number(38, 2)) as unit_price,
  cast(line_total as number(38, 2)) as line_total,
  to_timestamp_ntz(loaded_at) as loaded_at
from {{ source('sdp_in', 'ext_raw_order_items') }}
