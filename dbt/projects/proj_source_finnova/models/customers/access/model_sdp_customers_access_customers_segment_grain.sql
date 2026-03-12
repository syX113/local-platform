{{ config(alias='T_CUSTOMERS_SEGMENT_GRAIN') }}

select
  segment,
  customer_count,
  total_order_count,
  total_order_value,
  avg_customer_value,
  latest_cleaned_at
from {{ ref('model_sdp_customers_core_customer_segment_summary') }}
