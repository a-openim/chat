# Kubernetes RBAC Fix for OpenIM Chat

## Problem

The OpenIM chat services were experiencing Kubernetes RBAC (Role-Based Access Control) errors:

```
pods is forbidden: User "system:serviceaccount:openim:default" cannot list resource "pods" in API group "" at the cluster scope
services "admin-rpc-service" is forbidden: User "system:serviceaccount:openim:default" cannot get resource "services" in API group "" in the namespace "default"
```

The services were using the default service account which lacked the necessary permissions to:
- List pods at cluster scope
- Get services in the `default` namespace

## Solution

Created comprehensive RBAC resources to grant the required permissions:

### Files Created/Modified

1. **`openim-rbac.yml`** - New RBAC configuration file containing:
   - `ServiceAccount`: `openim-service-account` in the `openim` namespace
   - `ClusterRole`: `openim-pod-reader` - grants permission to list pods cluster-wide
   - `ClusterRole`: `openim-service-reader` - grants permission to get/list/watch services cluster-wide
   - `ClusterRoleBinding`: Binds the service account to the cluster roles
   - `Role`: `openim-service-reader-default` - grants service access in the `default` namespace
   - `RoleBinding`: Binds the service account to the role in the `default` namespace

2. **Updated Deployment Files** - Added `serviceAccountName: openim-service-account` to:
   - `openim-chat-rpc-deployment.yml`
   - `openim-admin-rpc-deployment.yml`
   - `openim-chat-api-deployment.yml`
   - `openim-admin-api-deployment.yml`

3. **`apply-rbac-and-redeploy.sh`** - Deployment script to apply RBAC and redeploy services

## How to Apply the Fix

### Option 1: Using the Deployment Script (Recommended)

```bash
./deployments/deploy/apply-rbac-and-redeploy.sh
```

This script will:
1. Apply the RBAC configuration
2. Restart all OpenIM deployments
3. Wait for pods to be ready
4. Display the chat-rpc pod logs

### Option 2: Manual Steps

1. Apply the RBAC configuration:
```bash
kubectl apply -f deployments/deploy/openim-rbac.yml
```

2. Redeploy each service:
```bash
kubectl rollout restart deployment/chat-rpc-server -n openim
kubectl rollout restart deployment/admin-rpc-server -n openim
kubectl rollout restart deployment/chat-api-server -n openim
kubectl rollout restart deployment/admin-api-server -n openim
```

3. Verify the pods are running:
```bash
kubectl get pods -n openim
```

4. Check the logs to ensure no RBAC errors:
```bash
kubectl logs -l app=chat-rpc-server -n openim --tail=20
```

## Verification

After applying the fix, the pod logs should no longer show RBAC errors. The services should be able to:
- List pods at cluster scope
- Get services in the `default` namespace

## RBAC Permissions Granted

The following permissions are granted to the `openim-service-account`:

### Cluster-wide Permissions (via ClusterRoles)
- **Pods**: `get`, `list`, `watch` (all namespaces)
- **Services**: `get`, `list`, `watch` (all namespaces)

### Namespace-specific Permissions (via Role)
- **Services in `default` namespace**: `get`, `list`, `watch`

## Security Considerations

The RBAC configuration grants the minimum necessary permissions for the OpenIM services to function. If you need to restrict permissions further, consider:
- Using namespace-scoped roles instead of cluster roles
- Limiting the resources to specific namespaces
- Using more specific resource names in the role definitions

## Troubleshooting

If you still encounter RBAC errors after applying the fix:

1. Verify the RBAC resources were created:
```bash
kubectl get serviceaccount,clusterrole,clusterrolebinding,role,rolebinding -n openim
kubectl get role,rolebinding -n default
```

2. Check the service account is correctly assigned to pods:
```bash
kubectl get pod -n openim -o jsonpath='{.items[*].spec.serviceAccountName}'
```

3. Review the RBAC permissions:
```bash
kubectl auth can-i list pods --as=system:serviceaccount:openim:openim-service-account
kubectl auth can-i get services --as=system:serviceaccount:openim:openim-service-account -n default
```
