#!/bin/bash

set -euo pipefail

echo "[task.sh] [1/2] Starting Execution."
export TZ="UTC"
source /workspace/envs/prod.env

echo "[task.sh] [2/2] Running workflow."
Rscript /workspace/code/get_rr5_archive.R

echo "[task.sh] All done!"