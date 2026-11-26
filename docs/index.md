---
title: Home
layout: default
---

# Open Data Project on Global Endogenous Climate Adaptation (DatAdapt)

DatAdapt provides country-level data on three variables, from 1980 to 2025:

- **hazard**: how often, how widely and how severely eight types of climate-related hazard struck each country in each year, from the ERA5 reanalysis;
- **damage**: the disasters recorded in EM-DAT and their human and economic losses;
- **exposure**: population, area and economy, from the World Bank's World Development Indicators.

The three variables are kept independent: none of them is weighted by, or derived from, another. How they are combined is left to the analyses that use them.

The project is registered at the OSF, [doi:10.17605/OSF.IO/DWH98](https://doi.org/10.17605/OSF.IO/DWH98).

## Raw and processed data

The data come in two DuckDB databases, distributed separately from the code in the dataset repository [DatAdapt-database](https://git.nilu.no/ribo/DatAdapt-database), which the pipeline expects in the root of this repository.

| Database | Tables | Content |
|---|---|---|
| `raw/DatAdapt.duckdb` | [`hazard`](raw/hazard.html), [`damage`](raw/damage.html), [`exposure`](raw/exposure.html) | The data as fetched from each source, or for hazard as computed from it |
| `processed/DatAdapt.duckdb` | [`hazard_country_year`](processed/hazard.html), [`damage_country_event_year`](processed/damage.html), [`exposure_country_year`](processed/exposure.html) | The raw tables on one country map, in the shape used for analysis |

Each database also has a table `metadata`, with one row per table: `table_name`, the years it covers (`start_year`, `end_year`), its `source` and the date it was last `updated`.

## Countries

All processed tables, and the raw hazard table, use one country map, so the three variables can be joined on `country_code`. A country is kept apart wherever all three variables can describe it on its own, which in practice means wherever the World Bank publishes its own series for it:

- the map is GADM 4.1 at country level, the map EM-DAT's codes come from;
- territories that another country's World Bank series include are merged into that country, such as France's overseas departments, the Canary Islands and the Azores. The full correspondence is in `country_mappings/hazard_units.csv`;
- of the contested areas, Kosovo (`XKO`) and Western Sahara (`ESH`) are kept apart, because the series of the countries that administer them leave them out;
- Antarctica and the Caspian Sea are not countries on this map.

## Running the pipeline

The pipeline is a Julia project. From the repository root:

1. `fetch_data.sh` fetches the raw data: exposure from the World Bank API, damage from an EM-DAT excerpt, and the ERA5 grids for hazard.
2. `compute_hazard_national.sh` computes the raw hazard table from the grids.
3. `transform_data.sh` makes the processed tables (it also holds the one-off installation of DuckDB's PRQL extension, which the transformations are written in).

Each raw data page gives what its source needs.

## Citation

If you use DatAdapt, please cite it as:

Boero, R. (2024). *Open Data Project on Global Endogenous Climate Adaptation (DatAdapt)* [Dataset]. OSF. https://doi.org/10.17605/OSF.IO/DWH98

```bibtex
@misc{boero2024datadapt,
  author    = {Boero, Riccardo},
  title     = {Open Data Project on Global Endogenous Climate Adaptation (DatAdapt)},
  year      = {2024},
  publisher = {OSF},
  doi       = {10.17605/OSF.IO/DWH98},
  url       = {https://doi.org/10.17605/OSF.IO/DWH98}
}
```

Author: Riccardo Boero ([ORCID 0000-0002-7468-9096](https://orcid.org/0000-0002-7468-9096)).

## Licence

The software is licensed under the [MIT license](https://github.com/open-and-sustainable/datadapt/blob/main/LICENSE). The resulting data is licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/). Hazard data are generated using Copernicus Climate Change Service information 2026. Damage data come from EM-DAT, CRED / UCLouvain ([www.emdat.be](https://www.emdat.be)), and exposure data from the World Bank's World Development Indicators.
