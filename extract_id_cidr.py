#!/usr/bin/env python3
import csv

BLOCKS_FILE = "/etc/ipset/GeoLite2-Country-Blocks-IPv4.csv"
LOCATIONS_FILE = "/etc/ipset/GeoLite2-Country-Locations-en.csv"
OUTPUT = "/etc/ipset/id.cidr"

# Find geoname_id for Indonesia
id_geonames = set()
with open(LOCATIONS_FILE, newline='') as loc_file:
    reader = csv.DictReader(loc_file)
    for row in reader:
        if row.get("country_iso_code") == "ID":
            id_geonames.add(row["geoname_id"])

# Extract CIDR blocks for Indonesia
with open(BLOCKS_FILE, newline='') as blocks_file, open(OUTPUT, "w") as out_file:
    reader = csv.DictReader(blocks_file)
    for row in reader:
        if row.get("geoname_id") in id_geonames:
            out_file.write(row["network"] + "\n")
