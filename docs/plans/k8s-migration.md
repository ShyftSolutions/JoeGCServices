# Kubernetes Migration Plan for JoeGCServices

## Goal

Create an alternative deployment path using Kubernetes (k3s) alongside the existing Docker Compose deployment. Includes a Helm chart, GitHub Actions CI for image builds, and support for horizontal scaling of the WMS and EDR API services.

## Scope

| Attribute | Value |
|---|---|
| Target platform | k3s (single-node) |
| Ingress controller | Traefik (k3s default) |
| Storage provisioner | local-path-provisioner (k3s default) |
| Deployment tooling | Helm 3 chart |
| Container registry | AWS ECR (711051230276, us-east-2), configurable |
| Monitoring | kube-prometheus-stack + loki-stack Helm charts |
| CI/CD | GitHub Actions (build + push), manual deploy (helm upgrade) |
| Coexistence | Docker Compose remains the primary dev/deploy path |

## Architecture

```
                      k3s cluster (single node)

Internet -> Traefik Ingress
              |-> /wms, /wmts, /api  -> wms-api (1-N pods)
              |-> /edr               -> edr-api (1-N pods)
              |-> /                  -> web-dashboard
              |-> /downloader        -> downloader

  data-pipeline pod (singleton):
    container: downloader --POST localhost:8082--> container: ingester
    shared emptyDir: /data/downloads

  postgres  <- StatefulSet (1 replica)
  redis     <- StatefulSet (1 replica)
  minio     <- StatefulSet (1 replica)
```

### Key Design Decisions

1. **Downloader + Ingester co-located** -- Share files via emptyDir, communicate on localhost:8082.
2. **WMS API scalable** -- ENABLE_CLEANUP/ENABLE_SYNC env vars control which replica runs background tasks. Dedicated cleanup pod when scaling.
3. **EDR API fully scalable** -- Stateless reads, no constraints.
4. **No autoheal** -- K8s liveness probes handle restarts natively.
5. **Same Dockerfiles** -- Chart coexists with Docker Compose, no image changes needed.

## Scaling Analysis

| Service | Scalable | Constraints |
|---------|----------|-------------|
| edr-api | Yes | Each replica has independent in-memory cache |
| wms-api | Yes (with caveats) | Cleanup/sync must run on one replica only |
| ingester | Yes (with caveats) | No deduplication; tied to downloader in same pod |
| downloader | No (singleton) | SQLite state DB, assumes single instance |

## Completed (Phases 0-3)

### Phase 0: Code Changes
- [x] ENABLE_CLEANUP/ENABLE_SYNC env vars already existed in WMS API
- [x] Fixed EDR API hardcoded `"config/edr"` path to use CONFIG_DIR env var
- [x] Verified ingester binds 0.0.0.0:8082, INGESTER_URL defaults to localhost:8082
- [x] Verified all config dirs < 1 MiB (total 816K)
- [x] Confirmed data/static is empty, wms-api doesn't read /data/downloads

### Phase 1: Helm Chart Scaffold
- [x] Chart.yaml, values.yaml, values-production.yaml
- [x] _helpers.tpl with image, label, URL helpers
- [x] NOTES.txt with post-install instructions

### Phase 2: Infrastructure Templates
- [x] ConfigMaps for models, layers, edr, styles (populated via .Files.Glob)
- [x] Secret with all credentials (stringData, no base64 encoding needed)
- [x] PostgreSQL StatefulSet + Service (PostGIS 16-3.4)
- [x] Redis StatefulSet + Service (conditional --requirepass)
- [x] MinIO StatefulSet + Service + post-install Job (bucket setup)

### Phase 3: Application Templates
- [x] Data Pipeline Deployment (2 containers, emptyDir shared volume, PVC for SQLite)
- [x] WMS API Deployment + Service + conditional cleanup Deployment
- [x] EDR API Deployment + Service
- [x] Web Dashboard Deployment + Service
- [x] HPA templates for wms-api and edr-api (disabled by default)
- [x] Ingress with path-based routing

## Remaining (Phases 3.5-7)

### Phase 3.5: Chart Hardening

Security and reliability fixes identified during code review. Should be
completed before any production deployment.

#### 3.5.1 — Redis probes must authenticate when password is set

**Problem:** The Redis StatefulSet liveness/readiness probes use
`redis-cli ping` without `-a $REDIS_PASSWORD`. When `--requirepass` is
configured (any production deploy), the probes will fail and Kubernetes
will restart the pod in a loop.

**Fix:** Use a shell-based probe that conditionally passes the auth flag:

```yaml
livenessProbe:
  exec:
    command:
      - /bin/sh
      - -c
      - |
        if [ -n "$REDIS_PASSWORD" ]; then
          redis-cli -a "$REDIS_PASSWORD" ping
        else
          redis-cli ping
        fi
```

**File:** `templates/redis/statefulset.yaml` (lines 44-61)

---

#### 3.5.2 — Add securityContext to all containers

**Problem:** No pod or container security contexts are set anywhere in
the chart. This means containers run as root with full capabilities,
which violates the principle of least privilege and many cluster
policies (e.g., Pod Security Standards "restricted" profile).

**Fix:** Add a default pod-level `securityContext` in `values.yaml` and
apply it in every deployment/statefulset template:

```yaml
# values.yaml
podSecurityContext:
  runAsNonRoot: true
  fsGroup: 1000

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: false   # some services write tmp files
  capabilities:
    drop: [ALL]
```

Then in each template's pod spec:

```yaml
spec:
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 8 }}
  containers:
    - name: ...
      securityContext:
        {{- toYaml .Values.containerSecurityContext | nindent 12 }}
```

