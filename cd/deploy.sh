#!/usr/bin/env bash
# 用 Helm 部署 / 升级（非 ArgoCD 通道，用于本地验证或纯 Helm 场景）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${RELEASE:-crud}"
NAMESPACE="${NAMESPACE:-crud-demo}"
VERSION="${VERSION:-v1}"
CHART="${CHART:-${ROOT}/charts/crud-app}"

# 解析 helm 可执行文件（winget 安装后 PATH 可能未刷新）
resolve_helm() {
  if command -v helm >/dev/null 2>&1; then
    HELM="helm"
    return
  fi
  local cand
  cand="$(find "${LOCALAPPDATA:-/c/Users/pc/AppData/Local}/Microsoft/WinGet/Packages" \
    -maxdepth 4 -iname 'helm.exe' 2>/dev/null | head -1)"
  if [ -n "${cand}" ]; then
    HELM="${cand}"
  else
    echo "!! 未找到 helm，请先安装：winget install -e --id Helm.Helm" >&2
    exit 1
  fi
}
resolve_helm
echo "==> helm: ${HELM}"

echo "==> 部署 ${RELEASE} -> 命名空间 ${NAMESPACE}（镜像 tag: ${VERSION}）"
"${HELM}" upgrade --install "${RELEASE}" "${CHART}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set "backend.image.tag=${VERSION}" \
  --set "frontend.image.tag=${VERSION}" \
  --wait --timeout 5m

echo "==> 部署结果"
kubectl -n "${NAMESPACE}" get deploy,sts,pod -o wide 2>/dev/null | head -20
echo
kubectl -n "${NAMESPACE}" get svc

cat <<EOF

访问方式：
  kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-frontend 8082:80
  浏览器打开 http://localhost:8082
EOF
