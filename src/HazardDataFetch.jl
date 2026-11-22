module HazardDataFetch

using DataFrames
using CSV
using JSON
using NCDatasets
using ZipFile
using GeoInterface
using LibGEOS
using SQLite

using ..CDSAPI
using ..CDSAPI: logmsg

export fetch_hazard_data

const DATASET = "derived-era5-single-levels-daily-statistics"

# The CDS job registries and the cached assignment of grid cells to countries
const DATA_DIR = "DatAdapt-database/raw/era5_daily"

# The downloaded grids, the input of the hazard transform (HazardTransform).
# They are ~731 MB per variable-year, and 1,064 of them in one flat directory
# would be unusable. One directory per year holds that year's 14
# variable-statistics, matching the order the fetch fills them in and keeping
# a year's ~10 GB together for archiving or pruning.
const GRID_DIR = "DatAdapt-database/raw/era5_grid"

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

# How many CDS jobs to keep in flight at once. The CDS caps queued requests per
# account and that cap varies with load, so the default (14 = a whole year's
# worth) suits a generous account, while a constrained one can lower it via the
# DATADAPT_MAX_IN_FLIGHT environment variable. Either way the cap self-tunes
# down whenever a submission is "rejected". Read at runtime (not a const) so the
# env var takes effect without recompiling. Throughput is unaffected — the CDS
# runs only one of a user's jobs at a time.
function max_in_flight()
    n = tryparse(Int, get(ENV, "DATADAPT_MAX_IN_FLIGHT", ""))
    return (n === nothing || n < 1) ? 14 : n
end
const REJECT_BACKOFF_START = 120.0
const REJECT_BACKOFF_MAX = 1800.0
# CDS jobs occasionally come back "failed"/"dismissed" for transient reasons;
# resubmit a piece up to MAX_ATTEMPTS times (with a short pause) before giving
# up, so one hiccup doesn't abort a multi-day run.
const MAX_ATTEMPTS = 3
const FAILED_RETRY_DELAY = 60.0

"""
    fetch_hazard_data(start_year, end_year) -> nothing

Download the ERA5 post-processed daily statistics of every year from
`start_year` to `end_year` as full global grids, one NetCDF file per
variable-statistic and year under `GRID_DIR`. Nothing is aggregated and
nothing is written to a database: the grids are the input of the hazard
transform (HazardTransform).

Files already in `GRID_DIR` are skipped, and CDS jobs still running from an
earlier run are picked up again, so an interrupted fetch resumes. A grid
moved off local disk counts as absent and is downloaded again.
"""
function fetch_hazard_data(start_year::Int, end_year::Int)
    if start_year < 1940
        @warn "ERA5 starts in 1940; adjusting start year from $start_year to 1940"
        start_year = 1940
    end
    mkpath(DATA_DIR)

    todo = Tuple{Int, Int}[]
    attached = Dict{Tuple{Int, Int}, String}()
    for year in start_year:end_year
        jobs = load_job_registry(year)
        for (i, (variable, statistic)) in enumerate(VARIABLE_STATS)
            isfile(nc_path(variable, statistic, year)) && continue
            key = registry_key(variable, statistic)
            job_id = get(jobs, key, "")
            if !isempty(job_id) && job_is_alive(job_id)
                logmsg("Re-attaching to CDS job $job_id for $variable / $statistic $year.")
                attached[(year, i)] = job_id
            else
                if !isempty(job_id)
                    delete!(jobs, key)
                    save_job_registry(year, jobs)
                end
                push!(todo, (year, i))
            end
        end
    end

    outstanding = length(todo) + length(attached)
    if outstanding == 0
        logmsg("Every grid of $start_year-$end_year is already on disk.")
    else
        logmsg("Fetching $outstanding grids of $start_year-$end_year.")
        drive_cds_fetch(todo, attached) do year, i
            variable, statistic = VARIABLE_STATS[i]
            logmsg("Saved $variable / $statistic for $year.")
        end
    end

    # A year's job registry is also how anything that moves finished years off
    # local disk knows the year is still being written to. Drop it only once
    # all of that year's grids are in place, so a half-filled year is never
    # archived.
    for year in start_year:end_year
        all(isfile(nc_path(v, s, year)) for (v, s) in VARIABLE_STATS) || continue
        path = job_registry_path(year)
        isfile(path) && rm(path)
    end
    return nothing
