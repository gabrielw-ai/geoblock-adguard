#!/usr/bin/env bash
# ========================================================
# GeoIP Firewall Manager (MaxMind CSV Manual)
# Author: Gabriel + Copilot
# Description: Block non-Indonesian IPs on specific ports
# ========================================================

set -e

# === Detect Distro ===
if [ -f /etc/redhat-release ]; then
  DISTRO="rhel"
  PKG_MGR="yum"
elif [ -f /etc/debian_version ]; then
  DISTRO="debian"
  PKG_MGR="apt"
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
$PKG_MGR install -y ipset unzip python3 jq net-tools

# === Prepare CSV ===
MMDB_DIR="/etc/ipset"
CIDR_FILE="$MMDB_DIR/id.cidr"
PY_SCRIPT="/root/extract_id_cidr.py"
ZIP_FILE="/root/geolite/geolite.zip"

mkdir -p "$MMDB_DIR"

if [ ! -f "$ZIP_FILE" ]; then
  echo "[!] GeoLite2-Country CSV ZIP not found at $ZIP_FILE. Please download it manually."
  exit 1
fi

echo "[+] Extracting CSV from ZIP..."
unzip -o "$ZIP_FILE" -d "$MMDB_DIR"
mv "$MMDB_DIR"/GeoLite2-Country-CSV_*/GeoLite2-Country-Blocks-IPv4.csv "$MMDB_DIR"/
mv "$MMDB_DIR"/GeoLite2-Country-CSV_*/GeoLite2-Country-Locations-en.csv "$MMDB_DIR"/

# === Validate CSV files ===
if [ ! -f "$MMDB_DIR/GeoLite2-Country-Blocks-IPv4.csv" ] || [ ! -f "$MMDB_DIR/GeoLite2-Country-Locations-en.csv" ]; then
  echo "[!] Required CSV files not found in $MMDB_DIR. Aborting."
  exit 1
fi

# === Extract CIDR for Indonesia ===
echo "[+] Parsing Indonesia CIDR from CSV..."
python3 "$PY_SCRIPT"

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
    echo "[!] Public IP $MYIP not in Indonesia set. Adding manually..."
    ipset add indonesia "$MYIP"
  fi
}

# === Save iptables ===
save_iptables() {
  echo "[+] Saving iptables rules..."
  if [ "$DISTRO" = "rhel" ]; then
    service iptables save
  else
    netfilter-persistent save
  fi
}

# === Block port with WireGuard exception ===
block_port() {
  local PORT=$1
  local PROTO=$2
  echo "[+] Blocking non-ID for port $PORT/$PROTO ..."
  iptables -I INPUT -p $PROTO --dport $PORT -m set ! --match-set indonesia src ! -i wg0 -j DROP
  save_iptables
  echo "[✓] Rule added and saved (WireGuard exempted)."
}

# === Remove rules ===
remove_rules() {
  echo "[+] Removing GeoIP blocking rules..."
  for port in 53 853; do
    for proto in tcp udp; do
      iptables -D INPUT -p $proto --dport $port -m set ! --match-set indonesia src ! -i wg0 -j DROP 2>/dev/null || true
    done
  done
  save_iptables
  echo "[✓] All GeoIP rules removed."
}

# === Check rules ===
check_rules() {
  echo "[+] Checking current GeoIP blocking rules..."
  iptables -L INPUT -n --line-numbers | grep match-set || echo "No GeoIP rules found."
}

# === Main Menu ===
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
  echo "5) Check blocking rules"
  echo "6) Remove all blocking"
  echo "7) Exit"
  echo "=============================="
  read -p "Select option [1-7]: " choice

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
      read -p "Enter port number: " port
      read -p "Protocol (tcp/udp): " proto
      block_port $port $proto
      ;;
    5)
      check_rules
      read -p "Press Enter to continue..."
      ;;
    6)
      remove_rules
      ;;
    7)
      echo "Exiting..."
      exit 0
      ;;
    *)
      echo "Invalid choice!"
      sleep 1
      ;;
  esac
done
