module HazardTransform

# Hazard transformation from the ERA5 grids to national annual values, as set
# out in docs/manual.md ("Hazard transformation method"). It runs in three
# stages, one latitude band of grid cells at a time:
#
#   1. daily indicators for each cell, 1950-2025, as one continuous record;
#   2. marginal and copula fits for each cell on the baseline 1950-1979;
#   3. joint extremes and return periods for each cell-day, then the national
#      annual values.
#
# Every grid year must be on local disk, laid out like HazardDataFetch.GRID_DIR
# (<grid_dir>/<year>/era5_<variable>_<statistic>_<year>.nc).

using Dates
using NCDatasets
import DataFrames
using DataFrames: DataFrame
import DuckDB
using DuckDB: DBInterface
using Random
using Statistics: mean, std
import Distributions
using Distributions: UnivariateDistribution, Normal, Gamma, LogNormal, Exponential, Beta,
    Gumbel, cdf, ccdf, fit_mle, loglikelihood
import Copulas

using ..CDSAPI: logmsg
using ..HazardDataFetch: VARIABLE_STATS, GRID_DIR, nc_path, find_data_variable,
    get_unit_assignment

# Band checkpoints (stage 3), beside the grids and ignored by git like them.
const BANDS_DIR = "DatAdapt-database/raw/era5_bands"

# The whole daily record, its baseline (manual, Step 1) and the years the
# national values cover.
const RECORD_YEARS = 1950:2025
const BASELINE_YEARS = 1950:1979
const MAIN_YEARS = 1980:2025

# ---------------------------------------------------------------------------
# Indicators and event types (manual, Step 2)
# ---------------------------------------------------------------------------

"""
    Indicator(name, sources, window, reduce, threshold)

A daily indicator for one grid cell. On each day it looks back over `window`
days, the day itself included. `sources` are (variable, statistic) pairs in
native ERA5 units; with several sources their daily values are added first
(surface + sub-surface runoff). `reduce` is `:sum`, `:mean`, or `:count_below`,
the number of days in the window whose value is below `threshold`.
"""
struct Indicator
    name::String
    sources::Vector{Tuple{String, String}}
    window::Int
    reduce::Symbol
    threshold::Float64
end
Indicator(name, sources, window, reduce) = Indicator(name, sources, window, reduce, NaN)

"""
    EventIndicator(indicator, direction, required = false)

An indicator as one event type uses it. `direction` is `:high` or `:low`,
the side on which the indicator's extremes lie for that type. Low-extreme
indicators are reversed before the copula is fitted (manual, Step 3).
`required` marks a precondition of the type: where it is almost always zero,
the type has no extremes (manual, Step 3, "Indicators that are almost always
zero").
"""
struct EventIndicator
    indicator::Indicator
    direction::Symbol
    required::Bool
end
EventIndicator(indicator, direction) = EventIndicator(indicator, direction, false)

"""
    EventType(name, indicators, reference)

One hazard definition. `reference` is `:whole_year` or `:time_of_year`, the
baseline each day is compared with (manual, Step 1).
"""
struct EventType
    name::String
    indicators::Vector{EventIndicator}
    reference::Symbol
end

const T2M_MIN = ("2m_temperature", "daily_minimum")
const T2M_MAX = ("2m_temperature", "daily_maximum")
const D2M = ("2m_dewpoint_temperature", "daily_mean")
const GUST = ("instantaneous_10m_wind_gust", "daily_maximum")
const MSLP = ("mean_sea_level_pressure", "daily_minimum")
const CAPE = ("convective_available_potential_energy", "daily_maximum")
const TP = ("total_precipitation", "daily_sum")
const SF = ("snowfall", "daily_sum")
const SD = ("snow_depth", "daily_mean")
const SRO = ("surface_runoff", "daily_sum")
const SSRO = ("sub_surface_runoff", "daily_sum")
const SWVL3 = ("volumetric_soil_water_layer_3", "daily_mean")

# A dry day has less than 1 mm of precipitation (Zhang et al., 2011); ERA5
# precipitation is in metres of water equivalent.
const DRY_DAY_M = 0.001

# Daily amounts below 0.1 mm, and negative ones, count as zero (manual, Step 3,
# "What counts as zero"). They are set to zero before the windows are summed.
const ZERO_FLOOR_M = 0.0001
const ZERO_FLOOR_SOURCES = [TP, SF, SRO, SSRO, SD]

# Sources bounded by 0 and 1, the only ones the beta distribution is tried on.
const BOUNDED_SOURCES = [SWVL3]

# Look-back windows follow the rule in the manual (Step 2, "Time step and
# look-back windows"). Indicators shared by several event types are defined
# once, so they are computed once.
const PRECIPITATION_1D = Indicator("precipitation_1d", [TP], 1, :sum)
const PRECIPITATION_5D = Indicator("precipitation_5d", [TP], 5, :sum)
const RUNOFF_5D = Indicator("runoff_5d", [SRO, SSRO], 5, :sum)
const SOIL_MOISTURE_1D = Indicator("soil_moisture_1d", [SWVL3], 1, :mean)
const SNOWFALL_5D = Indicator("snowfall_5d", [SF], 5, :sum)
const SNOW_DEPTH_1D = Indicator("snow_depth_1d", [SD], 1, :mean)
const TMAX_1D = Indicator("tmax_1d", [T2M_MAX], 1, :mean)
const TMAX_3D = Indicator("tmax_3d", [T2M_MAX], 3, :mean)
const TMAX_30D = Indicator("tmax_30d", [T2M_MAX], 30, :mean)
const TMIN_3D = Indicator("tmin_3d", [T2M_MIN], 3, :mean)
const DEWPOINT_1D = Indicator("dewpoint_1d", [D2M], 1, :mean)
const DEWPOINT_3D = Indicator("dewpoint_3d", [D2M], 3, :mean)
const GUST_1D = Indicator("gust_1d", [GUST], 1, :mean)
const MSLP_MIN_1D = Indicator("mslp_min_1d", [MSLP], 1, :mean)
const CAPE_1D = Indicator("cape_1d", [CAPE], 1, :mean)
const DRY_DAYS_90D = Indicator("dry_days_90d", [TP], 90, :count_below, DRY_DAY_M)

