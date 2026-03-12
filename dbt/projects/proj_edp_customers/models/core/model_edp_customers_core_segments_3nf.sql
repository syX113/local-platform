{{ config(alias='T_SEGMENTS_3NF') }}

select
  segment,
  customer_count,
  total_order_count,
  total_order_value,
  avg_customer_value,
  latest_cleaned_at
from {{ ref('model_edp_customers_inbound_customers_segment_grain') }}
