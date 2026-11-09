## Hazard transformation method

This section records how hazard is transformed from the ERA5 grids to national annual values, and why. Every step below has been agreed. None of it is implemented yet: the recomputation will run once every ERA5 grid year, 1950–2025, is available.

### Why country-day averages are not enough

The fetch currently aggregates each daily grid straight to countries (`aggregate_country_daily` in `src/HazardDataFetch.jl`). For each country and day it keeps four numbers from the grid cells inside the country: the area-weighted mean, the minimum, the maximum and the number of cells. The re-aggregation to the GADM-based country map (`reaggregate_year`) uses the same function. This is not enough to characterise extreme events, which are subnational by definition:

1. **The mean dilutes local events.** An extreme confined to a small part of a country barely changes the national mean. Heavy rain on 1% of the area, for example, moves it by about 1% of the rainfall.
2. **The maximum is a single cell, in a different place each day.** It shows how extreme the worst cell was, but not where the event happened or how much of the country it covered.
3. **Averaging comes before the event measures, and can't be undone.** Event measures are nonlinear: threshold exceedances, durations, multi-day accumulations, joint occurrence of several variables. They have to be computed in each grid cell before any spatial aggregation. The country-day table can't provide them, so they must be computed from the gridded NetCDF files.

### Scope

Only the hazard domain is changed here. Hazard, damage and exposure stay independent: hazard is characterised by physical and climatological measures alone, with no weighting by exposure or damage. How the domains are combined belongs to the modelling and analysis stage, outside this repository.

The method uses only the data the pipeline already downloads: the 14 ERA5 daily statistics for 1950–2025, through the main and baseline fetches. It requires no further downloads.

### Method

The method follows the concurrent-extremes approach of Bennett et al. (2021) and Boero et al. (2022). It is applied the same way to every event type, so that all types are characterised consistently.

#### Step 1: a baseline reference for each grid cell

Every grid cell gets its own reference for each event type, taken from the baseline period 1950–1979, which is fetched for this purpose (`fetch_baseline_hazard_data`, written to `DatAdapt-database/raw/DatAdapt_1950-1979.duckdb`). An extreme is then measured against the climate of the cell where it happens, so regions with very different climates are comparable before they are combined into countries. A 35 °C day, for instance, is extreme in Oslo but ordinary in Riyadh.

The per-cell reference follows the peaks-over-threshold approach of Bennett et al. (2021, §2.4.1). There, each indicator had its own threshold at each grid cell, from the historical period: the 95th percentile for high extremes and the 5th for low ones. An exceedance was recorded as a binary value for each cell and timestep. Those per-indicator thresholds and binary exceedances are not used here, because an extreme is defined jointly over an event type's indicators (Step 3). Instead, the cell's baseline supplies the indicators' marginal distributions, their copula and the joint threshold.

**Whole-year or seasonal reference.** A cell's baseline reference is either the whole year or the same time of year, depending on the event type:

- **Whole year:** Heat, Cold, Flood, Storm, Landslide and Wildfire. An extreme is one of the most extreme days of any season, and that is where the damage comes from. A heat-wave summer still has clearly hotter days than a normal one, so the whole-year reference keeps telling years apart.
- **Same time of year:** Drought and Avalanche.
  - **Drought.** Against the whole year, every normal dry season would look extreme. In a Mediterranean cell, for example, almost every summer has 80–90 dry days out of 90. The indicator would saturate, and a drought summer could not be told apart from a normal one. Against past summers, only a summer drier than usual stands out.
  - **Avalanche.** A winter thaw is never in the warm tail of the whole year, because summer is always warmer. Against the whole year, the warming indicator could never catch the winter warm spells that set off wet-snow avalanches.

A seasonal reference for Cold was considered. It would also catch unusually cold spring spells, but it would flag cool summer days too, which do no harm. Cold keeps the whole-year reference, and the late frosts it misses are recorded as a limitation.

**The time-of-year window.** For Drought and Avalanche, each calendar day's reference is a 31-day window centred on that day: the 15 days before, the day itself and the 15 days after. The window is taken from every baseline year, which gives about 930 days per cell (31 × 30) to fit the marginals and the copula on. It wraps across the new year, so the window for 1 January includes 17–31 December. The standard climate-extremes indices use the same calendar-day window, 5 days wide, for their percentile-based indices (Zhang et al., 2011). A 5-day window was considered and rejected, because it would give only about 150 days per cell, too few to fit a copula of three indicators. The wider window blurs the seasonal cycle little. For Drought, the dry-day and temperature indicators already look back 90 and 30 days (Step 2). For Avalanche, 15 days either side still compares a winter day with other winter days.

The marginals and the copula (Step 3) are fitted anew for each of the 366 calendar days. That takes roughly 45 hours on 32 cores, against about 4 hours for the six whole-year types together. Fitting every 5th day, with each day using the nearest fit, was considered and rejected. It would take about 9 hours, but the seasonal cycle would then move in steps.

