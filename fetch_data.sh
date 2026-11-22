#!/bin/bash

# Run the Julia script and call the fetch_exposure_data function
#julia --project=. -e 'push!(LOAD_PATH, "src"); using DatAdapt; DatAdapt.fetch_exposure_data()' 2>&1 | tee exposure.log

# Run the Julia script and call the fetch_damage_data function
#julia --project=. -e 'push!(LOAD_PATH, "src"); using DatAdapt; DatAdapt.fetch_damage_data()' 2>&1 | tee damage.log

# Download the ERA5 grids, 1950-2025, for the national hazard values
# (compute_hazard_national.sh)
julia --project=. -e 'push!(LOAD_PATH, "src"); using DatAdapt; DatAdapt.fetch_hazard_data()' 2>&1 | tee hazard.log
