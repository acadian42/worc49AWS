#!/bin/bash
set -uo pipefail


# ---- Buckets / paths --------------------------------------------------
SOURCE_BUCKET="testbucket"
SOURCE_PREFIX="awn-data-export-bucket/"   # stripped from destination keys
JOURNAL_ROOT="rawjournal"                 # date tree lives under here
DEST_BUCKET="testbucket1"
PARALLEL_JOBS=16                          # tune to vCPU count

# ---- Date window (INCLUSIVE) -----------------------------------------
# To process ONE MONTH at a time, just narrow these (e.g. 2025-06-01 / 2025-06-30).
START_DATE="2025-06-03"   # <-- I read "June 3, 2025". If you meant the 23rd: 2025-06-23
END_DATE="2026-04-29"     # April 29, 2026

FILTER_REGEX='customer'

# ---- Mode -------------------------------------------------------------
#   validate (default) : check selection + date window + conversion integrity.
#                        100% READ-ONLY on the destination bucket. Touches nothing.
#   run                : perform the real migration.
MODE="${MODE:-validate}"
SMOKE_N="${SMOKE_N:-3}"          # # of sample files to integrity-check in validate mode
TEST_UPLOAD="${TEST_UPLOAD:-0}"  # validate only: ALSO test the real S3 upload path.
                                 # Writes a temp object to dest then deletes it.
                                 # WARNING: dest may feed CrowdStrike ingest -> leave 0 unless sure.
# =========================================================================

# State is namespaced per date-range so month-by-month runs never collide.
WORK_DIR="$HOME/migration-state/${START_DATE}_to_${END_DATE}"
mkdir -p "$WORK_DIR"
OBJECT_LIST="$WORK_DIR/objects.txt"
FILTERED_LIST="$WORK_DIR/objects-filtered.txt"
COMPLETED="$WORK_DIR/completed.txt"
FAILED="$WORK_DIR/failed.txt"
JOBLOG="$WORK_DIR/joblog.tsv"
LOG="$WORK_DIR/migration.log"
touch "$COMPLETED" "$FAILED"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

