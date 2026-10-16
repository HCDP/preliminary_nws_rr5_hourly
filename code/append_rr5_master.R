# Append the latest code/get_rr5_archive.R output (rr5_obs_long.csv) into a
# growing master table (rr5_master.csv), deduplicated on
# station_id + datetime + variable.
#
# Usage:
#   Rscript code/append_rr5_master.R                     defaults below
#     (defaults are data_out/ at the project root, not the working dir)
#   Rscript code/append_rr5_master.R new.csv master.csv  explicit paths
#
# Intended flow (e.g. hourly scheduled task):
#   Rscript code/get_rr5_archive.R      # writes rr5_obs_long.csv
#   Rscript code/append_rr5_master.R    # folds it into rr5_master.csv
#
# On overlapping keys the INCOMING row wins, so a corrected/reissued
# hour from a fresh pull replaces what the master already had.

suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(readr))   # much faster than read.csv at master-file scale (millions of rows)

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
mainDir <- .env_dir("RR5_PROJECT_ROOT")
out_dir <- .env_dir("RR5_DATA_OUT", file.path(mainDir, "data_out"),
                    must_exist = FALSE)

args        <- commandArgs(trailingOnly = TRUE)
new_file    <- if (length(args) >= 1) args[1] else file.path(out_dir, "rr5_obs_long.csv")
master_file <- if (length(args) >= 2) args[2] else file.path(out_dir, "rr5_master.csv")

if (!file.exists(new_file)) stop("Input not found: ", new_file)

cols <- c("station_id", "datetime", "variable", "value", "unit")
col_spec <- cols_only(
  station_id = col_character(), datetime = col_character(),
  variable   = col_character(), value    = col_double(),
  unit       = col_character()
)

# Older runs wrote a POSIXct datetime, so write.csv rendered midnight as a
# bare "2026-08-20". Pad those back to a full timestamp on both sides, or
# the same hour would key twice and land in the master as a duplicate row.
pad_midnight <- function(x) ifelse(nchar(x) == 10, paste0(x, " 00:00:00"), x)

incoming <- read_csv(new_file, col_types = col_spec, progress = FALSE)
if (!all(cols %in% names(incoming))) {
  stop(new_file, " is missing expected columns: ",
       paste(setdiff(cols, names(incoming)), collapse = ", "))
}
incoming <- incoming[cols] |> mutate(datetime = pad_midnight(datetime))

if (file.exists(master_file)) {
  master <- read_csv(master_file, col_types = col_spec, progress = FALSE)[cols] |>
    mutate(datetime = pad_midnight(datetime))
  n_before <- nrow(master)
} else {
  master <- incoming[0, ]
  n_before <- 0
  dir.create(dirname(master_file), recursive = TRUE, showWarnings = FALSE)
  say("No existing master — creating ", master_file)
}

# incoming first so it wins on duplicate keys
combined <- bind_rows(incoming, master) |>
  distinct(station_id, datetime, variable, .keep_all = TRUE) |>
  arrange(station_id, datetime, variable)

write_csv(combined, master_file, progress = FALSE)

say(sprintf(
  "master: %d rows before, %d incoming, %d after (%+d); %s to %s",
  n_before, nrow(incoming), nrow(combined), nrow(combined) - n_before,
  min(combined$datetime), max(combined$datetime)
))
