module ExposureDataFetch

using HTTP
using JSON
using DataFrames
using XLSX

export fetch_exposure_data

# Penn World Table 11.0, on DataverseNL
const PWT_DOI = "doi:10.34894/FABVLR"
const PWT_MAIN_FILE = "pwt110.xlsx"
const PWT_DETAIL_FILE = "pwt110_capital_detail.xlsx"
# The capital stock and the GDP at current PPPs and their price levels, from
# the main file, and the current-cost net capital stock of each asset, from
# the capital detail file
const PWT_MAIN_COLUMNS = ["cn", "pl_n", "cgdpo", "pl_gdpo"]
const PWT_ASSET_COLUMNS = ["Nc_Struc", "Nc_Mach", "Nc_TraEq", "Nc_Other"]

"""
    fetch_capital_stock_data(start_year, end_year; dir = mktempdir()) -> DataFrame

Download the main file and the capital detail file of the Penn World Table
11.0 from DataverseNL, into `dir` (pass it to keep the files between runs),
and return the capital stock variables of the years from `start_year` to
`end_year` (`read_pwt`).
"""
function fetch_capital_stock_data(start_year::Int, end_year::Int; dir::String = mktempdir())
    response = fetch_with_retries("https://dataverse.nl/api/datasets/:persistentId/?persistentId=$PWT_DOI")
    response.status == 200 || error("Failed to list the PWT files: HTTP status $(response.status)")
    files = JSON.parse(String(response.body))["data"]["latestVersion"]["files"]
    ids = Dict(file["dataFile"]["filename"] => file["dataFile"]["id"] for file in files)
    paths = map((PWT_MAIN_FILE, PWT_DETAIL_FILE)) do name
        haskey(ids, name) || error("$name is not among the files of $PWT_DOI")
        path = joinpath(dir, name)
        if !isfile(path)
            file = fetch_with_retries("https://dataverse.nl/api/access/datafile/$(ids[name])")
            file.status == 200 || error("Failed to download $name: HTTP status $(file.status)")
            write(path, file.body)
        end
        path
    end
    return read_pwt(paths..., start_year, end_year)
end

"""
    read_pwt(main_path, detail_path, start_year, end_year) -> DataFrame

One row per country and year of the PWT main file, from `start_year` to
`end_year`, with its values as published: `countrycode`, `year`, `cn`,
`pl_n`, `cgdpo` and `pl_gdpo` from the main file, and `Nc_Struc`, `Nc_Mach`, `Nc_TraEq` and `Nc_Other`
from the capital detail file, missing where that file has no row.
"""
function read_pwt(main_path::String, detail_path::String, start_year::Int, end_year::Int)
    main = read_pwt_sheet(main_path, PWT_MAIN_COLUMNS, start_year, end_year)
    assets = read_pwt_sheet(detail_path, PWT_ASSET_COLUMNS, start_year, end_year)
    return sort!(leftjoin(main, assets, on = [:countrycode, :year]), [:countrycode, :year])
end

function read_pwt_sheet(path::String, columns::Vector{String}, start_year::Int, end_year::Int)
    sheet = DataFrame(XLSX.gettable(XLSX.readxlsx(path)["Data"]))
    df = DataFrame(countrycode = [string(code) for code in sheet.countrycode],
                   year = [Int(year) for year in sheet.year])
    for name in columns
        df[!, name] = Union{Missing, Float64}[ismissing(v) ? missing : Float64(v) for v in sheet[!, name]]
    end
    return filter(row -> start_year <= row.year <= end_year, df)
end

function fetch_exposure_data(start_year::Int, end_year::Int)
    base_url = "https://api.worldbank.org/v2/country/all/indicator/"
    indicators = [
        "SP.POP.TOTL",         # Population, total
        "AG.SRF.TOTL.K2",      # Surface area (sq. km)
        "EN.POP.DNST",         # Population density (people per sq. km of land area)
        "NY.GDP.MKTP.CD",      # GDP (current US$)
        "NY.GDP.MKTP.KD.ZG",   # GDP growth (annual %)
        "NY.GNP.PCAP.CD",      # GNI per capita, Atlas method (current US$)
        "NY.GNP.PCAP.PP.CD"    # GNI per capita, PPP (current international $)
    ]

    data_frames = DataFrame[]

    for indicator in indicators
        page = 1
        total_pages = 1

        while page <= total_pages
            url = string(base_url, indicator, "?date=", start_year, ":", end_year, "&format=json&per_page=50&page=", page)

            # Making the API request
            response = fetch_with_retries(url)
            if response.status != 200
                error("Failed to fetch data for indicator $indicator: HTTP status $(response.status)")
            end

            # Parsing the response body
            data = JSON.parse(String(response.body))

            # Set total_pages based on the first page response
            if page == 1
                total_pages = data[1]["pages"]
            end

            records = data[2]  # Data is in the second element of the list

            # Extracting relevant fields and converting to DataFrame
            df = DataFrame(
                country_name = [record["country"]["value"] for record in records],
                country_code = [record["countryiso3code"] for record in records],
                year = [record["date"] for record in records],
                value = [record["value"] for record in records]
            )
            df.indicator = fill(indicator, nrow(df))
            push!(data_frames, df)

            page += 1
        end
    end

    # Combine all data frames into one
    combined_df = vcat(data_frames...)
    return combined_df
end

function fetch_with_retries(url::String; retries::Int=8, delay::Float64=5.0)
    for attempt in 1:retries
        try
            response = HTTP.get(url; status_exception = false, retry = false)
            (response.status == 200 || attempt == retries) && return response
            println("Attempt $attempt got HTTP $(response.status). Retrying in $(round(Int, delay))s...")
        catch e
            attempt == retries && rethrow()
            println("Attempt $attempt failed ($e). Retrying in $(round(Int, delay))s...")
        end
        sleep(delay)
        delay = min(delay * 2, 60.0)
    end
end


function fetch_WB_test_data()
    base_url = "http://api.worldbank.org/v2/country/all/indicator/"
    indicators = [
        "SP.POP.TOTL"         # Population, total
    ]

    data_frames = DataFrame[]

    for indicator in indicators
        page = 1
        total_pages = 1

        while page <= total_pages
            url = string(base_url, indicator, "?date=2021:2021&format=json&per_page=50&page=", page)

            # Making the API request
            response = fetch_with_retries(url)
            if response.status != 200
                error("Failed to fetch data for indicator $indicator: HTTP status $(response.status)")
            end

            # Parsing the response body
            data = JSON.parse(String(response.body))

            # Set total_pages based on the first page response
            if page == 1
                total_pages = data[1]["pages"]
            end

            records = data[2]  # Data is in the second element of the list

            # Extracting relevant fields and converting to DataFrame
            df = DataFrame(
                country_name = [record["country"]["value"] for record in records],
                country_code = [record["country"]["id"] for record in records],
                year = [record["date"] for record in records],
                value = [record["value"] for record in records]
            )
            df.indicator = fill(indicator, nrow(df))
            push!(data_frames, df)

            page += 1
        end
    end

    # Combine all data frames into one
    combined_df = vcat(data_frames...)
    return combined_df
end

end
