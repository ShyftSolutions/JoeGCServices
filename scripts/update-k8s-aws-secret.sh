#!/bin/bash
# =============================================================================
# JoeGCServices - Update ECR Pull Secret in Kubernetes
# =============================================================================
# Creates or updates an imagePullSecret for pulling images from AWS ECR.
# ECR tokens are valid for 12 hours; re-run this script to refresh.
#
# Usage:
#   ./scripts/update-k8s-aws-secret.sh --profile 711051230276_AdministratorAccess
#   ./scripts/update-k8s-aws-secret.sh                    # Uses .env.k8s.production defaults
#   ./scripts/update-k8s-aws-secret.sh --namespace foo    # Override namespace
#
# Prerequisites:
#   - aws CLI configured with a valid SSO session or credentials
#   - kubectl configured for the target cluster
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Defaults (can be overridden by .env.k8s.production or CLI args)
ECR_SECRET_NAME="ecr-creds"
NAMESPACE="joegcservices"
AWS_PROFILE=""
AWS_REGION="us-east-2"
ECR_REGISTRY=""

# Source .env.k8s.production if it exists (for defaults)
ENV_FILE="${PROJECT_ROOT}/.env.k8s.production"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    # Map env file vars to our local vars (env file uses K8S_NAMESPACE, etc.)
    NAMESPACE="${K8S_NAMESPACE:-${NAMESPACE}}"
    AWS_REGION="${AWS_REGION:-us-east-2}"
    ECR_REGISTRY="${ECR_REGISTRY:-}"
fi

# Parse command line arguments (override env file)
while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --secret-name)
            ECR_SECRET_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--profile PROFILE] [--namespace NS] [--region REGION] [--secret-name NAME]"
            echo ""
            echo "  --profile NAME    AWS CLI profile to use (required if not in .env.k8s.production)"
            echo "  --namespace NS    Kubernetes namespace (default: joegcservices)"
            echo "  --region REGION   AWS region (default: us-east-2)"
            echo "  --secret-name N   Name of the k8s secret (default: ecr-creds)"
            echo "  -h, --help        Show this help"
            echo ""
            echo "If .env.k8s.production exists, defaults are loaded from it."
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$AWS_PROFILE" ]; then
    echo -e "${RED}Error: AWS profile not set.${NC}"
    echo "Provide --profile or set AWS_PROFILE in .env.k8s.production"
    exit 1
fi

# Derive ECR registry from profile if not set
if [ -z "$ECR_REGISTRY" ]; then
    echo -e "${YELLOW}Detecting ECR registry from AWS account...${NC}"
    ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null) || {
        echo -e "${RED}Error: Failed to get AWS account ID. Is your session valid?${NC}"
        echo "Try: aws sso login --profile ${AWS_PROFILE}"
        exit 1
    }
    ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
fi

echo "=========================================="
echo " ECR Pull Secret Update"
echo "=========================================="
echo "  AWS Profile:  ${AWS_PROFILE}"
echo "  AWS Region:   ${AWS_REGION}"
echo "  ECR Registry: ${ECR_REGISTRY}"
echo "  Namespace:    ${NAMESPACE}"
echo "  Secret Name:  ${ECR_SECRET_NAME}"
echo ""

# Verify AWS credentials are valid
echo -e "${YELLOW}Verifying AWS credentials...${NC}"
if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &>/dev/null; then
    echo -e "${RED}Error: AWS credentials are invalid or expired.${NC}"
    echo "Run: aws sso login --profile ${AWS_PROFILE}"
    exit 1
fi
echo -e "${GREEN}AWS credentials valid.${NC}"

# Get ECR login password
echo -e "${YELLOW}Fetching ECR login token...${NC}"
ECR_PASSWORD=$(aws ecr get-login-password --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null) || {
    echo -e "${RED}Error: Failed to get ECR login password.${NC}"
    exit 1
}
echo -e "${GREEN}ECR token obtained (valid for 12 hours).${NC}"

# Ensure namespace exists
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}Creating namespace ${NAMESPACE}...${NC}"
    kubectl create namespace "$NAMESPACE"
fi

# Delete existing secret if present
if kubectl get secret "$ECR_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}Deleting existing secret ${ECR_SECRET_NAME}...${NC}"
    kubectl delete secret "$ECR_SECRET_NAME" -n "$NAMESPACE"
fi

# Create the docker-registry secret
echo -e "${YELLOW}Creating ECR pull secret...${NC}"
kubectl create secret docker-registry "$ECR_SECRET_NAME" \
    --namespace="$NAMESPACE" \
    --docker-server="$ECR_REGISTRY" \
    --docker-username=AWS \
    --docker-password="$ECR_PASSWORD"

echo ""
echo -e "${GREEN}ECR pull secret '${ECR_SECRET_NAME}' created in namespace '${NAMESPACE}'.${NC}"
echo -e "${YELLOW}Note: ECR tokens expire after 12 hours. Re-run this script to refresh.${NC}"
