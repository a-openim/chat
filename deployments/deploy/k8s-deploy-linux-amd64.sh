#!/bin/bash

# OpenIM Chat Deployment Script for Linux AMD64
# This script cross-compiles binaries for linux/amd64 on mac arm64, builds Docker images, pushes to private Harbor, and deploys to Kubernetes

# Check if running as root
if [ "$EUID" -eq 0 ]; then
  echo "This script should not be run as root due to Docker credential storage issues on macOS."
  echo "Please run this script as your regular user."
  exit 1
fi

ROOT_DIR=$(pwd)
echo "Current Directory: $ROOT_DIR"

# Create version directory if it doesn't exist
mkdir -p deployments/version

# Source the deployment config
if [ -f "deployments/deploy.confg" ]; then
  source deployments/deploy.confg
else
  echo "Error: deployments/deploy.confg not found!"
  exit 1
fi

NAMESPACE=$NAMESPACE
VERSION=v$(date +%y%m%d%H%M%S)
FAILED_SERVICES=()

# Cross-compile binaries for linux/amd64
export GOOS=linux
export GOARCH=amd64

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
echo "$HARBOR_PASS" | docker login $HARBOR_URL -u $HARBOR_USER --password-stdin

# Check if buildx builder exists
if ! docker buildx ls | grep -q openim-builder; then
  docker buildx create openim-builder
  docker buildx use openim-builder
else
  docker buildx use openim-builder
fi

# Services list
services=("openim-admin-api" "openim-admin-rpc" "openim-chat-api" "openim-chat-rpc")

# Ask user whether to run docker build
read -p "Do you want to run docker build? (y/n): " run_docker_build
if [[ "$run_docker_build" =~ ^[Yy]$ ]]; then
  echo "Building and pushing Docker images for linux/amd64..."

  for service in "${services[@]}"; do
    IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${service}:${VERSION}"
    echo "----------------------------------------------------------"
    echo "Processing: $service"
    
    # 执行构建
    docker buildx build --platform linux/amd64 --load -t $IMAGE_TAG -f build/images/$service/Dockerfile .
    
    # 检查上一步执行状态
    if [ $? -eq 0 ]; then
      echo "Successfully built $service. Pushing..."
      docker push $IMAGE_TAG
      if [ $? -eq 0 ]; then
         echo -e "\033[32mSUCCESS: $service pushed.\033[0m"
         # Write version to individual service file
         VERSION_FILE="deployments/version/.version.${service}"
         echo $VERSION > $VERSION_FILE
         echo "Version saved to $VERSION_FILE"
      else
         echo -e "\033[31mERROR: Push failed for $service\033[0m"
         FAILED_SERVICES+=("$service (Push Failed)")
      fi
    else
      echo -e "\033[31mERROR: Build failed for $service\033[0m"
      FAILED_SERVICES+=("$service (Build Failed)")
    fi
  done

  # 打印最终汇总报告
  echo "=========================================================="
  if [ ${#FAILED_SERVICES[@]} -ne 0 ]; then
    echo -e "\033[31mBUILD SUMMARY: THE FOLLOWING SERVICES FAILED:\033[0m"
    for failed in "${FAILED_SERVICES[@]}"; do
      echo -e "\033[31m- $failed\033[0m"
    done
    echo "=========================================================="
    read -p "Some images failed to build. Do you want to continue deployment anyway? (y/n): " continue_deploy
    if [[ ! "$continue_deploy" =~ ^[Yy]$ ]]; then
      echo "Deployment aborted."
      exit 1
    fi
  else
    echo -e "\033[32mBUILD SUMMARY: ALL SERVICES BUILT AND PUSHED SUCCESSFULLY.\033[0m"
    echo "=========================================================="
  fi

else
  echo "Skipping docker build..."
  # Check if all service version files exist
  ALL_VERSIONS_EXIST=true
  for service in "${services[@]}"; do
    VERSION_FILE="deployments/version/.version.${service}"
    if [ ! -f "$VERSION_FILE" ]; then
      echo "Error: $VERSION_FILE not found. Cannot skip build without a prior version for $service."
      ALL_VERSIONS_EXIST=false
    fi
  done

  if [ "$ALL_VERSIONS_EXIST" = false ]; then
    exit 1
  fi

  echo "Using existing versions from individual service version files:"
  for service in "${services[@]}"; do
    VERSION_FILE="deployments/version/.version.${service}"
    EXISTING_VERSION=$(cat $VERSION_FILE)
    echo "  $service: $EXISTING_VERSION"
  done
fi

# Update deployment YAMLs
echo "Updating deployment YAMLs to use Harbor images..."
for service in "${services[@]}"; do
  DEPLOYMENT_FILE="deployments/deploy/${service}-deployment.yml"
  VERSION_FILE="deployments/version/.version.${service}"
  if [ -f "$VERSION_FILE" ]; then
    SERVICE_VERSION=$(cat $VERSION_FILE)
    IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${service}:${SERVICE_VERSION}"
    if [ -f "$DEPLOYMENT_FILE" ]; then
      sed -i.bak "s|image:.*${service}:.*|image: ${IMAGE_TAG}|g" $DEPLOYMENT_FILE
      echo "Updated $DEPLOYMENT_FILE with version: $SERVICE_VERSION"
    else
      echo "Warning: $DEPLOYMENT_FILE not found, skipping..."
    fi
  else
    echo "Warning: $VERSION_FILE not found, skipping $service..."
  fi
done

# Deploy to Kubernetes
echo "Starting OpenIM Chat Deployment in namespace: $NAMESPACE"

# Ask user whether to deploy to Kubernetes
read -p "Do you want to deploy to Kubernetes? (y/n): " run_deploy
if [[ ! "$run_deploy" =~ ^[Yy]$ ]]; then
  echo "Skipping Kubernetes deployment..."
  echo "Deployment YAMLs have been updated. You can deploy manually later."
  exit 0
fi

# Apply ConfigMap
echo "Applying ConfigMap..."
kubectl apply -f deployments/deploy/chat-config.yml -n $NAMESPACE

# Apply services (batch apply)
echo "Applying services..."
for service in "${services[@]}"; do
    FILE="deployments/deploy/${service}-service.yml"
    if [ -f "$FILE" ]; then
        kubectl apply -f "$FILE" -n $NAMESPACE
    fi
done

# Apply Deployments (batch apply)
echo "Applying Deployments..."
for service in "${services[@]}"; do
    FILE="deployments/deploy/${service}-deployment.yml"
    if [ -f "$FILE" ]; then
        kubectl apply -f "$FILE" -n $NAMESPACE
    fi
done

# Apply Ingress
echo "Applying Ingress..."
if [ -f "deployments/deploy/ingress.yml" ]; then
    kubectl apply -f deployments/deploy/ingress.yml -n $NAMESPACE
fi

echo "----------------------------------------------------------"
echo "OpenIM Chat Deployment process finished!"
echo "Check pods: kubectl get pods -n $NAMESPACE"

say -v Meijia "congratulations"
