#!/usr/bin/env bash
# 生成离线部署包：镜像 tar + Helm chart + 渲染好的 manifests + install.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-v1}"
NAMESPACE="${NAMESPACE:-crud-demo}"
RELEASE="${RELEASE:-crud}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0.36}"
DIST="${ROOT}/dist"
STAGE="${DIST}/crud-app-offline-${VERSION}"

resolve_helm() {
  if command -v helm >/dev/null 2>&1; then HELM="helm"; return; fi
  local cand
  cand="$(find "${LOCALAPPDATA:-/c/Users/pc/AppData/Local}/Microsoft/WinGet/Packages" \
    -maxdepth 4 -iname 'helm.exe' 2>/dev/null | head -1)"
  [ -n "${cand}" ] || { echo "!! 未找到 helm" >&2; exit 1; }
  HELM="${cand}"
}
resolve_helm

echo "==> 准备目录 ${STAGE}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/images" "${STAGE}/manifests" "${STAGE}/charts"

echo "==> 渲染 manifests（kubectl apply 即可安装，无需 helm）"
# 离线包默认渲染成 ClusterIP：装到任何集群都不会与已有 NodePort 冲突
# 需要直接对外暴露时用 FRONTEND_SERVICE_TYPE=NodePort NODEPORT=30081 重新打包
SET_ARGS=(--set "frontend.service.type=${FRONTEND_SERVICE_TYPE:-ClusterIP}")
if [ -n "${NODEPORT:-}" ]; then
  SET_ARGS+=(--set "frontend.service.nodePort=${NODEPORT}")
fi
"${HELM}" template "${RELEASE}" "${ROOT}/charts/crud-app" \
  --namespace "${NAMESPACE}" "${SET_ARGS[@]}" > "${STAGE}/manifests/all.yaml"
echo "    前端 Service 类型: ${FRONTEND_SERVICE_TYPE:-ClusterIP}"
echo "    $(grep -c '^kind:' "${STAGE}/manifests/all.yaml") 个资源"

echo "==> 打包 Helm chart"
"${HELM}" package "${ROOT}/charts/crud-app" -d "${STAGE}/charts" >/dev/null
cp -r "${ROOT}/charts/crud-app" "${STAGE}/charts/crud-app"

echo "==> 导出镜像"
for pair in "crud-backend:${VERSION}" "crud-frontend:${VERSION}" "${MYSQL_IMAGE}"; do
  name="${pair%%:*}"; tag="${pair##*:}"
  base="${name##*/}"
  out="${STAGE}/images/${base}-${tag}.tar"
  echo "    -> ${pair}  ($(docker image inspect -f '{{.Size}}' "${pair}" | awk '{printf "%.0f MB", $1/1024/1024}'))"
  docker save -o "${out}" "${pair}"
done

echo "==> 拷贝安装脚本与说明"
cp "${ROOT}/cd/install.sh" "${STAGE}/install.sh"
chmod +x "${STAGE}/install.sh"

cat > "${STAGE}/README-OFFLINE.md" <<EOF
# crud-app 离线部署包 (${VERSION})

适用于**无法访问外网**的 Kubernetes 集群：所有镜像、Chart、YAML 都已内置。

## 包内容

\`\`\`
crud-app-offline-${VERSION}/
├── install.sh              # 一键安装（只需 kubectl + docker）
├── images/                 # 三个镜像的 docker save 包
├── manifests/all.yaml      # helm template 渲染结果（kubectl apply 即装）
├── charts/                 # Helm Chart（.tgz + 源目录，可 helm install）
└── sha256sums.txt          # 校验和
\`\`\`

## 安装

\`\`\`bash
# 校验完整性
sha256sum -c sha256sums.txt

# 安装到默认命名空间 ${NAMESPACE}
./install.sh

# 或指定命名空间
NAMESPACE=prod-app ./install.sh
\`\`\`

安装脚本会：把镜像导入节点 → 创建命名空间 → \`kubectl apply\` 渲染好的清单 → 等待滚动就绪 → 打印访问方式。

## 访问

\`\`\`bash
kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-frontend 8082:80
# 浏览器打开 http://localhost:8082
\`\`\`

## 用 Helm 安装（可选）

\`\`\`bash
helm install ${RELEASE} charts/crud-app-0.1.0.tgz -n ${NAMESPACE} --create-namespace \\
  --set backend.image.tag=${VERSION} --set frontend.image.tag=${VERSION}
\`\`\`

## 卸载

\`\`\`bash
NAMESPACE=${NAMESPACE} ./install.sh --uninstall
# 或 kubectl delete -f manifests/all.yaml
\`\`\`

> 数据库 PVC 带 \`helm.sh/resource-policy: keep\`，直接删工作负载不会丢数据；
> 如需清空数据请手动删除 PVC。
EOF

echo "==> 生成校验和"
( cd "${STAGE}" && find images -name '*.tar' -type f | sort | xargs sha256sum > sha256sums.txt )
cat "${STAGE}/sha256sums.txt" | sed 's/^/    /'

echo "==> 压缩"
OUT_TGZ="${DIST}/crud-app-offline-${VERSION}.tar.gz"
tar -czf "${OUT_TGZ}" -C "${DIST}" "crud-app-offline-${VERSION}"
SIZE=$(du -h "${OUT_TGZ}" | awk '{print $1}')
echo
echo "==> 离线包已生成: ${OUT_TGZ}  (${SIZE})"
