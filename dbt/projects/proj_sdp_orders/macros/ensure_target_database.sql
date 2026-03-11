{% macro ensure_target_database_and_schemas(database_name, schemas) -%}
  {%- if execute -%}
    {% do run_query("create database if not exists " ~ adapter.quote(database_name)) %}
    {%- for schema_name in schemas -%}
      {% do run_query("create schema if not exists " ~ adapter.quote(database_name) ~ "." ~ adapter.quote(schema_name)) %}
    {%- endfor -%}
  {%- endif -%}
{%- endmacro %}
