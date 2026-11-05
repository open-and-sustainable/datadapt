module DatAdapt

using DataFrames
using DuckDB: DBInterface

# Time period covered by the database; actual table coverage is
# recorded in each database's metadata table
const START_YEAR = 1980
const END_YEAR = 2025
const BASELINE_START_YEAR = 1950
const BASELINE_END_YEAR = 1979

# Define the database paths as constants
const DB_PATH_RAW = "DatAdapt-database/raw/DatAdapt.duckdb"
# The baseline period is written to its own raw database whose name differs
# from the main one only by the period suffix. The non-baseline extraction
# keeps using DatAdapt.duckdb unchanged, and the two periods can be downloaded
# in parallel without contending for the same DuckDB file.
const DB_PATH_RAW_BASELINE = "DatAdapt-database/raw/DatAdapt_$(BASELINE_START_YEAR)-$(BASELINE_END_YEAR).duckdb"
const DB_PATH_PROCESSED = "DatAdapt-database/processed/DatAdapt.duckdb"

# Include and use the renamed modules
include("CDSAPI.jl")
include("DatabaseAccess.jl")
include("ExposureDataFetch.jl")
include("DamageDataFetch.jl")
include("HazardDataFetch.jl")
include("CountryMapping.jl")

using .CDSAPI: logmsg
using .DatabaseAccess
using .ExposureDataFetch
using .DamageDataFetch
using .HazardDataFetch

function fetch_exposure_data()
    E_data = ExposureDataFetch.fetch_exposure_data(START_YEAR, END_YEAR)
    DatabaseAccess.with_connection(DB_PATH_RAW) do con
        DatabaseAccess.write_duckdb_table!(E_data, con, "exposure")
        DatabaseAccess.update_metadata!(con, "exposure", START_YEAR, END_YEAR,
            "World Bank WDI API")
    end
end

function fetch_damage_data()
    D_data = DamageDataFetch.fetch_damage_data(START_YEAR, END_YEAR)
    DatabaseAccess.with_connection(DB_PATH_RAW) do con
        DatabaseAccess.write_duckdb_table!(D_data, con, "damage")
        DatabaseAccess.update_metadata!(con, "damage", START_YEAR, END_YEAR,
            "EM-DAT, CRED / UCLouvain (www.emdat.be)")
    end
end

const HAZARD_SOURCE = "ERA5 post-processed daily statistics, Copernicus CDS"

function fetch_hazard_data()
    load_hazard_years("hazard", START_YEAR, END_YEAR)
end

function fetch_baseline_hazard_data()
    load_hazard_years("hazard_baseline", BASELINE_START_YEAR, BASELINE_END_YEAR,
        DB_PATH_RAW_BASELINE)
end

# Years fetched before the pipeline began retaining the gridded downloads: the
# country-level data is in the database but the ERA5 files behind it were
# deleted after aggregation. 1987 lost only one of its fourteen files, the
# others lost all of theirs. Listed explicitly rather than detected, because a
# grid already moved to archival storage is equally absent from disk and must
# not be fetched a second time.
const MISSING_GRID_YEARS = [1980, 1981, 1982, 1983, 1984, 1985, 1986, 2000]
const MISSING_GRID_EXTRA = [(1987, "2m_temperature", "daily_minimum")]

function backfill_hazard_grids()
    items = [(year, variable, statistic)
             for year in MISSING_GRID_YEARS
             for (variable, statistic) in HazardDataFetch.VARIABLE_STATS]
    append!(items, MISSING_GRID_EXTRA)
    HazardDataFetch.backfill_grids(items)
end

# Hazard spans decades of daily country-level rows, far more than is
# comfortable to hold in memory at once, so each year is written to the
# database as it completes and then released. The connection stays open for
# the whole run: DuckDB autocommits each statement, so a year is durable once
# written, while reopening the file mid-process is not reliably durable (see
# update_metadata!).
function load_hazard_years(table::String, start_year::Int, end_year::Int,
        db_path::String=DB_PATH_RAW)
    DatabaseAccess.with_connection(db_path) do con
        HazardDataFetch.fetch_hazard_data(start_year, end_year) do year, df
            DatabaseAccess.replace_year_in_duckdb_table!(df, con, table, year)
            covered = DatabaseAccess.table_year_range(con, table)
            if covered !== nothing
                DatabaseAccess.update_metadata!(con, table, covered[1], covered[2],
                    HAZARD_SOURCE)
            end
            logmsg("Wrote $year to table $table ($(nrow(df)) rows); " *
                   "coverage now $(covered === nothing ? "unknown" : "$(covered[1])-$(covered[2])").")
        end
    end
end

# Hazard re-aggregated on the country map shared with damage and exposure
# (GADM 4.1 merged by country_mappings/hazard_units.csv) goes to tables of its
# own beside the Natural Earth ones, so a run spread over many days never
# leaves a table that mixes the two maps. switch_hazard_tables puts them in
# place once every year is in.
const HAZARD_GADM_SOURCE = HAZARD_SOURCE *
    "; countries: GADM 4.1 merged by country_mappings/hazard_units.csv"

