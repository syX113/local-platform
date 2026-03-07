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
from {{ source('source_edp_orders_sdp_access', 'T_ORDER_LINES_ORDER_GRAIN') }}
