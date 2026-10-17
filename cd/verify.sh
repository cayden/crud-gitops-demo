#!/usr/bin/env bash
# 端到端验证 CRUD：通过 port-forward 打到前端 nginx，再经反代访问 Go 后端
set -euo pipefail

NAMESPACE="${NAMESPACE:-crud-demo}"
RELEASE="${RELEASE:-crud}"
PORT="${PORT:-18099}"
BASE="http://127.0.0.1:${PORT}"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }

echo "==> 端口转发 ${RELEASE}-frontend -> 127.0.0.1:${PORT}"
kubectl -n "${NAMESPACE}" port-forward "svc/${RELEASE}-frontend" "${PORT}:80" >/tmp/crud-pf.log 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  if curl -sf -o /dev/null "${BASE}/healthz"; then break; fi
  sleep 1
done
curl -sf -o /dev/null "${BASE}/healthz" || fail "前端 /healthz 不可达"

# 1. 首页
code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/")
[ "${code}" = "200" ] && pass "GET / -> 200 (前端页面)" || fail "GET / -> ${code}"

# 2. 健康检查（经 nginx 反代到后端）
health=$(curl -s "${BASE}/api/health")
echo "${health}" | grep -q '"status":"ok"' && pass "GET /api/health -> ${health}" || fail "健康检查异常: ${health}"

# 3. 列表
before=$(curl -s "${BASE}/api/items")
count_before=$(printf '%s' "${before}" | grep -o '"id":' | wc -l | tr -d ' ')
pass "GET /api/items -> ${count_before} 条记录"

# 4. 新增
created=$(curl -s -X POST "${BASE}/api/items" \
  -H 'Content-Type: application/json' \
  -d '{"name":"e2e-验证任务","category":"test","status":"doing","description":"由 verify.sh 创建"}')
new_id=$(printf '%s' "${created}" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
[ -n "${new_id}" ] && pass "POST /api/items -> id=${new_id}" || fail "新增失败: ${created}"

# 5. 查询单条
one=$(curl -s "${BASE}/api/items/${new_id}")
echo "${one}" | grep -q 'e2e-验证任务' && pass "GET /api/items/${new_id} -> 命中" || fail "查询失败: ${one}"

# 6. 更新
updated=$(curl -s -X PUT "${BASE}/api/items/${new_id}" \
  -H 'Content-Type: application/json' \
  -d '{"name":"e2e-验证任务(已更新)","category":"test","status":"done","description":"状态改为 done"}')
echo "${updated}" | grep -q '"status":"done"' && pass "PUT /api/items/${new_id} -> 状态已改为 done" || fail "更新失败: ${updated}"

# 7. 过滤查询
filtered=$(curl -s "${BASE}/api/items?status=done")
echo "${filtered}" | grep -q 'e2e-验证任务(已更新)' && pass "GET /api/items?status=done -> 过滤生效" || fail "过滤失败"

# 8. 删除
del=$(curl -s -X DELETE "${BASE}/api/items/${new_id}")
echo "${del}" | grep -q "\"deleted\":${new_id}" && pass "DELETE /api/items/${new_id} -> 已删除" || fail "删除失败: ${del}"

# 9. 删除后应 404
code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/items/${new_id}")
[ "${code}" = "404" ] && pass "GET 已删除记录 -> 404" || fail "删除后仍可访问 (${code})"

# 10. 参数校验
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/api/items" \
  -H 'Content-Type: application/json' -d '{"name":""}')
[ "${code}" = "400" ] && pass "空名称校验 -> 400" || fail "校验返回 ${code}"

echo
echo "==> 全部通过 ✅"
