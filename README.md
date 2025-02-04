# Proxmox VM Batch Creation Script

This Bash script automates the creation of multiple virtual machines (VMs) on a Proxmox VE host. It supports:

- Cloning from a template (with optional snapshot creation).
- Incrementing VM IDs in a contiguous block.
- Interactive prompts for setting CPU, memory, network, and disk device if flags are omitted.
- Static IP assignment with basic IP/CIDR validation.
- Optional disk resizing with configurable disk device selection.
- Safe input validation to prevent misconfigurations.

## Features

✅ **Minimal Arguments:** Only `-n` (number of VMs) and `-p` (name prefix) are required.  
✅ **Interactive Prompts:** If CPU, memory, network bridge, or disk device are not provided via flags, the script prompts for input.  
✅ **Automatic Range Checking:**
   - Ensures a contiguous set of VM IDs is available.
   - Validates CPU core count (default upper bound: 32).
   - Validates memory size (default upper bound: 32GB).
   - Checks IP overflow if static IPs in a `/24` range are specified.
  
✅ **Flexible Disk Resizing:** Optionally add extra storage to VMs, with the ability to select a custom disk device (`scsi0`, `virtio0`, etc.).  
✅ **Optional Snapshot:** Pass `-s` to snapshot the template before cloning.  
✅ **Confirmation Step:** Prints a summary of planned VMs (IDs, IPs, and resource config) before creation.  

## Requirements

- **Proxmox VE 6.0+** (tested on modern versions)
- **Bash** (the script uses Bash-specific features)
- **Sufficient permissions** to run `qm` and `pvesh` commands on the Proxmox host
- **A template VM** already configured and set as a template (default ID: `5000`, but can be changed in the script)

## Usage

```sh
./vm-batch-creator-proxmox.sh -n <num_vms> -p <prefix> [options]
```

### Required Flags

| Flag      | Description                                                    |
|-----------|----------------------------------------------------------------|
| `-n NUM`  | Number of VMs to create.                                       |
| `-p PREFIX` | Name prefix (e.g., `ansible` → `ansible-1`, `ansible-2`, etc.). |

### Optional Flags

| Flag       | Description                                                                                                       |
|------------|-------------------------------------------------------------------------------------------------------------------|
| `-c CPU`   | CPU cores per VM (default: `2`).                                                                                  |
| `-m RAM`   | RAM per VM (e.g., `2048`, `512M`, `2G`).                                                                           |
| `-b BRIDGE`| Network bridge (default: `vmbr1`).                                                                                |
| `-i IP/CIDR`| First static IP with optional CIDR (e.g., `192.168.10.50/24`). Each subsequent VM increments the last octet.     |
| `-d DISK`  | **Extra disk space** to add to the VM's primary disk (e.g., `10G`, `512M`). By default, resizes `scsi0`.         |
| `-D DEVICE` | **Disk device to resize** (default: `scsi0`). Use `virtio0`, `ide0`, etc., if necessary.                         |
| `-s`       | Create a snapshot of the template before cloning.                                                                 |
| `-h`       | Show help message.                                                                                                |

## Examples

### Example 1: Minimal (with Defaults)

```sh
./vm-batch-creator-proxmox.sh -n 3 -p ansible
```

Creates **3 VMs**: `ansible-1`, `ansible-2`, `ansible-3`.
- Uses default **CPU cores (2)**, **memory (4096 MB)**, **network bridge (vmbr1)**.
- Interactively asks if you want to override CPU, RAM, bridge, or disk device (default answer: `no`).
- Uses **DHCP networking**.

### Example 2: Static IPs and Custom Resources

```sh
./vm-batch-creator-proxmox.sh -n 2 -p test -c 4 -m 8G -b vmbr0 -i 192.168.1.100/24
```

Creates **2 VMs**: `test-1`, `test-2`.
- **CPU:** `4 cores`
- **RAM:** `8GB`
- **Bridge:** `vmbr0`
- **IP Addresses:** `192.168.1.100`, `192.168.1.101`

### Example 3: Snapshot Before Cloning

```sh
./vm-batch-creator-proxmox.sh -n 5 -p node -s
```

Creates **5 VMs** (`node-1` to `node-5`) **after creating a snapshot of the template**.

### Example 4: Add Extra Disk Space

```sh
./vm-batch-creator-proxmox.sh -n 3 -p ansible -d 10G
```

Creates **3 VMs** (`ansible-1`, `ansible-2`, `ansible-3`) and **adds 10G** to the **primary disk** (`scsi0`) on each VM.

### Example 5: Resize a Different Disk Device

```sh
./vm-batch-creator-proxmox.sh -n 2 -p dev -d 20G -D virtio0
```

Creates **2 VMs** (`dev-1`, `dev-2`) and **adds 20G** to the **virtio0 disk** on each VM.

## Notes

- The script will **validate inputs** to ensure safe provisioning.
- **Interactive mode** allows for quick provisioning with minimal flags.
- If resizing disk (`-d`) is used, the script assumes the **primary disk** is `scsi0` by default. You can change this using the `-D` flag.
- Ensure your **template VM** has the necessary configurations (SSH keys, cloud-init, etc.) for successful deployment.

## License

This script is released under the **MIT License**.

---

### 📢 Feedback & Contributions
If you find any bugs or have suggestions for improvements, feel free to open an **issue** or submit a **pull request** on GitHub! 🚀

