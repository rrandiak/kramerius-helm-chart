#!/bin/sh
set -e

YEAR=$(date +%Y)
MONTH=$(date +%m)

download_mmdb() {
  URL=$(printf "$2" "$YEAR" "$MONTH")
  echo "Downloading $3 from $URL ..."
  wget -q -O "$1.gz" "$URL" && gunzip -f "$1.gz" && echo "$3 installed." || { echo "$3 download failed."; rm -f "$1.gz"; exit 1; }
}

download_mmdb /var/lib/vector/geoip.mmdb \
  "https://download.db-ip.com/free/dbip-city-lite-%s-%s.mmdb.gz" \
  "GeoIP city database"

download_mmdb /var/lib/vector/asn.mmdb \
  "https://download.db-ip.com/free/dbip-asn-lite-%s-%s.mmdb.gz" \
  "GeoIP ASN database"
