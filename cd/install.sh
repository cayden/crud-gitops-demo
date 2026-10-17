#!/usr/bin/env bash
# 离线安装脚本 —— 只需要 kubectl 和 docker，不依赖 helm / 外网
# 用法：
#   ./install.sh                 安装到默认命名空间 crud-demo
#   NAMESPACE=prod ./install.sh  安装到指定命名空间
#   NAMESPACE=prod SKIP_IMAGES=1 ./install.sh   跳过镜像导入
#   ./install.sh --uninstall     卸载（保留 PVC 与命名空间）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-crud-demo}"
RENDERED_NS="crud-demo"          # helm template 时写入的命名空间
MODE="${1:-install}"
SKIP_IMAGES="${SKIP_IMAGES:-0}"
RELEASE_NAME="crud"

log()  { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$1"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$1" >&2; exit 1; }

[ -f "${HERE}/manifests/all.yaml" ] || die "缺少 manifests/all.yaml，包不完整"

# ---------- 卸载 ----------
if [ "${MODE}" = "--uninstall" ]; then
  log "卸载命名空间 ${NAMESPACE} 中的应用资源（PVC 保留）"
  sed "s/namespace: ${RENDERED_NS}/namespace: ${NAMESPACE}/g" "${HERE}/manifests/all.yaml" \
    | kubectl delete -f - --ignore-not-found
  log "已卸载。如需彻底清理：kubectl delete ns ${NAMESPACE}"
  exit 0
fi

# ---------- 前置检查 ----------
command -v kubectl >/dev/null 2>&1 || die "未找到 kubectl"
command -v docker  >/dev/null 2>&1 || die "未找到 docker"
kubectl cluster-info >/dev/null 2>&1 || die "无法连接 Kubernetes 集群（检查 kubeconfig）"

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
log "目标集群: ${CTX} / 命名空间: ${NAMESPACE}"

# ---------- 导入镜像 ----------
if [ "${SKIP_IMAGES}" = "1" ]; then
  log "SKIP_IMAGES=1，跳过镜像导入"
else
  NODE=""
  case "${CTX}" in
    kind-*) NODE="${CTX#kind-}-control-plane" ;;
  esac

  if [ -n "${NODE}" ] && docker inspect "${NODE}" >/dev/null 2>&1; then
    log "检测到 kind 节点 ${NODE}，用 ctr 导入镜像"
    for f in "${HERE}"/images/*.tar; do
      printf '    -> %s\n' "$(basename "$f")"
      docker exec -i "${NODE}" ctr --namespace=k8s.io images import \
        --snapshotter=overlayfs - < "$f" >/dev/null
    done
  else
    log "非 kind 集群，使用 docker load（镜像需已推送到集群可访问的仓库，或节点与 docker 同机）"
    for f in "${HERE}"/images/*.tar; do
      printf '    -> %s\n' "$(basename "$f")"
      docker load -i "$f" >/dev/null
    done
    warn "若节点无法访问本地 docker 镜像，请推送到私有 registry 并 --set image.repository"
  fi
fi

# ---------- 应用清单 ----------
log "创建命名空间（如不存在）"
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

log "应用 manifests/all.yaml"
TMP="$(mktemp)"
sed "s/namespace: ${RENDERED_NS}/namespace: ${NAMESPACE}/g" "${HERE}/manifests/all.yaml" > "${TMP}"
kubectl apply -f "${TMP}"
rm -f "${TMP}"

# ---------- 等待就绪 ----------
log "等待 MySQL 就绪（首次启动初始化约 30~60s）"
kubectl -n "${NAMESPACE}" rollout status deploy/"${RELEASE_NAME}"-mysql --timeout=300s

log "等待后端就绪"
kubectl -n "${NAMESPACE}" rollout status deploy/"${RELEASE_NAME}"-backend --timeout=240s

log "等待前端就绪"
kubectl -n "${NAMESPACE}" rollout status deploy/"${RELEASE_NAME}"-frontend --timeout=180s

# ---------- 输出结果 ----------
echo
kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/part-of=crud-app -o wide 2>/dev/null \
  || kubectl -n "${NAMESPACE}" get pods

FRONTEND_TYPE="$(kubectl -n "${NAMESPACE}" get svc "${RELEASE_NAME}-frontend" \
  -o jsonpath='{.spec.type}' 2>/dev/null || echo unknown)"

cat <<EOF

安装完成 ✅

前端 Service 类型：${FRONTEND_TYPE}
EOF

if [ "${FRONTEND_TYPE}" = "NodePort" ]; then
  NODEPORT="$(kubectl -n "${NAMESPACE}" get svc "${RELEASE_NAME}-frontend" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo '')"
  NODEIP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo '<节点IP>')"
  cat <<EOF
直接访问（NodePort ${NODEPORT}）：
  http://${NODEIP}:${NODEPORT}
  集群在 Docker 里（kind）时，需先给节点做端口映射，否则用下面的 port-forward
EOF
else
  cat <<EOF
从集群外访问（ClusterIP 需要转发）：
  kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-frontend 8082:80
  → http://localhost:8082

想长期对外暴露，执行其一即可：
  # 1) 改成 NodePort（集群节点 IP 可直连）
  kubectl -n ${NAMESPACE} patch svc ${RELEASE_NAME}-frontend \\
    -p '{"spec":{"type":"NodePort"}}'
  # 2) 用 Ingress / Gateway 接入现有入口
EOF
fi

cat <<EOF

验证 API：
  kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-backend 8090:8080
  curl -s http://localhost:8090/api/items

卸载：
  NAMESPACE=${NAMESPACE} ./install.sh --uninstall
EOF
