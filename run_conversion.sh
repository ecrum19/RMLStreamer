#!/usr/bin/env bash
set -euo pipefail

# ---------- Config ----------
JAR=${JAR:-RMLStreamer-v2.5.0-standalone.jar}
IN=${IN:-rules.ttl}

# Directory where your TSV input files live
DATA_DIR=${DATA_DIR:-}

# Root output directory; each file gets its own subdir
OUT_ROOT_DIR=${OUT_ROOT_DIR:-run_output}

# Metrics directory
LOGDIR=${LOGDIR:-run_metrics}


# rdf2hdt binary
HDT=${RDF2HDT:-bin/rdf2hdt.sh}

# Base URI for rdf2hdt
BASE_URI=${BASE_URI:-http://example.org/base}

mkdir -p "$LOGDIR" "$OUT_ROOT_DIR"

METRICS_CSV="$LOGDIR/metrics.csv"

# List of TSV input files (relative to $DATA_DIR)
FILES=(
  "0GOOR_HG002.tsv"
  # "60820188475559.filtered.snp.tsv"
  # "bsr6402.combined.tsv"
  # "PG0000566-BLD.snps.tsv"
  # "PG0001199-BLD.SNPs.tsv"
  # "PG0001202-BLD.Genotyping.tsv"
)

# ---------- Helper functions ----------

stat_size() {
  local path="$1"

  # --- CASE 1: Regular file ---
  if [[ -f "$path" ]]; then
    # Linux (GNU coreutils)
    if stat -c%s "$path" >/dev/null 2>&1; then
      stat -c%s "$path"
    # macOS/BSD
    elif stat -f%z "$path" >/dev/null 2>&1; then
      stat -f%z "$path"
    else
      wc -c < "$path" | tr -d ' '
    fi
    return
  fi

  # --- CASE 2: Directory ---
  if [[ -d "$path" ]]; then
    # Linux (GNU du)
    if du -sb "$path" >/dev/null 2>&1; then
      du -sb "$path" | awk '{print $1}'
    # macOS/BSD (no -b)
    elif du -sk "$path" >/dev/null 2>&1; then
      local kb
      kb=$(du -sk "$path" | awk '{print $1}')
      echo $((kb * 1024))
    else
      echo 0
    fi
    return
  fi

  echo 0
}

have_gnu_time() { [[ -x /usr/bin/time ]] && /usr/bin/time --version >/dev/null 2>&1; }

# Count triples via number of non-comment lines ending in "."
count_triples_json() {
  local path="$1"
  local total=0

  echo "{"
  shopt -s nullglob

  for f in "$path"/*; do
    if [[ -f "$f" ]]; then
      local count
      count=$(
        grep -E '^[[:space:]]*[^#].*\.[[:space:]]*$' "$f" | wc -l | tr -d ' '
      )
      total=$((total + count))
      printf "  \"%s\": %s,\n" "$f" "$count"
    fi
  done

  shopt -u nullglob
  printf "  \"TOTAL\": %s\n" "$total"
  echo "}"
}

elapsed_to_seconds() {
  awk -F':' '{
    if (NF==3) { h=$1+0; m=$2+0; s=$3+0; printf("%.3f", h*3600 + m*60 + s) }
    else if (NF==2) { m=$1+0; s=$2+0; printf("%.3f", m*60 + s) }
    else { s=$1+0; printf("%.3f", s) }
  }'
}

JAVA_VERSION=$(java -version 2>&1 | head -n1 | sed 's/"/\\"/g')

# CSV header
if [[ ! -f "$METRICS_CSV" ]]; then
  echo "run_id,timestamp,input_tsv,exit_code_java,exit_code_gzip,exit_code_hdt,wall_seconds_java,user_seconds_java,sys_seconds_java,max_rss_kb_java,input_mapping_size_bytes,input_tsv_size_bytes,output_dir_size_bytes,output_triples,jar,mapping_file,output_dir,combined_nq_size_bytes,gzip_size_bytes,hdt_size_bytes" > "$METRICS_CSV"
fi

# ---------- Main loop over TSV files ----------
for TSV_FILE in "${FILES[@]}"; do
  FULL_TSV="$TSV_FILE"
  
  # Script that updates rules.ttl with the current TSV filename
  UPDATE_RULES_SCRIPT=${UPDATE_RULES_SCRIPT:-update_rules.sh}

  if [[ ! -f "$FULL_TSV" ]]; then
    echo "WARNING: TSV file '$FULL_TSV' not found, skipping." >&2
    continue
  fi

  BASENAME="${TSV_FILE%.tsv}"          # strip the .tsv suffix
  OUT_DIR="$OUT_ROOT_DIR"
  OUT_NAME="${BASENAME}_out"
  OUT="$OUT_DIR/$OUT_NAME"

  mkdir -p "$OUT"


  echo "Updating mapping '$IN' using '$UPDATE_RULES_SCRIPT' for '$FULL_TSV'..."
  "bash" "$UPDATE_RULES_SCRIPT" "$FULL_TSV" || {
    echo "WARNING: update script '$UPDATE_RULES_SCRIPT' failed; using existing '$IN' as-is." >&2
  }
  
  RUN_ID=$BASENAME
  TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S")

  TIME_LOG_JAVA="$LOGDIR/time-java-$RUN_ID.txt"
  TIME_LOG_GZIP="$LOGDIR/time-gzip-$RUN_ID.txt"
  TIME_LOG_HDT="$LOGDIR/time-hdt-$RUN_ID.txt"
  METRICS_JSON="$LOGDIR/metrics-$RUN_ID.json"

  # Sizes of mapping and TSV
  IN_SIZE=$(stat_size "$IN")
  TSV_SIZE=$(stat_size "$FULL_TSV")

  # ----- RMLStreamer run -----
  JAVA_CMD=(java -jar "$JAR" toFile -m "$IN" -o "$OUT")

  EXIT_CODE_JAVA=0
  if have_gnu_time; then
    /usr/bin/time -v -o "$TIME_LOG_JAVA" -- "${JAVA_CMD[@]}" || EXIT_CODE_JAVA=$?
  else
    { time -p "${JAVA_CMD[@]}"; } >"$TIME_LOG_JAVA" 2>&1 || EXIT_CODE_JAVA=$?
  fi

  for NO_EXT_FILE in "$OUT"/*; do
    if [[ -f "$NO_EXT_FILE" ]]; then
      mv "$NO_EXT_FILE" "${NO_EXT_FILE}.nq"
    fi
  done

  # Post-run metrics for Java/RML
  OUT_SIZE=$(stat_size "$OUT")
  TRIPLES_JSON=$(count_triples_json "$OUT")

  # Parse timing for Java/RML
  WALL_SEC_JAVA=""
  USER_SEC_JAVA=""
  SYS_SEC_JAVA=""
  MAX_RSS_KB_JAVA=""

  if have_gnu_time; then
    ELAPSED=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$TIME_LOG_JAVA")
    WALL_SEC_JAVA=$(printf "%s" "$ELAPSED" | elapsed_to_seconds)

    USER_SEC_JAVA=$(awk -F': ' '/User time \(seconds\)/ {print $2}' "$TIME_LOG_JAVA")
    SYS_SEC_JAVA=$(awk -F': '  '/System time \(seconds\)/ {print $2}' "$TIME_LOG_JAVA")
    MAX_RSS_KB_JAVA=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$TIME_LOG_JAVA")
  else
    WALL_SEC_JAVA=$(awk '/^real/ {print $2}' "$TIME_LOG_JAVA")
    USER_SEC_JAVA=$(awk '/^user/ {print $2}' "$TIME_LOG_JAVA")
    SYS_SEC_JAVA=$(awk  '/^sys/  {print $2}' "$TIME_LOG_JAVA")
    MAX_RSS_KB_JAVA=""
  fi

  [[ -z "$MAX_RSS_KB_JAVA" ]] && MAX_RSS_KB_JAVA="null"

  # ----- Concatenate N-Quads in this output dir -----
  BIG_NQ="$OUT/${BASENAME}.nq"

  shopt -s nullglob
  NQ_FILES=("$OUT"/*.nq)
  shopt -u nullglob

  if (( ${#NQ_FILES[@]} == 0 )); then
    echo "ERROR: no .nq files found in '$OUT'; cannot build combined.nq. Skipping compression/HDT for this run." >&2
    # We still write a JSON with only the Java part
    BIG_NQ=""
    NQ_SIZE=0
    GZ_PATH=""
    GZ_SIZE=0
    HDT_PATH=""
    HDT_SIZE=0
    EXIT_CODE_GZIP=0
    EXIT_CODE_HDT=0
    WALL_SEC_GZIP="null"
    USER_SEC_GZIP="null"
    SYS_SEC_GZIP="null"
    MAX_RSS_KB_GZIP="null"
    WALL_SEC_HDT="null"
    USER_SEC_HDT="null"
    SYS_SEC_HDT="null"
    MAX_RSS_KB_HDT="null"
  else
    > "$BIG_NQ"
    for f in "${NQ_FILES[@]}"; do
      cat "$f" >> "$BIG_NQ"
    done

    NQ_SIZE=$(stat_size "$BIG_NQ")

    # ----- gzip combined.nq with timing -----
    GZ_PATH="$BIG_NQ.gz"
    EXIT_CODE_GZIP=0

    if have_gnu_time; then
      /usr/bin/time -v -o "$TIME_LOG_GZIP" -- gzip -kf "$BIG_NQ" || EXIT_CODE_GZIP=$?
    else
      { time -p gzip -kf "$BIG_NQ"; } >"$TIME_LOG_GZIP" 2>&1 || EXIT_CODE_GZIP=$?
    fi

    GZ_SIZE=$(stat_size "$GZ_PATH")

    WALL_SEC_GZIP=""
    USER_SEC_GZIP=""
    SYS_SEC_GZIP=""
    MAX_RSS_KB_GZIP=""

    if have_gnu_time; then
      ELAPSED=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$TIME_LOG_GZIP")
      WALL_SEC_GZIP=$(printf "%s" "$ELAPSED" | elapsed_to_seconds)

      USER_SEC_GZIP=$(awk -F': ' '/User time \(seconds\)/ {print $2}' "$TIME_LOG_GZIP")
      SYS_SEC_GZIP=$(awk -F': '  '/System time \(seconds\)/ {print $2}' "$TIME_LOG_GZIP")
      MAX_RSS_KB_GZIP=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$TIME_LOG_GZIP")
    else
      WALL_SEC_GZIP=$(awk '/^real/ {print $2}' "$TIME_LOG_GZIP")
      USER_SEC_GZIP=$(awk '/^user/ {print $2}' "$TIME_LOG_GZIP")
      SYS_SEC_GZIP=$(awk  '/^sys/  {print $2}' "$TIME_LOG_GZIP")
      MAX_RSS_KB_GZIP=""
    fi

    [[ -z "$MAX_RSS_KB_GZIP" ]] && MAX_RSS_KB_GZIP="null"

    # ----- Convert combined.nq to HDT with timing -----
    HDT_PATH="$OUT/$BASENAME.hdt"
    EXIT_CODE_HDT=0

    (
      cd ../hdt-java/hdt-java-cli || exit

      if have_gnu_time; then
        /usr/bin/time -v -o "../../RMLStreamer/${TIME_LOG_HDT}" -- bash "$HDT" "../../RMLStreamer/${BIG_NQ}" "../../RMLStreamer/${HDT_PATH}" || EXIT_CODE_HDT=$?
      else
        { time -p bash "$HDT" "../../RMLStreamer/${BIG_NQ}" "../../RMLStreamer/${HDT_PATH}"; } >"../../RMLStreamer/${TIME_LOG_HDT}" 2>&1 || EXIT_CODE_HDT=$?
      fi
    )


    HDT_SIZE=$(stat_size "$HDT_PATH")

    WALL_SEC_HDT=""
    USER_SEC_HDT=""
    SYS_SEC_HDT=""
    MAX_RSS_KB_HDT=""

    if have_gnu_time; then
      ELAPSED=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$TIME_LOG_HDT")
      WALL_SEC_HDT=$(printf "%s" "$ELAPSED" | elapsed_to_seconds)

      USER_SEC_HDT=$(awk -F': ' '/User time \(seconds\)/ {print $2}' "$TIME_LOG_HDT")
      SYS_SEC_HDT=$(awk -F': '  '/System time \(seconds\)/ {print $2}' "$TIME_LOG_HDT")
      MAX_RSS_KB_HDT=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$TIME_LOG_HDT")
    else
      WALL_SEC_HDT=$(awk '/^real/ {print $2}' "$TIME_LOG_HDT")
      USER_SEC_HDT=$(awk '/^user/ {print $2}' "$TIME_LOG_HDT")
      SYS_SEC_HDT=$(awk  '/^sys/  {print $2}' "$TIME_LOG_HDT")
      MAX_RSS_KB_HDT=""
    fi

    [[ -z "$MAX_RSS_KB_HDT" ]] && MAX_RSS_KB_HDT="null"
  fi

  # ---------- Save JSON ----------
  TOTAL_TRIPLES=$(echo "$TRIPLES_JSON" | grep '"TOTAL"' | awk -F': ' '{print $2}' | tr -d '", ')

  cat > "$METRICS_JSON" <<EOF
{
  "run_id": "$RUN_ID",
  "timestamp": "$TIMESTAMP",
  "input_tsv": "$FULL_TSV",
  "java_command": "$(printf '%q ' "${JAVA_CMD[@]}")",
  "java_exit_code": $EXIT_CODE_JAVA,
  "gzip_exit_code": ${EXIT_CODE_GZIP:-0},
  "hdt_exit_code": ${EXIT_CODE_HDT:-0},
  "java_timing": {
    "wall_seconds": $WALL_SEC_JAVA,
    "user_seconds": $USER_SEC_JAVA,
    "sys_seconds": $SYS_SEC_JAVA,
    "max_rss_kb": $MAX_RSS_KB_JAVA
  },
  "gzip": {
    "input_nq_path": "${BIG_NQ:-}",
    "input_nq_size_bytes": ${NQ_SIZE:-0},
    "output_gz_path": "${GZ_PATH:-}",
    "output_gz_size_bytes": ${GZ_SIZE:-0},
    "timing": {
      "wall_seconds": ${WALL_SEC_GZIP:-null},
      "user_seconds": ${USER_SEC_GZIP:-null},
      "sys_seconds": ${SYS_SEC_GZIP:-null},
      "max_rss_kb": ${MAX_RSS_KB_GZIP:-null}
    }
  },
  "hdt_conversion": {
    "input_nq_path": "${BIG_NQ:-}",
    "input_nq_size_bytes": ${NQ_SIZE:-0},
    "output_hdt_path": "${HDT_PATH:-}",
    "output_hdt_size_bytes": ${HDT_SIZE:-0},
    "timing": {
      "wall_seconds": ${WALL_SEC_HDT:-null},
      "user_seconds": ${USER_SEC_HDT:-null},
      "sys_seconds": ${SYS_SEC_HDT:-null},
      "max_rss_kb": ${MAX_RSS_KB_HDT:-null}
    }
  },
  "artifacts": {
    "jar": "$JAR",
    "mapping_file": "$IN",
    "input_mapping_size_bytes": $IN_SIZE,
    "input_tsv_size_bytes": $TSV_SIZE,
    "output_dir": "$OUT",
    "output_dir_size_bytes": $OUT_SIZE,
    "output_triples": $TRIPLES_JSON,
    "combined_nq_path": "${BIG_NQ:-}",
    "combined_nq_size_bytes": ${NQ_SIZE:-0},
    "gzip_path": "${GZ_PATH:-}",
    "gzip_size_bytes": ${GZ_SIZE:-0},
    "hdt_path": "${HDT_PATH:-}",
    "hdt_size_bytes": ${HDT_SIZE:-0}
  },
  "java": {
    "version_header": "$JAVA_VERSION"
  }
}
EOF

  # ---------- Append CSV ----------
  echo "$RUN_ID,$TIMESTAMP,$FULL_TSV,$EXIT_CODE_JAVA,${EXIT_CODE_GZIP:-0},${EXIT_CODE_HDT:-0},$WALL_SEC_JAVA,$USER_SEC_JAVA,$SYS_SEC_JAVA,$MAX_RSS_KB_JAVA,$IN_SIZE,$TSV_SIZE,$OUT_SIZE,$TOTAL_TRIPLES,$JAR,$IN,$OUT,${NQ_SIZE:-0},${GZ_SIZE:-0},${HDT_SIZE:-0}" >> "$METRICS_CSV"

  echo "Done for $FULL_TSV."
  echo "  JSON metrics: $METRICS_JSON"
  echo
done

echo "All experiments finished."
echo "CSV summary: $METRICS_CSV"
