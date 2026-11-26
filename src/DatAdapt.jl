module DatAdapt

using DataFrames
import Dates
import DuckDB
using DuckDB: DBInterface

# Time period covered by the database; actual table coverage is
# recorded in each database's metadata table
const START_YEAR = 1980
const END_YEAR = 2025
# The hazard grids also cover the baseline 1950-1979, which the national
# values are measured against (docs/raw/hazard.md, Step 1)
const BASELINE_START_YEAR = 1950

# Define the database paths as constants
const DB_PATH_RAW = "DatAdapt-database/raw/DatAdapt.duckdb"
const DB_PATH_PROCESSED = "DatAdapt-database/processed/DatAdapt.duckdb"
# The raw EM-DAT records live in their own local file, which the dataset
# repository ignores: EM-DAT's licence does not allow redistributing them
const DB_PATH_DAMAGE = "DatAdapt-database/raw/DatAdapt_damage.duckdb"

# Include and use the renamed modules
include("CDSAPI.jl")
include("DatabaseAccess.jl")
include("ExposureDataFetch.jl")
include("DamageDataFetch.jl")
include("HazardDataFetch.jl")
include("HazardTransform.jl")
include("CountryMapping.jl")

using .CDSAPI: logmsg
using .DatabaseAccess
using .ExposureDataFetch
using .DamageDataFetch
using .HazardDataFetch

# Citations of the three sources for the metadata tables, as in "Data
# sources" on the documentation website; the metadata column `updated`
# gives the date of access
const EXPOSURE_SOURCE = "The World Bank: World Development Indicators, " *
    "https://datatopics.worldbank.org/world-development-indicators/, " *
    "licensed under CC BY 4.0; original sources of each indicator in " *
    "https://open-and-sustainable.github.io/datadapt/raw/exposure.html"
const DAMAGE_SOURCE = "Emergency Events Database (EM-DAT), UCLouvain / CRED, " *
    "Brussels, Belgium, https://www.emdat.be/; Delforge, D., Wathelet, V., " *
    "Below, R., Lanfredi Sofia, C., Tonnelier, M., van Loenhout, J. A. F., & " *
    "Speybroeck, N. (2025). EM-DAT: The Emergency Events Database. " *
    "International Journal of Disaster Risk Reduction, 124, 105509. " *
    "https://doi.org/10.1016/j.ijdrr.2025.105509"
# The Copernicus notice names the year the data are generated in
hazard_source(year::Int = Dates.year(Dates.today())) =
    "Copernicus Climate Change Service, Climate Data Store (2024): ERA5 " *
    "post-processed daily statistics on single levels from 1940 to present. " *
    "Copernicus Climate Change Service (C3S) Climate Data Store (CDS). " *
    "https://doi.org/10.24381/cds.4991cf48, licensed under CC BY 4.0; " *
    "national values by src/HazardTransform.jl " *
    "(https://open-and-sustainable.github.io/datadapt/raw/hazard.html). " *
    "Generated using Copernicus Climate Change Service information $year. " *
    "Neither the European Commission nor ECMWF is responsible for any use " *
    "that may be made of the Copernicus information or data it contains."

function fetch_exposure_data()
    E_data = ExposureDataFetch.fetch_exposure_data(START_YEAR, END_YEAR)
    DatabaseAccess.with_connection(DB_PATH_RAW) do con
        DatabaseAccess.write_duckdb_table!(E_data, con, "exposure")
        DatabaseAccess.update_metadata!(con, "exposure", START_YEAR, END_YEAR,
            EXPOSURE_SOURCE)
    end
end

function fetch_damage_data()
    D_data = DamageDataFetch.fetch_damage_data(START_YEAR, END_YEAR)
    DatabaseAccess.with_connection(DB_PATH_DAMAGE) do con
        DatabaseAccess.write_duckdb_table!(D_data, con, "damage")
        DatabaseAccess.update_metadata!(con, "damage", START_YEAR, END_YEAR,
            DAMAGE_SOURCE)
    end
