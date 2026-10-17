# crud-gitops

一个完整的 **Go + Vue 3 + MySQL** 增删改查项目，配套 **Helm Chart**、**CD 脚本**、**ArgoCD GitOps 接入** 和 **离线部署包**。

用于演示企业里一条完整的交付链路：代码 → 镜像 → Chart → Git → ArgoCD → 集群 → 离线包。

---

## 一、架构

```
                       ┌──────────────────────────────┐
                       │        Git (GitHub)          │
                       │  backend/ frontend/ charts/  │
                       └──────────────┬───────────────┘
                                      │ clone / poll
                       ┌──────────────▼───────────────┐
                       │          ArgoCD              │
                       │  Application: crud-app       │
                       │  auto-sync + self-heal       │
                       └──────────────┬───────────────┘
                                      │ helm template + apply
┌─────────────────────────────────────▼─────────────────────────────────────┐
│  Kubernetes (namespace: crud-demo)                                        │
│                                                                           │
│   ┌──────────────┐    /api/*     ┌───────────────┐      SQL      ┌───────┐│
│   │  frontend    │ ────────────► │   backend     │ ────────────► │ mysql ││
│   │ nginx + Vue  │               │  Go (net/http)│               │ 8.0   ││
│   │  :80         │               │  :8080        │               │ :3306 ││
│   └──────┬───────┘               └───────────────┘               └───┬───┘│
│          │ NodePort/port-forward                                    │    │
│          │                                                      PVC │    │
└──────────┼──────────────────────────────────────────────────────────┼────┘
           │                                                          │
     浏览器访问                                                 持久化数据
```

**关键设计**

| 关注点 | 做法 |
|---|---|
| 前后端通信 | 前端只请求同源 `/api/...`，由 nginx 反代到后端；后端地址通过 `BACKEND_URL` 环境变量注入，镜像可跨环境复用 |
| 镜像可离线 | 后端静态编译 + `vendor` 依赖，镜像构建不联网 |
| 配置与代码分离 | 所有可变项集中在 `charts/crud-app/values.yaml` |
| 数据库 | Deployment + PVC（`Recreate` 策略），首次启动自动建表并插入演示数据 |
| 幂等 | 后端启动时 `CREATE TABLE IF NOT EXISTS` + 空表才写入种子数据 |

---

## 二、目录结构

```
crud-gitops/
├── backend/                    # Go 后端
│   ├── main.go                 # REST API + 建表 + 种子数据 + 优雅退出
│   ├── go.mod / go.sum
│   ├── vendor/                 # 依赖已 vendor，构建无需联网
│   └── Dockerfile              # 多阶段：golang -> alpine（静态二进制）
├── frontend/                   # Vue 3 前端
│   ├── src/App.vue             # 列表 / 新增 / 编辑 / 删除 / 搜索 / 过滤
│   ├── nginx.conf.template     # 运行时用 BACKEND_URL 渲染反代目标
│   └── Dockerfile              # 多阶段：node -> nginx
├── charts/crud-app/            # Helm Chart
│   ├── values.yaml
│   └── templates/              # backend / frontend / mysql / secret / pvc / svc
├── cd/                         # CD 项目（构建、部署、打包、验证）
│   ├── Makefile                # make e2e / package / status ...
│   ├── build.sh                # 构建两个镜像（基础镜像走国内源）
│   ├── load-images.sh          # 镜像导入 kind 节点
│   ├── deploy.sh               # Helm 部署/升级
│   ├── verify.sh               # 端到端 CRUD 验证（10 项断言）
│   ├── package-offline.sh      # 生成离线部署包
│   └── install.sh              # 离线包内的安装脚本（仅需 kubectl + docker）
├── argocd/application.yaml     # ArgoCD Application（Helm 源）
└── docs/
```

---

## 三、API

