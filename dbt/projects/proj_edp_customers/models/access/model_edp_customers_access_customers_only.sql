{{ config(alias='T_CUSTOMERS_ONLY') }}

select
  customer_id,
  customer_name,
  region,
  segment,
  order_count,
  total_order_value,
  customer_value_band
from {{ ref('model_edp_customers_core_fct_customer_value_star') }}
