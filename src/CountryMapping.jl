module CountryMapping

using CSV
using DataFrames
using JSON

export locate_damage_events, locate_exposure

# EM-DAT events coded to states that no longer exist, each assigned to the
# present-day country it occurred in. Reviewed by hand, event by event: the
# successor is read from the event's Location text, or from its GADM codes
# where EM-DAT has them. An empty successor means the event cannot be located.
const FORMER_STATES_PATH = "country_mappings/damage_former_states.csv"

# Countries are kept at the finest level all three variables share, so an area
# is kept apart only where World Bank exposure has its own series for it.
#
# GADM 4.1 country codes of contested areas kept apart from the country that
# administers them, because that country's World Bank series exclude them:
# Kosovo, which has its own series (Serbia's excluding it in every year), and
# Western Sahara, which Morocco's surface area leaves out. GADM's other
# contested areas are counted in the administering country's series, so their
# events stay with the country EM-DAT records. Matches the hazard map in
# country_mappings/hazard_units.csv.
const CONTESTED_AREAS = Set(["XKO", "ESH"])

# EM-DAT codes for territories that the World Bank series of another country
# include: France's overseas departments, the Canary Islands and the Azores.
const DAMAGE_RECODE = Dict("REU" => "FRA", "MTQ" => "FRA", "GLP" => "FRA",
                           "GUF" => "FRA", "MYT" => "FRA",
                           "SPI" => "ESP", "AZO" => "PRT")

# GADM country codes of the admin units EM-DAT lists for an event. A GADM GID
# begins with the three-character country code (e.g. "XKO.3_1", "GHA7_2").
function gadm_countries(units)
    (ismissing(units) || isempty(units)) && return Set{String}()
    gids = String[]
    for unit in JSON.parse(units)
        gid = something(get(unit, "gid_2", nothing), get(unit, "gid_1", nothing),
                        get(unit, "gid_0", nothing), Some(nothing))
        gid === nothing || push!(gids, first(gid, 3))
    end
    return Set(gids)
end

"""
    locate_damage_events(damage) -> DataFrame

Assign each EM-DAT event to the present-day country it occurred in. The EM-DAT
code is kept as `ISO_EMDAT` and `ISO` holds the assigned country:

- events coded to a former state take the successor from the reviewed table;
- events whose GADM units all lie in one contested area are assigned to it;
- all other events keep their EM-DAT code, including those that cover a
  contested area together with the country that administers it, since their
  losses cannot be split;
- territories that another country's World Bank series include are merged
  into that country.

Events that cannot be located (a former state with no usable Location, or
units spread over several contested areas) are dropped.
"""
function locate_damage_events(damage::DataFrame)
    former = CSV.read(FORMER_STATES_PATH, DataFrame; types = String)
    successor = Dict(row."DisNo." => coalesce(row.successor, "") for row in eachrow(former))

    located = copy(damage)
    located.ISO_EMDAT = located.ISO
    located.ISO = map(eachrow(located)) do row
        haskey(successor, row."DisNo.") && return successor[row."DisNo."]
        countries = gadm_countries(row."GADM Admin Units")
        if !isempty(countries) && issubset(countries, CONTESTED_AREAS)
            return length(countries) == 1 ? only(countries) : ""
        end
        return get(DAMAGE_RECODE, row.ISO, row.ISO)
    end
    return filter(row -> !isempty(row.ISO), located)
end

# World Bank aggregates (regions, income groups, lending groups, the world),
# as classified by the World Bank's own country list
# (https://api.worldbank.org/v2/country, region "Aggregates"), downloaded
# 2026-11-04. The API returns some aggregates with an empty country code.
const WB_AGGREGATES_PATH = "country_mappings/exposure_world_bank_aggregates.csv"

# World Bank codes that differ from the ones used for damage (GADM's).
const EXPOSURE_RECODE = Dict("XKX" => "XKO")

"""
    locate_exposure(exposure) -> DataFrame

Keep only the World Bank's economies, dropping its aggregates, and recode
those whose World Bank code differs from the one used for damage.
"""
function locate_exposure(exposure::DataFrame)
    aggregates = Set(CSV.read(WB_AGGREGATES_PATH, DataFrame; types = String).code)
    located = filter(row -> !ismissing(row.country_code) && !isempty(row.country_code) &&
                            !(row.country_code in aggregates), exposure)
    located.country_code = [get(EXPOSURE_RECODE, code, code) for code in located.country_code]
    return located
end

end # module CountryMapping
