module DamageDataFetch

using XLSX
using DataFrames

export fetch_damage_data

function fetch_damage_data(start_year::Int, end_year::Int)
    filename = "DatAdapt-database/raw/clima-hydro-meteo_EM-DAT.xlsx"
    df = load_xlsx_to_dataframe_xlsxjl(filename, "EM-DAT Data")
    # Keep only events starting within the requested period; the excerpt
    # file may cover more
    return filter(row -> begin
        y = row[Symbol("Start Year")]
        y isa AbstractString && (y = tryparse(Int, y))
        y !== nothing && !ismissing(y) && start_year <= y <= end_year
    end, df)
end

function load_xlsx_to_dataframe_xlsxjl(file_path::String, sheet_name::String)
    # Read the table from the specified sheet
    m = XLSX.readtable(file_path, sheet_name)
    
    # Extract headers from the DataTable object (assuming headers are in m.headers)
    headers = m.column_labels
    
    # Convert the table data to a matrix
    data_matrix = hcat(m.data...)
    
    # Create a DataFrame with the extracted headers
    df = DataFrame(data_matrix, Symbol.(headers))
    
    return df
end

end
