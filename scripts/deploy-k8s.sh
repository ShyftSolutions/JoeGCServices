#!/bin/bash
# =============================================================================
# JoeGCServices - Kubernetes Deploy Script
# =============================================================================
# Builds images, pushes to ECR, and deploys to k3s via Helm.
# Defaults to PRODUCTION mode with a confirmation prompt.
#
# Usage:
#   ./scripts/deploy-k8s.sh                    # Production deploy (with confirmation)
#   ./scripts/deploy-k8s.sh --yes              # Production deploy, skip confirmation
#   ./scripts/deploy-k8s.sh --skip-build       # Production deploy, skip image builds
#   ./scripts/deploy-k8s.sh --dev              # Dev mode (no ECR, no builds, no confirm)
#   ./scripts/deploy-k8s.sh --dry-run          # Helm dry-run (no builds, no confirm)
#   ./scripts/deploy-k8s.sh --template         # Render templates only
#   ./scripts/deploy-k8s.sh --uninstall        # Remove the release
#
# Prerequisites:
#   - kubectl configured for the target k3s cluster
#   - helm 3 installed
#   - For production: .env.k8s.production, valid AWS credentials, Docker
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_DIR="${PROJECT_ROOT}/deploy/k8s/joegcservices"
RELEASE_NAME="joegcservices"
NAMESPACE="joegcservices"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Image tag (set during build step)
IMAGE_TAG=""

# Service definitions: name, dockerfile, build-context
# Format: "ecr-repo-name|dockerfile-path|build-context"
SERVICES=(
    "downloader|services/downloader/Dockerfile|."
    "ingester|services/ingester/Dockerfile|."
    "wms-api|services/wms-api/Dockerfile|."
    "edr-api|services/edr-api/Dockerfile|."
    "web-dashboard|web/Dockerfile|web/"
)

# Parse arguments — defaults to production mode
PRODUCTION=true
DRY_RUN=""
TEMPLATE_ONLY=false
UNINSTALL=false
SKIP_BUILD=false
CONFIRM=true
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --dev)
            PRODUCTION=false
            shift
            ;;
        --production)
            # Already the default; accept silently for backwards compat
            PRODUCTION=true
            shift
            ;;
        --yes|-y)
            CONFIRM=false
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --dry-run)
            DRY_RUN="--dry-run"
            shift
            ;;
        --template)
            TEMPLATE_ONLY=true
            shift
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --set|--set-string)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        -f|--values)
            EXTRA_ARGS+=("$1" "$2")
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            echo "Usage: $0 [--dev] [--yes] [--skip-build] [--dry-run] [--template] [--uninstall]"
            exit 1
            ;;
    esac
done

# =============================================================================
# Load production environment file
# =============================================================================
load_env_file() {
    local env_file="${PROJECT_ROOT}/.env.k8s.production"
    local example_file="${PROJECT_ROOT}/.env.k8s.production.example"

    if [ ! -f "${env_file}" ]; then
        if [ -f "${example_file}" ]; then
            echo -e "${YELLOW}.env.k8s.production not found — creating from example template${NC}"
            cp "${example_file}" "${env_file}"
        else
            echo -e "${RED}Error: .env.k8s.production not found and no example template available${NC}" >&2
            exit 1
        fi
    fi

    echo -e "${YELLOW}Loading .env.k8s.production...${NC}"
    # shellcheck source=/dev/null
    source "${env_file}"

    # Override namespace and context from env file if set
    NAMESPACE="${K8S_NAMESPACE:-${NAMESPACE}}"
    K8S_CONTEXT="${K8S_CONTEXT:-default}"
}

