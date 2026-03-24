{{ config(alias='V_IN_CUSTOMERS_REGION_GRAIN') }}

select
  region,
  customer_count,
  total_order_count,
  total_order_value,
  avg_customer_value,
  latest_cleaned_at
from {{ ref('proj_source_finnova', 'model_sdp_customers_access_customers_region_grain') }}
