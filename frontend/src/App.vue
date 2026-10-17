<script setup>
import { computed, onMounted, reactive, ref } from 'vue'

const API = '/api/items'
const STATUS = {
  pending: { label: '待处理', cls: 'is-pending' },
  doing: { label: '进行中', cls: 'is-doing' },
  done: { label: '已完成', cls: 'is-done' },
}

const items = ref([])
const loading = ref(false)
const error = ref('')
const toast = ref('')

const q = ref('')
const statusFilter = ref('')

const formOpen = ref(false)
const editingId = ref(null)
const saving = ref(false)
const formError = ref('')
const form = reactive({ name: '', category: 'general', status: 'pending', description: '' })

const confirmTarget = ref(null)

const stats = computed(() => {
  const total = items.value.length
  const by = { pending: 0, doing: 0, done: 0 }
  items.value.forEach((it) => {
    if (by[it.status] !== undefined) by[it.status] += 1
  })
  return { total, ...by }
})

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  })
  const text = await res.text()
  let data = null
  if (text) {
    try {
      data = JSON.parse(text)
    } catch {
      data = text
    }
  }
  if (!res.ok) {
    const msg = (data && data.error) || `请求失败 (HTTP ${res.status})`
    throw new Error(msg)
  }
  return data
}

let searchTimer = null
function onSearch() {
  clearTimeout(searchTimer)
  searchTimer = setTimeout(fetchItems, 260)
}

