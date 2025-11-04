#!/bin/sh
# ENHANCED Router Monitoring Setup - Permanent in /root with Watchdog
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

# === PERMANENT PATHS IN /ROOT ===
MONITOR_DIR="/root/monitoring"
BANDWIDTH_DIR="$MONITOR_DIR/bandwidth"
WEB_USAGE_DIR="$MONITOR_DIR/web_usage"
IP_TRAFFIC_DIR="$MONITOR_DIR/ip_traffic"
PID_FILE="$IP_TRAFFIC_DIR/monitor.pid"

send_log "INFO" "🚀 Starting ENHANCED router monitoring deployment..."

# === CREATE PERMANENT DIRECTORIES ===
mkdir -p "$BANDWIDTH_DIR" "$WEB_USAGE_DIR" "$IP_TRAFFIC_DIR"
send_log "INFO" "📁 Permanent directories created in /root/monitoring"

# === SETUP ENHANCED IP TRAFFIC MONITOR ===
send_log "INFO" "🔧 Setting up ENHANCED IP traffic monitoring..."

# Clean up any existing setup first
iptables -D INPUT -j TRAFFIC_TEST 2>/dev/null
iptables -D FORWARD -j TRAFFIC_TEST 2>/dev/null
iptables -F TRAFFIC_TEST 2>/dev/null
iptables -X TRAFFIC_TEST 2>/dev/null

# Create chain only if it doesn't exist
iptables -L TRAFFIC_TEST >/dev/null 2>&1 || iptables -N TRAFFIC_TEST

# Add to chains AFTER connection tracking
iptables -C INPUT -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST >/dev/null 2>&1 || iptables -I INPUT -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST
iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST >/dev/null 2>&1 || iptables -I FORWARD -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST

send_log "INFO" "📊 IPTables chains configured"

# Stop any existing monitor (clean start)
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        kill "$OLD_PID" 2>/dev/null
        send_log "INFO" "🛑 Stopped previous monitor (PID: $OLD_PID)"
    fi
    rm -f "$PID_FILE"
fi

# Start ENHANCED background monitor with logging
(
    while true; do
        # Refresh device list from ARP table
        DEVICES=$(awk 'NR>1 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3=="0x2" {print $1}' /proc/net/arp)
        
        # Update iptables rules
        iptables -F TRAFFIC_TEST
        
        for ip in $DEVICES; do
            iptables -A TRAFFIC_TEST -d "$ip"    # Download traffic TO device
            iptables -A TRAFFIC_TEST -s "$ip"    # Upload traffic FROM device
        done
        
        # Essential: Allow all traffic to continue through chain
        iptables -A TRAFFIC_TEST -j ACCEPT
        
        sleep 60
    done
) >/dev/null 2>&1 &
MONITOR_PID=$!
echo $MONITOR_PID > "$PID_FILE"

send_log "INFO" "📡 ENHANCED IP traffic monitor started (PID: $MONITOR_PID)"

# === CREATE WATCHDOG SCRIPT ===
send_log "INFO" "🛡️ Creating watchdog script..."

cat > /root/monitoring/ip_traffic/watchdog.sh <<'EOF'
#!/bin/sh
# ENHANCED IP Traffic Monitor Watchdog - Checks BOTH process AND iptables
PHONE_IP='192.168.1.13'
PORT='8081'

MONITOR_DIR="/root/monitoring"
IP_TRAFFIC_DIR="$MONITOR_DIR/ip_traffic"
PID_FILE="$IP_TRAFFIC_DIR/monitor.pid"
LOG_FILE="$IP_TRAFFIC_DIR/watchdog.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

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

log "🔍 ENHANCED Watchdog check started"

RESTART_NEEDED=0

# Check 1: Monitor process
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        log "✅ Monitor process running (PID: $PID)"
    else
        log "❌ Monitor PID exists but process dead (PID: $PID)"
        RESTART_NEEDED=1
    fi
else
    log "❌ No monitor PID file found"
    RESTART_NEEDED=1
fi

# Check 2: iptables chain exists
if iptables -t mangle -L TRAFFIC_TEST >/dev/null 2>&1; then
    log "✅ TRAFFIC_TEST chain exists"
else
    log "❌ TRAFFIC_TEST chain missing"
    RESTART_NEEDED=1
fi

# Check 3: Chain has rules (not empty)
if [ $RESTART_NEEDED -eq 0 ]; then
    RULE_COUNT=$(iptables -t mangle -L TRAFFIC_TEST -n 2>/dev/null | grep -c "^Chain")
    if [ "$RULE_COUNT" -gt 0 ]; then
        log "✅ TRAFFIC_TEST chain has rules"
    else
        log "❌ TRAFFIC_TEST chain is empty"
        RESTART_NEEDED=1
    fi
