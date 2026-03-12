{{ config(alias='T_CUSTOMERS_COMPLETE') }}

select
  customer_id,
  customer_name,
  region,
  segment,
  region_sk,
  segment_sk,
  order_count,
  total_order_value,
  first_order_at,
  latest_order_at,
  customer_created_at,
  load_batch,
  customer_value_band,
  modeled_at
from {{ ref('model_edp_customers_core_fct_customer_value_star') }}
