#!/bin/sh
# Complete Router Monitoring Setup - Your original working script
# This is the EXACT same system you already tested successfully

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
    
    BASE_DIR="/tmp/ip_traffic_test"
    mkdir -p "$BASE_DIR"
    
    # Create the IP traffic script (your working version)
    cat > "$BASE_DIR/ip_traffic_auto.sh" <<'EOF'
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
    
    iptables -L TRAFFIC_TEST >/dev/null 2>&1 || iptables -N TRAFFIC_TEST
    iptables -C INPUT -j TRAFFIC_TEST >/dev/null 2>&1 || iptables -I INPUT -j TRAFFIC_TEST
    iptables -C FORWARD -j TRAFFIC_TEST >/dev/null 2>&1 || iptables -I FORWARD -j TRAFFIC_TEST
    iptables -F TRAFFIC_TEST
    
    for ip in $DEVICES; do
        iptables -A TRAFFIC_TEST -s "$ip" -j RETURN
        iptables -A TRAFFIC_TEST -d "$ip" -j RETURN
    done
    log "Refreshed $(echo $DEVICES | wc -w) devices"
}

echo "Traffic snapshot: $(date)" > "$OUTFILE"
iptables -L TRAFFIC_TEST -v -n 2>/dev/null >> "$OUTFILE"

if [ ! -f "$PID_FILE" ] || ! kill -0 $(cat "$PID_FILE") 2>/dev/null; then
    ( while true; do update_rules; sleep 60; done ) >/dev/null 2>&1 &
    echo $! > "$PID_FILE"
    log "Monitor started: $!"
fi
EOF
    chmod +x "$BASE_DIR/ip_traffic_auto.sh"
    
    # Start the monitor
    "$BASE_DIR/ip_traffic_auto.sh"
    send_log "INFO" "IP Traffic Monitor started"
}

# === UPLOAD SCRIPT SETUP ===  
deploy_upload_script() {
    send_log "INFO" "Deploying upload script..."
    
    cat > /tmp/upload_logs.sh <<'EOF'
#!/bin/sh
PHONE_IP='192.168.1.13'
PORT='8081'
DIRS='/tmp/bandwidth /tmp/web_usage /tmp/ip_traffic_test'

# Take bandwidth snapshot
mkdir -p /tmp/bandwidth
cat /proc/net/dev > /tmp/bandwidth/bandwidth_snapshot_$(date +%Y%m%d_%H%M%S).txt

# Take IP traffic snapshot
[ -f "/tmp/ip_traffic_test/ip_traffic_auto.sh" ] && /tmp/ip_traffic_test/ip_traffic_auto.sh

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
EOF
    chmod +x /tmp/upload_logs.sh
    send_log "INFO" "Upload script deployed"
}

# === SCHEDULING ===
setup_scheduling() {
    send_log "INFO" "Setting up scheduling..."
    
    # Add to crontab if not exists
    if ! crontab -l 2>/dev/null | grep -q "upload_logs.sh"; then
        (crontab -l 2>/dev/null; echo "*/15 * * * * /tmp/upload_logs.sh") | crontab -
        send_log "INFO" "Added 15-minute schedule to crontab"
    fi
    
    # Run initial upload
    send_log "INFO" "Running initial upload..."
    /tmp/upload_logs.sh
    
    send_log "INFO" "Scheduling setup complete"
}

# === MAIN EXECUTION ===
send_log "INFO" "Starting complete router monitoring setup..."

setup_ip_traffic_monitor
deploy_upload_script  
setup_scheduling

send_log "INFO" "🎯 Router monitoring system fully deployed and running!"
