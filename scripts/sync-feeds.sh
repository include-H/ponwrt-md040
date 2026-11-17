#!/bin/sh
set -e
cd "$(dirname "$0")/.."

./scripts/feeds update -a
./scripts/feeds install -a
echo "feeds updated"
