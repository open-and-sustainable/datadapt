module DatAdapt

using DataFrames

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

function transform_data(table::String)
    if table == "damage"
        # Process the "damage" table
        D_processed = DatabaseAccess.executePRQL(DB_PATH_RAW, "src/DataTransform/damage_country_event_year.prql")
        DatabaseAccess.with_connection(DB_PATH_PROCESSED) do con
            DatabaseAccess.write_duckdb_table!(D_processed, con, "damage_country_event_year")
            DatabaseAccess.update_metadata!(con, "damage_country_event_year",
                START_YEAR, END_YEAR, "derived from raw damage table")
        end
    elseif table == "exposure"
        # Process the "exposure" table
        E_processed = DatabaseAccess.executePRQL(DB_PATH_RAW, "src/DataTransform/exposure_country_year.prql")
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
