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
Usage: ./CGO_batch_run.sh [SUFFIX] [LOCALMEM_MODE]

  SUFFIX          : suffix to append to result filenames (e.g., test1 → *_test1.txt)
                    (default: _test_tmp)
  LOCALMEM_MODE   : off | on | onoff
                    off    → VORTEX_LOCALMEM_FLAG=0
                    on     → VORTEX_LOCALMEM_FLAG=1
                    onoff  → run twice: first with 1, then with 0
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

# Input 2: localmem mode
localmem_mode="${2:-off}"   # default = off

# Benchmarks to run
benchmarks=(
  bfs
  backprop
  btree
  conv3
  dotproduct
  nn
  pathfinder
  psort
  transpose
  stencil
  sgemm
  saxpy
  vecadd
  psum
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

# Set env_cmds, out_name, and mode_tag depending on localmem flag
set_localmem() {
  local flag="$1"
  if [[ "$flag" == "1" ]]; then
    mode_tag="_lmON"
  else
    mode_tag="_lmOFF"
  fi

  # Result filename depends on LOCAL_MEM flag
  out_name="CGO_perf_counter_4C_16W_32T_SCHE_2_LOCAL_MEM_${flag}.txt"

  env_cmds=(
    "source $CuPBoP_PATH/CuPBoP_env_setup_wo_Pocl.sh"
    "source $CuPBoP_PATH/CuPBoP_env_setup_wo_Pocl.sh"
    "export VORTEX_SCHEDULE_FLAG=2"
    "export VORTEX_LOCALMEM_FLAG=$flag"
  )
}

# Run one benchmark
run_one() {
  local d="$1"
  local mode_suffix="$2"   # used for log file naming

  local tag
  tag="$(sanitize "$d")"
  local log="$logdir/${tag}${mode_suffix}.log"

  # Final result filename = LOCAL_MEM_x + suffix
  local base_noext="${out_name%.txt}"
  local renamed_name="${base_noext}${base_suffix}.txt"

  {
    echo "[$(date +'%F %T')] >>> start $d (mode=${mode_suffix}, out=$renamed_name)"

    if [[ ! -d "$d" ]]; then
      echo "Folder not found: $d"
      echo "[$(date +'%F %T')] <<< done $d (missing dir)"
      return 1
    fi

    pushd "$d" >/dev/null || { echo "Failed to cd: $d"; return 2; }

    # Apply environment settings
    for cmd in "${env_cmds[@]}"; do
      echo "ENV: $cmd"
      eval "$cmd"
    done

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
# Main: run localmem modes → benchmarks in parallel
############################

declare -a LM_SEQUENCE=()

case "$localmem_mode" in
  off)   LM_SEQUENCE=(0) ;;
  on)    LM_SEQUENCE=(1) ;;
  onoff) LM_SEQUENCE=(1 0) ;;   # run with 1 then with 0
  *) echo "Error: LOCALMEM_MODE must be off|on|onoff"; exit 2 ;;
esac

overall_fail=0

for lm in "${LM_SEQUENCE[@]}"; do
  set_localmem "$lm"
  echo
  echo "=== START BATCH: VORTEX_LOCALMEM_FLAG=$lm (${mode_tag}) ==="

  pids=()
  names=()

  for d in "${benchmarks[@]}"; do
    (
      echo "[$(date +'%F %T')] schedule $d (mode ${mode_tag})"
      run_one "$d" "${mode_tag}"
    ) &
    pids+=($!)
    names+=("$d")
    sleep 20
  done

  fail=0
  echo
  echo "=== WAITING JOBS (${mode_tag}) ==="
  for i in "${!pids[@]}"; do
    pid=${pids[$i]}
    name=${names[$i]}
    if wait "$pid"; then
      echo "[OK]  $name ${mode_tag}"
    else
      echo "[ERR] $name ${mode_tag}"
      fail=$((fail+1))
    fi
  done

  echo "=== DONE (${mode_tag}): ${#pids[@]} jobs, fail=$fail ==="
  overall_fail=$((overall_fail + fail))
done

#python completed_email.py || true
echo "=== ALL MODES DONE: total_fail=$overall_fail ==="
exit $overall_fail