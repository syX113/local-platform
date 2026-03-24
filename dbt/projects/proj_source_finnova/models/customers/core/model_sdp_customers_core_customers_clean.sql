{{ config(alias='T_CUSTOMERS_CLEAN') }}

select
  cast(customer_id as varchar) as customer_id,
  cast(customer_name as varchar) as customer_name,
  cast(order_count as number(38, 0)) as order_count,
  cast(total_order_value as number(38, 2)) as total_order_value,
  cast(load_batch as varchar) as load_batch,
  upper(trim(cast(region as varchar))) as region,
  upper(trim(cast(segment as varchar))) as segment,
  to_timestamp_ntz(first_order_at) as first_order_at,
  to_timestamp_ntz(latest_order_at) as latest_order_at,
  to_timestamp_ntz(customer_created_at) as customer_created_at,
  case
    when cast(total_order_value as number(38, 2)) >= 400 then 'HIGH_VALUE'
    when cast(total_order_value as number(38, 2)) >= 150 then 'MEDIUM_VALUE'
    else 'LOW_VALUE'
  end as customer_value_band,
  current_timestamp() as cleaned_at
from {{ source('source_sdp_customers_inbound', 'EXT_CUSTOMERS_RAW') }}
