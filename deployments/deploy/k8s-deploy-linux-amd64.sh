#!/bin/bash

# OpenIM Server Deployment Script for Linux AMD64
# 优化版：支持构建容错、错误汇总打印、批量处理

# 注意：这里去掉了 set -e，因为我们需要手动处理错误逻辑
# set -e 

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
  docker buildx create --use --name openim-builder
else
  docker buildx use openim-builder
fi

# 服务列表
services=("openim-admin-api" "openim-admin-rpc" "openim-chat-api" "openim-chat-rpc")

# 1. 编译与推送阶段
read -p "Do you want to run docker build? (y/n): " run_docker_build
if [[ "$run_docker_build" =~ ^[Yy]$ ]]; then
  echo "Building and pushing Docker images..."

  for service in "${services[@]}"; do
    IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${service}:${VERSION}"
    echo "----------------------------------------------------------"
    echo "Processing: $service"
    
    # 执行构建（设置超时或普通执行）
    if docker buildx build --platform linux/amd64 --load -t $IMAGE_TAG -f build/images/$service/Dockerfile . ; then
      echo "Build $service success, pushing..."
      if docker push $IMAGE_TAG; then
        echo -e "\033[32mSUCCESS: $service pushed.\033[0m"
      else
        echo -e "\033[31mERROR: Push failed for $service\033[0m"
        FAILED_SERVICES+=("$service (Push Failed)")
      fi
    else
      echo -e "\033[31mERROR: Build failed or timeout for $service\033[0m"
      FAILED_SERVICES+=("$service (Build Failed)")
    fi
  done

  # 汇总输出
  echo "=========================================================="
  if [ ${#FAILED_SERVICES[@]} -ne 0 ]; then
    echo -e "\033[31mBUILD SUMMARY: THE FOLLOWING SERVICES FAILED:\033[0m"
    for failed in "${FAILED_SERVICES[@]}"; do
      echo -e "\033[31m- $failed\033[0m"
    done
    echo "=========================================================="
    read -p "Some images failed. Continue to deploy others? (y/n): " continue_deploy
    if [[ ! "$continue_deploy" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  else
    echo -e "\033[32mBUILD SUMMARY: ALL IMAGES COMPLETED SUCCESSFULLY.\033[0m"
    echo "=========================================================="
  fi
  
  # 只有在有成功构建的情况下才更新版本号
  echo $VERSION > .version
else
  if [ -f ".version" ]; then
    VERSION=$(cat .version)
    echo "Using existing version: $VERSION"
  else
    echo "No .version file found and build skipped. Exiting."
    exit 1
  fi
fi

# 2. 更新 YAML 阶段
echo "Updating deployment YAMLs..."
for service in "${services[@]}"; do
  DEPLOYMENT_FILE="deployments/deploy/${service}-deployment.yml"
  IMAGE_TAG="${HARBOR_URL}/${HARBOR_PROJECT}/${service}:${VERSION}"
  if [ -f "$DEPLOYMENT_FILE" ]; then
    # 注意：macOS 的 sed 和 linux 有区别，这里通用处理
    sed -i.bak "s|image: .*/${service}:.*|image: ${IMAGE_TAG}|g" $DEPLOYMENT_FILE
    echo "Updated $DEPLOYMENT_FILE"
  fi
done

# 3. 部署阶段
echo "Starting K8s Deployment in namespace: $NAMESPACE"

# Apply ConfigMap
kubectl apply -f deployments/deploy/chat-config.yml -n $NAMESPACE

# 批量 Apply Services 和 Deployments
for service in "${services[@]}"; do
  SVC_FILE="deployments/deploy/${service}-service.yml"
  DEP_FILE="deployments/deploy/${service}-deployment.yml"
  
  [ -f "$SVC_FILE" ] && kubectl apply -f "$SVC_FILE" -n $NAMESPACE
  [ -f "$DEP_FILE" ] && kubectl apply -f "$DEP_FILE" -n $NAMESPACE
done

# Apply Ingress
[ -f "deployments/deploy/ingress.yml" ] && kubectl apply -f deployments/deploy/ingress.yml -n $NAMESPACE

echo "----------------------------------------------------------"
echo "Deployment Finished!"
echo "Check pods: kubectl get pods -n $NAMESPACE"

say -v Meijia "congratulations"
