#!/bin/bash
set -euo pipefail

# Usage check
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <input_file_or_dir> <output_dir>"
  exit 1
fi

input="$1"
output_dir="$2"

mkdir -p "$output_dir"

# Determine if input is a file or directory
if [ -f "$input" ]; then
  # Single file input
  mapfile -t files < <(echo "$input")
elif [ -d "$input" ]; then
  # Directory input - find all .vcf and .vcf.gz files
  mapfile -t files < <(find "$input" -maxdepth 1 -type f \( -name '*.vcf' -o -name '*.vcf.gz' \) | sort)
else
  echo "Error: '$input' is neither a file nor a directory."
  exit 1
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "No .vcf or .vcf.gz files found."
  exit 0
fi

for infile in "${files[@]}"; do
  base="$(basename "$infile")"
  if [[ "$base" == *.vcf.gz ]]; then
    reader_cmd=(gzip -dc)
    base="${base%.vcf.gz}"
  elif [[ "$base" == *.vcf ]]; then
    reader_cmd=(cat)
    base="${base%.vcf}"
  else
    echo "Skipping unsupported file: $infile"
    continue
  fi

  outfile="${output_dir}/${base}.tsv"
  headers_out="${output_dir}/${base}_headers.tsv"

  # Process: skip metadata, find #CHROM line, strip '#', and output variants
  "${reader_cmd[@]}" "$infile" | awk -v headers_out="$headers_out" '
    BEGIN { FS = OFS = "\t" }
    /^##/ {
      print > headers_out;
      next
    }
    /^#CHROM\t/ {
      sub(/^#/, "", $1);  # remove leading # from first field (#CHROM -> CHROM)
      print;
      next
    }
    /^[^#]/ { print }
  ' > "$outfile"

  echo "✅ Wrote: $outfile"
done
