#!/usr/bin/env python3
import csv
import os
import glob
import sys

# --- Pengaturan Lokasi File Dinamis ---

# 1. Tentukan BASE_DIR (Direktori tempat script Bash menjalankan Python, misal: /root/geoblock-adguard/)
# __file__ akan mengarah ke /root/geoblock-adguard/extract_id_cidr.py
BASE_DIR = os.path.dirname(os.path.abspath(__file__)) 

# 2. Path File Output Final
OUTPUT = "/etc/ipset/id.cidr" 

# 3. Cari folder data yang namanya diawali dengan 'GeoLite2-Country-CSV_' di dalam sub-folder 'geo'
print("Mencari folder data GeoLite...")
try:
    # Perubahan penting: Kita mencari folder hasil ekstrak di BASE_DIR/geo/
    # Folder hasil ekstrak berada di 'geo/GeoLite2-Country-CSV_YYYYMMDD'
    search_path = os.path.join(BASE_DIR, "geo", "GeoLite2-Country-CSV_*")
    
    # Gunakan glob untuk mencari folder yang cocok dengan pola
    data_folder_matches = glob.glob(search_path)
    
    if not data_folder_matches:
        print("Error: Tidak ditemukan folder GeoLite di dalam sub-folder 'geo'.")
        print(f"Periksa apakah folder ada di: {os.path.join(BASE_DIR, 'geo')}")
        sys.exit(1)

    # Ambil path folder yang pertama ditemukan (ini adalah /root/geoblock-adguard/geo/GeoLite2-Country-CSV_YYYYMMDD)
    data_folder_path = data_folder_matches[0]
    # Lakukan sanitasi path untuk menghilangkan trailing slash
    data_folder_path = data_folder_path.rstrip(os.sep) 
    print(f"Menggunakan folder data: {data_folder_path}")

except Exception as e:
    print(f"Terjadi error saat mencari folder: {e}")
    sys.exit(1)

# 4. Tentukan Path File CSV di dalam folder data
BLOCKS_FILE = os.path.join(data_folder_path, "GeoLite2-Country-Blocks-IPv4.csv")
LOCATIONS_FILE = os.path.join(data_folder_path, "GeoLite2-Country-Locations-es.csv") 

# --- Logika Ekstraksi ---

# Find geoname_id for Indonesia ("ID")
id_geonames = set()
print("Memproses file Lokasi...")
try:
    with open(LOCATIONS_FILE, newline='', encoding='utf-8') as loc_file:
        reader = csv.DictReader(loc_file)
        for row in reader:
            if row.get("country_iso_code") == "ID":
                id_geonames.add(row["geoname_id"])
    
    if not id_geonames:
        print("Peringatan: Tidak ditemukan GeoName ID untuk 'ID' (Indonesia).")

except FileNotFoundError:
    print(f"Error: File Lokasi tidak ditemukan di {LOCATIONS_FILE}")
    sys.exit(1)
except Exception as e:
    print(f"Error saat membaca file Lokasi: {e}")
    sys.exit(1)

# Extract CIDR blocks
print(f"Mengekstrak blok CIDR untuk {len(id_geonames)} GeoName IDs ke {OUTPUT}...")
try:
    with open(BLOCKS_FILE, newline='', encoding='utf-8') as blocks_file, open(OUTPUT, "w") as out_file:
        reader = csv.DictReader(blocks_file)
        count = 0
        for row in reader:
            if row.get("geoname_id") in id_geonames:
                out_file.write(row["network"] + "\n")
                count += 1
    
    print(f"✅ Ekstraksi selesai. Total {count} blok CIDR berhasil ditulis ke {OUTPUT}")

except FileNotFoundError:
    print(f"Error: File Blocks tidak ditemukan di {BLOCKS_FILE}")
    sys.exit(1)
except PermissionError:
    print(f"Error: Tidak ada izin untuk menulis ke {OUTPUT}. Anda harus menjalankan script ini dengan 'sudo'.")
    sys.exit(1)
except Exception as e:
    print(f"Error saat mengekstrak blok CIDR: {e}")
    sys.exit(1)
