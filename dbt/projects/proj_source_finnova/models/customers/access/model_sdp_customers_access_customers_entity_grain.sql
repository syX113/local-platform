{{ config(alias='T_CUSTOMERS_ENTITY_GRAIN') }}

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
  customer_value_band,
  cleaned_at
from {{ ref('model_sdp_customers_core_customers_clean') }}
