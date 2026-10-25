#!/bin/bash
cd "$(dirname "$0")/.."
awk '{print $3}' re/styletrans/prepare_syms_raw.txt | llvm-cxxfilt > /tmp/dm.txt
paste -d' ' <(awk '{print $1, $2}' re/styletrans/prepare_syms_raw.txt) /tmp/dm.txt > re/styletrans/prepare_syms.txt
wc -l re/styletrans/prepare_syms.txt
