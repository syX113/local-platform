{{ config(alias='T_ORDER_LINES_3NF') }}

select
  order_id,
  item_id,
  sku,
  quantity,
  unit_price,
  line_total,
  line_number,
  loaded_at
from {{ ref('model_edp_orders_inbound_order_lines_order_grain') }}
