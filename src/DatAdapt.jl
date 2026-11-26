module DatAdapt

using DataFrames
import Dates
import DuckDB
using DuckDB: DBInterface

# Time period covered by the database; actual table coverage is
# recorded in each database's metadata table
const START_YEAR = 1980
const END_YEAR = 2025
# The hazard grids also cover the baseline 1950-1979, which the national
# values are measured against (docs/raw/hazard.md, Step 1)
const BASELINE_START_YEAR = 1950

# Define the database paths as constants
const DB_PATH_RAW = "DatAdapt-database/raw/DatAdapt.duckdb"
const DB_PATH_PROCESSED = "DatAdapt-database/processed/DatAdapt.duckdb"
# The raw EM-DAT records live in their own local file, which the dataset
# repository ignores: EM-DAT's licence does not allow redistributing them
const DB_PATH_DAMAGE = "DatAdapt-database/raw/DatAdapt_damage.duckdb"

# Include and use the renamed modules
include("CDSAPI.jl")
include("DatabaseAccess.jl")
include("ExposureDataFetch.jl")
include("DamageDataFetch.jl")
include("HazardDataFetch.jl")
include("HazardTransform.jl")
include("CountryMapping.jl")

using .CDSAPI: logmsg
using .DatabaseAccess
using .ExposureDataFetch
using .DamageDataFetch
using .HazardDataFetch

# Citations of the three sources for the metadata tables, as in "Data
# sources" on the documentation website; the metadata column `updated`
# gives the date of access
const EXPOSURE_SOURCE = "The World Bank: World Development Indicators, " *
    "https://datatopics.worldbank.org/world-development-indicators/, " *
    "licensed under CC BY 4.0; original sources of each indicator in " *
    "https://open-and-sustainable.github.io/datadapt/raw/exposure.html"
const DAMAGE_SOURCE = "Emergency Events Database (EM-DAT), UCLouvain / CRED, " *
    "Brussels, Belgium, https://www.emdat.be/; Delforge, D., Wathelet, V., " *
    "Below, R., Lanfredi Sofia, C., Tonnelier, M., van Loenhout, J. A. F., & " *
    "Speybroeck, N. (2025). EM-DAT: The Emergency Events Database. " *
    "International Journal of Disaster Risk Reduction, 124, 105509. " *
    "https://doi.org/10.1016/j.ijdrr.2025.105509"
# The Copernicus notice names the year the data are generated in
hazard_source(year::Int = Dates.year(Dates.today())) =
    "Copernicus Climate Change Service, Climate Data Store (2024): ERA5 " *
    "post-processed daily statistics on single levels from 1940 to present. " *
    "Copernicus Climate Change Service (C3S) Climate Data Store (CDS). " *
    "https://doi.org/10.24381/cds.4991cf48, licensed under CC BY 4.0; " *
    "national values by src/HazardTransform.jl " *
    "(https://open-and-sustainable.github.io/datadapt/raw/hazard.html). " *
    "Generated using Copernicus Climate Change Service information $year. " *
    "Neither the European Commission nor ECMWF is responsible for any use " *
    "that may be made of the Copernicus information or data it contains."

function fetch_exposure_data()
    E_data = ExposureDataFetch.fetch_exposure_data(START_YEAR, END_YEAR)
    DatabaseAccess.with_connection(DB_PATH_RAW) do con
        DatabaseAccess.write_duckdb_table!(E_data, con, "exposure")
        DatabaseAccess.update_metadata!(con, "exposure", START_YEAR, END_YEAR,
            EXPOSURE_SOURCE)
    end
end

function fetch_damage_data()
    D_data = DamageDataFetch.fetch_damage_data(START_YEAR, END_YEAR)
    DatabaseAccess.with_connection(DB_PATH_DAMAGE) do con
        DatabaseAccess.write_duckdb_table!(D_data, con, "damage")
        DatabaseAccess.update_metadata!(con, "damage", START_YEAR, END_YEAR,
            DAMAGE_SOURCE)
    end
end

const WPP_SOURCE = "United Nations, Department of Economic and Social Affairs, " *
    "Population Division (2024). World Population Prospects 2024, Online " *
    "Edition. https://population.un.org/wpp/, licensed under CC BY 3.0 IGO; " *
    "estimates to 2023, medium-variant projections from 2024"

# Population and life expectancy by single age, for the life years lost to
# disaster deaths in the damage domain. The UN files are large (about 530
# MB); pass `dir` to keep them between runs.
function fetch_life_table_data(; dir::String = mktempdir())
    population, life_expectancy =
        DamageDataFetch.fetch_life_table_data(START_YEAR, END_YEAR; dir = dir)
    DatabaseAccess.with_connection(DB_PATH_RAW) do con
        DatabaseAccess.write_duckdb_table!(population, con, "population_by_age")
        DatabaseAccess.update_metadata!(con, "population_by_age", START_YEAR, END_YEAR,
            WPP_SOURCE)
        DatabaseAccess.write_duckdb_table!(life_expectancy, con, "life_expectancy_by_age")
        DatabaseAccess.update_metadata!(con, "life_expectancy_by_age", START_YEAR, END_YEAR,
            WPP_SOURCE)
    end
