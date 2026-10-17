# ===== crud-gitops CD 入口 =====
# 常用：make e2e（构建 -> 导入 -> 部署 -> 验证）
VERSION   ?= v1
CLUSTER   ?= argocd-demo
NAMESPACE ?= crud-demo
RELEASE   ?= crud

SHELL := /usr/bin/env bash

.PHONY: help all build load deploy verify package e2e uninstall clean status

help:
	@echo "crud-gitops CD 命令"
	@echo ""
	@echo "  make build      构建 crud-backend / crud-frontend 镜像 (VERSION=$(VERSION))"
	@echo "  make load       把镜像导入 kind 集群节点 (CLUSTER=$(CLUSTER))"
	@echo "  make deploy     Helm 部署/升级到命名空间 (NAMESPACE=$(NAMESPACE))"
	@echo "  make verify     端到端 CRUD 验证"
	@echo "  make e2e        build + load + deploy + verify 一条龙"
	@echo "  make package    生成离线部署包 dist/crud-app-offline-$(VERSION).tar.gz"
	@echo "  make status     查看部署状态"
	@echo "  make uninstall  Helm 卸载"
	@echo "  make clean      清理 dist 与本地镜像"

all: e2e

build:
	VERSION=$(VERSION) bash cd/build.sh

load:
	VERSION=$(VERSION) CLUSTER=$(CLUSTER) bash cd/load-images.sh

deploy:
	VERSION=$(VERSION) NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) bash cd/deploy.sh

verify:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) bash cd/verify.sh

e2e: build load deploy verify

package:
	VERSION=$(VERSION) NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) bash cd/package-offline.sh

status:
	kubectl -n $(NAMESPACE) get deploy,pod,svc,pvc

uninstall:
	helm uninstall $(RELEASE) -n $(NAMESPACE) || true

clean:
	rm -rf dist
	-docker rmi crud-backend:$(VERSION) crud-frontend:$(VERSION) 2>/dev/null || true
