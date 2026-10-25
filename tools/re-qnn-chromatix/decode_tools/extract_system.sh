#!/bin/bash
cd "$(dirname "$0")/../rom"
mkdir -p system
fsck.erofs --extract=system --no-preserve system_a.img > system.log 2>&1
echo "system rc=$?"
rm -f system_a.img system.log
