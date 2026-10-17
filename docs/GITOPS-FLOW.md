# GitOps 流程说明

## 1. 一次变更的完整路径

```
开发机                          GitHub                        ArgoCD                    集群
  │                               │                             │                        │
  ├─ 改 charts/values.yaml ──────►│                             │                        │
  │   git commit && git push      │                             │                        │
  │                               ├── repo-server clone ───────►│                        │
  │                               │                             ├─ helm template ────────┤
  │                               │                             ├─ diff 集群实际状态 ────┤
  │                               │                             ├─ 有差异则 apply ──────►│
  │                               │                             │                  Pod 滚动更新
  │                               │                             ◄─ health 检查 ─────────┤
  │                               │                             │  Synced / Healthy      │
```

默认 3 分钟轮询一次；想立刻生效就 `kubectl annotate ... argocd.argoproj.io/refresh=hard`。

## 2. 常见操作

### 改副本数 / 资源 / 镜像 tag

只改 `charts/crud-app/values.yaml`，push 即可。**不要**用 `kubectl scale` 手工改集群——
ArgoCD 的 `selfHeal: true` 会在下一次比对时把你改回去，这正是 GitOps 想要的行为。

### 回滚

```bash
git revert <bad-commit>
git push
```

ArgoCD 检测到 Git 回退后自动把集群回滚到上一状态。无需 `helm rollback`、无需 `kubectl`。

### 新增环境变量

1. 在 `charts/crud-app/values.yaml` 的对应组件下加字段
2. 在模板里用 `{{ .Values.xxx }}` 引用
3. push

### 临时排查（不影响 Git 状态）

```bash
kubectl -n crud-demo logs -f deploy/crud-backend
kubectl -n crud-demo exec -it deploy/crud-mysql -- mysql -ucrud -pcrud123456 crud -e "select * from items;"
kubectl -n crud-demo describe pod <pod>
```

## 3. 排查清单

| 现象 | 原因 | 处理 |
|---|---|---|
| Pod `ImagePullBackOff` | 集群节点没有该镜像，或 `imagePullPolicy` 为 `Always` 仍去外网拉 | 用 `cd/load-images.sh` 导入；chart 默认已是 `IfNotPresent` |
| 前端 502 | `BACKEND_URL` 指向的 service 名不对 | chart 里由 `fullname` 自动拼出，改名时同步改 `fullnameOverride` |
| 后端 `CrashLoopBackOff`，日志 `database not ready` | MySQL 未就绪 / 密码不符 | 后端会重试 120s；检查 Secret 与 `mysql.auth` 是否一致 |
| ArgoCD `ComparisonError` | 仓库不可访问或 chart 渲染失败 | `kubectl -n argocd logs deploy/argocd-repo-server`；本地跑 `helm template` 复现 |
| 手工 `kubectl edit` 后又被改回去 | `selfHeal: true` 正常行为 | 要持久化就改 Git |
| 卸载后数据还在 | PVC 带 `helm.sh/resource-policy: keep` | 需要清空时手动 `kubectl delete pvc` |

## 4. 从 GitOps 切回手工 Helm

```bash
kubectl delete -f argocd/application.yaml   # 反注册
helm install crud charts/crud-app -n crud-demo
```

两者不要同时管理同一批资源，否则会互相覆盖。
