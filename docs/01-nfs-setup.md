# Setting Up an NFS Server

The backup system needs an NFS share accessible from all cluster nodes.
VolSync mover pods mount this share to read/write Kopia repositories.

## Ubuntu / Debian

```bash
# Install NFS server
sudo apt update && sudo apt install -y nfs-kernel-server

# Create backup directory
sudo mkdir -p /mnt/backup/volsync
sudo chown 568:568 /mnt/backup/volsync

# Export the directory
echo '/mnt/backup/volsync *(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports

# Apply and start
sudo exportfs -ra
sudo systemctl enable --now nfs-kernel-server

# Verify
showmount -e localhost
```

## TrueNAS (SCALE or CORE)

1. Go to **Shares > Unix Shares (NFS) > Add**
2. Set path: `/mnt/YourPool/volsync`
3. Enable **Mapall User** = `568`, **Mapall Group** = `568`
4. Under **Advanced Options**: check **No Root Squash**
5. Under **Networks**: add your cluster subnet (e.g., `192.168.1.0/24`)
6. Save and verify the service is running under **Services > NFS**

## Synology DSM

1. Go to **Control Panel > Shared Folder > Create**
2. Name: `volsync`, Location: choose a volume
3. Go to **Control Panel > File Services > NFS**
4. Enable NFS, set max protocol to NFSv4.1
5. Edit the shared folder permissions:
   - Add your cluster subnet
   - Check **Allow connections from non-privileged ports**
   - Set **Squash** to `Map all users to admin`

## Windows (WSL2 / Hanewin)

Not recommended for production. For testing:

```bash
# In WSL2:
sudo apt install nfs-kernel-server
sudo mkdir -p /mnt/backup/volsync
sudo chown 568:568 /mnt/backup/volsync
echo '/mnt/backup/volsync *(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports
sudo exportfs -ra
sudo service nfs-kernel-server start
```

## Verify from Cluster Node

```bash
# SSH into a cluster node (or use talosctl)
# Test NFS mount:
mount -t nfs 192.168.1.100:/mnt/backup/volsync /mnt/test
ls -la /mnt/test
umount /mnt/test
```

## What Gets Stored

```
/mnt/backup/volsync/
└── kopia.repository.f    # Kopia repository metadata
└── p*/                   # Content-addressed deduplicated blocks
└── n*/                   # Index files
```

- All namespaces share one Kopia repository
- Data is encrypted with KOPIA_PASSWORD
- Snapshots are tagged per `{namespace}/{pvc-name}`
- Deduplication typically achieves 10-100x compression
