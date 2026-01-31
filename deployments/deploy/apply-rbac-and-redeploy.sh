#!/bin/bash

# Script to apply RBAC configuration and redeploy OpenIM services

set -e

echo "=========================================="
echo "Applying RBAC configuration..."
echo "=========================================="

# Apply RBAC configuration
kubectl apply -f deployments/deploy/openim-rbac.yml

echo ""
echo "RBAC configuration applied successfully!"
echo ""
echo "=========================================="
echo "Redeploying OpenIM services..."
echo "=========================================="

# Redeploy chat-rpc
echo "Redeploying chat-rpc..."
kubectl rollout restart deployment/chat-rpc-server -n openim

# Redeploy admin-rpc
echo "Redeploying admin-rpc..."
kubectl rollout restart deployment/admin-rpc-server -n openim

# Redeploy chat-api
echo "Redeploying chat-api..."
kubectl rollout restart deployment/chat-api-server -n openim

# Redeploy admin-api
echo "Redeploying admin-api..."
kubectl rollout restart deployment/admin-api-server -n openim

echo ""
echo "=========================================="
echo "Services redeployed successfully!"
echo "=========================================="
echo ""
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=chat-rpc-server -n openim --timeout=120s
kubectl wait --for=condition=ready pod -l app=admin-rpc-server -n openim --timeout=120s
kubectl wait --for=condition=ready pod -l app=chat-api-server -n openim --timeout=120s
kubectl wait --for=condition=ready pod -l app=admin-api-server -n openim --timeout=120s

echo ""
echo "=========================================="
echo "All pods are ready!"
echo "=========================================="
echo ""
echo "Checking pod logs..."
kubectl logs -l app=chat-rpc-server -n openim --tail=20
