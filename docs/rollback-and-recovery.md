# Helm Rollback and PostgreSQL Recovery

## Scope

This document records the rollback and logical database backup/restore exercises completed in the Kind chat application lab.

The exercises cover:
- Helm release history and manual rollback;
- recovery after a failed Helm upgrade;
- PostgreSQL custom-format logical backup;
- restore into an isolated test database;
- row-count and table-data checksum comparison;
- safe removal of the temporary restore database.

These tests do not constitute a complete production disaster recovery system. Off-cluster backup storage, retention, automated backup scheduling, separate-instance restore testing, and documented RPO/RTO targets remain future improvements.

## 1. Inspect Helm release history

```bash
helm history chat-auth -n chat-app-dev
```

Inspect the values of a particular revision:

```bash
helm get values chat-auth \
  -n chat-app-dev \
  --revision 6
```

Inspect the current release:

```bash
helm status chat-auth -n chat-app-dev
```

## 2. Manual Helm rollback

First inspect history and choose a known-good revision. Do not copy the example revision blindly; release history changes over time.

```bash
helm rollback chat-auth 6 \
  --namespace chat-app-dev \
  --wait \
  --timeout 5m
```

A rollback creates a new Helm revision. It does not erase the failed or superseded revisions from release history.

Verify:

```bash
helm history chat-auth -n chat-app-dev
kubectl rollout status deployment/chat-auth \
  -n chat-app-dev --timeout=120s
kubectl get deployment chat-auth -n chat-app-dev \
  -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[*].image'
```

The lab verified a rollback to the previous one-replica configuration while retaining the same image tag.

## 3. Failed deployment recovery

The lab simulated a failed upgrade and observed a failed Helm revision followed by a successful rollback revision.

Inspect the release history after an incident:

```bash
helm history chat-auth -n chat-app-dev
```

Then inspect the workload:

```bash
kubectl get pods -n chat-app-dev
kubectl describe deployment chat-auth -n chat-app-dev
kubectl logs -n chat-app-dev deployment/chat-auth --tail=100
```

Do not assume every failed deployment automatically rolls back. Confirm the actual Helm command and workflow behavior. Helm's `--atomic` option can enable automatic rollback on a failed upgrade; verify whether it is configured in the workflow before relying on it.

After recovery, compare the live deployment with the Git repository's desired values:

```bash
grep -A 3 '^image:' charts/chat-auth/values-dev.yaml
grep '^replicaCount:' charts/chat-auth/values-dev.yaml
```

A manual Helm rollback changes cluster release state; it does not automatically change the Git repository. In a GitOps-style workflow, reconcile the Git desired state deliberately to avoid a later deployment reapplying an unwanted configuration.

## 4. PostgreSQL backup

The lab PostgreSQL workload is the `postgres` StatefulSet in `chat-app-dev`. The database and user are `chatapp`.

Create a local backup directory:

```bash
mkdir -p ~/gitops-labs/backups/chat-app-dev
cd ~/gitops-labs/backups/chat-app-dev
```

Create a PostgreSQL custom-format backup on the local workstation:

```bash
kubectl exec -n chat-app-dev postgres-0 -- \
  pg_dump -U chatapp -d chatapp -Fc \
  > chatapp-dev-backup.dump
```

Do not allocate a TTY for binary dump output. The shell redirection writes the dump to the workstation, not into the Pod.

Inspect the archive using `pg_restore` inside the PostgreSQL Pod:

```bash
kubectl exec -i -n chat-app-dev postgres-0 -- \
  pg_restore -l < chatapp-dev-backup.dump | head -25
```

The lab archive was a custom-format backup from PostgreSQL 17.11 and contained the `public.users` table, table data, and its primary-key and unique constraints.

Calculate a checksum for the backup file:

```bash
shasum -a 256 chatapp-dev-backup.dump
```

Store backups securely. They may contain personal or application data. Do not commit database dumps to Git.

## 5. Restore into an isolated test database

Confirm whether the test database already exists:

```bash
kubectl exec -n chat-app-dev postgres-0 -- \
  psql -U chatapp -d postgres -Atc \
  "SELECT datname FROM pg_database WHERE datname = 'chatapp_restore_test';"
```

If it does not exist, create it:

```bash
kubectl exec -n chat-app-dev postgres-0 -- \
  createdb -U chatapp -T template0 chatapp_restore_test
```

Restore the local archive into the test database:

```bash
kubectl exec -i -n chat-app-dev postgres-0 -- \
  pg_restore \
    -U chatapp \
    -d chatapp_restore_test \
    --no-owner \
    --no-privileges \
    --exit-on-error \
  < chatapp-dev-backup.dump
```

List restored tables:

```bash
kubectl exec -n chat-app-dev postgres-0 -- \
  psql -U chatapp -d chatapp_restore_test -c '\dt'
```

## 6. Verify restored data

Compare row counts:

```bash
kubectl exec -n chat-app-dev postgres-0 -- \
  psql -U chatapp -d chatapp -c 'SELECT COUNT(*) FROM users;'

kubectl exec -n chat-app-dev postgres-0 -- \
  psql -U chatapp -d chatapp_restore_test \
  -c 'SELECT COUNT(*) FROM users;'
```

The completed lab observed three rows in each database.

Compare a deterministic checksum of the `users` table rows:

```bash
kubectl exec -n chat-app-dev postgres-0 -- \
  psql -U chatapp -d chatapp -Atc \
  "SELECT md5(COALESCE(string_agg(row_to_json(t)::text, ',' ORDER BY t.id), '')) FROM users t;"

kubectl exec -n chat-app-dev postgres-0 -- \
  psql -U chatapp -d chatapp_restore_test -Atc \
  "SELECT md5(COALESCE(string_agg(row_to_json(t)::text, ',' ORDER BY t.id), '')) FROM users t;"
```

The lab observed matching checksums:

```text
b2cab0510ed8aa8f9550a2088248e76e
```

This comparison verifies the selected `users` table row values at the time of comparison. It does not prove that every database object, permission, index, or application behavior has been tested.

## 7. Safe cleanup

Confirm the database names before deleting anything:

```bash
kubectl exec -n chat-app-dev postgres-0 -- \
  psql -U chatapp -d postgres -c \
  "SELECT datname FROM pg_database WHERE datname IN ('chatapp', 'chatapp_restore_test');"
```

Delete only the temporary test database:

```bash
kubectl exec -n chat-app-dev postgres-0 -- \
  dropdb -U chatapp chatapp_restore_test
```

Verify that the original database remains:

```bash
kubectl exec -n chat-app-dev postgres-0 -- \
  psql -U chatapp -d postgres -c \
  "SELECT datname FROM pg_database WHERE datname IN ('chatapp', 'chatapp_restore_test');"

kubectl exec -n chat-app-dev postgres-0 -- \
  psql -U chatapp -d chatapp -c 'SELECT COUNT(*) FROM users;'
```

The completed lab confirmed that only `chatapp` remained and its `users` table still contained three rows.

## 8. Recovery limitations and next improvements

The lab demonstrates a logical backup and restore on the same PostgreSQL instance and PVC. It does not protect against loss of the Kind cluster, host, or underlying storage.

Recommended next improvements for a production system:
- copy encrypted backups to off-cluster object storage;
- define backup frequency and retention;
- automate backup success/failure alerts;
- test restore to a separate PostgreSQL instance and storage volume;
- define and test Recovery Point Objective (RPO) and Recovery Time Objective (RTO);
- document database schema migration and compatibility procedures;
- protect production secrets and backup encryption keys.
