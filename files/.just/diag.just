# `os diag::*` — system diagnostics.

# Run a 1-minute CPU benchmark.
benchmark:
    @echo "🚀 Running a 1 minute system benchmark..."
    stress-ng --matrix 0 -t 1m --times

# Show BIOS / motherboard info.
bios-info:
    @echo "🖥️  Hardware Information:"
    @sudo bash -c 'echo "Manufacturer: $(dmidecode -s baseboard-manufacturer)"; echo "Product Name: $(dmidecode -s baseboard-product-name)"; echo "Version: $(dmidecode -s bios-version)"; echo "Release Date: $(dmidecode -s bios-release-date)"'
