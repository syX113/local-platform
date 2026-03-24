{{ config(alias='V_IN_ORDER_LINES_ORDER_GRAIN') }}

select
  order_id,
  item_id,
  sku,
  quantity,
  unit_price,
  line_total,
  line_number,
  loaded_at,
  cleaned_at
from {{ ref('proj_source_finnova', 'model_sdp_orders_access_order_lines_order_grain') }}
