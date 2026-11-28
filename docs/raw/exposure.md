---
title: Raw exposure data
layout: default
---

# Raw exposure data

The raw exposure data are two tables in `DatAdapt-database/raw/DatAdapt.duckdb`: [`exposure`](#table-exposure), seven World Development Indicators of the World Bank for 1980–2025, as returned by the World Bank API (85,330 rows), and [`capital_stock`](#table-capital_stock), the capital stock of the Penn World Table for 1980–2023 (8,140 rows).

## Source data

The indicators are downloaded from the World Bank API (`https://api.worldbank.org/v2/country/all/indicator/<code>`), for every economy and aggregate the API returns: 265 for each indicator and year.

Every indicator is licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The World Bank compiles them from the original sources listed in each indicator's metadata:

| Indicator | Name | Unit | Source |
|---|---|---|---|
| `SP.POP.TOTL` | Population, total | people | UN Population Division, World Population Prospects; national statistical offices; Eurostat, Demographic Statistics; UN Statistics Division, Population and Vital Statistics Report |
| `AG.SRF.TOTL.K2` | Surface area | km² | Food and Agriculture Organization of the United Nations (FAO) |
| `EN.POP.DNST` | Population density | people per km² of land area | FAO population estimates; World Bank population estimates |
| `NY.GDP.MKTP.CD` | GDP | current US$ | National statistical organizations and/or central banks; OECD National Accounts data files; World Bank staff estimates |
| `NY.GDP.MKTP.KD.ZG` | GDP growth | annual % | National statistical organizations and/or central banks; OECD National Accounts data files; World Bank staff estimates |
| `NY.GNP.PCAP.CD` | GNI per capita, Atlas method | current US$ | National statistical organizations and/or central banks; OECD National Accounts data files; World Bank staff estimates |
| `NY.GNP.PCAP.PP.CD` | GNI per capita, PPP | current international $ | World Bank, International Comparison Program (ICP); Eurostat and OECD PPP Programmes; OECD National Accounts data files; IMF World Economic Outlook database; World Bank staff estimates |

## Table `exposure`

One row per indicator, economy and year, in the long format of the API. All columns are stored as text.

| Column | Content |
|---|---|
| `country_name` | The World Bank's name for the economy or aggregate |
| `country_code` | Its ISO 3166 alpha-3 code (`countryiso3code`); empty for some aggregates |
| `year` | Year, 1980–2025 |
| `value` | The indicator's value, NULL where the World Bank has none (9,404 rows) |
| `indicator` | The indicator's code, as in the table above |

The rows include the World Bank's aggregates (regions, income groups, lending groups and the world). The [processed table](../processed/exposure.html) keeps only the economies.

## How to reproduce the table `exposure`

Run `fetch_exposure_data` (in `fetch_data.sh`). It needs no account: it downloads the seven indicators for 1980–2025, retrying failed requests, and writes the table `exposure`.

## Capital stock: source data

The capital stock comes from the Penn World Table (PWT) version 11.0 of the Groningen Growth and Development Centre, published on DataverseNL ([doi:10.34894/FABVLR](https://doi.org/10.34894/FABVLR)) under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), for 185 countries from 1950 to 2023 (Feenstra, Inklaar & Timmer, 2015). Two of its files are used: the main file `pwt110.xlsx`, for the capital stock and the GDP with their price levels, and the capital detail file `pwt110_capital_detail.xlsx`, for the stock of each asset. PWT estimates each country's capital stock from its past investment in each asset, less depreciation.

## Table `capital_stock`

One row per country and year of the PWT main file, 1980–2023, with PWT's values as published.

| Column | Content |
|---|---|
| `countrycode` | PWT's ISO 3166 alpha-3 code |
| `year` | Year, 1980–2023 |
| `cn` | Capital stock at current PPPs, millions of 2021 US$ (main file) |
| `pl_n` | Price level of the capital stock, the price level of the USA in 2021 = 1 (main file) |
| `cgdpo` | Output-side real GDP at current PPPs, millions of 2021 US$ (main file) |
| `pl_gdpo` | Price level of `cgdpo` (PPP over exchange rate), the price level of the USA's in 2021 = 1 (main file) |
| `Nc_Struc` | Current-cost net capital stock of residential and non-residential structures, millions of national currency (capital detail file) |
| `Nc_Mach` | The same, of machinery and (non-transport) equipment |
| `Nc_TraEq` | The same, of transport equipment |
| `Nc_Other` | The same, of other assets |

The values are NULL where PWT has none. 180 countries have them: 156 from 1980, Yemen from 1989, and the successors of the Soviet Union, Yugoslavia and Czechoslovakia from 1990 (7,681 rows). Curaçao, Guyana, Somalia, South Sudan and Sint Maarten have none. The GDP is in 7,823 rows, and in every row with a capital stock.

## How to reproduce the table `capital_stock`

Run `fetch_capital_stock_data` (in `fetch_data.sh`). It needs no account: it finds the two files among those of PWT 11.0 on DataverseNL, downloads them and writes the table `capital_stock`.