high(i) = EventIndicator(i, :high)
low(i) = EventIndicator(i, :low)
required(i) = EventIndicator(i, :high, true)

# The eight hazard definitions of the manual (Step 2, "Indicators by EM-DAT
# type"), named after the EM-DAT disaster types they characterise.
const EVENT_TYPES = [
    EventType("Flood",
        [high(PRECIPITATION_5D), high(PRECIPITATION_1D), high(RUNOFF_5D), high(SOIL_MOISTURE_1D)],
        :whole_year),
    EventType("Mass movement (wet, landslide)",
        [high(PRECIPITATION_5D), high(SOIL_MOISTURE_1D)],
        :whole_year),
    EventType("Mass movement (wet, avalanche)",
        [required(SNOWFALL_5D), required(SNOW_DEPTH_1D), high(TMAX_1D)],
        :time_of_year),
    EventType("Storm",
        [high(GUST_1D), low(MSLP_MIN_1D), high(PRECIPITATION_1D), high(CAPE_1D)],
        :whole_year),
    EventType("Extreme temperature (heat)",
        [high(TMAX_3D), high(TMIN_3D), high(DEWPOINT_3D)],
        :whole_year),
    EventType("Extreme temperature (cold)",
        [low(TMIN_3D), low(TMAX_3D), high(SNOWFALL_5D)],
        :whole_year),
    EventType("Drought",
        [high(TMAX_30D), high(DRY_DAYS_90D), low(SOIL_MOISTURE_1D)],
        :time_of_year),
    EventType("Wildfire",
        [high(TMAX_1D), low(DEWPOINT_1D), high(GUST_1D), low(SOIL_MOISTURE_1D)],
        :whole_year),
]

"All distinct indicators used by the event types, each listed once."
all_indicators() = unique(ei.indicator for e in EVENT_TYPES for ei in e.indicators)

"All distinct (variable, statistic) sources the indicators read."
all_sources() = unique(src for ind in all_indicators() for src in ind.sources)

# ---------------------------------------------------------------------------
# Reading a latitude band from every grid year
# ---------------------------------------------------------------------------

grid_path(grid_dir, (variable, statistic), year) =
    joinpath(grid_dir, string(year), basename(nc_path(variable, statistic, year)))

"Every day from 1 January of the first year to 31 December of the last."
record_dates(years::UnitRange{Int}) = collect(Date(first(years), 1, 1):Day(1):Date(last(years), 12, 31))

"""
    read_band(grid_dir, source, years, rows, cells) -> Matrix{Float32}

Read one (variable, statistic) source for the given cells from every year's
grid file, as one continuous daily record. The result has one row per day of
`record_dates(years)` and one column per cell. `rows` is the range of latitude
indices the band covers, and every cell (a CartesianIndex of longitude and
latitude index) must lie in it. Missing values become NaN.

Errors if a year's file is absent, if its grid differs from the first year's,
or if its days are not exactly that calendar year.
"""
function read_band(grid_dir::String, source::Tuple{String, String}, years::UnitRange{Int},
                   rows::UnitRange{Int}, cells::Vector{CartesianIndex{2}})
    all(c -> c[2] in rows, cells) || error("Cells outside latitude rows $rows")
    out = Matrix{Float32}(undef, length(record_dates(years)), length(cells))
    offset = 0
    ref_lon = ref_lat = nothing
    for year in years
        path = grid_path(grid_dir, source, year)
        isfile(path) || error("Missing grid file $path")
        NCDataset(path) do ds
            lon = Float64.(ds["longitude"][:])
            lat = Float64.(ds["latitude"][:])
            if ref_lon === nothing
                ref_lon, ref_lat = lon, lat
            elseif lon != ref_lon || lat != ref_lat
                error("Grid of $path differs from that of $(first(years))")
            end
            days = Date.(ds["valid_time"][:])
            days == collect(Date(year, 1, 1):Day(1):Date(year, 12, 31)) ||
                error("$path does not hold exactly the days of $year")
            v = ds[find_data_variable(ds)]
            dimnames(v) == ("longitude", "latitude", "valid_time") ||
                error("Unexpected dimension order $(dimnames(v)) in $path")
            slab = v[:, rows, :]
            r0 = first(rows) - 1
            @inbounds for (k, c) in enumerate(cells), t in eachindex(days)
                out[offset + t, k] = coalesce(slab[c[1], c[2] - r0, t], NaN32)
            end
            offset += length(days)
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# Daily indicators
# ---------------------------------------------------------------------------

# Each day's value over the `w` days ending on it. The first w - 1 days have
# no full window and stay NaN, as does any window holding a NaN. Summing each
# window directly, rather than with a running total, keeps a window of zeros
# exactly zero.
function rolling!(y::AbstractVector{Float32}, x::AbstractVector{Float32}, w::Int, mean::Bool)
    fill!(y, NaN32)
    @inbounds for t in w:length(x)
        s = 0.0
        for k in (t - w + 1):t
            s += x[k]
        end
        y[t] = Float32(mean ? s / w : s)
    end
    return y
end

