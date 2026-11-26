module DatabaseAccess

using DuckDB
using DataFrames
using Dates

export write_duckdb_table!, executePRQL, with_connection

# Open db_path, run f(con), and guarantee the connection is closed
# afterwards. Writes that must land in the same durability unit (e.g.
# a table write followed by its metadata update) should share the
# connection passed into f rather than opening the file again. Open with
# `readonly = true` to only read: DuckDB rewrites a file it opened for
# writing when it closes it, even if nothing changed.
function with_connection(f::Function, db_path::String; readonly::Bool = false)
    config = DuckDB.Config()
    readonly && DuckDB.set_config(config, "access_mode", "READ_ONLY")
    con = DuckDB.DB(db_path, config)
    try
        return f(con)
    finally
        DBInterface.close!(con)
    end
end

function escape_sql_string(value::String)::String
    # Manually escape single quotes by doubling them
    escaped_value = "'"
    for char in value
        if char == '\''
            escaped_value *= "''"
        else
            escaped_value *= string(char)
        end
    end
    escaped_value *= "'"
    return escaped_value
end

# Julia column types DuckDB stores as they are. A column of any other type,
# such as the Any columns of a spreadsheet read as is, is stored as text.
const NATIVE_TYPES = Union{Bool, Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64,
                           Float32, Float64, String, Dates.Date, Dates.DateTime}

as_text(column) = Union{Missing, String}[(x === missing || x === nothing) ? missing : string(x)
                                         for x in column]

"""
    write_duckdb_table!(df, con, table_name) -> nothing

Write `df` to the table `table_name`, replacing any table of that name. Each
column keeps its type, with missing values as NULL; a column of a type DuckDB
does not store natively is written as text.
"""
function write_duckdb_table!(df::DataFrame, con::DuckDB.DB, table_name::String)
    out = DataFrame()
    for name in names(df)
        column = df[!, name]
        T = nonmissingtype(eltype(column))
        out[!, name] = (T !== Union{} && T <: NATIVE_TYPES) ? column : as_text(column)
    end
    view = table_name * "_new"
    DuckDB.register_data_frame(con, out, view)
    try
        DBInterface.execute(con,
            "CREATE OR REPLACE TABLE \"$table_name\" AS SELECT * FROM \"$view\"")
    finally
        DuckDB.unregister_data_frame(con, view)
    end
    return nothing
end

# Record (or refresh) the period and provenance of a table in the
# database's metadata table, so coverage lives in the data rather
# than in file names. Must run on the same connection used to write
# the table: reopening a DuckDB file via a second DuckDB.DB(path) call
# within one process is not reliably durable once the first
# connection's local variable goes out of scope (its finalizer can
# run at an unpredictable time relative to the second connection),
# silently losing writes made through the second connection.
function update_metadata!(con::DuckDB.DB, table_name::String,
                          start_year::Int, end_year::Int, source::String)
    DBInterface.execute(con, """
        CREATE TABLE IF NOT EXISTS metadata (
            table_name STRING,
            start_year INTEGER,
            end_year INTEGER,
            source STRING,
            updated DATE
        )""")
    DBInterface.execute(con,
        "DELETE FROM metadata WHERE table_name = $(escape_sql_string(table_name))")
    # Today's date comes from Julia: DuckDB's CURRENT_DATE needs its ICU
    # extension, which DuckDB downloads on first use, so fails offline
    DBInterface.execute(con,
        "INSERT INTO metadata VALUES ($(escape_sql_string(table_name)), " *
        "$start_year, $end_year, $(escape_sql_string(source)), DATE '$(Dates.today())')")
end

function installPRQL_DuckDBextension()
    con = DuckDB.DB()
    try
        # Attempt to install the PRQL extension
        DuckDB.execute(con, "INSTALL 'prql' FROM community;")
        DuckDB.execute(con, "LOAD 'prql';")
        
        println("PRQL extension installed and loaded successfully.")
    catch e
        println("Error during PRQL extension installation: ", e)
    finally
        DBInterface.close!(con)
    end
end

# `tables` makes in-memory DataFrames queryable by name alongside the
# database's own tables, for inputs prepared in Julia before the query runs.
function executePRQL(dbpath::String, prqlpath::String;
                     tables::Dict{String,DataFrame} = Dict{String,DataFrame}())::DataFrame
    # Create a connection to the DuckDB database
    con = DuckDB.DB(dbpath)

    try
        for (name, df) in tables
            DuckDB.register_data_frame(con, df, name)
        end

        # Load the PRQL extension
        DuckDB.execute(con, "LOAD 'prql';")

        # Read the PRQL code from the file
        prql_query = read(prqlpath, String)
        
        # Execute the PRQL query and capture the result
        result_df = DataFrame(DuckDB.query(con, prql_query))
        
        # Return the resulting DataFrame
        return result_df
    catch e
        # Handle any errors that occur during the process
        println("Error during execution: ", e)
        return DataFrame()  # Return an empty DataFrame in case of error
    finally
        # Ensure the database connection is closed
        DBInterface.close!(con)
    end
end


end # module DatabaseAccess