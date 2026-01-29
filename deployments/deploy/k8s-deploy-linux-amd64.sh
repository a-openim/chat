#!/bin/bash

# OpenIM Server Deployment Script for Linux AMD64
# This script cross-compiles binaries for linux/amd64 on mac arm64, builds Docker images, pushes to private Harbor, and deploys to Kubernetes

set -e

# Source the deployment config
source deploy.confg

NAMESPACE=$NAMESPACE
VERSION=v3.8.3

# Cross-compile binaries for linux/amd64
export GOOS=linux
export GOARCH=amd64

echo "Building binaries for linux/amd64..."
mage build

# Login to private Harbor
echo "Logging in to Harbor..."
echo "$HARBOR_PASS" | docker login $HARBOR_URL -u $HARBOR_USER --password-stdin

# Build Docker images for linux/amd64 and push to Harbor
echo "Building and pushing Docker images for linux/amd64..."

# Remove existing builder if it exists to avoid conflicts
docker buildx rm openim-builder || true
docker buildx create --use --name openim-builder

services=("openim-admin-api" "openim-admin-rpc" "openim-chat-api" "openim-chat-rpc")

for service in "${services[@]}"; do
  IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${service}:${VERSION}"
  docker build -t $IMAGE_TAG -f build/images/$service/Dockerfile .
  docker push $IMAGE_TAG
done

# Update deployment YAMLs to use Harbor images
echo "Updating deployment YAMLs to use Harbor images..."
for service in "${services[@]}"; do
  DEPLOYMENT_FILE="${service}-deployment.yml"
  IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${service}:${VERSION}"
  sed -i.bak "s|image: openim/${service}:.*|image: ${IMAGE_TAG}|g" $DEPLOYMENT_FILE
done

# Deploy to Kubernetes
echo "Starting OpenIM Server Deployment in namespace: $NAMESPACE"

# Apply ConfigMap
echo "Applying ConfigMap..."
kubectl apply -f chat-config.yml -n $NAMESPACE

# Apply services
echo "Applying services..."
kubectl apply -f openim-admin-api-service.yml -n $NAMESPACE
kubectl apply -f openim-admin-rpc-service.yml -n $NAMESPACE
kubectl apply -f openim-chat-api-service.yml -n $NAMESPACE
kubectl apply -f openim-chat-rpc-service.yml -n $NAMESPACE

# Apply Deployments
echo "Applying Deployments..."
kubectl apply -f openim-admin-api-deployment.yml -n $NAMESPACE
kubectl apply -f openim-admin-rpc-deployment.yml -n $NAMESPACE
kubectl apply -f openim-chat-api-deployment.yml -n $NAMESPACE
kubectl apply -f openim-chat-rpc-deployment.yml -n $NAMESPACE

# Apply Ingress
echo "Applying Ingress..."
kubectl apply -f ingress.yml -n $NAMESPACE

echo "OpenIM Server Deployment completed successfully!"
echo "You can check the status with: kubectl get pods -n $NAMESPACE"
echo "Access the Admin API at: http://your-ingress-host/openim-admin-api"
echo "Access the Chat API at: http://your-ingress-host/openim-chat-api"