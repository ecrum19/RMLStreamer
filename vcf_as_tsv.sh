#!/bin/bash
set -euo pipefail

# Usage check
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <input.vcf|input.vcf.gz>"
  exit 1
fi

infile="$1"
if [ ! -f "$infile" ]; then
  echo "Error: '$infile' not found."
  exit 1
fi

# Determine decompression method and base name
if [[ "$infile" == *.vcf.gz ]]; then
  reader_cmd=(gzip -dc)
  base="$(basename "$infile" .vcf.gz)"
elif [[ "$infile" == *.vcf ]]; then
  reader_cmd=(cat)
  base="$(basename "$infile" .vcf)"
else
  echo "Error: input must end in .vcf or .vcf.gz"
  exit 1
fi

outfile="${base}.tsv"

# Process: skip metadata, find #CHROM line, strip '#', and output first 100 variants
"${reader_cmd[@]}" "$infile" | awk '
  BEGIN { n=0 }
  /^#CHROM(\t| )/ {
    sub(/^#/, "", $1);  # remove leading # from first field
    print;
    next
  }
  /^[^#]/ { print }                                # print all variant rows
' > "$outfile"

# started && $0 !~ /^#/ { print; n++; if (n>=100) exit }      # print first 100 variant rows

echo "✅ Wrote: $outfile"
