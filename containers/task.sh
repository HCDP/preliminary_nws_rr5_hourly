#!/bin/bash

set -euo pipefail

echo "[task.sh] [1/2] Starting Execution."
export TZ="HST"
source /workspace/envs/prod.env

echo "[task.sh] [2/2] Running workflow."
Rscript /workspace/code/get_rr5_archive.R
Rscript /workspace/code/append_rr5_master.R

echo "[task.sh] All done!"