# Run from the repository root: julia --project=. test/runtests.jl
using Test
using Dates
using NCDatasets
using Random
using Statistics
using Distributions
using DataFrames
import Copulas

include(joinpath(@__DIR__, "..", "src", "DatAdapt.jl"))
const HT = DatAdapt.HazardTransform
const HDF = DatAdapt.HazardDataFetch

const FIXTURE_DIR = joinpath(@__DIR__, "fixtures", "era5_grid")

# Write a small grid file laid out like the ERA5 downloads, with the value of
# each longitude index i, latitude index j and day given by f(i, j, day).
function write_grid(dir, (variable, statistic), year, lon, lat, f)
    path = joinpath(dir, string(year), "era5_$(variable)_$(statistic)_$(year).nc")
    mkpath(dirname(path))
    days = collect(Date(year, 1, 1):Day(1):Date(year, 12, 31))
    data = Float32[f(i, j, d) for i in eachindex(lon), j in eachindex(lat), d in days]
    NCDataset(path, "c") do ds
        defDim(ds, "longitude", length(lon))
        defDim(ds, "latitude", length(lat))
        defDim(ds, "valid_time", length(days))
        defVar(ds, "longitude", Float64.(lon), ("longitude",))
        defVar(ds, "latitude", Float64.(lat), ("latitude",))
        defVar(ds, "valid_time", DateTime.(days), ("valid_time",);
               attrib = Dict("units" => "days since $year-01-01 00:00:00",
                             "calendar" => "proleptic_gregorian"))
        defVar(ds, "x", data, ("longitude", "latitude", "valid_time"))
    end
    return path
end

