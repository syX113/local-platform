{{ config(alias='T_CUSTOMER_SEGMENT_SUMMARY') }}

select
  segment,
  count(*) as customer_count,
  sum(order_count) as total_order_count,
  sum(total_order_value) as total_order_value,
  avg(total_order_value) as avg_customer_value,
  max(cleaned_at) as latest_cleaned_at
from {{ ref('model_sdp_customers_core_customers_clean') }}
group by 1