# Number of days in the `w`-day window below `threshold`, NaN while the window
# is not full or holds a NaN.
function rolling_count_below!(y::AbstractVector{Float32}, x::AbstractVector{Float32},
                              w::Int, threshold::Float64)
    fill!(y, NaN32)
    below = 0
    nans = 0
    @inbounds for t in eachindex(x)
        v = x[t]
        isnan(v) ? (nans += 1) : (v < threshold && (below += 1))
        if t > w
            u = x[t - w]
            isnan(u) ? (nans -= 1) : (u < threshold && (below -= 1))
        end
        if t >= w && nans == 0
            y[t] = below
        end
    end
    return y
end

"Set values below `floor`, negative ones included, to zero. NaN stays NaN."
function floor_small!(x::AbstractArray{Float32}, floor::Real)
    f = Float32(floor)
    @inbounds for i in eachindex(x)
        x[i] < f && (x[i] = 0.0f0)
    end
    return x
end

"""
    compute_indicator(ind, sources) -> Matrix{Float32}

Compute an indicator for every day and cell, from `sources`, a Dict of
(variable, statistic) => day × cell matrix as returned by `read_band`.
"""
function compute_indicator(ind::Indicator, sources::AbstractDict)
    x = copy(sources[ind.sources[1]])
    for src in ind.sources[2:end]
        x .+= sources[src]
    end
    y = similar(x)
    for k in axes(x, 2)
        xk = view(x, :, k)
        yk = view(y, :, k)
        if ind.reduce === :sum
            rolling!(yk, xk, ind.window, false)
        elseif ind.reduce === :mean
            rolling!(yk, xk, ind.window, true)
        elseif ind.reduce === :count_below
            rolling_count_below!(yk, xk, ind.window, ind.threshold)
        else
            error("Unknown reduction $(ind.reduce) for $(ind.name)")
        end
    end
    return y
end

"""
    band_indicators(grid_dir, years, rows, cells) -> (dates, indicators)

Stage 1 for one latitude band: read every source the indicators need and
compute every indicator, for each day of `years` and each of `cells`.
`indicators` maps each indicator's name to a day × cell matrix; `dates` gives
the day of each row.
"""
function band_indicators(grid_dir::String, years::UnitRange{Int},
                         rows::UnitRange{Int}, cells::Vector{CartesianIndex{2}})
    sources = Dict{Tuple{String, String}, Matrix{Float32}}()
    for src in all_sources()
        logmsg("Rows $rows: reading $(src[1]) / $(src[2]), $(first(years))-$(last(years))...")
        sources[src] = read_band(grid_dir, src, years, rows, cells)
        src in ZERO_FLOOR_SOURCES && floor_small!(sources[src], ZERO_FLOOR_M)
    end
    indicators = Dict(ind.name => compute_indicator(ind, sources) for ind in all_indicators())
    return (dates = record_dates(years), indicators = indicators)
end

# ---------------------------------------------------------------------------
# Stage 2: marginal and copula fits (manual, Step 3)
# ---------------------------------------------------------------------------

# An indicator is left out of a cell's copula when fewer than this many of its
# baseline reference days differ from its most common value (manual, Step 3,
# "Indicators that are almost always zero" and "Indicators that never vary").
const MIN_INFORMATIVE_DAYS = 30

# Probabilities are kept this far inside (0, 1), where copula densities and
# return periods stay finite.
const U_EPS = 1e-10

# A day is a joint extreme above this quantile of the Kendall distribution.
const JOINT_EXTREME_LEVEL = 0.95

# Days either side of a calendar day in the time-of-year window (manual, Step 1).
const SEASON_HALF_WIDTH = 15

# Seed of the draws that spread tied values, fixed so results are reproducible.
const TIE_SEED = 1950

zero_mass(ind::Indicator) = ind.reduce !== :count_below && all(in(ZERO_FLOOR_SOURCES), ind.sources)
is_count(ind::Indicator) = ind.reduce === :count_below
bounded(ind::Indicator) = all(in(BOUNDED_SOURCES), ind.sources)

"""
    most_common(x) -> (value, others)

The most common non-NaN value of `x`, and how many non-NaN values differ from
it. `(NaN, 0)` when every value is NaN.
"""
function most_common(x::AbstractVector{<:Real})
    v = sort!(filter(!isnan, collect(x)))
    isempty(v) && return (NaN, 0)
    best, best_n = v[1], 0
    i = 1
    while i <= length(v)
        j = i
        while j < length(v) && v[j + 1] == v[i]
            j += 1
        end
        if j - i + 1 > best_n
            best, best_n = v[i], j - i + 1
        end
        i = j + 1
    end
    return (Float64(best), length(v) - best_n)
end

# ---------------------------------------------------------------------------
# Marginals
# ---------------------------------------------------------------------------

"""
    fit_gumbel(x) -> Gumbel

Maximum-likelihood fit of the Gumbel distribution for maxima, which
Distributions.jl does not provide. The scale β solves
β = mean(x) - Σ xᵢ e^(-xᵢ/β) / Σ e^(-xᵢ/β), found by Newton's method kept
inside a bracket; the location then follows in closed form.
"""
function fit_gumbel(x::AbstractVector{Float64})
    n = length(x)
    m = minimum(x)
    sd = std(x)
    (isfinite(sd) && sd > 0) || error("A Gumbel fit needs values that vary")
    ybar = mean(x) - m
    # The likelihood equation in β and its derivative, on values shifted to
    # start at zero so that the weights e^(-y/β) stay within [0, 1]. The
    # equation rises with β, so it has one root.
    function equation(β)
        sw = swy = swy2 = 0.0
        @inbounds for xi in x
            y = xi - m
            w = exp(-y / β)
            sw += w
            swy += w * y
            swy2 += w * y * y
        end
        my = swy / sw
        return β - ybar + my, 1 + (swy2 / sw - my^2) / β^2
    end
    β = sqrt(6) * sd / π
    lo, hi = 0.0, Inf
    for _ in 1:200
        f, df = equation(β)
        f < 0 ? (lo = β) : (hi = β)
        (abs(f) <= 1e-12 * β || hi - lo <= 1e-14 * β) && break
        next = β - f / df
        if !(lo < next < hi)
            next = isfinite(hi) ? (lo + hi) / 2 : 2β
        end
        β = next
    end
    μ = m - β * log(sum(xi -> exp(-(xi - m) / β), x) / n)
    return Gumbel(μ, β)