@testset "HazardTransform stage 1" begin

    @testset "event types match the manual" begin
        types = Dict(e.name => e for e in HT.EVENT_TYPES)
        @test length(HT.EVENT_TYPES) == 8 == length(types)
        n_indicators = Dict(
            "Flood" => 4, "Mass movement (wet, landslide)" => 2,
            "Mass movement (wet, avalanche)" => 3, "Storm" => 4,
            "Extreme temperature (heat)" => 3, "Extreme temperature (cold)" => 3,
            "Drought" => 3, "Wildfire" => 4)
        @test Dict(n => length(e.indicators) for (n, e) in types) == n_indicators
        seasonal = Set(n for (n, e) in types if e.reference === :time_of_year)
        @test seasonal == Set(["Drought", "Mass movement (wet, avalanche)"])
        @test all(e.reference in (:whole_year, :time_of_year) for e in HT.EVENT_TYPES)
        low = Set((e.name, ei.indicator.name) for e in HT.EVENT_TYPES
                  for ei in e.indicators if ei.direction === :low)
        @test low == Set([
            ("Storm", "mslp_min_1d"),
            ("Extreme temperature (cold)", "tmin_3d"),
            ("Extreme temperature (cold)", "tmax_3d"),
            ("Drought", "soil_moisture_1d"),
            ("Wildfire", "dewpoint_1d"),
            ("Wildfire", "soil_moisture_1d")])
        @test all(ei.direction in (:high, :low) for e in HT.EVENT_TYPES for ei in e.indicators)
        @test all(in(HDF.VARIABLE_STATS), HT.all_sources())
        @test length(HT.all_indicators()) == length(unique(i.name for i in HT.all_indicators()))
        @test maximum(i.window for i in HT.all_indicators()) == 90
        req = Set((e.name, ei.indicator.name) for e in HT.EVENT_TYPES
                  for ei in e.indicators if ei.required)
        @test req == Set([("Mass movement (wet, avalanche)", "snowfall_5d"),
                          ("Mass movement (wet, avalanche)", "snow_depth_1d")])
    end

    @testset "small amounts count as zero" begin
        x = Float32[0.00005, -0.00001, 0.0001, 0.002, NaN]
        HT.floor_small!(x, HT.ZERO_FLOOR_M)
        @test isequal(x, Float32[0, 0, 0.0001, 0.002, NaN])
    end

    @testset "rolling windows" begin
        x = Float32[1, 2, 3, 4, NaN, 6, 7, 8]
        y = similar(x)
        HT.rolling!(y, x, 3, false)
        @test isequal(y, Float32[NaN, NaN, 6, 9, NaN, NaN, NaN, 21])
        HT.rolling!(y, x, 3, true)
        @test isequal(y, Float32[NaN, NaN, 2, 3, NaN, NaN, NaN, 7])
        HT.rolling!(y, x, 1, false)
        @test isequal(y, x)

        # A window of zeros is exactly zero, even after non-zero days
        z = Float32[0.1, 0, 0, 0, 0]
        yz = similar(z)
        HT.rolling!(yz, z, 3, false)
        @test yz[4] === 0.0f0 && yz[5] === 0.0f0
    end

    @testset "dry-day counts" begin
        x = Float32[0.0005, 0.002, 0.0, NaN, 0.0001, 0.0002, 0.0003]
        y = similar(x)
        HT.rolling_count_below!(y, x, 2, HT.DRY_DAY_M)
        @test isequal(y, Float32[NaN, 1, 1, NaN, NaN, 2, 2])
        # Exactly 1 mm is not a dry day
        HT.rolling_count_below!(y, Float32[0.001, 0.001], 2, HT.DRY_DAY_M)
        @test y[2] == 0
    end

    @testset "reading the real fixture" begin
        source = ("2m_temperature", "daily_maximum")
        cells = vec([CartesianIndex(i, j) for i in 1:4, j in 1:4])
        m = HT.read_band(FIXTURE_DIR, source, 2024:2024, 1:4, cells)
        @test size(m) == (366, 16)
        NCDataset(joinpath(FIXTURE_DIR, "2024", "era5_2m_temperature_daily_maximum_2024.nc")) do ds
            for (k, c) in enumerate(cells)
                @test m[:, k] == Float32.(ds["t2m"][c[1], c[2], :])
            end
        end
        @test HT.record_dates(2024:2024)[60] == Date(2024, 2, 29)
        # Temperatures in Kelvin, plausible for Oslo
        @test all(240 .< m .< 310)
        # Only the band's rows can be read
        @test_throws ErrorException HT.read_band(FIXTURE_DIR, source, 2024:2024, 1:2, cells)
        # Every year must be on disk
        @test_throws ErrorException HT.read_band(FIXTURE_DIR, source, 2023:2024, 1:4, cells)
    end

    @testset "continuous record across years" begin
        dir = mktempdir()
        lon, lat = [0.0, 0.25], [60.0, 59.75, 59.5]
        source = ("2m_temperature", "daily_maximum")
        first_day = Date(2023, 1, 1)
        code(i, j, d) = i * 1_000_000 + j * 10_000 + Dates.value(d - first_day) + 1
        for year in 2023:2024
            write_grid(dir, source, year, lon, lat, code)
        end
        cells = [CartesianIndex(1, 2), CartesianIndex(2, 3)]
        m = HT.read_band(dir, source, 2023:2024, 2:3, cells)
        dates = HT.record_dates(2023:2024)
        @test size(m) == (365 + 366, 2)
        @test dates[365 + 60] == Date(2024, 2, 29)
        @test m[:, 1] == Float32[code(1, 2, d) for d in dates]
        @test m[:, 2] == Float32[code(2, 3, d) for d in dates]

        # A grid that differs from the first year's is refused
        write_grid(dir, source, 2024, [0.0, 0.5], lat, code)
        @test_throws ErrorException HT.read_band(dir, source, 2023:2024, 2:3, cells)
    end

    @testset "band indicators end to end" begin
        dir = mktempdir()
        lon, lat = [0.0, 0.25], [60.0, 59.75, 59.5]
        first_day = Date(2023, 1, 1)
        n(d) = Dates.value(d - first_day) + 1  # day number in the record
        series = Dict(
            HT.TP => (i, j, d) -> isodd(n(d)) ? 0.0005 : 0.002,
            HT.SRO => (i, j, d) -> 0.001,
            HT.SSRO => (i, j, d) -> 0.002,
            HT.T2M_MAX => (i, j, d) -> 280 + 0.01 * n(d),
            HT.SF => (i, j, d) -> 0.00005,
            HT.CAPE => (i, j, d) -> 0.00005,
        )
        for src in HT.all_sources(), year in 2023:2024
            write_grid(dir, src, year, lon, lat, get(series, src, (i, j, d) -> 1.0))
        end
        cells = [CartesianIndex(1, 2), CartesianIndex(2, 3)]
        r = HT.band_indicators(dir, 2023:2024, 2:3, cells)
        ind = r.indicators
        @test r.dates == HT.record_dates(2023:2024)
        @test Set(keys(ind)) == Set(i.name for i in HT.all_indicators())
        @test all(size(m) == (731, 2) for m in values(ind))

        # Dry days: odd days are dry, so 45 of the first 90
        @test isnan(ind["dry_days_90d"][89, 1])
        @test ind["dry_days_90d"][90, 1] == 45
        @test ind["dry_days_90d"][91, 2] == 45
        # Runoff adds its two sources, over 5 days
        @test all(isnan, ind["runoff_5d"][1:4, :])
        @test ind["runoff_5d"][5:end, :] ≈ fill(0.015f0, 727, 2)
        @test ind["precipitation_1d"][1:4, 1] == Float32[0.0005, 0.002, 0.0005, 0.002]
        # Means of a linear series, including across the year boundary
        @test isnan(ind["tmax_30d"][29, 1])
        @test ind["tmax_30d"][30, 1] ≈ 280 + 0.01 * 15.5 atol = 1e-3
        @test ind["tmax_3d"][366, 1] ≈ 280 + 0.01 * 365 atol = 1e-3
        @test ind["tmax_1d"][425, 2] ≈ 280 + 0.01 * 425 atol = 1e-3
        @test ind["soil_moisture_1d"] == fill(1.0f0, 731, 2)
        # Snowfall below 0.1 mm counts as zero; CAPE is not an amount and keeps its value
        @test all(iszero, ind["snowfall_5d"][5:end, :])
        @test ind["cape_1d"] == fill(0.00005f0, 731, 2)
    end