基址：`/api`

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/health` | 健康检查（含数据库连通性） |
| GET | `/api/items?q=&status=` | 列表，支持名称/描述模糊搜索、状态过滤 |
| POST | `/api/items` | 新增 |
| GET | `/api/items/{id}` | 查询单条 |
| PUT | `/api/items/{id}` | 更新 |
| DELETE | `/api/items/{id}` | 删除 |

请求体：

```json
{
  "name": "任务名称（必填，≤120 字）",
  "category": "分类，默认 general",
  "status": "pending | doing | done",
  "description": "描述，≤500 字"
}
```

响应示例：

```json
{
  "id": 4,
  "name": "接入 ArgoCD 同步",
  "category": "devops",
  "status": "doing",
  "description": "Git 变更自动同步到集群",
  "createdAt": "2026-10-17 09:20:11",
  "updatedAt": "2026-10-17 09:20:11"
}
```

错误统一为 `{"error": "..."}`，校验失败返回 400，未找到返回 404。

---

## 四、快速开始

### 4.1 前置要求

- Docker（构建镜像 / 加载到 kind）
- kubectl + 一个 K8s 集群（下文以 kind 为例）
- Helm 3（`make package` 与 Helm 部署需要）
- Node 22+（仅本地前端开发需要）

### 4.2 本地开发

```bash
# 后端：需要一个可访问的 MySQL，或先起一个容器
docker run -d --name mysql-dev -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=root123456 -e MYSQL_DATABASE=crud mysql:8.0.36

cd backend
DB_HOST=127.0.0.1 DB_USER=root DB_PASSWORD=root123456 DB_NAME=crud go run .

# 前端
cd frontend
npm install      # 建议先 npm config set registry https://registry.npmmirror.com
npm run dev      # http://localhost:5173，/api 自动代理到 8080
```

### 4.3 部署到 Kubernetes（Helm）

```bash
cd cd

make build       # 构建 crud-backend:v1 / crud-frontend:v1
make load        # 导入 kind 节点（CLUSTER=argocd-demo）
make deploy      # helm upgrade --install crud charts/crud-app -n crud-demo
make verify      # 端到端验证 CRUD

# 前端通过 NodePort 30080 暴露（values.yaml 里 frontend.service.nodePort）
# kind 集群已把节点端口 30080 映射到宿主机 8081，浏览器直接打开：
#   http://localhost:8081
# 非 kind 集群用节点 IP 访问：http://<nodeIP>:30080
#
# 临时访问也可以继续用 port-forward：
kubectl -n crud-demo port-forward svc/crud-frontend 8082:80
# → http://localhost:8082
```

一条命令跑完：`make e2e`

### 4.4 GitOps（ArgoCD）

```bash
kubectl apply -f argocd/application.yaml

# 观察同步
kubectl -n argocd get application crud-app \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status}{"\n"}'
```

之后**任何改动**只需 `git push`：改 `values.yaml` 的副本数、改 `backend/main.go` 后更新镜像 tag，
ArgoCD 都会在 3 分钟内（或手动 refresh）自动把集群收敛到 Git 状态。

强制立即比对：

```bash
kubectl -n argocd annotate application crud-app \
  argocd.argoproj.io/refresh=hard --overwrite
```

### 4.5 离线部署（无外网集群）

```bash
cd cd
make package     # 产出 dist/crud-app-offline-v1.tar.gz

# 拷贝到目标机器后
tar -xzf crud-app-offline-v1.tar.gz
cd crud-app-offline-v1
sha256sum -c sha256sums.txt
./install.sh                        # 默认装到 crud-demo
NAMESPACE=prod-app ./install.sh     # 指定命名空间
./install.sh --uninstall            # 卸载（保留 PVC）
```

安装完 `install.sh` 会打印前端访问方式。离线包里的前端默认是 **ClusterIP**
（避免装到已有 NodePort 30080 的集群上冲突），对外暴露有两种方式：

```bash
# 方式一：装完改成 NodePort
kubectl -n crud-demo patch svc crud-frontend -p '{"spec":{"type":"NodePort"}}'

# 方式二：打包时就渲染成 NodePort（换端口避免冲突）
FRONTEND_SERVICE_TYPE=NodePort NODEPORT=30081 bash cd/package-offline.sh

