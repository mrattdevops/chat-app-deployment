# Kubernetes Deployment Guide

## 1. Architecture and prerequisites

The application runs on a Kind multi-node Kubernetes cluster with separate namespaces:

- `chat-app-dev`
- `chat-app-prod`

Application workloads are packaged as Helm charts. PostgreSQL and Redis are maintained as separate infrastructure charts.

Prerequisites on the deployment operator's workstation or runner:
- `kubectl`
- Helm
- access to the intended Kind cluster
- a valid kubeconfig
- required Kubernetes Secrets already created in the target namespace

Check tool versions and current context:

```bash
kubectl version --client
helm version
kubectl config current-context
kubectl get nodes
```

The lab's expected Kind context is:

```text
kind-multi-node-cluster
```

Do not deploy if the current context is not the intended cluster.

## 2. Repository layout

```text
chat-app-deployment/
├── .github/
│   └── workflows/
├── charts/
│   ├── chat-auth/
│   ├── chat-service/
│   ├── chat-realtime/
│   └── chat-frontend/
├── infrastructure/
│   ├── postgres/
│   └── redis/
└── docs/
```

Each application chart contains `Chart.yaml`, `templates/`, `values.yaml`, `values-dev.yaml`, and `values-prod.yaml`.

## 3. Namespace and prerequisites

Inspect namespaces:

```bash
kubectl get namespace chat-app-dev chat-app-prod
```

Inspect required Secrets without displaying their values:

```bash
kubectl get secrets -n chat-app-dev
kubectl get secrets -n chat-app-prod
```

The application charts reference pre-created Secrets for database connection strings and JWT secrets. PostgreSQL references a Secret containing `POSTGRES_PASSWORD`.

Create or synchronize these Secrets securely before deploying into a new namespace. Do not commit Secret values to Git.

Inspect persistent storage support:

```bash
kubectl get storageclass
kubectl get pvc -n chat-app-dev
kubectl get pvc -n chat-app-prod
```

The lab uses the `standard` StorageClass and local-path provisioning in Kind. This is suitable for the lab cluster, not a substitute for production-grade storage.

## 4. Validate Helm charts

Validate development values:

```bash
for chart in charts/*; do
  [ -f "$chart/Chart.yaml" ] || continue
  helm lint "$chart" -f "$chart/values-dev.yaml"
  helm template "$(basename "$chart")" "$chart" \
    -n chat-app-dev \
    -f "$chart/values-dev.yaml" > /dev/null
done
```

Validate production values:

```bash
for chart in charts/*; do
  [ -f "$chart/Chart.yaml" ] || continue
  helm lint "$chart" -f "$chart/values-prod.yaml"
  helm template "$(basename "$chart")" "$chart" \
    -n chat-app-prod \
    -f "$chart/values-prod.yaml" > /dev/null
done
```

Rendering templates validates the generated manifests; it does not prove that the application can connect to its dependencies or become healthy.

## 5. Deploy application charts

The GitHub Actions workflow is the normal deployment path. For a controlled lab operation, the equivalent Helm command for one development chart is:

```bash
helm upgrade --install chat-auth ./charts/chat-auth \
  --namespace chat-app-dev \
  -f ./charts/chat-auth/values-dev.yaml \
  --wait \
  --timeout 5m
```

For production, the corresponding chart values file and namespace are:

```bash
helm upgrade --install chat-auth ./charts/chat-auth \
  --namespace chat-app-prod \
  -f ./charts/chat-auth/values-prod.yaml \
  --wait \
  --timeout 5m
```

Use the production command only when intentionally performing a production deployment. The project's normal production process is a manual GitHub Actions workflow.

Repeat for the other application releases as required:
- `chat-service`
- `chat-realtime`
- `chat-frontend`

PostgreSQL and Redis are separate infrastructure releases. Do not reinstall or upgrade stateful infrastructure casually; review its values, PVCs, and data impact first.

## 6. Verify deployment

```bash
helm list -n chat-app-dev
kubectl get deployments,statefulsets,pods,services,pvc -n chat-app-dev
```

Production:

```bash
helm list -n chat-app-prod
kubectl get deployments,statefulsets,pods,services,pvc -n chat-app-prod
```

Check application images:

```bash
kubectl get deployments -n chat-app-dev \
  -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[*].image'
```

Check rollout status:

```bash
for app in chat-auth chat-service chat-realtime chat-frontend; do
  kubectl rollout status deployment/"$app" \
    -n chat-app-dev --timeout=120s || exit 1
done
```

Check logs for a workload:

```bash
kubectl logs -n chat-app-dev deployment/chat-auth \
  --all-containers=true --tail=100
```

## 7. Deployment safety

- Confirm the Kubernetes context before every manual deployment.
- Confirm the namespace and values file before running Helm.
- Confirm image tags exist in Docker Hub.
- Ensure required Secrets exist without printing their values.
- Review changes to PostgreSQL, PVCs, and storage settings separately.
- Keep production deployment manual as configured in this project.
- Do not use a local Kind cluster as evidence of production-grade high availability.
