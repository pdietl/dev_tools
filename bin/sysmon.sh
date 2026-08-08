#!/usr/bin/env bash
# sysmon.sh — 1 Hz system monitor for screen + file logging
# Usage: ./sysmon.sh [logfile]
# Requires: sysstat (mpstat).  Optional: lm-sensors, nvidia-driver

set -euo pipefail

LOGFILE="${1:-sysmon_$(date +%Y%m%d_%H%M%S).csv}"

# --- dependency check ---
# mpstat alone is required: the per-CPU column count is derived from its
# output, so without it every row would disagree with the header. The sensor
# and GPU fields already fall back to "-", so those tools being absent must
# not stop a run that can still log everything else.
if ! command -v mpstat &>/dev/null; then
    echo "Missing required: mpstat" >&2
    echo "  sudo apt install sysstat" >&2
    exit 1
fi

for cmd in sensors nvidia-smi; do
    if ! command -v "$cmd" &>/dev/null; then
        case "$cmd" in
            sensors)
                echo "Note: sensors absent — temp and fan columns will be '-'" >&2
                echo "  sudo apt install lm-sensors && sudo sensors-detect" >&2
                ;;
            nvidia-smi)
                echo "Note: nvidia-smi absent — GPU columns will be '-'" >&2
                ;;
        esac
    fi
done

NCPU=$(nproc)

# --- build CSV header ---
HEADER="timestamp,cpu_total_pct"
for ((i=0; i<NCPU; i++)); do HEADER+=",cpu${i}_pct"; done
HEADER+=",mem_used_mb,mem_total_mb,mem_pct"
HEADER+=",tctl_c,tdie_c,tccd1_c,tccd2_c"
HEADER+=",gpu_temp_c,gpu_util_pct,gpu_mem_used_mb,gpu_power_w"
HEADER+=",gpu_mem_free_mb,gpu_mem_total_mb,gpu_mem_reserved_mb"
HEADER+=",fan_info"

echo "$HEADER" | tee "$LOGFILE"

# --- main loop ---
while true; do
    TS=$(date +%H:%M:%S)

    # CPU usage via mpstat — single awk pass, null-terminated
    read -r -d '' CPU_CSV < <(mpstat -P ALL 1 1 | awk '
        /^Average/ && $2 == "all" { printf "%.1f", 100-$NF }
        /^Average/ && $2 ~ /^[0-9]+$/ { printf ",%.1f", 100-$NF }
        END { printf "\0" }
    ') || true

    # Memory — null-terminated
    read -r -d '' MEM_CSV < <(free -m | awk '
        /^Mem:/ { printf "%d,%d,%.1f", $3, $2, $3/$2*100 }
        END { printf "\0" }
    ') || true

    # Sensors — capture once; command may fail if no sensors loaded
    SENSORS_RAW=$(sensors -u 2>/dev/null) || SENSORS_RAW=""

    # CPU temps from k10temp (Tctl, Tdie, Tccd1, Tccd2)
    read -r -d '' TEMP_CSV < <(printf '%s' "$SENSORS_RAW" | awk '
        BEGIN { tctl="-"; tdie="-"; tccd1="-"; tccd2="-" }
        /Tctl/  { getline; tctl=sprintf("%.0f",$2) }
        /Tdie/  { getline; tdie=sprintf("%.0f",$2) }
        /Tccd1/ { getline; tccd1=sprintf("%.0f",$2) }
        /Tccd2/ { getline; tccd2=sprintf("%.0f",$2) }
        END { printf "%s,%s,%s,%s\0", tctl, tdie, tccd1, tccd2 }
    ') || true

    # GPU stats — awk provides defaults if nvidia-smi produces no output.
    # Free and reserved framebuffer are logged beside used because a scanout
    # allocation that video memory cannot satisfy fails outright — that path
    # has no system-memory fallback — so headroom is what explains a refusal.
    read -r -d '' GPU_CSV < <(nvidia-smi \
        --query-gpu=temperature.gpu,utilization.gpu,memory.used,power.draw,memory.free,memory.total,memory.reserved \
        --format=csv,noheader,nounits 2>/dev/null \
        | awk '
            BEGIN { out="-,-,-,-,-,-,-" }
            NF { gsub(/ /,""); out=$0 }
            END { printf "%s\0", out }
        ') || true

    # Fan RPMs — reuse sensors output (sensors -u format: "fan1_input: 2242.000")
    read -r -d '' FAN_CSV < <(printf '%s' "$SENSORS_RAW" | awk '
        BEGIN { out="" }
        /fan[0-9]+_input:/ {
            rpm = int($2)
            if (rpm > 0) {
                name = $1; sub(/_input:/, "", name)
                out = out sprintf("%s=%dRPM ", name, rpm)
            }
        }
        END {
            sub(/ $/, "", out)
            if (out == "") out = "-"
            printf "%s\0", out
        }
    ') || true

    LINE="${TS},${CPU_CSV},${MEM_CSV},${TEMP_CSV},${GPU_CSV},${FAN_CSV}"
    echo "$LINE" | tee -a "$LOGFILE"
done
