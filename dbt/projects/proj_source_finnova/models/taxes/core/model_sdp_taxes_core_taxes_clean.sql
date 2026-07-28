{{ config(alias='T_TAXES_CLEAN') }}

select
  cast(tax_code as varchar) as tax_code,
  cast(tax_name as varchar) as tax_name,
  cast(rate as number(12, 4)) as rate,
  cast(load_batch as varchar) as load_batch,
  upper(trim(cast(jurisdiction as varchar))) as jurisdiction,
  to_timestamp_ntz(effective_at) as effective_at,
  to_timestamp_ntz(loaded_at) as loaded_at,
  case
    when cast(rate as number(12, 4)) >= 0.2 then 'HIGH'
    when cast(rate as number(12, 4)) >= 0.1 then 'STANDARD'
    else 'REDUCED'
  end as rate_band,
  current_timestamp() as cleaned_at
from {{ source('source_sdp_taxes_inbound', 'EXT_TAXES_RAW') }}
