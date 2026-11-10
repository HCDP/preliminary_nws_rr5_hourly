# Incremental pull of the RR5HFO products (Hawaii One-Hour Rainfall Summary,
# SHEF format) from the NWS API, written to the HCDP database's nws_rr5
# tables through the acquisition API (code/hcdp_db_acquisition.R):
#   data              station_id | timestamp | variable | value
#   variableMetadata  variable | unit
#   stationMetadata   station_id | station_name | skn | lat | lng
#
# 'timestamp' is each 1-hr total's obs-ending hour as UTC ISO 8601 text
# (e.g. "2026-07-24T02:00:00Z"); nothing is converted to local time. The one
# variable is precip_1hr, in inches as reported. Missing readings ("M") are
# not written.
#
# How it decides what to fetch:
#   1. Builds the station list with get_rr5_stations(refresh = TRUE) from the
#      newest product -- two requests, every run, so nothing has to persist
#      between runs.
#   2. Every RR5 product carries ALL gauges, so the incremental unit is hours
#      of products, not per-station windows: it asks the HCDP database for
#      its newest stored hour and fetches from there to now, with a 12-hour
#      minimum (re-collecting late or reissued hours) and the ~7-day product
#      retention as the cap. An empty database -> full retention.
#   3. Writes to the database (hcdp_write()): observations and station
#      metadata are upserted, so a re-fetched value replaces the stored one;
#      variable metadata is insert-only. Each station's skn, lat and lng come
#      from the HCDP master station list, matched on NWS.id as in the MADIS
#      and NWS API workflows -- NA where there is no unambiguous match, until
#      the list is updated (RR5 products carry no coordinates).
#
# Usage:
#   Rscript code/get_rr5_archive.R      database-driven window (default)
#   Rscript code/get_rr5_archive.R 73   manual override: newest 73 products
#
# Output: the HCDP database (nothing is written locally except the station
#         list, $RR5_DATA_CATALOG/rr5_stations.csv, default dataCatalog/
#         under $RR5_PROJECT_ROOT). Needs the HCDP token in token.env at the
#         project root, or the file named by $HCDP_TOKEN_FILE.
#
# Notes:
#  - Products come from https://api.weather.gov/products/types/RR5/locations/HFO
#    (~7 days retention; one product per hour).
#  - Each product reports 1-hr precip totals ending at the hour given in the
#    SHEF .B header (e.g. ".B HFO 0730 H  DH 15" = Jul 30, 15:00 HST, written
#    as 2026-07-31T01:00:00Z).
#  - Value coding: 'M' (missing) -> not written; 'T' (trace) -> 0.001 in.
#  - If an hour was reissued/corrected, the newest issuance wins.

# --- directories from the environment --------------------------------------
# This workflow takes its paths from the environment rather than deriving
# them from the script's own location. RR5_PROJECT_ROOT is REQUIRED; the
# directories under it can each be redirected individually. An unset root is
# a hard error on purpose -- the old behaviour fell back to the script's
# parent (or, when sourced, the working directory), which could silently
# write a whole run into the wrong tree.
#
#   RR5_PROJECT_ROOT           required   project root
#   RR5_CODE_DIR               optional   default $RR5_PROJECT_ROOT/code
#   RR5_DATA_CATALOG           optional   default $RR5_PROJECT_ROOT/dataCatalog
#
# See envs/rr5.env for a ready-to-source file, and the cron file for how
# the scheduled job loads it.
.env_dir <- function(var, default = NULL, must_exist = TRUE) {
  v <- Sys.getenv(var)
  if (!nzchar(v)) {
    if (is.null(default))
      stop(var, " is not set. This workflow requires its directories to come ",
           "from the environment -- export ", var, " (see envs/rr5.env) ",
           "before running.", call. = FALSE)
    v <- default
  }
  v <- path.expand(v)
  if (must_exist && !dir.exists(v))
    stop(var, " is set to a directory that does not exist: ", v, call. = FALSE)
  normalizePath(v, winslash = "/", mustWork = FALSE)
}
mainDir     <- .env_dir("RR5_PROJECT_ROOT")
codeDir     <- .env_dir("RR5_CODE_DIR",     file.path(mainDir, "code"))
catalog_dir <- .env_dir("RR5_DATA_CATALOG", file.path(mainDir, "dataCatalog"),
                        must_exist = FALSE)

source(file.path(codeDir, "get_rr5_stations_fn.R"))   # loads httr2/dplyr/
                                                      # tibble, get_rr5_stations()
# the HCDP database client: hcdp_get(), hcdp_write(), and api_url. Reads the
# token now, so a missing token.env fails here, before any fetching.
source(file.path(codeDir, "hcdp_db_acquisition.R"))
suppressPackageStartupMessages(library(purrr))