# ---- Preflight: required tools + working AWS creds --------------------
preflight() {
  local missing=0 c
  for c in aws zstd pigz parallel date sha256sum mktemp; do
    command -v "$c" >/dev/null 2>&1 || { echo "MISSING TOOL: $c"; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || { echo "Install the missing tool(s) and re-run."; exit 1; }
  date -d "2025-01-01" >/dev/null 2>&1 || { echo "GNU 'date -d' required (Linux). Aborting."; exit 1; }
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "AWS credentials not working (aws sts get-caller-identity failed)."; exit 1
  fi
  log "Preflight OK (tools present, AWS creds valid)."
}

# ---- Generate inclusive day-prefixes ----------------------------------
gen_day_prefixes() {
  local d="$START_DATE"
  while [[ ! "$d" > "$END_DATE" ]]; do          # while d <= END_DATE
    printf '%s%s/%s/\n' "$SOURCE_PREFIX" "$JOURNAL_ROOT" "$(date -d "$d" +%Y/%m/%d)"
    d=$(date -d "$d +1 day" +%Y-%m-%d)
  done
}

# ---- Build the object list once (resumable: reuses cache) -------------
build_list() {
  if [[ -s "$OBJECT_LIST" ]]; then
    log "Reusing cached listing ($(wc -l < "$OBJECT_LIST") objects): $OBJECT_LIST"
    return
  fi
  log "Listing source objects for $START_DATE .. $END_DATE (inclusive)..."
  : > "$OBJECT_LIST.tmp"
  local n_days=0
  while IFS= read -r dprefix; do
    n_days=$((n_days+1))
    aws s3api list-objects-v2 \
      --bucket "$SOURCE_BUCKET" --prefix "$dprefix" \
      --query 'Contents[].Key' --output text 2>>"$LOG" \
      | tr '\t' '\n' >> "$OBJECT_LIST.tmp"
  done < <(gen_day_prefixes)
  grep -v -e '^None$' -e '^[[:space:]]*$' "$OBJECT_LIST.tmp" > "$OBJECT_LIST" || true
  rm -f "$OBJECT_LIST.tmp"
  log "Scanned $n_days day-prefixes; $(wc -l < "$OBJECT_LIST") objects listed."
}

dest_key_for() { local k="${1#${SOURCE_PREFIX}}"; printf '%s' "${k%.zst}.gz"; }

# ---- Phase 1: selection + date reconciliation -------------------------
report_selection() {
  grep -E "$FILTER_REGEX" "$OBJECT_LIST" > "$FILTERED_LIST" || true
  local total match cust_opt cust_plain awn skip
  total=$(wc -l < "$OBJECT_LIST")
  match=$(wc -l < "$FILTERED_LIST")
  cust_opt=$(grep -c 'customer-optimized' "$FILTERED_LIST" || true); cust_opt=${cust_opt:-0}
  cust_plain=$(( match - cust_opt ))
  awn=$(grep -c 'awn-optimized' "$OBJECT_LIST" || true); awn=${awn:-0}
  skip=$(( total - match ))

  echo
  echo "================= SELECTION / DATE SUMMARY ================="
  echo "Date window (inclusive)  : $START_DATE  ->  $END_DATE"
  echo "Objects in window (all)  : $total"
  echo "WILL MIGRATE (customer*) : $match"
  echo "    customer-optimized   : $cust_opt"
  echo "    customer (plain)     : $cust_plain"
  echo "WILL SKIP                : $skip"
  echo "    awn-optimized counted: $awn"
  echo "==========================================================="
  if [[ "$skip" -ne "$awn" ]]; then
    echo "!! WARNING: $((skip-awn)) skipped object(s) are NOT awn-optimized."
    echo "   Inspect these unexpected types BEFORE running live:"
    grep -vE "$FILTER_REGEX" "$OBJECT_LIST" | grep -v 'awn-optimized' | head -n 10 | sed 's/^/     /'
  else
    echo "OK: every skipped object is awn-optimized (matches your '3 source types')."
  fi
  echo
  echo "---- sample objects to MIGRATE (first 5), src -> dst ----"
  head -n 5 "$FILTERED_LIST" | while IFS= read -r key; do
    echo "  SRC s3://${SOURCE_BUCKET}/${key}"
    echo "  DST s3://${DEST_BUCKET}/$(dest_key_for "$key")"
  done
  echo
}

# ---- Phase 2: conversion integrity (reads only; NO dest writes) -------
integrity_check() {
  echo "---- conversion integrity check on up to $SMOKE_N sample file(s) ----"
  local key tmp h1 h2 i=0
  while IFS= read -r key; do
    i=$((i+1)); [[ "$i" -le "$SMOKE_N" ]] || break
    tmp=$(mktemp -d)
    if ! aws s3 cp "s3://${SOURCE_BUCKET}/${key}" "$tmp/orig.zst" >/dev/null 2>>"$LOG"; then
      echo "  FAIL  download  $key"; rm -rf "$tmp"; continue
    fi
    # Exact production transform, run locally:  zstd -d | pigz
    zstd -d --stdout "$tmp/orig.zst" 2>/dev/null | pigz -c -p 1 > "$tmp/out.gz" 2>/dev/null
    h1=$(zstd -d --stdout "$tmp/orig.zst" 2>/dev/null | sha256sum | awk '{print $1}')
    h2=$(gunzip -c "$tmp/out.gz" 2>/dev/null | sha256sum | awk '{print $1}')
    if [[ -n "$h1" && "$h1" == "$h2" ]]; then
      echo "  PASS  $(basename "$key")  (decompressed bytes identical, valid gzip)"
    else
      echo "  FAIL  $(basename "$key")  (h1=$h1 h2=$h2)"
    fi
    rm -rf "$tmp"
  done < "$FILTERED_LIST"

  if [[ "$TEST_UPLOAD" == "1" ]]; then
    echo
    echo "  TEST_UPLOAD=1: exercising the real streaming upload to dest (temp, will delete)."
    echo "  WARNING: writes to s3://${DEST_BUCKET}/_smoketest/ -- confirm CrowdStrike ignores that prefix."
    local key2 smoke
    key2=$(head -n 1 "$FILTERED_LIST")
    if [[ -n "$key2" ]]; then
      smoke="_smoketest/$(date +%s)-$(basename "$(dest_key_for "$key2")")"
      if aws s3 cp "s3://${SOURCE_BUCKET}/${key2}" - 2>>"$LOG" \
           | zstd -d --stdout \
           | pigz -c -p 1 \
           | aws s3 cp --expected-size 5368709120 - "s3://${DEST_BUCKET}/${smoke}" >/dev/null 2>>"$LOG"
      then
        echo "  PASS  streaming upload OK -> s3://${DEST_BUCKET}/${smoke}"
        aws s3 rm "s3://${DEST_BUCKET}/${smoke}" >/dev/null 2>>"$LOG" && echo "  cleaned up test object."
      else
        echo "  FAIL  streaming upload failed (see $LOG)"
      fi
    fi
  fi
  echo
}

# ---- The actual per-object migration ----------------------------------
process_object() {
  local key="$1"
  local dest_key="${key#${SOURCE_PREFIX}}"
  dest_key="${dest_key%.zst}.gz"
  if aws s3 cp "s3://${SOURCE_BUCKET}/${key}" - \
       | zstd -d --stdout \
       | pigz -c -p 1 \
       | aws s3 cp --expected-size 5368709120 - "s3://${DEST_BUCKET}/${dest_key}"
  then
    echo "$key" >> "$COMPLETED"
  else
    echo "$key" >> "$FAILED"
    echo "$(date '+%F %T') FAILED: $key" >> "$LOG"
  fi
}
export -f process_object
export SOURCE_BUCKET DEST_BUCKET SOURCE_PREFIX COMPLETED FAILED LOG

# =========================================================================
#  MAIN
# =========================================================================
preflight
build_list
report_selection

case "$MODE" in
  validate)
    integrity_check
    echo ">>> MODE=validate : nothing was migrated, no writes to the destination bucket."
    echo ">>> Review the numbers above. When satisfied, run for real with:"
    echo ">>>     MODE=run $0"
    ;;
  run)
    log "LIVE RUN: migrating $(wc -l < "$FILTERED_LIST") objects ($START_DATE .. $END_DATE)"
    # --resume-failed: skips already-succeeded jobs and retries failed/unrun ones.
    parallel -j "$PARALLEL_JOBS" --bar --resume-failed --joblog "$JOBLOG" \
      process_object :::: "$FILTERED_LIST"
    n_total=$(wc -l < "$FILTERED_LIST")
    n_done=$(grep -Fxf "$COMPLETED" "$FILTERED_LIST" 2>/dev/null | sort -u | wc -l)
    n_pending=$(( n_total - n_done ))
    log "Run complete. In-scope: $n_total  Completed: $n_done  Pending/failed: $n_pending"
    [[ "$n_pending" -gt 0 ]] && log "Re-run 'MODE=run $0' to retry the remaining $n_pending."
    ;;
  *)
    echo "Unknown MODE='$MODE' (use validate or run)"; exit 1 ;;
esac