fi

# RESTART if needed
if [ $RESTART_NEEDED -eq 1 ]; then
    log "🚨 RESTARTING IP traffic monitor (reason: process=$([ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null && echo "running" || echo "dead"), chain=$(iptables -t mangle -L TRAFFIC_TEST >/dev/null 2>&1 && echo "exists" || echo "missing"))"

    # Kill old monitor
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        kill "$PID" 2>/dev/null
        rm -f "$PID_FILE"
    fi

    # Cleanup iptables
    iptables -t mangle -D INPUT -j TRAFFIC_TEST 2>/dev/null
    iptables -t mangle -D FORWARD -j TRAFFIC_TEST 2>/dev/null
    iptables -t mangle -F TRAFFIC_TEST 2>/dev/null
    iptables -t mangle -X TRAFFIC_TEST 2>/dev/null

    # Recreate everything
    iptables -t mangle -N TRAFFIC_TEST
    iptables -t mangle -I INPUT -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST
    iptables -t mangle -I FORWARD -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST

    # Start enhanced monitor with error checking
    (
        while true; do
            # Ensure chain exists before adding rules
            if ! iptables -t mangle -L TRAFFIC_TEST >/dev/null 2>&1; then
                echo "❌ TRAFFIC_TEST chain missing, recreating..." >> "$LOG_FILE"
                iptables -t mangle -N TRAFFIC_TEST
                iptables -t mangle -I INPUT -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST
                iptables -t mangle -I FORWARD -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST
            fi

            DEVICES=$(awk 'NR>1 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $3=="0x2" {print $1}' /proc/net/arp)
            
            # Clear and rebuild rules
            iptables -t mangle -F TRAFFIC_TEST
            
            for ip in $DEVICES; do
                iptables -t mangle -A TRAFFIC_TEST -d "$ip"
                iptables -t mangle -A TRAFFIC_TEST -s "$ip"
            done
            
            iptables -t mangle -A TRAFFIC_TEST -j ACCEPT
            sleep 60
        done
    ) >/dev/null 2>&1 &
    
    NEW_PID=$!
    echo $NEW_PID > "$PID_FILE"
    log "✅ Monitor restarted (PID: $NEW_PID)"
    send_log "WARNING" "🔄 IP Traffic Monitor restarted by enhanced watchdog"

    # Verify
    sleep 2
    if kill -0 "$NEW_PID" 2>/dev/null && iptables -t mangle -L TRAFFIC_TEST >/dev/null 2>&1; then
        log "✅ Restart verified successful"
        send_log "SUCCESS" "✅ IP Traffic Monitor restart successful"
    else
        log "❌ Restart verification failed"
        send_log "ERROR" "❌ IP Traffic Monitor restart failed"
    fi
else
    log "✅ All checks passed - no restart needed"
fi
EOF

chmod +x /root/monitoring/ip_traffic/watchdog.sh
send_log "INFO" "🛡️ Watchdog script created: $IP_TRAFFIC_DIR/watchdog.sh"

# === ENHANCED UPLOAD SCRIPT WITH WATCHDOG INTEGRATION ===
send_log "INFO" "📤 Setting up ENHANCED upload script with watchdog..."

cat > "/root/upload_logs.sh" <<'EOF'
#!/bin/sh
PHONE_IP='192.168.1.13'
PORT='8081'

MONITOR_DIR="/root/monitoring"
BANDWIDTH_DIR="$MONITOR_DIR/bandwidth"
WEB_USAGE_DIR="$MONITOR_DIR/web_usage"
IP_TRAFFIC_DIR="$MONITOR_DIR/ip_traffic"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

log "Starting ENHANCED upload cycle..."

# === RUN WATCHDOG CHECK FIRST ===
log "🛡️ Running watchdog check..."
"$IP_TRAFFIC_DIR/watchdog.sh"

# Create bandwidth snapshot
mkdir -p "$BANDWIDTH_DIR"
cat /proc/net/dev > "$BANDWIDTH_DIR/bandwidth_snapshot_$(date +%Y%m%d_%H%M%S).txt"

# Create IP traffic snapshot
IP_OUTFILE="$IP_TRAFFIC_DIR/traffic_snapshot_$(date +%Y%m%d_%H%M%S).txt"

echo "=== RAW IP Traffic Data Dump ===" > "$IP_OUTFILE"
echo "Snapshot time: $(date)" >> "$IP_OUTFILE"
echo "" >> "$IP_OUTFILE"

