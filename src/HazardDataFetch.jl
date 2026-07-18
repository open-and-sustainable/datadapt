module HazardDataFetch

using DataFrames
using Dates
using Statistics
using CSV
using HTTP
using JSON
using NCDatasets
using ZipFile
using Shapefile
using GeoInterface
using LibGEOS

using ..CDSAPI

export fetch_hazard_data

const DATASET = "derived-era5-single-levels-daily-statistics"
const DATA_DIR = "DatAdapt-database/raw/era5_daily"
const COUNTRIES_URL = "https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_0_countries.zip"

# (variable, daily_statistic) pairs downloaded from the CDS.
# Values keep native ERA5 units: temperatures/dewpoint [K],
# total_precipitation / potential_evaporation / runoff / snowfall /
# snow_depth [m of water equivalent], volumetric_soil_water_layer_3
# [m^3/m^3], instantaneous_10m_wind_gust [m/s],
# mean_sea_level_pressure [Pa], CAPE [J/kg].
const VARIABLE_STATS = [
    ("2m_temperature", "daily_minimum"),
    ("2m_temperature", "daily_maximum"),
    ("2m_temperature", "daily_mean"),
    ("2m_dewpoint_temperature", "daily_mean"),
    ("instantaneous_10m_wind_gust", "daily_maximum"),
    ("mean_sea_level_pressure", "daily_minimum"),
    ("convective_available_potential_energy", "daily_maximum"),
    ("total_precipitation", "daily_sum"),
    ("snowfall", "daily_sum"),
    ("snow_depth", "daily_mean"),
    ("potential_evaporation", "daily_sum"),
    ("surface_runoff", "daily_sum"),
    ("sub_surface_runoff", "daily_sum"),
    ("volumetric_soil_water_layer_3", "daily_mean"),
]

"""
    fetch_hazard_data(start_year, end_year) -> DataFrame

Download ERA5 post-processed daily statistics from the CDS and aggregate them
to country-day level. Returns a long-format DataFrame with columns:
date, country_iso3, variable, statistic, value_mean (area-weighted),
value_min, value_max, n_cells.

Progress is checkpointed per year in `DATA_DIR/country_daily_<year>.csv`;
already-processed years are skipped, so interrupted runs can be resumed.
"""
function fetch_hazard_data(start_year::Int, end_year::Int)
    if start_year < 1940
        @warn "ERA5 starts in 1940; adjusting start year from $start_year to 1940"
        start_year = 1940
    end
    mkpath(DATA_DIR)

    yearly = DataFrame[]
    for year in start_year:end_year
        csv_path = joinpath(DATA_DIR, "country_daily_$year.csv")
        if isfile(csv_path)
            println("Year $year already processed. Loading checkpoint.")
            push!(yearly, load_checkpoint(csv_path))
        else
            df = process_year(year)
            CSV.write(csv_path, df)
            cleanup_parts(year)
            push!(yearly, df)
        end
    end
    return vcat(yearly...)
end

function load_checkpoint(csv_path::String)
    return CSV.read(csv_path, DataFrame;
        types = Dict(:date => Date, :country_iso3 => String,
                     :variable => String, :statistic => String))
end

# Each (variable, statistic) is checkpointed separately so an interrupted
# run only loses the piece it was working on. All CDS jobs for the year
# are submitted up front so they queue on the CDS in parallel; results
# are downloaded and aggregated as each job finishes.
function process_year(year::Int)
    results = Vector{Union{Nothing, DataFrame}}(nothing, length(VARIABLE_STATS))
    jobs = load_job_registry(year)
    pending = Int[]

    for (i, (variable, statistic)) in enumerate(VARIABLE_STATS)
        if isfile(part_checkpoint_path(variable, statistic, year))
            println("$variable / $statistic for $year already aggregated. Loading checkpoint.")
            results[i] = load_checkpoint(part_checkpoint_path(variable, statistic, year))
        elseif isfile(nc_path(variable, statistic, year))
            results[i] = aggregate_part(variable, statistic, year)
        else
            key = registry_key(variable, statistic)
            job_id = get(jobs, key, "")
            if !isempty(job_id) && !job_is_alive(job_id)
                job_id = ""
            end
            if isempty(job_id)
                println("Requesting $variable / $statistic for $year from the CDS...")
                job_id = CDSAPI.submit_job(DATASET, cds_request(variable, statistic, year))
                jobs[key] = job_id
                save_job_registry(year, jobs)
            else
                println("Re-attaching to CDS job $job_id for $variable / $statistic $year.")
            end
            push!(pending, i)
        end
    end

    delay = 10.0
    while !isempty(pending)
        progressed = false
        for i in copy(pending)
            variable, statistic = VARIABLE_STATS[i]
            key = registry_key(variable, statistic)
            job_id = jobs[key]
            status, message = CDSAPI.job_status(job_id)
            if status == "successful"
                println("CDS job $job_id ($variable / $statistic $year) finished.")
                archive_path = nc_path(variable, statistic, year) * ".download"
                CDSAPI.download_result(job_id, archive_path)
                extract_netcdf(archive_path, nc_path(variable, statistic, year))
                results[i] = aggregate_part(variable, statistic, year)
                delete!(jobs, key)
                save_job_registry(year, jobs)
                filter!(!=(i), pending)
                progressed = true
                delay = 10.0
            elseif status in ("failed", "dismissed")
                delete!(jobs, key)
                save_job_registry(year, jobs)
                error("CDS job $job_id for $variable / $statistic $year $status: " *
                      (isempty(message) ? "no error message provided" : message))
            end
        end
        if !isempty(pending) && !progressed
            sleep(delay)
            delay = min(delay * 1.5, 120.0)
        end
    end
    return vcat(results...)