# =============================================================================
# Ensure internal service passwords are populated (generate once, persist)
# =============================================================================
# Auto-generates random passwords for internal services (Postgres, Redis, MinIO)
# if they are empty in .env.k8s.production. Generated values are written back
# to the file so they persist across deploys. External credentials (Earthdata)
# are never auto-generated — only a warning is printed if they're missing.
ensure_secrets() {
    local env_file="${PROJECT_ROOT}/.env.k8s.production"
    local generated=false

    # Generate a random value and write it back to the env file.
    # Usage: generate_secret VAR_NAME length_bytes encoding
    #   encoding: "hex" for alphanumeric, "base64" for standard base64
    generate_secret() {
        local var_name="$1"
        local length="$2"
        local encoding="${3:-hex}"
        local value

        if [ "$encoding" = "base64" ]; then
            value=$(openssl rand -base64 "$length" | tr -d '\n')
        else
            value=$(openssl rand -hex "$length")
        fi

        # Set the variable in the current shell
        eval "export ${var_name}='${value}'"

        # Write it back to the env file (replace empty assignment)
        sed -i '' "s/^${var_name}=\$/${var_name}=${value}/" "${env_file}"

        echo -e "  ${GREEN}Generated ${var_name}${NC} (saved to .env.k8s.production)"
        generated=true
    }

    echo ""
    echo -e "${YELLOW}Checking secrets...${NC}"

    # Internal service passwords — safe to auto-generate
    [ -z "${POSTGRES_PASSWORD:-}" ] && generate_secret POSTGRES_PASSWORD 24
    [ -z "${REDIS_PASSWORD:-}" ]    && generate_secret REDIS_PASSWORD 24
    # MinIO access key: alphanumeric, 16 chars (hex gives 32 hex chars = 16 bytes)
    [ -z "${S3_ACCESS_KEY:-}" ]     && generate_secret S3_ACCESS_KEY 16
    # MinIO secret key: alphanumeric, 24 chars
    [ -z "${S3_SECRET_KEY:-}" ]     && generate_secret S3_SECRET_KEY 24

    if [ "$generated" = true ]; then
        echo ""
        echo -e "  ${YELLOW}Secrets have been saved to .env.k8s.production.${NC}"
        echo -e "  ${YELLOW}Back up this file — these passwords cannot be recovered.${NC}"
    else
        echo -e "  ${GREEN}All internal secrets populated${NC}"
    fi

    # External credentials — warn if missing but don't block
    if [ -z "${EARTHDATA_USERNAME:-}" ] || [ -z "${EARTHDATA_PASSWORD:-}" ]; then
        echo -e "  ${YELLOW}Note: Earthdata credentials not set (downloader will skip NASA sources)${NC}"
    fi
}

# =============================================================================
# Check prerequisites
# =============================================================================
check_prereqs() {
    local missing=false

    if ! command -v helm &>/dev/null; then
        echo -e "${RED}Error: helm is not installed${NC}"
        missing=true
    fi

    if ! command -v kubectl &>/dev/null; then
        echo -e "${RED}Error: kubectl is not installed${NC}"
        missing=true
    fi

    if [ "$missing" = true ]; then
        exit 1
    fi

    # Check kubectl connectivity
    echo -e "${YELLOW}Checking cluster connectivity...${NC}"
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null) || {
        echo -e "${RED}Error: No kubectl context configured${NC}"
        echo "Make sure kubectl is configured and the cluster is running."
        exit 1
    }

    # Verify context matches expected (production only)
    if [ "$PRODUCTION" = true ] && [ -n "${K8S_CONTEXT:-}" ]; then
        if [ "$current_context" != "$K8S_CONTEXT" ]; then
            echo -e "${RED}Error: kubectl context mismatch${NC}"
            echo "  Expected: ${K8S_CONTEXT}"
            echo "  Current:  ${current_context}"
            echo ""
            echo "Switch context with: kubectl config use-context ${K8S_CONTEXT}"
            exit 1
        fi
    fi

    # Lightweight connectivity check
    if ! kubectl get nodes --request-timeout=5s &>/dev/null; then
        echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
        echo "Make sure the cluster is running and kubectl is configured."
        echo "  Context: ${current_context}"
        local server
        server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
        echo "  Server:  ${server}"
        exit 1
    fi

    local server
    server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")
    echo -e "${GREEN}Cluster reachable${NC}"
    echo -e "  ${BLUE}Context:${NC} ${current_context}"
    echo -e "  ${BLUE}Server:${NC}  ${server}"
}

