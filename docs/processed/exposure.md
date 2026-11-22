---
title: Processed exposure data
layout: default
---

# Processed exposure data

The processed table `exposure_country_year` (in `DatAdapt-database/processed/DatAdapt.duckdb`) holds the seven [World Bank indicators](../raw/exposure.html) as one row per country and year, on the [shared country map](../index.html#countries). It is made by `transform_data("exposure")` (in `transform_data.sh`) in two steps.

## Step 1: economies only, on the shared codes

The World Bank's aggregates are left out: its regions, income groups, lending groups and the world, as listed in `country_mappings/exposure_world_bank_aggregates.csv` (from the World Bank's own country list), together with the rows that have no country code. Kosovo's World Bank code `XKX` becomes `XKO`, the code used for damage and hazard (`locate_exposure` in `src/CountryMapping.jl`).

## Step 2: one column per indicator

The long raw table is turned into one row per country and year, with one column per indicator (`src/DataTransform/exposure_country_year.prql`). A value is empty where the World Bank has none.

| Column | Content |
|---|---|
| `country_code` | Country, on the shared country map |
| `year` | Year, 1980–2025 |
| `population_total` | Population, total (`SP.POP.TOTL`) |
| `surface_area_sq_km` | Surface area, km² (`AG.SRF.TOTL.K2`) |
| `population_density` | Population density, people per km² of land area (`EN.POP.DNST`) |
| `gdp_current_usd` | GDP, current US$ (`NY.GDP.MKTP.CD`) |
| `gdp_growth_annual_percent` | GDP growth, annual % (`NY.GDP.MKTP.KD.ZG`) |
| `gni_per_capita_atlas_usd` | GNI per capita, Atlas method, current US$ (`NY.GNP.PCAP.CD`) |
| `gni_per_capita_ppp_usd` | GNI per capita, PPP, current international $ (`NY.GNP.PCAP.PP.CD`) |
