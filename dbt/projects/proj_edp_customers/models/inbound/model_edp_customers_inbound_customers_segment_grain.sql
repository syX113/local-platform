{{ config(alias='V_IN_CUSTOMERS_SEGMENT_GRAIN') }}

select
  segment,
  customer_count,
  total_order_count,
  total_order_value,
  avg_customer_value,
  latest_cleaned_at
from {{ source('source_edp_customers_sdp_access', 'T_CUSTOMERS_SEGMENT_GRAIN') }}
