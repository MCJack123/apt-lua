#!/bin/sh
# This file makes sure the control and data archives in a deb file are compressed with gzip ONLY.
# Usage: convert_package.sh <file.deb>
# Requirements: ar, gzip, bzip2, xz

FILE="$(readlink -f "$1")"
pushd "$PWD"
TEMP="$(mktemp)"
cd "$TEMP"
ar x "$FILE"

if [ -e "control.tar.gz" ]; then 
    echo "control is OK"
elif [ -e "control.tar.bz2" ]; then
    echo "converting control to gz"
    bzip2 -d control.tar.bz2
    gzip control.tar
elif [ -e "control.tar.xz" ]; then
    echo "converting control to gz"
    bzip2 -d control.tar.xz
    gzip control.tar
else 
    echo "could not find control file!"
    popd
    rm -r "$TEMP"
    exit 1
fi

if [ -e "data.tar.gz" ]; then 
    echo "data is OK"
elif [ -e "data.tar.bz2" ]; then
    echo "converting data to gz"
    bzip2 -d data.tar.bz2
    gzip data.tar
elif [ -e "data.tar.xz" ]; then
    echo "converting data to gz"
    bzip2 -d data.tar.xz
    gzip data.tar
else 
    echo "could not find data file!"
    popd
    rm -r "$TEMP"
    exit 1
fi

rm "$FILE"
ar r "$FILE" debian-binary control.tar.gz data.tar.gz
popd
rm -r "$TEMP"
exit 0