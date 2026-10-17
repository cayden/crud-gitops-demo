# ---------- build stage ----------
FROM node:22-alpine AS build

WORKDIR /app

ENV npm_config_registry=https://registry.npmmirror.com

COPY package.json ./
RUN npm install --no-audit --no-fund

COPY index.html vite.config.js ./
COPY src/ ./src/
RUN npm run build

# ---------- runtime stage ----------
FROM nginx:1.27-alpine

# 运行时用 BACKEND_URL 环境变量渲染 nginx 配置（镜像自带 envsubst 机制）
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html

ENV BACKEND_URL=http://crud-backend:8080

EXPOSE 80

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1/healthz || exit 1