end

"""
    Fitted(family, dist, aic)

A candidate distribution fitted by maximum likelihood (manual, Step 3,
"Candidate distributions"). For `:gumbel_min`, the Gumbel for minima, `dist` is
the Gumbel for maxima fitted to the negated values.
"""
struct Fitted
    family::Symbol
    dist::UnivariateDistribution
    aic::Float64
end

fitted_cdf(g::Fitted, x::Real) = g.family === :gumbel_min ? ccdf(g.dist, -x) : cdf(g.dist, x)

const FAMILY_TYPES = Dict(:normal => Normal, :gamma => Gamma, :lognormal => LogNormal,
                          :exponential => Exponential, :beta => Beta)

"The candidates whose range holds every value of `x`."
function candidate_families(x::AbstractVector{Float64}, bounded::Bool)
    families = [:normal, :gumbel_max, :gumbel_min]
    all(>(0), x) && append!(families, [:gamma, :lognormal, :exponential])
    bounded && all(v -> 0 < v < 1, x) && push!(families, :beta)
    return families
end

function fit_family(family::Symbol, x::AbstractVector{Float64})
    if family === :gumbel_max
        d = fit_gumbel(x)
        ll = loglikelihood(d, x)
    elseif family === :gumbel_min
        d = fit_gumbel(-x)
        ll = loglikelihood(d, -x)
    else
        d = fit_mle(FAMILY_TYPES[family], x)
        ll = loglikelihood(d, x)
    end
    k = family === :exponential ? 1 : 2
    return Fitted(family, d, 2k - 2ll)
end

"""
    best_fit(x, bounded) -> Fitted

The candidate with the lowest AIC (manual, Step 3). Candidates that cannot be
fitted to `x` are skipped; it errors if none can.
"""
function best_fit(x::AbstractVector{Float64}, bounded::Bool)
    best = nothing
    for family in candidate_families(x, bounded)
        g = try
            fit_family(family, x)
        catch err
            err isa InterruptException && rethrow()
            continue
        end
        isfinite(g.aic) || continue
        (best === nothing || g.aic < best.aic) && (best = g)
    end
    best === nothing && error("No candidate distribution could be fitted to $(length(x)) values")
    return best
end

"""
    Marginal

An indicator's fitted marginal in one cell, on one baseline reference
(manual, Step 3). `kind` is one of:

- `:continuous`, with `g` fitted to every value;
- `:zero_mass`, a share `p0` of zero days and `g` fitted to the other days;
- `:count`, a whole number from 0 to `cap`, with a share `pcap` of days at
  the cap and `g` fitted to the other days, truncated to the counts it covers
  (`glo` and `ghi` are G at the truncation bounds).
"""
struct Marginal
    kind::Symbol
    g::Fitted
    p0::Float64
    cap::Int
    pcap::Float64
    glo::Float64
    ghi::Float64
end

count_upper(m::Marginal) = m.pcap > 0 ? m.cap - 0.5 : m.cap + 0.5

"Fit an indicator's marginal to its values `x` on the baseline reference days."
function fit_marginal(ind::Indicator, x::AbstractVector{Float64})
    if zero_mass(ind)
        nz = count(<=(0), x)
        g = best_fit(nz > 0 ? x[x .> 0] : x, false)
        return Marginal(:zero_mass, g, nz / length(x), 0, 0.0, 0.0, 1.0)
    elseif is_count(ind)
        cap = ind.window
        ncap = count(>=(cap), x)
        g = best_fit(ncap > 0 ? x[x .< cap] : x, false)
        upper = ncap > 0 ? cap - 0.5 : cap + 0.5
        return Marginal(:count, g, 0.0, cap, ncap / length(x),
                        fitted_cdf(g, -0.5), fitted_cdf(g, upper))
    else
        return Marginal(:continuous, best_fit(x, bounded(ind)), 0.0, 0, 0.0, 0.0, 1.0)
    end
end

# The count marginal below the cap: G truncated to the counts it covers and
# scaled to the share of days below the cap.
function count_cdf(m::Marginal, y::Float64)
    y <= -0.5 && return 0.0
    y >= count_upper(m) && return 1 - m.pcap
    return (1 - m.pcap) * (fitted_cdf(m.g, y) - m.glo) / (m.ghi - m.glo)
end

"""
    prob_range(m, x) -> (lo, hi)

The probability range the marginal gives value `x`: one point for a
continuous value, and for a tied value (a zero day, a whole-number count) the
range its probability is drawn from (manual, Step 3, "Tied values are spread
at random").
"""
function prob_range(m::Marginal, x::Real)
    if m.kind === :continuous
        F = fitted_cdf(m.g, x)
        return (F, F)
    elseif m.kind === :zero_mass
        x <= 0 && return (0.0, m.p0)
        F = m.p0 + (1 - m.p0) * fitted_cdf(m.g, x)
        return (F, F)
    else
        k = round(Int, x)
        m.pcap > 0 && k >= m.cap && return (1 - m.pcap, 1.0)
        return (count_cdf(m, k - 0.5), count_cdf(m, k + 0.5))
    end
