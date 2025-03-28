#!/bin/sh
set -e

# Default exclude pattern if not set in environment
EXCLUDE_PATTERN=${EXCLUDE_PATTERN:-"./ci/*"}

# Generate checksums for all shell scripts except those matching exclude pattern
find . -type f -name "*.sh" -not -path "$EXCLUDE_PATTERN" | while read file; do
    echo "Creating checksum for $file"
    sha256sum "$file" | awk '{print $1}' > "$file.sha256"
done

echo "All checksums generated successfully"
