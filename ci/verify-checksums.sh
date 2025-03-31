#!/bin/sh
set -e

# Default exclude pattern if not set in environment
EXCLUDE_PATTERN=${EXCLUDE_PATTERN:-"./ci/*"}

# Verify checksums for all shell scripts except those matching exclude pattern
errors=0
for file in $(find . -type f -name "*.sh" -not -path "$EXCLUDE_PATTERN"); do
    cs_file="$file.sha256"
    if [ ! -f "$cs_file" ]; then
        echo "[ERR] $file - checksum file missing"
        errors=$((errors+1))
    else
        computed=$(sha256sum "$file" | awk '{print $1}')
        expected=$(awk '{print $1}' "$cs_file")
        if [ "$computed" = "$expected" ]; then
            echo "[OK] $file"
        else
            echo "[ERR] $file - checksum mismatch"
            errors=$((errors+1))
        fi
    fi
done

if [ $errors -ne 0 ]; then
    echo "Checksum verification failed with $errors errors"
    exit 1
fi

echo "All checksums verified successfully"