end

"""
    pit(m, x, v, reversed) -> Float64

The probability u of value `x`, with `v`, a uniform draw, placing it within
its range, and reversed (1 - u) for a low-extreme indicator.
"""
function pit(m::Marginal, x::Real, v::Float64, reversed::Bool)
    lo, hi = prob_range(m, x)
    u = clamp(lo + v * (hi - lo), U_EPS, 1 - U_EPS)
    return reversed ? 1 - u : u
end

"""
    tie_draws(cell, n) -> Dict{String, Vector{Float64}}

Uniform draws for one grid cell, one per day for each indicator, that spread
tied values (manual, Step 3). They depend only on the cell and the indicator,
so a day keeps the same draw in the fits and when it is classified, and an
indicator shared by several event types has one draw per day.
"""
function tie_draws(cell::CartesianIndex{2}, n::Int)
    Dict(ind.name => rand(Xoshiro(((TIE_SEED * 10_000 + cell[1]) * 1_000 + cell[2]) * 100 + k), n)
         for (k, ind) in enumerate(all_indicators()))
end

# ---------------------------------------------------------------------------
# Archimedean copulas and their Kendall distribution
# ---------------------------------------------------------------------------

"""
    Archimedean(family, θ, dim)

A fitted Archimedean copula, `:clayton`, `:frank`, `:gumbel` or `:joe`, with
the parameterisation of Copulas.jl. `:single` stands for an event type with
one indicator left, whose own probability is the joint value.
"""
struct Archimedean
    family::Symbol
    θ::Float64
    dim::Int
end

# The generator ψ, with C(u) = ψ(Σ ψ⁻¹(uᵢ)), and its inverse.
function generator(C::Archimedean, s::Float64)
    θ = C.θ
    if C.family === :clayton
        iszero(θ) && return exp(-s)
        return 1 + θ * s <= 0 ? 0.0 : exp(-log1p(θ * s) / θ)
    elseif C.family === :frank
        iszero(θ) && return exp(-s)
        return -log1p(exp(-s) * expm1(-θ)) / θ
    elseif C.family === :gumbel
        return exp(-s^(1 / θ))
    elseif C.family === :joe
        return 1 - (-expm1(-s))^(1 / θ)
    end
    error("Unknown copula family $(C.family)")
end

function inv_generator(C::Archimedean, u::Float64)
    θ = C.θ
    if C.family === :clayton
        iszero(θ) && return -log(u)
        return expm1(-θ * log(u)) / θ
    elseif C.family === :frank
        iszero(θ) && return -log(u)
        return -log(expm1(-θ * u) / expm1(-θ))
    elseif C.family === :gumbel
        return (-log(u))^θ
    elseif C.family === :joe
        return -log1p(-(1 - u)^θ)
    end
    error("Unknown copula family $(C.family)")
end

"The joint value C(u₁, …, uₘ) of one day (manual, Step 3)."
function joint_value(C::Archimedean, u::AbstractVector{<:Real})
    C.family === :single && return Float64(u[1])
    s = 0.0
    for ui in u
        s += inv_generator(C, Float64(ui))
    end
    return generator(C, s)
end

"""
    kendall(C, t) -> Float64

The Kendall distribution K_C(t) = P(C(U) ≤ t) of an Archimedean copula in
dimension d, in closed form (Barbe et al., 1996):

    K_C(t) = Σₖ₌₀^(d-1) (-s)ᵏ ψ⁽ᵏ⁾(s) / k!,  s = ψ⁻¹(t),

with ψ the generator. The terms are written out for each family, for up to
four indicators.
"""
function kendall(C::Archimedean, t::Float64)
    t <= 0 && return 0.0
    t >= 1 && return 1.0
    C.family === :single && return t
    d = C.dim
    d <= 4 || error("The Kendall distribution is written out for up to 4 indicators, not $d")
    θ = C.θ
    K = t
    if C.family === :clayton || iszero(θ)
        # Clayton, and independence (θ = 0 for Clayton and Frank):
        # term k is t Lᵏ Π_{j<k} (1 + jθ) / k!, with L = (1 - t^θ) / θ
        L = iszero(θ) ? -log(t) : -expm1(θ * log(t)) / θ
        a = 1.0
        for k in 1:d-1
            a *= (1 + (k - 1) * θ) * L / k
            K += t * a
        end
    elseif C.family === :frank
        # (-1)ᵏ ψ⁽ᵏ⁾(s) = (1/θ) Σₙ nᵏ⁻¹ yⁿ with y = 1 - e^(-θt), summed in
        # closed form
        s = inv_generator(C, t)
        e = exp(θ * t)
        L = expm1(θ * t) / θ
        y = -expm1(-θ * t)
        D = (L, L * e, L * e^2 * (1 + y))
        for k in 1:d-1
            K += s^k / factorial(k) * D[k]
        end
    elseif C.family === :gumbel
        # ψ(s) = exp(-s^a), a = 1/θ; with x = -log t, sᵏ ψ⁽ᵏ⁾(s) is t times
        # a polynomial in x
        a = 1 / θ
        x = -log(t)
        D = (a * x,
             a^2 * x^2 - a * (a - 1) * x,
             a^3 * x^3 - 3 * a^2 * (a - 1) * x^2 + a * (a - 1) * (a - 2) * x)
        for k in 1:d-1
            K += t * D[k] / factorial(k)
        end
    elseif C.family === :joe
        # ψ(s) = 1 - zᵃ with z = 1 - e^(-s), a = 1/θ; the terms are sums of
        # sᵏ z^(a-j) wʲ, w = 1 - z, computed in logs because z can be tiny
        a = 1 / θ
        lz = θ * log1p(-t)
        z = exp(lz)
        w = -expm1(lz)
        s = z < 0.5 ? -log1p(-z) : -log(w)
        ls = s > 0 ? log(s) : lz
        c2 = a * (a - 1)
        coefs = ((a,), (a, -c2), (a, -3c2, c2 * (a - 2)))
        for k in 1:d-1
            term = 0.0
            for (j, c) in enumerate(coefs[k])
                iszero(c) && continue
                term += c * exp(k * ls + (a - j) * lz) * w^j
            end
            K += term / factorial(k)
        end
    else
        error("Unknown copula family $(C.family)")
    end
    return clamp(K, t, 1.0)
