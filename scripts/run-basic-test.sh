#!/bin/bash

# Basic DNS Load Test Script
# This script runs a basic DNS performance test

set -e

# Load configuration from config file
CONFIG_FILE="configs/basic-test.conf"
if [ -f "$CONFIG_FILE" ]; then
    echo "📋 Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    echo "❌ Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Use CONCURRENT from config, default to 1 if not set
CONCURRENT=${CONCURRENT:-1}

# Create results directory if it doesn't exist
mkdir -p dnsperf-results

# Generate timestamp for unique result files
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_FILE="dnsperf-results/basic_test_${TIMESTAMP}.txt"
PROBE_RESULT_FILE="dnsperf-results/probe_test_${TIMESTAMP}.txt"

echo "🚀 Starting Basic DNS Load Test..."
echo "📊 Configuration:"
echo "   DNS Server: $DNS_SERVER"
echo "   Query File: $QUERY_FILE"
echo "   Duration: ${DURATION}s"
echo "   Queries per second: $QPS"
echo "   Concurrent connections: $CONCURRENT"
echo "   Timeout: ${TIMEOUT}s"
echo "   Results: $RESULT_FILE"
if [ "${PROBE_ENABLED}" = "true" ]; then
echo "   Probe: QPS=$PROBE_QPS, Concurrency=$PROBE_CONCURRENT, Timeout=${PROBE_TIMEOUT}s, Output: $PROBE_RESULT_FILE"
fi
echo ""

# Check if query file exists
if [ ! -f "$QUERY_FILE" ]; then
    echo "❌ Query file not found: $QUERY_FILE"
    exit 1
fi

# Check if dnsperf is installed
if ! command -v dnsperf &> /dev/null; then
    echo "❌ dnsperf not found. Please run ./setup.sh first"
    exit 1
fi

# Check if dig is available if benchmarking is enabled
if [ "${DIG_BENCH_ENABLED}" = "true" ]; then
    if ! command -v dig &> /dev/null; then
        echo "⚠️  dig not found. Disabling dig benchmark."
        DIG_BENCH_ENABLED=false
    fi
fi

# Prepare probe dnsperf if enabled
if [ "${PROBE_ENABLED}" = "true" ]; then
    PROBE_D_FILE=${PROBE_QUERY_FILE:-$QUERY_FILE}
    if [ ! -f "$PROBE_D_FILE" ]; then
        echo "⚠️  Probe query file not found: $PROBE_D_FILE — disabling probe"
        PROBE_ENABLED=false
    fi
fi

# Prepare dig benchmark if enabled
if [ "${DIG_BENCH_ENABLED}" = "true" ]; then
    DIG_DOMAIN=${DIG_BENCH_DOMAIN}
    if [ -z "$DIG_DOMAIN" ]; then
        # Take first domain from query file (assumes format: FQDN. TYPE)
        DIG_DOMAIN=$(head -n 1 "$QUERY_FILE" | awk '{print $1}')
    fi
    DIG_RESOLVER=${DIG_BENCH_RESOLVER:-$DNS_SERVER}
    DIG_INTERVAL=${DIG_BENCH_INTERVAL:-1}
    DIG_TYPE=${DIG_BENCH_TYPE:-A}
    DIG_OUT="dnsperf-results/dig_bench_${TIMESTAMP}.csv"
    echo "timestamp,domain,resolver,type,rcode,query_time_ms" > "$DIG_OUT"

    echo "🧪 Starting dig benchmark in background: resolver=$DIG_RESOLVER interval=${DIG_INTERVAL}s type=$DIG_TYPE random=${DIG_BENCH_RANDOM}"
    (
        while true; do
            TS=$(date +"%Y-%m-%dT%H:%M:%S%z")
            DOMAIN_TO_QUERY="$DIG_DOMAIN"
            TYPE_TO_QUERY="$DIG_TYPE"
            if [ "${DIG_BENCH_RANDOM}" = "true" ]; then
                # Pick random line from QUERY_FILE; assumes format: FQDN. TYPE
                # shuf may not exist everywhere; fall back to awk+NR random if needed
                if command -v shuf >/dev/null 2>&1; then
                    LINE=$(shuf -n 1 "$QUERY_FILE")
                else
                    # AWK random selection
                    LINE=$(awk 'BEGIN{srand()} {a[NR]=$0} END{print a[int(rand()*NR)+1]}' "$QUERY_FILE")
                fi
                RAND_DOMAIN=$(echo "$LINE" | awk '{print $1}')
                RAND_TYPE=$(echo "$LINE" | awk '{print $2}')
                if [ -n "$RAND_DOMAIN" ]; then DOMAIN_TO_QUERY="$RAND_DOMAIN"; fi
                if [ -n "$RAND_TYPE" ]; then TYPE_TO_QUERY="$RAND_TYPE"; fi
            fi
            # Run dig with timing; capture status and query time
            DIG_OUTPUT=$(dig @"$DIG_RESOLVER" "$DOMAIN_TO_QUERY" "$TYPE_TO_QUERY" +tries=1 +timeout=2 +stats 2>/dev/null)
            RCODE=$(echo "$DIG_OUTPUT" | awk '/^;; ->>HEADER<<-/{for(i=1;i<=NF;i++){if($i ~ /^status/){gsub("status=","",$i); gsub(",","",$i); print $i}}}')
            QTIME=$(echo "$DIG_OUTPUT" | awk '/Query time:/{print $(NF-1)}')
            if [ -z "$RCODE" ]; then RCODE=NOANSWER; fi
            if [ -z "$QTIME" ]; then QTIME=NaN; fi
            echo "$TS,$DOMAIN_TO_QUERY,$DIG_RESOLVER,$TYPE_TO_QUERY,$RCODE,$QTIME" >> "$DIG_OUT"
            sleep "$DIG_INTERVAL"
        done
    ) &
    DIG_PID=$!