end

# Hazard comes in two steps. The fetch only downloads the ERA5 grids, for the
# baseline 1950-1979 and the main period alike, since the national values are
# computed from the grids cell by cell; compute_hazard_national then writes
# those values to the raw database.
function fetch_hazard_data()
    HazardDataFetch.fetch_hazard_data(BASELINE_START_YEAR, END_YEAR)
end

"""
    compute_hazard_national() -> nothing

Combine the checkpoints of every latitude band into the national annual
hazard values (`HazardTransform.hazard_country_year`) and write them to the
table `hazard` of the raw database, from which `transform_data("hazard")`
makes the processed table. The bands are computed first by
`HazardTransform.run_bands`, in several processes: run
compute_hazard_national.sh, which does both. Errors, writing nothing, if any
band is not done.
"""
function compute_hazard_national()
    national = HazardTransform.hazard_country_year()
    DatabaseAccess.with_connection(DB_PATH_RAW) do con
        DatabaseAccess.write_duckdb_table!(national, con, "hazard")
        DatabaseAccess.update_metadata!(con, "hazard", START_YEAR, END_YEAR, hazard_source())
    end
    logmsg("Wrote $(nrow(national)) rows to table hazard in $DB_PATH_RAW.")
    return nothing
end

function transform_data(table::String)
    if table == "damage"
        # Process the "damage" table, with each event assigned to the
        # present-day country it occurred in
        damage = DatabaseAccess.with_connection(DB_PATH_DAMAGE) do con
            DataFrame(DBInterface.execute(con, "SELECT * FROM damage"))
        end
        located = CountryMapping.locate_damage_events(damage)
        D_processed = DatabaseAccess.executePRQL(DB_PATH_DAMAGE,
            "src/DataTransform/damage_country_event_year.prql";
            tables = Dict("damage_located" => located))
        DatabaseAccess.with_connection(DB_PATH_PROCESSED) do con
            DatabaseAccess.write_duckdb_table!(D_processed, con, "damage_country_event_year")
            DatabaseAccess.update_metadata!(con, "damage_country_event_year",
                START_YEAR, END_YEAR, "Derived from the raw damage table. Source: " * DAMAGE_SOURCE)
        end
    elseif table == "exposure"
        # Process the "exposure" table, countries only, with codes aligned
        # to the ones used for damage
        exposure = DatabaseAccess.with_connection(DB_PATH_RAW) do con
            DataFrame(DBInterface.execute(con, "SELECT * FROM exposure"))
        end
        located = CountryMapping.locate_exposure(exposure)
        E_processed = DatabaseAccess.executePRQL(DB_PATH_RAW,
            "src/DataTransform/exposure_country_year.prql";
            tables = Dict("exposure_located" => located))
        DatabaseAccess.with_connection(DB_PATH_PROCESSED) do con
            DatabaseAccess.write_duckdb_table!(E_processed, con, "exposure_country_year")
            DatabaseAccess.update_metadata!(con, "exposure_country_year",
                START_YEAR, END_YEAR, "Derived from the raw exposure table. Source: " * EXPOSURE_SOURCE)
        end
    elseif table == "hazard"
        # Process the national hazard values of the raw database (see
        # compute_hazard_national); adjustments for the processed database
        # go in the PRQL step
        H_processed = DatabaseAccess.executePRQL(DB_PATH_RAW,
            "src/DataTransform/hazard_country_year.prql")
        nrow(H_processed) > 0 || error("The hazard PRQL step returned no rows; nothing written.")
        DatabaseAccess.with_connection(DB_PATH_PROCESSED) do con
            DatabaseAccess.write_duckdb_table!(H_processed, con, "hazard_country_year")
            DatabaseAccess.update_metadata!(con, "hazard_country_year",
                START_YEAR, END_YEAR, "Derived from the raw hazard table. Source: " * hazard_source())
        end
    else
        println("Table name not recognized. Please provide a valid table name.")
    end
end

end # module DatAdapt