#### Step 2: event types and their indicators

Indicators are organised by the disaster types in the damage data (EM-DAT): Flood, Storm, Mass movement (wet), Extreme temperature, Drought, Wildfire and Glacial lake outburst flood. Each type gets hazard measures that correspond to it.

Following Bennett et al. (2021, §2.4 and Table 2), each event type is characterised by two or three indicators that are relevant to it, chosen to be only weakly correlated with one another. In that study:

| Impact | Indicators |
|---|---|
| Heat waves | maximum temperature, maximum evapotranspiration |
| Drought | maximum temperature, low-precipitation days (< 0.01 mm), minimum soil moisture |
| Low flows | minimum streamflow, minimum soil moisture, maximum evapotranspiration |
| Flooding | maximum precipitation, maximum streamflow, maximum soil moisture |

The indicators were computed for each grid cell over several intervals: synoptic (5-day, 73 per year), monthly, seasonal and annual. Leap days were removed so that every year has 365 days (Bennett et al., 2021, §2.4).

Here the indicators are built from the 14 ERA5 daily statistics the pipeline downloads: 2 m temperature (daily minimum, maximum and mean), 2 m dewpoint temperature (daily mean), 10 m wind gust (daily maximum), mean sea-level pressure (daily minimum), convective available potential energy (daily maximum), total precipitation, snowfall, potential evaporation, surface runoff and sub-surface runoff (daily sums), snow depth and volumetric soil water layer 3 (daily means).

Indicators by EM-DAT type:

| EM-DAT type | Indicator | ERA5 source | Basis |
|---|---|---|---|
| Flood | maximum 5-day precipitation | `total_precipitation`, daily sum | flooding indicators of Bennett et al. (2021, Table 2) and Boero et al. (2022, §2.1.1) |
| Flood | maximum 1-day precipitation | `total_precipitation`, daily sum | flash floods respond to a single day's rain |
| Flood | maximum runoff | `surface_runoff` + `sub_surface_runoff`, daily sums | ERA5 counterpart of streamflow or runoff in those studies |
| Flood | maximum soil moisture | `volumetric_soil_water_layer_3` (28–100 cm), daily mean | the third soil layer used by Bennett et al. (2021, Table 1) |
| Mass movement (wet) | maximum precipitation | `total_precipitation`, daily sum | rain-triggered landslides and mudflows start with heavy rain |
| Mass movement (wet) | maximum soil moisture | `volumetric_soil_water_layer_3` (28–100 cm), daily mean | on ground that is already wet; runoff is left out as less relevant to slope failure than to floods |
| Mass movement (wet, avalanche) | heavy snowfall | `snowfall`, daily sum | new snow loads the snowpack |
| Mass movement (wet, avalanche) | deep snowpack | `snow_depth`, daily mean | there must be snow to slide |
| Mass movement (wet, avalanche) | warming | `2m_temperature`, daily maximum, at its high extreme | warm spells destabilise snow and set off wet-snow avalanches |
| Storm | maximum wind gust | `instantaneous_10m_wind_gust`, daily maximum | storm winds |
| Storm | minimum sea-level pressure | `mean_sea_level_pressure`, daily minimum | depth of the low; a low extreme, so it is reversed before the copula is fitted (Step 3) |
| Storm | maximum precipitation | `total_precipitation`, daily sum | storm rainfall; ERA5 precipitation includes snow, so blizzards are covered too |
| Storm | maximum convective instability | `convective_available_potential_energy` (CAPE), daily maximum | conditions favourable to thunderstorms, hail and tornadoes |
| Extreme temperature (heat) | maximum temperature | `2m_temperature`, daily maximum | heat-wave indicator of Bennett et al. (2021, Table 2) |
| Extreme temperature (heat) | warm nights | `2m_temperature`, daily minimum, at its high extreme | hot nights prevent recovery from daytime heat |
| Extreme temperature (heat) | humid heat | `2m_dewpoint_temperature`, daily mean | humidity makes the same temperature more dangerous |
| Extreme temperature (cold) | cold nights | `2m_temperature`, daily minimum, at its low extreme | a low extreme, so it is reversed before the copula is fitted (Step 3) |
| Extreme temperature (cold) | cold days | `2m_temperature`, daily maximum, at its low extreme | days that stay cold mark a persistent cold spell |
| Extreme temperature (cold) | heavy snowfall | `snowfall`, daily sum | the main feature of severe winter conditions; carries no information where it never snows, so cold there rests on the two temperature indicators |
| Drought | maximum temperature | `2m_temperature`, daily maximum | drought indicator of Bennett et al. (2021, Table 2) |
| Drought | dry days | days with `total_precipitation` below 1 mm | low-precipitation days of Bennett et al. (2021, Table 1), with the dry-day threshold of the standard climate-extremes indices (Zhang et al., 2011) |
| Drought | minimum soil moisture | `volumetric_soil_water_layer_3` (28–100 cm), daily mean, at its low extreme | drought indicator of Bennett et al. (2021, Table 2) |
| Wildfire | maximum temperature | `2m_temperature`, daily maximum | hot fire weather |
| Wildfire | dry air | `2m_dewpoint_temperature`, daily mean, at its low extreme | combined with high temperature, a low dewpoint means very dry air |
| Wildfire | strong wind | `instantaneous_10m_wind_gust`, daily maximum | wind drives fire spread |
| Wildfire | dry fuel | `volumetric_soil_water_layer_3` (28–100 cm), daily mean, at its low extreme | dry soil and vegetation |

