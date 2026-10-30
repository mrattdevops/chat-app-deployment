# CI/CD Workflow

## Overview

This project uses a push-based GitOps-style deployment workflow with separate application and Kubernetes deployment repositories.

- **Application repository:** GitLab — `chat-app`
- **Deployment repository:** GitHub — `chat-app-deployment`
- **Container registry:** Docker Hub
- **CI:** GitLab CI/CD
- **CD:** GitHub Actions
- **Kubernetes:** Kind multi-node cluster
- **Deployment packaging:** Helm

This is not an Argo CD deployment. GitHub Actions applies Helm configuration to the cluster; continuous in-cluster reconciliation is not implemented.

## End-to-end flow

1. A developer pushes application code to the GitLab repository.
2. GitLab CI/CD runs the configured service tests and build jobs.
3. On the configured `main` branch, Docker images are built for the application services and tagged with `CI_COMMIT_SHORT_SHA`.
4. The images are pushed to Docker Hub.
5. The GitLab pipeline clones the GitHub deployment repository and updates the development image tags in the relevant Helm values files.
6. The pipeline commits and pushes the deployment configuration change to the deployment repository's `main` branch.
7. The GitHub Actions development workflow validates Helm charts, detects changed charts, and deploys them to `chat-app-dev`.
8. Production deployment is initiated manually through the production GitHub Actions workflow.

## Application services and image repositories

| Helm release / service | Image repository |
|---|---|
| `chat-auth` | `mrattdevops/chat-app-auth` |
| `chat-service` | `mrattdevops/chat-app-chat` |
| `chat-realtime` | `mrattdevops/chat-app-realtime` |
| `chat-frontend` | `mrattdevops/chat-app-frontend` |

Image tags use the short Git commit SHA. For example, `ca3801c8` identifies the application commit used for a build.

## GitLab CI/CD responsibilities

The application pipeline includes test jobs for the Go auth service, Go realtime service, Rust chat service, and frontend build. The build stage builds and pushes the four Docker images.

The GitOps update job:
- clones `mrattdevops/chat-app-deployment`;
- updates the development image tag values;
- commits the changes using a CI bot identity;
- pushes the update to the deployment repository.

The pipeline requires appropriately scoped GitLab CI/CD variables for registry authentication and GitHub repository access. Do not place token values in this document or commit them to either repository.

## GitHub Actions development deployment

The development workflow:
- validates charts with `helm lint` and `helm template`;
- uses a self-hosted macOS runner for cluster deployment;
- verifies the Kubernetes context is `kind-multi-node-cluster`;
- detects changed charts, with a fallback to all charts if the push event's previous commit is unavailable;
- runs `helm upgrade --install` for changed application charts in `chat-app-dev`;
- waits for Helm operations and verifies the deployment.

The deployment runner must have access to the intended kubeconfig and cluster. Keep the runner online and ensure its labels match the workflow's `runs-on` requirements.

## Development and production behavior

| Environment | Namespace | Trigger |
|---|---|---|
| Development | `chat-app-dev` | Automatically after eligible deployment-repository changes |
| Production | `chat-app-prod` | Manually triggered workflow |

The production workflow is manually triggered. Confirm its configured branch, runner labels, Kubernetes context checks, and Helm arguments in the repository before changing production deployment behavior.

## Operational checks

After a deployment, verify the Helm releases:

```bash
helm list -n chat-app-dev
helm list -n chat-app-prod
```

Check workload readiness:

```bash
kubectl get deployments,statefulsets,pods -n chat-app-dev
kubectl get deployments,statefulsets,pods -n chat-app-prod
```

Check the deployed application images:

```bash
kubectl get deployments -n chat-app-dev \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image'
```

For an individual deployment:

```bash
kubectl rollout status deployment/chat-auth \
  -n chat-app-dev --timeout=120s
```

## Important design note

This project is a push-based GitOps-style workflow: the deployment repository stores Helm desired configuration and GitHub Actions applies it. It does not currently use Argo CD or Flux for continuous reconciliation.
