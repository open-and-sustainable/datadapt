module DamageDataFetch

using XLSX
using DataFrames

export fetch_damage_data

function fetch_damage_data(start_year::Int, end_year::Int)
    filename = "DatAdapt-database/raw/clima-hydro-meteo_EM-DAT.xlsx"
    df = load_xlsx_to_dataframe(filename, "EM-DAT Data")
    # Keep only events starting within the requested period; the excerpt
    # file may cover more
    return filter(row -> begin
        y = row[Symbol("Start Year")]
        y isa AbstractString && (y = tryparse(Int, y))
        y !== nothing && !ismissing(y) && start_year <= y <= end_year
    end, df)
end

function load_xlsx_to_dataframe(file_path::String, sheet_name::String)
    m = XLSX.readtable(file_path, sheet_name)
    return DataFrame(m.data, Symbol.(m.column_labels))
end

end