end

@testset "HazardTransform stage 2" begin

    @testset "most common value" begin
        @test HT.most_common([0.0, 0.0, 1.0, 2.0, 0.0]) == (0.0, 2)
        @test HT.most_common(Float32[NaN, 3, 3, NaN]) == (3.0, 0)
        v, n = HT.most_common([NaN, NaN])
        @test isnan(v) && n == 0
    end

    @testset "Gumbel fit" begin
        rng = Xoshiro(1)
        x = rand(rng, Gumbel(3.0, 2.0), 50_000)
        g = HT.fit_gumbel(x)
        @test location(g) ≈ 3.0 atol = 0.05
        @test scale(g) ≈ 2.0 atol = 0.05
        # The fit maximises the likelihood
        ll = loglikelihood(g, x)
        for (dμ, dβ) in ((0.01, 0.0), (-0.01, 0.0), (0.0, 0.01), (0.0, -0.01))
            @test loglikelihood(Gumbel(location(g) + dμ, scale(g) + dβ), x) < ll
        end
        @test_throws ErrorException HT.fit_gumbel(fill(1.0, 10))
    end

    @testset "candidate distributions" begin
        rng = Xoshiro(2)
        @test HT.best_fit(rand(rng, Gamma(2.0, 3.0), 20_000), false).family === :gamma
        @test HT.best_fit(rand(rng, Normal(-5.0, 2.0), 20_000), false).family === :normal
        # Gamma, log-normal and exponential only for positive values
        @test Set(HT.candidate_families([-1.0, 2.0], false)) == Set([:normal, :gumbel_max, :gumbel_min])
        # A long lower tail, as in winter minimum temperature
        t = 280 .- rand(rng, Gumbel(0.0, 3.0), 20_000)
        g = HT.best_fit(t, false)
        @test g.family === :gumbel_min
        @test HT.fitted_cdf(g, 275.0) ≈ ccdf(Gumbel(0.0, 3.0), 5.0) atol = 0.01
        # Beta only for bounded indicators
        s = rand(rng, Beta(2.0, 5.0), 20_000)
        @test HT.best_fit(s, true).family === :beta
        @test :beta ∉ HT.candidate_families(s, false)
    end

    @testset "zero days and dry-day counts" begin
        rng = Xoshiro(3)
        x = [rand(rng) < 0.4 ? 0.0 : rand(rng, Gamma(2.0, 0.01)) for _ in 1:20_000]
        m = HT.fit_marginal(HT.PRECIPITATION_1D, x)
        @test m.kind === :zero_mass
        @test m.p0 == count(iszero, x) / length(x)
        @test HT.prob_range(m, 0.0) == (0.0, m.p0)
        lo, hi = HT.prob_range(m, 0.02)
        @test lo == hi ≈ m.p0 + (1 - m.p0) * HT.fitted_cdf(m.g, 0.02)
        # Spread at random, the probabilities are uniform
        v = rand(rng, length(x))
        u = [HT.pit(m, x[i], v[i], false) for i in eachindex(x)]
        @test mean(u) ≈ 0.5 atol = 0.01
        @test mean(u .< 0.2) ≈ 0.2 atol = 0.01
        @test all(u[i] <= m.p0 for i in eachindex(x) if x[i] == 0)
        # Reversal
        @test HT.pit(m, 0.02, 0.5, true) ≈ 1 - HT.pit(m, 0.02, 0.5, false)

        # Counts with a mass at the cap of 90
        k = [rand(rng) < 0.3 ? 90.0 : Float64(rand(rng, Binomial(89, 0.6))) for _ in 1:20_000]
        mc = HT.fit_marginal(HT.DRY_DAYS_90D, k)
        @test mc.kind === :count
        @test mc.pcap == count(==(90), k) / length(k)
        @test HT.prob_range(mc, 90.0) == (1 - mc.pcap, 1.0)
        @test HT.prob_range(mc, 0.0)[1] == 0.0
        @test HT.prob_range(mc, 89.0)[2] ≈ 1 - mc.pcap
        @test all(HT.prob_range(mc, j)[2] ≈ HT.prob_range(mc, j + 1)[1] for j in 0:88)
        uc = [HT.pit(mc, k[i], v[i], false) for i in eachindex(k)]
        @test mean(uc) ≈ 0.5 atol = 0.02
        # Without days at the cap, a count of 90 takes the top of the range
        k2 = Float64.(rand(rng, Binomial(89, 0.5), 5_000))
        m2 = HT.fit_marginal(HT.DRY_DAYS_90D, k2)
        @test m2.pcap == 0
        @test HT.prob_range(m2, 90.0)[2] == 1.0
        @test HT.prob_range(m2, 90.0)[1] == HT.prob_range(m2, 89.0)[2]
    end

    @testset "tie draws" begin
        a = HT.tie_draws(CartesianIndex(3, 4), 10)
        @test a == HT.tie_draws(CartesianIndex(3, 4), 10)
        @test a != HT.tie_draws(CartesianIndex(4, 3), 10)
        @test Set(keys(a)) == Set(i.name for i in HT.all_indicators())
        @test length(unique(values(a))) == length(a)
    end

    families = ((:clayton, Copulas.ClaytonCopula, 2.0), (:frank, Copulas.FrankCopula, 5.0),
                (:gumbel, Copulas.GumbelCopula, 1.8), (:joe, Copulas.JoeCopula, 2.5))

    @testset "joint values match Copulas.jl" begin
        rng = Xoshiro(4)
        for (family, F, θ) in (families..., (:clayton, Copulas.ClaytonCopula, -0.3)), d in 2:4
            C = HT.Archimedean(family, θ, d)
            Cj = F(d, θ)
            for _ in 1:20
                u = rand(rng, d)
                @test HT.joint_value(C, u) ≈ cdf(Cj, u) rtol = 1e-6 atol = 1e-12
            end
        end
    end

    @testset "Kendall distribution" begin
        rng = Xoshiro(5)
        for (family, F, θ) in families, d in 2:4
            C = HT.Archimedean(family, θ, d)
            U = rand(rng, F(d, θ), 100_000)
            c = [HT.joint_value(C, view(U, :, j)) for j in axes(U, 2)]
            for p in (0.1, 0.5, 0.9, 0.95, 0.99)
                t = quantile(c, p)
                @test HT.kendall(C, t) ≈ mean(c .<= t) atol = 0.008
            end
            ts = collect(0.01:0.01:0.99)
            Ks = HT.kendall.(Ref(C), ts)
            @test issorted(Ks) && all(Ks .>= ts)
            @test HT.kendall(C, 0.0) == 0.0 && HT.kendall(C, 1.0) == 1.0
            t95 = HT.kendall_quantile(C, 0.95)
            @test HT.kendall(C, t95) ≈ 0.95 atol = 1e-9
            # The joint-extreme threshold is a return period of about 20 days
            @test HT.return_period_years(C, t95) * 365.25 ≈ 20 atol = 1e-6
        end
        # Independence, where every family meets: K(t) = t Σ (-log t)ᵏ / k!
        x = -log(0.3)
        for C in (HT.Archimedean(:clayton, 0.0, 3), HT.Archimedean(:frank, 0.0, 3),
                  HT.Archimedean(:gumbel, 1.0, 3), HT.Archimedean(:joe, 1.0, 3))
            @test HT.kendall(C, 0.3) ≈ 0.3 * (1 + x + x^2 / 2)
        end
        @test HT.kendall(HT.Archimedean(:single, NaN, 1), 0.7) == 0.7
    end

    @testset "copula fit" begin
        rng = Xoshiro(6)
        C = HT.fit_copula(rand(rng, Copulas.GumbelCopula(3, 2.0), 5_000))
        @test C.family === :gumbel && C.dim == 3
        @test C.θ ≈ 2.0 atol = 0.1
        @test HT.fit_copula(rand(rng, Copulas.ClaytonCopula(3, 3.0), 5_000)).family === :clayton
    end

    @testset "event fits" begin
        rng = Xoshiro(7)
        n = 3_000
        types = Dict(e.name => e for e in HT.EVENT_TYPES)

        # Cold where it never snows rests on the two temperature indicators
        z = randn(rng, n)
        X = hcat(270 .+ 5 .* (z .+ 0.5 .* randn(rng, n)),
                 275 .+ 5 .* (z .+ 0.5 .* randn(rng, n)), zeros(n))
        X[1:10, 3] .= 0.01
        f = HT.fit_event(types["Extreme temperature (cold)"], X, rand(rng, n, 3))
        @test f.has_extremes
        @test f.used == [1, 2] && f.reversed == [true, true]
        @test f.copula.dim == 2
        @test HT.kendall(f.copula, f.threshold) ≈ 0.95 atol = 1e-9
        # Missing values at the start of the record are left out
        X[1:5, 1] .= NaN
        @test HT.fit_event(types["Extreme temperature (cold)"], X, rand(rng, n, 3)).has_extremes

        # Avalanche without snow has no extremes
        aval = types["Mass movement (wet, avalanche)"]
        Xa = hcat(zeros(n), zeros(n), 270 .+ 5 .* randn(rng, n))
        Xa[1:10, 1] .= 0.01
        @test !HT.fit_event(aval, Xa, rand(rng, n, 3)).has_extremes
        # On a glacier, snow depth never varies, so Avalanche rests on snowfall and warming
        Xg = hcat([rand(rng) < 0.3 ? 0.001 + 0.05 * rand(rng) : 0.0 for _ in 1:n],
                  fill(10.0, n), 270 .+ 5 .* randn(rng, n))
        fg = HT.fit_event(aval, Xg, rand(rng, n, 3))
        @test fg.has_extremes && fg.used == [1, 3]

        # With one indicator left, its own probability is the joint value
        Xl = hcat(zeros(n), 0.2 .+ 0.05 .* rand(rng, n))
        fl = HT.fit_event(types["Mass movement (wet, landslide)"], Xl, rand(rng, n, 2))
        @test fl.has_extremes && fl.used == [2] && fl.copula.family === :single
        @test fl.threshold ≈ 0.95 atol = 1e-12
    end

    @testset "time-of-year window" begin
        @test HT.calendar_day(Date(2023, 3, 1)) == 61
        @test HT.calendar_day(Date(2024, 2, 29)) == 60
        @test HT.calendar_day(Date(2023, 12, 31)) == 366
        @test HT.calendar_distance(1, 366) == 1
        dates = HT.record_dates(1950:1979)
        rows = HT.season_rows(HT.calendar_day.(dates), 1)
        @test length(rows) == 930  # 31 days in each of 30 years
        @test Date(1979, 12, 17) in dates[rows] && Date(1950, 1, 16) in dates[rows]
        @test !(Date(1979, 12, 16) in dates[rows]) && !(Date(1950, 1, 17) in dates[rows])
    end

    @testset "cell fits" begin
        rng = Xoshiro(8)
        dates = HT.record_dates(1950:1953)
        nd = length(dates)
        value(name) = name == "dry_days_90d" ? Float32(rand(rng, 0:90)) :
                      name == "soil_moisture_1d" ? Float32(0.1 + 0.3 * rand(rng)) :
                      Float32(1 + rand(rng))
        series = Dict(i.name => Float32[value(i.name) for _ in 1:nd] for i in HT.all_indicators())
        fits = HT.fit_cell(series, HT.tie_draws(CartesianIndex(3, 4), nd), dates;
                           baseline = 1950:1952)
        @test Set(keys(fits)) == Set(e.name for e in HT.EVENT_TYPES)
        @test length(fits["Drought"]) == 366 && length(fits["Mass movement (wet, avalanche)"]) == 366
        @test length(fits["Flood"]) == 1
        @test all(f.has_extremes for v in values(fits) for f in v)
    end
