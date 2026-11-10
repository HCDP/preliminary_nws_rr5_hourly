# R port of acquisition.py: HCDP acquisition API client
# Requires the httr2 package: install.packages("httr2")
#
# The same client as the NWS API workflow (preliminary_nws_api_hourly); only
# the default token location differs.
#
# As a library (code/get_rr5_archive.R sources it this way) it only defines the
# helpers below and sends no requests:
#   source("code/hcdp_db_acquisition.R")
#   hcdp_latest_obs("nws_rr5", c("AALH1", "PLRH1"))  # newest timestamp per station
#   hcdp_write("nws_rr5", "data", rows)               # batched upsert of a data frame
# Run as a script, it also runs the example requests at the bottom (which include
# POSTs of empty data to every source's tables):
#   Rscript code/hcdp_db_acquisition.R
#
# Environment:
#   HCDP_TOKEN_FILE   token file (default: token.env at $RR5_PROJECT_ROOT)
#   HCDP_API_URL      API base URL (default https://api.hcdp.ikewai.org)

suppressPackageStartupMessages(library(httr2))   # load httr2, the HTTP client used for all requests (quietly: startup chatter goes to stderr)

# ---------------------------------------------------------------------------
# Table schemas (reference only; table names as in hcdp_api since 2026-10-26, commit 089bd97)
# ---------------------------------------------------------------------------
# hads:
#   stationMetadata: cols station_id, station_name, nesdis_id, skn, lat, lng       | key station_id
#   variableMetadata: cols variable, unit                                           | key variable
#   data:            cols station_id, timestamp, variable, value, mode              | key station_id, timestamp, variable
# madis:
#   stationMetadata: cols station_id, station_name, data_provider, skn, lat, lng, source | key station_id
#   variableMetadata: cols variable, unit                                           | key variable
#   data:            cols station_id, timestamp, variable, value                    | key station_id, timestamp, variable
# nws_api:
#   stationMetadata: cols station_id, station_name, data_provider, skn, lat, lng    | key station_id
#   variableMetadata: cols variable, unit                                           | key variable
#   data:            cols station_id, timestamp, variable, value                    | key station_id, timestamp, variable
# nws_rr5:
#   stationMetadata: cols station_id, station_name, skn, lat, lng                   | key station_id
#   variableMetadata: cols variable, unit                                           | key variable
#   data:            cols station_id, timestamp, variable, value                    | key station_id, timestamp, variable

# API token: read at run time from token.env (git-ignored), never hard-coded or printed.
# The file may hold the bare token, or a NAME=value line (optional "export" and quotes).
token_file <- Sys.getenv("HCDP_TOKEN_FILE",      # path override, if set; otherwise token.env at the project root
                         file.path(Sys.getenv("RR5_PROJECT_ROOT", "."), "token.env"))
read_token <- function(path) {                   # define a function returning the token stored in `path`
  if (!file.exists(path)) stop("token file not found: ", path, call. = FALSE)  # fail clearly if it is missing
  x <- trimws(readLines(path, warn = FALSE))     # read the lines; warn = FALSE tolerates a missing final newline
  x <- x[nzchar(x) & !startsWith(x, "#")][1]     # keep the first non-blank, non-comment line
  if (is.na(x)) stop("token file is empty: ", path, call. = FALSE)  # fail clearly if there is nothing in it
  kv <- "^(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*([^=[:space:]].*)$"  # NAME=value form
  if (grepl(kv, x)) x <- sub(kv, "\\2", x)       # keep only the value (a bare token's trailing "=" padding never matches)
  gsub("^[\"']|[\"']$", "", x)                   # drop surrounding quotes, if any
}                                                # end of read_token
token <- read_token(token_file)                  # the token, used by the request helpers below

api_url <- Sys.getenv("HCDP_API_URL", "https://api.hcdp.ikewai.org")  # base URL of the HCDP API (override for testing)

