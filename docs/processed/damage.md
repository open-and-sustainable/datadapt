---
title: Processed damage data
layout: default
---

# Processed damage data

The processed table `damage_country_event_year` (in `DatAdapt-database/processed/DatAdapt.duckdb`) sums the losses of the [raw EM-DAT records](../raw/damage.html) by country, disaster type and year, with every event assigned to a present-day country on the [shared country map](../index.html#countries). It is made by `transform_data("damage")` (in `transform_data.sh`) in two steps.

## Step 1: each event in a present-day country

EM-DAT's own code is kept as `ISO_EMDAT`, and `ISO` takes the country the event is assigned to (`locate_damage_events` in `src/CountryMapping.jl`):

- **Former states.** Events coded to a state that no longer exists, such as Czechoslovakia or Yugoslavia, take the successor state they occurred in. Each one was reviewed by hand, reading the successor from the event's `Location` or its GADM units; the result is in `country_mappings/damage_former_states.csv`.
- **Contested areas.** Events whose GADM units all lie in Kosovo (`XKO`) or Western Sahara (`ESH`) are assigned to that area. Events that cover a contested area together with the country that administers it keep EM-DAT's code, since their losses cannot be split.
- **Territories merged into a country.** Events in territories that another country's World Bank series include take that country's code: Réunion, Martinique, Guadeloupe, French Guiana and Mayotte become France (`FRA`), the Canary Islands Spain (`ESP`) and the Azores Portugal (`PRT`).
- **All other events** keep EM-DAT's code.

Events that cannot be located are left out: a former state with no usable location, or an event spread over two successor states or several contested areas, whose losses cannot be split.

## Step 2: sums by country, disaster type and year

The located records are grouped by country, disaster type and start year (`src/DataTransform/damage_country_event_year.prql`). A disaster type's losses in a year are the sums over its records; a sum is empty where no record of the group reports that loss.

| Column | Content |
|---|---|
| `ISO` | Country, on the shared country map |
| `Disaster Type` | EM-DAT disaster type (see the [raw data](../raw/damage.html#source-data)) |
| `Start Year` | Year the disasters started |
| `CPI` | EM-DAT's consumer price index for that year |
| `iso_emdat` | The EM-DAT codes of the group's records, separated by `;` |
| `record_count` | Number of EM-DAT records in the group |
| `total_deaths` | Sum of `Total Deaths` |
| `total_injured` | Sum of `No. Injured` |
| `total_affected` | Sum of `No. Affected` |
| `total_homeless` | Sum of `No. Homeless` |
| `total_damage` | Sum of `Total Damage ('000 US$)` |
| `total_damage_adjusted` | Sum of `Total Damage, Adjusted ('000 US$)` |