end

"""
    drive_cds_fetch(on_ready, todo, attached) -> nothing

Fetch gridded files from the CDS, keeping several jobs queued at once, and
call `on_ready(year, index)` on each one after it is downloaded and extracted.

Work items are `(year, index)` pairs, where `index` points into
`VARIABLE_STATS`; `attached` holds the items whose CDS job is already running
from an earlier run. Items may span years, so the queue stays full across the
end of a year.
"""
function drive_cds_fetch(on_ready::Function, todo::Vector{Tuple{Int, Int}},
                         attached::Dict{Tuple{Int, Int}, String})
    todo = copy(todo)
    in_flight = copy(attached)
    # One registry per year, kept open for the whole run and written through on
    # every change: it is both the resume point and the signal to anything
    # watching that the year is still being fetched.
    registries = Dict{Int, Dict{String, String}}()
    registry(year) = get!(() -> load_job_registry(year), registries, year)

    cap = max_in_flight()
    poll_delay = 10.0
    reject_backoff = REJECT_BACKOFF_START
    hold_submits_until = 0.0
    attempts = Dict{Tuple{Int, Int}, Int}()

    # Submit queued items until the CDS holds `cap` jobs, unless a recent
    # rejection asked us to hold off while its queue drains. Called at the top
    # of the loop and again as soon as jobs finish, so freed slots are
    # resubmitted before the download and handover rather than after them.
    refill!() = begin
        if time() >= hold_submits_until
            while !isempty(todo) && length(in_flight) < cap
                item = popfirst!(todo)
                year, i = item
                variable, statistic = VARIABLE_STATS[i]
                key = registry_key(variable, statistic)
                logmsg("Requesting $variable / $statistic for $year from the CDS...")
                job_id = CDSAPI.submit_job(DATASET, cds_request(variable, statistic, year))
                jobs = registry(year)
                jobs[key] = job_id
                save_job_registry(year, jobs)
                in_flight[item] = job_id
            end
        end
    end

    while !isempty(todo) || !isempty(in_flight)
        refill!()

        # Poll every in-flight job; collect the finished ones but defer their
        # download so we can refill the freed slots first.
        progressed = false
        ready = Tuple{Tuple{Int, Int}, String}[]
        for (item, job_id) in collect(in_flight)
            year, i = item
            variable, statistic = VARIABLE_STATS[i]
            key = registry_key(variable, statistic)
            jobs = registry(year)
            status, message = CDSAPI.job_status(job_id)
            if status == "successful"
                delete!(in_flight, item)
                push!(ready, (item, job_id))
            elseif status == "rejected"
                # Per-account queued limit hit; not a real failure. Requeue,
                # lower the cap by one, and pause submissions for a growing
                # backoff so the queue can drain.
                delete!(jobs, key)
                save_job_registry(year, jobs)
                delete!(in_flight, item)
                push!(todo, item)
                cap = max(1, cap - 1)
                hold_submits_until = time() + reject_backoff
                logmsg("CDS job $job_id ($variable / $statistic $year) rejected " *
                       "(queue limit); cap now $cap, retrying in $(round(Int, reject_backoff))s.")
                reject_backoff = min(reject_backoff * 2, REJECT_BACKOFF_MAX)
            elseif status in ("failed", "dismissed")
                # Usually a transient CDS-side failure. Resubmit the piece a
                # few times before giving up, so one hiccup doesn't abort the
                # whole run; a persistent failure still surfaces after the cap.
                delete!(jobs, key)
                save_job_registry(year, jobs)
                delete!(in_flight, item)
                attempts[item] = get(attempts, item, 0) + 1
                if attempts[item] >= MAX_ATTEMPTS
                    error("CDS job $job_id for $variable / $statistic $year $status " *
                          "after $(attempts[item]) attempts: " *
                          (isempty(message) ? "no error message provided" : message))
                end
                push!(todo, item)
                hold_submits_until = max(hold_submits_until, time() + FAILED_RETRY_DELAY)
                logmsg("CDS job $job_id ($variable / $statistic $year) $status " *
                       "(attempt $(attempts[item])/$MAX_ATTEMPTS); resubmitting in " *
                       "$(round(Int, FAILED_RETRY_DELAY))s.")
            end
        end

        # Refill the freed slots now, before the slow local work below.
        isempty(ready) || refill!()

        for (item, job_id) in ready
            year, i = item
            variable, statistic = VARIABLE_STATS[i]
            key = registry_key(variable, statistic)
            logmsg("CDS job $job_id ($variable / $statistic $year) finished.")
            archive_path = nc_path(variable, statistic, year) * ".download"
            mkpath(dirname(archive_path))
            CDSAPI.download_result(job_id, archive_path)
            extract_netcdf(archive_path, nc_path(variable, statistic, year))
            on_ready(year, i)
            jobs = registry(year)
            delete!(jobs, key)
            save_job_registry(year, jobs)
            progressed = true
            poll_delay = 10.0
            reject_backoff = REJECT_BACKOFF_START
        end

        if (!isempty(todo) || !isempty(in_flight)) && !progressed
            sleep(poll_delay)
            poll_delay = min(poll_delay * 1.5, 120.0)
        end
    end
    return nothing
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