hazard_tables(year::Int) =
    BASELINE_START_YEAR <= year <= BASELINE_END_YEAR ?
        (DB_PATH_RAW_BASELINE, "hazard_baseline") : (DB_PATH_RAW, "hazard")

"""
    reaggregate_hazard(year; grid_dir) -> nothing

Re-aggregate one year's grids to the shared country map and write it to the
`_gadm` table of its period's raw database. Errors, writing nothing, if any of
the year's grids is missing from `grid_dir`.
"""
function reaggregate_hazard(year::Int; grid_dir::String = HazardDataFetch.GRID_DIR)
    df = HazardDataFetch.reaggregate_year(year; grid_dir)
    df === nothing && error("Grids for $year are incomplete in $grid_dir; nothing written.")
    db_path, table = hazard_tables(year)
    table *= "_gadm"
    DatabaseAccess.with_connection(db_path) do con
        DatabaseAccess.replace_year_in_duckdb_table!(df, con, table, year)
        covered = DatabaseAccess.table_year_range(con, table)
        DatabaseAccess.update_metadata!(con, table, covered[1], covered[2], HAZARD_GADM_SOURCE)
    end
    logmsg("Wrote $year to table $table in $db_path ($(nrow(df)) rows).")
    return nothing
end

"""
    switch_hazard_tables() -> nothing

Replace each period's Natural Earth hazard table with its re-aggregated
`_gadm` table. Refuses, changing nothing in that database, unless the `_gadm`
table holds every year of the period.
"""
function switch_hazard_tables()
    for (db_path, table, first_year, last_year) in
            ((DB_PATH_RAW, "hazard", START_YEAR, END_YEAR),
             (DB_PATH_RAW_BASELINE, "hazard_baseline", BASELINE_START_YEAR, BASELINE_END_YEAR))
        if !isfile(db_path)
            logmsg("$db_path does not exist; not switched.")
            continue
        end
        DatabaseAccess.with_connection(db_path) do con
            exists = DataFrame(DBInterface.execute(con,
                "SELECT count(*) AS n FROM information_schema.tables " *
                "WHERE table_name = '$(table)_gadm'")).n[1] > 0
            if !exists
                logmsg("$db_path: $(table)_gadm does not exist; not switched.")
                return
            end
            years = DataFrame(DBInterface.execute(con,
                "SELECT DISTINCT EXTRACT(YEAR FROM date)::INTEGER AS y FROM $(table)_gadm")).y
            absent = setdiff(first_year:last_year, years)
            if !isempty(absent)
                logmsg("$db_path: $(table)_gadm lacks $(length(absent)) years ($(absent)); not switched.")
                return
            end
            DBInterface.execute(con, "DROP TABLE IF EXISTS $table")
            DBInterface.execute(con, "ALTER TABLE $(table)_gadm RENAME TO $table")
            DBInterface.execute(con, "DELETE FROM metadata WHERE table_name = '$(table)_gadm'")
            DatabaseAccess.update_metadata!(con, table, first_year, last_year, HAZARD_GADM_SOURCE)
            logmsg("$db_path: $table now holds the re-aggregated data.")
        end
    end
    return nothing
end

function transform_data(table::String)
    if table == "damage"
        # Process the "damage" table, with each event assigned to the
        # present-day country it occurred in
        damage = DatabaseAccess.with_connection(DB_PATH_RAW) do con
            DataFrame(DBInterface.execute(con, "SELECT * FROM damage"))
        end
        located = CountryMapping.locate_damage_events(damage)
        D_processed = DatabaseAccess.executePRQL(DB_PATH_RAW,
            "src/DataTransform/damage_country_event_year.prql";
            tables = Dict("damage_located" => located))
        DatabaseAccess.with_connection(DB_PATH_PROCESSED) do con
            DatabaseAccess.write_duckdb_table!(D_processed, con, "damage_country_event_year")
            DatabaseAccess.update_metadata!(con, "damage_country_event_year",
                START_YEAR, END_YEAR, "derived from raw damage table")
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
                START_YEAR, END_YEAR, "derived from raw exposure table")
        end
    elseif table == "hazard"
        # Process the "hazard" table
        H_processed = DatabaseAccess.executePRQL(DB_PATH_RAW, "src/DataTransform/hazard_country_year.prql")
        DatabaseAccess.with_connection(DB_PATH_PROCESSED) do con
            DatabaseAccess.write_duckdb_table!(H_processed, con, "hazard_country_year")
            DatabaseAccess.update_metadata!(con, "hazard_country_year",
                START_YEAR, END_YEAR, "derived from raw hazard table")
        end
    else
        println("Table name not recognized. Please provide a valid table name.")
    end
end

end # module DatAdapt