end

"The joint value t with K_C(t) = p, by bisection."
function kendall_quantile(C::Archimedean, p::Float64)
    lo, hi = 0.0, 1.0
    for _ in 1:200
        mid = (lo + hi) / 2
        kendall(C, mid) < p ? (lo = mid) : (hi = mid)
        hi - lo <= 1e-15 && break
    end
    return (lo + hi) / 2
end

"The Kendall return period, in years, of a day with joint value `c` (manual, Step 4)."
return_period_years(C::Archimedean, c::Float64) = 1 / (365.25 * (1 - kendall(C, c)))

const COPULA_FAMILIES = (:clayton => Copulas.ClaytonCopula, :frank => Copulas.FrankCopula,
                         :gumbel => Copulas.GumbelCopula, :joe => Copulas.JoeCopula)

"""
    fit_copula(U) -> Archimedean

Fit the four Archimedean families to `U` (indicators × days, on the
probability scale) by maximum likelihood with Copulas.jl, and keep the most
likely. Each family has one parameter, so that is also the lowest AIC.
"""
function fit_copula(U::AbstractMatrix{Float64})
    best = nothing
    best_ll = -Inf
    for (family, F) in COPULA_FAMILIES
        C = try
            Distributions.fit(F, U; method = :mle)
        catch err
            err isa InterruptException && rethrow()
            continue
        end
        ll = Distributions.loglikelihood(C, U)
        if isfinite(ll) && ll > best_ll
            best, best_ll = Archimedean(family, Float64(C.G.θ), size(U, 1)), ll
        end
    end
    best === nothing && error("No copula family could be fitted to $(size(U, 2)) days")
    return best
end

# ---------------------------------------------------------------------------
# Fits for one event type and one cell
# ---------------------------------------------------------------------------

"""
    EventFit

An event type's fit in one cell, on one baseline reference. `used` lists the
positions, among the type's indicators, of those in the copula, with their
marginals and whether each is reversed. A day is a joint extreme when its
joint value is above `threshold`. With `has_extremes` false the cell has no
extremes of the type on this reference, because a precondition is absent.
"""
struct EventFit
    has_extremes::Bool
    used::Vector{Int}
    marginals::Vector{Marginal}
    reversed::Vector{Bool}
    copula::Archimedean
    threshold::Float64
end

const NO_EXTREMES = EventFit(false, Int[], Marginal[], Bool[], Archimedean(:single, NaN, 0), Inf)

"""
    fit_event(e, X, V) -> EventFit

Stage 2 for one event type, cell and baseline reference. Column j of `X`
holds the type's j-th indicator on the reference days, and column j of `V`
the uniform draws that spread its tied values.
"""
function fit_event(e::EventType, X::AbstractMatrix{<:Real}, V::AbstractMatrix{Float64})
    kept = Int[]
    for (j, ei) in enumerate(e.indicators)
        value, others = most_common(view(X, :, j))
        if others >= MIN_INFORMATIVE_DAYS
            push!(kept, j)
        elseif ei.required && !(value > 0)
            # A precondition that is almost always absent, such as snow for
            # Avalanche. One that never varies from a non-zero value, such as
            # snow depth on a glacier, is always met and is just left out.
            return NO_EXTREMES
        end
    end
    isempty(kept) && return NO_EXTREMES
    rows = [r for r in axes(X, 1) if all(j -> !isnan(X[r, j]), kept)]
    marginals = [fit_marginal(e.indicators[j].indicator, Float64.(X[rows, j])) for j in kept]
    reversed = [e.indicators[j].direction === :low for j in kept]
    U = Matrix{Float64}(undef, length(kept), length(rows))
    for (a, j) in enumerate(kept), (b, r) in enumerate(rows)
        U[a, b] = pit(marginals[a], X[r, j], V[r, j], reversed[a])
    end
    C = length(kept) == 1 ? Archimedean(:single, NaN, 1) : fit_copula(U)
    return EventFit(true, kept, marginals, reversed, C, kendall_quantile(C, JOINT_EXTREME_LEVEL))
end

"Day of the year on a 366-day calendar, so 29 February is day 60 in every year."
calendar_day(d::Date) = dayofyear(Date(2000, month(d), day(d)))

"Distance in days between two days of the 366-day calendar, across the new year."
calendar_distance(a::Int, b::Int) = (δ = abs(a - b); min(δ, 366 - δ))

"Positions of the days, given by their calendar days, in the time-of-year window of calendar day `c`."
season_rows(cdays::AbstractVector{Int}, c::Int) =
    findall(k -> calendar_distance(k, c) <= SEASON_HALF_WIDTH, cdays)

