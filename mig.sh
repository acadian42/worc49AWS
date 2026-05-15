#!/bin/bash
set -uo pipefail

SOURCE_BUCKET="<src>"
SOURCE_PREFIX="awn-data-export-bucket/"
DEST_BUCKET="<dest>"
PARALLEL_JOBS=16    # tune to vCPU count

WORK_DIR="$HOME/migration-state"
mkdir -p "$WORK_DIR"
OBJECT_LIST="$WORK_DIR/objects.txt"
COMPLETED="$WORK_DIR/completed.txt"
FAILED="$WORK_DIR/failed.txt"
LOG="$WORK_DIR/migration.log"
touch "$COMPLETED" "$FAILED"

# Build object list once (resumable: skips if file exists)
if [[ ! -s "$OBJECT_LIST" ]]; then
  echo "$(date) Listing source objects..." | tee -a "$LOG"
  aws s3api list-objects-v2 \
    --bucket "$SOURCE_BUCKET" --prefix "$SOURCE_PREFIX" \
    --query 'Contents[].Key' --output text \
    | tr '\t' '\n' > "$OBJECT_LIST"
fi

TOTAL=$(wc -l < "$OBJECT_LIST")
echo "$(date) Total objects to process: $TOTAL" | tee -a "$LOG"

process_object() {
  local key="$1"
  local dest_key="${key#${SOURCE_PREFIX}}"   # strip source prefix
  dest_key="${dest_key%.zst}.gz"             # swap extension

  # Resume support: skip if already done
  grep -Fxq "$key" "$COMPLETED" && return 0

  if aws s3 cp "s3://${SOURCE_BUCKET}/${key}" - \
      | zstd -d --stdout \
      | pigz -c -p 1 \
      | aws s3 cp --expected-size 5368709120 - "s3://${DEST_BUCKET}/${dest_key}"
  then
    echo "$key" >> "$COMPLETED"
  else
    echo "$key" >> "$FAILED"
    echo "$(date) FAILED: $key" >> "$LOG"
  fi
}
export -f process_object
export SOURCE_BUCKET DEST_BUCKET SOURCE_PREFIX COMPLETED FAILED LOG

cat "$OBJECT_LIST" \
  | parallel -j "$PARALLEL_JOBS" --bar --joblog "$WORK_DIR/joblog.tsv" process_object

echo "$(date) Done. Completed: $(wc -l < $COMPLETED) / Failed: $(wc -l < $FAILED)" | tee -a "$LOG"
