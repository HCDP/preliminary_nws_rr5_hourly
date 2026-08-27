# Catalog-driven incremental pull of the RR5HFO products (Hawaii One-Hour
# Rainfall Summary, SHEF format) from the NWS API, parsed into a
# long-format table:
#   station_id | datetime | variable | value | unit
#
# How it decides what to fetch (via the RR5 station list in dataCatalog/):
#   1. Loads the station list with get_rr5_stations() — reads
#      dataCatalog/rr5_stations.csv if present, otherwise builds and
#      writes it (first run).
#   2. Every RR5 product carries ALL gauges, so the incremental unit is
#      hours of products, not per-station windows: it fetches from the
#      oldest latest_obs_data across stations to now, with a 12-hour
#      minimum and the ~7-day product retention as the cap. No station
#      has latest_obs_data at all -> full retention. Note that
#      latest_obs_data tracks the newest non-missing value, so a gauge
#      sending "M" for a while widens the window -- deliberate
#      over-fetching, since re-fetched hours dedupe on append.
#   3. After writing data_out/rr5_obs_long.csv, refreshes the station
#      list (refresh = TRUE) so the file reflects this fetch.
#
# Usage:
#   Rscript code/get_rr5_archive.R      catalog-driven window (default)
#   Rscript code/get_rr5_archive.R 73   manual override: newest 73 products
#
# Output: data_out/rr5_obs_long.csv, dataCatalog/rr5_stations.csv
#         (both are created at the project root -- the parent of code/ --
#         NOT in the working directory)
#
# Notes:
#  - Products come from https://api.weather.gov/products/types/RR5/locations/HFO
#    (~7 days retention; one product per hour).
#  - Each product reports 1-hr precip totals ending at the hour given in the
#    SHEF .B header (e.g. ".B HFO 0730 H  DH 15" = Jul 30, 15:00 HST).
#  - Value coding: 'M' (missing) -> NA; 'T' (trace) -> 0.001 in.
#  - If an hour was reissued/corrected, the newest issuance wins.

# code/ directory this script lives in (Rscript --file=...; falls back to
# the working directory if the script is sourced interactively). The
# project root -- where the data directories live -- is its parent. Source
# the station-list function from code/ so the pair stays linked no matter
# where the process was launched from.
codeDir <- local({
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(fa))
    dirname(normalizePath(sub("^--file=", "", fa[1]), winslash = "/"))
  else getwd()
})
mainDir <- dirname(codeDir)

source(file.path(codeDir, "get_rr5_stations_fn.R"))   # loads httr2/dplyr/
                                                      # tibble, get_rr5_stations()
suppressPackageStartupMessages(library(purrr))

# progress goes to stdout via say(), not message()/stderr, so the cron job's
# .err log collects only real problems (warnings and errors). say() matches
# message() semantics: arguments pasted with no separator, newline appended.
say <- function(...) cat(..., "\n", sep = "")

# data lives at the project root, not in the working directory
out_dir  <- file.path(mainDir, "data_out")
obs_path <- file.path(out_dir, "rr5_obs_long.csv")

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

# --- 1. Station list: read cache, or build + write on first run ------------
# (lives in dataCatalog/ next to the code — the function's default)
stns <- get_rr5_stations()

# --- 2. How many product-hours to fetch ------------------------------------
if (!is.na(n_override)) {
  n_products <- n_override
  say("Manual override: newest ", n_products, " products")
} else {
  data_ts <- as.POSIXct(sub(" HST$", "", stns$latest_obs_data),
                        tz = "Pacific/Honolulu")
  if (all(is.na(data_ts))) {
    gap_h <- max_fetch_h
  } else {
    gap_h <- as.numeric(difftime(Sys.time(), min(data_ts, na.rm = TRUE),
                                 units = "hours"))
  }
  fetch_h    <- ceiling(max(min_fetch_h, min(gap_h, max_fetch_h)))
  n_products <- fetch_h + 1   # +1 so the boundary hour is included
  say(sprintf(
    "Most-behind reporting station is %.1f hrs old -> fetching newest %d products",
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
    datetime = as.POSIXct(format(datetime, tz = "UTC"), tz = "UTC")
  ) |>
  # products are processed newest-first, so on reissued hours the newest wins
  distinct(station_id, datetime, variable, .keep_all = TRUE) |>
  arrange(station_id, datetime)

say(sprintf(
  "TOTAL: %d rows, %d stations, %d hourly products, %s to %s UTC",
  nrow(obs_long), n_distinct(obs_long$station_id),
  n_distinct(obs_long$datetime),
  format(min(obs_long$datetime), "%Y-%m-%d %H:%M"),
  format(max(obs_long$datetime), "%Y-%m-%d %H:%M")
))

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
# format as text so midnight keeps its "00:00:00" -- write.csv on a POSIXct
# would drop it, and the bare date would not match the rest of the keys
write.csv(transform(obs_long,
                    datetime = format(datetime, "%Y-%m-%d %H:%M:%S", tz = "UTC")),
          obs_path, row.names = FALSE)
say("Written to ", obs_path)

# --- 5. Refresh the station list so it reflects this fetch -----------------
invisible(get_rr5_stations(refresh = TRUE))