"""
    fit_cell(series, draws, dates; baseline = BASELINE_YEARS) -> Dict{String, Vector{EventFit}}

Stage 2 for one grid cell. `series` maps each indicator's name to its daily
values on `dates` (stage 1), and `draws` maps it to the draws of `tie_draws`.
Each event type gets one fit on a whole-year reference, or 366 on a
time-of-year reference, one per calendar day.
"""
function fit_cell(series::AbstractDict, draws::AbstractDict, dates::Vector{Date};
                  baseline::UnitRange{Int} = BASELINE_YEARS)
    base = findall(d -> year(d) in baseline, dates)
    cdays = calendar_day.(dates[base])
    fits = Dict{String, Vector{EventFit}}()
    for e in EVENT_TYPES
        names = [ei.indicator.name for ei in e.indicators]
        X = reduce(hcat, [series[n][base] for n in names])
        V = reduce(hcat, [draws[n][base] for n in names])
        fits[e.name] = if e.reference === :whole_year
            [fit_event(e, X, V)]
        else
            map(1:366) do c
                rows = season_rows(cdays, c)
                fit_event(e, view(X, rows, :), view(V, rows, :))
            end
        end
    end
    return fits
end

# ---------------------------------------------------------------------------
# Stage 3: joint extremes, return periods and national values (manual, Step 4)
# ---------------------------------------------------------------------------

"""
    classify_cell(fits, series, draws, dates, days) -> Dict{String, NamedTuple}

Stage 3 for one grid cell, on the days at positions `days` of `dates`. For
each event type it gives `extreme`, whether each day is a joint extreme, and
`T`, each day's Kendall return period in years, NaN where the type cannot
occur that day (manual, Step 4).
"""
function classify_cell(fits::AbstractDict, series::AbstractDict, draws::AbstractDict,
                       dates::Vector{Date}, days::AbstractVector{Int})
    cdays = [calendar_day(dates[d]) for d in days]
    out = Dict{String, NamedTuple{(:extreme, :T), Tuple{BitVector, Vector{Float64}}}}()
    for e in EVENT_TYPES
        names = [ei.indicator.name for ei in e.indicators]
        extreme = falses(length(days))
        T = fill(NaN, length(days))
        u = Vector{Float64}(undef, length(names))
        for (k, d) in enumerate(days)
            f = e.reference === :whole_year ? fits[e.name][1] : fits[e.name][cdays[k]]
            f.has_extremes || continue
            m = length(f.used)
            complete = true
            for a in 1:m
                name = names[f.used[a]]
                x = series[name][d]
                if isnan(x)
                    complete = false
                    break
                end
                u[a] = pit(f.marginals[a], x, draws[name][d], f.reversed[a])
            end
            complete || continue
            c = joint_value(f.copula, view(u, 1:m))
            extreme[k] = c > f.threshold
            T[k] = return_period_years(f.copula, c)
        end
        out[e.name] = (extreme = extreme, T = T)
    end
    return out
end

"""
    band_partials(results, countries, areas, dates, days) -> (daily, peak)

A band's share of the national values. `results` holds `classify_cell`'s
output for each cell, `countries` and `areas` each cell's country code and
area weight. `daily` has the area in joint extreme per country, day and
event type, only where it is above zero; `peak` has the highest return period
per country, year and event type, only where one is defined.
"""
function band_partials(results::AbstractVector, countries::AbstractVector{String},
                       areas::AbstractVector{Float64}, dates::Vector{Date},
                       days::AbstractVector{Int})
    n = length(days)
    day_years = year.(dates[days])
    years = unique(day_years)
    year_index = day_years .- first(years) .+ 1
    acc = Dict{Tuple{String, String}, Tuple{Vector{Float64}, Vector{Float64}}}()
    for (k, res) in enumerate(results), e in EVENT_TYPES
        area, peak = get!(() -> (zeros(n), fill(NaN, length(years))), acc, (countries[k], e.name))
        r = res[e.name]
        a = areas[k]
        @inbounds for t in 1:n
            r.extreme[t] && (area[t] += a)
            T = r.T[t]
            # Highest defined return period; true also while the peak is NaN
            if !isnan(T) && !(T <= peak[year_index[t]])
                peak[year_index[t]] = T
            end
        end
    end
    daily = DataFrame(country_code = String[], date = Date[], event_type = String[],
                      extreme_area = Float64[])
    peak = DataFrame(country_code = String[], year = Int[], event_type = String[],
                     peak_return_period_years = Float64[])
    for ((country, etype), (area, peaks)) in sort!(collect(acc); by = first)
        for t in 1:n
            area[t] > 0 && push!(daily, (country, dates[days[t]], etype, area[t]))
        end
        for (i, y) in enumerate(years)
            isnan(peaks[i]) || push!(peak, (country, y, etype, peaks[i]))
        end
    end
    return daily, peak
end

sql_path(path::String) = "'" * replace(path, "'" => "''") * "'"

function write_parquet(df::DataFrame, path::String)
    con = DuckDB.DB()
    try
        DuckDB.register_data_frame(con, df, "t")
        DBInterface.execute(con, "COPY t TO $(sql_path(path)) (FORMAT parquet)")
    finally
        DBInterface.close!(con)
    end
end

band_name(rows::UnitRange{Int}) = "band_$(first(rows))-$(last(rows))"
band_done(out_dir::String, rows::UnitRange{Int}) = isfile(joinpath(out_dir, band_name(rows) * ".done"))

