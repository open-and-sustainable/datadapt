---
title: Raw exposure data
layout: default
---

# Raw exposure data

The raw table `exposure` (in `DatAdapt-database/raw/DatAdapt.duckdb`) holds seven World Development Indicators of the World Bank for 1980–2025, as returned by the World Bank API: 85,330 rows.

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

## How to reproduce the table

Run `fetch_exposure_data` (in `fetch_data.sh`). It needs no account: it downloads the seven indicators for 1980–2025, retrying failed requests, and writes the table `exposure`.
