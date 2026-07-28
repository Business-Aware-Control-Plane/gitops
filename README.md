# RideShare GitOps Repository

This repository manages the deployments and configurations for the RideShare microservices platform across **development** (local Minikube/k3d cluster) and **production** (cloud cluster) environments using **ArgoCD** and **Helm**.

Repository: `https://github.com/Business-Aware-Control-Plane/gitops.git`

---

## Architecture Overview

This repository uses a modular **App-of-Apps** pattern with clear domain boundaries:

```text
gitops/
├── bootstrap/                    # Platform & system bootstrap
│   └── projects/
│       ├── development.yaml      # ArgoCD AppProject for Dev Cluster
│       └── production.yaml       # ArgoCD AppProject for Prod Cluster
│
├── charts/                       # Shared Helm charts
│   ├── rideshare-service/        # Shared Helm chart for microservices
│   ├── rabbitmq/                 # StatefulSet Helm chart
│   ├── jaeger/                   # Deployment Helm chart
│   └── namespaces/               # Declarative namespaces Helm chart
│
├── applications/                 # ArgoCD Application CRDs split by domain
│   ├── system/
│   │   └── namespaces.yaml       # ← Declarative namespace management!
│   ├── platform-services/
│   │   └── rabbitmq.yaml
│   ├── observability/
│   │   └── jaeger.yaml
│   └── services/
│       ├── api-gateway.yaml
│       ├── trip-service.yaml
│       ├── driver-service.yaml
│       ├── payment-service.yaml
│       └── web.yaml
│
├── clusters/                     # Environment configuration values & Root Apps
│   ├── development/
│   │   ├── root.yaml             # Single Root App watching applications/ recursively
│   │   └── values/
│   └── production/
│       ├── root.yaml
│       └── values/
│
└── policies/                     # Reserved for Kyverno / OPA policies
```

---

## Namespace Strategy

Since development and production run in dedicated, separate Kubernetes clusters, namespaces are simplified without environment suffixes:

| Domain | Namespace | Description |
|---|---|---|
| Business Microservices | `rideshare` | `api-gateway`, `trip-service`, `driver-service`, `payment-service`, `web` |
| Platform Services | `platform` | `rabbitmq` |
| Observability | `observability` | `jaeger` |
| System / Bootstrap | `argocd` | ArgoCD Server, Controller, AppProjects |

---

## Bootstrap Guide (Development Cluster)

### Step 1: Create Cluster & Namespaces

Create the target namespaces in your cluster:
```bash
kubectl create namespace argocd
kubectl create namespace rideshare
kubectl create namespace platform
kubectl create namespace observability
```

---

### Step 2: Install ArgoCD

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

---

### Step 3: Inject Secrets & Repository Credentials

1. **ArgoCD Repository Access (for Private GitOps Repos)**:
   ```bash
   kubectl create secret generic repo-gitops \
     --from-literal=url=https://github.com/Business-Aware-Control-Plane/gitops.git \
     --from-literal=username=<YOUR_GITHUB_USERNAME> \
     --from-literal=password=<YOUR_GITHUB_PAT> \
     -n argocd
   kubectl label secret repo-gitops -n argocd "argocd.argoproj.io/secret-type=repository"
   ```

2. **Application Secrets**:
   ```bash
   # RabbitMQ credentials (in platform namespace for StatefulSet)
   kubectl create secret generic rabbitmq-credentials \
     --from-literal=username=guest \
     --from-literal=password=guest \
     --from-literal=uri=amqp://guest:guest@rabbitmq.platform.svc.cluster.local:5672/ \
     -n platform

   # RabbitMQ credentials (in rideshare namespace for microservice consumption)
   kubectl create secret generic rabbitmq-credentials \
     --from-literal=uri=amqp://guest:guest@rabbitmq.platform.svc.cluster.local:5672/ \
     -n rideshare

   # Stripe Secrets
   kubectl create secret generic stripe-secrets \
     --from-literal=stripe-secret-key="sk_test_..." \
     --from-literal=stripe-webhook-key="whsec_..." \
     -n rideshare
   ```

3. **CloudNativePG PostgreSQL Secret Sync**:
   Once CloudNativePG operator initializes `postgres-cluster` in the `platform` namespace, dynamically bind its generated connection string to the `rideshare` namespace:
   ```bash
   POSTGRES_URI=$(kubectl get secret postgres-cluster-app -n platform -o jsonpath='{.data.uri}' | base64 -d)
   kubectl create secret generic postgres-cluster-app \
     --from-literal=uri="${POSTGRES_URI}?sslmode=disable" \
     -n rideshare --dry-run=client -o yaml | kubectl apply -f -
   ```

---

### Step 4: Deploy the AppProject & Root Application

1. Apply the Development AppProject:
   ```bash
   kubectl apply -f bootstrap/projects/development.yaml
   ```

2. Deploy the Root Application for **Development**:
   ```bash
   kubectl apply -f clusters/development/root.yaml
   ```

3. ArgoCD will discover the Root App (`dev-root`), scan the `applications/` folder recursively, and sync all child applications to your cluster automatically!

---

### Troubleshooting & Environment Notes

- **Docker Desktop DNS Timeout (`github.com` resolution fail)**:
  If `argocd-repo-server` fails with DNS `i/o timeout`, update the CoreDNS ConfigMap to forward upstream queries to public DNS (`1.1.1.1` / `8.8.8.8`):
  ```bash
  kubectl get cm coredns -n kube-system -o json | jq '.data.Corefile |= gsub("forward . /etc/resolv.conf"; "forward . 1.1.1.1 8.8.8.8 /etc/resolv.conf")' | kubectl apply -f -
  kubectl rollout restart deployment coredns -n kube-system
  ```

---

## GitOps Developer Workflow (CI/CD Tag Bumps)

To deploy new versions of a microservice:

1. A code change is committed to the application repository.
2. The CI pipeline builds the Docker image and tags it using `MAJOR.MINOR.PATCH+<commit-sha>` (e.g. `1.0.0+a3f9c12`).
3. The CI pipeline updates the `image.tag` key inside the corresponding service values file:
   - Development: `clusters/development/values/applications/<service-name>.yaml`
   - Production: `clusters/production/values/applications/<service-name>.yaml`
4. The CI pipeline commits and pushes the change to this GitOps repository.
5. ArgoCD detects the change, marks the application `OutOfSync`, and performs a rolling update automatically.