"""
    run_band(grid_dir, out_dir, rows, cells, countries, areas;
             years = RECORD_YEARS, baseline = BASELINE_YEARS, main = MAIN_YEARS) -> Bool

All three stages for the cells of one latitude band (`rows`), with each cell's
country code and area weight. Writes the band's checkpoint to `out_dir`: the
two tables of `band_partials` as Parquet files, then a `.done` marker. A
band whose marker exists is skipped, and `false` returned. Cells are fitted
in parallel on Julia's threads.
"""
function run_band(grid_dir::String, out_dir::String, rows::UnitRange{Int},
                  cells::Vector{CartesianIndex{2}}, countries::Vector{String},
                  areas::Vector{Float64}; years::UnitRange{Int} = RECORD_YEARS,
                  baseline::UnitRange{Int} = BASELINE_YEARS,
                  main::UnitRange{Int} = MAIN_YEARS)
    band_done(out_dir, rows) && return false
    mkpath(out_dir)
    started = time()
    dates, indicators = band_indicators(grid_dir, years, rows, cells)
    days = findall(d -> year(d) in main, dates)
    results = Vector{Any}(undef, length(cells))
    finished = Threads.Atomic{Int}(0)
    Threads.@threads :dynamic for k in eachindex(cells)
        cell = cells[k]
        try
            series = Dict(name => view(m, :, k) for (name, m) in indicators)
            draws = tie_draws(cell, length(dates))
            fits = fit_cell(series, draws, dates; baseline)
            results[k] = classify_cell(fits, series, draws, dates, days)
        catch err
            err isa InterruptException && rethrow()
            logmsg("Rows $rows: cell (lon $(cell[1]), lat $(cell[2])) failed.")
            rethrow()
        end
        done = Threads.atomic_add!(finished, 1) + 1
        done % 100 == 0 && logmsg("Rows $rows: $done of $(length(cells)) cells done.")
    end
    daily, peak = band_partials(results, countries, areas, dates, days)
    base = joinpath(out_dir, band_name(rows))
    for (df, suffix) in ((daily, "_daily.parquet"), (peak, "_peak.parquet"))
        write_parquet(df, base * suffix * ".tmp")
        mv(base * suffix * ".tmp", base * suffix; force = true)
    end
    touch(base * ".done")
    logmsg("Rows $rows: $(length(cells)) cells in $(round((time() - started) / 60; digits = 1)) min.")
    return true
end

"""
    combine_bands(out_dir, bands, country_areas; main = MAIN_YEARS) -> DataFrame

The national values (manual, Step 4) from the checkpoints of every band in
`bands`, which must all be done. `country_areas` has each country's code and
total area weight A over all its cells. One row per country, year of `main`
and event type, with `extreme_area_days`, `peak_extent` and
`peak_return_period_years` (missing where the type cannot occur).
"""
function combine_bands(out_dir::String, bands::AbstractVector{UnitRange{Int}},
                       country_areas::DataFrame; main::UnitRange{Int} = MAIN_YEARS)
    missing_bands = [b for b in bands if !band_done(out_dir, b)]
    isempty(missing_bands) ||
        error("$(length(missing_bands)) bands are not done yet, first $(first(missing_bands))")
    grid = DataFrame(
        [(country_code = r.country_code, year = y, event_type = e.name, area = r.area)
         for r in eachrow(country_areas) for y in main for e in EVENT_TYPES])
    files(suffix) = "[" * join((sql_path(joinpath(out_dir, band_name(b) * suffix)) for b in bands), ", ") * "]"
    con = DuckDB.DB()
    try
        DuckDB.register_data_frame(con, grid, "grid")
        return DataFrame(DBInterface.execute(con, """
            WITH day_area AS (
                SELECT country_code, date, event_type, sum(extreme_area) AS area
                FROM read_parquet($(files("_daily.parquet")))
                GROUP BY ALL),
            year_area AS (
                SELECT country_code, year(date) AS year, event_type,
                       sum(area) AS area_days, max(area) AS peak_area
                FROM day_area
                GROUP BY ALL),
            year_peak AS (
                SELECT country_code, year, event_type,
                       max(peak_return_period_years) AS peak_return_period_years
                FROM read_parquet($(files("_peak.parquet")))
                GROUP BY ALL)
            SELECT g.country_code, g.year, g.event_type,
                   coalesce(a.area_days, 0) / g.area AS extreme_area_days,
                   coalesce(a.peak_area, 0) / g.area AS peak_extent,
                   p.peak_return_period_years
            FROM grid g
            LEFT JOIN year_area a USING (country_code, year, event_type)
            LEFT JOIN year_peak p USING (country_code, year, event_type)
            ORDER BY g.country_code, g.year, g.event_type
            """))
    finally
        DBInterface.close!(con)
    end
end

"""
    hazard_country_year(; grid_dir = GRID_DIR, out_dir = BANDS_DIR, band_rows = 4) -> DataFrame

The whole hazard transformation: every latitude band of `band_rows` grid rows
that holds land cells, then the national values. Cells are assigned to
countries on the map shared with damage and exposure. Bands already done in
`out_dir` are skipped, so a stopped run resumes where it left off.
"""
function hazard_country_year(; grid_dir::String = GRID_DIR, out_dir::String = BANDS_DIR,
                             band_rows::Int = 4)
    first_grid = grid_path(grid_dir, first(all_sources()), first(RECORD_YEARS))
    assignment = get_unit_assignment(first_grid)
    n_lat = NCDataset(ds -> length(ds["latitude"]), first_grid)
    cell_country = Dict{CartesianIndex{2}, Tuple{String, Float64}}()
    for (code, v) in assignment, (c, w) in zip(v.cells, v.weights)
        cell_country[c] = (code, w)
    end
    bands = UnitRange{Int}[]
    for r in 1:band_rows:n_lat
        rows = r:min(r + band_rows - 1, n_lat)
        cells = sort!([c for c in keys(cell_country) if c[2] in rows])
        isempty(cells) && continue
        push!(bands, rows)
        run_band(grid_dir, out_dir, rows, cells, [cell_country[c][1] for c in cells],
                 [cell_country[c][2] for c in cells])
    end
    country_areas = DataFrame(country_code = collect(keys(assignment)),
                              area = [sum(v.weights) for v in values(assignment)])
    return combine_bands(out_dir, bands, country_areas)
end

end # module HazardTransform