end

@testset "HazardTransform stage 3" begin
    AVALANCHE = "Mass movement (wet, avalanche)"
    THRESHOLD_YEARS = 1 / (365.25 * 0.05)  # 20 days

    @testset "classifying cell-days" begin
        rng = Xoshiro(9)
        dates = HT.record_dates(1950:1954)
        nd = length(dates)
        gen = Dict("dry_days_90d" => () -> Float32(rand(rng, Binomial(90, 0.5))),
                   "soil_moisture_1d" => () -> Float32(rand(rng, Beta(2.0, 5.0))))
        other = () -> Float32(rand(rng, Gamma(4.0, 2.0)))
        series = Dict(i.name => Float32[get(gen, i.name, other)() for _ in 1:nd]
                      for i in HT.all_indicators())
        draws = HT.tie_draws(CartesianIndex(5, 6), nd)
        fits = HT.fit_cell(series, draws, dates; baseline = 1950:1952)
        base = findall(d -> year(d) <= 1952, dates)
        res = HT.classify_cell(fits, series, draws, dates, base)
        @test Set(keys(res)) == Set(e.name for e in HT.EVENT_TYPES)
        for e in HT.EVENT_TYPES
            r = res[e.name]
            # About 5% of the baseline days are joint extremes
            @test 0.02 < mean(r.extreme) < 0.08
            @test all(!isnan, r.T)
            # Joint extremes are the days with a return period above 20 days
            @test all(r.T[r.extreme] .>= THRESHOLD_YEARS * (1 - 1e-6))
            @test all(r.T[.!r.extreme] .<= THRESHOLD_YEARS * (1 + 1e-6))
        end

        # Where the type cannot occur, no extremes and no return period
        fits2 = copy(fits)
        fits2[AVALANCHE] = fill(HT.NO_EXTREMES, 366)
        r2 = HT.classify_cell(fits2, series, draws, dates, base)[AVALANCHE]
        @test !any(r2.extreme) && all(isnan, r2.T)

        # A missing indicator value leaves the day without a value for the
        # types that use it
        series["gust_1d"][base[10]] = NaN
        r3 = HT.classify_cell(fits, series, draws, dates, base)
        @test isnan(r3["Storm"].T[10]) && isnan(r3["Wildfire"].T[10])
        @test !isnan(r3["Flood"].T[10])
    end

    # Hand-made results for three cells over 1980-1981: two cells in AAA,
    # one in BBB where nothing can occur
    dates = HT.record_dates(1980:1981)
    n = length(dates)
    result(extreme_days, T) = Dict(e.name => (extreme = BitVector([t in extreme_days for t in 1:n]),
                                              T = copy(T)) for e in HT.EVENT_TYPES)
    T1 = fill(0.01, n)
    T1[2] = 0.1
    T2 = fill(NaN, n)
    T2[400] = 5.0
    results = [result([1, 2], T1), result([2, 400], T2), result(Int[], fill(NaN, n))]
    daily, peak = HT.band_partials(results, ["AAA", "AAA", "BBB"], [1.0, 0.5, 2.0], dates, 1:n)

    @testset "band partials" begin
        flood = daily[daily.event_type .== "Flood", :]
        @test flood.country_code == ["AAA", "AAA", "AAA"]
        @test flood.date == [dates[1], dates[2], dates[400]]
        @test flood.extreme_area == [1.0, 1.5, 0.5]
        pf = peak[peak.event_type .== "Flood", :]
        @test pf.country_code == ["AAA", "AAA"] && pf.year == [1980, 1981]
        @test pf.peak_return_period_years == [0.1, 5.0]
        @test !("BBB" in daily.country_code) && !("BBB" in peak.country_code)
    end

    @testset "national values" begin
        out = mktempdir()
        write_band(rows, d, p) = begin
            HT.write_parquet(d, joinpath(out, HT.band_name(rows) * "_daily.parquet"))
            HT.write_parquet(p, joinpath(out, HT.band_name(rows) * "_peak.parquet"))
            touch(joinpath(out, HT.band_name(rows) * ".done"))
        end
        write_band(1:4, daily, peak)
        # A second band adds to AAA's second day and raises its 1980 peak
        write_band(5:8,
            DataFrame(country_code = ["AAA"], date = [dates[2]], event_type = ["Flood"], extreme_area = [0.5]),
            DataFrame(country_code = ["AAA"], year = [1980], event_type = ["Flood"],
                      peak_return_period_years = [0.2]))
        areas = DataFrame(country_code = ["AAA", "BBB"], area = [2.0, 2.0])
        tab = HT.combine_bands(out, [1:4, 5:8], areas; main = 1980:1981)
        @test nrow(tab) == 2 * 2 * 8
        row(c, y, t) = only(eachrow(tab[(tab.country_code .== c) .& (tab.year .== y) .& (tab.event_type .== t), :]))
        f80 = row("AAA", 1980, "Flood")
        @test f80.extreme_area_days ≈ (1.0 + 1.5 + 0.5) / 2
        @test f80.peak_extent ≈ 1.0
        @test f80.peak_return_period_years ≈ 0.2
        f81 = row("AAA", 1981, "Flood")
        @test f81.extreme_area_days ≈ 0.25 && f81.peak_extent ≈ 0.25
        @test f81.peak_return_period_years ≈ 5.0
        @test row("AAA", 1980, "Storm").extreme_area_days ≈ (1.0 + 1.5) / 2
        b = row("BBB", 1980, "Flood")
        @test b.extreme_area_days == 0 && b.peak_extent == 0 && ismissing(b.peak_return_period_years)
        # Every band must be done
        @test_throws ErrorException HT.combine_bands(out, [1:4, 9:12], areas; main = 1980:1981)
    end

    @testset "one band end to end" begin
        dir = mktempdir()
        out = joinpath(mktempdir(), "bands")
        lon, lat = [0.0, 0.25], [60.0, 59.75, 59.5]
        rng = Xoshiro(10)
        gens = Dict(
            HT.TP => () -> rand(rng) < 0.4 ? 0.0 : 0.001 + 0.01 * rand(rng),
            HT.SWVL3 => () -> 0.1 + 0.3 * rand(rng),
            HT.T2M_MAX => () -> 280 + 5 * randn(rng),
            HT.T2M_MIN => () -> 270 + 5 * randn(rng),
            HT.D2M => () -> 275 + 5 * randn(rng),
            HT.MSLP => () -> 100_000 + 1_000 * randn(rng))
        for src in HT.all_sources(), y in 1950:1954
            g = get(gens, src, () -> rand(rng, Gamma(4.0, 0.01)))
            write_grid(dir, src, y, lon, lat, (i, j, d) -> g())
        end
        cells = [CartesianIndex(1, 2), CartesianIndex(2, 2), CartesianIndex(1, 3)]
        countries = ["AAA", "AAA", "BBB"]
        areas = cosd.([59.75, 59.75, 59.5])
        kw = (years = 1950:1954, baseline = 1950:1952, main = 1953:1954)
        @test HT.run_band(dir, out, 2:3, cells, countries, areas; kw...)
        @test HT.band_done(out, 2:3)
        # A band already done is skipped
        @test !HT.run_band(dir, out, 2:3, cells, countries, areas; kw...)
        tab = HT.combine_bands(out, [2:3],
            DataFrame(country_code = ["AAA", "BBB"], area = [2cosd(59.75), cosd(59.5)]);
            main = 1953:1954)
        @test nrow(tab) == 2 * 2 * 8
        @test all(0 .<= tab.extreme_area_days .<= 365)
        @test all(0 .<= tab.peak_extent .<= 1 + 1e-12)
        @test all(!ismissing, tab.peak_return_period_years)
        # The main period is like the baseline, so about 5% of days are extremes
        @test 0.01 < mean(tab.extreme_area_days) / 365 < 0.12
    end
end
