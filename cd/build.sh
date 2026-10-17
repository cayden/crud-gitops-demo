#!/usr/bin/env bash
# 构建前后端镜像
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-v1}"
BACKEND_IMAGE="${BACKEND_IMAGE:-crud-backend}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-crud-frontend}"
MIRROR="${MIRROR:-docker.m.daocloud.io/library}"

echo "==> 构建版本: ${VERSION}"

# 基础镜像走国内源，本地缺 tag 时自动补齐（避免 Docker Hub 超时）
ensure_base() {
  local image="$1" mirrored="$2"
  if docker image inspect "${image}" >/dev/null 2>&1; then
    echo "    [base] ${image} 已存在"
    return
  fi
  echo "    [base] 拉取 ${mirrored} 并打标签为 ${image}"
  docker pull "${mirrored}"
  docker tag "${mirrored}" "${image}"
}

ensure_base "golang:1.23-alpine"    "${MIRROR}/golang:1.23-alpine"
ensure_base "node:22-alpine"        "${MIRROR}/node:22-alpine"
ensure_base "alpine:3.20"           "${MIRROR}/alpine:3.20"
ensure_base "nginx:1.27-alpine"     "${MIRROR}/nginx:1.27-alpine"

echo "==> 构建后端 ${BACKEND_IMAGE}:${VERSION}"
docker build -t "${BACKEND_IMAGE}:${VERSION}" "${ROOT}/backend"

echo "==> 构建前端 ${FRONTEND_IMAGE}:${VERSION}"
docker build -t "${FRONTEND_IMAGE}:${VERSION}" "${ROOT}/frontend"

echo "==> 完成"
docker images --format '    {{.Repository}}:{{.Tag}}  {{.Size}}' \
  | grep -E "${BACKEND_IMAGE}|${FRONTEND_IMAGE}" || true
