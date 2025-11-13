#!/usr/bin/env bash
set -uo pipefail

############################
# Environment checks
############################

if [ -z "${TOOLDIR}" ]; then
  echo "Error: TOOLDIR(Vortex Toolchain) is not defined. Please check your Vortex environment."
  exit 1
fi

if [ -z "${VORTEX_HOME}" ]; then
  echo "Error: VORTEX_HOME is not defined. Please check whether Vortex is built and installed."
  exit 1
fi

if [ -z "${LLVM_VORTEX}" ]; then
  echo "Error: LLVM_VORTEX is not defined. Please check whether Vortex LLVM is built and installed."
  exit 1
fi

if [ -z "${CuPBoP_PATH}" ]; then
  echo "Error: CuPBoP_PATH is not defined. Please check whether CuPBoP is built and installed."
  exit 1
fi

if [ -z "${VORTEX_PATH}" ]; then
  echo "Error: VORTEX_PATH is not defined. Please check where vortex builds are located"
  exit 1
fi

#!/usr/bin/env bash
set -uo pipefail

############################
# Input arguments
############################

# Usage
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: ./CGO_batch_warp_feature_run.sh [SUFFIX]

  SUFFIX          : suffix to append to result filenames (e.g., test1 → *_test1.txt)
                    (default: _test_tmp)
USAGE
  exit 0
fi

# Input 1: suffix
raw_suffix="${1:-_test_tmp}"
if [[ "${raw_suffix}" != _* ]]; then
  base_suffix="_${raw_suffix}"
else
  base_suffix="${raw_suffix}"
fi

# Benchmarks to run
benchmarks=(
  vote-cuda
  shuffle-cuda
  bscan-cuda
  atomicAggregate-cuda
  gc-cuda
)

# Script to run inside each benchmark folder
runner="./kjrun_llvm18.sh"

# Log directory
logdir="logs"
mkdir -p "$logdir"

############################
# Utility functions
############################

sanitize() {
  local s="$1"
  s="${s//\//_}"
  s="${s//+/_}"
  s="${s// /_}"
  printf "%s" "$s"
}



# Run one benchmark
run_one() {
  local d="$1"
  local tag
  tag="$(sanitize "$d")"
  local log="$logdir/${tag}.log"

  # Result filename
  local out_name="CGO_perf_counter_1C_32W_32T_SCHE_2_LOCAL_MEM_1.txt"
  local base_noext="${out_name%.txt}"
  local renamed_name="${base_noext}${base_suffix}.txt"

  {
    echo "[$(date +'%F %T')] >>> start $d (out=$renamed_name)"

    if [[ ! -d "$d" ]]; then
      echo "Folder not found: $d"
      echo "[$(date +'%F %T')] <<< done $d (missing dir)"
      return 1
    fi

    pushd "$d" >/dev/null || { echo "Failed to cd: $d"; return 2; }

    # Apply environment settings
    source "$CuPBoP_PATH/CuPBoP_env_setup_wo_Pocl.sh"
    export VORTEX_SCHEDULE_FLAG=2

    # Run benchmark script
    if [[ ! -x "$runner" ]]; then
      echo "Runner not found or not executable: $runner"
      popd >/dev/null
      echo "[$(date +'%F %T')] <<< done $d (runner missing)"
      return 3
    fi

    echo "RUN: $runner"
    "$runner"
    rc=$?
    echo "RUN RC=$rc"

    local produced=0
    if [[ -f "$out_name" ]]; then
      mv -f "$out_name" "$renamed_name"
      echo "RENAMED: $out_name -> $renamed_name"
      produced=1
    elif [[ -f "$renamed_name" ]]; then
      produced=1
      echo "SKIP RENAME: already present $renamed_name"
    else
      echo "Result file not found: $out_name"
    fi

    if [[ $rc -ne 0 ]]; then
      if [[ $rc -eq 255 ]]; then
        echo "NOTE: runner uses 'exit -1'; treating as SUCCESS"
        rc=0
      elif [[ $produced -eq 1 ]]; then
        echo "NOTE: non-zero RC but result exists; treating as SUCCESS"
        rc=0
      fi
    fi

    popd >/dev/null
    echo "[$(date +'%F %T')] <<< done $d (rc=$rc)"
    return $rc
  } | tee "$log"
}

############################
# Main: run benchmarks in parallel
############################

overall_fail=0

pids=()
names=()

for d in "${benchmarks[@]}"; do
  (
    echo "[$(date +'%F %T')] schedule $d"
    run_one "$d"
  ) &
  pids+=($!)
  names+=("$d")
  sleep 20
done

fail=0
echo
echo "=== WAITING JOBS ==="
for i in "${!pids[@]}"; do
  pid=${pids[$i]}
  name=${names[$i]}
  if wait "$pid"; then
    echo "[OK]  $name"
  else
    echo "[ERR] $name"
    fail=$((fail+1))
  fi
done

echo "=== DONE: ${#pids[@]} jobs, fail=$fail ==="
overall_fail=$((overall_fail + fail))

#python completed_email.py || true
echo "=== ALL DONE: total_fail=$overall_fail ==="
exit $overall_fail