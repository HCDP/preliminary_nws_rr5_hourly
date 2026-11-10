# Cache-aware, sourceable function for the RR5 gauge station list —
# same interface as get_station_catalog() in get_station_catalog_fn.R.
# Returns a data frame:
#   station_id | location | source | island | latest_obs_api
# (parsed from the newest RR5HFO product; source "hydronet" = numeric
# county-gauge IDs in the product text).
#
#   latest_obs_api  — the newest product's obs-ending hour if the station
#                     reported a real value in it (NA if it reported "M"),
#                     as UTC ISO 8601 text ("YYYY-MM-DDTHH:MM:SSZ")
# What has already been collected is not tracked here -- the fetcher asks
# the HCDP database for that.
#
# As a library:
#   source("code/get_rr5_stations_fn.R")
#   stns <- get_rr5_stations()                  # read cache, or build if absent
#   stns <- get_rr5_stations(refresh = TRUE)    # re-parse newest product + overwrite
#
# Arguments:
#   latest    add the latest_obs_api column when building (default TRUE)
#   dir       directory holding the CSV (default: dataCatalog/ at the
#             project root — NOT the working directory — created if
#             missing; file is rr5_stations.csv inside it)
#   write_csv when building, save the list there (default TRUE)
#   refresh   TRUE = ignore any existing CSV, rebuild from the newest
#             RR5HFO product and overwrite (default FALSE: an existing
#             CSV is read and returned as-is, no API calls)
#
# As a script (always refreshes):
#   Rscript code/get_rr5_stations_fn.R
#   -> dataCatalog/rr5_stations.csv (at the project root)

suppressPackageStartupMessages(library(httr2))
suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(tibble))

# progress goes to stdout via say(), not message()/stderr, so the cron job's
# .err log collects only real problems (warnings and errors). say() matches
# message() semantics: arguments pasted with no separator, newline appended.
say <- function(...) cat(..., "\n", sep = "")

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
#   RR5_DATA_OUT               optional   default $RR5_PROJECT_ROOT/data_out
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
.data_dir    <- .env_dir("RR5_PROJECT_ROOT")
.code_dir    <- .env_dir("RR5_CODE_DIR",     file.path(.data_dir, "code"))
.catalog_dir <- .env_dir("RR5_DATA_CATALOG", file.path(.data_dir, "dataCatalog"),
                         must_exist = FALSE)

get_rr5_stations <- function(latest = TRUE,
                             dir = .catalog_dir,
                             write_csv = TRUE, refresh = FALSE,
                             ua = "R script (hcdp@hawaii.edu)") {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  csv_path <- file.path(dir, "rr5_stations.csv")

  # --- cached copy? -------------------------------------------------------
  if (!refresh && file.exists(csv_path)) {
    say("Reading existing RR5 station list: ", csv_path,
            " (last modified ", format(file.mtime(csv_path)), ")")
    return(read.csv(csv_path))
  }

  # --- newest RR5HFO product ----------------------------------------------
  get_json <- function(url) {
    request(url) |>
      req_headers(`User-Agent` = ua, Accept = "application/ld+json") |>
      req_retry(max_tries = 3) |>
      req_perform() |>
      resp_body_json()
  }
  say("Fetching newest RR5HFO product...")
  listing <- get_json("https://api.weather.gov/products/types/RR5/locations/HFO")
  newest  <- listing$`@graph`[[1]]
  txt     <- get_json(newest$`@id`)$productText
  lines   <- strsplit(txt, "\n")[[1]]

  # obs-ending time from the SHEF .B header: ".B HFO  0813 H  DH 15 ..."
  bline <- grep("^\\.B HFO", lines, value = TRUE)[1]
  bm <- regmatches(bline, regexec(
    "^\\.B HFO\\s+(\\d{2})(\\d{2})\\s+H\\s+DH\\s*(\\d{1,2})", bline))[[1]]
  prod_time <- if (length(bm) == 4) {
    yr <- format(as.POSIXct(newest$issuanceTime, format = "%Y-%m-%dT%H:%M:%S",
                            tz = "UTC"), "%Y")
    # the SHEF hour is HST; written as UTC like every other timestamp here
    format(as.POSIXct(sprintf("%s-%s-%s %s:00:00", yr, bm[2], bm[3], bm[4]),
                      tz = "Pacific/Honolulu"),
           "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  } else NA_character_

  # --- parse gauge lines ---------------------------------------------------
  island <- NA_character_
  stn <- list()
  for (ln in lines) {
    # header looks like ":Island of Oahu                         Inches"
    im <- regmatches(ln, regexec("^:Islands? of ([A-Za-z ]+)", ln))[[1]]
    if (length(im) == 2) { island <- trimws(sub("\\s{2,}.*$", "", im[2])); next }
    gm <- regmatches(ln, regexec(
      "^([A-Z0-9]{3,8})\\s*:\\s*(.*?)\\s*:\\s*(-?[0-9.]+|T|M)\\s*$", ln))[[1]]
    if (length(gm) == 4) {
      loc <- gm[3]
      sm  <- regmatches(loc, regexec("^(.*?)\\s*\\(([^)]*)\\)\\s*$", loc))[[1]]
      if (length(sm) == 3) {
        src <- if (grepl("^[0-9]+$", sm[3])) "hydronet" else sm[3]
        loc <- sm[2]
      } else src <- NA_character_
      stn[[length(stn) + 1]] <- tibble(
        station_id = gm[2], location = loc, source = src, island = island,
        latest_obs_api = if (gm[4] == "M") NA_character_ else prod_time)
    }
  }
  station_list <- bind_rows(stn) |>
    distinct(station_id, .keep_all = TRUE) |>
    arrange(station_id)
  say(nrow(station_list), " stations parsed from product issued ",
          newest$issuanceTime, " (",
          sum(!is.na(station_list$latest_obs_api)), " reporting)")

  if (!latest) station_list$latest_obs_api <- NULL

  # --- save ---------------------------------------------------------------
  if (write_csv) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    write.csv(station_list, csv_path, row.names = FALSE)
    say("Written to ", csv_path)
  }

  station_list
}

# --- run as a script -------------------------------------------------------
if (sys.nframe() == 0) {
  invisible(get_rr5_stations(refresh = TRUE))
}
