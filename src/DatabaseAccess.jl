module DatabaseAccess

using DuckDB
using DataFrames
using Dates
using CSV

export write_duckdb_table, write_large_duckdb_table, executePRQL, with_connection

# Open db_path, run f(con), and guarantee the connection is closed
# afterwards. Writes that must land in the same durability unit (e.g.
# a table write followed by its metadata update) should share the
# connection passed into f rather than opening the file again.
function with_connection(f::Function, db_path::String)
    con = DuckDB.DB(db_path)
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

function sql_value(value)::String
    # Convert a Julia value to a proper SQL representation
    if value === nothing || value === missing
        return "NULL"
    elseif value isa String
        return escape_sql_string(value)
    else
        return string(value)
    end
end

function create_and_load_table_throughCSV!(df::DataFrame, con::DuckDB.DB, table_name::String)
    # Drop the table if it exists
    DBInterface.execute(con, "DROP TABLE IF EXISTS $table_name")

    # Create the table with explicit types
    create_table_with_types!(df, con, table_name)

    # Write DataFrame to a temporary CSV file
    temp_csv_path = "DatAdapt-database/raw/temp_data.csv"
    CSV.write(temp_csv_path, df)

    # Load data from the CSV file using COPY
    DBInterface.execute(con, "COPY $table_name FROM '$temp_csv_path' (FORMAT CSV, HEADER TRUE)")

    # Remove the temporary CSV file
    rm(temp_csv_path)
end

function create_and_load_table_directly!(df::DataFrame, con::DuckDB.DB, table_name::String)
    # Drop the table if it exists
    DBInterface.execute(con, "DROP TABLE IF EXISTS $table_name")

    # Create the table with explicit types
    create_table_with_types!(df, con, table_name)

    # Determine the column names and types
    column_names = names(df)
    column_types = eltype.(eachcol(df))

    # Insert data into the table
    for row in eachrow(df)
        values_sql = String[]
        for (name, _) in zip(column_names, column_types)
            value = row[name]
            push!(values_sql, sql_value(value))
        end
        insert_sql = "INSERT INTO $table_name VALUES ($(join(values_sql, ", ")))"
        DBInterface.execute(con, insert_sql)
    end

end

function write_duckdb_table!(df::DataFrame, con::DuckDB.DB, table_name::String)
    create_and_load_table_directly!(df, con, table_name)
end

function table_exists(con::DuckDB.DB, table_name::String)
    rows = DataFrame(DBInterface.execute(con,
        "SELECT count(*) AS n FROM duckdb_tables() " *
        "WHERE table_name = $(escape_sql_string(table_name))"))
    return rows[1, :n] > 0
end

"""
    replace_year_in_duckdb_table!(df, con, table_name, year; date_column="date")

Load one year of `df` into `table_name`, creating the table from `df`'s schema
on first use. Rows already present for `year` are deleted first, which makes
the load idempotent: a resumed multi-year fetch re-writes years it had already
written instead of duplicating them.
"""
function replace_year_in_duckdb_table!(df::DataFrame, con::DuckDB.DB,
                                       table_name::String, year::Int;
                                       date_column::String = "date")
    if table_exists(con, table_name)
        DBInterface.execute(con, "DELETE FROM $table_name " *
            "WHERE EXTRACT(YEAR FROM \"$date_column\") = $year")
    else
        create_table_with_types!(df, con, table_name)
    end

    # COPY matches columns positionally; the table was created from this same
    # DataFrame's schema, so CSV.write's column order lines up.
    temp_csv_path = "DatAdapt-database/raw/temp_$(table_name)_$(year).csv"
    CSV.write(temp_csv_path, df)
    try
        DBInterface.execute(con,
            "COPY $table_name FROM '$temp_csv_path' (FORMAT CSV, HEADER TRUE)")
    finally
        rm(temp_csv_path; force = true)
    end
end

"""
    table_year_range(con, table_name; date_column="date") -> (first, last) or nothing

Year span actually stored in `table_name`, read back from the data. Lets an
incrementally loaded table record the coverage it really has, rather than the
period a run intended to cover but may not have finished.
"""
function table_year_range(con::DuckDB.DB, table_name::String;
                          date_column::String = "date")
    table_exists(con, table_name) || return nothing
    rows = DataFrame(DBInterface.execute(con,
        "SELECT min(EXTRACT(YEAR FROM \"$date_column\"))::INTEGER AS first_year, " *
        "max(EXTRACT(YEAR FROM \"$date_column\"))::INTEGER AS last_year " *
        "FROM $table_name"))
    (nrow(rows) == 0 || ismissing(rows[1, :first_year])) && return nothing
    return (Int(rows[1, :first_year]), Int(rows[1, :last_year]))
end

function write_large_duckdb_table!(df::DataFrame, con::DuckDB.DB, table_name::String)
    create_and_load_table_throughCSV!(df, con, table_name)
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
    DBInterface.execute(con,
        "INSERT INTO metadata VALUES ($(escape_sql_string(table_name)), " *
        "$start_year, $end_year, $(escape_sql_string(source)), CURRENT_DATE)")
end

function create_table_with_types!(df::DataFrame, con::DuckDB.DB, table_name::String)
    # Determine the column names and types
    column_names = names(df)
    column_types = eltype.(eachcol(df))

    # Map Julia types to SQL types
    type_map = Dict(
        Int => "INTEGER",
        Float64 => "DOUBLE",
        String => "STRING",
        Bool => "BOOLEAN",
        Dates.Date => "DATE",
        Dates.DateTime => "TIMESTAMP"
        # Add more mappings as needed
    )

    # Construct the CREATE TABLE statement with quoted column names and SQL types
    columns_sql = String[]
    for (name, col_type) in zip(column_names, column_types)
        quoted_name = "\"" * name * "\""  # Quote the column name
        sql_type = get(type_map, col_type, "STRING")  # Default to STRING if type is not mapped
        push!(columns_sql, "$quoted_name $sql_type")
    end
    create_table_sql = "CREATE TABLE $table_name ($(join(columns_sql, ", ")))"
    DBInterface.execute(con, create_table_sql)
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

function executePRQL(dbpath::String, prqlpath::String)::DataFrame
    # Create a connection to the DuckDB database
    con = DuckDB.DB(dbpath)
    
    try
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