end

function cds_request(variable::String, statistic::String, year::Int)
    # One variable x one year stays below the CDS request cost limit
    # (400 variable-days per request for this dataset)
    return Dict(
        "product_type" => "reanalysis",
        "variable" => [variable],
        "year" => string(year),
        "month" => [lpad(m, 2, '0') for m in 1:12],
        "day" => [lpad(d, 2, '0') for d in 1:31],
        "daily_statistic" => statistic,
        "time_zone" => "utc+00:00",
        "frequency" => "1_hourly",
    )
end

function aggregate_part(variable::String, statistic::String, year::Int)
    path = nc_path(variable, statistic, year)
    countries = get_country_assignment(path)
    println("Aggregating $variable / $statistic for $year...")
    df = aggregate_country_daily(path, variable, statistic, countries)
    CSV.write(part_checkpoint_path(variable, statistic, year), df)
    rm(path)
    return df
end

function job_is_alive(job_id::String)
    status, _ = try
        CDSAPI.job_status(job_id)
    catch
        return false
    end
    return status in ("accepted", "running", "successful")
end

nc_path(variable, statistic, year) =
    joinpath(DATA_DIR, "era5_$(variable)_$(statistic)_$year.nc")

part_checkpoint_path(variable, statistic, year) =
    joinpath(DATA_DIR, "part_$(variable)_$(statistic)_$year.csv")

registry_key(variable, statistic) = "$variable|$statistic"

job_registry_path(year) = joinpath(DATA_DIR, "cds_jobs_$year.json")

function load_job_registry(year::Int)
    path = job_registry_path(year)
    isfile(path) || return Dict{String, String}()
    return Dict{String, String}(JSON.parsefile(path))
end

save_job_registry(year::Int, jobs::Dict{String, String}) =
    write(job_registry_path(year), JSON.json(jobs))

function cleanup_parts(year::Int)
    for (variable, statistic) in VARIABLE_STATS
        path = part_checkpoint_path(variable, statistic, year)
        isfile(path) && rm(path)
    end
    registry = job_registry_path(year)
    isfile(registry) && rm(registry)
end

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

# The CDS delivers daily statistics as a zip holding one NetCDF file per
# variable, but single-file requests may arrive as plain NetCDF
function extract_netcdf(archive_path::String, nc_path::String)
    magic = open(io -> read(io, 2), archive_path)
    if magic == UInt8['P', 'K']
        archive = ZipFile.Reader(archive_path)
        members = filter(f -> endswith(f.name, ".nc"), archive.files)
        length(members) == 1 ||
            error("Expected exactly one NetCDF file in $archive_path, found $(length(members))")
        open(nc_path, "w") do out
            write(out, read(members[1]))
        end
        close(archive)
        rm(archive_path)
    else
        mv(archive_path, nc_path)
    end
end

# ---------------------------------------------------------------------------
# Country assignment of grid cells
# ---------------------------------------------------------------------------

function ensure_countries_shapefile()
    dir = joinpath(DATA_DIR, "countries")
    shp_path = joinpath(dir, "ne_10m_admin_0_countries.shp")
    isfile(shp_path) && return shp_path

    mkpath(dir)
    zip_path = joinpath(dir, "ne_10m_admin_0_countries.zip")
    println("Downloading Natural Earth country boundaries...")
    HTTP.download(COUNTRIES_URL, zip_path)
    archive = ZipFile.Reader(zip_path)
    for f in archive.files
        open(joinpath(dir, basename(f.name)), "w") do out
            write(out, read(f))
        end
    end
    close(archive)
    rm(zip_path)
    return shp_path
end

