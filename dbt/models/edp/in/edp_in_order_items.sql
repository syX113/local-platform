{{ config(alias='ORDER_ITEMS') }}

select
  order_id,
  item_id,
  sku,
  quantity,
  unit_price,
  line_total,
  line_number,
  loaded_at,
  published_at as sdp_published_at
from {{ ref('sdp_acc_order_items') }}
