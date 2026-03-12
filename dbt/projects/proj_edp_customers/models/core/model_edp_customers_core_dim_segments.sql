{{ config(alias='DIM_SEGMENTS') }}

select
  segment,
  customer_count,
  total_order_count,
  total_order_value,
  avg_customer_value,
  md5(segment) as segment_sk
from {{ ref('model_edp_customers_core_segments_3nf') }}
