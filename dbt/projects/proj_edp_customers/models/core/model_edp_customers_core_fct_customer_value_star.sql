{{ config(alias='FCT_CUSTOMER_VALUE_STAR') }}

with customers as (
  select *
  from {{ ref('model_edp_customers_core_customers_3nf') }}
),
dim_regions as (
  select
    region,
    region_sk
  from {{ ref('model_edp_customers_core_dim_regions') }}
),
dim_segments as (
  select
    segment,
    segment_sk
  from {{ ref('model_edp_customers_core_dim_segments') }}
)
select
  customers.customer_id,
  customers.customer_name,
  customers.region,
  customers.segment,
  customers.order_count,
  customers.total_order_value,
  customers.first_order_at,
  customers.latest_order_at,
  customers.customer_created_at,
  customers.load_batch,
  customers.customer_value_band,
  dim_regions.region_sk,
  dim_segments.segment_sk,
  current_timestamp() as modeled_at
from customers
left join dim_regions
  on customers.region = dim_regions.region
left join dim_segments
  on customers.segment = dim_segments.segment
