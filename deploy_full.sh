#!/bin/sh
# Complete Router Monitoring Setup - No crontab dependencies

PHONE_IP='192.168.1.13'
PORT='8081'

send_log() {
    level="$1"
    message="$2"
    (
        printf 'POST /log-message HTTP/1.1\r\n'
        printf 'Host: %s:%s\r\n' "$PHONE_IP" "$PORT"
        printf 'X-Log-Level: %s\r\n' "$level"
        printf 'Content-Length: %s\r\n' "$(printf "%s" "$message" | wc -c)"
        printf 'Content-Type: text/plain\r\n'
        printf 'Connection: close\r\n\r\n'
        printf "%s" "$message"
    ) | nc -w 3 "$PHONE_IP" "$PORT" >/dev/null 2>&1
}

# === IP TRAFFIC MONITOR SETUP ===
setup_ip_traffic_monitor() {
    send_log "INFO" "Setting up IP Traffic Monitor..."
    
    BASE_DIR="/tmp/ip_traffic"
    mkdir -p "$BASE_DIR"
    
    # Create the main iptables chains (ONLY ONCE during deployment)
    iptables -L TRAFFIC_TEST >/dev/null 2>&1 || iptables -N TRAFFIC_TEST
    iptables -C INPUT -j TRAFFIC_TEST >/dev/null 2>&1 || iptables -I INPUT -j TRAFFIC_TEST
    iptables -C FORWARD -j TRAFFIC_TEST >/dev/null 2>&1 || iptables -I FORWARD -j TRAFFIC_TEST
    
    send_log "INFO" "IPTables chains created and hooked"
    
    # Create the IP traffic script (rules update happens here)
    cat > "$BASE_DIR/ip_traffic_auto.sh" <<'IPEOF'
#!/bin/sh
BASE_DIR="/tmp/ip_traffic_test"
OUTFILE="$BASE_DIR/traffic_snapshot_$(date +%Y%m%d_%H%M%S).txt"
PID_FILE="$BASE_DIR/monitor.pid"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

update_rules() {
    log "Refreshing device list..."
    DEVICES=""
    [ -f "/proc/net/arp" ] && DEVICES="$DEVICES $(awk 'NR>1&&$3=="0x2"{print $1}' /proc/net/arp)"
    [ -f "/tmp/dhcp.leases" ] && DEVICES="$DEVICES $(awk '{print $3}' /tmp/dhcp.leases)"
    DEVICES=$(echo "$DEVICES" | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')
    
    # Flush and recreate device rules (chains already exist from deployment)
    iptables -F TRAFFIC_TEST
    
    for ip in $DEVICES; do
        # Skip counting local-to-local traffic (RETURN early)
        iptables -A TRAFFIC_TEST -s "$ip" -d 192.168.0.0/16 -j RETURN
        iptables -A TRAFFIC_TEST -d "$ip" -s 192.168.0.0/16 -j RETURN
        
        # Count everything else (Internet traffic)
        iptables -A TRAFFIC_TEST -s "$ip" -j RETURN
        iptables -A TRAFFIC_TEST -d "$ip" -j RETURN
    done
    log "Refreshed $(echo $DEVICES | wc -w) devices (Internet traffic only)"
}

# Create enhanced snapshot with Internet-only traffic
echo "=== Internet Traffic Snapshot ===" > "$OUTFILE"
echo "Snapshot time: $(date)" >> "$OUTFILE"
echo "Note: Local LAN traffic (192.168.x.x) is excluded" >> "$OUTFILE"
echo "" >> "$OUTFILE"

# Get device count
CURRENT_DEVICES=$(iptables -L TRAFFIC_TEST -n 2>/dev/null | grep RETURN | awk '{print $NF}' | grep '^[0-9]' | sort -u | wc -l)
echo "Monitored devices: $CURRENT_DEVICES" >> "$OUTFILE"
echo "" >> "$OUTFILE"

# === Internet-Only Traffic ===
echo "==== Internet Traffic per IP ====" >> "$OUTFILE"
iptables -L TRAFFIC_TEST -v -n 2>/dev/null | awk '
/^[[:space:]]*[0-9]+/ {
    ip1=""; ip2=""
    for(i=1;i<=NF;i++){
        if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){
            if(ip1=="") ip1=$i
            else ip2=$i
        }
    }
    if(ip1 && ip2 && $2 ~ /^[0-9]+$/){
        # Only count traffic to/from non-LAN IP (Internet traffic)
        if(ip1 !~ /^192\.168\./ || ip2 !~ /^192\.168\./){
            lan_ip=(ip1 ~ /^192\.168\./ ? ip1 : ip2)
            bytes[lan_ip]+=$2
        }
    }
}
END {
    for(ip in bytes){
        t=bytes[ip]
        if(t>1024*1024*1024)
            printf "%-15s %7.2f GB\n", ip, t/1024/1024/1024
        else if(t>1024*1024)
            printf "%-15s %7.2f MB\n", ip, t/1024/1024
        else if(t>1024)
            printf "%-15s %7.2f KB\n", ip, t/1024
        else
            printf "%-15s %7d B\n", ip, t
    }
}' >> "$OUTFILE"

# Start background monitor if not running
if [ ! -f "$PID_FILE" ] || ! kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    ( while true; do update_rules; sleep 60; done ) >/dev/null 2>&1 &
    echo $! > "$PID_FILE"
    log "Internet-only monitor started: $!"
fi

log "Internet traffic snapshot created: $OUTFILE"
IPEOF
    chmod +x "$BASE_DIR/ip_traffic_auto.sh"
    
    # Start the monitor
    "$BASE_DIR/ip_traffic_auto.sh"
    send_log "INFO" "IP Traffic Monitor started (Internet-only tracking)"
}