function job_is_alive(job_id::String)
    status, _ = try
        CDSAPI.job_status(job_id)
    catch
        return false
    end
    return status in ("accepted", "running", "successful")
end

nc_path(variable, statistic, year) =
    joinpath(GRID_DIR, string(year),
             "era5_$(variable)_$(statistic)_$year.nc")

registry_key(variable, statistic) = "$variable|$statistic"

job_registry_path(year) = joinpath(DATA_DIR, "cds_jobs_$year.json")

function load_job_registry(year::Int)
    path = job_registry_path(year)
    isfile(path) || return Dict{String, String}()
    return Dict{String, String}(JSON.parsefile(path))
end

save_job_registry(year::Int, jobs::Dict{String, String}) =
    write(job_registry_path(year), JSON.json(jobs))

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

# The one 3-D data variable of a downloaded grid
function find_data_variable(ds::NCDatasets.Dataset)
    for name in keys(ds)
        v = ds[name]
        if ndims(v) == 3 && issetequal(dimnames(v), ("longitude", "latitude", "valid_time"))
            return name
        end
    end
    error("No 3-D data variable with (longitude, latitude, valid_time) dimensions found")
end

# ---------------------------------------------------------------------------
# Country map shared with damage and exposure
# ---------------------------------------------------------------------------

# Countries are kept at the finest level hazard, damage and exposure all share.
# The map is GADM 4.1 at country level, the map EM-DAT's codes come from, which
# keeps every territory apart; HAZARD_UNITS_PATH maps each GADM unit to the
# country code used for damage and exposure, merging the territories whose
# World Bank series another country includes. GADM's licence does not allow
# redistribution, so the GeoPackage is downloaded, not committed.
const GADM_PATH = "country_mappings/source_maps/gadm_4.1/gadm_410-levels.gpkg"
const HAZARD_UNITS_PATH = "country_mappings/hazard_units.csv"

