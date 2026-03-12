{{ config(alias='T_CUSTOMERS_HIGH_VALUE') }}

select
  customer_id,
  customer_name,
  region,
  segment,
  order_count,
  total_order_value,
  customer_value_band,
  latest_order_at
from {{ ref('model_edp_customers_core_fct_customer_value_star') }}
where customer_value_band = 'HIGH_VALUE'
