#!/usr/bin/env bash

# ------------------------------------------------------------------------------
# Proxmox Batch VM Creation Script with Disk Resize Feature
#   With interactive prompts for default hardware overrides, optional extra disk space,
#   and configurable disk device for resizing.
# ------------------------------------------------------------------------------

set -euo pipefail  # Exit on error, unset variables are errors, pipeline fails on first error

# ----- Default Values -----
TEMPLATE_ID=5000
STORAGE="local-lvm"
START_ID=5050

DEFAULT_CPU_CORES=2
DEFAULT_RAM="4096M"       # 4096 MB by default
DEFAULT_NET_BRIDGE="vmbr1"
DEFAULT_DISK_DEVICE="scsi0"  # Default disk device to resize

# Upper/Lower bounds (adjust to taste)
MAX_CPU_CORES=32
MAX_RAM_MB=32768           # 32GB in MB
MIN_RAM_MB=256             # e.g. 256MB

# CLI argument defaults
NUM_VMS=""
VM_PREFIX=""
CPU_CORES="$DEFAULT_CPU_CORES"
RAM="$DEFAULT_RAM"
NET_BRIDGE="$DEFAULT_NET_BRIDGE"
DISK_DEVICE="$DEFAULT_DISK_DEVICE"
USE_STATIC_IP=false
FIRST_IP=""   # e.g. "192.168.1.10/24"
ENABLE_SNAPSHOT=false
EXTRA_DISK=""  # Extra disk space to add (e.g., 10G or 512M)

# Bookkeeping to detect if user explicitly set each option
FLAG_CPU_SET=false
FLAG_RAM_SET=false
FLAG_BRIDGE_SET=false
FLAG_DISK_DEVICE_SET=false

# ----- Usage Function -----
usage() {
  cat <<EOF
Usage: $0 -n <num_vms> -p <prefix> [options]

Required:
  -n NUM       Number of VMs to create.
  -p PREFIX    VM name prefix (e.g., 'ansible' -> ansible-1, ansible-2)

Options:
  -c CPU       CPU cores per VM (integer 1..$MAX_CPU_CORES) [default: $DEFAULT_CPU_CORES]
  -m RAM       RAM per VM. Accepts:
               - plain MB (e.g., 4096) [default: $DEFAULT_RAM]
               - suffix M or G (e.g., 512M, 2G)
  -b BRIDGE    Network bridge (default: $DEFAULT_NET_BRIDGE)
  -i IP/CIDR   First static IP with optional CIDR (e.g., 192.168.10.50/24).
               Each subsequent VM increments the last octet.
  -d DISK      Extra disk space to add to the VM (e.g., 10G, 512M).
  -D DEVICE    Disk device to resize (default: $DEFAULT_DISK_DEVICE).
  -s           Create a snapshot of the template before cloning.
  -h           Show this help message.

Examples:
  $0 -n 3 -p ansible
  $0 -n 3 -p ansible -c 2 -m 2G -b vmbr1 -i 192.168.10.50/24 -d 10G -D scsi0
EOF
  exit 1
}

