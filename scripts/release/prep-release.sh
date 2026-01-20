#!/usr/bin/env bash

# 1. Build reproducible images 
# echo "Building reproducible images..."
# make build-reproducible

# 2. Create tar.gz files of binaries
echo "Creating tar.gz files of binaries..."
tar -czvf build/terpd-linux-amd64.tar.gz build/terpd-linux-amd64
tar -czvf build/terpd-linux-arm64.tar.gz build/terpd-linux-arm64

# 3. Calculate sha256sum for all images into checksum.txt in ./build
echo "Calculating sha256sum for all images..."

sha256sum build/terpd-linux-amd64 > build/checksum.txt
sha256sum build/terpd-linux-arm64 >> build/checksum.txt
sha256sum build/terpd-linux-amd64.tar.gz >> build/checksum.txt
sha256sum build/terpd-linux-arm64.tar.gz >> build/checksum.txt 

echo "SHA256 checksums have been saved to build/checksum.txt."