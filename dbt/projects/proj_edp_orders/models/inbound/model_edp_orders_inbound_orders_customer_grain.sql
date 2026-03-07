{{ config(alias='V_IN_ORDERS_CUSTOMER_GRAIN') }}

select
  customer_id,
  order_count,
  total_order_value,
  first_order_at,
  latest_order_at,
  latest_load_batch
from {{ source('source_edp_orders_sdp_access', 'T_ORDERS_CUSTOMER_GRAIN') }}