# A GeoPackage geometry is a header (magic, version, flags, SRS id, then an
# envelope whose size the flags give) followed by standard WKB.
function gpkg_geometry(blob::Vector{UInt8})
    envelope = (0, 32, 48, 48, 64)[((blob[4] >> 1) & 0x07) + 1]
    return LibGEOS.readgeom(blob[9 + envelope:end])
end

function load_unit_features()
    units = CSV.read(HAZARD_UNITS_PATH, DataFrame; types = String)
    code_of = Dict(row.gadm_code => coalesce(row.code, "") for row in eachrow(units))
    db = SQLite.DB(GADM_PATH)
    features = []
    try
        # Units taken from GADM's regional level (Hong Kong, Macao) lie inside
        # a country polygon, so they come first: the first feature that
        # contains a cell wins.
        level1 = [gid for gid in keys(code_of) if occursin('.', gid)]
        rows = vcat(
            DataFrame(DBInterface.execute(db,
                "SELECT GID_1 AS gid, geom FROM ADM_1 WHERE GID_1 IN " *
                "($(join(("'$gid'" for gid in level1), ", ")))")),
            DataFrame(DBInterface.execute(db, "SELECT GID_0 AS gid, geom FROM ADM_0")))
        nrow(rows) == length(code_of) ||
            error("$HAZARD_UNITS_PATH lists $(length(code_of)) units, GADM has $(nrow(rows))")
        for row in eachrow(rows)
            haskey(code_of, row.gid) || error("GADM unit $(row.gid) missing from $HAZARD_UNITS_PATH")
            code = code_of[row.gid]
            isempty(code) && continue  # not a country (the Caspian Sea, Antarctica)
            geom = gpkg_geometry(Vector{UInt8}(row.geom))
            box = GeoInterface.extent(geom)
            push!(features, (iso3 = code, prepared = LibGEOS.prepareGeom(geom),
                             left = box.X[1], right = box.X[2],
                             bottom = box.Y[1], top = box.Y[2]))
        end
    finally
        close(db)
    end
    return features
end

"""
    get_unit_assignment(nc_path) -> Dict{String, NamedTuple}

Assign every grid cell of the NetCDF file's lon/lat grid to a country of the
map shared with damage and exposure, by point-in-polygon test of the cell's
centre. Returns a Dict mapping each country code to (cells, weights), where
cells are CartesianIndex{2} into the (lon, lat) arrays and weights are
cos(latitude) area weights. Cells in no country (sea) are left out.

The assignment is computed once and cached as CSV. The cache is keyed by the
merge table's content, so editing the table forces a new assignment.
"""
function get_unit_assignment(nc_path::String)
    lon, lat = Dataset(nc_path) do ds
        Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:])
    end

    key = string(hash(read(HAZARD_UNITS_PATH)); base = 16)
    cache_path = joinpath(DATA_DIR, "grid_unit_assignment_$(length(lon))x$(length(lat))_$key.csv")
    if isfile(cache_path)
        df = CSV.read(cache_path, DataFrame; types = Dict(:iso3 => String))
        return build_country_cells(df, lat)
    end

    logmsg("Assigning grid cells to GADM-based countries (done once, may take a while)...")
    mkpath(DATA_DIR)
    df = assign_cells(lon, lat, load_unit_features())
    CSV.write(cache_path, df)
    logmsg("Assigned $(nrow(df)) land cells to $(length(unique(df.iso3))) countries.")
    return build_country_cells(df, lat)
end

# Assign each grid cell to the first feature that contains its centre. Cells
# in no feature (sea) are left out.
function assign_cells(lon::Vector{Float64}, lat::Vector{Float64}, features)
    lon_idx = Int[]
    lat_idx = Int[]
    iso3 = String[]
    for (j, λ) in enumerate(lon)
        x = λ > 180 ? λ - 360 : λ  # ERA5 uses 0..360, the maps -180..180
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
    return DataFrame(lon_idx = lon_idx, lat_idx = lat_idx, iso3 = iso3)
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

end # module HazardDataFetch
