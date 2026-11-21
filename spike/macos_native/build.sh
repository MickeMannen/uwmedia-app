#!/bin/bash
# Builds build/uwbench: the Apple runners' media engine
# (apple/MediaEngine.swift), as its source stands, compiled as a
# command-line tool with the stand-ins of shims.swift for the Flutter
# types.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 -o build/uwbench ../../apple/MediaEngine.swift shims.swift main.swift
echo "built build/uwbench"
