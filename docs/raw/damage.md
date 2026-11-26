---
title: Raw damage data
layout: default
---

# Raw damage data

The raw table `damage` (in `DatAdapt-database/raw/DatAdapt_damage.duckdb`, a local file that the dataset repository ignores) lists the climate-related disasters recorded in EM-DAT, the international disaster database of CRED / UCLouvain ([www.emdat.be](https://www.emdat.be)), that started between 1980 and 2025: 12,499 events in 228 countries and territories.

EM-DAT's licence does not allow redistributing its records, so the public database leaves this table out: build it with the steps [below](#how-to-reproduce-the-table).

## Source data

EM-DAT records a disaster when it meets at least one of its entry criteria: 10 or more deaths, 100 or more people affected, a declared state of emergency, or a call for international assistance. A disaster that hits several countries has one record per country.

The table is read from an excerpt exported from the EM-DAT data portal, `DatAdapt-database/raw/clima-hydro-meteo_EM-DAT.xlsx` (sheet `EM-DAT Data`). It holds the natural disasters of the climatological, hydrological and meteorological subgroups:

| Disaster Subgroup | Disaster Type | Events |
|---|---|---|
| Climatological | Drought | 661 |
| Climatological | Glacial lake outburst flood | 8 |
| Climatological | Wildfire | 488 |
| Hydrological | Flood | 5,616 |
| Hydrological | Mass movement (wet) | 750 |
| Meteorological | Extreme temperature | 696 |
| Meteorological | Storm | 4,280 |

## Table `damage`

One row per EM-DAT record, with EM-DAT's 47 columns under their EM-DAT names, unchanged. Only records whose `Start Year` lies in 1980–2025 are kept. `Start Year` and `End Year` are integers and `CPI` a double; every other column is stored as text, as in the excerpt.

- **Identification and classification:** `DisNo.`, `Historic`, `Classification Key`, `Disaster Group`, `Disaster Subgroup`, `Disaster Type`, `Disaster Subtype`, `External IDs`, `Event Name`, `Origin`, `Associated Types`.
- **Location:** `ISO`, `Country`, `Subregion`, `Region`, `Location`, `Latitude`, `Longitude`, `River Basin`, `Admin Units`, `GADM Admin Units`.
- **Timing:** `Start Year`, `Start Month`, `Start Day`, `End Year`, `End Month`, `End Day`.
- **Intensity:** `Magnitude`, `Magnitude Scale`.
- **Response:** `OFDA/BHA Response`, `Appeal`, `Declaration`, `AID Contribution ('000 US$)`.
- **Human impact:** `Total Deaths`, `No. Injured`, `No. Affected`, `No. Homeless`, `Total Affected`.
- **Economic impact:** `Reconstruction Costs ('000 US$)`, `Reconstruction Costs, Adjusted ('000 US$)`, `Insured Damage ('000 US$)`, `Insured Damage, Adjusted ('000 US$)`, `Total Damage ('000 US$)`, `Total Damage, Adjusted ('000 US$)`, `CPI`. The adjusted amounts are in constant US dollars, scaled by EM-DAT with the consumer price index `CPI`.
- **Record keeping:** `Entry Date`, `Last Update`.

`ISO` is EM-DAT's country code, including codes for states that no longer exist, such as Czechoslovakia (`CSK`). The [processed table](../processed/damage.html) assigns every event to a present-day country.

## How to reproduce the table

1. Export the climatological, hydrological and meteorological natural disasters from the EM-DAT data portal (registration required) as an Excel file, and save it as `DatAdapt-database/raw/clima-hydro-meteo_EM-DAT.xlsx`.
2. Run `fetch_damage_data` (in `fetch_data.sh`), which reads the excerpt, keeps the records of 1980–2025 and writes the table `damage`.

## Population and life expectancy by age

Two further raw tables, in `DatAdapt-database/raw/DatAdapt.duckdb`, give the population and life expectancy of every country by single year of age, from which the processed damage data value the life years lost to disaster deaths. They come from the UN World Population Prospects 2024 ([population.un.org/wpp](https://population.un.org/wpp/)), for both sexes together: estimates to 2023 and, for 2024 and 2025, the medium-variant projections. Both cover 237 countries and areas, 1980–2025 and ages 0 to 100, 1,101,102 rows each; the UN's regional and other aggregates are left out.

| Table | Column | Content |
|---|---|---|
| both | `ISO3_code` | ISO 3166 alpha-3 code of the country or area |
| both | `Location` | The UN's name for it |
| both | `Time` | Year, 1980–2025 |
| both | `AgeGrpStart` | Age in completed years, 0–100; 100 stands for 100 and over |
| `population_by_age` | `PopTotal` | Population on 1 July, in thousands |
| `life_expectancy_by_age` | `ex` | Life expectancy at that age, in years, from the UN's complete life table |

The UN's interim update of January 2026 revises only Togo's population counts, not its mortality, and is not used.

Run `fetch_life_table_data` (in `fetch_data.sh`) to reproduce both tables. It downloads four files of about 530 MB in all from the UN (`WPP2024_PopulationBySingleAgeSex_Medium_1950-2023.csv.gz`, `..._2024-2100.csv.gz`, `WPP2024_Life_Table_Complete_Medium_Both_1950-2023.csv.gz` and `..._2024-2100.csv.gz`) and keeps the countries and years above.
