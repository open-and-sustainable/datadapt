#!/bin/bash

# National hazard values from the ERA5 grids (src/HazardTransform.jl), written
# to the table hazard_national of the raw database.
#
# The latitude bands are shared among PROCESSES Julia processes of THREADS
# threads each, all at the lowest CPU priority (nice 19), so that other work
# on the machine always comes first. Each process also runs one garbage
# collector thread, so the run occupies PROCESSES x (THREADS + 1) hardware
# threads; the script refuses to start unless that leaves 4 free.
#
# The run takes days. Every band saves its results in chunks of cells as it
# goes (DatAdapt-database/raw/era5_bands), so a run that stops, for whatever
# reason, is resumed by starting this script again: only the chunks in
# progress are lost. Once every band is done, the bands are combined into the
# national values.
#
# Usage, from the repository root (in tmux or similar, as it runs for days):
#   ./compute_hazard_national.sh
#   PROCESSES=2 THREADS=6 ./compute_hazard_national.sh

PROCESSES=${PROCESSES:-4}
THREADS=${THREADS:-6}
OUT=DatAdapt-database/raw/era5_bands

used=$(( PROCESSES * (THREADS + 1) ))
limit=$(( $(nproc) - 4 ))
if (( used > limit )); then
    echo "$PROCESSES processes x ($THREADS + 1) threads = $used threads, more than $limit (all but 4)." >&2
    exit 1
fi

# One run at a time: a second one would repeat the same bands
mkdir -p "$OUT"
exec 9> "$OUT/run.lock"
if ! flock -n 9; then
    echo "A run is already in progress (lock $OUT/run.lock)." >&2
    exit 1
fi

# Processes of this run share bands through claims under this id
RUN_ID=$(date +%Y%m%dT%H%M%S)
echo "Run $RUN_ID: $PROCESSES processes x $THREADS threads, logs in hazard_bands_<n>.log"
for n in $(seq 1 "$PROCESSES"); do
    nice -n 19 julia -t "$THREADS" --gcthreads=1 --project=. \
        -e "push!(LOAD_PATH, \"src\"); using DatAdapt; DatAdapt.HazardTransform.run_bands(\"$RUN_ID\")" \
        >> "hazard_bands_$n.log" 2>&1 &
done
wait

# Combine the bands; errors, writing nothing, if any band is not done yet
nice -n 19 julia --gcthreads=1 --project=. \
    -e 'push!(LOAD_PATH, "src"); using DatAdapt; DatAdapt.compute_hazard_national()' \
    2>&1 | tee -a hazard_national.log