async function fetchItems() {
  loading.value = true
  error.value = ''
  try {
    const params = new URLSearchParams()
    if (q.value.trim()) params.set('q', q.value.trim())
    if (statusFilter.value) params.set('status', statusFilter.value)
    const qs = params.toString()
    items.value = (await api(`${API}${qs ? `?${qs}` : ''}`)) || []
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

function showToast(msg) {
  toast.value = msg
  setTimeout(() => {
    if (toast.value === msg) toast.value = ''
  }, 2200)
}

function openCreate() {
  editingId.value = null
  formError.value = ''
  Object.assign(form, { name: '', category: 'general', status: 'pending', description: '' })
  formOpen.value = true
}

function openEdit(item) {
  editingId.value = item.id
  formError.value = ''
  Object.assign(form, {
    name: item.name,
    category: item.category || 'general',
    status: item.status || 'pending',
    description: item.description || '',
  })
  formOpen.value = true
}

function closeForm() {
  if (!saving.value) formOpen.value = false
}

async function save() {
  if (!form.name.trim()) {
    formError.value = '名称不能为空'
    return
  }
  saving.value = true
  formError.value = ''
  try {
    const body = JSON.stringify({
      name: form.name.trim(),
      category: form.category.trim() || 'general',
      status: form.status,
      description: form.description.trim(),
    })
    if (editingId.value) {
      await api(`${API}/${editingId.value}`, { method: 'PUT', body })
      showToast('已保存修改')
    } else {
      await api(API, { method: 'POST', body })
      showToast('已新增任务')
    }
    formOpen.value = false
    await fetchItems()
  } catch (e) {
    formError.value = e.message
  } finally {
    saving.value = false
  }
}

async function doDelete() {
  const target = confirmTarget.value
  if (!target) return
  try {
    await api(`${API}/${target.id}`, { method: 'DELETE' })
    confirmTarget.value = null
    showToast('已删除')
    await fetchItems()
  } catch (e) {
    confirmTarget.value = null
    error.value = e.message
  }
}

onMounted(fetchItems)
</script>

<template>
  <div class="page">
    <header class="hero">
      <div class="hero-inner">
        <div class="brand">
          <div class="logo">TF</div>
          <div class="brand-text">
            <h1>TaskFlow</h1>
            <p>Go · Vue 3 · MySQL · ArgoCD GitOps</p>
          </div>
        </div>
        <div class="stats">
          <div class="stat">
            <span>{{ stats.total }}</span>
            <small>全部</small>
          </div>
          <div class="stat">
            <span>{{ stats.pending }}</span>
            <small>待处理</small>
          </div>
          <div class="stat">
            <span>{{ stats.doing }}</span>
            <small>进行中</small>
          </div>
          <div class="stat">
            <span>{{ stats.done }}</span>
            <small>已完成</small>
          </div>
        </div>
      </div>
    </header>

    <main class="container">
      <section class="card toolbar">
        <div class="field search-field">
          <input v-model="q" type="search" placeholder="搜索名称或描述…" @input="onSearch" />
        </div>
        <div class="field filter-field">
          <select v-model="statusFilter" @change="fetchItems">
            <option value="">全部状态</option>
            <option value="pending">待处理</option>
            <option value="doing">进行中</option>
            <option value="done">已完成</option>
          </select>
        </div>
        <button class="btn ghost" :disabled="loading" @click="fetchItems">刷新</button>
        <button class="btn primary" @click="openCreate">+ 新增任务</button>
      </section>

      <p v-if="error" class="alert">{{ error }}</p>

      <section class="card table-card">
        <table>
          <thead>
            <tr>
              <th class="col-id">#</th>
              <th>名称</th>
              <th class="col-cat">分类</th>
              <th class="col-status">状态</th>
              <th class="col-desc">描述</th>
              <th class="col-time">更新时间</th>
              <th class="col-act">操作</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="item in items" :key="item.id">
              <td class="col-id mono">{{ item.id }}</td>
              <td class="col-name">{{ item.name }}</td>
              <td class="col-cat"><span class="tag">{{ item.category }}</span></td>
              <td class="col-status">
                <span class="badge" :class="STATUS[item.status]?.cls || 'is-pending'">
                  {{ STATUS[item.status]?.label || item.status }}
                </span>
              </td>
              <td class="col-desc muted">{{ item.description || '—' }}</td>
              <td class="col-time mono">{{ item.updatedAt }}</td>
              <td class="col-act">
                <button class="link" @click="openEdit(item)">编辑</button>
                <button class="link danger" @click="confirmTarget = item">删除</button>
              </td>
            </tr>
          </tbody>
        </table>

        <div v-if="loading" class="placeholder">加载中…</div>
        <div v-else-if="items.length === 0" class="placeholder">
          <strong>暂无数据</strong>
          <span>点击「新增任务」创建第一条记录</span>
        </div>
      </section>
    </main>

    <transition name="fade">
      <div v-if="formOpen" class="overlay" @click.self="closeForm">
        <div class="modal card">
          <h2>{{ editingId ? '编辑任务' : '新增任务' }}</h2>
          <p class="muted sub">数据通过 Go API 写入 MySQL</p>

          <label class="field">
            <span>名称 <em>*</em></span>
            <input v-model="form.name" maxlength="120" placeholder="例如：修复登录接口超时" />
          </label>

          <div class="row">
            <label class="field">
              <span>分类</span>
              <input v-model="form.category" maxlength="60" placeholder="general" />
            </label>
            <label class="field">
              <span>状态</span>
              <select v-model="form.status">
                <option value="pending">待处理</option>
                <option value="doing">进行中</option>
                <option value="done">已完成</option>
              </select>
            </label>
          </div>

          <label class="field">
            <span>描述</span>
            <textarea v-model="form.description" maxlength="500" placeholder="可选，最多 500 字" />
          </label>

          <p v-if="formError" class="alert">{{ formError }}</p>

          <div class="actions">
            <button class="btn ghost" :disabled="saving" @click="closeForm">取消</button>
            <button class="btn primary" :disabled="saving" @click="save">
              {{ saving ? '保存中…' : '保存' }}
            </button>
          </div>
        </div>
      </div>
    </transition>

    <transition name="fade">
      <div v-if="confirmTarget" class="overlay" @click.self="confirmTarget = null">
        <div class="modal card small">
          <h2>确认删除</h2>
          <p class="muted">删除后不可恢复，确定要删除「{{ confirmTarget.name }}」吗？</p>
          <div class="actions">
            <button class="btn ghost" @click="confirmTarget = null">取消</button>
            <button class="btn danger" @click="doDelete">删除</button>
          </div>
        </div>
      </div>
    </transition>

    <transition name="fade">
      <div v-if="toast" class="toast">{{ toast }}</div>
    </transition>
  </div>
</template>

<style scoped>
.page {
  min-height: 100vh;
  padding-bottom: 56px;
}

/* ---------- hero ---------- */
.hero {
  background: linear-gradient(120deg, #4f46e5 0%, #6366f1 45%, #8b5cf6 100%);
  color: #fff;
  padding: 26px 0 30px;
  border-radius: 0 0 26px 26px;
  box-shadow: 0 10px 30px rgba(79, 70, 229, 0.22);
}

.hero-inner {
  max-width: 1120px;
  margin: 0 auto;
  padding: 0 24px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 20px;
  flex-wrap: wrap;
}

.brand {
  display: flex;
  align-items: center;
  gap: 14px;
}

.logo {
  width: 46px;
  height: 46px;
  border-radius: 13px;
  background: rgba(255, 255, 255, 0.18);
  border: 1px solid rgba(255, 255, 255, 0.32);
  display: grid;
  place-items: center;
  font-weight: 700;
  letter-spacing: 0.5px;
}

.brand-text h1 {
  font-size: 21px;
  font-weight: 650;
  letter-spacing: 0.2px;
}

.brand-text p {
  font-size: 12.5px;
  opacity: 0.82;
  margin-top: 2px;
}

.stats {
  display: flex;
  gap: 10px;
}

.stat {
  min-width: 68px;
  padding: 8px 14px;
  border-radius: 12px;
  background: rgba(255, 255, 255, 0.14);
  border: 1px solid rgba(255, 255, 255, 0.22);
  text-align: center;
}

.stat span {
  display: block;
  font-size: 18px;
  font-weight: 650;
  line-height: 1.2;
}

.stat small {
  font-size: 11.5px;
  opacity: 0.8;
}

/* ---------- layout ---------- */
.container {
  max-width: 1120px;
  margin: -18px auto 0;
  padding: 0 24px;
  display: flex;
  flex-direction: column;
  gap: 16px;
  position: relative;
}

.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow-sm);
}

.toolbar {
  display: flex;
  gap: 10px;
  align-items: center;
  padding: 12px;
  flex-wrap: wrap;
}

.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.field > span {
  font-size: 12.5px;
  color: var(--text-soft);
  font-weight: 500;
}

.field em {
  color: var(--danger);
  font-style: normal;
}

.search-field {
  flex: 1 1 260px;
  min-width: 200px;
}

.filter-field {
  flex: 0 0 148px;
}

.btn {
  padding: 9px 16px;
  border-radius: 10px;
  font-weight: 550;
  transition: transform 0.12s ease, background 0.15s ease, box-shadow 0.15s ease;
  white-space: nowrap;
}

.btn:active {
  transform: translateY(1px);
}

.btn:disabled {
  opacity: 0.55;
  cursor: not-allowed;
}

.btn.primary {
  background: var(--primary);
  color: #fff;
  box-shadow: 0 6px 16px rgba(91, 91, 214, 0.24);
}

.btn.primary:hover:not(:disabled) {
  background: var(--primary-dark);
}

.btn.ghost {
  background: #f5f6fb;
  color: var(--text-soft);
  border: 1px solid var(--border);
}

.btn.ghost:hover:not(:disabled) {
  background: #eef0f8;
  color: var(--text);
}

.btn.danger {
  background: var(--danger);
  color: #fff;
}

.alert {
  margin: 0;
  padding: 10px 14px;
  border-radius: 10px;
  background: var(--danger-soft);
  color: #a32b36;
  border: 1px solid #f7cfd3;
  font-size: 13px;
}

/* ---------- table ---------- */
.table-card {
  overflow: hidden;
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13.5px;
}

thead th {
  text-align: left;
  padding: 12px 14px;
  background: #fafbfe;
  border-bottom: 1px solid var(--border);
  color: var(--text-soft);
  font-weight: 550;
  font-size: 12.5px;
  white-space: nowrap;
}

tbody td {
  padding: 12px 14px;
  border-bottom: 1px solid #f0f2f8;
  vertical-align: middle;
}

tbody tr:last-child td {
  border-bottom: none;
}

tbody tr:hover {
  background: #fafbff;
}

.col-name {
  font-weight: 550;
}

.col-desc {
  max-width: 280px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.col-id {
  width: 56px;
}

.col-cat {
  width: 110px;
}

.col-status {
  width: 96px;
}

.col-time {
  width: 150px;
}

.col-act {
  width: 110px;
  text-align: right;
  white-space: nowrap;
}

.mono {
  font-family: ui-monospace, 'SFMono-Regular', Consolas, monospace;
  font-size: 12.5px;
  color: var(--text-soft);
}

.muted {
  color: var(--text-soft);
}

.tag {
  display: inline-block;
  padding: 2px 9px;
  border-radius: 999px;
  background: #f0f2fa;
  color: #5b6478;
  font-size: 12px;
}

.badge {
  display: inline-flex;
  align-items: center;
  padding: 3px 10px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 550;
}

.badge.is-pending {
  background: #fdf4e3;
  color: var(--warn);
}

.badge.is-doing {
  background: #e8f1ff;
  color: #1f6fd0;
}

.badge.is-done {
  background: #e7f7f1;
  color: var(--success);
}

.link {
  color: var(--primary);
  padding: 4px 6px;
  border-radius: 6px;
  font-weight: 550;
}

.link:hover {
  background: var(--primary-soft);
}

.link.danger {
  color: var(--danger);
}

.link.danger:hover {
  background: var(--danger-soft);
}

.placeholder {
  padding: 46px 20px;
  text-align: center;
  color: var(--text-soft);
  display: flex;
  flex-direction: column;
  gap: 4px;
  font-size: 13px;
}

.placeholder strong {
  color: var(--text);
  font-size: 15px;
}

/* ---------- modal ---------- */
.overlay {
  position: fixed;
  inset: 0;
  background: rgba(20, 26, 45, 0.42);
  backdrop-filter: blur(2px);
  display: grid;
  place-items: center;
  padding: 20px;
  z-index: 40;
}

.modal {
  width: 100%;
  max-width: 520px;
  padding: 22px;
  display: flex;
  flex-direction: column;
  gap: 14px;
  box-shadow: var(--shadow-md);
}

.modal.small {
  max-width: 400px;
}

.modal h2 {
  font-size: 17px;
  font-weight: 650;
}

.sub {
  margin-top: -8px;
  font-size: 12.5px;
}

.row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}

.actions {
  display: flex;
  justify-content: flex-end;
  gap: 10px;
  margin-top: 4px;
}

.toast {
  position: fixed;
  left: 50%;
  bottom: 30px;
  transform: translateX(-50%);
  background: #1f2437;
  color: #fff;
  padding: 10px 20px;
  border-radius: 999px;
  font-size: 13px;
  box-shadow: var(--shadow-md);
  z-index: 60;
}

.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.18s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

@media (max-width: 760px) {
  .stats {
    width: 100%;
  }
  .stat {
    flex: 1;
  }
  .col-desc,
  .col-time,
  .col-cat {
    display: none;
  }
  th.col-desc,
  th.col-time,
  th.col-cat {
    display: none;
  }
  .row {
    grid-template-columns: 1fr;
  }
}
</style>
