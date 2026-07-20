module DamageDataFetch

using XLSX
using DataFrames

export fetch_damage_data

function fetch_damage_data(start_year::Int, end_year::Int)
    filename = "DatAdapt-database/raw/clima-hydro-meteo_$(start_year)-$(end_year)_EM-DAT.xlsx"
    return load_xlsx_to_dataframe_xlsxjl(filename, "EM-DAT Data")
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
