#!/usr/bin/env bash
set -euo pipefail

cat << "EOF"
===========================================================================================
|                  NVIDIA Blackwell eGPU Hot-Plug & Link Optimizer                        |
|        This script configures the PCIe bus, authorizes Thunderbolt/USB4 devices,        |
|        disables ASPM/L1SS power management, negotiates the maximum link speed,          |
|                        and locks the P0 performance state.                              |
===========================================================================================
EOF

if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: This script requires root privileges."
    echo "    Run: sudo $0"
    exit 1
fi

if ! modinfo nvidia >/dev/null 2>&1; then
    echo "[-] Error: NVIDIA drivers not found on the system."
    echo "    Please install the appropriate driver package before running."
    exit 1
fi

negotiate_optimal_link_speed() {
    local GPU_PCI="$1"
    local PARENT_PORT="$2"

    local gpu_speed parent_speed
    gpu_speed=$(lspci -s "$GPU_PCI" -vv 2>/dev/null | awk '/LnkCap:/ {for(i=1;i<=NF;i++) if($i ~ /Speed/) print $(i+1)}' | tr -dc '0-9' || true)
    parent_speed=$(lspci -s "$PARENT_PORT" -vv 2>/dev/null | awk '/LnkCap:/ {for(i=1;i<=NF;i++) if($i ~ /Speed/) print $(i+1)}' | tr -dc '0-9' || true)

    local min_speed=${gpu_speed:-16}
    if [ -n "$parent_speed" ] && [ "$parent_speed" -lt "$min_speed" ]; then
        min_speed=$parent_speed
    fi

    case "$min_speed" in
        32*) echo "0025" ;; # Gen5 (32 GT/s)
        16*) echo "0024" ;; # Gen4 (16 GT/s)
        8*)  echo "0023" ;; # Gen3 (8 GT/s)
        *)   echo "0024" ;; # Safe fallback standard
    esac
}

echo "--- 1. Unloading NVIDIA kernel modules before bus reconfiguration ---"
fuser -k /dev/nvidia* 2>/dev/null || true
modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true

cat << "EOF"

===========================================================================================
|                        Environment prepared for GPU connection.                         |
|                                                                                         |
|                  >>> CONNECT eGPU CABLE NOW (Thunderbolt / USB4) <<<                    |
|                                                                                         |
|                 Waiting for bus detection and device authorization...                   |
===========================================================================================

EOF

# Polling loop with boltctl and sysfs authorization
while true; do
    # 1. Authorize via boltctl (if boltd daemon sees the device)
    if command -v boltctl >/dev/null 2>&1; then
        for uuid in $(boltctl list 2>/dev/null | awk '/ ● / {uuid=$2} /status:[[:space:]]+(connected|authorizing)/ {print uuid}'); do
            boltctl enroll --policy auto "$uuid" 2>/dev/null || boltctl authorize "$uuid" 2>/dev/null || true
        done
    fi

    # 2. Direct sysfs authorization fallback
    for auth in /sys/bus/thunderbolt/devices/*-*/authorized; do
        if [ -f "$auth" ]; then
            echo 1 > "$auth" 2>/dev/null || true
        fi
    done

    # 3. Trigger PCIe bus rescan
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    udevadm settle --timeout=1 2>/dev/null || true

    # 4. Check if NVIDIA GPU appears on the PCIe bus
    if lspci -d 10de: -nn 2>/dev/null | grep -iqE "VGA|3D"; then
        break
    fi

    sleep 0.5
done

GPU_FULL_PCI=$(lspci -D -d 10de: -nn 2>/dev/null | grep -iE "VGA|3D" | awk '{print $1}' | head -n 1 || true)
echo "[+] Detected GPU: $GPU_FULL_PCI"

# Dynamically parse the entire bridge path
PCI_TREE=$(lspci -D -PP -s "$GPU_FULL_PCI" 2>/dev/null | awk '{print $1}' || true)
IFS="/" read -ra BRIDGE_LIST <<< "$PCI_TREE"
TOTAL_NODES=${#BRIDGE_LIST[@]}

echo "--- 2. Disabling ASPM and L1SS along the bridge path (${BRIDGE_LIST[*]}) ---"
echo performance > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true

for node in "${BRIDGE_LIST[@]}"; do
    setpci -s "$node" CAP_EXP+10.w=0000 2>/dev/null || true
    setpci -s "$node" ECAP_1E+04.l=00000000 2>/dev/null || true
done

if [ "$TOTAL_NODES" -ge 2 ]; then
    PARENT_PORT="${BRIDGE_LIST[$((TOTAL_NODES - 2))]}"
    TARGET_HEX=$(negotiate_optimal_link_speed "$GPU_FULL_PCI" "$PARENT_PORT")
    echo "[+] Negotiating and enforcing link speed ($TARGET_HEX) on parent port: $PARENT_PORT"

    setpci -s "$PARENT_PORT" CAP_EXP+30.w="$TARGET_HEX:002f" 2>/dev/null || true
    setpci -s "$GPU_FULL_PCI" CAP_EXP+30.w="$TARGET_HEX:002f" 2>/dev/null || true
    setpci -s "$PARENT_PORT" CAP_EXP+10.w=0020:0020 2>/dev/null || true

    retries=0
    while [ $retries -lt 30 ]; do
        lnksta=$(setpci -s "$PARENT_PORT" CAP_EXP+12.w 2>/dev/null || echo "0")
        val=$(( 16#${lnksta:-0} ))
        if [ $(( val & 0x0800 )) -eq 0 ]; then
            break
        fi
        sleep 0.1
        retries=$((retries + 1))
    done
fi

sleep 0.5
echo "--- 3. Loading NVIDIA kernel modules with Runtime D3 disabled ---"
modprobe nvidia NVreg_DynamicPowerManagement=0x00 2>/dev/null || true

if [ -n "${PARENT_PORT:-}" ]; then
    setpci -s "$PARENT_PORT" CAP_EXP+30.w="$TARGET_HEX:002f" 2>/dev/null || true
fi

modprobe nvidia_modeset nvidia_drm nvidia_uvm 2>/dev/null || true
udevadm settle || true

echo "--- 4. Enforcing Persistence Mode and locked P0 performance clocks ---"
nvidia-smi -pm 1 >/dev/null 2>&1 || true
nvidia-smi --auto-boost-permission=0 >/dev/null 2>&1 || true

MAX_GPU=$(nvidia-smi --query-gpu=clocks.max.graphics --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)
MAX_MEM=$(nvidia-smi --query-gpu=clocks.max.memory --format=csv,noheader,nounits 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)

if [ -n "$MAX_GPU" ]; then
    nvidia-smi --lock-gpu-clocks="2000,$MAX_GPU" >/dev/null 2>&1 || true
fi

if [ -n "$MAX_MEM" ]; then
    nvidia-smi --lock-memory-clocks="$MAX_MEM,$MAX_MEM" >/dev/null 2>&1 || true
fi

cat << "EOF"

===========================================================================================
|                                                                                         |
|                                       ALL DONE!                                         |
|                                                                                         |
===========================================================================================


EOF

echo -e "\n============================= Hardware PCIe Registers (lspci) ============================="
lspci -vv -s "$GPU_FULL_PCI" | grep -E 'LnkSta:' | head -n 1


echo -e "\n=================================== NVIDIA-SMI Status ====================================="
nvidia-smi
