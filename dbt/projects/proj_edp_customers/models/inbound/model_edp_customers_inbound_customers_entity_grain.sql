{{ config(alias='V_IN_CUSTOMERS_ENTITY_GRAIN') }}

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
from {{ ref('proj_source_finnova', 'model_sdp_customers_access_customers_entity_grain') }}
