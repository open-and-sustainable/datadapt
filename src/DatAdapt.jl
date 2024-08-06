module DatAdapt

using DataFrames
#using DuckDB

# Include and use the renamed modules
include("DataFetch.jl")
include("DatabaseAccess.jl")
#include("DataCleaning.jl")

using .DataFetch
using .DatabaseAccess
#using .DataCleaning


export fetch_exposure_data

function fetch_exposure_data()
    # wb_test_data = DataFetch.fetch_WB_test_data()
    # write_duckdb_table(wb_test_data, db_path, "wb_test_data")
    db_path = "data/raw/DatAdapt_1990-2021.duckdb"
    E_data = DataFetch.fetch_exposure_data(1980, 2021)
    write_duckdb_table(E_data, db_path, "exposure")
end

function clean_data(df::DataFrame)
    return DataCleaning.clean_data(df)
end

function transform_data(df::DataFrame)
    return DataCleaning.transform_data(df)
end

function setup_database()
    DatabaseSetup.setup()
end

end # module DatAdapt
