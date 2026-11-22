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

# A unit of the map: its country code, its outline and bounding box, and, for
# a unit taken from GADM's regional level, the code of the country whose
# outline contains it.
function unit_feature(code::String, geom, parent::Union{Nothing, String} = nothing)
    box = GeoInterface.extent(geom)
    return (iso3 = code, geom = geom, parent = parent,
            left = box.X[1], right = box.X[2], bottom = box.Y[1], top = box.Y[2])
end

function load_unit_features()
    units = CSV.read(HAZARD_UNITS_PATH, DataFrame; types = String)
    code_of = Dict(row.gadm_code => coalesce(row.code, "") for row in eachrow(units))
    db = SQLite.DB(GADM_PATH)
    features = []
    try
        # Units taken from GADM's regional level (Hong Kong, Macao) lie inside
        # a country's outline; their area is taken off that country's.
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
            parent = occursin('.', row.gid) ? code_of[first(split(row.gid, '.'))] : nothing
            push!(features, unit_feature(code, gpkg_geometry(Vector{UInt8}(row.geom)), parent))
        end
    finally
        close(db)
    end
    return features
end

"""
    get_unit_assignment(nc_path) -> Dict{String, NamedTuple}

Assign the grid cells of the NetCDF file's lon/lat grid to the countries of
the map shared with damage and exposure. A cell counts for every country it
overlaps, in proportion to the share of its area inside that country, so a
cell on a border counts in part for each neighbour and a coastal cell only for
its land. Returns a Dict mapping each country code to (cells, weights), where
cells are CartesianIndex{2} into the (lon, lat) arrays and weights are each
cell's share in the country times cos(latitude), its area weight. Cells in no
country (sea) are left out.

The assignment is computed once and cached as CSV. The cache is keyed by the
merge table's content, so editing the table forces a new assignment.
"""
function get_unit_assignment(nc_path::String)
    lon, lat = Dataset(nc_path) do ds
        Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:])
    end

    key = string(hash(read(HAZARD_UNITS_PATH)); base = 16)
    cache_path = joinpath(DATA_DIR, "grid_unit_shares_$(length(lon))x$(length(lat))_$key.csv")
    if isfile(cache_path)
        df = CSV.read(cache_path, DataFrame; types = Dict(:iso3 => String))
        return build_country_cells(df, lat)
    end

    logmsg("Assigning grid cells to GADM-based countries (done once, may take a while)...")
    mkpath(DATA_DIR)
    df = unit_shares(lon, lat, load_unit_features())
    CSV.write(cache_path, df)
    logmsg("Assigned $(length(unique(zip(df.lon_idx, df.lat_idx)))) land cells to " *
           "$(length(unique(df.iso3))) countries.")
    return build_country_cells(df, lat)
end

# Grid cells are 0.25° on a side, centred on the grid's coordinates
const CELL = 0.25

# Shares below this are dropped: slivers of a few hundred square metres, from
# outlines that do not quite meet, would otherwise add cells to compute.
const MIN_SHARE = 1e-6

# The rectangle of the grid cells in columns ks and rows is, shifted east by
# `shift` degrees. `x` holds the columns' longitudes from west to east, `y` the
# rows' latitudes from north to south.
function cell_box(x, y, ks::UnitRange{Int}, is::UnitRange{Int}, shift::Float64)
    w, e = x[first(ks)] - CELL / 2 + shift, x[last(ks)] + CELL / 2 + shift
    n, s = y[first(is)] + CELL / 2, y[last(is)] - CELL / 2
    return LibGEOS.Polygon([[[w, s], [e, s], [e, n], [w, n], [w, s]]])
end

function clip(geom, box)
    try
        return LibGEOS.intersection(geom, box)
    catch err
        err isa LibGEOS.GEOSError || rethrow()
        return LibGEOS.intersection(LibGEOS.makeValid(geom), box)
    end
end