sources <- c("hads", "madis", "nws_api", "nws_rr5")  # the four data sources to loop over

# Helper: build a GET request with auth and query parameters
hcdp_get <- function(url, query = list()) {      # define a function taking a URL and a named list of query params
  query <- Filter(length, query)                 # drop empty parameters (same as Python requests omitting empty lists)
  request(url) |>                                # start a request for the given URL
    req_auth_bearer_token(token) |>              # add the "Authorization: Bearer <token>" header
    req_url_query(!!!query, .multi = "explode") |>  # add query params; vectors become repeated keys (a=1&a=2), like Python requests
    req_retry(max_tries = 3, retry_on_failure = TRUE) |>  # retry transient failures (429/503, dropped connections)
    req_error(body = function(resp) resp_body_string(resp)) |>  # put the API's error text in the R error message
    req_perform()                                # send the request; httr2 throws an error on 4xx/5xx (like raise_for_status)
}                                                # end of hcdp_get

# Helper: build a POST request with auth and a JSON body
hcdp_post <- function(url, body, ...) {          # define a function taking a URL, a list to send as JSON, and jsonlite options (...)
  request(url) |>                                # start a request for the given URL
    req_auth_bearer_token(token) |>              # add the bearer token header
    req_body_json(body, ...) |>                  # encode the body as JSON and set the method to POST
    req_retry(max_tries = 3, retry_on_failure = TRUE) |>  # retry transient failures; safe because inserts are keyed upserts
    req_error(body = function(resp) resp_body_string(resp)) |>  # put the API's error text in the R error message
    req_perform()                                # send it; errors on HTTP failure
}                                                # end of hcdp_post

# Newest observation timestamp per station in a source's data table (NA = no rows yet).
# The API orders by timestamp DESC (then station_id, variable) and applies `limit` to the
# whole result, so limit = 1 is one row overall -- hence one request per station.
hcdp_latest_obs <- function(source, station_ids) {  # define a function taking a source and a vector of station IDs
  url <- paste0(api_url, "/acquisition/", source, "/data")  # build the data endpoint URL
  vapply(station_ids, function(id) {             # one lookup per station, returning a character vector
    rows <- resp_body_json(hcdp_get(url, list(station_ids = id, limit = 1)))  # that station's newest row, if any
    if (length(rows) == 0) NA_character_ else rows[[1]]$timestamp  # its timestamp text, or NA if the station has no rows
  }, character(1), USE.NAMES = FALSE)            # end of vapply
}                                                # end of hcdp_latest_obs

# Write a data frame to a source's table; its columns must be that table's schema
# (see above). The API caps a request body at 100 KB, so rows go in batches, and a
# batch is halved until its JSON fits. NA is sent as null and numbers at R's 15
# significant digits. overwrite = TRUE upserts on the table key; FALSE inserts only
# new keys and leaves existing rows untouched. Returns the rows the API reports modified.
hcdp_write <- function(source, table, rows, overwrite = TRUE,  # define a function taking a source, table name, and data frame
                       batch_rows = 500, max_bytes = 90000) {  # batch size, and the JSON size a batch must stay under
  url <- paste0(api_url, "/acquisition/", source, "/", table)  # build the ingest endpoint URL
  post <- function(b) {                          # send one batch, splitting it if its JSON is too large
    body <- list(data = b, overwrite = overwrite)  # the request body the API expects
    size <- nchar(jsonlite::toJSON(body, auto_unbox = TRUE, digits = NA, null = "null", na = "null"), "bytes")  # its JSON size
    if (size > max_bytes && nrow(b) > 1) {       # too large: send each half separately
      half <- nrow(b) %/% 2
      return(post(b[seq_len(half), , drop = FALSE]) + post(b[-seq_len(half), , drop = FALSE]))
    }
    m <- resp_body_json(hcdp_post(url, body, digits = NA, na = "null"))$modified  # send it; the API answers {"modified": n}
    if (is.null(m)) NA_real_ else as.numeric(m)  # the count, or NA if the API did not report one
  }                                              # end of post
  starts <- if (nrow(rows) > 0) seq(1, nrow(rows), by = batch_rows) else integer(0)  # first row of each batch (none for an empty frame)
  modified <- 0                                  # running total of rows modified
  for (i in seq_along(starts)) {                 # loop over the batches
    s <- starts[i]                               # this batch's first row
    modified <- modified + post(rows[s:min(s + batch_rows - 1, nrow(rows)), , drop = FALSE])  # send it and add its count
    if (i %% 100 == 0) cat(sprintf("...%s: %d/%d batches\n", table, i, length(starts)))  # progress on large writes (stdout)
  }                                              # end of batch loop
  modified                                       # total rows modified
}                                                # end of hcdp_write