fi

# Run the probe stream in background (if enabled)
if [ "${PROBE_ENABLED}" = "true" ]; then
    echo "🧪 Starting probe dnsperf in background..."
    dnsperf -s $DNS_SERVER \
            -d $PROBE_D_FILE \
            -l $DURATION \
            -Q $PROBE_QPS \
            -q $PROBE_QPS \
            -c $PROBE_CONCURRENT \
            -t $PROBE_TIMEOUT \
            $PROBE_EXTRA_OPTIONS \
            > $PROBE_RESULT_FILE 2>&1 &
    PROBE_PID=$!
fi

# Run the test (dnsperf)
echo "🔄 Running DNS performance test..."
dnsperf -s $DNS_SERVER \
        -d $QUERY_FILE \
        -l $DURATION \
        -Q $QPS \
        -q $QPS \
        -c $CONCURRENT \
        -t $TIMEOUT \
        $EXTRA_OPTIONS \
	| grep -v "Query timed out" \
        | tee $RESULT_FILE

# Stop dig benchmark if running
if [ -n "${DIG_PID}" ]; then
    echo "🛑 Stopping dig benchmark (PID $DIG_PID)"
    kill "$DIG_PID" >/dev/null 2>&1 || true
    wait "$DIG_PID" 2>/dev/null || true
fi

# Wait for probe stream to finish if running
if [ -n "${PROBE_PID}" ]; then
    echo "🛑 Stopping probe stream (PID $PROBE_PID)"
    wait "$PROBE_PID" 2>/dev/null || true
fi

echo ""
echo "✅ Test completed!"
echo "📄 Results saved to: $RESULT_FILE"
echo ""

# Create a symlink to the latest result
ln -sf "$(basename $RESULT_FILE)" dnsperf-results/latest-basic-test.txt

# Extract key metrics
echo "📈 Key Metrics:"
grep -E "(Queries sent|Queries completed|Response codes|Average|Percentage)" $RESULT_FILE | head -10

# Summarize dig benchmark if produced
if [ "${DIG_BENCH_ENABLED}" = "true" ] && [ -f "$DIG_OUT" ]; then
    echo ""
    echo "📊 dig benchmark summary (file: $DIG_OUT)"
    TOTAL=$(awk -F, 'NR>1{c++} END{print c+0}' "$DIG_OUT")
    OK=$(awk -F, 'NR>1 && $5=="NOERROR"{c++} END{print c+0}' "$DIG_OUT")
    FAIL=$((TOTAL-OK))
    PCT_OK=$(awk -v ok="$OK" -v tot="$TOTAL" 'BEGIN{if(tot>0) printf("%.2f", ok*100/tot); else print "0.00"}')
    P50=$(awk -F, 'NR>1 && $6 ~ /^[0-9]+$/{print $6}' "$DIG_OUT" | sort -n | awk 'NF{a[NR]=$1} END{if(NR){i=int((NR+1)*0.5); print a[i]} else print "NaN"}')
    P95=$(awk -F, 'NR>1 && $6 ~ /^[0-9]+$/{print $6}' "$DIG_OUT" | sort -n | awk 'NF{a[NR]=$1} END{if(NR){i=int(NR*0.95); if(i<1)i=1; print a[i]} else print "NaN"}')
    MAX=$(awk -F, 'NR>1 && $6 ~ /^[0-9]+$/{if($6>m)m=$6} END{if(m>0)print m; else print "NaN"}' "$DIG_OUT")
    echo "   Samples: $TOTAL, Success: $OK (${PCT_OK}%), Fail: $FAIL"
    echo "   Latency ms: p50=$P50, p95=$P95, max=$MAX"
fi

# Summarize probe dnsperf if produced
if [ -f "$PROBE_RESULT_FILE" ]; then
    echo ""
    echo "🔎 Probe stream summary (file: $PROBE_RESULT_FILE)"
    grep -E "(Queries sent|Queries completed|Average latency|Latency|Response codes|Lost)" "$PROBE_RESULT_FILE" | sed -e 's/^/   /'
fi

echo ""
echo "💡 Analysis:"
# Calculate success rate
SENT=$(grep "Queries sent:" $RESULT_FILE | awk '{print $3}' || echo "0")
COMPLETED=$(grep "Queries completed:" $RESULT_FILE | awk '{print $3}' || echo "0")

if [ "$SENT" -gt 0 ]; then
    SUCCESS_RATE=$(echo "scale=2; $COMPLETED * 100 / $SENT" | bc -l 2>/dev/null || echo "N/A")
    echo "   Success Rate: ${SUCCESS_RATE}%"
fi

echo ""
echo "🔬 Running detailed analysis..."
echo "=============================================="

# Check if analyzer script exists and run it
ANALYZER_SCRIPT="./scripts/analyze-uv.sh"
if [ -f "$ANALYZER_SCRIPT" ]; then
    echo "📊 Launching DNS performance analyzer..."
    $ANALYZER_SCRIPT "$RESULT_FILE"
else
    echo "⚠️  Analyzer script not found: $ANALYZER_SCRIPT"
    echo "💡 You can manually analyze results with:"
    echo "   ./scripts/analyze-uv.sh $RESULT_FILE"
fi

echo ""
echo "💡 Tips:"
echo "   - View full results: cat $RESULT_FILE"
echo "   - Run stress test: ./scripts/run-stress-test.sh"
echo "   - Customize queries: edit $QUERY_FILE"
echo "   - Modify config: edit $CONFIG_FILE"
echo "   - Analysis reports: check analyzer-results/ directory" 
