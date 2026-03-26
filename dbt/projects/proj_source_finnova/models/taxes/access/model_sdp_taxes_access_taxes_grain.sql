{{ config(alias='T_TAXES_GRAIN') }}

select
  tax_code,
  tax_name,
  jurisdiction,
  rate,
  rate_band,
  effective_at,
  loaded_at,
  load_batch,
  cleaned_at
from {{ ref('model_sdp_taxes_core_taxes_clean') }}