# === UPLOAD SCRIPT SETUP ===  
deploy_upload_script() {
    send_log "INFO" "Deploying upload script..."
    
    cat > /tmp/upload_logs.sh <<'UPLOADEOF'
#!/bin/sh
PHONE_IP='192.168.1.13'
PORT='8081'
DIRS='/tmp/bandwidth /tmp/web_usage /tmp/ip_traffic'

# Take bandwidth snapshot
mkdir -p /tmp/bandwidth
cat /proc/net/dev > /tmp/bandwidth/bandwidth_snapshot_$(date +%Y%m%d_%H%M%S).txt

# Take IP traffic snapshot
[ -f "/tmp/ip_traffic/ip_traffic_auto.sh" ] && /tmp/ip_traffic_test/ip_traffic_auto.sh

send_file() {
    file="$1"
    filesize=$(wc -c < "$file")
    {
        printf 'POST /upload-bandwidth HTTP/1.1\r\n'
        printf 'Host: %s:%s\r\n' "$PHONE_IP" "$PORT"
        printf 'Content-Type: application/octet-stream\r\n'
        printf 'Content-Length: %s\r\n' "$filesize"
        printf 'X-Source-Path: %s\r\n' "$file"
        printf 'Connection: close\r\n\r\n'
        cat "$file"
    } | nc -w 5 "$PHONE_IP" "$PORT" && rm -f "$file"
}

for DIR in $DIRS; do
    [ -d "$DIR" ] && for file in "$DIR"/*; do [ -f "$file" ] && send_file "$file"; done
done
UPLOADEOF
    chmod +x /tmp/upload_logs.sh
    send_log "INFO" "Upload script deployed"
}

# === INITIAL UPLOAD ===
run_initial_upload() {
    send_log "INFO" "Running initial upload..."
    /tmp/upload_logs.sh
    send_log "INFO" "Initial upload completed"
}

# === MAIN EXECUTION ===
send_log "INFO" "Starting complete router monitoring setup..."

setup_ip_traffic_monitor
deploy_upload_script  
run_initial_upload

send_log "INFO" "🎯 Router monitoring system fully deployed and running!"
EOF
