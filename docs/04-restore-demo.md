# Demo: Automatic Restore

This is the **killer feature** — when a PVC is created and a backup exists, the data is automatically restored. No manual intervention.

## Scenario: Simulate Disaster Recovery

### 1. Confirm Backup Exists

First, make sure a backup has completed for Karakeep:

```bash
# Check that backup has run at least once
kubectl get replicationsource -n karakeep
# Look for "lastSyncTime" in the status

# Or check PVC Plumber directly
kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- \
  curl http://pvc-plumber.volsync-system.svc.cluster.local/exists/karakeep/data-pvc
# Should return: {"exists": true, "snapshots": N}
```

### 2. Delete the PVC (Simulating Data Loss)

```bash
# Delete the Karakeep data PVC
kubectl delete pvc data-pvc -n karakeep

# The deployment will crash (expected)
kubectl get pods -n karakeep
```

### 3. Recreate the PVC

Apply the same PVC manifest (or let ArgoCD recreate it):

```bash
# ArgoCD will detect the missing PVC and recreate it
# OR manually apply:
kubectl apply -f my-apps/media/karakeep/karakeep/pvc-data.yaml
```

### 4. Watch the Auto-Restore

```bash
# Kyverno intercepts the PVC CREATE
# 1. Calls PVC Plumber: "Does backup exist?" → YES
# 2. Mutates PVC: adds dataSourceRef pointing to ReplicationDestination
# 3. VolSync VolumePopulator restores data from Kopia

# Watch the PVC — it will go through Pending → Bound
kubectl get pvc data-pvc -n karakeep -w

# Check the PVC spec — Kyverno added the dataSourceRef
kubectl get pvc data-pvc -n karakeep -o yaml | grep -A 4 dataSourceRef

# Watch the restore job
kubectl get pods -n karakeep -l app.kubernetes.io/created-by=volsync -w
```

### 5. Verify Data Restored

```bash
# Karakeep should be running with restored data
kubectl get pods -n karakeep

# Access the app — all bookmarks/data should be present
kubectl port-forward svc/karakeep-web -n karakeep 3000:3000
# Open http://localhost:3000
```

## What Happened Under the Hood

```
1. PVC CREATE request arrives at API server
2. Kyverno admission webhook intercepts
3. Rule 0: GET /readyz → PVC Plumber healthy ✓
4. Rule 1: GET /exists/karakeep/data-pvc → {"exists": true} ✓
5. Kyverno MUTATES the PVC spec:
   dataSourceRef:
     apiGroup: volsync.backube
     kind: ReplicationDestination
     name: data-pvc-backup
6. Kubernetes creates the PVC with the dataSourceRef
7. VolSync VolumePopulator kicks in:
   - Creates a mover pod
   - Kyverno injects NFS mount (volsync-nfs-inject policy)
   - Kopia restores latest snapshot from NFS
   - PVC is populated with data
8. PVC becomes Bound
9. App pod starts with all data restored
```

## The Fail-Closed Gate

What if PVC Plumber is down during disaster recovery?

```bash
# Scale down PVC Plumber to simulate failure
kubectl scale deployment pvc-plumber -n volsync-system --replicas=0

# Try to create a backup-labeled PVC
kubectl apply -f my-apps/media/karakeep/karakeep/pvc-data.yaml
# ERROR: PVC Plumber is not available. Backup-labeled PVCs cannot be created...

# ArgoCD retries automatically (5s → 10s → 20s → 40s → 3m)
# Once Plumber is back:
kubectl scale deployment pvc-plumber -n volsync-system --replicas=2

# PVC creation succeeds on next retry, with data restored
```

This prevents apps from deploying with **empty data** when backups exist but the checker is temporarily down.
