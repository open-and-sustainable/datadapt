module DamageDataFetch

using XLSX
using DataFrames
import DuckDB
using DuckDB: DBInterface
import HTTP

export fetch_damage_data, fetch_life_table_data

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

# UN World Population Prospects 2024, medium variant, both sexes: estimates
# to 2023 and projections from 2024, by single year of age
const WPP_URL = "https://population.un.org/wpp/assets/Excel%20Files/" *
    "1_Indicator%20(Standard)/CSV_FILES/"
const WPP_POPULATION_FILES = [
    "WPP2024_PopulationBySingleAgeSex_Medium_1950-2023.csv.gz",
    "WPP2024_PopulationBySingleAgeSex_Medium_2024-2100.csv.gz"]
const WPP_LIFE_TABLE_FILES = [
    "WPP2024_Life_Table_Complete_Medium_Both_1950-2023.csv.gz",
    "WPP2024_Life_Table_Complete_Medium_Both_2024-2100.csv.gz"]

"""
    read_wpp(paths, value, start_year, end_year) -> DataFrame

Read the UN WPP CSV files at `paths` (gzipped or not) and keep, for every
country or area and year in `start_year:end_year`, the column `value` by
single year of age: columns `ISO3_code`, `Location`, `Time`, `AgeGrpStart`
(100 stands for 100 and over) and `value`. The regional and other aggregates
of the files are left out.
"""
function read_wpp(paths::Vector{String}, value::String, start_year::Int, end_year::Int)
    files = join(("'" * replace(p, "'" => "''") * "'" for p in paths), ", ")
    db = DuckDB.DB()
    try
        con = DBInterface.connect(db)
        # The files quote names that hold commas, which DuckDB's sniffer
        # misses, so every option is set
        df = DataFrame(DBInterface.execute(con, """
            SELECT ISO3_code, Location, CAST(Time AS INTEGER) AS Time,
                   CAST(AgeGrpStart AS INTEGER) AS AgeGrpStart,
                   CAST($value AS DOUBLE) AS $value
            FROM read_csv([$files], header = true, delim = ',', quote = '"',
                          escape = '"', all_varchar = true)
            WHERE LocTypeName = 'Country/Area'
              AND CAST(Time AS INTEGER) BETWEEN $start_year AND $end_year
            ORDER BY ISO3_code, Time, AgeGrpStart"""))
        DBInterface.close!(con)
        return df
    finally
        close(db)
    end
end

"""
    fetch_life_table_data(start_year, end_year; dir = mktempdir())
        -> (population, life_expectancy)

Download the UN WPP 2024 population by single age (`PopTotal`, thousands of
people on 1 July) and complete life tables for both sexes (`ex`, life
expectancy at each age), into `dir` unless already there, and read them with
`read_wpp`.
"""
function fetch_life_table_data(start_year::Int, end_year::Int; dir::String = mktempdir())
    paths(files) = map(files) do f
        path = joinpath(dir, f)
        isfile(path) || HTTP.download(WPP_URL * f, path; update_period = Inf)
        path
    end
    population = read_wpp(paths(WPP_POPULATION_FILES), "PopTotal", start_year, end_year)
    life_expectancy = read_wpp(paths(WPP_LIFE_TABLE_FILES), "ex", start_year, end_year)
    return population, life_expectancy
end

end
