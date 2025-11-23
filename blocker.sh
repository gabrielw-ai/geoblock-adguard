#!/usr/bin/env bash
# ========================================================
# GeoIP Firewall Manager (Auto Setup)
# Improved Version
# ========================================================

set -e

# === Detect Distro ===
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO=$ID
  PKG_MGR=$(command -v dnf || command -v yum || command -v apt || echo "unknown")
else
  echo "Unsupported distro. Exiting."
  exit 1
fi

echo "Detected distro: $DISTRO"

# === Ensure root ===
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# === Install dependencies ===
echo "[+] Installing required packages..."
$PKG_MGR install -y ipset unzip python3 jq net-tools curl

# Debian needs iptables-persistent for saving rules
if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
  $PKG_MGR install -y iptables-persistent
fi

# === Setup repo directory ===
REPO_DIR="$(pwd)"
ZIP_FILE="$REPO_DIR/GeoLite2-Country-CSV.zip"

if [ ! -f "$ZIP_FILE" ]; then
  echo "[!] Missing GeoLite2-Country-CSV.zip in repo folder!"
  echo "    Make sure you downloaded the complete geoblock-adguard package."
  exit 1
fi

# === Setup paths ===
MMDB_DIR="/etc/ipset"
CIDR_FILE="$MMDB_DIR/id.cidr"
PY_SCRIPT="$REPO_DIR/extract_id_cidr.py"

mkdir -p "$MMDB_DIR"

# === Extract only once ===
if [ ! -f "$CIDR_FILE" ]; then
  echo "[+] Extracting GeoLite2-Country-CSV.zip..."
  unzip -o "$ZIP_FILE" -d "$MMDB_DIR"

  # Find extracted folder
  CSV_FOLDER=$(find "$MMDB_DIR" -maxdepth 1 -type d -name "GeoLite2-Country-CSV_*" | head -n 1)
  if [ -z "$CSV_FOLDER" ]; then
    echo "[!] Unable to find extracted GeoLite2-Country-CSV folder."
    exit 1
  fi

  echo "[+] Found CSV folder: $CSV_FOLDER"

  # Move only the needed files
  mv "$CSV_FOLDER/GeoLite2-Country-Blocks-IPv4.csv" "$MMDB_DIR"
  mv "$CSV_FOLDER/GeoLite2-Country-Locations-en.csv" "$MMDB_DIR"

  echo "[+] Parsing Indonesia CIDR..."
  python3 "$PY_SCRIPT"
else
  echo "[=] CIDR already exists. Skipping extraction."
fi

# === Get public IP ===
MYIP=$(curl -s https://ipinfo.io/ip)
echo "[+] Server public IP: $MYIP"

# === Create IPSET ===
create_ipset() {
  if ! ipset list indonesia &>/dev/null; then
    echo "[+] Creating IP set for Indonesia..."
    ipset create indonesia hash:net
    for i in $(cat "$CIDR_FILE"); do ipset add indonesia "$i"; done
  else
    echo "[=] IP set 'indonesia' already exists."
  fi

  if ! ipset test indonesia "$MYIP" &>/dev/null; then
    echo "[!] Public IP $MYIP not in Indonesia list — adding..."
    ipset add indonesia "$MYIP"
  fi
}

# === Save iptables (FIXED permanent save) ===
save_iptables() {
  echo "[+] Saving iptables..."

  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save

  elif [[ -d /etc/iptables ]]; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6

  elif [[ -f /etc/sysconfig ]]; then
    iptables-save > /etc/sysconfig/iptables

  else
    echo "[!] Could not find standard save location!"
  fi

  echo "[✓] iptables saved."
}

# === Add blocking rule ===
block_port() {
  local PORT=$1
  local PROTO=$2
  echo "[+] Blocking non-ID access for $PORT/$PROTO..."
  iptables -I INPUT -p $PROTO --dport $PORT -m set ! --match-set indonesia src ! -i wg0 -j DROP
  save_iptables
}

# === Remove rules ===
remove_rules() {
  echo "[+] Removing all GeoIP rules..."
  iptables -L INPUT -n --line-numbers | grep match-set | awk '{print $1}' | sort -r | while read num; do
    iptables -D INPUT "$num"
  done
  save_iptables
  echo "[✓] Removed."
}

# === Check rules ===
check_rules() {
  echo "[+] Current rules:"
  iptables -L INPUT -n --line-numbers | grep match-set || echo "No rules."
}

# === Menu ===
create_ipset

while true; do
  clear
  echo "=============================="
  echo " GEOIP FIREWALL MANAGER "
  echo "=============================="
  echo "1) Block non-ID port 53"
  echo "2) Block non-ID port 853"
  echo "3) Block both 53 & 853"
  echo "4) Block custom port"
  echo "5) Check rules"
  echo "6) Remove all rules"
  echo "7) Exit"
  echo "=============================="
  read -p "Choose [1-7]: " choice

  case $choice in
    1)
      block_port 53 tcp
      block_port 53 udp
      ;;
    2)
      block_port 853 tcp
      ;;
    3)
      block_port 53 tcp
      block_port 53 udp
      block_port 853 tcp
      ;;
    4)
      read -p "Port: " port
      read -p "Protocol (tcp/udp): " proto
      block_port $port $proto
      ;;
    5)
      check_rules
      read -p "Press Enter..."
      ;;
    6)
      remove_rules
      ;;
    7)
      exit 0
      ;;
    *)
      echo "Invalid choice."
      sleep 1
      ;;
  esac
done
