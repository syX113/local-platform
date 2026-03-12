{{ config(alias='T_REGIONS_3NF') }}

select
  region,
  customer_count,
  total_order_count,
  total_order_value,
  avg_customer_value,
  latest_cleaned_at
from {{ ref('model_edp_customers_inbound_customers_region_grain') }}
