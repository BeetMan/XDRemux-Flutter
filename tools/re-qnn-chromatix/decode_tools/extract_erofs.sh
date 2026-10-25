#!/bin/bash
# Run inside WSL: extract EROFS partition images under rom/
cd "$(dirname "$0")/../rom"
for p in odm vendor product; do
  mkdir -p "$p"
  fsck.erofs --extract="$p" --no-preserve "${p}_a.img" > "$p.log" 2>&1
  echo "$p rc=$?"; tail -2 "$p.log"
done
