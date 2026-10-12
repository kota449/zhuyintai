#!/bin/bash
# 產生腳本必須把 XcodeGen 版號寫死，而且不准在腳本裡安裝套件。
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -f generate_xcodeproj.sh ]]; then
  echo "missing generate_xcodeproj.sh" >&2
  exit 1
fi
grep -q '2.45.4' generate_xcodeproj.sh
if grep -q 'brew install' generate_xcodeproj.sh; then
  echo "script must not install packages" >&2
  exit 1
fi
echo "ok"
