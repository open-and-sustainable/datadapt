module DatAdapt

using DataFrames

# Time period covered by the database
const START_YEAR = 1980
const END_YEAR = 2025

# Define the database paths as constants
const DB_PATH_RAW = "DatAdapt-database/raw/DatAdapt_$(START_YEAR)-$(END_YEAR).duckdb"
const DB_PATH_PROCESSED = "DatAdapt-database/processed/DatAdapt_$(START_YEAR)-$(END_YEAR).duckdb"

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
    # wb_test_data = DataFetch.fetch_WB_test_data()
    # write_duckdb_table(wb_test_data, db_path, "wb_test_data")
    E_data = ExposureDataFetch.fetch_exposure_data(START_YEAR, END_YEAR)
    DatabaseAccess.write_duckdb_table!(E_data, DB_PATH_RAW, "exposure")
end

function fetch_damage_data()
    D_data = DamageDataFetch.fetch_damage_data(START_YEAR, END_YEAR)
    DatabaseAccess.write_duckdb_table!(D_data, DB_PATH_RAW, "damage")
end

function fetch_hazard_data()
    H_data = HazardDataFetch.fetch_hazard_data(START_YEAR, END_YEAR)
    DatabaseAccess.write_large_duckdb_table!(H_data, DB_PATH_RAW, "hazard")
end

function fetch_baseline_hazard_data()
    H_BL_data = HazardDataFetch.fetch_hazard_data(1950, 1979)
    DatabaseAccess.write_large_duckdb_table!(H_BL_data, DB_PATH_RAW, "hazard_baseline")
end

function transform_data(table::String)
    if table == "damage"
        # Process the "damage" table
        D_processed = DatabaseAccess.executePRQL(DB_PATH_RAW, "src/DataTransform/damage_country_event_year.prql")
        DatabaseAccess.write_duckdb_table!(D_processed, DB_PATH_PROCESSED, "damage_country_event_year")
    elseif table == "exposure"
        # Process the "exposure" table
        E_processed = DatabaseAccess.executePRQL(DB_PATH_RAW, "src/DataTransform/exposure_country_year.prql")
        DatabaseAccess.write_duckdb_table!(E_processed, DB_PATH_PROCESSED, "exposure_country_year")
    elseif table == "hazard"
        # Process the "hazard" table
        H_processed = DatabaseAccess.executePRQL(DB_PATH_RAW, "src/DataTransform/hazard_country_year.prql")
        DatabaseAccess.write_duckdb_table!(H_processed, DB_PATH_PROCESSED, "hazard_country_year")
    else
        println("Table name not recognized. Please provide a valid table name.")
    end
end

end # module DatAdapt
