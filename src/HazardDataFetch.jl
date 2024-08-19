module HazardDataFetch

using HTTP
using Tar
using DataFrames
using CSV
using CodecZlib
using Dates

export fetch_hazard_data


function fetch_hazard_data(start_year::Int, end_year::Int)
    destination_dir = "data/raw/nathaz/"
    extraction_dir = joinpath(destination_dir, "extracted")
    mkpath(destination_dir)
    
    url = "https://www.ncei.noaa.gov/data/global-historical-climatology-network-daily/archive/daily-summaries-latest.tar.gz"
    tarball_path = joinpath(destination_dir, "daily-summaries-latest.tar.gz")

    if isfile(tarball_path)
        println("File already exists. Skipping download.")
    else
        println("Downloading data...")
        HTTP.download(url, tarball_path)
        println("Download complete.")
    end

    # Check if files are already extracted
    if isdir(extraction_dir) && length(readdir(extraction_dir)) > 0
        println("Files already extracted. Skipping decompression.")
    else
        # Ensure the extraction directory is empty
        if isdir(extraction_dir)
            rm(extraction_dir; force = true, recursive = true)
        end
        mkpath(extraction_dir)

        # Decompress and extract the tar.gz file
        println("Decompressing and extracting data...")
        open(tarball_path) do tar_gz
            tar = GzipDecompressorStream(tar_gz)
            Tar.extract(tar, extraction_dir)
            close(tar)
        end
        println("Decompression and extraction complete.")
    end

    # Load data from the extracted files
    println("Loading data from extracted files...")
    data_frames = DataFrame[]
    files = readdir(extraction_dir, join=true)

    # Limit the number of files to a specified limit
    files = first(files, 10)
        
    for file in files
        if endswith(file, ".csv")
            println("Processing $file...")
            try
                df = CSV.read(file, DataFrame)
                
                # Ensure that the DATE column exists and is a valid date
                if "DATE" in names(df)
                    # Check the year of every entry before filtering
                    years = unique(year.(df[!, "DATE"]))
                    println("Unique years in $file: $years")
                    println("Filtering for years between $start_year and $end_year")

                    # Apply the filtering based on the year
                    filter!(row -> start_year <= year(row["DATE"]) <= end_year, df)

                    # Remove rows where all entries are missing
                    dropmissing!(df)

                    # Inspect DataFrame state
                    println("Processed DataFrame has $(nrow(df)) rows and $(ncol(df)) columns after filtering")
                    println("Columns: ", names(df))

                    if nrow(df) > 0
                        push!(data_frames, df)
                    else
                        println("DataFrame from $file is empty after filtering.")
                    end
                else
                    println("Skipping $file: 'DATE' column not found.")
                end
            catch e
                println("Error processing $file: $e")
            end
        end
    end
    
    # Inspect the state of all DataFrames before concatenation
    if !isempty(data_frames)
        println("Concatenating $(length(data_frames)) DataFrames...")
        for (i, df) in enumerate(data_frames)
            println("DataFrame $i: $(nrow(df)) rows, $(ncol(df)) columns")
            println("Columns: ", names(df))
        end

        align_columns!(data_frames)  # Ensure columns are aligned
        combined_df = vcat(data_frames...; cols=:union)
        
        # Remove any rows that are completely empty or contain only missing values
        dropmissing!(combined_df)
        
        println("Data loading complete. Combined DataFrame has $(nrow(combined_df)) rows.")
        return combined_df
    else
        println("No data to combine.")
        return DataFrame()
    end
end

function align_columns!(dfs::Vector{DataFrame})
    # Collect all unique columns across all DataFrames
    all_columns = unique(vcat(names.(dfs)...))
    
    for df in dfs
        for col in all_columns
            if !haskey(df, col)
                df[!, col] = missing
            end
        end
    end
end

end