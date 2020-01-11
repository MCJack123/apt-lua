#!/bin/bash
# This file makes sure the control and data archives in a deb file are compressed with gzip ONLY.
# Usage: convert_package.sh <file.deb>
# Requirements: ar, gzip, bzip2, xz
set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <package.deb>"
    exit 2
fi

FILE="$(cd $(dirname "$1"); pwd)/$(basename "$1")"
pushd "$PWD" > /dev/null
TEMP="$(mktemp -d 2>/dev/null || mktemp -d -t 'tmp')"
cd "$TEMP"
ar x "$FILE"

if [ -e "control.tar.gz" ]; then 
    echo "control is OK"
elif [ -e "control.tar.bz2" ]; then
    echo "converting control from bz2"
    bzip2 -d control.tar.bz2
    gzip control.tar
elif [ -e "control.tar.xz" ]; then
    echo "converting control from xz"
    xz -d control.tar.xz
    gzip control.tar
else 
    echo "could not find control file!"
    popd > /dev/null
    rm -r "$TEMP"
    echo "$FILE: failed"
    exit 1
fi

if [ -e "data.tar.gz" ]; then 
    echo "data is OK"
elif [ -e "data.tar.bz2" ]; then
    echo "converting data from bz2"
    bzip2 -d data.tar.bz2
    gzip data.tar
elif [ -e "data.tar.xz" ]; then
    echo "converting data from xz"
    xz -d data.tar.xz
    gzip data.tar
else 
    echo "could not find data file!"
    popd > /dev/null
    rm -r "$TEMP"
    echo "$FILE: failed"
    exit 1
fi

rm "$FILE"
ar r "$FILE" debian-binary control.tar.gz data.tar.gz > /dev/null 2>/dev/null
popd > /dev/null
rm -r "$TEMP"
echo "$FILE: OK"
exit 0