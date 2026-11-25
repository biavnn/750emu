#!/usr/bin/env python3
"""Convert a flat binary (loaded at address 0) to a one-byte-per-line $readmemh file."""
import sys

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
with open(dst, "w") as f:
    f.write("\n".join(f"{b:02x}" for b in data))
    f.write("\n")
