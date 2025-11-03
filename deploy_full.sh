#!/bin/sh
# Idempotent Router Monitoring Setup - Safe for multiple runs
PHONE_IP='192.168.1.13'
PORT='8081'

send_log() {
    level="$1"
    message="$2"
    length=$(echo -n "$message" | wc -c)
    {
        echo "POST /log-message HTTP/1.1"
        echo "Host: $PHONE_IP:$PORT"
        echo "X-Log-Level: $level"
        echo "Content-Length: $length"
        echo "Content-Type: text/plain"
        echo "Connection: close"
        echo
        echo "$message"
    } | nc -w 3 "$PHONE_IP" "$PORT" >/dev/null 2>&1
}

# === CHECK IF ALREADY RUNNING ===
if [ -f "/tmp/ip_traffic_test/monitor.pid" ] && kill -0 $(cat "/tmp/ip_traffic_test/monitor.pid") 2>/dev/null; then
    send_log "INFO" "✅ Monitor already running (PID: $(cat /tmp/ip_traffic_test/monitor.pid)) - Safe to skip"
    exit 0
fi

send_log "INFO" "🚀 Starting router monitoring deployment..."

# === CREATE DIRECTORIES ===
mkdir -p /tmp/bandwidth /tmp/web_usage /tmp/ip_traffic_test
send_log "INFO" "📁 Directories created"

# === SETUP IP TRAFFIC MONITOR ===
send_log "INFO" "🔧 Setting up IP traffic monitoring..."

# Create chains only if they don't exist (idempotent)
iptables -L TRAFFIC_TEST >/dev/null 2>&1 || iptables -N TRAFFIC_TEST
iptables -C INPUT -j TRAFFIC_TEST >/dev/null 2>&1 || iptables -I INPUT -j TRAFFIC_TEST
iptables -C FORWARD -j TRAFFIC_TEST >/dev/null 2>&1 || iptables -I FORWARD -j TRAFFIC_TEST

send_log "INFO" "📊 IPTables chains configured"

# Stop any existing monitor (clean start)
if [ -f "/tmp/ip_traffic_test/monitor.pid" ]; then
    OLD_PID=$(cat "/tmp/ip_traffic_test/monitor.pid")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null
        send_log "INFO" "🛑 Stopped previous monitor (PID: $OLD_PID)"
    fi
    rm -f "/tmp/ip_traffic_test/monitor.pid"
fi

# Start background monitor
(
    while true; do
        # Refresh device list and rules
        DEVICES=""
        [ -f "/proc/net/arp" ] && DEVICES="$DEVICES $(awk 'NR>1 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3=="0x2" {print $1}' /proc/net/arp)"
        [ -f "/tmp/dhcp.leases" ] && DEVICES="$DEVICES $(awk '$3 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $3}' /tmp/dhcp.leases)"
        DEVICES=$(echo "$DEVICES" | tr ' ' '\n' | awk '!seen[$0]++' | tr '\n' ' ')
        
        # Update iptables rules
        iptables -F TRAFFIC_TEST
        
        for ip in $DEVICES; do
            # Skip local traffic, count internet traffic
            iptables -A TRAFFIC_TEST -s "$ip" -d 192.168.0.0/16 -j RETURN
            iptables -A TRAFFIC_TEST -d "$ip" -s 192.168.0.0/16 -j RETURN
            iptables -A TRAFFIC_TEST -s "$ip" -j RETURN
            iptables -A TRAFFIC_TEST -d "$ip" -j RETURN
        done
        sleep 60
    done
) >/dev/null 2>&1 &
MONITOR_PID=$!
echo $MONITOR_PID > /tmp/ip_traffic_test/monitor.pid

send_log "INFO" "📡 IP traffic monitor started (PID: $MONITOR_PID)"

# === SETUP UPLOAD SCRIPT ===
send_log "INFO" "📤 Setting up upload script..."

cat > /tmp/upload_logs.sh <<'EOF'
#!/bin/sh
PHONE_IP='192.168.1.13'
PORT='8081'

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

log "Starting upload cycle..."

# Create bandwidth snapshot
mkdir -p /tmp/bandwidth
cat /proc/net/dev > /tmp/bandwidth/bandwidth_snapshot_$(date +%Y%m%d_%H%M%S).txt

# Create IP traffic snapshot (directly in upload script)
IP_OUTFILE="/tmp/ip_traffic_test/traffic_snapshot_$(date +%Y%m%d_%H%M%S).txt"

echo "=== Internet Traffic Snapshot ===" > "$IP_OUTFILE"
echo "Snapshot time: $(date)" >> "$IP_OUTFILE"
echo "Note: Local LAN traffic (192.168.x.x) is excluded" >> "$IP_OUTFILE"
echo "" >> "$IP_OUTFILE"

# Get device count
CURRENT_DEVICES=$(iptables -L TRAFFIC_TEST -n 2>/dev/null | grep RETURN | awk '{print $NF}' | grep '^[0-9]' | sort -u | wc -l)
echo "Monitored devices: $CURRENT_DEVICES" >> "$IP_OUTFILE"
echo "" >> "$IP_OUTFILE"