# =============================================================================
# Ensure namespace exists
# =============================================================================
ensure_namespace() {
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        echo -e "${YELLOW}Creating namespace ${NAMESPACE}...${NC}"
        kubectl create namespace "$NAMESPACE"
    else
        echo -e "${GREEN}Namespace '${NAMESPACE}' exists${NC}"
    fi
}

# =============================================================================
# Build and push Docker images to ECR
# =============================================================================
build_and_push_images() {
    local ecr_registry="${ECR_REGISTRY:-}"
    local aws_profile="${AWS_PROFILE:-}"
    local aws_region="${AWS_REGION:-us-east-2}"

    if [ -z "$ecr_registry" ]; then
        echo -e "${RED}Error: ECR_REGISTRY not set in .env.k8s.production${NC}"
        exit 1
    fi

    # Determine image tag from git SHA
    IMAGE_TAG=$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null) || {
        echo -e "${RED}Error: Failed to get git commit SHA${NC}"
        exit 1
    }

    echo ""
    echo -e "${YELLOW}Checking images for tag: ${BOLD}${IMAGE_TAG}${NC}"

    # Check which services need building
    local need_build=()
    for svc_def in "${SERVICES[@]}"; do
        IFS='|' read -r svc_name svc_dockerfile svc_context <<< "$svc_def"
        local repo="joegcservices/${svc_name}"

        if aws ecr describe-images \
            --profile "$aws_profile" \
            --region "$aws_region" \
            --repository-name "$repo" \
            --image-ids imageTag="$IMAGE_TAG" &>/dev/null; then
            echo -e "  ${GREEN}${svc_name}${NC} — ${IMAGE_TAG} exists in ECR"
        else
            echo -e "  ${YELLOW}${svc_name}${NC} — needs building"
            need_build+=("$svc_def")
        fi
    done

    if [ ${#need_build[@]} -eq 0 ]; then
        echo -e "${GREEN}All images up to date for ${IMAGE_TAG}${NC}"
        return 0
    fi

    echo ""
    echo -e "${YELLOW}Building ${#need_build[@]} image(s) for linux/amd64...${NC}"

    # Log in to ECR
    echo -e "${YELLOW}Logging in to ECR...${NC}"
    aws ecr get-login-password --profile "$aws_profile" --region "$aws_region" \
        | docker login --username AWS --password-stdin "$ecr_registry" 2>/dev/null
    echo -e "${GREEN}ECR login successful${NC}"

    # Build images in parallel
    local pids=()
    local svc_names=()
    local build_failed=false

    for svc_def in "${need_build[@]}"; do
        IFS='|' read -r svc_name svc_dockerfile svc_context <<< "$svc_def"
        local full_image="${ecr_registry}/joegcservices/${svc_name}"

        echo -e "  ${BLUE}Starting build:${NC} ${svc_name}"

        # Build and push in background
        (
            docker buildx build \
                --platform linux/amd64 \
                -f "${PROJECT_ROOT}/${svc_dockerfile}" \
                -t "${full_image}:${IMAGE_TAG}" \
                -t "${full_image}:latest" \
                --push \
                "${PROJECT_ROOT}/${svc_context}" \
                > "/tmp/docker-build-${svc_name}.log" 2>&1
        ) &
        pids+=($!)
        svc_names+=("$svc_name")
    done

    # Wait for all builds and report results
    echo ""
    echo -e "${YELLOW}Waiting for builds to complete (this may take a while for first build)...${NC}"
    for i in "${!pids[@]}"; do
        local pid="${pids[$i]}"
        local name="${svc_names[$i]}"
        if wait "$pid"; then
            echo -e "  ${GREEN}${name}${NC} — built and pushed successfully"
        else
            echo -e "  ${RED}${name}${NC} — BUILD FAILED"
            echo "  See /tmp/docker-build-${name}.log for details"
            build_failed=true
        fi
    done

    if [ "$build_failed" = true ]; then
        echo ""
        echo -e "${RED}One or more image builds failed. Aborting deploy.${NC}"
        exit 1
    fi

    echo -e "${GREEN}All images built and pushed for ${IMAGE_TAG}${NC}"
}

# =============================================================================
# Uninstall the release
# =============================================================================
do_uninstall() {
    echo -e "${YELLOW}Uninstalling ${RELEASE_NAME} from namespace ${NAMESPACE}...${NC}"
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
    echo -e "${GREEN}Release uninstalled.${NC}"
    echo -e "${YELLOW}Note: PVCs are NOT deleted. To remove all data:${NC}"
    echo "  kubectl delete pvc --all -n ${NAMESPACE}"
    echo "  kubectl delete namespace ${NAMESPACE}"
}

# =============================================================================
# Build values arguments into HELM_VALUES_ARGS array
# =============================================================================
# Uses a global array to preserve quoting (avoids word-split bugs with echo).
HELM_VALUES_ARGS=()
build_values_args() {
    HELM_VALUES_ARGS=("-f" "${CHART_DIR}/values.yaml")

    if [ "$PRODUCTION" = true ]; then
        if [ ! -f "${CHART_DIR}/values-production.yaml" ]; then
            echo -e "${RED}Error: values-production.yaml not found${NC}" >&2
            exit 1
        fi
        HELM_VALUES_ARGS+=("-f" "${CHART_DIR}/values-production.yaml")
        echo -e "${YELLOW}Using production values overlay${NC}" >&2

        # Map env file secrets to --set flags
        [ -n "${DOMAIN:-}" ] && \
            HELM_VALUES_ARGS+=("--set" "global.domain=${DOMAIN}")
        [ -n "${ECR_REGISTRY:-}" ] && \
            HELM_VALUES_ARGS+=("--set" "global.image.registry=${ECR_REGISTRY}")
        [ -n "${POSTGRES_PASSWORD:-}" ] && \
            HELM_VALUES_ARGS+=("--set" "secrets.postgres.password=${POSTGRES_PASSWORD}")
        [ -n "${REDIS_PASSWORD:-}" ] && \
            HELM_VALUES_ARGS+=("--set" "secrets.redis.password=${REDIS_PASSWORD}")
        [ -n "${S3_ACCESS_KEY:-}" ] && \
            HELM_VALUES_ARGS+=("--set" "secrets.s3.accessKey=${S3_ACCESS_KEY}")
        [ -n "${S3_SECRET_KEY:-}" ] && \
            HELM_VALUES_ARGS+=("--set" "secrets.s3.secretKey=${S3_SECRET_KEY}")
        [ -n "${EARTHDATA_USERNAME:-}" ] && \
            HELM_VALUES_ARGS+=("--set" "secrets.earthdata.username=${EARTHDATA_USERNAME}")
        [ -n "${EARTHDATA_PASSWORD:-}" ] && \
            HELM_VALUES_ARGS+=("--set" "secrets.earthdata.password=${EARTHDATA_PASSWORD}")
        [ -n "${EARTHDATA_TOKEN:-}" ] && \
            HELM_VALUES_ARGS+=("--set" "secrets.earthdata.token=${EARTHDATA_TOKEN}")

        # Pin images to the built git SHA tag (if we built images)
        if [ -n "$IMAGE_TAG" ]; then
            HELM_VALUES_ARGS+=("--set" "dataPipeline.image.downloader.tag=${IMAGE_TAG}")
            HELM_VALUES_ARGS+=("--set" "dataPipeline.image.ingester.tag=${IMAGE_TAG}")
            HELM_VALUES_ARGS+=("--set" "wmsApi.image.tag=${IMAGE_TAG}")
            HELM_VALUES_ARGS+=("--set" "edrApi.image.tag=${IMAGE_TAG}")
            HELM_VALUES_ARGS+=("--set" "webDashboard.image.tag=${IMAGE_TAG}")
        fi
    fi

    # Append any extra --set or -f args from the command line
    if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
        HELM_VALUES_ARGS+=("${EXTRA_ARGS[@]}")
    fi
}

# =============================================================================
# Confirmation prompt before deploying
# =============================================================================
confirm_deploy() {
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    local server
    server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")

    echo ""
    echo -e "${BOLD}=========================================="
    echo " Deploy Summary"
    echo "==========================================${NC}"
    if [ "$PRODUCTION" = true ]; then
        echo -e "  ${BOLD}Mode:${NC}      ${RED}PRODUCTION${NC}"
    else
        echo -e "  ${BOLD}Mode:${NC}      DEV"
    fi
    echo -e "  ${BOLD}Cluster:${NC}   ${current_context} (${server})"
    echo -e "  ${BOLD}Namespace:${NC} ${NAMESPACE}"
    echo -e "  ${BOLD}Release:${NC}   ${RELEASE_NAME}"
    if [ "$PRODUCTION" = true ]; then
        echo -e "  ${BOLD}Domain:${NC}    ${DOMAIN:-not set}"
        echo -e "  ${BOLD}Registry:${NC}  ${ECR_REGISTRY:-not set}"
    fi
    if [ -n "$IMAGE_TAG" ]; then
        echo -e "  ${BOLD}Image Tag:${NC} ${IMAGE_TAG}"
    fi
    echo ""

    read -r -p "  Continue with deploy? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            echo ""
            ;;
        *)
            echo ""
            echo -e "${YELLOW}Deploy cancelled.${NC}"
            exit 0
            ;;
    esac
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo "=========================================="
    echo " JoeGCServices - Kubernetes Deploy"
    echo "=========================================="
    if [ "$PRODUCTION" = true ]; then
        echo -e " Mode: ${RED}${BOLD}PRODUCTION${NC}"
    else
        echo -e " Mode: DEV"
    fi
    echo ""

    # Load production env file (default unless --dev)
    if [ "$PRODUCTION" = true ]; then
        load_env_file
        ensure_secrets
    fi

    if [ "$UNINSTALL" = true ]; then
        check_prereqs
        do_uninstall
        exit 0
    fi

    if [ "$TEMPLATE_ONLY" = true ]; then
        build_values_args
        echo -e "${YELLOW}Rendering templates...${NC}"
        helm template "${RELEASE_NAME}" "${CHART_DIR}" \
            --namespace "${NAMESPACE}" \
            "${HELM_VALUES_ARGS[@]}" 2>&1
        exit 0
    fi

    check_prereqs
    ensure_namespace

    # Build and push images (production only, unless --skip-build or --dry-run)
    if [ "$PRODUCTION" = true ] && [ "$SKIP_BUILD" = false ] && [ -z "$DRY_RUN" ]; then
        build_and_push_images
    elif [ "$PRODUCTION" = true ] && [ "$SKIP_BUILD" = true ]; then
        # Still set IMAGE_TAG for helm --set even when skipping build
        IMAGE_TAG=$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "")
        if [ -n "$IMAGE_TAG" ]; then
            echo ""
            echo -e "${YELLOW}Skipping build. Using image tag: ${IMAGE_TAG}${NC}"
        fi
    fi

    # Lint first
    echo ""
    echo -e "${YELLOW}Linting chart...${NC}"
    if ! helm lint "${CHART_DIR}"; then
        echo -e "${RED}Chart lint failed!${NC}"
        exit 1
    fi
    echo -e "${GREEN}Lint passed${NC}"

    # Build values args
    build_values_args

    # Confirmation prompt (skip for --dry-run, --dev, or --yes)
    if [ "$CONFIRM" = true ] && [ -z "$DRY_RUN" ] && [ "$PRODUCTION" = true ]; then
        confirm_deploy
    fi

    # Uninstall existing release before installing.
    # StatefulSet volumeClaimTemplates are immutable, so helm upgrade cannot
    # change storageClassName or other spec fields. Uninstall + install avoids
    # this. PVCs are preserved across uninstall (Helm does not delete them),
    # so persistent data in Postgres/Redis/MinIO survives redeployments.
    echo ""
    if [ -n "$DRY_RUN" ]; then
        echo -e "${YELLOW}Dry run (no changes will be applied)...${NC}"
        helm install "${RELEASE_NAME}" "${CHART_DIR}" \
            --namespace "${NAMESPACE}" --create-namespace \
            "${HELM_VALUES_ARGS[@]}" \
            --dry-run
    else
        if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" &>/dev/null; then
            echo -e "${YELLOW}Uninstalling existing release...${NC}"
            helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait
            echo -e "${GREEN}Uninstalled${NC}"
        fi

        echo -e "${YELLOW}Installing ${RELEASE_NAME} in namespace ${NAMESPACE}...${NC}"
        helm install "${RELEASE_NAME}" "${CHART_DIR}" \
            --namespace "${NAMESPACE}" --create-namespace \
            "${HELM_VALUES_ARGS[@]}"

        echo ""
        echo -e "${GREEN}Deploy initiated!${NC}"
        echo -e "${YELLOW}Waiting for rollout...${NC}"

        # Wait for critical deployments
        kubectl -n "${NAMESPACE}" rollout status deployment/"${RELEASE_NAME}-data-pipeline" --timeout=300s 2>/dev/null || true
        kubectl -n "${NAMESPACE}" rollout status deployment/"${RELEASE_NAME}-wms-api" --timeout=300s 2>/dev/null || true
        kubectl -n "${NAMESPACE}" rollout status deployment/"${RELEASE_NAME}-edr-api" --timeout=300s 2>/dev/null || true

        echo ""
        echo -e "${GREEN}Deploy complete!${NC}"
        echo ""
        echo "Pod status:"
        kubectl get pods -n "${NAMESPACE}" -o wide

        # Smoke-test the services
        verify_services
    fi
}

