checksums:
	@find . -type f \( -name "*.sh" -o -name "*.bash" \) | while read file; do \
		echo "Creating checksum for $$file"; \
		sha256sum "$$file" | awk '{print $$1}' > "$$file.sha256"; \
	done

verify-checksums:
	@find . -type f \( -name "*.sh" -o -name "*.bash" \) | while read file; do \
		cs_file="$$file.sha256"; \
		if [ ! -f "$$cs_file" ]; then \
			echo "[ERR] $$file - checksum file missing"; \
		else \
			computed=`sha256sum "$$file" | awk '{print $$1}'`; \
			expected=`awk '{print $$1}' "$$cs_file"`; \
			if [ "$$computed" = "$$expected" ]; then \
				echo "[OK] $$file"; \
			else \
				echo "[ERR] $$file - checksum mismatch"; \
			fi; \
		fi; \
	done
