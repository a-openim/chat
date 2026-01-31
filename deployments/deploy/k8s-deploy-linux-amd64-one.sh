#!/bin/bash

# OpenIM Server Deployment Script for Linux AMD64 - Single Service
# This script cross-compiles binaries for linux/amd64 on mac arm64, builds Docker image for selected service, pushes to private Harbor, and deploys to Kubernetes

set -e

# Source the deployment config
if [ ! -f deploy.confg ]; then
  echo "Configuration file 'deploy.confg' not found. Exiting."
  exit 1
fi
source deploy.confg

NAMESPACE=$NAMESPACE
VERSION=v$(date +%y%m%d%H%M%S)
echo $VERSION > .version

# Note: Binaries are built inside the Docker container, so no pre-build needed
GOOS=linux GOARCH=amd64 PLATFORMS=linux_amd64 CGO_ENABLED=0 mage build

# Login to private Harbor
echo "Logging in to Harbor..."
if ! echo "$HARBOR_PASS" | docker login $HARBOR_URL -u $HARBOR_USER --password-stdin; then
  echo "Failed to login to Harbor. Exiting."
  exit 1
fi

# Build Docker images for linux/amd64 and push to Harbor
echo "Building and pushing Docker image for selected service..."

# Check if buildx builder exists, create if not
if ! docker buildx ls | grep -q openim-builder; then
  docker buildx create --use --name openim-builder
else
  docker buildx use openim-builder
fi

services=("openim-admin-api" "openim-admin-rpc" "openim-chat-api" "openim-chat-rpc")

echo "Available services:"
for i in "${!services[@]}"; do
  echo "$((i+1)). ${services[i]}"
done

read -p "Choose a service to build (1-${#services[@]}): " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#services[@]}" ]; then
  echo "Invalid choice. Exiting."
  exit 1
fi

chosen_service=${services[$((choice-1))]}
echo "Selected service: $chosen_service"

services=("$chosen_service")

for service in "${services[@]}"; do
  IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${service}:${VERSION}"
  docker buildx build --platform linux/amd64 --load -t $IMAGE_TAG -f build/images/$service/Dockerfile .
  echo "Docker buildx build completed for $service. Checking image architecture:"
  docker inspect $IMAGE_TAG | grep -A 5 '"Architecture"'
  docker push $IMAGE_TAG
  echo "Pushed $IMAGE_TAG"
done

# Update deployment YAMLs to use Harbor images
echo "Updating deployment YAML to use Harbor image..."
echo "Current directory: $(pwd)"
echo "Checking for deployment file..."

for service in "${services[@]}"; do
  DEPLOYMENT_FILE="deployments/deploy/${service}-deployment.yml"
  IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${service}:${VERSION}"
  sed -i.bak "s|image: .*/${service}:.*|image: ${IMAGE_TAG}|g" $DEPLOYMENT_FILE
done

# Deploy to Kubernetes
echo "Starting OpenIM Server Deployment in namespace: $NAMESPACE"

# Apply ConfigMap
echo "Applying ConfigMap..."
kubectl apply -f deployments/deploy/chat-config.yml -n $NAMESPACE

# Apply services
echo "Applying service..."
for service in "${services[@]}"; do
  kubectl apply -f deployments/deploy/${service}-service.yml -n $NAMESPACE
done

# Apply Deployments
echo "Applying Deployment..."
for service in "${services[@]}"; do
  kubectl apply -f deployments/deploy/${service}-deployment.yml -n $NAMESPACE
done

# Apply Ingress
echo "Applying Ingress..."
kubectl apply -f deployments/deploy/ingress.yml -n $NAMESPACE

echo "OpenIM Server Deployment for $chosen_service completed successfully!"
echo "You can check the status with: kubectl get pods -n $NAMESPACE"
echo "Access the Admin API at: http://your-ingress-host/openim-admin-api"
echo "Access the Chat API at: http://your-ingress-host/openim-chat-api"