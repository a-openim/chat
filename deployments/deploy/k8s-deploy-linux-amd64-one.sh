#!/bin/bash

# OpenIM Chat Deployment Script for Linux AMD64 - Single Service
# This script cross-compiles binaries for linux/amd64 on mac arm64, builds Docker image for selected service, pushes to private Harbor, and deploys to Kubernetes

set -e

# Check if running as root
if [ "$EUID" -eq 0 ]; then
  echo "This script should not be run as root due to Docker credential storage issues on macOS."
  echo "Please run this script as your regular user."
  exit 1
fi

ROOT_DIR=$(pwd)
echo $ROOT_DIR

# Create version directory if it doesn't exist
mkdir -p deployments/version

# Source the deployment config
source deployments/deploy.confg

NAMESPACE=$NAMESPACE
VERSION=v$(date +%y%m%d%H%M%S)

# Note: Binaries are built inside the Docker container, so no pre-build needed
# Ask user whether to run mage build
read -p "Do you want to run mage build? (y/n): " run_build
if [[ "$run_build" =~ ^[Yy]$ ]]; then
  echo "Running mage build..."
  GOOS=linux CGO_ENABLE=0 PLATFORMS=linux_amd64 mage build
else
  echo "Skipping mage build..."
fi

# Login to private Harbor
echo "Logging in to Harbor..."
# Set DOCKER_CONFIG to a temporary directory to avoid macOS Keychain issues
export DOCKER_CONFIG=$(mktemp -d)
export DOCKER_CREDS_STORE=""
# Create a config.json with credsStore set to empty string to prevent Keychain usage
echo '{"auths":{},"credsStore":""}' > $DOCKER_CONFIG/config.json
echo "$HARBOR_PASS" | docker login $HARBOR_URL -u $HARBOR_USER --password-stdin
# Unset DOCKER_CONFIG to allow buildx to use default config
unset DOCKER_CONFIG
unset DOCKER_CREDS_STORE

# Check if buildx builder exists, create if not
if ! docker buildx ls | grep -q openim-builder; then
  docker buildx create openim-builder
  docker buildx use openim-builder
else
  docker buildx use openim-builder
fi

# List of services
services=("openim-admin-api" "openim-admin-rpc" "openim-chat-api" "openim-chat-rpc")

# Display services with numbers
echo "Available services:"
for i in "${!services[@]}"; do
  echo "$((i+1)). ${services[$i]}"
done

# Prompt user to choose a service
read -p "Enter the number of the service to build and deploy: " choice

# Validate choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#services[@]}" ]; then
  echo "Invalid choice. Please enter a number between 1 and ${#services[@]}."
  exit 1
fi

# Get the selected service
selected_service="${services[$((choice-1))]}"
echo "Selected service: $selected_service"

# Ask user whether to run docker build
read -p "Do you want to run docker build? (y/n): " run_docker_build
if [[ "$run_docker_build" =~ ^[Yy]$ ]]; then
  # Build Docker image for the selected service and push to Harbor
  services=("$selected_service")

  for service in "${services[@]}"; do
    IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${service}:${VERSION}"
    docker buildx build --platform linux/amd64 --load -t $IMAGE_TAG -f build/images/$service/Dockerfile .
    echo "Docker buildx build completed for $service. Checking image architecture:"
    docker inspect $IMAGE_TAG | grep -A 5 '"Architecture"'
    docker push $IMAGE_TAG
    echo "Pushed $IMAGE_TAG"
    # Write version to individual service file
    VERSION_FILE="deployments/version/.version.${service}"
    echo $VERSION > $VERSION_FILE
    echo "Version saved to $VERSION_FILE"
  done

else
  echo "Skipping docker build..."
  # Read version from service-specific version file for deployment YAML update
  VERSION_FILE="deployments/version/.version.${selected_service}"
  if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: $VERSION_FILE not found. Cannot skip build without a prior version for $selected_service."
    exit 1
  fi
  EXISTING_VERSION=$(cat $VERSION_FILE)
  IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${selected_service}:${EXISTING_VERSION}"
  echo "Using existing version: $EXISTING_VERSION"
fi

# Update deployment YAML for the selected service to use Harbor image
echo "Updating deployment YAML for $selected_service to use Harbor image..."
DEPLOYMENT_FILE="deployments/deploy/${selected_service}-deployment.yml"
sed -i.bak "s|image:.*${selected_service}:.*|image: ${IMAGE_TAG}|g" $DEPLOYMENT_FILE

# Deploy to Kubernetes
echo "Starting OpenIM Chat Deployment in namespace: $NAMESPACE"

# Apply ConfigMap
echo "Applying ConfigMap..."
kubectl apply -f deployments/deploy/chat-config.yml -n $NAMESPACE

# Apply the selected service and deployment
echo "Applying selected service: $selected_service"
kubectl apply -f deployments/deploy/${selected_service}-service.yml -n $NAMESPACE
kubectl apply -f deployments/deploy/${selected_service}-deployment.yml -n $NAMESPACE

cd $ROOT_DIR
echo "OpenIM Chat Deployment for $selected_service completed successfully!"
echo "You can check the status with: kubectl get pods -n $NAMESPACE"
echo "Access the Admin API at: http://your-ingress-host/openim-admin-api"
echo "Access the Chat API at: http://your-ingress-host/openim-chat-api"