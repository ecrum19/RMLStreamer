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

# Determine decompression method
if [[ "$infile" == *.gz ]]; then
  reader="zcat"
  base="$(basename "$infile" .vcf.gz)"
else
  reader="cat"
  base="$(basename "$infile" .vcf)"
fi

outfile="${base}.tsv"

# Process: skip metadata, find #CHROM line, strip '#', and output first 100 variants
$reader "$infile" | awk '
  BEGIN { started=0; n=0 }
  /^#CHROM(\t| )/ { sub(/^#/, ""); print; started=1; next }   # remove leading # on header
  /^[^#]/ { print }                                # print all variant rows
' > "$outfile"

# started && $0 !~ /^#/ { print; n++; if (n>=100) exit }      # print first 100 variant rows

echo "✅ Wrote: $outfile"