# =============================================================================
# Verify services are responding after deploy
# =============================================================================
verify_services() {
    local domain="${DOMAIN:-localhost}"
    local base_url="http://${domain}"
    local pass=0
    local fail=0

    echo ""
    echo -e "${BOLD}=========================================="
    echo " Service Health Checks"
    echo "==========================================${NC}"

    # Use kubectl port-forward through the Istio gateway if domain isn't
    # directly reachable from this machine. For now, try the public URL
    # and fall back to a kubectl exec curl inside the cluster.

    check_endpoint() {
        local label="$1"
        local url="$2"
        local expect_str="${3:-}"   # Optional string to look for in response

        printf "  %-22s %s\n" "${label}" "${url}"

        local http_code body
        http_code=$(curl -s -L -o /tmp/deploy-check-body -w '%{http_code}' \
            --max-time 10 --connect-timeout 5 "${url}" 2>/dev/null) || http_code="000"
        body=$(cat /tmp/deploy-check-body 2>/dev/null || echo "")

        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 400 ]; then
            if [ -n "$expect_str" ] && ! echo "$body" | grep -q "$expect_str"; then
                echo -e "    ${YELLOW}${http_code} OK — but expected '${expect_str}' not found in response${NC}"
                ((fail++))
            else
                echo -e "    ${GREEN}${http_code} OK${NC}"
                ((pass++))
            fi
        else
            echo -e "    ${RED}${http_code} FAILED${NC}"
            ((fail++))
        fi
    }

    check_endpoint "WMS GetCapabilities" \
        "${base_url}/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities" \
        "WMS_Capabilities"

    check_endpoint "WMTS GetCapabilities" \
        "${base_url}/wmts?SERVICE=WMTS&VERSION=1.0.0&REQUEST=GetCapabilities" \
        "Capabilities"

    check_endpoint "EDR Landing Page" \
        "${base_url}/edr" \
        "links"

    check_endpoint "EDR Collections" \
        "${base_url}/edr/collections" \
        "collections"

    check_endpoint "Web Dashboard" \
        "${base_url}/" \
        ""

    echo ""
    echo -e "  Results: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}"

    if [ "$fail" -gt 0 ]; then
        echo -e "  ${YELLOW}Some checks failed — services may still be starting up.${NC}"
        echo "  Re-check manually:"
        echo "    curl -s -o /dev/null -w '%{http_code}' '${base_url}/wms?SERVICE=WMS&REQUEST=GetCapabilities'"
        echo "    curl -s -o /dev/null -w '%{http_code}' '${base_url}/edr/collections'"
    fi

    rm -f /tmp/deploy-check-body
}

main
