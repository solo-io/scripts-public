# Default exclude pattern
EXCLUDE ?= "./ci/*"

.PHONY: checksums
checksums:
	EXCLUDE_PATTERN="$(EXCLUDE)" ./ci/generate-checksums.sh

.PHONY: verify-checksums
verify-checksums:
	EXCLUDE_PATTERN="$(EXCLUDE)" ./ci/verify-checksums.sh