# progress goes to stdout via say(), not message()/stderr, so the cron job's
# .err log collects only real problems (warnings and errors). say() matches
# message() semantics: arguments pasted with no separator, newline appended.
say <- function(...) cat(..., "\n", sep = "")

# every timestamp written is UTC ISO 8601 ending in "Z"; the HCDP API returns
# the same with fractional seconds ("...00.000Z")
iso_utc   <- function(t) format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
parse_utc <- function(x) as.POSIXct(sub("\\.[0-9]+Z$", "Z", x),
                                    format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

args        <- commandArgs(trailingOnly = TRUE)
n_override  <- if (length(args) >= 1) as.numeric(args[1]) else NA

min_fetch_h <- 12          # never fetch fewer product-hours than this
max_fetch_h <- 7 * 24      # ~product retention

ua <- "R script (hcdp@hawaii.edu)"

get_json <- function(url) {
  request(url) |>
    req_headers(`User-Agent` = ua, Accept = "application/ld+json") |>
    req_retry(max_tries = 3) |>
    req_perform() |>
    resp_body_json()
}

# --- HCDP master station list, for skn / lat / lng --------------------------
# Same source and match as the MADIS and NWS API workflows: a station's skn,
# lat and lng are the master list's SKN, LAT and LON on the row whose NWS.id
# equals its station_id. An NWS.id listed more than once is ambiguous and,
# like a station not in the list, gets NA for all three. Loaded before
# anything is fetched so an unreachable list stops the run early: station
# metadata is upserted, so falling back to NA would wipe the stored values.
master_meta_url <- Sys.getenv("HCDP_MASTER_META_URL", paste0(
  "https://raw.githubusercontent.com/ikewai/hawaii_wx_station_mgmt_container/",
  "main/Hawaii_Master_Station_Meta.csv"))
master_meta <- request(master_meta_url) |>
  req_retry(max_tries = 3, retry_on_failure = TRUE) |>
  req_perform() |>
  resp_body_string()
master_meta <- read.csv(text = master_meta, stringsAsFactors = FALSE)
if (!all(c("SKN", "NWS.id", "LAT", "LON", "Station.Name") %in% names(master_meta)))
  stop("master station list (", master_meta_url, ") lacks SKN / NWS.id / ",
       "LAT / LON / Station.Name columns", call. = FALSE)
master_nws  <- master_meta$NWS.id[!is.na(master_meta$NWS.id) & master_meta$NWS.id != ""]
meta_dupes  <- unique(master_nws[duplicated(master_nws)])
meta_lookup <- master_meta |>
  filter(NWS.id %in% master_nws, !NWS.id %in% meta_dupes) |>
  transmute(station_id = NWS.id, master_name = Station.Name,
            skn = SKN, lat = LAT, lng = LON)
say("Master station list: ", nrow(meta_lookup), " unambiguous NWS.id entries")

# --- 1. Station list from the newest product -------------------------------
stns <- get_rr5_stations(refresh = TRUE)

# --- 2. How many product-hours to fetch ------------------------------------
if (!is.na(n_override)) {
  n_products <- n_override
  say("Manual override: newest ", n_products, " products")
} else {
  # One request: the API orders rows newest first (timestamp DESC, since
  # hcdp_api commit 089bd97) and applies `limit` to the whole result, so
  # limit = 1 is the newest stored hour across all gauges.
  newest <- resp_body_json(hcdp_get(paste0(api_url, "/acquisition/nws_rr5/data"),
                                    list(limit = 1)))
  db_ts  <- if (length(newest)) parse_utc(newest[[1]]$timestamp) else as.POSIXct(NA)
  if (is.na(db_ts)) {
    gap_h <- max_fetch_h
    say("No RR5 data in the HCDP database yet")
  } else {
    gap_h <- as.numeric(difftime(Sys.time(), db_ts, units = "hours"))
    say("Newest hour in the HCDP database: ", iso_utc(db_ts))
  }
  fetch_h    <- ceiling(max(min_fetch_h, min(gap_h, max_fetch_h)))
  n_products <- fetch_h + 1   # +1 so the boundary hour is included
  say(sprintf("Database is %.1f hrs behind -> fetching newest %d products",
              gap_h, n_products))
}

# --- 3. List and parse products (newest first) -----------------------------
say("Listing RR5 HFO products...")
listing <- get_json("https://api.weather.gov/products/types/RR5/locations/HFO")
products <- listing$`@graph`
say(length(products), " products available; taking newest ",
        min(n_products, length(products)))
products <- products[seq_len(min(n_products, length(products)))]

parse_product <- function(prod) {
  txt   <- get_json(prod$`@id`)$productText
  lines <- strsplit(txt, "\n")[[1]]

  # obs-ending time from the SHEF .B header: ".B HFO  0730 H  DH 15 ..."
  bline <- grep("^\\.B HFO", lines, value = TRUE)[1]
  m <- regmatches(bline, regexec("^\\.B HFO\\s+(\\d{2})(\\d{2})\\s+H\\s+DH\\s*(\\d{1,2})", bline))[[1]]
  if (length(m) == 0) return(NULL)
  yr <- format(as.POSIXct(prod$issuanceTime, format = "%Y-%m-%dT%H:%M:%S",
                          tz = "UTC"), "%Y")
  obs_end <- as.POSIXct(sprintf("%s-%s-%s %s:00:00", yr, m[2], m[3], m[4]),
                        tz = "Pacific/Honolulu")

  # gauge lines: "PLRH1 : Puu Lua (RAWS)              :    0.00"
  gm <- regmatches(lines,
    regexec("^([A-Z0-9]{3,8})\\s*:\\s*.*?:\\s*(-?[0-9.]+|T|M)\\s*$", lines))
  gm <- gm[lengths(gm) == 3]
  if (length(gm) == 0) return(NULL)

  tibble(
    station_id = map_chr(gm, 2),
    datetime   = obs_end,
    variable   = "precip_1hr",
    value      = map_chr(gm, 3),
    unit       = "in"
  )
}

obs_long <- imap_dfr(products, function(p, i) {
  say(sprintf("Product %d/%d (%s)", i, length(products), p$issuanceTime))
  tryCatch(parse_product(p), error = function(e) {
    warning("Product ", p$`@id`, " failed: ", conditionMessage(e),
            call. = FALSE, immediate. = TRUE)
    NULL
  })
})

if (nrow(obs_long) == 0) stop("No observations parsed.")

# --- 4. Finalize -----------------------------------------------------------
obs_long <- obs_long |>
  mutate(
    value = case_when(value == "M" ~ NA_real_,
                      value == "T" ~ 0.001,
                      .default = suppressWarnings(as.numeric(value))),
    timestamp = iso_utc(datetime)
  ) |>
  # products are processed newest-first, so on reissued hours the newest wins
  # (even when it is "M": a reissue that blanks a value is not undone here)
  distinct(station_id, timestamp, variable, .keep_all = TRUE)

say(sprintf(
  "TOTAL: %d rows (%d missing, not written), %d stations, %d hourly products, %s to %s UTC",
  nrow(obs_long), sum(is.na(obs_long$value)), n_distinct(obs_long$station_id),
  n_distinct(obs_long$timestamp),
  format(min(obs_long$datetime), "%Y-%m-%d %H:%M", tz = "UTC"),
  format(max(obs_long$datetime), "%Y-%m-%d %H:%M", tz = "UTC")
))

# --- 5. Write to the HCDP database -----------------------------------------
# Observations upsert on station_id + timestamp + variable, so a re-fetched
# value replaces what the database had. They are written oldest hour first:
# every product covers every gauge, so a run that dies partway leaves the
# database complete up to its newest stored hour, which is where step 2
# resumes (the 12-hour minimum re-covers that boundary hour).
data_rows <- obs_long |>
  filter(!is.na(value)) |>
  arrange(timestamp, station_id) |>
  select(station_id, timestamp, variable, value)
var_rows <- obs_long |>
  distinct(variable, unit)
# Station metadata is upserted every run, as in the MADIS and NWS API
# workflows. station_name is the product's location text (the master list's
# name for a gauge no longer in the newest product); skn / lat / lng are NA
# where the master list has no unambiguous NWS.id match.
amb <- intersect(unique(data_rows$station_id), meta_dupes)
if (length(amb))
  say("Ambiguous NWS.id entries in master table this run (treated as unmatched): ",
      paste(amb, collapse = ", "))
station_rows <- tibble(station_id = unique(data_rows$station_id)) |>
  left_join(select(stns, station_id, location), by = "station_id") |>
  left_join(meta_lookup, by = "station_id") |>
  transmute(station_id, station_name = coalesce(location, master_name),
            skn, lat, lng) |>
  arrange(station_id)
say(sum(!is.na(station_rows$skn)), " of ", nrow(station_rows),
    " reporting stations matched in the master station list")

say("Writing to the HCDP database (", api_url, ")...")
n_sta <- hcdp_write("nws_rr5", "stationMetadata", station_rows)
n_var <- hcdp_write("nws_rr5", "variableMetadata", var_rows, overwrite = FALSE)
n_obs <- hcdp_write("nws_rr5", "data", data_rows)
say(sprintf("Database: %.0f observation rows written; %.0f station rows upserted, %.0f new variables",
            n_obs, n_sta, n_var))