# ----- Parse Memory Helper -----
# Converts e.g. "2048" -> 2048 MB, "2G" -> 2048 MB, "512M" -> 512 MB
parse_memory_mb() {
  local input="$1"
  # Plain integer (assume MB)
  if [[ "$input" =~ ^([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  # e.g. "512M" or "512m"
  elif [[ "$input" =~ ^([0-9]+)[mM]$ ]]; then
    echo "${BASH_REMATCH[1]}"
  # e.g. "2G" or "2g"
  elif [[ "$input" =~ ^([0-9]+)[gG]$ ]]; then
    local gigs="${BASH_REMATCH[1]}"
    echo $(( gigs * 1024 ))
  else
    echo "Error: invalid memory format '$input' (valid examples: 2048, 512M, 2G)." >&2
    exit 1
  fi
}

# ----- Parse IP/CIDR Helper -----
# Takes "192.168.1.50/24" or "192.168.1.50".
# Splits into base IP, netmask bits. If no /bits, default 24.
# Returns (global variables):
#   IP_BASE, LAST_OCTET, CIDR
parse_ip_cidr() {
  local input="$1"
  local ip_part
  local cidr_part=24  # default if not specified

  if [[ "$input" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(/(3[0-2]|[12]?[0-9]))?$ ]]; then
    ip_part="${BASH_REMATCH[1]}"
    if [[ -n "${BASH_REMATCH[2]}" ]]; then
      cidr_part="${BASH_REMATCH[2]#'/'}"
    fi
  else
    echo "Error: Invalid IP/CIDR format '$input'. Expected e.g. 192.168.1.50 or 192.168.1.50/24" >&2
    exit 1
  fi

  IFS='.' read -r o1 o2 o3 o4 <<< "$ip_part"

  # Validate octets in 0-255
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    if (( octet < 0 || octet > 255 )); then
      echo "Error: Invalid IP octet '$octet' in '$ip_part'." >&2
      exit 1
    fi
  done

  IP_BASE="$o1.$o2.$o3"
  LAST_OCTET="$o4"
  CIDR="$cidr_part"
}

# ----- Check IP Range for Overflows -----
check_ip_range() {
  local start_octet=$1
  local count=$2
  local netmask=$3
  # Simple /24 check
  if (( netmask >= 24 )); then
    local end_octet=$((start_octet + count - 1))
    if (( end_octet > 254 )); then
      echo "Error: Not enough IPs in the /${netmask} range for ${count} VMs. (Would exceed .254)" >&2
      exit 1
    fi
  fi
}

# ----- Parse CLI Arguments -----
while getopts "n:p:c:m:b:i:d:D:sh" opt; do
  case "$opt" in
    n) NUM_VMS="$OPTARG" ;;
    p) VM_PREFIX="$OPTARG" ;;
    c) CPU_CORES="$OPTARG"; FLAG_CPU_SET=true ;;
    m) RAM="$OPTARG"; FLAG_RAM_SET=true ;;
    b) NET_BRIDGE="$OPTARG"; FLAG_BRIDGE_SET=true ;;
    i) USE_STATIC_IP=true; FIRST_IP="$OPTARG" ;;
    d) EXTRA_DISK="$OPTARG" ;;
    D) DISK_DEVICE="$OPTARG"; FLAG_DISK_DEVICE_SET=true ;;
    s) ENABLE_SNAPSHOT=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

# ----- Validate Required Args -----
if [[ -z "$NUM_VMS" || -z "$VM_PREFIX" ]]; then
  echo "Error: -n (num_vms) and -p (prefix) are required."
  usage
fi

if ! [[ "$NUM_VMS" =~ ^[0-9]+$ ]] || (( NUM_VMS < 1 )); then
  echo "Error: -n must be a positive integer." >&2
  exit 1
fi

# ----- Validate EXTRA_DISK if Specified -----
if [[ -n "$EXTRA_DISK" ]]; then
  if ! [[ "$EXTRA_DISK" =~ ^[0-9]+[mMgG]$ ]]; then
    echo "Error: invalid extra disk space format '$EXTRA_DISK'. Expected format examples: 10G, 512M." >&2
    exit 1
  fi
fi

# ----- Possibly Ask for Override if Not Set by Flags -----
# 1) CPU
if [[ "$FLAG_CPU_SET" == "false" ]]; then
  echo "Default CPU cores is $DEFAULT_CPU_CORES."
  read -rp "Would you like to override the default CPU cores? (y/N): " ans
  ans="${ans,,}"
  if [[ "$ans" == "y" ]]; then
    read -rp "Enter new CPU core count: " user_cpu
    if ! [[ "$user_cpu" =~ ^[0-9]+$ ]] || (( user_cpu < 1 )); then
      echo "Error: CPU cores must be a positive integer."
      exit 1
    fi
    CPU_CORES="$user_cpu"
    FLAG_CPU_SET=true
  fi
fi

# 2) RAM
if [[ "$FLAG_RAM_SET" == "false" ]]; then
  echo "Default RAM is $DEFAULT_RAM (e.g., 4096 MB)."
  read -rp "Would you like to override the default RAM? (y/N): " ans
  ans="${ans,,}"
  if [[ "$ans" == "y" ]]; then
    read -rp "Enter new RAM (e.g., 2048, 512M, 2G): " user_ram
    RAM="$user_ram"
    FLAG_RAM_SET=true
  fi
