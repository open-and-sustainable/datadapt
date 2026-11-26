---
title: Processed damage data
layout: default
---

# Processed damage data

The processed table `damage_country_event_year` (in `DatAdapt-database/processed/DatAdapt.duckdb`) sums the losses of the [raw EM-DAT records](../raw/damage.html) by country, disaster type and year, with every event assigned to a present-day country on the [shared country map](../index.html#countries). It is made by `transform_data("damage")` (in `transform_data.sh`) in three steps.

## Step 1: each event in a present-day country

EM-DAT's own code is kept as `ISO_EMDAT`, and `ISO` takes the country the event is assigned to (`locate_damage_events` in `src/CountryMapping.jl`):

- **Former states.** Events coded to a state that no longer exists, such as Czechoslovakia or Yugoslavia, take the successor state they occurred in. Each one was reviewed by hand, reading the successor from the event's `Location` or its GADM units; the result is in `country_mappings/damage_former_states.csv`.
- **Contested areas.** Events whose GADM units all lie in Kosovo (`XKO`) or Western Sahara (`ESH`) are assigned to that area. Events that cover a contested area together with the country that administers it keep EM-DAT's code, since their losses cannot be split.
- **Territories merged into a country.** Events in territories that another country's World Bank series include take that country's code: Réunion, Martinique, Guadeloupe, French Guiana and Mayotte become France (`FRA`), the Canary Islands Spain (`ESP`) and the Azores Portugal (`PRT`).
- **All other events** keep EM-DAT's code.

Events that cannot be located are left out: a former state with no usable location, or an event spread over two successor states or several contested areas, whose losses cannot be split.

## Step 2: sums by country, disaster type and year

The located records are grouped by country, disaster type and start year (`src/DataTransform/damage_country_event_year.prql`). A disaster type's losses in a year are the sums over its records; a sum is 0 where no record of the group reports that loss.

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
| `vsl` | Value of one death in the country and year (step 3) |
| `deaths_value` | `total_deaths` × `vsl` |
| `injuries_value` | `total_injured` × 0.047 × `vsl` |
| `total_damage_monetized` | `total_damage_adjusted` + `deaths_value` + `injuries_value` |

The last four columns are in thousands of US dollars at EM-DAT's constant prices, like `total_damage_adjusted`.

## Step 3: deaths and injuries in money

Deaths and injuries are valued in money and added to the economic damage, for a total that also covers the many events whose economic damage EM-DAT does not record (`value_human_losses` in `src/DatAdapt.jl`). This is the one step where damage draws on other data: the UN's population and life tables, and the World Bank's GNI per capita from the [raw exposure data](../raw/exposure.html).

- **A death** is valued at the life years it costs. For every age, the life expectancy e at that age in the country and year ([UN life tables](../raw/damage.html#population-and-life-expectancy-by-age)) is turned into its present value at a 3% discount rate, (1 − 1.03<sup>−e</sup>) / 0.03 years, and the values are averaged with the population of each age as weights, so a victim is taken to be of the population's age. Each of these years is worth the country's GNI per capita (Atlas method, current US$) of the same year. Brought to EM-DAT's constant prices with × 100 / `CPI`, as EM-DAT adjusts its own amounts, the result is the value of a statistical life, `vsl`.
- **An injury** is valued at 4.7% of `vsl`, the value of a moderate injury (MAIS 2) in the US Department of Transportation's *Departmental Guidance: Treatment of the Value of Preventing Fatalities and Injuries in Preparing Economic Analyses* (March 2021), Table 2. That table derives each injury's value from the quality-adjusted life years it costs relative to a death, so the share holds whatever the value of a death. EM-DAT does not record how severe injuries are, and counts as injured anyone who needs immediate medical assistance.
- **The homeless and the affected are not valued.** The loss of a home is part of the economic damage, and the number affected says more about exposure than about losses.

Where the inputs are missing:

- **No GNI per capita or no life table.** A country and year without one takes the average of its land neighbours on the [country map](../index.html#countries) that have one in that year. An island, or a country none of whose neighbours has one, takes the value of the nearest country that has one. Two countries are land neighbours where their outlines, simplified to about 500 m, come within about 1 km of each other, and distances are measured between outlines, across the antimeridian where shorter. The outlines are GADM's, from the GeoPackage the hazard data use (`country_mappings/source_maps/gadm_4.1/`), so this step needs it too. This fills the GNI per capita of 236 of the 7,026 rows, 138 of them with deaths or injuries, mostly in years the World Bank has no figure for, such as the 1980s for Vietnam, Mozambique and the Soviet Union's successors, and recent years for Afghanistan, Yemen, Syria and Cuba. The life tables cover every country with deaths or injuries; the UN codes Kosovo `XKX`, which is matched to `XKO`.
- **Taiwan and North Korea** have no GNI per capita in the World Bank's data, and their neighbours' incomes are far from theirs, so their four columns are empty.
- **No economic damage.** Economic damage that EM-DAT does not record counts as 0, so the total of such a row is the value of its deaths and injuries alone.

## Data limitations and assumptions

- **The value of a death is a lower bound.** Valuing a life year at GNI per capita counts what a death costs in income, about 20 to 25 times GNI per capita. Estimates of what people are willing to pay to reduce their risk of death are far higher: the US Department of Transportation's value of a statistical life is $9.1 million for 2012, about 173 times the US GNI per capita of that year, against about $1.2 million here.
- **Totals are underestimates where economic damage is not recorded.** Of the 5,111 rows with deaths or injuries, 2,930 (4,346 events) have no economic damage in EM-DAT, and their total is the value of their deaths and injuries alone.
- **Victims are of the population's age.** EM-DAT does not record the ages of the dead, so the life years lost are the population's average.
- **Injuries are all moderate.** EM-DAT does not record how severe injuries are.
- **Neighbours stand in for missing incomes.** A neighbour's income can be far from the country's own. Cuba, for example, an island whose last World Bank figure is $9,010 for 2019, takes for 2020–2025 the GNI per capita of Haiti, its nearest country, $1,340 to $2,010.
