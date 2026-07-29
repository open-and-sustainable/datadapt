#!/bin/bash

# Run the Julia script and call the fetch_exposure_data function
#julia --project=. -e 'push!(LOAD_PATH, "src"); using DatAdapt; DatAdapt.fetch_exposure_data()' 2>&1 | tee exposure.log

# Run the Julia script and call the fetch_damage_data function
#julia --project=. -e 'push!(LOAD_PATH, "src"); using DatAdapt; DatAdapt.fetch_damage_data()' 2>&1 | tee damage.log

# Run the Julia script and call the fetch_hazard_data function
julia --project=. -e 'push!(LOAD_PATH, "src"); using DatAdapt; DatAdapt.fetch_hazard_data()' 2>&1 | tee hazard.log

# Run the Julia script and call the fetch_hazard_baseline_data function
#julia --project=. -e 'push!(LOAD_PATH, "src"); using DatAdapt; DatAdapt.fetch_baseline_hazard_data()' 2>&1 | tee hazard_baseline.log
