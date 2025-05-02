#!/bin/bash
set -e

# 获取传入的参数
DEPLOY_ENV="$1"   # 第一个参数：环境（prod 或 test）
JDK_VERSION="$2"  # 第二个参数：JDK 版本（8 或 17）
NAMESPACE="$3"    # 第三个参数：Kubernetes 的命名空间

# 根据 JDK 版本选择 JDK
if [ "$JDK_VERSION" == "17" ]; then
  export JAVA_HOME=/opt/jdk-17.0.4
  export PATH=$PATH:/opt/jdk-17.0.4/bin:/opt/apache-maven-3.6.3/bin
  echo ">>> 使用 JDK 17"
else
  export JAVA_HOME=/opt/jdk1.8.0_332
  export PATH=$PATH:/data/jenkins/jdk1.8.0_332/bin  
  echo ">>> 使用 JDK 8"
fi

# 根据 DEPLOY_ENV 变量决定环境和镜像标签
if [ "$DEPLOY_ENV" == "prod" ]; then
  IMAGE_SUFFIX="prod"
  echo ">>> 部署环境: 生产环境 (prod)"
else
  IMAGE_SUFFIX="test"
  echo ">>> 部署环境: 测试环境 (test)"
fi

# 变量设置
TAG=$(date +%Y%m%d%H%M%S)

# 替换 $SPUG_APP_NAME 中的 _ 为 -
SPUG_APP_NAME_MODIFIED=$(echo "$SPUG_APP_NAME" | sed 's/_/-/g')

# 根据部署环境决定镜像标签
IMAGE_PUBLIC="aliyun-acr-registry.cn-beijing.cr.aliyuncs.com/aliyun-crm/aliyun-crm-acr:${SPUG_APP_NAME_MODIFIED}-${TAG}-${IMAGE_SUFFIX}"
IMAGE_VPC="aliyun-acr-registry-vpc.cn-beijing.cr.aliyuncs.com/aliyun-crm/aliyun-crm-acr:${SPUG_APP_NAME_MODIFIED}-${TAG}-${IMAGE_SUFFIX}"

DOCKERFILE_PATH="docker/Dockerfile"
DEPLOY_YAML_ORIG="/data/repos/deployments/${DEPLOY_ENV}/yaml/${SPUG_APP_NAME_MODIFIED}.yaml"
DEPLOY_YAML_TMP="/tmp/${SPUG_APP_NAME_MODIFIED}-${TAG}.yaml"
CONFIG_YML="/data/repos/config/${DEPLOY_ENV}/${SPUG_APP_NAME_MODIFIED}-${DEPLOY_ENV}.yml"

# 配置不需要 ConfigMap 的服务列表
NO_CONFIGMAP_SERVICES=("registry" "config")  # 替换 your-service-name 为实际名称

echo ">>> 构建服务: $SPUG_APP_NAME_MODIFIED"
echo ">>> 公网镜像: $IMAGE_PUBLIC"
echo ">>> VPC 镜像: $IMAGE_VPC"

# 构建 Jar 包
mvn -B clean package install -pl $SPUG_APP_NAME_MODIFIED -am -Dmaven.test.skip=true -Dautoconfig.skip

# 构建 Docker 镜像
cd $SPUG_APP_NAME_MODIFIED
docker build -f $DOCKERFILE_PATH -t ${SPUG_APP_NAME_MODIFIED} .
docker tag ${SPUG_APP_NAME_MODIFIED} $IMAGE_PUBLIC
docker push $IMAGE_PUBLIC
cd -

# 拉取配置仓库
rm -rf /data/repos/config/${DEPLOY_ENV}
git clone ssh://git@....../config/${DEPLOY_ENV}.git /data/repos/config/${DEPLOY_ENV}

# 拉取部署 YAML 仓库
rm -rf /data/repos/deployments/${DEPLOY_ENV}
git clone ssh://git@....../devops/${DEPLOY_ENV}.git /data/repos/deployments/${DEPLOY_ENV}

# 检查是否需要创建 ConfigMap
NEED_CONFIGMAP=true
for svc in "${NO_CONFIGMAP_SERVICES[@]}"; do
  if [ "$SPUG_APP_NAME_MODIFIED" == "$svc" ]; then
    NEED_CONFIGMAP=false
    break
  fi
done

# 创建 ConfigMap
if [ "$NEED_CONFIGMAP" = true ]; then
  echo ">>> 创建 ConfigMap: ${SPUG_APP_NAME_MODIFIED}"
  kubectl --kubeconfig /data/repos/k8s.conf create configmap ${SPUG_APP_NAME_MODIFIED} \
    --from-file=application.yml=${CONFIG_YML} \
    -n $NAMESPACE --dry-run=client -o yaml | \
    kubectl --kubeconfig /data/repos/k8s.conf apply -f -
else
  echo ">>> 跳过 ConfigMap: ${SPUG_APP_NAME_MODIFIED} 不需要配置文件"
fi

# 替换 YAML 中的镜像变量
cp "$DEPLOY_YAML_ORIG" "$DEPLOY_YAML_TMP"
sed -i "s|\${IMAGE}|${IMAGE_VPC}|g" "$DEPLOY_YAML_TMP"

# 部署服务
echo ">>> 应用 Deployment: $DEPLOY_YAML_TMP"
kubectl --kubeconfig /data/repos/k8s.conf apply -f "$DEPLOY_YAML_TMP"
kubectl --kubeconfig /data/repos/k8s.conf rollout restart deployment/${SPUG_APP_NAME_MODIFIED} -n $NAMESPACE

echo "✅ 发版完成：$SPUG_APP_NAME_MODIFIED @ $TAG"