#!/usr/bin/env bash
# ========================================================
# GeoIP Country Blocker (Indonesia Only) - Simple Version
# Author: Gabriel + ChatGPT
# Debian + RHEL compatible
# ========================================================

set -euo pipefail

# Colors
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
NC="\e[0m"

# Detect distro
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
else
    echo -e "${RED}Cannot detect OS!${NC}"
    exit 1
fi

echo -e "${GREEN}Detected distro: $DISTRO${NC}"

# Ensure root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root.${NC}"
    exit 1
fi

# Select package manager
if command -v dnf >/dev/null 2>&1; then
    PKG=dnf
elif command -v yum >/dev/null 2>&1; then
    PKG=yum
elif command -v apt >/dev/null 2>&1; then
    PKG=apt
else
    echo -e "${RED}No supported package manager found.${NC}"
    exit 1
fi

# Install deps
echo -e "${YELLOW}[+] Installing dependencies...${NC}"
if [[ "$PKG" == "apt" ]]; then
    apt update -y
    apt install -y ipset unzip python3 jq curl iptables-persistent
else
    $PKG install -y ipset unzip python3 jq curl
fi

# Main directory (where script runs)
BASE_DIR="$(pwd)"

# Detect GeoLite2 ZIP
ZIP_FILE=$(ls "$BASE_DIR"/GeoLite2-Country-CSV_*.zip 2>/dev/null | head -n 1 || true)

if [ -z "$ZIP_FILE" ]; then
    echo -e "${RED}[!] GeoLite2-Country-CSV_*.zip not found in $BASE_DIR${NC}"
    exit 1
fi

echo -e "${GREEN}[+] Found ZIP: $ZIP_FILE${NC}"

# Extract files
echo -e "${YELLOW}[+] Extracting...${NC}"

mkdir -p "$BASE_DIR/geo"
unzip -o "$ZIP_FILE" -d "$BASE_DIR/geo"

CSV_DIR=$(find "$BASE_DIR/geo" -maxdepth 1 -type d -name "GeoLite2-Country-CSV_*" | head -n 1)

if [ -z "$CSV_DIR" ]; then
    echo -e "${RED}[!] Extraction failed.${NC}"
    exit 1
fi

echo -e "${GREEN}[+] CSV DIR: $CSV_DIR${NC}"

# Run python extractor
CIDR_DIR="/etc/ipset"
CIDR_FILE="$CIDR_DIR/id.cidr"
mkdir -p "$CIDR_DIR"

echo -e "${YELLOW}[+] Generating CIDR for Indonesia...${NC}"
python3 "$BASE_DIR/extract_id_cidr.py"

if [ ! -f "$CIDR_FILE" ]; then
    echo -e "${RED}[!] Failed to generate CIDR file!${NC}"
    exit 1
fi

echo -e "${GREEN}[✓] CIDR saved to $CIDR_FILE${NC}"

# Prepare ipset
setup_ipset() {
    echo -e "${YELLOW}[+] Preparing ipset 'indonesia'...${NC}"

    if ipset list indonesia >/dev/null 2>&1; then
        echo "[=] ipset exists → flushing..."
        ipset flush indonesia
    else
        echo "[+] Creating new ipset..."
        ipset create indonesia hash:net maxelem 1000000
    fi

    echo "[+] Loading CIDR..."
    while read -r cidr; do
        ipset add indonesia "$cidr"
    done < "$CIDR_FILE"

    echo -e "${GREEN}[✓] ipset 'indonesia' ready.${NC}"
}

# Save iptables permanent
save_iptables() {
    echo -e "${YELLOW}[+] Saving iptables...${NC}"

    if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6
        systemctl restart netfilter-persistent || true

    elif [[ "$DISTRO" == "almalinux" || "$DISTRO" == "rocky" || "$DISTRO" == "centos" || "$DISTRO" == "rhel" ]]; then
        iptables-save > /etc/sysconfig/iptables
        systemctl restart iptables || true
    fi

    echo -e "${GREEN}[✓] iptables persisted.${NC}"
}

# Blocking function
block_port() {
    PORT="$1"
    PROTO="$2"

    echo -e "${YELLOW}[+] Blocking non-ID for port $PORT/$PROTO ...${NC}"

    iptables -I INPUT -p "$PROTO" --dport "$PORT" -m set ! --match-set indonesia src -j DROP

    save_iptables

    echo -e "${GREEN}[✓] Blocking applied.${NC}"
}

# Remove rules
remove_rules() {
    echo -e "${YELLOW}[+] Removing all GeoIP rules...${NC}"

    iptables -L INPUT -n --line-numbers \
        | grep match-set \
        | awk '{print $1}' \
        | sort -rn \
        | while read -r num; do
            iptables -D INPUT "$num"
        done

    save_iptables

    echo -e "${GREEN}[✓] All GeoIP rules removed.${NC}"
}

# Check rules
check_rules() {
    echo -e "${YELLOW}===== IPTABLES RULES =====${NC}"
    iptables -L INPUT -n --line-numbers | grep -E "match-set|DROP" || echo "No blocking rules."
    echo ""
    read -p "Press Enter..."
}

# Initialize ipset on startup
setup_ipset

# Menu loop
while true; do
    clear
    echo -e "${GREEN}=============================="
    echo " GEO BLOCKER - INDONESIA ONLY "
    echo "==============================${NC}"
    echo "1. Block non-ID port 53"
    echo "2. Block non-ID port 853"
    echo "3. Block both (53 + 853)"
    echo "4. Block custom port"
    echo "5. Check blocking"
    echo "6. Remove blocking"
    echo "7. Exit"
    echo ""

    read -p "Choose: " opt

    case "$opt" in
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
            read -p "Port: " p
            read -p "Protocol (tcp/udp): " pr
            block_port "$p" "$pr"
            ;;
        5)
            check_rules
            ;;
        6)
            remove_rules
            ;;
        7)
            echo -e "${GREEN}Bye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option!${NC}"
            sleep 1
            ;;
    esac
done