# === Internet-Only Traffic (FIXED VERSION) ===
echo "==== Internet Traffic per IP ====" >> "$IP_OUTFILE"
iptables -L TRAFFIC_TEST -v -n 2>/dev/null | awk '
/^[[:space:]]*[0-9]+/ {
    bytes = $2
    ip_src = $7
    ip_dst = $8
    
    if (bytes > 0) {
        if (ip_src ~ /^192\.168\./ && ip_dst !~ /^192\.168\./) {
            internet_bytes[ip_src] += bytes
        }
        else if (ip_src !~ /^192\.168\./ && ip_dst ~ /^192\.168\./) {
            internet_bytes[ip_dst] += bytes
        }
    }
}
END {
    for (ip in internet_bytes) {
        total = internet_bytes[ip]
        if (total > 1024*1024*1024)
            printf "%-15s %7.2f GB\n", ip, total/1024/1024/1024
        else if (total > 1024*1024)
            printf "%-15s %7.2f MB\n", ip, total/1024/1024
        else if (total > 1024)
            printf "%-15s %7.2f KB\n", ip, total/1024
        else
            printf "%-15s %7d B\n", ip, total
    }
}' >> "$IP_OUTFILE"

log "IP traffic snapshot created: $(basename $IP_OUTFILE)"

# Upload function
send_file() {
    file="$1"
    if [ ! -f "$file" ]; then
        log "File not found: $file"
        return 1
    fi
    
    filesize=$(wc -c < "$file")
    log "Uploading: $file ($filesize bytes)"
    
    if {
        printf 'POST /upload-bandwidth HTTP/1.1\r\n'
        printf 'Host: %s:%s\r\n' "$PHONE_IP" "$PORT"
        printf 'Content-Type: application/octet-stream\r\n'
        printf 'Content-Length: %s\r\n' "$filesize"
        printf 'X-Source-Path: %s\r\n' "$file"
        printf 'Connection: close\r\n'
        printf '\r\n'
        cat "$file"
    } | nc -w 10 "$PHONE_IP" "$PORT"; then
        log "✅ Upload successful, deleting $file"
        rm -f "$file"
        return 0
    else
        log "❌ Upload failed, keeping $file for retry"
        return 1
    fi
}

# Upload bandwidth snapshot
for file in /tmp/bandwidth/bandwidth_snapshot_*.txt; do
    [ -f "$file" ] && send_file "$file"
done

# Upload latest IP traffic snapshot
LATEST_SNAPSHOT=$(ls -t /tmp/ip_traffic_test/traffic_snapshot_*.txt 2>/dev/null | head -1)
if [ -n "$LATEST_SNAPSHOT" ] && [ -f "$LATEST_SNAPSHOT" ]; then
    log "Uploading IP traffic snapshot: $(basename $LATEST_SNAPSHOT)"
    send_file "$LATEST_SNAPSHOT"
fi

# Upload web usage if any
if [ -d "/tmp/web_usage" ]; then
    for file in /tmp/web_usage/*; do
        [ -f "$file" ] && send_file "$file"
    done
fi

# Cleanup old snapshots (keep only last 3)
ls -t /tmp/ip_traffic_test/traffic_snapshot_*.txt 2>/dev/null | tail -n +4 | while read old_file; do
    rm -f "$old_file"
done

log "Upload cycle completed"
EOF

chmod +x /tmp/upload_logs.sh
send_log "INFO" "✅ Upload script deployed"

# === CREATE CLEANUP SCRIPT ===
cat > /tmp/ip_traffic_test/clean_monitor.sh <<'EOF'
#!/bin/sh
echo "🧹 Cleaning up IP Traffic Monitor..."
PID_FILE="/tmp/ip_traffic_test/monitor.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null
        echo "✅ Stopped monitor (PID: $PID)"
    fi
    rm -f "$PID_FILE"
fi

iptables -D INPUT -j TRAFFIC_TEST 2>/dev/null && echo "✅ Removed from INPUT chain"
iptables -D FORWARD -j TRAFFIC_TEST 2>/dev/null && echo "✅ Removed from FORWARD chain"
iptables -F TRAFFIC_TEST 2>/dev/null && echo "✅ Flushed TRAFFIC_TEST chain"
iptables -X TRAFFIC_TEST 2>/dev/null && echo "✅ Deleted TRAFFIC_TEST chain"

echo "🎯 Cleanup completed"
EOF
chmod +x /tmp/ip_traffic_test/clean_monitor.sh
send_log "INFO" "🧹 Cleanup script created"

# === RUN INITIAL UPLOAD ===
send_log "INFO" "📊 Running initial upload..."
/tmp/upload_logs.sh

send_log "INFO" "🎯 Router monitoring system fully deployed and ready!"
send_log "INFO" "💡 Run '/tmp/upload_logs.sh' manually for immediate data upload"
send_log "INFO" "💡 Run '/tmp/ip_traffic_test/clean_monitor.sh' to stop monitoring"
