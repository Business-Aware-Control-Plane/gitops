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

## Quick Start (Automated Lifecycle Script)

You can manage the entire local cluster lifecycle (creation, shutdown, ArgoCD setup, secret injection, image builds, and bootstrap) using the master `./cluster.sh` script in the root directory:

```bash
# Start/Create cluster, install ArgoCD, inject secrets, build & deploy all services
./cluster.sh start

# Check status of cluster, pods, and ArgoCD applications
./cluster.sh status

# Gracefully stop the cluster when not developing (frees up RAM & CPU)
./cluster.sh stop

# Restart cluster and re-sync all services
./cluster.sh restart
```

---

## Manual Bootstrap Guide (Development Cluster)

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

- **ArgoCD Applications stuck `Progressing`/`Degraded` forever on any Ingress-owning app** (found 2026-09-28 investigating a stuck `prometheus-stack` sync): ArgoCD's default Lua health check for `networking.k8s.io/Ingress` waits for `status.loadBalancer.ingress` to be populated — a real cloud load balancer would set this, but k3d's `nginx-ingress` never does, so the health check waits forever and blocks the whole sync (this was silently affecting `api-gateway`, `jaeger`, and `web` too — all three flipped from stuck `Progressing` to `Healthy` immediately once this was applied). Not tracked by this repo since ArgoCD's own config isn't GitOps-managed here — re-apply after any cluster rebuild:
  ```bash
  kubectl patch configmap argocd-cm -n argocd --type=merge -p '{"data":{"resource.customizations.health.networking.k8s.io_Ingress":"hs = {}\nhs.status = \"Healthy\"\nhs.message = \"Ingress assumed healthy -- this k3d cluster has no cloud load balancer to populate status.loadBalancer.ingress, which ArgoCD default health check waits on forever otherwise\"\nreturn hs\n"}}'
  ```
  If an Application is already stuck `Running` from before this was applied, clear its stuck operation once to let it pick up the new health check (`argocd app terminate-op <name>` via the ArgoCD CLI, or without it: `kubectl patch application <name> -n argocd --type=merge -p '{"status":{"operationState":null}}'` followed by `kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite`).

---

## Autoscaling experiments (INFRA-HB-01)

`charts/rideshare-service` ships an HPA template (`templates/hpa.yaml`) and a KEDA `ScaledObject`/`TriggerAuthentication` pair (`templates/scaledobject.yaml`, `templates/triggerauthentication.yaml`), both inert unless a service's values opt in (`autoscaling.enabled` / `keda.enabled` — the two are mutually exclusive; the chart fails the Helm render if both are set on one service). KEDA itself is installed as its own ArgoCD Application, `applications/platform-services/keda.yaml`.

Five comparable conditions (Test Plan Layer 3) live as small overlay files under `clusters/development/values/applications/api-gateway-condition-*.yaml` — static replicas (no overlay, today's actual config), HPA-CPU, HPA-CPU+memory, KEDA-RabbitMQ (`notify_driver_assign` queue depth), and KEDA-Prometheus (nginx-ingress request rate, needs Prometheus's storage fix live first). To run one:

1. Add the condition's overlay file as a second entry in `applications/services/api-gateway.yaml`'s `spec.source.helm.valueFiles` (after the base `api-gateway.yaml`).
2. Commit, push, let ArgoCD sync.
3. In `../loadtest/`: run `./watch-replicas.sh api-gateway rideshare <condition-label>` in one terminal, `k6 run --env BASE_URL=<api-gateway URL> ramp-to-spike.js` in another.
4. Remove the overlay entry and re-sync before switching to the next condition — conditions are run one at a time, not layered.

Full rationale, the exact metrics each condition is meant to produce, and the build sequence: see the INFRA-HB-01 blueprint.

## GitOps Developer Workflow (CI/CD Tag Bumps)

To deploy new versions of a microservice:

1. A code change is committed to the application repository.
2. The CI pipeline builds the Docker image and tags it using `MAJOR.MINOR.PATCH+<commit-sha>` (e.g. `1.0.0+a3f9c12`).
3. The CI pipeline updates the `image.tag` key inside the corresponding service values file:
   - Development: `clusters/development/values/applications/<service-name>.yaml`
   - Production: `clusters/production/values/applications/<service-name>.yaml`
4. The CI pipeline commits and pushes the change to this GitOps repository.
5. ArgoCD detects the change, marks the application `OutOfSync`, and performs a rolling update automatically.
