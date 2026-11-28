---
title: Processed exposure data
layout: default
---

# Processed exposure data

The processed table `exposure_country_year` (in `DatAdapt-database/processed/DatAdapt.duckdb`) holds the seven [World Bank indicators](../raw/exposure.html) and the [capital stock of the Penn World Table](../raw/exposure.html#table-capital_stock) as one row per country and year, on the [shared country map](../index.html#countries). It is made by `transform_data("exposure")` (in `transform_data.sh`) in three steps.

## Step 1: economies only, on the shared codes

The World Bank's aggregates are left out: its regions, income groups, lending groups and the world, as listed in `country_mappings/exposure_world_bank_aggregates.csv` (from the World Bank's own country list), together with the rows that have no country code. Kosovo's World Bank code `XKX` becomes `XKO`, the code used for damage and hazard (`locate_exposure` in `src/CountryMapping.jl`). The Penn World Table's codes are already the map's.

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
| `capital_stock_current_usd` | Capital stock, current US$, PWT's own measure (step 3) |
| `capital_stock_current_usd_wb_aligned` | Capital stock, current US$, converted as the World Bank's GDP is; empty where that is not possible (step 3) |
| `structures_current_usd` | Capital stock in residential and non-residential structures, current US$, PWT's own measure (step 3) |
| `structures_current_usd_wb_aligned` | Capital stock in residential and non-residential structures, current US$, converted as the World Bank's GDP is; empty where that is not possible (step 3) |

## Step 3: capital stock in current US$

The capital stock is added in current US dollars, like the GDP, as a measure of the assets exposed, in two versions (`capital_stock_country_year` in `src/DatAdapt.jl`):

- `capital_stock_current_usd` is PWT's own measure, its capital stock at current PPPs times its price level (`cn` × `pl_n`), in dollars rather than PWT's millions. It is converted with PWT's exchange rate, and is there for every country and year PWT has a capital stock.
- `capital_stock_current_usd_wb_aligned` is PWT's capital stock over its GDP, both in current US$ (`cn` × `pl_n` and `cgdpo` × `pl_gdpo`), times the World Bank's GDP in current US$ of the country and year. The exchange rate PWT converts with cancels out of the ratio, so the stock is converted to dollars as the World Bank's GDP is, and `capital_stock_current_usd_wb_aligned` / `gdp_current_usd` is PWT's own ratio of capital to GDP. The two versions are more than 10% apart in 1,704 of the 7,353 country-years that have both, mostly in the 1980s and 1990s, where official and market exchange rates diverged: Iraq's stock in 1992 is 79 times its World Bank GDP in PWT's own measure, against 4.4 times aligned.
- The alignment is not possible where the World Bank has no GDP, and `capital_stock_current_usd_wb_aligned` is empty there. This is the case for 328 country-years: Taiwan, Anguilla, Montserrat and the British Virgin Islands in every year, the Cayman Islands to 2005, the Turks and Caicos Islands to 2000, and the years before the World Bank's series start for some countries, mostly in the 1980s and early 1990s, such as Palestine, Mozambique, Poland, Lebanon and Romania.
- `structures_current_usd` and `structures_current_usd_wb_aligned` are the part of each in residential and non-residential structures, that is buildings and infrastructure: the total times the share of `Nc_Struc` in the current-cost net stocks of the four assets PWT distinguishes (structures, machinery and equipment, transport equipment and other assets), at national prices.

The capital stock joins the World Bank's indicators on the country and year. Taiwan, Anguilla and Montserrat, which the World Bank has no series for, have rows of their own for 1980–2023, with PWT's own measure of the capital stock only. The four columns are empty where PWT has no value: for every country in 2024 and 2025, before 1990 for the successors of the Soviet Union, Yugoslavia and Czechoslovakia, and in every year for 40 countries of the map, among them Afghanistan, Cuba, North Korea, Somalia, South Sudan, Guyana, Papua New Guinea, Puerto Rico and most Pacific islands. Nothing is filled in.

## Data limitations and assumptions

- **The capital stock is estimated, not observed.** PWT builds it from each country's past investment in each asset, less depreciation.
- **It ends in 2023.** PWT 11.0 has no later year, so 2024 and 2025 are empty.
- **It moves with exchange rates.** Like the GDP in current US$, both versions are converted at each year's exchange rate, PWT's or the World Bank's, so they change with the exchange rate as well as with the assets.
- **Two versions, two exchange rates.** `capital_stock_current_usd` is converted with PWT's exchange rate, `capital_stock_current_usd_wb_aligned` as the World Bank's GDP is. Only the aligned version is on the same basis as `gdp_current_usd`, and it is empty for the 328 country-years without a World Bank GDP (step 3).
- **The ratio to GDP is PWT's, and in places very high.** The aligned stock is more than 8 times the GDP in Tajikistan and Ukraine from 1994, Nigeria in 1982–2001, Venezuela from 2017 (up to 38 times) and, in fewer years, a dozen other countries. These are PWT's estimates, kept as they are.