end

# Hazard comes in two steps. The fetch only downloads the ERA5 grids, for the
# baseline 1950-1979 and the main period alike, since the national values are
# computed from the grids cell by cell; compute_hazard_national then writes
# those values to the raw database.
function fetch_hazard_data()
    HazardDataFetch.fetch_hazard_data(BASELINE_START_YEAR, END_YEAR)
end

"""
    compute_hazard_national() -> nothing

Combine the checkpoints of every latitude band into the national annual
hazard values (`HazardTransform.hazard_country_year`) and write them to the
table `hazard` of the raw database, from which `transform_data("hazard")`
makes the processed table. The bands are computed first by
`HazardTransform.run_bands`, in several processes: run
compute_hazard_national.sh, which does both. Errors, writing nothing, if any
band is not done.
"""
function compute_hazard_national()
    national = HazardTransform.hazard_country_year()
    DatabaseAccess.with_connection(DB_PATH_RAW) do con
        DatabaseAccess.write_duckdb_table!(national, con, "hazard")
        DatabaseAccess.update_metadata!(con, "hazard", START_YEAR, END_YEAR, hazard_source())
    end
    logmsg("Wrote $(nrow(national)) rows to table hazard in $DB_PATH_RAW.")
    return nothing
end

# Deaths and injuries of the processed damage table are valued in money
# (docs/processed/damage.md). A death is worth the life years the country's
# population had left that year, each valued at the country's GNI per capita of
# the year and discounted at DISCOUNT_RATE; a conservative lower bound for the
# value of a statistical life (VSL).
const DISCOUNT_RATE = 0.03
# An injury is worth INJURY_SHARE of a death: the value of a moderate injury
# (MAIS 2) in US Department of Transportation, Departmental Guidance: Treatment
# of the Value of Preventing Fatalities and Injuries in Preparing Economic
# Analyses (March 2021), Table 2.
const INJURY_SHARE = 0.047
# GNI per capita, Atlas method (current US$), from the raw exposure table
const GNI_PER_CAPITA = "NY.GNP.PCAP.CD"
# The World Bank has no GNI per capita for Taiwan or North Korea, and their
# neighbours' are far from theirs, so their losses are not valued.
const NOT_VALUED = Set(["TWN", "PRK"])

# The present value of T years, one a year from now, at rate r: what a
# death costs in years of income
present_years(T::Real, r::Real) = (1 - (1 + r)^(-T)) / r

"""
    discounted_life_years(rows, r) -> Dict{Tuple{String, Int}, Float64}

The present value of the life years a death costs in each country and year,
at rate `r`: `present_years` of the life expectancy at each age, averaged with
the population of each age as weights, so a victim is taken to be of the
population's age. `rows` holds `code`, `year`, the population `pop` and the
life expectancy `ex` of each age; a country that several rows' codes belong
to (France with its overseas departments) is averaged over all of them.
"""
function discounted_life_years(rows::DataFrame, r::Real)
    totals = Dict{Tuple{String, Int}, Tuple{Float64, Float64}}()
    for row in eachrow(rows)
        key = (String(row.code), Int(row.year))
        weighted, pop = get(totals, key, (0.0, 0.0))
        totals[key] = (weighted + row.pop * present_years(row.ex, r), pop + row.pop)
    end
    return Dict(key => weighted / pop for (key, (weighted, pop)) in totals if pop > 0)
end

