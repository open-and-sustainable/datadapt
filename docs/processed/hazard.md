---
title: Processed hazard data
layout: default
---

# Processed hazard data

The processed table `hazard_country_year` (in `DatAdapt-database/processed/DatAdapt.duckdb`) holds the national annual hazard values, one row per country, year and event type. It is made by `transform_data("hazard")` (in `transform_data.sh`) from the [raw table `hazard`](../raw/hazard.html), through `src/DataTransform/hazard_country_year.prql`.

The raw table is already on the [shared country map](../index.html#countries) and in the shape used for analysis, so the processed table has the same rows and columns:

| Column | Content |
|---|---|
| `country_code` | Country, on the shared country map |
| `year` | Calendar year, 1980–2025 |
| `event_type` | One of the eight event types (see the [raw data](../raw/hazard.html#table-hazard)) |
| `extreme_area_days` | Share of the country in a joint extreme, summed over the days of the year, in days |
| `peak_extent` | Largest share of the country in a joint extreme on a single day, from 0 to 1 |
| `peak_return_period_years` | Return period of the most extreme cell-day of the year, in years |

How each value is computed is set out on the [raw hazard page](../raw/hazard.html#hazard-transformation-method).
