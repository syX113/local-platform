{{ config(alias='DIM_REGIONS') }}

select
  region,
  customer_count,
  total_order_count,
  total_order_value,
  avg_customer_value,
  md5(region) as region_sk
from {{ ref('model_edp_customers_core_regions_3nf') }}