# === DUMP ALL IPTABLES DATA ===
echo "==== RAW IPTABLES DUMP ====" >> "$IP_OUTFILE"
iptables -L TRAFFIC_TEST -v -n >> "$IP_OUTFILE"

echo "" >> "$IP_OUTFILE"
echo "==== PROCESSED TRAFFIC TOTALS ====" >> "$IP_OUTFILE"

# Process IP traffic data
iptables -L TRAFFIC_TEST -v -n 2>/dev/null | awk '
/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+/ {
    pkts = $1
    bytes = $2
    ip_src = $8
    ip_dst = $9
    
    # Skip the ACCEPT rule at the end
    if ($3 == "ACCEPT") next
    
    if (bytes > 0) {
        # Count traffic for destination IPs (download)
        if (ip_dst ~ /^192\.168\.1\.[0-9]+$/) {
            total_bytes[ip_dst] += bytes
            internet_bytes[ip_dst] += bytes
        }
        
        # Count traffic for source IPs (upload)  
        if (ip_src ~ /^192\.168\.1\.[0-9]+$/) {
            total_bytes[ip_src] += bytes
            internet_bytes[ip_src] += bytes
        }
    }
}
END {
    print "IP TOTAL INTERNET LOCAL"
    print "--- -------- --------- -----"
    for (ip in total_bytes) {
        total_kb = total_bytes[ip] / 1024
        internet_kb = internet_bytes[ip] / 1024
        local_kb = 0
        
        # Format output nicely
        if (total_kb >= 1024) {
            total_str = sprintf("%.1f MB", total_kb / 1024)
            internet_str = sprintf("%.1f MB", internet_kb / 1024)
        } else {
            total_str = sprintf("%.0f KB", total_kb)
            internet_str = sprintf("%.0f KB", internet_kb)
        }
        
        printf "%-15s %-8s %-8s %s\n", ip, total_str, internet_str, "0 B"
    }
}' >> "$IP_OUTFILE"

log "ENHANCED traffic data dumped: $(basename $IP_OUTFILE)"

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
for file in "$BANDWIDTH_DIR"/bandwidth_snapshot_*.txt; do
    [ -f "$file" ] && send_file "$file"
done

# Upload IP traffic snapshot
for file in "$IP_TRAFFIC_DIR"/traffic_snapshot_*.txt; do
    [ -f "$file" ] && send_file "$file"
done

# Upload web usage if any
if [ -d "$WEB_USAGE_DIR" ]; then
    for file in "$WEB_USAGE_DIR"/*; do
        [ -f "$file" ] && send_file "$file"
    done
fi

log "ENHANCED upload cycle completed"
EOF

chmod +x "/root/upload_logs.sh"
send_log "INFO" "✅ ENHANCED upload script deployed with watchdog integration"

# === CREATE ENHANCED CLEANUP SCRIPT ===
cat > "$IP_TRAFFIC_DIR/clean_monitor.sh" <<'EOF'
#!/bin/sh
echo "🧹 Cleaning up ENHANCED IP Traffic Monitor..."
MONITOR_DIR="/root/monitoring"
IP_TRAFFIC_DIR="$MONITOR_DIR/ip_traffic"
PID_FILE="$IP_TRAFFIC_DIR/monitor.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null
        echo "✅ Stopped monitor (PID: $PID)"
    fi
    rm -f "$PID_FILE"
fi

# Remove from chains
iptables -D INPUT -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST 2>/dev/null && echo "✅ Removed from INPUT chain"
iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j TRAFFIC_TEST 2>/dev/null && echo "✅ Removed from FORWARD chain"
iptables -F TRAFFIC_TEST 2>/dev/null && echo "✅ Flushed TRAFFIC_TEST chain"
iptables -X TRAFFIC_TEST 2>/dev/null && echo "✅ Deleted TRAFFIC_TEST chain"

echo "🎯 ENHANCED Cleanup completed"
EOF
chmod +x "$IP_TRAFFIC_DIR/clean_monitor.sh"
send_log "INFO" "🧹 ENHANCED cleanup script created"

# === RUN INITIAL UPLOAD ===
send_log "INFO" "📊 Running initial upload with ENHANCED processing..."
/root/upload_logs.sh

send_log "SUCCESS" "🎯 ENHANCED Router monitoring system fully deployed and ready!")"
send_log "INFO" "📁 All files in /root/monitoring/ (permanent storage)")
send_log "INFO" "🛡️ Watchdog integrated - auto-restarts if monitor dies")
send_log "INFO" "💡 Run '/root/upload_logs.sh' manually for immediate data upload")
send_log "INFO" "💡 Run '$IP_TRAFFIC_DIR/clean_monitor.sh' to stop monitoring")