Bennett et al. (2021, Table 1) counted days below 0.01 mm as dry. ERA5, like other reanalyses, produces light precipitation on too many days, so at 0.01 mm hardly any day would count as dry. The 1 mm threshold is the one that defines dry days in the standard climate-extremes indices (Zhang et al., 2011).

Wildfire covers EM-DAT's forest fires (307 events, 1980–2025), land fires (82) and wildfires of unspecified subtype (99). Like CAPE for storms, its indicators describe fire weather, the conditions under which fires spread, not ignition: lightning and human causes are not captured.

Glacial lake outburst flood has no hazard definition (see "Data limitations and assumptions").

Mass movement (wet) has two definitions:
- **Landslide:** precipitation and soil moisture. It covers EM-DAT's wet landslides (558 events, 1980–2025), mudslides (79), wet rockfalls (3) and the one wet subsidence. It shares two inputs with Flood but has its own joint distribution, so the two types stay distinct.
- **Avalanche:** snowfall, snow depth and warming. It covers EM-DAT's `Avalanche (wet)` subtype (109 events), which is snow avalanches. These are driven by the snowpack rather than by wet soil, so the landslide indicators do not describe them.

Storm has a single definition for all EM-DAT storm subtypes. There are 4,280 storm events in 1980–2025:

- **Large systems (3,325 events):** tropical cyclones (2,159), extratropical storms (180), blizzards and winter storms (228), and storms of unspecified subtype (738). Wind gust, low pressure and precipitation capture these well.
- **Convective storms (564 events):** severe weather (360), lightning and thunderstorms (188), derechos (6), and storm surges (10). Gust and rain catch the larger ones, but there is no low-pressure signal, and ERA5 smooths out convection.
- **Small-scale storms (411 events):** tornadoes (277), hail (108), and sand and dust storms (26).

CAPE was added as a fourth indicator to cover the convective part. It shows that conditions favoured convection, not that the event happened. Because the indicators are combined through their joint distribution, an extra indicator adds information without needing a separate definition for each subtype.

Extreme temperature has two definitions, because a joint extreme runs in one direction only. *Heat* covers EM-DAT's heat waves (321 events, 1980–2025). *Cold* covers cold waves (295) and severe winter conditions (80). Bennett et al. (2021, Table 2) also used maximum evapotranspiration for heat waves. Its nearest ERA5 counterpart, `potential_evaporation`, is computed for a well-watered surface and is unreliable in dry regions, so it is not used.

**Time step and look-back windows.** Every indicator is computed daily, for each grid cell, and each indicator looks back over its own window of past days: one day for a wind gust, for example, or several months for a precipitation deficit. All of an event type's indicators then line up day by day for the joint distribution, while each keeps its own memory.

This differs from the reference studies, which computed indicators over fixed blocks: 5-day periods (Boero et al., 2022, §2.1.1), and monthly, seasonal and annual intervals (Bennett et al., 2021, §2.4). Fixed blocks collapse every indicator onto one scale, blur the timing of events, and split events that cross a block boundary. With daily data there is no reason to accept that.

A value with a look-back window of n days needs the n − 1 preceding days of data. At the start of the record, 1 January 1950, an indicator has no value until its window is full. With the longest window at 90 days, that leaves at most the first 89 days of 1950 without some indicators. No spin-up year is downloaded: ERA5 goes back to 1940, but the extra requests and storage would buy only a few weeks of the baseline.

Look-back windows follow one rule for all indicators:

1. **State variables** (`volumetric_soil_water_layer_3`, `snow_depth`): the same day's value. They already carry the memory of past days.
2. **Daily extremes** (`instantaneous_10m_wind_gust`, `mean_sea_level_pressure`, `convective_available_potential_energy`): the same day.
3. **Amounts that build up** (`total_precipitation`, `surface_runoff` + `sub_surface_runoff`, `snowfall`): summed over how long the event takes to build.
   - 1 day for Storm.
   - 5 days for Flood, Landslide and Avalanche, the window of the standard multi-day rainfall index Rx5day (Zhang et al., 2011).
   - 5 days for Cold's snowfall too. It is the same snow load that builds over several days for Avalanche, so both types share one indicator.
   - Flood also has a 1-day precipitation indicator, because flash floods respond to a single day's rain, which a 5-day sum would dilute.
