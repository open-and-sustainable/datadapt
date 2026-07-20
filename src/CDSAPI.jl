module CDSAPI

using HTTP
using JSON

export retrieve

const DEFAULT_URL = "https://cds.climate.copernicus.eu/api"

struct Client
    url::String
    key::String
end

"""
    Client() -> Client

Build a client from `CDSAPI_URL`/`CDSAPI_KEY` environment variables or,
if unset, from `~/.cdsapirc` (`url: ...` / `key: ...` lines). The key is
a CDS personal access token (shown on https://cds.climate.copernicus.eu
under your user profile).
"""
function Client()
    url = get(ENV, "CDSAPI_URL", "")
    key = get(ENV, "CDSAPI_KEY", "")
    if isempty(key)
        rcfile = joinpath(homedir(), ".cdsapirc")
        isfile(rcfile) ||
            error("CDS credentials not found. Create $rcfile with lines\n" *
                  "  url: $DEFAULT_URL\n  key: <personal-access-token>\n" *
                  "or set the CDSAPI_URL and CDSAPI_KEY environment variables.")
        for line in eachline(rcfile)
            m = match(r"^\s*(url|key)\s*:\s*(\S+)", line)
            m === nothing && continue
            m.captures[1] == "url" && isempty(url) && (url = m.captures[2])
            m.captures[1] == "key" && (key = m.captures[2])
        end
        isempty(key) && error("No 'key:' entry found in $rcfile")
    end
    isempty(url) && (url = DEFAULT_URL)
    return Client(rstrip(url, '/'), key)
end

headers(client::Client) = ["PRIVATE-TOKEN" => client.key,
                           "Content-Type" => "application/json"]

# Server-side hiccups (HTTP 5xx) that are worth retrying, unlike
# genuine API rejections (4xx) which fail fast
struct TransientError <: Exception
    msg::String
end
Base.showerror(io::IO, e::TransientError) = print(io, e.msg)

# Retry connection-level failures (stale pooled connections, SSL hiccups,
# DNS blips, timeouts) and TransientError; HTTP.jl does not retry POSTs
# on its own. HTTP.Exceptions.HTTPError covers ConnectError, RequestError,
# StatusError and TimeoutError -- these are siblings, not a hierarchy, so
# the common supertype must be matched explicitly.
function with_retries(f::Function, description::String; attempts::Int = 5, quiet::Bool = false)
    delay = 5.0
    for attempt in 1:attempts
        try
            return f()
        catch e
            (e isa HTTP.Exceptions.HTTPError || e isa Base.IOError || e isa TransientError) || rethrow()
            attempt == attempts && rethrow()
            quiet || println("$description failed ($(sprint(showerror, e))). Retrying in $(round(Int, delay))s...")
            sleep(delay)
            delay = min(delay * 2, 120.0)
        end
    end
end

function api_error(prefix::String, response::HTTP.Response)
    detail = try
        body = JSON.parse(String(response.body))
        get(body, "detail", get(body, "title", ""))
    catch
        String(response.body)
    end
    error("$prefix (HTTP $(response.status)): $detail")
end

"""
    retrieve(dataset, request, target; quiet=false) -> target

Submit `request` (a Dict of CDS request parameters) for `dataset` to the
CDS, wait for the job to complete and download the result to `target`.
Equivalent to the Python cdsapi `Client().retrieve(...).download(...)`.
"""
function retrieve(dataset::String, request::Dict, target::String; quiet::Bool = false)
    client = Client()
    job_id = submit_job(client, dataset, request)
    quiet || println("CDS request submitted (job $job_id). Waiting...")
    wait_for_job(client, job_id; quiet = quiet)
    return download_result(client, job_id, target; quiet = quiet)
end

"""
    submit_job(dataset, request) -> job_id

Submit a request without waiting for it. Combine with `job_status` and
`download_result` to run several CDS jobs in parallel.
"""
submit_job(dataset::String, request::Dict) = submit_job(Client(), dataset, request)

function submit_job(client::Client, dataset::String, request::Dict)
    response = with_retries("CDS request submission") do
        HTTP.post(
            "$(client.url)/retrieve/v1/processes/$dataset/execution",
            headers(client),
            JSON.json(Dict("inputs" => request));
            status_exception = false,
        )
    end
    response.status in (200, 201) ||
        api_error("CDS request for $dataset was rejected", response)
    body = JSON.parse(String(response.body))
    return body["jobID"]
end

"""
    job_status(job_id) -> (status, message)

Current status of a CDS job: "accepted" (queued), "running",
"successful", "failed" or "dismissed", plus the server's message
(usually empty unless the job failed).
"""
job_status(job_id::String) = job_status(Client(), job_id)

function job_status(client::Client, job_id::String)
    response = with_retries("Status check of CDS job $job_id") do
        r = HTTP.get("$(client.url)/retrieve/v1/jobs/$job_id",
                     headers(client); status_exception = false)
        r.status >= 500 && throw(TransientError("CDS returned HTTP $(r.status)"))
        r
    end
    response.status == 200 ||
        api_error("Failed to check status of CDS job $job_id", response)
    body = JSON.parse(String(response.body))
    return body["status"], string(get(body, "message", ""))
end

function wait_for_job(client::Client, job_id::String; quiet::Bool = false)
    delay = 1.0
    last_status = ""
    while true
        status, message = job_status(client, job_id)
        if status != last_status
            quiet || println("CDS job $job_id: $status")
            last_status = status
        end
        status == "successful" && return
        if status in ("failed", "dismissed")
            error("CDS job $job_id $status: $(isempty(message) ? "no error message provided" : message)")
        end
        sleep(delay)
        delay = min(delay * 1.5, 60.0)
    end
end

"""
    download_result(job_id, target; quiet=false) -> target

Download the result of a successful CDS job to `target`.
"""
download_result(job_id::String, target::String; quiet::Bool = false) =
    download_result(Client(), job_id, target; quiet = quiet)

function download_result(client::Client, job_id::String, target::String; quiet::Bool = false)
    href = result_href(client, job_id)
    quiet || println("Downloading result to $target...")
    with_retries("Download of CDS job $job_id"; quiet = quiet) do
        HTTP.download(href, target; update_period = Inf)
    end
    return target
end

function result_href(client::Client, job_id::String)
    response = with_retries("Fetching results of CDS job $job_id") do
        HTTP.get("$(client.url)/retrieve/v1/jobs/$job_id/results",
                 headers(client); status_exception = false)
    end
    response.status == 200 ||
        api_error("Failed to fetch results of CDS job $job_id", response)
    body = JSON.parse(String(response.body))
    href = find_href(body)
    href === nothing && error("No download link in CDS results for job $job_id: $(JSON.json(body))")
    startswith(href, "/") && (href = replace(client.url, r"/api$" => "") * href)
    return href
end

# The results document nests the link as asset.value.href; search
# recursively so minor API layout changes do not break the client
function find_href(node)
    if node isa AbstractDict
        haskey(node, "href") && return node["href"]
        for value in values(node)
            href = find_href(value)
            href === nothing || return href
        end
    elseif node isa AbstractVector
        for value in node
            href = find_href(value)
            href === nothing || return href
        end
    end
    return nothing
end

end # module CDSAPI