"""
    value_human_losses(damage) -> DataFrame

Add to the processed damage table the money value of its deaths and injuries,
in thousands of US dollars at EM-DAT's constant prices like
`total_damage_adjusted`:

- `vsl`: the value of one death in the country and year, its discounted life
  years times its GNI per capita, brought to constant prices with EM-DAT's
  `CPI` (× 100 / CPI);
- `deaths_value` and `injuries_value`: `total_deaths` × `vsl` and
  `total_injured` × INJURY_SHARE × `vsl`;
- `total_damage_monetized`: `total_damage_adjusted` + `deaths_value` +
  `injuries_value`.

A country and year with no GNI per capita, or no life table, takes the average
of its land neighbours, or the nearest country's for an island
(`CountryMapping.fill_from_map`). The columns are empty for the countries in
NOT_VALUED.
"""
function value_human_losses(damage::DataFrame)
    exposure, rows = DatabaseAccess.with_connection(DB_PATH_RAW; readonly = true) do con
        (DataFrame(DBInterface.execute(con,
             "SELECT * FROM exposure WHERE indicator = '$GNI_PER_CAPITA'")),
         DataFrame(DBInterface.execute(con, """
             SELECT p.ISO3_code AS code, p.Time AS year, p.PopTotal AS pop, l.ex AS ex
             FROM population_by_age p
             JOIN life_expectancy_by_age l USING (ISO3_code, Time, AgeGrpStart)""")))
    end
    exposure = CountryMapping.locate_exposure(exposure)
    gni = Dict((row.country_code, row.year) => row.value
               for row in eachrow(exposure) if !ismissing(row.value))
    un_codes = CountryMapping.life_table_codes(HazardDataFetch.HAZARD_UNITS_PATH)
    on_map = Dict(zip(un_codes.un_code, un_codes.code))
    rows.code = [get(on_map, code, code) for code in rows.code]
    life_years = discounted_life_years(rows, DISCOUNT_RATE)

    country_years = [(String(row.ISO), Int(row."Start Year")) for row in eachrow(damage)]
    filled = [!(code in NOT_VALUED) && !(haskey(gni, (code, year)) && haskey(life_years, (code, year)))
              for (code, year) in country_years]
    lacking = unique(first.(country_years[filled]))
    neighbours = isempty(lacking) ? Dict{String, NamedTuple}() :
        HazardDataFetch.map_neighbours(lacking)

    valued = copy(damage)
    valued.vsl = map(zip(country_years, damage.CPI)) do ((code, year), cpi)
        code in NOT_VALUED && return missing
        income = CountryMapping.fill_from_map(gni, code, year, neighbours)
        years = CountryMapping.fill_from_map(life_years, code, year, neighbours)
        return years * income * 100 / cpi / 1000
    end
    valued.deaths_value = valued.total_deaths .* valued.vsl
    valued.injuries_value = valued.total_injured .* INJURY_SHARE .* valued.vsl
    valued.total_damage_monetized =
        valued.total_damage_adjusted .+ valued.deaths_value .+ valued.injuries_value
    logmsg("Valued deaths and injuries of $(nrow(valued)) rows; $(count(filled)) rows take " *
           "neighbouring countries' GNI per capita or life table, " *
           "$(count(ismissing, valued.vsl)) are not valued.")
    return valued
end

function transform_data(table::String)
    if table == "damage"
        # Process the "damage" table, with each event assigned to the
        # present-day country it occurred in
        damage = DatabaseAccess.with_connection(DB_PATH_DAMAGE) do con
            DataFrame(DBInterface.execute(con, "SELECT * FROM damage"))
        end
        located = CountryMapping.locate_damage_events(damage)
        D_processed = DatabaseAccess.executePRQL(DB_PATH_DAMAGE,
            "src/DataTransform/damage_country_event_year.prql";
            tables = Dict("damage_located" => located))
        nrow(D_processed) > 0 || error("The damage PRQL step returned no rows; nothing written.")
        D_processed = value_human_losses(D_processed)
        DatabaseAccess.with_connection(DB_PATH_PROCESSED) do con
            DatabaseAccess.write_duckdb_table!(D_processed, con, "damage_country_event_year")
            DatabaseAccess.update_metadata!(con, "damage_country_event_year",
                START_YEAR, END_YEAR,
                "Derived from the raw tables damage, population_by_age, " *
                "life_expectancy_by_age and exposure. Sources: " * DAMAGE_SOURCE *
                "; " * WPP_SOURCE * "; " * EXPOSURE_SOURCE)
        end
    elseif table == "exposure"
        # Process the "exposure" table, countries only, with codes aligned
        # to the ones used for damage
        exposure = DatabaseAccess.with_connection(DB_PATH_RAW) do con
            DataFrame(DBInterface.execute(con, "SELECT * FROM exposure"))
        end
        located = CountryMapping.locate_exposure(exposure)
        E_processed = DatabaseAccess.executePRQL(DB_PATH_RAW,
            "src/DataTransform/exposure_country_year.prql";
            tables = Dict("exposure_located" => located))
        DatabaseAccess.with_connection(DB_PATH_PROCESSED) do con
            DatabaseAccess.write_duckdb_table!(E_processed, con, "exposure_country_year")
            DatabaseAccess.update_metadata!(con, "exposure_country_year",
                START_YEAR, END_YEAR, "Derived from the raw exposure table. Source: " * EXPOSURE_SOURCE)
        end
    elseif table == "hazard"
        # Process the national hazard values of the raw database (see
        # compute_hazard_national); adjustments for the processed database
        # go in the PRQL step
        H_processed = DatabaseAccess.executePRQL(DB_PATH_RAW,
            "src/DataTransform/hazard_country_year.prql")
        nrow(H_processed) > 0 || error("The hazard PRQL step returned no rows; nothing written.")
        DatabaseAccess.with_connection(DB_PATH_PROCESSED) do con
            DatabaseAccess.write_duckdb_table!(H_processed, con, "hazard_country_year")
            DatabaseAccess.update_metadata!(con, "hazard_country_year",
                START_YEAR, END_YEAR, "Derived from the raw hazard table. Source: " * hazard_source())
        end
    else
        println("Table name not recognized. Please provide a valid table name.")
    end
end

end # module DatAdapt