4. **Temperature and dewpoint** (`2m_temperature`, `2m_dewpoint_temperature`): averaged over the past 3 days for Heat and Cold, because a heat or cold wave has to persist. The same day for Wildfire and for avalanche warming, which respond within a day.
5. **Drought:** dry days counted over the past 90 days, and maximum temperature averaged over the past 30 days.

Daily values are linked to calendar years as follows:

1. **Each day's value belongs to its own calendar year.** An event that crosses the year boundary, such as a heat wave from 30 December to 3 January, counts in both years for the days it covers.
2. **Look-back windows reach across the year boundary.** A 90-day window on 15 January draws on the previous October to December. For 1980 those days are in the baseline period. The baseline (1950–1979) and the main period (1980–2025) are stored in separate databases and grid years, but they are read as one continuous daily record.
3. **Leap days are kept.** Bennett et al. (2021, §2.4) removed them so that their 5-day blocks fit the year; with a daily time step there is no need. Under a time-of-year reference (Step 1), 29 February borrows its reference from the surrounding days. Under a whole-year reference it is one more day in the sample.

#### Step 3: combining the indicators through their joint distribution

An event type's indicators are combined through their joint distribution, using copulas, rather than one at a time. Bennett et al. (2021) combined indicators by averaging a standardised change metric, the Distance Number. They describe that as a basic statistical metric and name copulas as the next step (§2.4.2 and §4). Boero et al. (2022) then applied copulas to flooding, and found that considering the concurrent distribution of several variables makes quantifying and predicting extremes "easier, more realistic" (Abstract).

In Boero et al. (2022, §2.1.1), the joint distribution of an event type's m indicators X₁…Xₘ is given by a copula C (Sklar's theorem):

F(x) = C(F₁(x₁), …, Fₘ(xₘ))

where F₁…Fₘ are the indicators' marginal cumulative distribution functions. The estimation takes two stages:

