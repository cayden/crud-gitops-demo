#!/usr/bin/env bash
# 把镜像导入 kind 集群节点（kind 节点默认看不到宿主机 Docker 镜像）
set -euo pipefail

VERSION="${VERSION:-v1}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.0.36}"
MIRROR="${MIRROR:-docker.m.daocloud.io/library}"

IMAGES=("crud-backend:${VERSION}" "crud-frontend:${VERSION}" "${MYSQL_IMAGE}")

# mysql 镜像若只有镜像源 tag，先规范成本地标准 tag
if ! docker image inspect "${MYSQL_IMAGE}" >/dev/null 2>&1; then
  echo "==> 本地缺少 ${MYSQL_IMAGE}，从镜像源补齐"
  docker pull "${MIRROR}/mysql:${MYSQL_IMAGE##*:}"
  docker tag "${MIRROR}/mysql:${MYSQL_IMAGE##*:}" "${MYSQL_IMAGE}"
fi

for img in "${IMAGES[@]}"; do
  docker image inspect "${img}" >/dev/null 2>&1 || {
    echo "!! 本地缺少镜像 ${img}，请先执行 make build" >&2
    exit 1
  }
done

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
echo "==> 当前集群: ${CTX}"

NODE=""
case "${CTX}" in
  kind-*) NODE="${CTX#kind-}-control-plane" ;;
esac

if [ -n "${NODE}" ] && docker inspect "${NODE}" >/dev/null 2>&1; then
  echo "==> 导入镜像到 kind 节点 ${NODE}"
  for img in "${IMAGES[@]}"; do
    printf '    -> %s\n' "${img}"
    # 用 ctr import 而非 kind load，规避 multi-platform manifest 在 CRI 侧解析失败
    docker save "${img}" | docker exec -i "${NODE}" \
      ctr --namespace=k8s.io images import --snapshotter=overlayfs - >/dev/null
  done
  echo "==> 节点内镜像："
  docker exec "${NODE}" crictl images 2>/dev/null \
    | grep -E "crud-backend|crud-frontend|mysql" \
    | awk '{printf "    %s:%s  %s\n", $1, $2, $3}' || true
  exit 0
fi

echo "==> 非 kind 集群（${CTX}），跳过节点导入"
echo "    这些镜像已在本地 Docker 中：${IMAGES[*]}"
echo "    常规集群请推送到私有 registry，再用离线包/--set image.repository 指向它"