# ---------------------------------------------------------------------------
# Examples -- run only when this file is executed as a script, never when sourced
# ---------------------------------------------------------------------------
if (sys.nframe() == 0) {                         # TRUE under Rscript, FALSE inside source()

  # ---------------------------------------------------------------------------
  # Get variable metadata (units)
  # ---------------------------------------------------------------------------
  for (source in sources) {                        # loop over each data source
    url <- paste0(api_url, "/acquisition/", source, "/variableMetadata")  # build the variable metadata endpoint URL
    query <- list(                                 # start the list of query parameters
      var_ids = character(0)                       # variables you want; leaving empty returns all variables
    )                                              # end of query list
    res <- hcdp_get(url, query)                    # send the GET request
    print(resp_body_json(res))                     # parse the JSON response and print it
  }                                                # end of loop

  # ---------------------------------------------------------------------------
  # Get station metadata
  # ---------------------------------------------------------------------------
  for (source in sources) {                        # loop over each data source
    url <- paste0(api_url, "/acquisition/", source, "/stationMetadata")   # build the station metadata endpoint URL
    query <- list(                                 # start the list of query parameters
      station_ids = character(0)                   # stations you want; leaving empty returns all stations
    )                                              # end of query list
    res <- hcdp_get(url, query)                    # send the GET request
    print(resp_body_json(res))                     # parse the JSON response and print it
  }                                                # end of loop

  # ---------------------------------------------------------------------------
  # Get last measurement
  # ---------------------------------------------------------------------------
  for (source in sources) {                        # loop over each data source
    url <- paste0(api_url, "/acquisition/", source, "/data")  # build the data endpoint URL
    query <- list(                                 # start the list of query parameters
      limit = 1,                                   # return only the most recent record
      # local_tz = "true",                         # uncomment to get timestamps in HST instead of UTC
      station_ids = character(0),                  # stations you want; empty means all stations
      var_ids = character(0)                       # variables you want; empty means all variables
    )                                              # end of query list
    res <- hcdp_get(url, query)                    # send the GET request
    print(resp_body_json(res))                     # parse the JSON response and print it
  }                                                # end of loop

  # ---------------------------------------------------------------------------
  # Ingest data
  # ---------------------------------------------------------------------------
  tables <- c("stationMetadata", "variableMetadata", "data")  # the three tables that can receive data

  for (source in sources) {                        # loop over each data source
    for (table in tables) {                        # loop over each table within the source
      url <- paste0(api_url, "/acquisition/", source, "/", table)  # build the ingest endpoint URL
      # Fill `data` with rows matching the table schema above, one list per row, e.g. for hads/data:
      # list(list(station_id = "123", timestamp = "2026-10-16T00:00:00-10:00", variable = "rf", value = 12.1, mode = "X"))
      body <- list(                                # start the request body
        data = list()                              # rows to insert; an empty list() is sent as [] in JSON
      )                                            # end of body
      res <- hcdp_post(url, body)                  # send the POST request
      print(resp_body_json(res))                   # parse the JSON response and print it
    }                                              # end of table loop
  }                                                # end of source loop
}                                                # end of examples