1. **Marginals.** Each indicator's marginal distribution is fitted and selected by goodness-of-fit tests. Candidates include normal, gamma, log-normal, exponential, Gumbel and beta, fitted with the R package fitdistrplus.
2. **Copula.** A copula is fitted to the selected marginals. The candidates are elliptical (Gaussian, Student's t) and Archimedean (Clayton, Frank, Gumbel, Joe) families, and the best fit is found with a quasi-Newton method.

There, copulas were fitted for each watershed (HUC8) on the historical simulation. Exceedance of the 95th percentile of the copula's range was then identified at the grid-cell scale.

Boero et al. (2022, §4) state that the approach is independent of the geographical area and of the extreme event considered, and can be applied to other kinds of extremes, such as droughts, wildfires, snow and ice storms, and tornadoes. That is the basis for using one method across all EM-DAT types here.

**Marginals are fitted distributions, not empirical ranks.** Here, each indicator's marginal distribution is fitted separately for each grid cell on the baseline 1950–1979, using the whole-year or time-of-year reference from Step 1. As in Boero et al. (2022, §2.1.1), the distribution is chosen by goodness of fit, here measured by AIC (see below). Empirical ranks were considered and rejected. They make no distributional assumption, but they cap at the largest baseline value, so a record value in 1980–2025 would rank no higher than the worst day of 1950–1979. A main period warmer than the baseline makes such records common, especially for temperature indicators. A fitted distribution extends beyond the baseline range, so values more extreme than any in the baseline can still be ranked.

**Candidate distributions.** The candidates are those of Boero et al. (2022, §2.1.1): normal, gamma, log-normal, exponential, Gumbel and beta. Each is tried only where the indicator's values lie within its range: beta only for soil moisture, a volumetric fraction bounded by 0 and 1, and gamma, log-normal and exponential only for positive values, such as the non-zero days of a mixed distribution (below). For each cell, the candidate with the lowest AIC is chosen (see "The best fit is chosen by AIC").

Gumbel is tried both ways, for maxima and for minima, its mirror image, on every indicator. Of the other candidates, only normal and beta can fit a long lower tail, while gamma, log-normal, exponential and the Gumbel for maxima are all skewed upwards. Yet some low-extreme indicators have their extremes in a long lower tail, such as daily minimum pressure in deep cyclones and winter minimum temperature in cold outbreaks. A lower tail fitted too thin would exaggerate the return periods of their extremes.

**Indicators with many zero days.** Precipitation, runoff, snowfall and snow depth can be exactly zero on many days, and none of the continuous candidate distributions can represent a mass of values at zero. For these indicators, in any cell whose baseline reference has zero days, the marginal is a mixed distribution: F(0) = p₀, and F(x) = p₀ + (1 − p₀) G(x) for x > 0. Here p₀ is the share of zero days in the cell's baseline reference, and G is a continuous distribution fitted to the non-zero days only, chosen by AIC like the other marginals. This is how zero precipitation is handled in drought indices (Stagge et al., 2015). The extremes of these indicators are high values, so a zero day is never an extreme of that indicator on its own.

**What counts as zero.** ERA5 precipitation often holds tiny non-zero amounts, known as model drizzle, on days when a rain gauge would record nothing. Counted as non-zero, they would shrink p₀ and leave G fitted to drizzle. Daily values of precipitation, snowfall, runoff and snow depth below 0.1 mm, the smallest amount a rain gauge reports, are therefore set to zero, as are negative values. This is done on the daily values, before the look-back windows are summed.

**Indicators that are almost always zero.** Where an indicator is zero on nearly every baseline day, too few non-zero days remain to fit G. Examples are snowfall where it never snows, and snow depth in summer under a time-of-year reference. An indicator with fewer than 30 non-zero days in a cell's baseline reference, one a year on average, is therefore left out of that cell's copula, and the event type rests on its remaining indicators there. Cold where it never snows, for example, rests on its two temperature indicators. If a single indicator remains, its own u is the day's joint value. Avalanche is the exception, because snow is its precondition rather than one sign among several. Where, or at a time of year when, snowfall or snow depth has fewer than 30 non-zero baseline days, a cell has no avalanche extremes.

**Dry-day counts at their cap.** Drought's dry-day count cannot exceed 90, the length of its window. In dry places and dry seasons, such as the Sahel in January, most baseline days have all 90 days dry, a mass of values at 90 that no continuous distribution can represent. The marginal mirrors the one for zero days: F jumps by p₉₀ at 90, where p₉₀ is the share of baseline days with all 90 days dry, and G is fitted to the counts below 90 only. Days at 90 get a random u in [1 − p₉₀, 1], like the other tied values (below). If fewer than 30 baseline days have a count below 90, the indicator is left out of the cell's copula, as for indicators that are almost always zero, and Drought there rests on temperature and soil moisture.

**Indicators that never vary.** The same rule covers any indicator that holds one value on nearly every baseline day, such as snow depth on glaciers, which ERA5 holds fixed at 10 m of water equivalent. An indicator with fewer than 30 baseline days that differ from its most common value is left out of the cell's copula. For Avalanche, a snow depth that never varies from a non-zero value means snow is always present, so the precondition is met and Avalanche there rests on snowfall and warming.

**Tied values are spread at random.** The copula is fitted to one point (u₁, …, uₘ) per baseline day, and assumes that no two points are identical. Two kinds of indicator break that assumption. Zero days all share u = p₀ (see above), and Drought's dry-day counts repeat because they are whole numbers from 0 to 90. Fitted as they are, such ties form a wall of identical points that the fit reads as real structure, which distorts the estimated dependence and can change which family is chosen. Each tied day therefore gets a random u, drawn uniformly from the probability range its value covers: [0, p₀] for a zero day, and [F(k − ½), F(k + ½)] for a dry-day count k. This is the randomised probability integral transform (Brockwell, 2007).

It adds no bias. A tied value tells only that its u lies somewhere in that range, and spreading it evenly over the range expresses exactly that while restoring the uniform marginals the copula requires. Values above p₀ keep their exact u, so the upper tail, where extremes are decided, is unchanged. The only artefact is that dependence among tied days becomes random noise. That slightly weakens the estimated dependence in the low, non-extreme range. Dry-day counts repeat in narrow probability steps, so their random shifts are small, except in cells that are dry on almost every day. A fixed random seed makes the results reproducible.

**The same random spread is used when classifying days.** When a day's joint value is computed, in the baseline or in 1980–2025, a tied value also gets a random u within its range. A zero day can still be part of a joint extreme. A snowmelt flood, for example, has no rain but very high runoff and soil moisture, so the zero day's u matters there too. Fixing u at 0 would understate such days, and fixing it at p₀ would overstate them. The draws use the same fixed seed, so results are reproducible. Their noise largely averages out across a country's cells in the area-based national values (Step 4).

**Copulas are fitted for each grid cell.** Boero et al. (2022) fitted one copula per watershed (HUC8). Here each event type's copula is fitted separately for each grid cell, on the same baseline as its marginals. At a daily step a cell has about 11,000 baseline days (30 years × 365.25) under a whole-year reference, which is enough for a fit of its own. Under a time-of-year reference the sample is smaller, and its size depends on the window still open in Step 1. Fitting per region was considered and rejected. Watersheds are not available globally in the inputs, and a copula per country would pool very different climates, especially in large countries, which goes against keeping the subnational character of events.

**Copula families.** The candidates are the four Archimedean families of Boero et al. (2022, §2.1.1): Clayton, Frank, Gumbel and Joe. The best-fitting family is chosen separately for each grid cell and event type. Their tails differ. Gumbel and Joe have upper-tail dependence, Clayton has lower-tail dependence, and Frank has neither, so the choice adapts to how strongly the indicators' extremes occur together.

Boero et al.'s two elliptical families, Gaussian and Student's t, were considered and rejected for computational reasons. They were timed with Copulas.jl 1.0.1 on 11,000 days of four indicators. Fitting them is affordable, but evaluating the joint value C(u₁, …, uₘ) of one day takes 0.26 ms with a Gaussian copula and 93 ms with a t copula, which need numerical integration. An Archimedean copula takes 0.3 µs. The joint value is needed for every day, cell and event type, about 4 × 10¹⁰ evaluations, so even the Gaussian copula would take months of computing. In addition, the Kendall distribution (below) has a closed form for Archimedean copulas in any dimension (Barbe et al., 1996), but not for elliptical ones, where it would need a simulation that cannot reach the small probabilities of long return periods. The cost of this choice is that an Archimedean copula has a single parameter, so all indicator pairs of an event type share one dependence strength (see "Data limitations and assumptions").

**Low-extreme indicators are reversed first.** Before the copula is fitted, every indicator whose extreme is low is reversed on the probability scale, using 1 − Fᵢ(xᵢ) in place of Fᵢ(xᵢ). After that, every indicator rises as the hazard gets worse. The reversal is needed because the Clayton, Gumbel and Joe families can only represent indicators that rise together. The reversed indicators are minimum sea-level pressure (Storm), cold nights and cold days (cold), minimum soil moisture (Drought), and dry air and dry fuel (Wildfire). Reversing changes only the direction of an indicator, not its fitted marginal distribution.

**What counts as a joint extreme.** Each day in each cell gets the copula's joint value C(u₁, …, uₘ), with uᵢ = Fᵢ(xᵢ), reversed for low-extreme indicators. C is the probability that all indicators are at or below that day's values together, so it is high only when the indicators are high at the same time. A day is a joint extreme when its joint value c is above the 95th percentile of the joint values implied by the cell's fitted copula, K_C(c) > 0.95. Here K_C(t) = P(C(U₁, …, Uₘ) ≤ t) is the distribution of the joint value, known as the Kendall distribution (Genest and Rivest, 1993). For Archimedean copulas it has a closed form in any dimension (Barbe et al., 1996). The copula is fitted under the same whole-year or time-of-year reference as the marginals. The percentile is taken from the fitted copula rather than ranked among baseline days, so, like the marginals, it extends beyond the baseline range. This is how the exceedance of the 95th percentile of the copula's range in Boero et al. (2022) is applied here. The 95th percentile is also the level Bennett et al. (2021, §2.4.1) used for single indicators. Two alternatives were considered and rejected:

- Requiring every indicator to exceed its own baseline percentile makes joint extremes very rare as the number of indicators grows.
- Requiring any one indicator to exceed its own baseline percentile loses the concurrence that the joint distribution is meant to capture.

**The best fit is chosen by AIC.** Both the marginal distribution of each indicator and the copula family are chosen, for each grid cell, as the candidate with the lowest Akaike Information Criterion (Akaike, 1974), AIC = 2k − 2 ln L. Here k is the number of fitted parameters and L the maximised likelihood. Boero et al. (2022, §2.1.1) selected marginals by goodness-of-fit tests and copulas by best fit. AIC is used here because it rewards a good fit but penalises extra parameters, so a more flexible candidate does not win only because it is more flexible. The four copula families each have one parameter, so for the copula AIC ranks the candidates by likelihood alone. The penalty matters for the marginals, for example when an exponential distribution (one parameter) competes with a gamma distribution (two). Using the same criterion in both stages keeps the choice consistent across indicators, cells and event types.

#### Step 4: national annual values

Each country, year and event type gets three values, computed from the per-cell, per-day joint extremes of Step 3. None of them averages indicator values or intensities across cells, so an extreme in one part of a country is not diluted by the rest of it.

**Cells are weighted by their real surface area.** All cells are 0.25° × 0.25°, but their area in km² shrinks towards the poles in proportion to the cosine of latitude. A cell at 60°N, for example, covers about half the area of one at the equator. The current country-day aggregation already uses this weighting (`aggregate_country_daily` in `src/HazardDataFetch.jl`), and cells are assigned to countries the same way it does it (`assign_cells`). Each day counts in its own calendar year (Step 2).

**The three values.** Let aᵢ be the area of cell i and A = Σᵢ aᵢ the area of all the country's cells. Let Eᵢ,d be 1 when cell i is in a joint extreme on day d, and 0 otherwise.

1. **Extreme area-days**, Σ_d Σᵢ aᵢ Eᵢ,d / A: how much of the country was hit, and for how many days, summed over the year. It is measured in days. A value of 10 is the equivalent of the whole country in a joint extreme for 10 days, or of half the country for 20 days.
2. **Peak extent**, max_d Σᵢ aᵢ Eᵢ,d / A: the largest share of the country in a joint extreme on a single day, from 0 to 1.
3. **Peak intensity**, maxᵢ,d Tᵢ,d: how extreme the worst cell-day of the year was, compared with that cell's baseline, given as a return period in years.

**Rarity is taken from the fitted copula.** A day's return period in cell i is Tᵢ,d = 1 / (365.25 × (1 − K_C(cᵢ,d))) years, which is the Kendall return period of Salvadori et al. (2011) applied to daily values. K_C is the cell's Kendall distribution from Step 3. A value of 200 means that a day at least this extreme occurred in that cell, at the baseline frequency, once every 200 years on average. Ranking the day among the cell's baseline days was considered and rejected. It would stop at the worst baseline day, the same problem that ruled out empirical ranks for the marginals (Step 3). The joint-extreme threshold of Step 3 uses the same fitted copula, so the threshold and the rarity are consistent. A joint extreme (K_C > 0.95) corresponds to a return period above 1 / (365.25 × 0.05) ≈ 0.055 years, about 20 days.

**Return periods under a time-of-year reference.** Drought and Avalanche use the same formula, Tᵢ,d = 1 / (365.25 × (1 − K_C(cᵢ,d))). Their K_C is fitted on the 31-day window of Step 1, so a day is compared only with the same time of year. A 200-year drought day is therefore 200-year for that season. A different formula for these two types was considered and rejected, because with one formula the joint-extreme threshold maps to the same return period, about 20 days, for every event type. That keeps the national values comparable across types.

**Where a type cannot occur.** A cell has no joint extremes, and no return period, on days when a precondition of the type is absent, such as Avalanche without snow (Step 3). Those cell-days are left out of the peak intensity. Where no cell of a country has a return period in a year, such as for Avalanche in a country without snow, extreme area-days and peak extent are 0 and the peak intensity is left empty (NULL). A return period of 0 would wrongly suggest that the type was measured there and found mild.

### Differences from the reference studies

The reference studies used hydrological simulations from the Variable Infiltration Capacity (VIC) model at 1/16° (about 6 km), driven by downscaled CMIP5 Earth System Model scenarios. Their historical period was 1970–1999 and their study area was the Colorado River basin (Bennett et al., 2021, §2.2–2.3; Boero et al., 2022, §2.1.1). Here the inputs are ERA5 reanalysis at 0.25° (about 28 km), the baseline is 1950–1979, and the domain is global. Copulas are fitted for each grid cell rather than for each watershed (Step 3). Only the Archimedean copula families are candidates (Step 3).

### References

- Akaike, H. (1974). A new look at the statistical model identification. *IEEE Transactions on Automatic Control*, 19(6), 716–723. https://doi.org/10.1109/TAC.1974.1100705
- Barbe, P.; Genest, C.; Ghoudi, K.; Rémillard, B. (1996). On Kendall's process. *Journal of Multivariate Analysis*, 58(2), 197–229. https://doi.org/10.1006/jmva.1996.0048
- Bennett, K.E.; Talsma, C.; Boero, R. (2021). Concurrent Changes in Extreme Hydroclimate Events in the Colorado River Basin. *Water*, 13(7), 978. https://doi.org/10.3390/w13070978
- Boero, R.; Talsma, C.J.; Oliveto, J.A.; Bennett, K.E. (2022). Expectations of Future Natural Hazards in Human Adaptation to Concurrent Extreme Events in the Colorado River Basin. *Climate*, 10(2), 27. https://doi.org/10.3390/cli10020027
- Brockwell, A.E. (2007). Universal residuals: A multivariate transformation. *Statistics & Probability Letters*, 77(14), 1473–1478. https://doi.org/10.1016/j.spl.2007.02.008
- Genest, C.; Rivest, L.-P. (1993). Statistical inference procedures for bivariate Archimedean copulas. *Journal of the American Statistical Association*, 88(423), 1034–1043. https://doi.org/10.1080/01621459.1993.10476372
- Salvadori, G.; De Michele, C.; Durante, F. (2011). On the return period and design in a multivariate framework. *Hydrology and Earth System Sciences*, 15(11), 3293–3305. https://doi.org/10.5194/hess-15-3293-2011
- Stagge, J.H.; Tallaksen, L.M.; Gudmundsson, L.; Van Loon, A.F.; Stahl, K. (2015). Candidate distributions for climatological drought indices (SPI and SPEI). *International Journal of Climatology*, 35(13), 4027–4040. https://doi.org/10.1002/joc.4267
- Zhang, X.; Alexander, L.; Hegerl, G.C.; Jones, P.; Klein Tank, A.; Peterson, T.C.; Trewin, B.; Zwiers, F.W. (2011). Indices for monitoring changes in extremes based on daily temperature and precipitation data. *WIREs Climate Change*, 2(6), 851–870. https://doi.org/10.1002/wcc.147

## Data limitations and assumptions

### Hazard

- **Baseline period 1950–1979.** Climatological references for the hazard data, such as the per-cell marginal distributions, copulas and joint thresholds, are derived from the 1950–1979 baseline. ERA5 assimilated no satellite observations before 1979, so in regions with sparse station coverage, notably much of Africa and parts of the southern hemisphere, the baseline is less reliable. This is accepted as a known limitation.
- **Storm subtypes the hazard data cannot characterise.** For four EM-DAT storm subtypes, ERA5 at 0.25° and daily resolution has no usable signal:
  - `Tornado` (277 events, 1980–2025) and `Hail` (108) occur at scales far below a 28 km grid cell.
  - `Sand/Dust storm` (26) has no dust variable among the downloaded ones.
  - `Storm surge` (10) is a sea-level phenomenon, and sea cells are not aggregated.

  The names are EM-DAT's exact `Disaster Subtype` values, so these 421 events can be identified and left out wherever hazard is used to study them.
- **Indicators missing at the start of the baseline.** Indicators with a look-back window have no value until the window is full, so the first days of 1950 lack some indicators: up to 89 days for the 90-day drought window. Baseline references are therefore built from slightly less than the full 30 years for those indicators. The main period, 1980–2025, is not affected.
- **Return periods count days, not events.** Peak intensity is a return period computed from daily probabilities. Consecutive days of one event are not independent, so the return period gives how often a day at least that extreme occurs at a cell, not how often a separate event of that severity occurs. This is accepted because the national values describe days and area, and events are not separated in the hazard data.
- **Dry-day counts carry little information in cells that are dry on almost every day.** In such cells, mostly hyper-arid deserts, the count of dry days over 90 days is at or near its maximum in most of the baseline, so its random spread over tied values (Step 3) is wide and the indicator barely tells drought years apart. Drought there is characterised mainly by its other two indicators, temperature and soil moisture.
- **One dependence strength per event type and cell.** Copulas are limited to the four Archimedean families, for computational reasons (Step 3). Each has a single parameter, so all indicator pairs of an event type in a cell share one dependence strength. Where some pairs are strongly dependent and others weakly, the fitted strength is a compromise between them. In Flood, for example, 1-day and 5-day precipitation are strongly dependent, while deep soil moisture depends less on a single day's rain. Nor can these families represent indicators that move in opposite directions once there are three or more: Gumbel and Joe allow no negative dependence, Frank allows it only for two indicators, and Clayton allows only a little. Where an event type's indicators move apart, such as maximum temperature and dewpoint for Heat in arid places, where hot days are dry, the fit falls back to near-independence, and joint extremes are judged as if the indicators were unrelated.
- **Coastal floods are not characterised.** The EM-DAT `Disaster Subtype` `Coastal flood` (80 events, 1980–2025) is driven by storm surge, tides and sea level, none of which is among the downloaded variables, and sea cells are not aggregated. The flood indicators (rain, runoff, soil moisture) do not describe it. These events can be identified by their `Disaster Subtype` and left out.
- **Flash floods are only partly characterised.** For the EM-DAT `Disaster Subtype` `Flash flood` (904 events, 1980–2025), the heavy rain behind an event shows up in the flood indicators. But many flash floods last only hours and hit small catchments, below the daily, 0.25° resolution of the data, so the hazard can understate them.
- **Avalanches are only partly characterised.** For the EM-DAT `Disaster Subtype` `Avalanche (wet)` (109 events, 1980–2025), the avalanche definition captures snowfall, snowpack and warming over a whole grid cell. Avalanches happen on single slopes, far below the 0.25° cell size, so the hazard describes conditions across the area, not the slope that failed.
- **Late frosts are not characterised as cold extremes.** Cold uses a whole-year baseline reference, so an unusually cold spell outside the cold season, such as a late spring frost that damages crops, is not extreme against the coldest days of the year. EM-DAT cold waves of this kind are understated by the hazard.
- **Glacial lake outburst floods are not characterised.** The EM-DAT `Disaster Type` `Glacial lake outburst flood` (8 events, 1980–2025) has no hazard definition. A failure of a glacial lake's ice or moraine dam depends on glacier and lake dynamics that none of the downloaded variables describe, and the lakes are far smaller than a grid cell. Heat or heavy rain can trigger a failure but do not explain it. These events can be identified by their `Disaster Type` and left out.
