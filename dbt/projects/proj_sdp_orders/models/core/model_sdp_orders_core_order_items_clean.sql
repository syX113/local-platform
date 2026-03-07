{{ config(alias='T_ORDER_ITEMS_CLEAN') }}

select
  cast(order_id as varchar) as order_id,
  cast(item_id as varchar) as item_id,
  cast(sku as varchar) as sku,
  cast(quantity as number(38, 0)) as quantity,
  cast(unit_price as number(38, 2)) as unit_price,
  cast(line_total as number(38, 2)) as line_total,
  row_number() over (partition by order_id order by item_id) as line_number,
  to_timestamp_ntz(loaded_at) as loaded_at,
  current_timestamp() as cleaned_at
from {{ source('source_sdp_orders_inbound', 'EXT_ORDER_ITEMS_RAW') }}
