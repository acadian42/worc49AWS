#!/bin/bash
set -uo pipefail


SOURCE_BUCKET="testa"
DEST_BUCKET="testb"

# Prefix stripped to build the destination key. MUST match the prod script
# so the resulting keys are identical (-> rawjournal/2025/05/07/...log.gz).
DEST_STRIP_PREFIX="awn-data-export-bucket/"

# Only this single day is listed and processed for the test.
TEST_PREFIX="awn-data-export-bucket/rawjournal/2025/05/07/"

# Optional smoke-test cap: process at most N files (0 = the whole day).
#   MAX_FILES=5 ./migration-test-singleday.sh   # first 5 objects only
# Recommended: run with MAX_FILES=5 first, confirm CrowdStrike parses them,
# then re-run with MAX_FILES=0 for the full day.
MAX_FILES="${MAX_FILES:-0}"

# Same multipart sizing hint the prod script uses for streamed uploads.
EXPECTED_SIZE=5368709120   # 5 GiB upper bound; safe to overestimate

# ---------------------------------------------------------------------------

WORK_DIR="$HOME/migration-test-state"   # kept separate from prod state
mkdir -p "$WORK_DIR"
OBJECT_LIST="$WORK_DIR/objects.txt"
COMPLETED="$WORK_DIR/completed.txt"
FAILED="$WORK_DIR/failed.txt"
LOG="$WORK_DIR/migration-test.log"
touch "$COMPLETED" "$FAILED"

# Build the day's object list once (resumable: skips if the file exists).
# NOTE: the AWS CLI auto-paginates list-objects-v2, so this captures EVERY
# object under the prefix even though the S3 console only displays 1000.
if [[ ! -s "$OBJECT_LIST" ]]; then
  echo "$(date) Listing objects under $TEST_PREFIX ..." | tee -a "$LOG"
  aws s3api list-objects-v2 \
    --bucket "$SOURCE_BUCKET" --prefix "$TEST_PREFIX" \
    --query 'Contents[].Key' --output text \
    | tr '\t' '\n' \
    | sed '/^$/d' > "$OBJECT_LIST"
fi

TOTAL=$(wc -l < "$OBJECT_LIST")
echo "$(date) Objects found for the day: $TOTAL" | tee -a "$LOG"
if [[ "$MAX_FILES" -gt 0 ]]; then
  echo "$(date) MAX_FILES=$MAX_FILES -> processing only the first $MAX_FILES" | tee -a "$LOG"
fi

process_object() {
  local key="$1"
  local dest_key="${key#${DEST_STRIP_PREFIX}}"   # strip prefix -> prod layout
  dest_key="${dest_key%.zst}.gz"                 # swap extension

  if aws s3 cp "s3://${SOURCE_BUCKET}/${key}" - \
      | zstd -d --stdout \
      | pigz -c -p 1 \
      | aws s3 cp --expected-size "$EXPECTED_SIZE" - "s3://${DEST_BUCKET}/${dest_key}"
  then
    echo "$key" >> "$COMPLETED"
    echo "$(date) OK:     $key  ->  $dest_key" | tee -a "$LOG"
  else
    echo "$key" >> "$FAILED"
    echo "$(date) FAILED: $key" | tee -a "$LOG"
  fi
}

# Deliberately SERIAL -- no parallelism, safe for the t2.micro test.
count=0
while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  grep -Fxq "$key" "$COMPLETED" && continue   # resume: skip already-done
  process_object "$key"
  count=$((count + 1))
  if [[ "$MAX_FILES" -gt 0 && "$count" -ge "$MAX_FILES" ]]; then
    echo "$(date) Reached MAX_FILES=$MAX_FILES, stopping." | tee -a "$LOG"
    break
  fi
done < "$OBJECT_LIST"

echo "$(date) Done. Completed: $(wc -l < "$COMPLETED") / Failed: $(wc -l < "$FAILED")" \
  | tee -a "$LOG"

