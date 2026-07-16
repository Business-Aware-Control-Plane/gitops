# RideShare GitOps Repository

This repository manages the deployments and configurations for the RideShare microservices platform across **development** (local/Minikube/k3d) and **production** environments using **ArgoCD** and **Helm**.

---

## Architecture Overview

This project is organized around the **App-of-Apps** pattern and is separated into distinct operational domains:

- **`charts/`**: Unified Helm charts for all services (`rideshare-service`, `rabbitmq`, `jaeger`).
- **`clusters/`**: Configuration values and environment mapping files per environment.
  - `clusters/development/`: Local cluster values (e.g. Minikube/k3d) and root App-of-Apps.
  - `clusters/production/`: Production cluster values and root App-of-Apps.
- **`argocd/`**: Scoping and permissions manifests.

---

## Prerequisites

1. A Kubernetes cluster (e.g., Minikube, k3d, GKE).
2. `kubectl` CLI installed and configured.
3. `helm` CLI installed.
4. **ArgoCD** installed in the `argocd` namespace:
   ```bash
   kubectl create namespace argocd
   kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
   ```

---

## Bootstrap Guide

### Step 1: Create Namespaces

First, create the namespaces targetted by the environments:

**Development:**
```bash
kubectl create namespace rideshare-dev
kubectl create namespace platform-dev
kubectl create namespace observability-dev
```

**Production:**
```bash
kubectl create namespace rideshare-prod
kubectl create namespace platform-prod
```

---

### Step 2: Inject Secrets Manually

Secrets are not stored in Git for security. You must manually apply them to the target namespaces before syncing applications.

#### Inject Secrets for Development (`rideshare-dev`):

```bash
# RabbitMQ credentials
kubectl create secret generic rabbitmq-credentials \
  --from-literal=username=guest \
  --from-literal=password=guest \
  --from-literal=uri=amqp://guest:guest@rabbitmq.platform-dev.svc.cluster.local:5672/ \
  -n platform-dev

kubectl create secret generic rabbitmq-credentials \
  --from-literal=uri=amqp://guest:guest@rabbitmq.platform-dev.svc.cluster.local:5672/ \
  -n rideshare-dev

# Stripe Secrets
kubectl create secret generic stripe-secrets \
  --from-literal=stripe-secret-key="sk_test_..." \
  --from-literal=stripe-webhook-key="whsec_..." \
  -n rideshare-dev

# MongoDB Connection String (Atlas/External URI)
kubectl create secret generic mongodb \
  --from-literal=uri="mongodb+srv://..." \
  -n rideshare-dev
```

#### Inject Secrets for Production (`rideshare-prod`):

Apply similar secrets to the `rideshare-prod` and `platform-prod` namespaces using production-specific values.

---

### Step 3: Deploy the ArgoCD AppProject and Root App

Before deploying, you must replace `{{REPO_URL}}` in the root manifests with your actual Git repository URL (e.g., `https://github.com/your-username/rideshare-gitops.git`).

1. Deploy the AppProject:
   ```bash
   kubectl apply -f argocd/projects/rideshare.yaml
   ```

2. Deploy the Root Application for **Development**:
   ```bash
   kubectl apply -f clusters/development/root.yaml
   ```

3. ArgoCD will automatically pick up the root manifest, discover all child applications, and begin syncing them to the cluster!

---

## GitOps Developer Workflow (CI/CD Tag Bumps)

To deploy new versions of a microservice:

1. A code change is committed to the application repository.
2. The CI pipeline builds the Docker image and tags it using `MAJOR.MINOR.PATCH+<commit-sha>` (e.g. `1.0.0+a3f9c12`).
3. The CI pipeline updates the `image.tag` key inside the corresponding service values file in this repository:
   - Development: `clusters/development/values/applications/<service-name>.yaml`
   - Production: `clusters/production/values/applications/<service-name>.yaml`
4. The CI pipeline commits and pushes the change to this GitOps repository.
5. ArgoCD detects the change, marks the application `OutOfSync`, and performs a rolling update automatically.
