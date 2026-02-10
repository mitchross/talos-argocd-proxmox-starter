# Demo: Automatic Backup

This walkthrough demonstrates how adding a single label triggers the entire backup pipeline.

## What Happens When You Add `backup: "hourly"`

### 1. Observe Current State (Before)

```bash
# Karakeep PVCs should have the backup label
kubectl get pvc -n karakeep --show-labels

# Kyverno should have generated backup resources
kubectl get replicationsource,replicationdestination -n karakeep

# Check the generated Secret
kubectl get secret -n karakeep -l app.kubernetes.io/managed-by=kyverno
```

### 2. Understanding What Kyverno Generated

For each PVC with `backup: "hourly"`, Kyverno created:

```bash
# The credentials Secret (cloned from volsync-system/kopia-credentials)
kubectl get secret volsync-data-pvc -n karakeep -o yaml

# The backup schedule (ReplicationSource)
kubectl get replicationsource data-pvc-backup -n karakeep -o yaml

# The restore capability (ReplicationDestination)
kubectl get replicationdestination data-pvc-backup -n karakeep -o yaml
```

### 3. Wait for First Backup

The ReplicationSource won't be created until the PVC is 2+ hours old (prevents backing up empty data). Once it's created:

```bash
# Watch for backup jobs
kubectl get jobs -n karakeep -l app.kubernetes.io/created-by=volsync -w

# Check backup status
kubectl get replicationsource -n karakeep -o wide

# View mover pod logs (Kopia output)
kubectl logs -n karakeep -l app.kubernetes.io/created-by=volsync -c kopia --tail=20
```

### 4. Verify NFS Injection

Kyverno automatically injects the NFS volume into VolSync mover pods:

```bash
# Check that the mover job has the NFS mount
kubectl get jobs -n karakeep -l app.kubernetes.io/created-by=volsync -o yaml | grep -A 5 "nfs"
```

### 5. Try It Yourself: Add Backup to a New PVC

Create a test PVC:

```yaml
# test-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-backup
  namespace: default
  labels:
    backup: "daily"
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: longhorn
```

```bash
kubectl apply -f test-pvc.yaml

# Watch Kyverno generate resources (within seconds)
kubectl get secret,replicationsource,replicationdestination -n default -l volsync.backup/pvc=test-backup -w

# Clean up
kubectl delete pvc test-backup -n default
# Orphan cleanup will remove generated resources within 15 minutes
```

## Backup Schedule Reference

| Label Value | Schedule | Retention |
|-------------|----------|-----------|
| `backup: "hourly"` | Every hour (`0 * * * *`) | 24 hourly, 7 daily, 4 weekly, 2 monthly |
| `backup: "daily"` | Daily at 2am (`0 2 * * *`) | Same retention policy |