fi

# 3) Bridge
if [[ "$FLAG_BRIDGE_SET" == "false" ]]; then
  echo "Default network bridge is '$DEFAULT_NET_BRIDGE'."
  read -rp "Would you like to override the default bridge? (y/N): " ans
  ans="${ans,,}"
  if [[ "$ans" == "y" ]]; then
    read -rp "Enter new bridge name (e.g., vmbr0): " user_bridge
    NET_BRIDGE="$user_bridge"
    FLAG_BRIDGE_SET=true
  fi
fi

# 4) Disk Device
if [[ "$FLAG_DISK_DEVICE_SET" == "false" ]]; then
  echo "Default disk device is '$DEFAULT_DISK_DEVICE'."
  read -rp "Would you like to override the default disk device? (y/N): " ans
  ans="${ans,,}"
  if [[ "$ans" == "y" ]]; then
    read -rp "Enter new disk device (e.g., scsi0, virtio0): " user_drive
    DISK_DEVICE="$user_drive"
    FLAG_DISK_DEVICE_SET=true
  fi
fi

# ----- Validate CPU & RAM (Now That We Possibly Overrode) -----
if ! [[ "$CPU_CORES" =~ ^[0-9]+$ ]] || (( CPU_CORES < 1 )); then
  echo "Error: CPU cores must be a positive integer." >&2
  exit 1
fi
if (( CPU_CORES > MAX_CPU_CORES )); then
  echo "Error: CPU cores cannot exceed $MAX_CPU_CORES." >&2
  exit 1
fi

RAM_MB=$(parse_memory_mb "$RAM")
if (( RAM_MB < MIN_RAM_MB || RAM_MB > MAX_RAM_MB )); then
  echo "Error: Memory must be between ${MIN_RAM_MB}MB and ${MAX_RAM_MB}MB (inclusive)." >&2
  exit 1
fi

# ----- Check Proxmox API -----
if ! pvesh get /nodes/"$(hostname)"/status &>/dev/null; then
  echo "Error: Proxmox API is not responding. Check node status."
  exit 1
fi

# ----- Gather Existing VM IDs -----
EXISTING_VMS=$(qm list | awk 'NR>1 {print $1}')

# ----- Find Available Contiguous Block -----
find_available_start_id() {
  local id=$START_ID
  while true; do
    local conflict=0
    for ((i=0; i<NUM_VMS; i++)); do
      if echo "$EXISTING_VMS" | grep -q "^$((id + i))$"; then
        conflict=1
        break
      fi
    done
    if [[ $conflict -eq 0 ]]; then
      echo "$id"
      return
    fi
    ((id++))
  done
}

NEW_START_ID=$(find_available_start_id)
if [[ $NEW_START_ID -ne $START_ID ]]; then
  echo "WARNING: VM IDs in range $START_ID - $((START_ID + NUM_VMS - 1)) are in use."
  echo "Suggested new starting ID: $NEW_START_ID"
  read -rp "Enter a new starting VM ID (or press Enter to use $NEW_START_ID): " USER_NEW_START_ID
  START_ID="${USER_NEW_START_ID:-$NEW_START_ID}"
fi

# ----- Snapshot if Enabled -----
if [[ "$ENABLE_SNAPSHOT" == "true" ]]; then
  SNAP_NAME="pre-clone-$(date +%Y%m%d-%H%M%S)"
  echo "Creating snapshot '$SNAP_NAME' on template ID $TEMPLATE_ID..."
  qm snapshot "$TEMPLATE_ID" "$SNAP_NAME"
  echo "Snapshot $SNAP_NAME created."
fi

# ----- Static IP Handling -----
CIDR=24
if [[ "$USE_STATIC_IP" == "true" ]]; then
  parse_ip_cidr "$FIRST_IP"  # sets IP_BASE, LAST_OCTET, CIDR
  check_ip_range "$LAST_OCTET" "$NUM_VMS" "$CIDR"
fi

# ----- Determine "Origin" Strings for Summary -----
cpu_origin="(default)"
ram_origin="(default)"
bridge_origin="(default)"
disk_origin="(default)"

