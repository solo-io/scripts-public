.PHONY: checksums
checksums:
	@find . -type f \( -name "*.sh" -o -name "*.bash" \) | while read file; do \
		echo "Creating checksum for $$file"; \
		sha256sum "$$file" | awk '{print $$1}' > "$$file.sha256"; \
	done

.PHONY: verify-checksums
verify-checksums:
	@errors=0; \
	for file in $$(find . -type f \( -name "*.sh" -o -name "*.bash" \)); do \
		cs_file="$$file.sha256"; \
		if [ ! -f "$$cs_file" ]; then \
			echo "[ERR] $$file - checksum file missing"; \
			errors=$$((errors+1)); \
		else \
			computed=$$(sha256sum "$$file" | awk '{print $$1}'); \
			expected=$$(awk '{print $$1}' "$$cs_file"); \
			if [ "$$computed" = "$$expected" ]; then \
				echo "[OK] $$file"; \
			else \
				echo "[ERR] $$file - checksum mismatch"; \
				errors=$$((errors+1)); \
			fi; \
		fi; \
	done; \
	if [ $$errors -ne 0 ]; then \
		echo "Checksum verification failed with $$errors errors"; \
		exit 1; \
	fi; \
	echo "All checksums verified successfully"
