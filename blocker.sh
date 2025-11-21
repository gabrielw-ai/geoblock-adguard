#!/usr/bin/env bash
# ========================================================
# GeoIP Firewall Manager (Auto Setup)
# Author: Gabriel + Copilot
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
$PKG_MGR install -y ipset unzip python3 jq net-tools curl git

# === Setup geo-block repo ===
REPO_DIR="/root/geo-block"
if [ ! -d "$REPO_DIR" ]; then
  echo "[+] Cloning geo-block repo..."
  git clone https://github.com/gabrielw-ai/geo-block "$REPO_DIR"
else
  echo "[=] geo-block repo already exists."
fi

# === Locate ZIP file ===
ZIP_FILE="$REPO_DIR/geolite.zip"
if [ ! -f "$ZIP_FILE" ]; then
  echo "[!] File geolite.zip not found in $REPO_DIR. Please download it manually."
  exit 1
fi

# === Setup paths ===
MMDB_DIR="/etc/ipset"
CIDR_FILE="$MMDB_DIR/id.cidr"
PY_SCRIPT="$REPO_DIR/extract_id_cidr.py"

mkdir -p "$MMDB_DIR"

# === Extract CSV only if CIDR not yet parsed ===
if [ ! -f "$CIDR_FILE" ]; then
  echo "[+] Extracting CSV from ZIP..."
  unzip -o "$ZIP_FILE" -d "$MMDB_DIR"
  mv "$MMDB_DIR"/GeoLite2-Country-CSV_*/GeoLite2-Country-Blocks-IPv4.csv "$MMDB_DIR"/
  mv "$MMDB_DIR"/GeoLite2-Country-CSV_*/GeoLite2-Country-Locations-en.csv "$MMDB_DIR"/

  # === Validate CSV files ===
  if [ ! -f "$MMDB_DIR/GeoLite2-Country-Blocks-IPv4.csv" ] || [ ! -f "$MMDB_DIR/GeoLite2-Country-Locations-en.csv" ]; then
    echo "[!] Required CSV files not found in $MMDB_DIR. Aborting."
    exit 1
  fi

  echo "[+] Parsing Indonesia CIDR from CSV..."
  python3 "$PY_SCRIPT"
else
  echo "[=] CIDR file already exists. Skipping extraction and parsing."
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
    echo "[!] Public IP $MYIP not in Indonesia set. Adding manually..."
    ipset add indonesia "$MYIP"
  fi
}

# === Save iptables ===
save_iptables() {
  echo "[+] Saving iptables rules..."
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
  elif command -v iptables-save &>/dev/null; then
    if [ -f /etc/sysconfig/iptables ]; then
      # RHEL/Fedora
      iptables-save > /etc/sysconfig/iptables
      systemctl restart iptables || echo "[!] iptables service not managed by systemctl"
    elif [ -d /etc/iptables ]; then
      # Ubuntu/Debian
      iptables-save > /etc/iptables/rules.v4
      ip6tables-save > /etc/iptables/rules.v6
      systemctl restart netfilter-persistent || echo "[!] netfilter-persistent not managed by systemctl"
    else
      echo "[!] Could not determine where to save iptables rules."
    fi
  else
    echo "[!] Could not determine how to save iptables rules."
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
  echo "[+] Removing all GeoIP rules from INPUT chain..."
  iptables -L INPUT -n --line-numbers | grep match-set | awk '{print $1}' | sort -r | while read num; do
    iptables -D INPUT "$num"
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