# Add to `shares` the share of each cell of columns ks and rows is covered by
# `geom`, already clipped to those cells. The rectangle is halved until it is
# one cell, or wholly covered, clipping the outline at each step, so an
# outline is never intersected whole with a single cell.
function add_shares!(shares::Dict{Tuple{Int, Int}, Float64}, geom, x, y,
                     ks::UnitRange{Int}, is::UnitRange{Int}, shift::Float64)
    LibGEOS.isEmpty(geom) && return
    area = LibGEOS.area(geom)
    area > 0 || return
    if area >= length(ks) * length(is) * CELL^2 * (1 - 1e-9)
        for k in ks, i in is
            shares[(k, i)] = get(shares, (k, i), 0.0) + 1.0
        end
    elseif length(ks) == 1 && length(is) == 1
        shares[(first(ks), first(is))] = get(shares, (first(ks), first(is)), 0.0) + area / CELL^2
    elseif length(ks) >= length(is)
        m = first(ks) + length(ks) ÷ 2 - 1
        for h in (first(ks):m, m + 1:last(ks))
            add_shares!(shares, clip(geom, cell_box(x, y, h, is, shift)), x, y, h, is, shift)
        end
    else
        m = first(is) + length(is) ÷ 2 - 1
        for h in (first(is):m, m + 1:last(is))
            add_shares!(shares, clip(geom, cell_box(x, y, ks, h, shift)), x, y, ks, h, shift)
        end
    end
end

"""
    unit_shares(lon, lat, features) -> DataFrame

The share of each grid cell's area inside each country, from the outlines in
`features`, as rows of `lon_idx`, `lat_idx` (into `lon` and `lat`), `iso3` and
`fraction`. Units with the same code are added together, and a regional unit
is taken off the country that contains it. Longitudes may run 0..360, as in
ERA5, or -180..180.
"""
function unit_shares(lon::Vector{Float64}, lat::Vector{Float64}, features)
    # Columns from west to east in map longitudes; the column at 180° spans
    # the antimeridian
    xs = [λ > 180 ? λ - 360 : λ for λ in lon]
    order = sortperm(xs)
    x = xs[order]
    rows = sortperm(lat; rev = true)
    y = lat[rows]
    by_code = Dict{String, Dict{Tuple{Int, Int}, Float64}}()
    regional = Tuple{String, String, Dict{Tuple{Int, Int}, Float64}}[]
    for f in features
        shares = Dict{Tuple{Int, Int}, Float64}()
        k1 = max(1, searchsortedfirst(x, f.left - CELL / 2))
        k2 = min(length(x), searchsortedlast(x, f.right + CELL / 2))
        i1 = something(findfirst(<=(f.top + CELL / 2), y), length(y) + 1)
        i2 = something(findlast(>=(f.bottom - CELL / 2), y), 0)
        if i1 <= i2
            if k1 <= k2
                box = cell_box(x, y, k1:k2, i1:i2, 0.0)
                add_shares!(shares, clip(f.geom, box), x, y, k1:k2, i1:i2, 0.0)
            end
            # Land west of the first column's edge lies in the last column,
            # across the antimeridian
            if f.left < x[1] - CELL / 2 && x[end] + CELL / 2 > 180
                last_col = length(x):length(x)
                add_shares!(shares, clip(f.geom, cell_box(x, y, last_col, i1:i2, -360.0)),
                            x, y, last_col, i1:i2, -360.0)
            end
        end
        total = get!(Dict{Tuple{Int, Int}, Float64}, by_code, f.iso3)
        for (c, v) in shares
            total[c] = get(total, c, 0.0) + v
        end
        f.parent === nothing || push!(regional, (f.iso3, f.parent, shares))
    end
    for (_, parent, shares) in regional
        total = by_code[parent]
        for (c, v) in shares
            haskey(total, c) && (total[c] = max(0.0, total[c] - v))
        end
    end
    lon_idx, lat_idx, iso3, fraction = Int[], Int[], String[], Float64[]
    for code in sort!(collect(keys(by_code))), ((k, i), v) in sort!(collect(by_code[code]))
        v >= MIN_SHARE || continue
        push!(lon_idx, order[k]); push!(lat_idx, rows[i]); push!(iso3, code)
        push!(fraction, min(v, 1.0))
    end
    return DataFrame(lon_idx = lon_idx, lat_idx = lat_idx, iso3 = iso3, fraction = fraction)
end

function build_country_cells(df::DataFrame, lat::Vector{Float64})
    countries = Dict{String, NamedTuple{(:cells, :weights), Tuple{Vector{CartesianIndex{2}}, Vector{Float64}}}}()
    for group in groupby(df, :iso3)
        cells = [CartesianIndex(r.lon_idx, r.lat_idx) for r in eachrow(group)]
        weights = [r.fraction * cosd(lat[r.lat_idx]) for r in eachrow(group)]
        countries[group.iso3[1]] = (cells = cells, weights = weights)
    end
    return countries
end

end # module HazardDataFetch
