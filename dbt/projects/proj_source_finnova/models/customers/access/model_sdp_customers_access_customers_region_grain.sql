{{ config(alias='T_CUSTOMERS_REGION_GRAIN') }}

select
  region,
  customer_count,
  total_order_count,
  total_order_value,
  avg_customer_value,
  latest_cleaned_at
from {{ ref('model_sdp_customers_core_customer_region_summary') }}