$FLAG_CPU_SET && cpu_origin="(user-specified)"
$FLAG_RAM_SET && ram_origin="(user-specified)"
$FLAG_BRIDGE_SET && bridge_origin="(user-specified)"
$FLAG_DISK_DEVICE_SET && disk_origin="(user-specified)"

# ----- Final Summary Before Proceeding -----
echo ""
echo "==================  SUMMARY  =================="
echo "VMs to create: $NUM_VMS"
echo "VM name prefix: $VM_PREFIX"
echo "Starting VM ID: $START_ID"
echo "Template ID:    $TEMPLATE_ID"
echo ""
echo "Hardware specs for each VM:"
echo "  CPU cores:   $CPU_CORES $cpu_origin"
echo "  RAM:         ${RAM_MB}MB $ram_origin"
echo "  Bridge:      $NET_BRIDGE $bridge_origin"
if [[ -n "$EXTRA_DISK" ]]; then
  echo "  Extra disk:  $EXTRA_DISK on device $DISK_DEVICE"
else
  echo "  Extra disk:  None"
fi
echo ""
if [[ "$USE_STATIC_IP" == "true" ]]; then
  echo "Using static IP. First IP: $IP_BASE.$LAST_OCTET/$CIDR"
  echo "IPs will increment last octet by 1 for each subsequent VM."
else
  echo "Network config: DHCP"
fi
echo "-----------------------------------------------"
echo "The following VMs will be created:"
for (( i=1; i<=NUM_VMS; i++ )); do
  local_id=$((START_ID + i - 1))
  name="${VM_PREFIX}-${i}"
  if [[ "$USE_STATIC_IP" == "true" ]]; then
    ip="${IP_BASE}.$((LAST_OCTET + i - 1))/$CIDR"
    echo "  - $name (VM ID: $local_id, IP: $ip)"
  else
    echo "  - $name (VM ID: $local_id, IP: DHCP)"
  fi
done
echo "==============================================="

read -rp "Proceed with VM creation? (y/N): " CONFIRM
CONFIRM="${CONFIRM,,}"
if [[ "$CONFIRM" != "y" ]]; then
  echo "Operation canceled."
  exit 1
fi

# ----- Create VMs in a Loop -----
for (( i=1; i<=NUM_VMS; i++ )); do
  VM_ID=$((START_ID + i - 1))
  VM_NAME="${VM_PREFIX}-${i}"

  echo -ne "Cloning VM $VM_ID ($VM_NAME)... "
  if qm clone "$TEMPLATE_ID" "$VM_ID" --name "$VM_NAME" --full true --storage "$STORAGE" &>/dev/null; then
    echo "Done"
  else
    echo "Failed"
    exit 1
  fi

  # Set CPU & RAM
  qm set "$VM_ID" --memory "$RAM_MB" --cores "$CPU_CORES" &>/dev/null
  qm set "$VM_ID" --net0 "virtio,bridge=$NET_BRIDGE" &>/dev/null

  # IP Configuration
  if [[ "$USE_STATIC_IP" == "true" ]]; then
    vm_ip="${IP_BASE}.$((LAST_OCTET + i - 1))"
    # Assume gateway is .1
    gateway="${IP_BASE}.1"
    qm set "$VM_ID" --ipconfig0 "ip=${vm_ip}/${CIDR},gw=${gateway}" &>/dev/null
  else
    qm set "$VM_ID" --ipconfig0 "ip=dhcp" &>/dev/null
  fi

  # Resize Disk if EXTRA_DISK is Specified
  if [[ -n "$EXTRA_DISK" ]]; then
    # Ensure the size argument starts with a plus sign (e.g., "+10G")
    if [[ "$EXTRA_DISK" =~ ^\+ ]]; then
      SIZE_ARG="$EXTRA_DISK"
    else
      SIZE_ARG="+$EXTRA_DISK"
    fi
    echo -ne "Resizing disk for VM $VM_ID ($VM_NAME)... "
    if qm resize "$VM_ID" "$DISK_DEVICE" "$SIZE_ARG" &>/dev/null; then
      echo "Done"
    else
      echo "Failed"
      exit 1
    fi
  fi

  # Start the VM
  qm start "$VM_ID" &>/dev/null
  echo "VM $VM_ID ($VM_NAME) created and started."
done

echo "Batch VM creation complete."
