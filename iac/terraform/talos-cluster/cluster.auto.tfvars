# Fully populated cluster configuration (non-secret). Adjust as needed.
# Secrets (API token, SSH password) go ONLY in credentials.auto.tfvars.

# Talos ISOs uploaded to Proxmox ISO storage
# Confirm filenames match Proxmox storage list.
talos_iso_file = "local:iso/talos-1.11.iso"              # Standard Talos ISO
talos_gpu_iso_file = "local:iso/talos-1.11-gpu.iso"     # GPU-enabled Talos ISO (optional)

# Primary system disk datastore id (Proxmox storage ID)
# Choices visible on node: e.g. local, local-zfs, zfs1, zfs2, zfs3
disk_storage = "zfs1"

# Datastore for additional data disks (if nodes define additional_disk_size)
additional_disk_storage = "zfs2"

# Proxmox network bridge
network_bridge = "vmbr0"

# Cluster node definitions (MACs preserved for router/DHCP reservations)
# Fields:
# - vmid: unique VM ID per Proxmox node
# - role: controlplane | worker | worker-gpu (determines Talos extensions if you template later)
# - additional_disk_size: optional extra raw disk (size in G) for data/storage layers
# NOTE: Ensure IPs match your network plan and do not conflict.

nodes = [
  # Control Plane Node - Uses standard Talos ISO
  { 
    name = "talos-lab-master-00", 
    vmid = 2000, 
    role = "controlplane", 
    ip = "192.168.10.101", 
    cores = 6, 
    memory = 16000, 
    disk_size = "48G", 
    mac_address = "BC:24:21:A4:B2:97", 
    tags = ["talos", "controlplane"] 
  },
  
  # Regular Worker Node - Uses standard Talos ISO
  { 
    name = "talos-lab-worker-01", 
    vmid = 3001, 
    role = "worker", 
    ip = "192.168.10.211", 
    cores = 8, 
    memory = 18000, 
    disk_size = "64G", 
    additional_disk_size = "112G", 
    mac_address = "BC:24:21:4C:99:A2", 
    tags = ["talos", "worker"] 
  },
  
  # GPU Worker Node - Uses GPU-enabled Talos ISO (configure GPU passthrough in Proxmox UI)
  { 
    name = "talos-lab-gpu-worker-02", 
    vmid = 3002, 
    role = "worker-gpu", 
    ip = "192.168.10.213", 
    cores = 8, 
    memory = 18000, 
    disk_size = "64G", 
    additional_disk_size = "112G", 
    mac_address = "BC:24:21:AD:82:0D", 
    tags = ["talos", "worker-gpu"] 
  }
]

# After editing run:
# terraform plan -out .tfplan
# terraform apply .tfplan
