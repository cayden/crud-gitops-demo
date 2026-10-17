# ---------- build stage ----------
FROM golang:1.23-alpine AS build

WORKDIR /src

# 依赖使用 vendor 目录，构建过程完全离线
COPY go.mod go.sum* ./
COPY vendor/ ./vendor/
COPY main.go ./

ENV CGO_ENABLED=0 GOOS=linux GOFLAGS=-mod=vendor
RUN go build -trimpath -ldflags "-s -w" -o /out/crud-backend .

# ---------- runtime stage ----------
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata wget \
    && addgroup -S app && adduser -S -G app app

WORKDIR /app
COPY --from=build /out/crud-backend /app/crud-backend

ENV PORT=8080 \
    DB_HOST=mysql \
    DB_PORT=3306 \
    DB_NAME=crud \
    DB_USER=crud \
    DB_SEED=true

USER app
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/api/health || exit 1

ENTRYPOINT ["/app/crud-backend"]