"""
    get_country_assignment(nc_path) -> Dict{String, NamedTuple}

Assign every grid cell of the NetCDF file's lon/lat grid to a country
(ISO3 code) by point-in-polygon test against Natural Earth boundaries.
Returns a Dict mapping ISO3 => (cells, weights) where cells are
CartesianIndex{2} into (lon, lat) arrays and weights are cos(latitude)
area weights. The assignment is computed once and cached as CSV.
"""
function get_country_assignment(nc_path::String)
    lon, lat = Dataset(nc_path) do ds
        Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:])
    end

    cache_path = joinpath(DATA_DIR, "grid_country_assignment_$(length(lon))x$(length(lat)).csv")
    if isfile(cache_path)
        df = CSV.read(cache_path, DataFrame; types = Dict(:iso3 => String))
        return build_country_cells(df, lat)
    end

    println("Assigning grid cells to countries (done once, may take a while)...")
    shp_path = ensure_countries_shapefile()
    features = load_country_features(shp_path)

    lon_idx = Int[]
    lat_idx = Int[]
    iso3 = String[]
    for (j, λ) in enumerate(lon)
        x = λ > 180 ? λ - 360 : λ  # ERA5 uses 0..360, Natural Earth -180..180
        for (i, φ) in enumerate(lat)
            point = LibGEOS.Point(x, φ)
            for f in features
                if f.left <= x <= f.right && f.bottom <= φ <= f.top &&
                   LibGEOS.intersects(f.prepared, point)
                    push!(lon_idx, j)
                    push!(lat_idx, i)
                    push!(iso3, f.iso3)
                    break
                end
            end
        end
    end
    df = DataFrame(lon_idx = lon_idx, lat_idx = lat_idx, iso3 = iso3)
    CSV.write(cache_path, df)
    println("Assigned $(nrow(df)) land cells to $(length(unique(df.iso3))) countries.")
    return build_country_cells(df, lat)
end

function load_country_features(shp_path::String)
    table = Shapefile.Table(shp_path)
    features = []
    for row in table
        geom = Shapefile.shape(row)
        geom === nothing && continue
        code = row.ISO_A3
        # Natural Earth marks some ISO codes as -99 (e.g. France, Norway)
        if code === missing || code == "-99"
            code = row.ADM0_A3
        end
        mbr = geom.MBR
        prepared = LibGEOS.prepareGeom(GeoInterface.convert(LibGEOS, geom))
        push!(features, (iso3 = String(code), prepared = prepared,
                         left = mbr.left, right = mbr.right,
                         bottom = mbr.bottom, top = mbr.top))
    end
    return features
end

function build_country_cells(df::DataFrame, lat::Vector{Float64})
    countries = Dict{String, NamedTuple{(:cells, :weights), Tuple{Vector{CartesianIndex{2}}, Vector{Float64}}}}()
    for group in groupby(df, :iso3)
        cells = [CartesianIndex(r.lon_idx, r.lat_idx) for r in eachrow(group)]
        weights = [cosd(lat[r.lat_idx]) for r in eachrow(group)]
        countries[group.iso3[1]] = (cells = cells, weights = weights)
    end
    return countries
end

# ---------------------------------------------------------------------------
# Aggregation to country-day level
# ---------------------------------------------------------------------------

function aggregate_country_daily(nc_path::String, variable::String, statistic::String, countries)
    Dataset(nc_path) do ds
        varname = find_data_variable(ds)
        v = ds[varname]
        dimnames(v) == ("longitude", "latitude", "valid_time") ||
            error("Unexpected dimension order $(dimnames(v)) in $nc_path")
        dates = Date.(ds["valid_time"][:])

        n = length(dates) * length(countries)
        date_col = Vector{Date}(undef, 0); sizehint!(date_col, n)
        iso_col = Vector{String}(undef, 0); sizehint!(iso_col, n)
        mean_col = Vector{Float64}(undef, 0); sizehint!(mean_col, n)
        min_col = Vector{Float64}(undef, 0); sizehint!(min_col, n)
        max_col = Vector{Float64}(undef, 0); sizehint!(max_col, n)
        cells_col = Vector{Int}(undef, 0); sizehint!(cells_col, n)

        for (t, date) in enumerate(dates)
            slice = v[:, :, t]
            for (iso3, cw) in countries
                stats = weighted_stats(slice, cw.cells, cw.weights)
                stats === nothing && continue
                push!(date_col, date)
                push!(iso_col, iso3)
                push!(mean_col, stats.mean)
                push!(min_col, stats.min)
                push!(max_col, stats.max)
                push!(cells_col, stats.n)
            end
        end

        return DataFrame(
            date = date_col,
            country_iso3 = iso_col,
            variable = fill(variable, length(date_col)),
            statistic = fill(statistic, length(date_col)),
            value_mean = mean_col,
            value_min = min_col,
            value_max = max_col,
            n_cells = cells_col,
        )
    end
end

function find_data_variable(ds::NCDatasets.Dataset)
    for name in keys(ds)
        v = ds[name]
        if ndims(v) == 3 && issetequal(dimnames(v), ("longitude", "latitude", "valid_time"))
            return name
        end
    end
    error("No 3-D data variable with (longitude, latitude, valid_time) dimensions found")
end

function weighted_stats(slice, cells::Vector{CartesianIndex{2}}, weights::Vector{Float64})
    wsum = 0.0
    vsum = 0.0
    vmin = Inf
    vmax = -Inf
    n = 0
    @inbounds for (k, cell) in enumerate(cells)
        val = slice[cell]
        val === missing && continue
        x = Float64(val)
        w = weights[k]
        vsum += w * x
        wsum += w
        vmin = min(vmin, x)
        vmax = max(vmax, x)
        n += 1
    end
    n == 0 && return nothing
    return (mean = vsum / wsum, min = vmin, max = vmax, n = n)
end

end # module HazardDataFetch