**Notes:**
- `readOnlyRootFilesystem: true` can be enabled per-service where
  possible (edr-api, web-dashboard) but not for Postgres/Redis/MinIO
  which write to their data dirs outside the PVC mount.
- `runAsNonRoot` requires the container images to use a non-root user.
  Verify each Dockerfile sets `USER` before enabling.

**Files:** All templates in `templates/*/deployment.yaml`,
`templates/*/statefulset.yaml`, and `values.yaml`.

---

#### 3.5.3 — Pin MinIO image tags

**Problem:** `values.yaml` uses `minio/minio:latest` and
`minio/mc:latest`. The `latest` tag is mutable — a MinIO release could
introduce breaking changes (API, CLI flags, default config) that
silently break the deployment on the next pod restart or node drain.

**Fix:** Pin to specific release tags. As of this writing, recommended:

```yaml
minio:
  image: minio/minio:RELEASE.2024-11-07T00-52-20Z
  mcImage: minio/mc:RELEASE.2024-11-17T19-35-25Z
```

Pick the latest stable release from
https://github.com/minio/minio/releases and update periodically as a
deliberate maintenance task.

**File:** `values.yaml` (lines 218-219)

---

#### 3.5.4 — Confirm MinIO public bucket policy is intentional

**Problem:** `templates/minio/job-setup.yaml` runs
`mc anonymous set download minio/weather-data`, making the bucket
publicly readable. Anyone with network access to the MinIO service can
download all stored weather data.

**Current mitigation:** MinIO is not exposed via the Ingress, so it's
only reachable from within the cluster. This is acceptable for a
single-node k3s setup.

**Action items:**
- [ ] Confirm this is intentional (weather data is public domain, the
  services need unauthenticated S3 reads)
- [ ] If public access is NOT needed, change to `mc anonymous set none`
  and ensure services use the S3 credentials for reads
- [ ] If the chart is ever deployed to a multi-tenant cluster, add a
  `NetworkPolicy` restricting access to MinIO from only the
  joegcservices namespace

**File:** `templates/minio/job-setup.yaml` (line 47)

---

#### 3.5.5 — Deploy script lint check should use exit code

**Problem:** The helm lint check in `scripts/deploy-k8s.sh` greps for
the string `"0 chart(s) failed"` in helm output. If Helm changes its
output format in a future version, the check silently passes even on
lint failures.

**Fix:** Check the exit code directly:

```bash
echo -e "${YELLOW}Linting chart...${NC}"
if ! helm lint "${CHART_DIR}"; then
    echo -e "${RED}Chart lint failed!${NC}"
    exit 1
fi
echo -e "${GREEN}Lint passed${NC}"
```

**File:** `scripts/deploy-k8s.sh` (line 175)

---

#### Checklist

- [ ] 3.5.1 — Redis probe authentication
- [ ] 3.5.2 — securityContext on all containers
- [ ] 3.5.3 — Pin MinIO image tags
- [ ] 3.5.4 — Confirm/restrict MinIO public bucket policy
- [ ] 3.5.5 — Deploy script lint check reliability

### Phase 4: Ingress Refinement
- [ ] Rate limiting middleware for Traefik
- [ ] TLS configuration with cert-manager

### Phase 5: Monitoring
- [ ] values-monitoring.yaml for kube-prometheus-stack
- [ ] values-loki.yaml for loki-stack
- [ ] ServiceMonitor templates in chart
- [ ] Grafana dashboard ConfigMaps with auto-discovery labels

### Phase 6: CI/CD
- [ ] GitHub Actions workflow for building 4 service images
- [ ] Push to ECR registry with SHA + latest tags
- [ ] Document ECR registry setup and credential refresh

### Phase 7: Documentation
- [ ] docs/src/deployment/kubernetes.md
- [ ] Update docs/src/SUMMARY.md

## Chart Structure

```
deploy/k8s/joegcservices/
  Chart.yaml
  values.yaml
  values-production.yaml
  .helmignore
  templates/
    _helpers.tpl
    NOTES.txt
    secret.yaml
    ingress.yaml
    data-pipeline/
      deployment.yaml       # Downloader + Ingester (same pod)
      service-downloader.yaml
      service-ingester.yaml
      pvc-state.yaml
    wms-api/
      deployment.yaml       # Scalable serving replicas
      deployment-cleanup.yaml  # Conditional cleanup pod
      service.yaml
      hpa.yaml
    edr-api/
      deployment.yaml
      service.yaml
      hpa.yaml
    web-dashboard/
      deployment.yaml
      service.yaml
    postgres/
      statefulset.yaml
      service.yaml
    redis/
      statefulset.yaml
      service.yaml
    minio/
      statefulset.yaml
      service.yaml
      job-setup.yaml
```

## Usage

```bash
# Dev install (uses deploy script)
./scripts/deploy-k8s.sh

# Production install
# 1. Copy and fill in secrets:
cp .env.k8s.production.example .env.k8s.production
# 2. Ensure ECR credentials are set up:
./scripts/update-k8s-aws-secret.sh --profile 711051230276_AdministratorAccess
# 3. Deploy (loads .env.k8s.production, checks ECR, syncs config, runs helm):
./scripts/deploy-k8s.sh --production

# Other commands
./scripts/deploy-k8s.sh --dry-run     # Preview without applying
./scripts/deploy-k8s.sh --template    # Render templates only
./scripts/deploy-k8s.sh --uninstall   # Remove the release

# Manual helm commands (if needed)
helm upgrade --install joegcservices deploy/k8s/joegcservices \
  -n joegcservices --create-namespace
```