# 方式三：临时 port-forward
kubectl -n crud-demo port-forward svc/crud-frontend 8082:80
```

离线包内容：

```
crud-app-offline-v1/
├── install.sh              # 仅依赖 kubectl + docker
├── images/                 # 3 个镜像的 docker save 包
├── manifests/all.yaml      # helm template 渲染结果（kubectl apply 即可）
├── charts/                 # Chart（.tgz 与源目录）
├── sha256sums.txt
└── README-OFFLINE.md
```

---

## 五、Helm Chart 参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `fullnameOverride` | `crud` | 资源名前缀，决定 svc 名称 |
| `imagePullPolicy` | `IfNotPresent` | 本地导入镜像必须用它 |
| `backend.image.repository/tag` | `crud-backend` / `v1` | 后端镜像 |
| `backend.replicas` | `3` | 后端副本数（GitOps 演示时从 2 扩到 3） |
| `backend.env.seed` | `true` | 首次启动写入演示数据 |
| `frontend.image.repository/tag` | `crud-frontend` / `v1` | 前端镜像 |
| `frontend.replicas` | `2` | 前端副本数 |
| `frontend.service.type` | `NodePort` | 本机 demo 用 NodePort 直连；离线包默认渲染成 `ClusterIP` |
| `frontend.service.nodePort` | `30080` | kind 只映射了 30080 这一个端口 |
| `mysql.image.repository/tag` | `mysql` / `8.0.36` | 数据库镜像 |
| `mysql.auth.rootPassword` | `root123456` | root 口令 |
| `mysql.auth.username/password` | `crud` / `crud123456` | 业务账号 |
| `mysql.auth.existingSecret` | `""` | 使用已有 Secret（生产推荐） |
| `mysql.persistence.enabled/size` | `true` / `2Gi` | 数据卷 |
| `mysql.persistence.storageClass` | `""` | 空则用集群默认 SC |

生产环境请务必：

```bash
helm upgrade --install crud charts/crud-app -n crud-demo \
  --set mysql.auth.existingSecret=my-db-secret \
  --set backend.image.repository=registry.example.com/crud-backend \
  --set backend.image.tag=v1.2.3
```

---

## 六、CD 脚本说明

| 命令 | 作用 |
|---|---|
| `make build` | 构建两个镜像；基础镜像缺失时自动从 `docker.m.daocloud.io` 拉取并重打 tag |
| `make load` | `docker save \| ctr images import` 导入 kind 节点（规避 `kind load` 的 multi-platform 问题） |
| `make deploy` | `helm upgrade --install`，等待 rollout 完成 |
| `make verify` | 端口转发后依次验证：健康检查、列表、新增、单查、更新、过滤、删除、404、参数校验 |
| `make package` | 生成离线包（镜像 tar + 渲染清单 + chart + install.sh + 校验和） |
| `make status` | 查看 deploy/pod/svc/pvc |

环境变量可覆盖：`VERSION`、`CLUSTER`、`NAMESPACE`、`RELEASE`。

---

## 七、实现要点

- **后端零框架**：仅标准库 `net/http` + `go-sql-driver/mysql`，Go 1.22 的 `POST /api/items`、`/api/items/{id}` 路由语法，无第三方 Web 框架。
- **启动韧性**：数据库未就绪时最多重试 120s，适合容器编排下不确定的启动顺序；`/api/health` 会真实 ping 数据库，K8s 探针据此判断就绪。
- **前端配置注入**：nginx 官方镜像自带 `envsubst` 模板机制，`BACKEND_URL` 在启动时渲染进配置，同一个镜像可在任意命名空间复用。
- **PVC 保护**：`helm.sh/resource-policy: keep`，卸载工作负载不会删掉数据库卷。
- **镜像兼容**：kind 节点用 `ctr import` 而不是 `kind load`，避免 multi-platform manifest 在 CRI 侧解析失败（详见仓库根 README 的踩坑记录）。

---

## 八、清理

```bash
kubectl delete -f argocd/application.yaml    # 移除 ArgoCD 托管（会级联删除资源）
kubectl delete ns crud-demo
kubectl delete pvc -n crud-demo --all        # 数据卷需手动清理
```
