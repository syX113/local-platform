{{ config(alias='V_IN_CUSTOMERS_REGION_GRAIN') }}

select
  region,
  customer_count,
  total_order_count,
  total_order_value,
  avg_customer_value,
  latest_cleaned_at
from {{ source('source_edp_customers_sdp_access', 'T_CUSTOMERS_REGION_GRAIN') }}
