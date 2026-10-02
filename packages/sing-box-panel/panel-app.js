/* sing-box 控制台前端 —— 无构建，原生 ES2020 */
'use strict';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const state = {
  token: localStorage.getItem('panel_token') || '',
  view: 'status',
  ebpfPolicy: { mode: 'off', uids: [] },
  apps: [],
  selectedUids: new Set(),
  clashTimer: null,
};

/* ------------------------------------------------------------------ 基础 */
function toast(message, kind = '') {
  const box = document.createElement('div');
  box.className = `toast ${kind}`;
  box.textContent = message;
  $('#toasts').append(box);
  setTimeout(() => box.remove(), kind === 'err' ? 9000 : 5000);
}

async function api(path, method = 'GET', body) {
  const res = await fetch(`/api${path}`, {
    method,
    headers: {
      'X-Panel-Token': state.token,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401) {
    showGate('令牌无效或已过期');
    throw new Error('unauthorized');
  }
  return res.json();
}

const fmtBytes = (n) => {
  if (!n && n !== 0) return '–';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let i = 0, v = Number(n);
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return `${v.toFixed(i ? 1 : 0)} ${units[i]}`;
};
const fmtTime = (ts) => (ts ? new Date(ts * 1000).toLocaleString('zh-CN', { hour12: false }) : '–');

function showGate(message = '') {
  $('#gate').classList.remove('hidden');
  $('#gateErr').textContent = message;
  $('#gateToken').focus();
}

/* ------------------------------------------------------------------ 视图切换 */
function switchView(view) {
  state.view = view;
  $$('.tab').forEach((t) => t.classList.toggle('active', t.dataset.view === view));
  $$('.view').forEach((v) => v.classList.toggle('hidden', v.id !== `view-${view}`));
  if (view === 'status') startClashPolling(); else stopClashPolling();
  if (view === 'nodes') loadProxies();
  if (view === 'apps') loadApps();
  if (view === 'config') loadConfig();
}

/* ------------------------------------------------------------------ 运行状态 */
async function loadStatus() {
  const s = await api('/state');
  const svc = s.service || {};
  setText('#svcState', svc.active ? 'active' : (svc.raw || 'inactive'));
  $('#svcState').className = svc.active ? 'badge ok' : 'badge err';
  setText('#svcEnabled', svc.enabled ? 'enabled' : 'disabled');
  setText('#svcPid', `${svc.pid || '–'} · ${svc.since || '–'}`);
  setText('#sbVersion', s.version || '–');
  setText('#sbMode', (s.inbounds || []).join(' + ') || '–');
  setText('#cfgPath', s.config_path);
  setText('#cfgMeta', `${s.config_bytes} B · ${fmtTime(s.config_mtime)}`);
  $('#modePill').textContent = s.mode === 'ebpf' ? 'eBPF 模式' : `${s.mode} 模式`;
  $('#dryPill').classList.toggle('hidden', !s.dry_run);
  if (s.version) document.title = `sing-box ${s.version} · 控制台`;

  // 集成入口：zashboard 深链带密钥，点开即配置完成
  setText('#clashApi', s.clash_api || '–');
  setText('#clashSecret', s.clash_secret ? s.clash_secret : '(未设置)');
  const zash = $('#zashLink');
  if (zash) zash.href = s.zash_setup_url || '/dash/';
  const official = $('#officialLink');
  if (official) official.href = s.official_dashboard_url || '#';
  const mcd = $('#mcdLink');
  if (mcd) {
    // 只有 sing-box 配置里启用了 external_ui 才显示；用 zashboard 作为唯一运行时面板时它自动消失
    if (s.metacubexd_url) { mcd.href = s.metacubexd_url; mcd.classList.remove('hidden'); }
    else { mcd.classList.add('hidden'); }
  }
  if (s.config_error) toast(`配置读取失败：${s.config_error}`, 'err');
}

function setText(sel, value) { const el = $(sel); if (el) el.textContent = value; }

async function loadLogs() {
  const r = await api('/logs?n=200');
  $('#logBox').textContent = r.lines || '(空)';
}

async function runProbe() {
  const btn = $('#probeBtn');
  btn.disabled = true;
  $('#probeSummary').textContent = '探测中…（要加载 eBPF 对象，可能需要几秒）';
  try {
    const r = await api('/ebpf/probe', 'POST', { interface: $('#probeIface').value.trim() });
    const data = r.data || {};
    const sum = data.summary || {};
    $('#probeSummary').textContent = data.result
      ? `结果：${data.result}｜PASS ${sum.pass ?? 0} / FAIL ${sum.fail ?? 0} / UNKNOWN ${sum.unknown ?? 0}`
      : '探测未返回结构化结果';
    const findings = data.findings || [];
    $('#probeResult').innerHTML = findings.map((f) => {
      const kind = (f.status || '').toLowerCase();
      const cls = kind === 'pass' ? 'ok' : kind === 'fail' ? 'err' : 'warn';
      return `<div class="row"><b class="badge ${cls}">${f.status}</b>
        <div><div>${escapeHtml(f.feature || '')} <span class="muted small">[${f.scope || ''}${f.importance ? ' · ' + f.importance : ''}]</span></div>
        <div class="muted small">${escapeHtml(f.detail || '')}</div></div></div>`;
    }).join('') || '<div class="muted">没有可显示的条目</div>';
  } catch (e) {
    if (e.message !== 'unauthorized') toast(`预检失败：${e.message}`, 'err');
  } finally {
    btn.disabled = false;
  }
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* ---- Clash 实时数据 ---- */
async function pollClash() {
  try {
    const [conn, ver] = await Promise.all([api('/clash/connections'), api('/clash/version')]);
    if (conn.ok) {
      const d = conn.data || {};
      $('#connCount').textContent = (d.connections || []).length;
      $('#upTotal').textContent = fmtBytes(d.uploadTotal);
      $('#downTotal').textContent = fmtBytes(d.downloadTotal);
      $('#clashState').innerHTML = '<span class="badge ok">在线</span>';
      if (ver.ok) $('#clashState').innerHTML += ` <span class="muted small">${escapeHtml((ver.data || {}).version || '')}</span>`;
    } else {
      $('#clashState').innerHTML = '<span class="badge err">不可用</span>';
    }
  } catch { /* 忽略轮询错误 */ }
}
function startClashPolling() {
  stopClashPolling();
  pollClash();
  state.clashTimer = setInterval(pollClash, 3000);
}
function stopClashPolling() { if (state.clashTimer) clearInterval(state.clashTimer); state.clashTimer = null; }

/* ------------------------------------------------------------------ 订阅 */
async function loadSubs() {
  const r = await api('/subscriptions');
  const tbody = $('#subTable tbody');
  tbody.innerHTML = (r.subscriptions || []).map((s) => `
    <tr>
      <td>${escapeHtml(s.name || '')}<div class="muted small mono">${escapeHtml(s.url || '')}</div></td>
      <td>${s.node_count ?? 0}</td>
      <td>${s.last_update ? fmtTime(s.last_update) : '<span class="muted">从未</span>'}</td>
      <td>${s.last_error ? `<span class="badge err" title="${escapeHtml(s.last_error)}">失败</span>` : '<span class="badge ok">正常</span>'}</td>
      <td class="btn-row">
        <button class="btn small" data-sub-update="${s.id}">更新</button>
        <button class="btn small danger" data-sub-del="${s.id}">删除</button>
      </td>
    </tr>`).join('') || '<tr><td colspan="5" class="muted">还没有订阅</td></tr>';
}

async function addSub() {
  const url = $('#subUrl').value.trim();
  if (!url) return toast('请填订阅 URL', 'warn');
  toast('正在拉取订阅…');
  const r = await api('/subscriptions', 'POST', { name: $('#subName').value.trim(), url });
  toast(r.message || (r.ok ? '已添加' : '失败'), r.ok ? 'ok' : 'err');
  $('#subUrl').value = '';
  loadSubs();
}

/* ---- 节点/分组 ---- */
async function loadProxies() {
  const r = await api('/clash/proxies');
  if (!r.ok) { $('#groups').innerHTML = `<div class="muted">Clash API 不可用：${escapeHtml(r.message || '')}</div>`; return; }
  const container = $('#groups');
  container.innerHTML = (r.groups || []).map((g) => `
    <div class="group" data-group="${escapeHtml(g.name)}">
      <div class="group-head">
        <b>${escapeHtml(g.name)}</b>
        <span class="badge">${escapeHtml(g.type)}</span>
        <span class="muted small">当前：</span><span class="now">${escapeHtml(g.now || '–')}</span>
        <button class="btn small ghost" data-delay-group="${escapeHtml(g.name)}">整组测速</button>
      </div>
      <div class="nodes">
        ${(g.members || []).map((m) => `
          <span class="node ${m === g.now ? 'active' : ''}" data-node="${escapeHtml(m)}" data-group="${escapeHtml(g.name)}">
            <span>${escapeHtml(m)}</span>
            <span class="delay" data-delay-of="${escapeHtml(m)}">–</span>
            <button class="btn small ghost" data-delay="${escapeHtml(m)}">测</button>
          </span>`).join('')}
      </div>
    </div>`).join('') || '<div class="muted">没有策略组</div>';
}

async function testDelay(name, el) {
  el.textContent = '…';
  el.className = 'delay';
  const r = await api(`/clash/proxies/${encodeURIComponent(name)}/delay`);
  if (r.ok && r.delay) { el.textContent = `${r.delay}ms`; el.className = 'delay ok'; }
  else { el.textContent = '超时'; el.className = 'delay bad'; }
}

async function delayAll() {
  const nodes = $$('.node');
  toast(`开始测速 ${nodes.length} 个节点…`);
  for (const node of nodes) {
    const name = node.dataset.node;
    const el = $(`[data-delay-of="${CSS.escape(name)}"]`, node);
    if (el) await testDelay(name, el);
  }
}

/* ------------------------------------------------------------------ 分应用 */
async function loadApps() {
  const [policy, apps] = await Promise.all([api('/ebpf/policy'), api('/apps')]);
  state.ebpfPolicy = policy;
  state.selectedUids = new Set((policy.uids || []).map(Number));
  if (!policy.present) {
    $('#appList').innerHTML = '<div class="muted">当前配置里没有 ebpf 入站——分应用策略只在 eBPF 模式下可用（TUN 模式请用其他方式）。</div>';
  }
  state.apps = apps.apps || [];
  const radio = $(`input[name="polmode"][value="${policy.mode || 'off'}"]`);
  if (radio) radio.checked = true;
  renderApps();
  renderUidChips();
}

function renderApps() {
  const q = $('#appSearch').value.trim().toLowerCase();
  const list = state.apps.filter((a) => {
    if (!q) return true;
    return String(a.uid).includes(q) || (a.label || '').toLowerCase().includes(q)
      || (a.execs || []).some((e) => e.toLowerCase().includes(q));
  });
  $('#appList').innerHTML = list.map((a) => `
    <div class="approw">
      <label>
        <input type="checkbox" data-uid="${a.uid}" ${state.selectedUids.has(a.uid) ? 'checked' : ''}>
        <span>${escapeHtml(a.label)}</span>
      </label>
      <span class="meta">UID ${a.uid} · ${escapeHtml((a.execs || []).join(', ') || '—')} · ${(a.pids || []).length} 进程</span>
    </div>`).join('') || '<div class="muted">没有匹配的应用</div>';
}

function renderUidChips() {
  const chips = [...state.selectedUids].sort((a, b) => a - b)
    .map((u) => `<span class="chip">${u}<button data-uid-del="${u}">×</button></span>`).join('');
  $('#policyUids').innerHTML = chips || '<span class="muted small">尚未选择任何 UID</span>';
}

async function applyPolicy() {
  const mode = ($('input[name="polmode"]:checked') || {}).value || 'off';
  const r = await api('/ebpf/policy', 'POST', { mode, uids: [...state.selectedUids] });
  toast(r.message || (r.ok ? '已应用' : '失败'), r.ok ? 'ok' : 'err');
  loadStatus();
}

/* ------------------------------------------------------------------ 配置 */
async function loadConfig() {
  const r = await api('/config');
  $('#cfgText').value = r.text || '';
  const tbody = $('#backupTable tbody');
  tbody.innerHTML = (r.backups || []).map((b) => `
    <tr><td class="mono small">${escapeHtml(b.name)}</td><td>${fmtBytes(b.size)}</td>
      <td>${fmtTime(b.mtime)}</td>
      <td><button class="btn small" data-restore="${escapeHtml(b.name)}">恢复</button></td></tr>`).join('')
    || '<tr><td colspan="4" class="muted">还没有备份</td></tr>';
}

async function validateConfig() {
  const r = await api('/config/validate', 'POST', { text: $('#cfgText').value });
  $('#cfgMsg').textContent = r.message || '';
  toast(r.ok ? '校验通过' : `校验失败：${r.message}`, r.ok ? 'ok' : 'err');
}

async function applyConfig() {
  if (!confirm('将写入配置并重启 sing-box，失败会自动回滚。继续？')) return;
  toast('正在校验并应用…');
  const r = await api('/config', 'POST', { text: $('#cfgText').value });
  toast(r.message || (r.ok ? '已应用' : '失败'), r.ok ? 'ok' : 'err');
  loadStatus();
  loadConfig();
}

/* ------------------------------------------------------------------ 事件绑定 */
function bind() {
  $('#gateForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    state.token = $('#gateToken').value.trim();
    try {
      await api('/state');
      localStorage.setItem('panel_token', state.token);
      $('#gate').classList.add('hidden');
      boot();
    } catch { $('#gateErr').textContent = '令牌无效'; }
  });

  $('#tabs').addEventListener('click', (e) => {
    const tab = e.target.closest('.tab');
    if (tab) switchView(tab.dataset.view);
  });

  $$('[data-svc]').forEach((b) => b.addEventListener('click', async () => {
    const r = await api('/service', 'POST', { action: b.dataset.svc });
    toast(r.message, r.ok ? 'ok' : 'err');
    setTimeout(loadStatus, 800);
  }));

  $('#copySecret').addEventListener('click', async () => {
    const text = $('#clashSecret').textContent.trim();
    if (!text || text === '(未设置)') return toast('没有配置 Clash 密钥', 'warn');
    try { await navigator.clipboard.writeText(text); toast('密钥已复制', 'ok'); }
    catch { toast('复制失败，请手动选择复制', 'warn'); }
  });

  $('#probeBtn').addEventListener('click', runProbe);
  $('#logRefresh').addEventListener('click', loadLogs);
  $('#lockBtn').addEventListener('click', () => { localStorage.removeItem('panel_token'); state.token = ''; showGate('已锁定'); });

  $('#subAdd').addEventListener('click', addSub);
  $('#subUpdateAll').addEventListener('click', async () => {
    toast('正在更新全部订阅…');
    const r = await api('/subscriptions/update_all', 'POST');
    toast(`更新完成：${(r.results || []).filter((x) => x.ok).length}/${(r.results || []).length} 成功`, r.ok ? 'ok' : 'err');
    loadSubs();
  });
  $('#subApply').addEventListener('click', async () => {
    if (!confirm('把订阅节点写入配置并重启核心？失败会自动回滚。')) return;
    const r = await api('/subscriptions/apply', 'POST');
    toast(r.message || '已应用', r.ok ? 'ok' : 'err');
    loadProxies();
  });
  $('#subTable').addEventListener('click', async (e) => {
    const upd = e.target.closest('[data-sub-update]');
    const del = e.target.closest('[data-sub-del]');
    if (upd) { toast('更新中…'); const r = await api(`/subscriptions/${upd.dataset.subUpdate}/update`, 'POST'); toast(r.message, r.ok ? 'ok' : 'err'); loadSubs(); }
    if (del && confirm('删除该订阅？')) { await api(`/subscriptions/${del.dataset.subDel}`, 'DELETE'); loadSubs(); }
  });

  $('#nodeRefresh').addEventListener('click', loadProxies);
  $('#delayAll').addEventListener('click', delayAll);
  $('#groups').addEventListener('click', async (e) => {
    const delayBtn = e.target.closest('[data-delay]');
    if (delayBtn) {
      const node = delayBtn.closest('.node');
      const el = $('.delay', node);
      return testDelay(delayBtn.dataset.delay, el);
    }
    const groupBtn = e.target.closest('[data-delay-group]');
    if (groupBtn) {
      const group = groupBtn.closest('.group');
      for (const node of $$('.node', group)) await testDelay(node.dataset.node, $('.delay', node));
      return;
    }
    const node = e.target.closest('.node');
    if (node) {
      const r = await api(`/clash/proxies/${encodeURIComponent(node.dataset.group)}`, 'PUT', { name: node.dataset.node });
      toast(r.message, r.ok ? 'ok' : 'err');
      loadProxies();
    }
  });

  $('#appList').addEventListener('change', (e) => {
    const box = e.target.closest('input[data-uid]');
    if (!box) return;
    const uid = Number(box.dataset.uid);
    if (box.checked) state.selectedUids.add(uid); else state.selectedUids.delete(uid);
    renderUidChips();
  });
  $('#appSearch').addEventListener('input', renderApps);
  $('#appRefresh').addEventListener('click', loadApps);
  $('#policyApply').addEventListener('click', applyPolicy);
  $('#uidAdd').addEventListener('click', () => {
    const v = Number($('#uidInput').value.trim());
    if (!Number.isInteger(v) || v < 0) return toast('请输入合法 UID', 'warn');
    state.selectedUids.add(v);
    $('#uidInput').value = '';
    renderApps(); renderUidChips();
  });
  $('#policyUids').addEventListener('click', (e) => {
    const btn = e.target.closest('[data-uid-del]');
    if (!btn) return;
    state.selectedUids.delete(Number(btn.dataset.uidDel));
    renderApps(); renderUidChips();
  });

  $('#cfgValidate').addEventListener('click', validateConfig);
  $('#cfgApply').addEventListener('click', applyConfig);
  $('#cfgReload').addEventListener('click', loadConfig);
  $('#cfgBackup').addEventListener('click', async () => {
    const r = await api('/config/backup', 'POST');
    toast(r.message, r.ok ? 'ok' : 'err');
    loadConfig();
  });
  $('#backupTable').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-restore]');
    if (!btn) return;
    if (!confirm(`用 ${btn.dataset.restore} 覆盖当前配置并重启？`)) return;
    const r = await api('/config/restore', 'POST', { name: btn.dataset.restore });
    toast(r.message, r.ok ? 'ok' : 'err');
    loadConfig(); loadStatus();
  });
}

/* ------------------------------------------------------------------ 启动 */
async function boot() {
  const s = await api('/state');
  const secret = '';
  $('#dashLink').href = `/dash/#/setup?hostname=127.0.0.1&port=${encodeURIComponent(new URL(s.clash_api).port || '9090')}`;
  await loadStatus();
  await loadLogs();
  await loadSubs();
  if (state.view === 'status') startClashPolling();
  setInterval(loadStatus, 15000);
}

(async function init() {
  bind();
  if (!state.token) return showGate();
  try { await api('/state'); } catch { return; }
  $('#gate').classList.add('hidden');
  boot();
})();
