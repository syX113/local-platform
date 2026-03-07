{{ config(alias='ORDER_ITEMS') }}

select
  order_id,
  item_id,
  sku,
  quantity,
  unit_price,
  line_total,
  row_number() over (partition by order_id order by item_id) as line_number,
  loaded_at,
  current_timestamp() as published_at
from {{ ref('sdp_core_order_items') }}
