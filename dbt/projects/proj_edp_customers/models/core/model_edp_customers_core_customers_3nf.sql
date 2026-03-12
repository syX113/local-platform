{{ config(alias='T_CUSTOMERS_3NF') }}

select
  customer_id,
  customer_name,
  region,
  segment,
  order_count,
  total_order_value,
  first_order_at,
  latest_order_at,
  customer_created_at,
  load_batch,
  customer_value_band
from {{ ref('model_edp_customers_inbound_customers_entity_grain') }}
