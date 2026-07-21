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
const DB_PATH_PROCESSED = "DatAdapt-database/processed/DatAdapt.duckdb"

# Include and use the renamed modules
include("CDSAPI.jl")
include("DatabaseAccess.jl")
include("ExposureDataFetch.jl")
include("DamageDataFetch.jl")
include("HazardDataFetch.jl")

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

function fetch_hazard_data()
    H_data = HazardDataFetch.fetch_hazard_data(START_YEAR, END_YEAR)
    DatabaseAccess.with_connection(DB_PATH_RAW) do con
        DatabaseAccess.write_large_duckdb_table!(H_data, con, "hazard")
        DatabaseAccess.update_metadata!(con, "hazard", START_YEAR, END_YEAR,
            "ERA5 post-processed daily statistics, Copernicus CDS")
    end
end

function fetch_baseline_hazard_data()
    H_BL_data = HazardDataFetch.fetch_hazard_data(BASELINE_START_YEAR, BASELINE_END_YEAR)
    DatabaseAccess.with_connection(DB_PATH_RAW) do con
        DatabaseAccess.write_large_duckdb_table!(H_BL_data, con, "hazard_baseline")
        DatabaseAccess.update_metadata!(con, "hazard_baseline",
            BASELINE_START_YEAR, BASELINE_END_YEAR,
            "ERA5 post-processed daily statistics, Copernicus CDS")
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
