import {
  createI18nHelper,
  escapeHtml,
  formatBytes,
  formatNumber,
  formatTimestampShort,
  formatTokens,
  formatUsd,
  modelIconPath,
  normalizeDailyTrends,
  normalizeTodayHourlyPoints,
  renderBarChartSvg,
  renderDonutSvg,
  renderQuotaRowsHtml,
  tierBadgeHtml,
} from './shared.js';

const state = {
  activeTab: 'overview',
  activeLocale: 'zh-Hans',
  i18nPacks: {},
  config: {},
  appInfo: {},
  statusPayload: null,
  dashboard: null,
  accountsPayload: null,
  autoSwitchConfig: null,
  recommendation: null,
  usagePeriod: 'today',
  usageAccountId: 'all',
  usageReport: null,
  maintenanceSummary: null,
  deepLocalization: null,
  pendingScanResult: null,
  updateState: null,
  collapsedAccounts: new Set(),
  allCollapsed: false,
  busy: {},
};

const t = createI18nHelper(() => state);

const NAV_ITEMS = [
  {
    id: 'overview',
    key: 'nav.overview',
    fallback: '总览',
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>`,
  },
  {
    id: 'accounts',
    key: 'nav.accounts',
    fallback: '账号',
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>`,
  },
  {
    id: 'usage',
    key: 'nav.usage',
    fallback: '用量',
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 20V10"/><path d="M12 20V4"/><path d="M6 20v-6"/></svg>`,
  },
  {
    id: 'localization',
    key: 'nav.localization',
    fallback: '深度汉化',
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m5 8 6 6"/><path d="m4 14 6-6 2-3"/><path d="M2 5h12"/><path d="M7 2h1"/><path d="m22 22-5-10-5 10"/><path d="M14 18h6"/></svg>`,
  },
  {
    id: 'settings',
    key: 'nav.settings',
    fallback: '设置',
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9c.26.6.77 1 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>`,
  },
  {
    id: 'about',
    key: 'nav.about',
    fallback: '关于',
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>`,
  },
];

function toast(message, isError = false) {
  const stack = document.getElementById('toast-stack');
  if (!stack || !message) return;
  const el = document.createElement('div');
  el.className = `toast ${isError ? 'error' : ''}`;
  el.textContent = message;
  stack.appendChild(el);
  setTimeout(() => el.remove(), 3500);
}

function showModal({ title, bodyHtml, footerHtml = '' }) {
  const backdrop = document.getElementById('modal-backdrop');
  document.getElementById('modal-title').textContent = title;
  document.getElementById('modal-body').innerHTML = bodyHtml;
  document.getElementById('modal-footer').innerHTML = footerHtml || `<button class="btn btn-primary" id="modal-ok-close">${escapeHtml(t('common.ok', null, '好'))}</button>`;
  backdrop.classList.add('open');
  document.getElementById('modal-ok-close')?.addEventListener('click', closeModal);
  return {
    body: document.getElementById('modal-body'),
    footer: document.getElementById('modal-footer'),
  };
}

function closeModal() {
  document.getElementById('modal-backdrop').classList.remove('open');
}

document.getElementById('modal-close-x')?.addEventListener('click', closeModal);
document.getElementById('modal-backdrop')?.addEventListener('click', e => {
  if (e.target.id === 'modal-backdrop') closeModal();
});

function renderSidebar() {
  const nav = document.getElementById('nav-list');
  nav.innerHTML = NAV_ITEMS.map(item => `
    <button class="nav-item ${state.activeTab === item.id ? 'active' : ''}" data-tab="${item.id}">
      ${item.icon}
      <span>${escapeHtml(t(item.key, null, item.fallback))}</span>
    </button>
  `).join('');
  nav.querySelectorAll('.nav-item').forEach(btn => {
    btn.addEventListener('click', () => {
      state.activeTab = btn.getAttribute('data-tab');
      renderSidebar();
      renderCurrentPage();
      void refreshActiveTabData();
    });
  });

  const s = state.statusPayload?.status;
  const dot = document.getElementById('sidebar-status-dot');
  const txt = document.getElementById('sidebar-status-text');
  if (!s) {
    dot.className = 'status-dot';
    txt.textContent = t('sidebar.waiting_service', null, '等待本机服务…');
  } else if (s.deepAsarActive && s.hudEnabled !== false) {
    dot.className = 'status-dot connected';
    txt.textContent = t('sidebar.deep_asar_active', null, '深度汉化已接管 · HUD 运行中');
  } else {
    const mode = s.mode || '';
    dot.className = `status-dot ${
      ['connected', 'adaptive'].includes(mode) ? 'connected'
      : ['debug-port-missing', 'unsupported', 'legacy-blocked'].includes(mode) ? 'warn'
      : mode === 'error' ? 'error'
      : 'paused'
    }`;
    txt.textContent = s.message || mode;
  }

  document.getElementById('btn-open-antigravity').textContent = t('sidebar.open_antigravity', null, '打开 Antigravity');
}

function debugBannerHtml() {
  const s = state.statusPayload?.status;
  if (!s || s.mode !== 'debug-port-missing') return '';
  const busy = Boolean(state.busy.safeRelaunch);
  const btnText = busy
    ? t('assistant.safe_relaunch_busy', null, '正在安全重启 Antigravity…')
    : t('assistant.safe_relaunch_btn', null, '安全重启 Antigravity 以连接');
  return `
    <div class="banner banner-warn">
      <div>
        <div class="banner-title">${escapeHtml(t('status.debug_port_missing', null, '未开启调试端口'))}</div>
        <div class="banner-body">${escapeHtml(t('debug_port_missing.banner_body', null, '检测到 Antigravity 已运行但未开启调试端口，汉化与对话状态栏暂不可连接。请先保存工作后再安全重启。'))}</div>
      </div>
      <button class="btn btn-primary btn-sm" id="btn-safe-relaunch" ${busy ? 'disabled' : ''}>${escapeHtml(btnText)}</button>
    </div>
  `;
}

function bindDebugBanner() {
  const btn = document.getElementById('btn-safe-relaunch');
  if (!btn) return;
  btn.addEventListener('click', async () => {
    if (state.busy.safeRelaunch) return;
    state.busy.safeRelaunch = true;
    btn.disabled = true;
    btn.textContent = t('assistant.safe_relaunch_busy', null, '正在安全重启 Antigravity…');
    toast(t('assistant.safe_relaunch_busy', null, '正在关闭并重启 Antigravity…'));
    try {
      const res = await window.gravitybox.safeRelaunchAntigravity();
      if (!res?.ok) {
        toast(res?.error || t('assistant.safe_relaunch_timeout', null, '安全重启未完成，请手动关闭 Antigravity 后重开'), true);
      } else {
        toast(t('status.waiting_app', null, '已重启 Antigravity，正在连接调试端口…'));
        setTimeout(() => { void refreshActiveTabData(); }, 1800);
      }
    } catch (err) {
      toast(String(err?.message || err || '安全重启失败'), true);
    } finally {
      state.busy.safeRelaunch = false;
      const curBtn = document.getElementById('btn-safe-relaunch');
      if (curBtn) {
        curBtn.disabled = false;
        curBtn.textContent = t('assistant.safe_relaunch_btn', null, '安全重启 Antigravity 以连接');
      }
    }
  });
}

function renderOverviewPage(root) {
  const d = state.dashboard || {};
  const acc = d.accounts || {};
  const usage = d.usage || {};
  const activeEmail = acc.activeEmail || state.statusPayload?.status?.activeAccountEmail || '';
  const activeName = acc.activeName || activeEmail || t('overview.no_account', null, '未检测到已保存账号');
  const activeTier = acc.activeTier || state.statusPayload?.status?.activeSubscriptionTier || 'FREE';

  const points = normalizeTodayHourlyPoints(usage.todayHourly, 4);
  const peak = points.reduce((best, cur) => (cur.tokens > best.tokens ? cur : best), { hourNum: 0, tokens: 0 });
  const topModels = Array.isArray(usage.todayByModel) ? usage.todayByModel.slice(0, 3) : [];
  const totalTodayTokens = Math.max(1, topModels.reduce((s, m) => s + (m.totalTokens || 0), 0));
  const todayTokensVal = usage.todayTokens ?? 0;
  const totalTokensVal = usage.totalTokens ?? 0;
  const todayUsdVal = usage.estimatedUsd ?? usage.todayUsd ?? 0;
  const totalUsdVal = usage.allTimeEstimatedUsd ?? usage.totalUsd ?? 0;
  const todayReqVal = usage.requestCount ?? usage.todayRequests ?? 0;
  const totalReqVal = usage.totalRequestCount ?? usage.totalRequests ?? 0;

  root.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${escapeHtml(t('overview.title', null, '总览'))}</h1>
    </div>
    ${debugBannerHtml()}
    <div class="card">
      <div class="account-head">
        <div style="min-width:0">
          <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
            <span style="font-size:16px;font-weight:700">${escapeHtml(activeName)}</span>
            ${tierBadgeHtml(activeTier)}
          </div>
          ${activeEmail ? `<div class="muted small truncate" style="margin-top:2px">${escapeHtml(activeEmail)}</div>` : ''}
        </div>
        <button class="btn btn-sm" id="btn-overview-refresh-quota">${escapeHtml(t('common.refresh_quota', null, '刷新配额'))}</button>
      </div>
      ${renderQuotaRowsHtml(acc, t)}
      ${d.accountsError ? `<div class="muted xs" style="margin-top:8px;color:var(--accent-amber)">${escapeHtml(d.accountsError)}</div>` : ''}
    </div>

    <div class="bento-3">
      <div class="card" style="margin-top:0">
        <div class="metric-title">${escapeHtml(t('overview.metric.today_tokens', null, '今日 Token 用量'))}</div>
        <div class="metric-value tabular">${escapeHtml(formatTokens(todayTokensVal))}</div>
        <div class="metric-sub tabular">${escapeHtml(t('overview.metric.total_tokens', { tokens: formatTokens(totalTokensVal) }, `累计 ${formatTokens(totalTokensVal)} Token`))}</div>
      </div>
      <div class="card" style="margin-top:0">
        <div class="metric-title">${escapeHtml(t('overview.metric.today_cost', null, '今日费用估算'))}</div>
        <div class="metric-value tabular">${escapeHtml(formatUsd(todayUsdVal))}</div>
        <div class="metric-sub tabular">${escapeHtml(t('overview.metric.total_cost', { cost: formatUsd(totalUsdVal) }, `累计 ${formatUsd(totalUsdVal)}`))}</div>
      </div>
      <div class="card" style="margin-top:0">
        <div class="metric-title">${escapeHtml(t('overview.metric.today_requests', null, '今日请求数'))}</div>
        <div class="metric-value tabular">${escapeHtml(formatNumber(todayReqVal))}</div>
        <div class="metric-sub tabular">${escapeHtml(t('overview.metric.total_requests', { count: formatNumber(totalReqVal) }, `累计 ${formatNumber(totalReqVal)} 次`))}</div>
      </div>
    </div>

    <div class="bento-2">
      <div class="card" style="margin-top:0">
        <div class="account-head">
          <span style="font-weight:600">${escapeHtml(t('overview.trend.title', null, '今日时段消耗'))}</span>
          <span class="pill pill-blue">${escapeHtml(peak.tokens > 0
            ? t('overview.trend.peak_badge', { label: `${String(peak.hourNum).padStart(2, '0')}时`, peak: formatTokens(peak.tokens) }, `峰值 ${String(peak.hourNum).padStart(2, '0')}时 · ${formatTokens(peak.tokens)}`)
            : t('overview.trend.24h_badge', null, '24 小时分布'))}</span>
        </div>
        <div class="chart-wrap" id="overview-trend-chart"></div>
      </div>
      <div class="card" style="margin-top:0">
        <div class="account-head">
          <span style="font-weight:600">${escapeHtml(t('overview.bento.active_models', null, '今日活跃模型'))}</span>
          <span class="pill">${topModels.length ? `${topModels.length}` : t('overview.bento.no_calls_badge', null, '暂无调用')}</span>
        </div>
        <div style="margin-top:8px">
          ${topModels.length === 0
            ? `<div class="muted small" style="padding:28px 0;text-align:center">${escapeHtml(t('menu_panel.models_empty', null, '当前时间范围暂无模型调用记录'))}</div>`
            : topModels.map(m => {
                const pct = Math.min(100, Math.round(((m.totalTokens || 0) / totalTodayTokens) * 100));
                return `
                  <div style="padding:8px 0;border-bottom:1px solid var(--border-subtle)">
                    <div style="display:flex;justify-content:space-between;gap:8px;margin-bottom:5px">
                      <span style="font-weight:600" class="truncate">${escapeHtml(m.model)}</span>
                      <span class="tabular small" style="font-weight:600">${escapeHtml(formatTokens(m.totalTokens))} Token</span>
                    </div>
                    <div class="progress-track"><div class="progress-fill" style="width:${Math.max(pct, 3)}%"></div></div>
                    <div class="muted xs tabular" style="margin-top:4px">${formatNumber(m.requestCount || 0)} req · ${pct}% · ${formatUsd(m.estimatedUsd || 0)}</div>
                  </div>
                `;
              }).join('')}
        </div>
      </div>
    </div>
  `;

  bindDebugBanner();
  renderBarChartSvg(document.getElementById('overview-trend-chart'), points, { metric: 'tokens', height: 145 });

  document.getElementById('btn-overview-refresh-quota')?.addEventListener('click', async () => {
    const btn = document.getElementById('btn-overview-refresh-quota');
    btn.disabled = true;
    await window.gravitybox.rpc('quota_refresh_start');
    toast(t('menu_panel.quota.refreshing', null, '正在刷新配额…'));
    setTimeout(() => { void loadDashboard(); btn.disabled = false; }, 1200);
  });
}

function renderAccountsPage(root) {
  const payload = state.accountsPayload || {};
  const accounts = Array.isArray(payload.accounts) ? payload.accounts : [];
  const activeId = payload.activeId || payload.currentAccountId || '';
  const policy = state.autoSwitchConfig || {};
  const rec = state.recommendation;
  const recovery = payload.recovery || {};

  const recoveryBanner = payload.pendingSwitch || (recovery.available && !recovery.expired)
    ? `
      <div class="banner banner-info">
        <div>
          <div class="banner-title">${escapeHtml(t('accounts.pending_recovery', null, '已保存上次切换快照，可按需撤销回滚'))}</div>
          <div class="banner-body">${escapeHtml(recovery.createdAt || '')}</div>
        </div>
        <div style="display:flex;gap:6px">
          <button class="btn btn-sm" id="btn-rollback-switch">${escapeHtml(t('accounts.rollback_btn', null, '撤销切换'))}</button>
          ${!payload.pendingSwitch && recovery.digest ? `<button class="btn btn-sm" id="btn-clear-recovery">${escapeHtml(t('common.clear', null, '清除'))}</button>` : ''}
        </div>
      </div>
    `
    : '';

  const recBanner = rec?.shouldSwitch && rec?.bestCandidate
    ? `
      <div class="banner banner-info">
        <div>
          <div class="banner-title">${escapeHtml(rec.bestCandidate.name || rec.bestCandidate.email)}</div>
          <div class="banner-body">${escapeHtml(rec.reason || '')}</div>
        </div>
        <button class="btn btn-primary btn-sm" id="btn-switch-recommended">${escapeHtml(t('accounts.switch_recommended_btn', null, '切换至推荐账号'))}</button>
      </div>
    `
    : '';

  root.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${escapeHtml(t('accounts.title', null, '账号'))}</h1>
      <div class="header-actions">
        <button class="btn btn-sm" id="btn-toggle-collapse">${escapeHtml(state.allCollapsed ? t('accounts.expand_all', null, '展开配额') : t('accounts.collapse_all', null, '收起配额'))}</button>
        <button class="btn btn-sm" id="btn-refresh-all-accounts">${escapeHtml(t('common.refresh_quota', null, '刷新配额'))}</button>
        <button class="btn btn-primary btn-sm" id="btn-add-account">${escapeHtml(t('accounts.add_btn', null, '添加账号…'))}</button>
      </div>
    </div>
    ${debugBannerHtml()}
    ${recoveryBanner}
    ${recBanner}
    <div class="card">
      <div class="setting-row">
        <div class="setting-left">
          <div class="setting-icon">⇄</div>
          <div>
            <div class="setting-title" style="display:flex;align-items:center;gap:8px">
              <span>${escapeHtml(t('accounts.smart_switch.title', null, '智能切换'))}</span>
              <span class="pill ${policy.enabled ? 'pill-green' : ''}">${escapeHtml(policy.enabled ? t('accounts.smart_switch.enabled', null, '已启用') : t('accounts.smart_switch.disabled', null, '已停用'))}</span>
            </div>
            <div class="setting-sub">${escapeHtml(t('accounts.smart_switch.summary', { threshold: policy.threshold ?? 10, recovery: policy.recoveryThreshold ?? 30 }, `剩余 ≤ ${policy.threshold ?? 10}% 时推荐候选（≥ ${policy.recoveryThreshold ?? 30}%）`))}</div>
          </div>
        </div>
        <div style="display:flex;align-items:center;gap:10px">
          <button class="btn btn-sm" id="btn-config-policy">${escapeHtml(t('accounts.smart_switch.config_btn', null, '配置…'))}</button>
          <label class="switch">
            <input type="checkbox" id="toggle-auto-switch" ${policy.enabled ? 'checked' : ''} />
            <span class="switch-slider"></span>
          </label>
        </div>
      </div>
    </div>

    ${accounts.length === 0
      ? `<div class="card" style="text-align:center;padding:36px 20px">
          <div style="font-weight:600;margin-bottom:6px">${escapeHtml(t('menu_panel.quota.no_saved', null, '尚未保存账号'))}</div>
          <div class="muted small" style="margin-bottom:14px">${escapeHtml(t('menu_panel.quota.empty_hint', null, '保存当前正在使用的 Antigravity 账号，或通过 OAuth / Refresh Token 添加备用账号'))}</div>
          <button class="btn btn-primary" id="btn-save-current-empty">${escapeHtml(t('accounts.save_current_btn', null, '保存当前账号'))}</button>
        </div>`
      : accounts.map(acc => {
          const isActive = acc.id === activeId;
          const isCollapsed = state.collapsedAccounts.has(acc.id);
          const readiness = acc.credentialReadiness || {};
          const standby = acc.standbyRefreshStatus || {};
          const standbyMode = standby.mode || '';
          const standbyPill = !isActive && (standbyMode === 'snapshot_cooldown_elapsed' || standbyMode === 'snapshot_cooling')
            ? `<span class="pill ${standbyMode === 'snapshot_cooldown_elapsed' ? 'pill-blue' : ''}">${escapeHtml(standbyMode === 'snapshot_cooldown_elapsed' ? '预计已重置 · 切换时同步' : '待机保鲜 · 切换时同步')}</span>`
            : (readiness.state && readiness.state !== 'ready' ? `<span class="pill pill-amber">${escapeHtml(readiness.message || readiness.state)}</span>` : '');
          const updatedStr = acc.quotaLastUpdated ? t('common.updated_at', { time: formatTimestampShort(acc.quotaLastUpdated) }, `更新于 ${formatTimestampShort(acc.quotaLastUpdated)}`) : '';
          return `
            <div class="card account-card ${isActive ? 'active' : ''}" data-acc-id="${escapeHtml(acc.id)}">
              <div class="account-head">
                <div style="min-width:0">
                  <div style="display:flex;align-items:center;gap:7px;flex-wrap:wrap">
                    <span style="font-size:15px;font-weight:700">${escapeHtml(acc.name || acc.email)}</span>
                    ${tierBadgeHtml(acc.subscription_tier)}
                    ${isActive ? `<span class="pill pill-blue">${escapeHtml(t('menu_panel.quota.current_account', null, '当前账号'))}</span>` : ''}
                    ${standbyPill}
                  </div>
                  <div class="muted small truncate" style="margin-top:2px">${escapeHtml(acc.email)}</div>
                </div>
                <div style="display:flex;align-items:center;gap:6px;flex-shrink:0">
                  ${!isActive ? `<button class="btn btn-sm btn-switch-acc" data-id="${escapeHtml(acc.id)}">${escapeHtml(t('accounts.switch_btn', null, '切换账号'))}</button>` : ''}
                  <button class="btn btn-sm btn-refresh-acc" data-id="${escapeHtml(acc.id)}">↻</button>
                  <button class="btn btn-sm btn-rename-acc" data-id="${escapeHtml(acc.id)}" data-name="${escapeHtml(acc.name || '')}">${escapeHtml(t('accounts.rename_btn', null, '重命名'))}</button>
                  <button class="btn btn-sm btn-danger btn-delete-acc" data-id="${escapeHtml(acc.id)}" data-email="${escapeHtml(acc.email)}">${escapeHtml(t('accounts.delete_btn', null, '删除'))}</button>
                  <button class="btn btn-sm btn-collapse-one" data-id="${escapeHtml(acc.id)}">${isCollapsed ? '▾' : '▴'}</button>
                </div>
              </div>
              ${!isCollapsed ? renderQuotaRowsHtml(acc, t) : ''}
              ${acc.quota_refresh_error ? `<div class="xs" style="margin-top:8px;color:var(--accent-red)">${escapeHtml(acc.quota_refresh_error)}</div>` : ''}
              ${updatedStr ? `<div class="muted xs" style="margin-top:8px">${escapeHtml(updatedStr)}</div>` : ''}
            </div>
          `;
        }).join('')}
  `;

  bindDebugBanner();
  document.getElementById('btn-toggle-collapse')?.addEventListener('click', () => {
    state.allCollapsed = !state.allCollapsed;
    state.collapsedAccounts = state.allCollapsed ? new Set(accounts.map(a => a.id)) : new Set();
    renderAccountsPage(root);
  });
  document.getElementById('btn-refresh-all-accounts')?.addEventListener('click', async () => {
    await window.gravitybox.rpc('quota_refresh_start');
    toast(t('menu_panel.quota.refreshing', null, '正在刷新配额…'));
    setTimeout(() => { void loadAccounts(); }, 1500);
  });
  document.getElementById('btn-add-account')?.addEventListener('click', openAddAccountModal);
  document.getElementById('btn-save-current-empty')?.addEventListener('click', async () => {
    const res = await window.gravitybox.rpc('account_save_current');
    if (res?.ok) {
      toast(res.account?.email || 'OK');
      await loadAccounts();
    } else {
      toast(res?.error || t('assistant.action_incomplete'), true);
    }
  });
  document.getElementById('toggle-auto-switch')?.addEventListener('change', async e => {
    const res = await window.gravitybox.rpc('auto_switch_set', { config: { enabled: e.target.checked } });
    if (res?.ok) state.autoSwitchConfig = res.config;
    renderAccountsPage(root);
  });
  document.getElementById('btn-config-policy')?.addEventListener('click', openPolicyModal);
  document.getElementById('btn-rollback-switch')?.addEventListener('click', async () => {
    if (state.switchingAccount) return;
    const pre = await window.gravitybox.rpc('account_switch_preflight');
    if (pre?.appRunning) {
      const { body, footer } = showModal({
        title: t('accounts.rollback_btn', null, '撤销切换'),
        bodyHtml: `
          <p class="small">${escapeHtml(t('accounts.stop_app_before_switch', null, 'Antigravity 正在运行。切换/回滚账号需要先温和关闭 Antigravity，并在完成后自动重新打开。'))}</p>
          <div id="m-switch-progress" class="muted small" style="margin-top:8px;display:none"></div>
        `,
        footerHtml: `<button class="btn" id="m-cancel">取消</button><button class="btn btn-primary" id="m-go">关闭 Antigravity 并回滚</button>`,
      });
      const cancelBtn = footer.querySelector('#m-cancel');
      const goBtn = footer.querySelector('#m-go');
      const prog = body.querySelector('#m-switch-progress');
      cancelBtn?.addEventListener('click', () => { if (!state.switchingAccount) closeModal(); });
      goBtn?.addEventListener('click', async () => {
        if (state.switchingAccount) return;
        state.switchingAccount = true;
        if (cancelBtn) cancelBtn.disabled = true;
        if (goBtn) { goBtn.disabled = true; goBtn.textContent = '正在回滚…'; }
        if (prog) { prog.style.display = 'block'; prog.textContent = '1/3 正在温和关闭 Antigravity…'; }
        try {
          const closed = await window.gravitybox.closeAntigravityGracefully();
          if (!closed?.ok) {
            toast(t('assistant.safe_relaunch_timeout'), true);
            return;
          }
          if (prog) prog.textContent = '2/3 正在恢复上一账号凭据…';
          const res = await window.gravitybox.rpc('account_switch_rollback', { waitForExit: true });
          if (res?.ok) {
            if (prog) prog.textContent = '3/3 正在重新打开 Antigravity（开启调试端口）…';
            await window.gravitybox.openAntigravity({ remoteDebug: true });
            closeModal();
            toast(res.message || 'OK');
            await loadAccounts();
            void loadOverview();
          } else toast(res?.error || 'Failed', true);
        } finally {
          state.switchingAccount = false;
          if (cancelBtn) cancelBtn.disabled = false;
          if (goBtn) { goBtn.disabled = false; goBtn.textContent = '关闭 Antigravity 并回滚'; }
        }
      });
      return;
    }
    state.switchingAccount = true;
    try {
      const res = await window.gravitybox.rpc('account_switch_rollback');
      if (res?.ok) { toast(res.message || 'OK'); await loadAccounts(); void loadOverview(); }
      else toast(res?.error || 'Failed', true);
    } finally {
      state.switchingAccount = false;
    }
  });
  document.getElementById('btn-clear-recovery')?.addEventListener('click', async () => {
    const res = await window.gravitybox.rpc('account_recovery_clear', { confirm: true, digest: recovery.digest });
    if (res?.ok) { toast(res.message || 'OK'); await loadAccounts(); }
    else toast(res?.error || 'Failed', true);
  });
  document.getElementById('btn-switch-recommended')?.addEventListener('click', () => {
    if (rec?.bestCandidate?.id) void performAccountSwitch(rec.bestCandidate.id, rec.bestCandidate.email);
  });

  root.querySelectorAll('.btn-collapse-one').forEach(b => b.addEventListener('click', () => {
    const id = b.getAttribute('data-id');
    if (state.collapsedAccounts.has(id)) state.collapsedAccounts.delete(id);
    else state.collapsedAccounts.add(id);
    renderAccountsPage(root);
  }));
  root.querySelectorAll('.btn-refresh-acc').forEach(b => b.addEventListener('click', async () => {
    b.disabled = true;
    const res = await window.gravitybox.rpc('quota_refresh', { id: b.getAttribute('data-id') });
    if (!res?.ok) toast(res?.error || 'Failed', true);
    await loadAccounts();
  }));
  root.querySelectorAll('.btn-switch-acc').forEach(b => b.addEventListener('click', () => {
    const id = b.getAttribute('data-id');
    const acc = accounts.find(a => a.id === id);
    void performAccountSwitch(id, acc?.email || id);
  }));
  root.querySelectorAll('.btn-rename-acc').forEach(b => b.addEventListener('click', () => {
    const id = b.getAttribute('data-id');
    const oldName = b.getAttribute('data-name') || '';
    const { body, footer } = showModal({
      title: t('accounts.rename_btn', null, '重命名'),
      bodyHtml: `<input type="text" id="rename-input" value="${escapeHtml(oldName)}" style="width:100%" />`,
      footerHtml: `<button class="btn" id="m-cancel">取消</button><button class="btn btn-primary" id="m-save">保存</button>`,
    });
    footer.querySelector('#m-cancel').addEventListener('click', closeModal);
    footer.querySelector('#m-save').addEventListener('click', async () => {
      const name = body.querySelector('#rename-input').value.trim();
      const res = await window.gravitybox.rpc('account_rename', { id, name });
      closeModal();
      if (res?.ok) await loadAccounts();
      else toast(res?.error || 'Failed', true);
    });
  }));
  root.querySelectorAll('.btn-delete-acc').forEach(b => b.addEventListener('click', () => {
    const id = b.getAttribute('data-id');
    const email = b.getAttribute('data-email');
    const { footer } = showModal({
      title: t('accounts.delete_btn', null, '删除'),
      bodyHtml: `<p class="small">${escapeHtml(email)}</p>`,
      footerHtml: `<button class="btn" id="m-cancel">取消</button><button class="btn btn-danger" id="m-del">${escapeHtml(t('accounts.delete_btn', null, '删除'))}</button>`,
    });
    footer.querySelector('#m-cancel').addEventListener('click', closeModal);
    footer.querySelector('#m-del').addEventListener('click', async () => {
      const res = await window.gravitybox.rpc('account_delete', { id });
      closeModal();
      if (res?.ok) await loadAccounts();
      else toast(res?.error || 'Failed', true);
    });
  }));
}

async function performAccountSwitch(id, email) {
  if (state.switchingAccount) return;
  state.switchingAccount = true;
  try {
    const pre = await window.gravitybox.rpc('account_switch_preflight', { id });
    if (pre?.appRunning) {
      const { body, footer } = showModal({
        title: t('accounts.switch_btn', null, '切换账号'),
        bodyHtml: `
          <p class="small">${escapeHtml(`即将切换至 ${email}。`)}</p>
          <p class="muted small" style="margin-top:8px">${pre.hasRunningTask ? `⚠ 检测到 Antigravity 正在运行推理任务（${escapeHtml(pre.taskReason || '')}），建议等待任务结束后再切换。` : '需要先温和关闭 Antigravity，切换凭据后自动重新打开（开启调试端口）。'}</p>
          <div id="m-switch-progress" class="muted small" style="margin-top:10px;display:none"></div>
        `,
        footerHtml: `<button class="btn" id="m-cancel">取消</button><button class="btn btn-primary" id="m-go">关闭 Antigravity 并切换</button>`,
      });
      const cancelBtn = footer.querySelector('#m-cancel');
      const goBtn = footer.querySelector('#m-go');
      const prog = body.querySelector('#m-switch-progress');
      state.switchingAccount = false;
      cancelBtn.addEventListener('click', () => { if (!state.switchingAccount) closeModal(); });
      goBtn.addEventListener('click', async () => {
        if (state.switchingAccount) return;
        state.switchingAccount = true;
        cancelBtn.disabled = true;
        goBtn.disabled = true;
        goBtn.textContent = '正在切换…';
        if (prog) { prog.style.display = 'block'; prog.textContent = '1/3 正在温和关闭 Antigravity…'; }
        try {
          const closed = await window.gravitybox.closeAntigravityGracefully();
          if (!closed?.ok) {
            toast(t('assistant.safe_relaunch_timeout'), true);
            return;
          }
          if (prog) prog.textContent = '2/3 正在写入账号凭据…';
          const res = await window.gravitybox.rpc('account_switch', { id, autoRefreshToken: true, waitForExit: true });
          if (res?.ok) {
            if (prog) prog.textContent = '3/3 正在重新打开 Antigravity（开启调试端口）…';
            await window.gravitybox.openAntigravity({ remoteDebug: true });
            closeModal();
            toast(res.message || `已切换至 ${email}`);
            await loadAccounts();
            void loadOverview();
          } else {
            toast(res?.error || 'Switch failed', true);
          }
        } finally {
          state.switchingAccount = false;
          cancelBtn.disabled = false;
          goBtn.disabled = false;
          goBtn.textContent = '关闭 Antigravity 并切换';
        }
      });
      return;
    }
    toast(`正在切换至 ${email}…`);
    const res = await window.gravitybox.rpc('account_switch', { id, autoRefreshToken: true });
    if (res?.ok) {
      toast(res.message || `已切换至 ${email}`);
      await loadAccounts();
      void loadOverview();
    } else {
      toast(res?.error || 'Switch failed', true);
    }
  } finally {
    state.switchingAccount = false;
  }
}

function openAddAccountModal() {
  const { body, footer } = showModal({
    title: t('accounts.add_btn', null, '添加账号'),
    bodyHtml: `
      <div style="display:flex;flex-direction:column;gap:12px">
        <div class="card" style="padding:12px">
          <div style="font-weight:600">1. 保存本机正在登录的账号</div>
          <div class="muted small" style="margin:4px 0 8px">从 Windows 凭据管理器与 Antigravity 数据库提取当前会话。</div>
          <button class="btn btn-primary btn-sm" id="m-save-current">${escapeHtml(t('accounts.save_current_btn', null, '保存当前账号'))}</button>
        </div>
        <div class="card" style="padding:12px;margin-top:0">
          <div style="font-weight:600">2. Google OAuth 网页授权</div>
          <div class="muted small" style="margin:4px 0 8px">通过系统浏览器完成 Google 登录（不切换当前 IDE 账号）。</div>
          <button class="btn btn-sm" id="m-oauth-begin">打开浏览器授权</button>
          <div id="m-oauth-status" class="muted small" style="margin-top:6px"></div>
        </div>
        <div class="card" style="padding:12px;margin-top:0">
          <div style="font-weight:600">3. 导入 Refresh Token</div>
          <input type="password" id="m-refresh-token" placeholder="1//..." style="width:100%;margin:8px 0" />
          <button class="btn btn-sm" id="m-token-add">验证并导入</button>
        </div>
        <div class="card" style="padding:12px;margin-top:0">
          <div style="font-weight:600">4. JSON 批量导入 / 备份导出</div>
          <div class="muted small" style="margin:4px 0 8px">支持单个 JSON 文件或目录路径导入（按邮箱去重），或导出全部账号备份。</div>
          <input type="text" id="m-json-path" placeholder="输入 JSON 文件或目录完整路径…" style="width:100%;margin-bottom:8px" />
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-sm" id="m-json-import">导入 JSON</button>
            <button class="btn btn-sm" id="m-json-export">导出备份到该路径</button>
          </div>
        </div>
      </div>
    `,
    footerHtml: `<button class="btn" id="m-close">关闭</button>`,
  });
  footer.querySelector('#m-close').addEventListener('click', closeModal);
  body.querySelector('#m-save-current').addEventListener('click', async () => {
    const res = await window.gravitybox.rpc('account_save_current');
    if (res?.ok) { toast(res.account?.email || 'OK'); closeModal(); await loadAccounts(); }
    else toast(res?.error || 'Failed', true);
  });
  body.querySelector('#m-json-import')?.addEventListener('click', async () => {
    const pathVal = body.querySelector('#m-json-path')?.value?.trim();
    if (!pathVal) return toast('请输入 JSON 文件或目录路径', true);
    const res = await window.gravitybox.rpc('account_import_json', { paths: [pathVal] });
    if (res?.ok) {
      toast(`导入完成：新增 ${res.imported ?? 0}，更新 ${res.updated ?? 0}，跳过 ${res.skipped ?? 0}`);
      closeModal();
      await loadAccounts();
    } else {
      toast(res?.error || '导入失败', true);
    }
  });
  body.querySelector('#m-json-export')?.addEventListener('click', async () => {
    const pathVal = body.querySelector('#m-json-path')?.value?.trim();
    if (!pathVal) return toast('请输入导出目标 JSON 文件路径（如 D:\\accounts-backup.json）', true);
    const res = await window.gravitybox.rpc('account_export_backup', { path: pathVal, confirmed: true });
    if (res?.ok) {
      toast(`已导出 ${res.count ?? 0} 个账号至 ${res.path}`);
    } else {
      toast(res?.error || '导出失败', true);
    }
  });
  body.querySelector('#m-oauth-begin').addEventListener('click', async () => {
    const res = await window.gravitybox.rpc('account_oauth_begin');
    if (!res?.ok || !res.authUrl) {
      body.querySelector('#m-oauth-status').textContent = res?.error || 'OAuth unavailable';
      return;
    }
    await window.gravitybox.openExternal(res.authUrl);
    const oauthId = res.id;
    body.querySelector('#m-oauth-status').textContent = '等待浏览器完成授权…';
    const timer = setInterval(async () => {
      const st = await window.gravitybox.rpc('account_oauth_status', { id: oauthId });
      if (!st?.ok) { clearInterval(timer); return; }
      if (st.state === 'succeeded') {
        clearInterval(timer);
        toast(st.account?.email || 'OAuth OK');
        closeModal();
        await loadAccounts();
      } else if (['failed', 'cancelled', 'expired'].includes(st.state)) {
        clearInterval(timer);
        body.querySelector('#m-oauth-status').textContent = st.error || st.state;
      }
    }, 1000);
  });
  body.querySelector('#m-token-add').addEventListener('click', async () => {
    const refreshToken = body.querySelector('#m-refresh-token').value.trim();
    if (!refreshToken) return;
    const res = await window.gravitybox.rpc('account_add_token_start', { refreshToken });
    if (res?.ok) {
      toast('正在验证 Token…');
      closeModal();
      setTimeout(() => { void loadAccounts(); }, 2500);
    } else toast(res?.error || 'Failed', true);
  });
}

function openPolicyModal() {
  const cfg = state.autoSwitchConfig || {};
  const { body, footer } = showModal({
    title: t('accounts.smart_switch.config_btn', null, '配置智能切换策略'),
    bodyHtml: `
      <div style="display:flex;flex-direction:column;gap:12px">
        <label class="small">触发阈值 (%) <input type="number" id="pol-threshold" min="1" max="98" value="${cfg.threshold ?? 10}" style="width:100%;margin-top:4px"/></label>
        <label class="small">候选最低配额 (%) <input type="number" id="pol-recovery" min="2" max="100" value="${cfg.recoveryThreshold ?? 30}" style="width:100%;margin-top:4px"/></label>
        <label class="small">监测范围
          <select id="pol-scope" style="width:100%;margin-top:4px">
            <option value="all" ${cfg.modelScope === 'all' ? 'selected' : ''}>全部主力模型</option>
            <option value="gemini" ${cfg.modelScope === 'gemini' ? 'selected' : ''}>仅 Gemini</option>
            <option value="claude" ${cfg.modelScope === 'claude' ? 'selected' : ''}>仅 Claude/GPT</option>
            <option value="gemini_all" ${cfg.modelScope === 'gemini_all' ? 'selected' : ''}>Gemini + Argon/Carbon</option>
          </select>
        </label>
        <label class="small">调度策略
          <select id="pol-strategy" style="width:100%;margin-top:4px">
            <option value="highest" ${cfg.strategy === 'highest' ? 'selected' : ''}>优先最高剩余配额</option>
            <option value="round_robin" ${cfg.strategy === 'round_robin' ? 'selected' : ''}>顺序轮转</option>
          </select>
        </label>
      </div>
    `,
    footerHtml: `<button class="btn" id="m-cancel">取消</button><button class="btn btn-primary" id="m-save">保存</button>`,
  });
  footer.querySelector('#m-cancel').addEventListener('click', closeModal);
  footer.querySelector('#m-save').addEventListener('click', async () => {
    const res = await window.gravitybox.rpc('auto_switch_set', {
      config: {
        threshold: Number(body.querySelector('#pol-threshold').value),
        recoveryThreshold: Number(body.querySelector('#pol-recovery').value),
        modelScope: body.querySelector('#pol-scope').value,
        strategy: body.querySelector('#pol-strategy').value,
      },
    });
    if (res?.ok) {
      state.autoSwitchConfig = res.config;
      closeModal();
      await loadAccounts();
    } else {
      toast(res?.error || 'Invalid policy', true);
    }
  });
}

function renderUsagePage(root) {
  const rep = state.usageReport || {};
  const s = rep.summary || rep;
  const accounts = state.accountsPayload?.accounts || [];
  const models = Array.isArray(rep.byModel) ? rep.byModel : [];
  const totalTokens = Number(s.totalTokens ?? s.total_tokens ?? 0);
  const inputTokens = Number(s.promptTokens ?? s.input_tokens ?? s.inputTokens ?? 0);
  const cachedTokens = Number(s.cachedTokens ?? s.cached_tokens ?? 0);
  const outputTokens = Number(s.candidatesTokens ?? s.output_tokens ?? s.outputTokens ?? 0);
  const totalUsd = Number(s.estimatedUsd ?? s.estimated_usd ?? rep.totalEstimatedUsd ?? 0);
  const requests = Number(s.requestCount ?? s.request_count ?? 0);
  const cacheRate = Number(s.cacheHitRate ?? 0);
  const periods = [
    { id: 'today', label: t('usage.period.today', null, '今日') },
    { id: '7d', label: t('usage.period.7d', null, '近 7 天') },
    { id: '30d', label: t('usage.period.30d', null, '近 30 天') },
    { id: 'all', label: t('usage.period.all', null, '全部') },
  ];

  const trendSrc = state.usagePeriod === 'today'
    ? normalizeTodayHourlyPoints(rep.todayHourly, 3)
    : normalizeDailyTrends(rep);

  const pricedModels = models.filter(m => (m.estimatedUsd || 0) > 0).slice(0, 5);
  const donutSlices = pricedModels.map(m => ({ label: m.model, value: m.estimatedUsd || 0 }));

  root.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${escapeHtml(t('usage.title', null, '用量'))}</h1>
      <div class="header-actions">
        <select id="usage-account-filter">
          <option value="all">全部账号</option>
          ${accounts.map(a => `<option value="${escapeHtml(a.id)}" ${state.usageAccountId === a.id ? 'selected' : ''}>${escapeHtml(a.email)}</option>`).join('')}
        </select>
        <div class="segmented">
          ${periods.map(p => `<button class="${state.usagePeriod === p.id ? 'active' : ''}" data-period="${p.id}">${escapeHtml(p.label)}</button>`).join('')}
        </div>
        <button class="btn btn-sm" id="btn-usage-refresh">${escapeHtml(t('common.refresh', null, '刷新'))}</button>
        <button class="btn btn-sm" id="btn-usage-export">${escapeHtml(t('usage.export_btn', null, '导出…'))}</button>
      </div>
    </div>

    <div class="card">
      <div class="account-head">
        <div>
          <div class="muted xs">${escapeHtml(t('usage.section.token_usage', null, 'Token 用量'))}</div>
          <div class="metric-value tabular" style="font-size:30px;margin:2px 0">${escapeHtml(formatTokens(totalTokens))}</div>
          <div class="muted xs tabular">输入 ${formatTokens(inputTokens)} · 缓存读取 ${formatTokens(cachedTokens)} · 输出 ${formatTokens(outputTokens)}</div>
        </div>
        <span class="pill">${escapeHtml(periods.find(p => p.id === state.usagePeriod)?.label || '')}</span>
      </div>
      <div class="chart-wrap" id="usage-trend-chart"></div>
    </div>

    <div class="bento-2">
      <div class="card" style="margin-top:0">
        <div class="account-head">
          <span style="font-weight:600">${escapeHtml(t('usage.section.cost', null, 'API 费用估算'))}</span>
          <span class="tabular" style="font-size:22px;font-weight:700">${escapeHtml(formatUsd(totalUsd))}</span>
        </div>
        <div class="donut-layout">
          <div id="usage-donut-svg"></div>
          <div class="donut-legend">
            ${pricedModels.length === 0
              ? `<div class="muted small">—</div>`
              : pricedModels.map((m, idx) => {
                  const pct = totalUsd > 0 ? Math.round(((m.estimatedUsd || 0) / totalUsd) * 100) : 0;
                  const colors = ['#2563eb', '#0d9488', '#7c3aed', '#d97706', '#4f46e5'];
                  return `
                    <div class="legend-row">
                      <span class="legend-dot" style="background:${colors[idx % colors.length]}"></span>
                      <div style="min-width:0">
                        <div style="font-weight:600" class="truncate">${escapeHtml(m.model)}</div>
                        <div class="muted xs tabular">${formatUsd(m.estimatedUsd)} · ${pct}%</div>
                      </div>
                    </div>
                  `;
                }).join('')}
          </div>
        </div>
      </div>

      <div class="card" style="margin-top:0">
        <div class="account-head">
          <span style="font-weight:600">${escapeHtml(t('usage.section.requests_cache', null, '请求与缓存'))}</span>
          <div style="display:flex;gap:6px">
            <button class="btn btn-sm" id="btn-pricing-modal">API 定价</button>
            <button class="btn btn-sm" id="btn-usage-log">${escapeHtml(t('usage.request_details_btn', null, '请求明细…'))}</button>
          </div>
        </div>
        <div class="row-divider"></div>
        <div class="setting-row">
          <div>
            <div class="setting-title">${escapeHtml(t('usage.requests.total', null, '请求总数'))}</div>
            <div class="setting-sub tabular">${requests > 0 ? `平均每次约 ${formatTokens(totalTokens / requests)} Token` : '—'}</div>
          </div>
          <div class="tabular" style="font-size:22px;font-weight:700">${escapeHtml(formatNumber(requests))}</div>
        </div>
        <div class="row-divider"></div>
        <div>
          <div class="setting-row">
            <div>
              <div class="setting-title">${escapeHtml(t('usage.cache.hit_rate', null, '缓存命中率'))}</div>
              <div class="setting-sub tabular">读取 ${formatTokens(cachedTokens)} Token</div>
            </div>
            <div class="tabular" style="font-size:22px;font-weight:700">${cacheRate.toFixed(1)}%</div>
          </div>
          <div class="progress-track" style="margin-top:8px"><div class="progress-fill" style="width:${Math.min(100, Math.max(0, cacheRate))}%"></div></div>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="account-head" style="margin-bottom:8px">
        <span style="font-weight:600">${escapeHtml(t('menu_panel.models_header', null, '模型用量'))}</span>
        <span class="muted small">${models.length} 个模型</span>
      </div>
      ${models.length === 0
        ? `<div class="muted small" style="padding:20px 0;text-align:center">${escapeHtml(t('menu_panel.models_empty', null, '当前时间范围暂无模型调用记录'))}</div>`
        : models.map(m => {
            const share = totalTokens > 0 ? Math.round(((m.totalTokens || 0) / totalTokens) * 100) : 0;
            return `
              <div class="model-row">
                <div class="model-left">
                  <div class="model-icon-box"><img src="${modelIconPath(m.model)}" alt="" /></div>
                  <div style="min-width:0">
                    <div style="font-weight:600" class="truncate">${escapeHtml(m.model)}</div>
                    <div class="muted xs tabular">${formatTokens(m.totalTokens)} Token · ${formatNumber(m.requestCount)} req</div>
                  </div>
                </div>
                <div style="text-align:right;flex-shrink:0">
                  <div class="tabular" style="font-weight:700">${m.priced ? escapeHtml(formatUsd(m.estimatedUsd)) : escapeHtml(t('menu_panel.usage.unpriced', null, '未计价'))}</div>
                  <div class="muted xs tabular">占比 ${share}%</div>
                </div>
              </div>
            `;
          }).join('')}
    </div>
  `;

  renderBarChartSvg(document.getElementById('usage-trend-chart'), trendSrc, { metric: 'tokens', height: 145 });
  renderDonutSvg(document.getElementById('usage-donut-svg'), donutSlices, formatUsd(totalUsd), '估算');

  root.querySelectorAll('.segmented button').forEach(btn => btn.addEventListener('click', () => {
    state.usagePeriod = btn.getAttribute('data-period');
    void loadUsage(true);
  }));
  document.getElementById('usage-account-filter')?.addEventListener('change', e => {
    state.usageAccountId = e.target.value;
    void loadUsage(true);
  });
  document.getElementById('btn-usage-refresh')?.addEventListener('click', () => void loadUsage(true));
  document.getElementById('btn-usage-export')?.addEventListener('click', async () => {
    await window.gravitybox.saveJsonDialog(`gravitybox-usage-${state.usagePeriod}.json`, rep);
  });
  document.getElementById('btn-usage-log')?.addEventListener('click', openUsageEventsModal);
  document.getElementById('btn-pricing-modal')?.addEventListener('click', openPricingModal);
}

async function openUsageEventsModal() {
  const { body, footer } = showModal({
    title: t('usage.request_details_btn', null, '请求明细'),
    bodyHtml: `
      <div style="display:flex;gap:8px;margin-bottom:10px">
        <input type="text" id="evt-search" placeholder="搜索模型名称…" style="flex:1" />
        <button class="btn btn-sm" id="evt-search-btn">搜索</button>
      </div>
      <div id="evt-list" class="muted small">加载中…</div>
    `,
    footerHtml: `<button class="btn" id="m-close">关闭</button>`,
  });
  footer.querySelector('#m-close').addEventListener('click', closeModal);

  async function query(q = '') {
    const res = await window.gravitybox.rpc('usage_events', {
      period: state.usagePeriod,
      accountId: state.usageAccountId === 'all' ? undefined : state.usageAccountId,
      query: q,
      offset: 0,
      limit: 60,
    });
    const events = Array.isArray(res?.events) ? res.events : [];
    const listEl = body.querySelector('#evt-list');
    if (!events.length) {
      listEl.innerHTML = `<div class="muted small" style="padding:20px 0;text-align:center">暂无请求记录</div>`;
      return;
    }
    listEl.innerHTML = events.map(e => `
      <div style="padding:8px 0;border-bottom:1px solid var(--border-subtle);display:flex;justify-content:space-between;gap:10px">
        <div style="min-width:0">
          <div style="font-weight:600" class="truncate">${escapeHtml(e.model || 'unknown')}</div>
          <div class="muted xs tabular">${escapeHtml(formatTimestampShort(e.timestamp_seconds || e.timestamp))} · in ${formatTokens(e.input_tokens)} / cache ${formatTokens(e.cached_tokens)} / out ${formatTokens(e.output_tokens)}</div>
        </div>
        <div class="tabular small" style="font-weight:600;flex-shrink:0">${e.estimated_usd != null ? formatUsd(e.estimated_usd) : '—'}</div>
      </div>
    `).join('');
  }
  await query('');
  body.querySelector('#evt-search-btn').addEventListener('click', () => {
    void query(body.querySelector('#evt-search').value.trim());
  });
}

async function openPricingModal() {
  const res = await window.gravitybox.rpc('api_pricing_get');
  const models = Array.isArray(res?.models) ? res.models : [];
  const { body, footer } = showModal({
    title: 'API 定价与历史重估',
    bodyHtml: `
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
        <span class="muted small">共 ${models.length} 款模型定价</span>
        <button class="btn btn-sm" id="btn-revalue-unpriced">重估未计价历史</button>
      </div>
      <div style="max-height:340px;overflow-y:auto">
        ${models.slice(0, 60).map(m => `
          <div style="padding:7px 0;border-bottom:1px solid var(--border-subtle);display:flex;justify-content:space-between;gap:10px">
            <span style="font-weight:600" class="truncate">${escapeHtml(m.model || m.id)}</span>
            <span class="muted xs tabular">in $${m.inputUsdPerMillion ?? m.input ?? 0}/M · out $${m.outputUsdPerMillion ?? m.output ?? 0}/M</span>
          </div>
        `).join('')}
      </div>
    `,
    footerHtml: `<button class="btn" id="m-close">关闭</button>`,
  });
  footer.querySelector('#m-close').addEventListener('click', closeModal);
  body.querySelector('#btn-revalue-unpriced')?.addEventListener('click', async () => {
    const prev = await window.gravitybox.rpc('api_pricing_revalue_preview', { mode: 'unpriced_only' });
    if (!prev?.ok) return toast(prev?.error || 'Preview failed', true);
    const rev = await window.gravitybox.rpc('api_pricing_revalue', {
      confirm: true,
      mode: 'unpriced_only',
      previewId: prev.preview?.previewId,
    });
    if (rev?.ok) {
      toast('历史用量重估完成');
      await loadUsage(true);
    } else {
      toast(rev?.error || 'Revalue failed', true);
    }
  });
}

function renderSettingsPage(root) {
  const cfg = state.config || {};
  const maint = state.maintenanceSummary;
  const storageText = maint
    ? t('settings.storage.detail_subtitle', { safe: formatBytes(maint.safeBytes || 0), stateful: formatBytes(maint.historyBytes || 0) }, `运行缓存 ${formatBytes(maint.safeBytes || 0)}，另有 ${formatBytes(maint.historyBytes || 0)} 后台日志`)
    : t('settings.storage.default_subtitle', null, '一键释放运行缓存与超期日志，登录态与对话完好保留');

  root.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${escapeHtml(t('settings.title', null, '设置'))}</h1>
    </div>

    <div class="section-label">${escapeHtml(t('settings.section.enhance', null, 'Antigravity 增强'))}</div>
    <div class="card">
      <div class="setting-row">
        <div class="setting-left">
          <div class="setting-icon">🌐</div>
          <div>
            <div class="setting-title">${escapeHtml(t('settings.language.title', null, '显示语言'))}</div>
            <div class="setting-sub">${escapeHtml(state.statusPayload?.status?.deepAsarActive ? t('localization.guard_active', null, '已自动接管 · GravityBox 仅运行 HUD 增强，不重复改写界面') : t('settings.language.subtitle', null, '同时决定 GravityBox 与 Antigravity 的界面语言，不改动官方应用'))}</div>
          </div>
        </div>
        <div style="display:flex;align-items:center;gap:8px">
          ${state.statusPayload?.status?.deepAsarActive ? `<button class="btn btn-sm" id="btn-goto-deep-loc">${escapeHtml(t('nav.localization', null, '深度汉化'))}</button>` : ''}
          <select id="set-language">
          <option value="system" ${cfg.appLanguage === 'system' ? 'selected' : ''}>${escapeHtml(t('language.system', null, '跟随系统'))}</option>
          <option value="zh-Hans" ${cfg.appLanguage === 'zh-Hans' ? 'selected' : ''}>简体中文</option>
          <option value="en" ${cfg.appLanguage === 'en' ? 'selected' : ''}>English</option>
          </select>
        </div>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <div class="setting-left">
          <div class="setting-icon">📊</div>
          <div>
            <div class="setting-title">${escapeHtml(t('settings.hud.title', null, '对话状态栏'))}</div>
            <div class="setting-sub">${escapeHtml(t('settings.hud.subtitle', null, '在 Antigravity 输入框下方显示轮次、Token 与上下文'))}</div>
          </div>
        </div>
        <label class="switch">
          <input type="checkbox" id="set-hud" ${cfg.hudEnabled !== false ? 'checked' : ''} />
          <span class="switch-slider"></span>
        </label>
      </div>
    </div>

    <div class="section-label">${escapeHtml(t('settings.section.quota_pricing', null, '配额与计价'))}</div>
    <div class="card">
      <div class="setting-row">
        <div class="setting-left">
          <div class="setting-icon">↻</div>
          <div>
            <div class="setting-title">${escapeHtml(t('settings.refresh.title', null, '配额刷新间隔'))}</div>
            <div class="setting-sub">${escapeHtml(t('settings.refresh.subtitle', null, '定时更新已保存账号的剩余配额'))}</div>
          </div>
        </div>
        <select id="set-refresh-interval">
          <option value="0" ${Number(cfg.quotaRefreshMinutes) === 0 ? 'selected' : ''}>${escapeHtml(t('settings.refresh.manual', null, '手动刷新'))}</option>
          <option value="5" ${Number(cfg.quotaRefreshMinutes) === 5 ? 'selected' : ''}>${escapeHtml(t('settings.refresh.5m', null, '每 5 分钟'))}</option>
          <option value="10" ${Number(cfg.quotaRefreshMinutes) === 10 ? 'selected' : ''}>${escapeHtml(t('settings.refresh.10m', null, '每 10 分钟'))}</option>
          <option value="15" ${Number(cfg.quotaRefreshMinutes) === 15 ? 'selected' : ''}>${escapeHtml(t('settings.refresh.15m', null, '每 15 分钟'))}</option>
          <option value="30" ${Number(cfg.quotaRefreshMinutes) === 30 ? 'selected' : ''}>${escapeHtml(t('settings.refresh.30m', null, '每 30 分钟'))}</option>
          <option value="60" ${Number(cfg.quotaRefreshMinutes) === 60 ? 'selected' : ''}>${escapeHtml(t('settings.refresh.60m', null, '每 60 分钟'))}</option>
        </select>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <div class="setting-left">
          <div class="setting-icon">$</div>
          <div>
            <div class="setting-title">${escapeHtml(t('settings.pricing_sync.title', null, '自动更新价格基准'))}</div>
            <div class="setting-sub">${escapeHtml(t('settings.pricing_sync.subtitle', null, '自动同步公开模型费率，每 24 小时检查一次'))}</div>
          </div>
        </div>
        <div style="display:flex;align-items:center;gap:10px">
          <button class="btn btn-sm" id="btn-pricing-check">${escapeHtml(t('settings.pricing_sync.check_now', null, '立即检查'))}</button>
          <label class="switch">
            <input type="checkbox" id="set-pricing-sync" ${cfg.autoPricingSyncEnabled ? 'checked' : ''} />
            <span class="switch-slider"></span>
          </label>
        </div>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <div class="setting-left">
          <div class="setting-icon">🔑</div>
          <div>
            <div class="setting-title" style="display:flex;align-items:center;gap:8px">
              <span>${escapeHtml(t('settings.oauth.title', null, '后台自动续期凭据 (Google OAuth)'))}</span>
              <span class="pill ${state.statusPayload?.status?.oauthClientConfigured ? 'pill-green' : 'pill-amber'}">${escapeHtml(state.statusPayload?.status?.oauthClientConfigured ? t('settings.oauth.configured', null, '已配置') : t('settings.oauth.unconfigured', null, '未配置'))}</span>
            </div>
            <div class="setting-sub">${escapeHtml(t('settings.oauth.subtitle', null, '可选配置 · 用于备用账号过期后后台自动刷新 Token 及浏览器授权登录'))}</div>
          </div>
        </div>
        <button class="btn btn-sm" id="btn-config-oauth">${escapeHtml(t('settings.oauth.config_btn', null, '配置…'))}</button>
      </div>
    </div>

    <div class="section-label">${escapeHtml(t('settings.section.system_storage', null, '系统与存储'))}</div>
    <div class="card">
      <div class="setting-row">
        <div class="setting-left">
          <div class="setting-icon">⚡</div>
          <div>
            <div class="setting-title">${escapeHtml(t('settings.login.title', null, '登录时启动'))}</div>
            <div class="setting-sub">登录 Windows 时自动在系统托盘驻留</div>
          </div>
        </div>
        <label class="switch">
          <input type="checkbox" id="set-login-launch" ${state.appInfo?.openAtLogin ? 'checked' : ''} />
          <span class="switch-slider"></span>
        </label>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <div class="setting-left">
          <div class="setting-icon">🔗</div>
          <div>
            <div class="setting-title">${escapeHtml(t('settings.sync_lifecycle.title', null, '跟随 Antigravity 启停'))}</div>
            <div class="setting-sub">${escapeHtml(t('settings.sync_lifecycle.subtitle', null, '随 Antigravity 自动启动并同步退出'))}</div>
          </div>
        </div>
        <label class="switch">
          <input type="checkbox" id="set-sync-lifecycle" ${cfg.syncAntigravityLifecycle ? 'checked' : ''} />
          <span class="switch-slider"></span>
        </label>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <div class="setting-left">
          <div class="setting-icon">💾</div>
          <div>
            <div class="setting-title" style="display:flex;align-items:center;gap:8px">
              <span>${escapeHtml(t('settings.storage.title', null, '存储与维护'))}</span>
              ${maint ? `<span class="pill pill-blue">${escapeHtml(t('settings.storage.reclaimable', { size: formatBytes(maint.safeBytes || 0) }, `可释放 ${formatBytes(maint.safeBytes || 0)}`))}</span>` : ''}
            </div>
            <div class="setting-sub">${escapeHtml(storageText)}</div>
          </div>
        </div>
        <button class="btn btn-sm" id="btn-manage-storage">${escapeHtml(t('settings.storage.manage_btn', null, '管理存储…'))}</button>
      </div>
    </div>
  `;

  document.getElementById('btn-goto-deep-loc')?.addEventListener('click', () => {
    state.activeTab = 'localization';
    renderSidebar();
    renderCurrentPage();
    void refreshActiveTabData();
  });

  document.getElementById('set-language')?.addEventListener('change', async e => {
    const language = e.target.value;
    await window.gravitybox.setConfig({ appLanguage: language });
    await window.gravitybox.rpc('language_set', {
      language,
      systemLocales: [state.systemLocale || navigator.language],
    });
    const fresh = await window.gravitybox.getState();
    state.activeLocale = fresh.activeLocale;
    state.config = fresh.config;
    renderSidebar();
    renderSettingsPage(root);
  });

  document.getElementById('set-hud')?.addEventListener('change', async e => {
    await window.gravitybox.rpc('hud_set', { enabled: e.target.checked });
  });

  document.getElementById('set-refresh-interval')?.addEventListener('change', async e => {
    state.config = await window.gravitybox.setConfig({ quotaRefreshMinutes: Number(e.target.value) });
  });

  document.getElementById('set-pricing-sync')?.addEventListener('change', async e => {
    await window.gravitybox.rpc('pricing_sync_set', { enabled: e.target.checked });
  });

  document.getElementById('btn-pricing-check')?.addEventListener('click', async () => {
    const res = await window.gravitybox.rpc('pricing_sync_check');
    if (res?.ok) toast(t('settings.pricing_sync.synced', { count: res.models?.length ?? 0 }, '价格基准已同步'));
    else toast(res?.error || 'Sync failed', true);
  });

  document.getElementById('set-login-launch')?.addEventListener('change', async e => {
    const res = await window.gravitybox.setLoginItem(e.target.checked);
    state.appInfo.openAtLogin = res.openAtLogin;
  });

  document.getElementById('set-sync-lifecycle')?.addEventListener('change', async e => {
    state.config = await window.gravitybox.setConfig({ syncAntigravityLifecycle: e.target.checked });
  });

  document.getElementById('btn-manage-storage')?.addEventListener('click', openMaintenanceModal);
  document.getElementById('btn-config-oauth')?.addEventListener('click', openOAuthClientModal);
}

async function openOAuthClientModal() {
  const info = await window.gravitybox.rpc('oauth_client_get');
  const { body, footer } = showModal({
    title: t('settings.oauth.title', null, '后台自动续期凭据 (Google OAuth)'),
    bodyHtml: `
      <div style="display:flex;flex-direction:column;gap:12px">
        <div class="muted small">${escapeHtml(t('settings.oauth.subtitle', null, '可选配置 · 用于备用账号过期后后台自动刷新 Token 及浏览器授权登录'))}</div>
        <div>
          <label class="small" style="display:block;margin-bottom:4px;font-weight:600">Client ID (GRAVITYBOX_GOOGLE_CLIENT_ID)</label>
          <input id="m-oauth-cid" type="text" style="width:100%" value="${escapeHtml(info?.clientId || '')}" placeholder="xxxx.apps.googleusercontent.com" />
        </div>
        <div>
          <label class="small" style="display:block;margin-bottom:4px;font-weight:600">Client Secret (GRAVITYBOX_GOOGLE_CLIENT_SECRET)</label>
          <input id="m-oauth-csec" type="password" style="width:100%" value="" placeholder="${escapeHtml(info?.hasSecret ? '••••••••（如需修改请重新输入）' : 'GOCSPX-...')}" />
        </div>
        ${info?.envPath ? `<div class="muted xs" style="word-break:break-all">配置文件：${escapeHtml(info.envPath)}</div>` : ''}
      </div>
    `,
    footerHtml: `
      ${info?.configured ? `<button class="btn btn-danger" id="m-oauth-clear">${escapeHtml(t('settings.oauth.clear_btn', null, '清除'))}</button>` : ''}
      <button class="btn" id="m-oauth-cancel">${escapeHtml(t('common.cancel', null, '取消'))}</button>
      <button class="btn btn-primary" id="m-oauth-save">${escapeHtml(t('settings.oauth.save_btn', null, '保存配置'))}</button>
    `,
  });
  footer.querySelector('#m-oauth-cancel')?.addEventListener('click', closeModal);
  footer.querySelector('#m-oauth-clear')?.addEventListener('click', async () => {
    const res = await window.gravitybox.rpc('oauth_client_set', { clientId: '', clientSecret: '' });
    if (res?.ok) {
      if (state.statusPayload?.status) state.statusPayload.status.oauthClientConfigured = false;
      closeModal();
      toast(t('settings.oauth.cleared', null, 'OAuth 凭据已清除'));
      renderCurrentPage();
    } else {
      toast(res?.error || 'Failed', true);
    }
  });
  footer.querySelector('#m-oauth-save')?.addEventListener('click', async () => {
    const clientId = body.querySelector('#m-oauth-cid')?.value?.trim() || '';
    const clientSecret = body.querySelector('#m-oauth-csec')?.value?.trim() || '';
    const res = await window.gravitybox.rpc('oauth_client_set', { clientId, clientSecret });
    if (res?.ok) {
      if (state.statusPayload?.status) state.statusPayload.status.oauthClientConfigured = Boolean(res.configured);
      closeModal();
      toast(t('settings.oauth.saved', null, 'OAuth 凭据已保存并生效'));
      renderCurrentPage();
    } else {
      toast(res?.error || 'Failed', true);
    }
  });
}

async function openMaintenanceModal() {
  const { body, footer } = showModal({
    title: t('settings.storage.title', null, '存储与维护'),
    bodyHtml: `<div class="muted small">正在扫描缓存与日志…</div>`,
    footerHtml: `<button class="btn" id="m-close">关闭</button>`,
  });
  footer.querySelector('#m-close').addEventListener('click', closeModal);

  async function refreshScan(retentionDays = 7) {
    const [scan, hist] = await Promise.all([
      window.gravitybox.rpc('maintenance_scan', { retentionDays }),
      window.gravitybox.rpc('maintenance_history'),
    ]);
    const safeBytes = Number(scan?.safeReclaimableBytes ?? scan?.reclaimableSafeBytes ?? 0);
    const historyBytes = Number(scan?.historySlimmingBytes ?? scan?.reclaimableHistoryBytes ?? 0);
    const snapshots = Array.isArray(hist?.snapshots) ? hist.snapshots : [];
    const lastSnap = snapshots[0];
    body.innerHTML = `
      <div class="card" style="padding:13px">
        <div class="account-head">
          <div>
            <div class="muted xs">已选可释放空间</div>
            <div style="font-size:24px;font-weight:700" class="tabular" id="maint-selected-size">${escapeHtml(formatBytes(safeBytes))}</div>
          </div>
          <button class="btn btn-primary" id="btn-smart-clear">一键清理</button>
        </div>
        <div class="muted xs" style="margin-top:6px">运行缓存 ${formatBytes(safeBytes)} · 后台日志 ${formatBytes(historyBytes)} · 账号与对话完好保留</div>
      </div>
      <div class="card" style="padding:13px">
        <div class="setting-row">
          <div>
            <div class="setting-title">应用运行缓存</div>
            <div class="setting-sub">临时网页、编译与崩溃残留 (${formatBytes(safeBytes)})</div>
          </div>
          <label class="switch"><input type="checkbox" id="chk-runtime-cache" checked /><span class="switch-slider"></span></label>
        </div>
        <div class="row-divider"></div>
        <div class="setting-row">
          <div>
            <div class="setting-title">后台运行日志（保留 ${retentionDays} 天）</div>
            <div class="setting-sub">清理超期步骤日志与冗长转录 (${formatBytes(historyBytes)})</div>
          </div>
          <label class="switch"><input type="checkbox" id="chk-history-logs" /><span class="switch-slider"></span></label>
        </div>
      </div>
      ${lastSnap ? `
        <div class="card" style="padding:13px">
          <div class="setting-row">
            <div>
              <div class="setting-title">上次清理释放 ${escapeHtml(formatBytes(lastSnap.totalBytes || lastSnap.reclaimedBytes || 0))}</div>
              <div class="setting-sub">${escapeHtml(lastSnap.createdAt || '')}</div>
            </div>
            <button class="btn btn-sm" id="btn-restore-maint" data-id="${escapeHtml(lastSnap.id || lastSnap.snapshotId)}">撤回上次清理</button>
          </div>
        </div>
      ` : ''}
    `;

    const updateTotal = () => {
      const r = body.querySelector('#chk-runtime-cache').checked ? safeBytes : 0;
      const h = body.querySelector('#chk-history-logs').checked ? historyBytes : 0;
      body.querySelector('#maint-selected-size').textContent = formatBytes(r + h);
    };
    body.querySelector('#chk-runtime-cache').addEventListener('change', updateTotal);
    body.querySelector('#chk-history-logs').addEventListener('change', updateTotal);

    body.querySelector('#btn-smart-clear').addEventListener('click', async () => {
      const scopes = [];
      if (body.querySelector('#chk-runtime-cache').checked) scopes.push('runtime_cache');
      if (body.querySelector('#chk-history-logs').checked) scopes.push('history_logs');
      if (!scopes.length) return;
      const res = await window.gravitybox.rpc('maintenance_smart_clear', { scopes, retentionDays });
      if (res?.ok) {
        toast(`已释放 ${formatBytes(res.reclaimedBytes || 0)}`);
        await refreshScan(retentionDays);
        void loadMaintenanceSummary();
      } else toast(res?.error || 'Clear failed', true);
    });
    body.querySelector('#btn-restore-maint')?.addEventListener('click', async e => {
      const res = await window.gravitybox.rpc('maintenance_restore', { snapshotId: e.target.getAttribute('data-id') });
      if (res?.ok) { toast('已撤回上次清理'); await refreshScan(retentionDays); }
      else toast(res?.error || 'Restore failed', true);
    });
  }
  await refreshScan(7);
}

function renderAboutPage(root) {
  const info = state.appInfo || {};
  const u = state.updateState || {};
  const s = state.statusPayload?.status || {};
  const repoSlug = info.repoSlug || 'Enzoo404/gravitybox';
  const releaseUrl = u.releaseUrl || `https://github.com/${repoSlug}/releases`;

  let updateStatusText = '';
  if (u.state === 'checking') updateStatusText = t('about.status.checking', null, '正在检查最新版本…');
  else if (u.state === 'up-to-date') updateStatusText = t('about.status.up_to_date', null, '已是最新版本');
  else if (u.state === 'available') updateStatusText = t('about.status.available', { tag: u.latestTag }, `发现新版本 ${u.latestTag}`);
  else if (u.state === 'downloading') updateStatusText = t('about.status.downloading_progress', { pct: u.progress || 0 }, `下载中 ${u.progress || 0}%`);
  else if (u.state === 'ready') updateStatusText = t('about.status.ready', { tag: u.latestTag }, `${u.latestTag} 更新包已就绪`);
  else if (u.state === 'error') updateStatusText = t('about.status.failed', { message: u.error || '' }, `检查更新未完成：${u.error || ''}`);

  root.innerHTML = `
    <div class="page-header">
      <h1 class="page-title">${escapeHtml(t('about.title', null, '关于'))}</h1>
    </div>

    <div class="card">
      <div class="account-head">
        <div style="display:flex;align-items:center;gap:12px">
          <div style="width:46px;height:46px;border-radius:10px;background:var(--bg-pill-muted);display:flex;align-items:center;justify-content:center">
            <img src="../../assets/master-1024.png" alt="" style="width:30px;height:30px" />
          </div>
          <div>
            <div style="display:flex;align-items:center;gap:8px">
              <span style="font-size:18px;font-weight:700">GravityBox</span>
              <span class="pill pill-blue">v${escapeHtml(info.version || '1.1.2')} (Windows)</span>
            </div>
            ${updateStatusText ? `<div class="muted small" style="margin-top:3px">${escapeHtml(updateStatusText)}</div>` : ''}
          </div>
        </div>
        <div style="display:flex;gap:8px">
          <button class="btn btn-sm" id="btn-release-notes">${escapeHtml(t('about.release_notes', null, '更新日志 ↗'))}</button>
          ${u.state === 'available'
            ? `<button class="btn btn-primary btn-sm" id="btn-download-update">${escapeHtml(t('about.install_now', null, '立即更新'))}</button>`
            : u.state === 'downloading'
            ? `<button class="btn btn-sm" id="btn-cancel-update">${escapeHtml(t('about.cancel_download', null, '取消下载'))}</button>`
            : u.state === 'ready'
            ? `<button class="btn btn-primary btn-sm" id="btn-install-update">${escapeHtml(t('about.install_now', null, '立即安装'))}</button>`
            : `<button class="btn btn-sm" id="btn-check-update">${escapeHtml(t('about.check_update', null, '检查更新'))}</button>`}
        </div>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <span style="font-weight:600">${escapeHtml(t('about.auto_update', null, '自动检查更新'))}</span>
        <label class="switch">
          <input type="checkbox" id="set-auto-update" ${state.config?.autoUpdateEnabled !== false ? 'checked' : ''} />
          <span class="switch-slider"></span>
        </label>
      </div>
    </div>

    <div class="section-label">${escapeHtml(t('about.section.runtime', null, '运行信息'))}</div>
    <div class="card">
      <div class="setting-row">
        <span style="font-weight:600">${escapeHtml(t('about.target_app', null, '目标应用'))}</span>
        <span class="small mono">${escapeHtml(s.appVersion ? `Antigravity ${s.appVersion}` : (info.antigravityExe || 'Antigravity'))}</span>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <div style="min-width:0;flex:1">
          <div style="font-weight:600">${escapeHtml(t('about.data_dir', null, 'GravityBox 数据目录'))}</div>
          <div class="muted xs mono truncate">${escapeHtml(info.stateDir || '')}</div>
        </div>
        <div style="display:flex;gap:6px;flex-shrink:0">
          <button class="btn btn-sm" id="btn-copy-data-dir">${escapeHtml(t('about.copy_data_path', null, '复制路径'))}</button>
          <button class="btn btn-sm" id="btn-open-data-dir">在资源管理器中打开</button>
        </div>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <span style="font-weight:600">GitHub Releases</span>
        <button class="btn btn-sm" id="btn-open-github">GitHub ↗</button>
      </div>
    </div>
  `;

  document.getElementById('btn-check-update')?.addEventListener('click', () => void window.gravitybox.checkUpdates());
  document.getElementById('btn-download-update')?.addEventListener('click', () => void window.gravitybox.downloadUpdate());
  document.getElementById('btn-cancel-update')?.addEventListener('click', () => void window.gravitybox.cancelUpdate());
  document.getElementById('btn-install-update')?.addEventListener('click', () => void window.gravitybox.installUpdate());
  document.getElementById('btn-release-notes')?.addEventListener('click', () => void window.gravitybox.openExternal(releaseUrl));
  document.getElementById('btn-open-github')?.addEventListener('click', () => void window.gravitybox.openExternal(releaseUrl));
  document.getElementById('btn-open-data-dir')?.addEventListener('click', () => void window.gravitybox.openPath(info.stateDir));
  document.getElementById('btn-copy-data-dir')?.addEventListener('click', async () => {
    await window.gravitybox.copyText(info.stateDir || '');
    toast('已复制路径');
  });
  document.getElementById('set-auto-update')?.addEventListener('change', async e => {
    state.config = await window.gravitybox.setConfig({ autoUpdateEnabled: e.target.checked });
  });
}

function renderLocalizationPage(root) {
  const ds = state.deepLocalization;
  const scan = state.pendingScanResult;
  const isBusyApply = Boolean(state.busy.asarApply);
  const isBusySync = Boolean(state.busy.asarSync);
  const isBusyScan = Boolean(state.busy.asarScan);

  const patchPill = ds?.isPatched
    ? `<span class="pill pill-green">${escapeHtml(t('localization.asar_patched', null, '已启用深度汉化'))}</span>${ds.needsReapply ? ` <span class="pill pill-amber">${escapeHtml(t('localization.needs_reapply', null, '（有更新可重新应用）'))}</span>` : ''}`
    : `<span class="pill">${escapeHtml(t('localization.asar_official', null, '官方纯净原版'))}</span>`;

  const guardText = ds?.conflictGuardActive
    ? t('localization.guard_active', null, '已自动接管 · GravityBox 仅运行 HUD 增强，不重复改写界面')
    : t('localization.guard_standby', null, '未检测到 ASAR 汉化 · 点击下方一键安装即可全面接管');

  const sourceLabel = ds?.zhPackSource === 'remote-synced'
    ? t('localization.pack_source_remote', null, '云端同步版本')
    : t('localization.pack_source_bundled', null, '内置离线基线');

  root.innerHTML = `
    <div class="page-header">
      <div>
        <h1 class="page-title">${escapeHtml(t('localization.title', null, 'Antigravity 深度汉化'))}</h1>
        <div class="muted small" style="margin-top:4px">${escapeHtml(t('localization.subtitle', null, '由你的自有汉化引擎与白名单词库全权接管，自动避让 GravityBox 重复注入'))}</div>
      </div>
    </div>

    <div class="section-label">${escapeHtml(t('localization.section.status', null, '当前汉化与防冲突状态'))}</div>
    <div class="card">
      <div class="setting-row">
        <span style="font-weight:600">${escapeHtml(t('localization.app_version', null, '客户端版本'))}</span>
        <span class="small mono">${escapeHtml(ds?.appFound ? `Antigravity v${ds.appVersion || 'unknown'}` : t('common.unavailable', null, '未检测到安装目录'))}</span>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <span style="font-weight:600">${escapeHtml(t('localization.asar_status', null, 'ASAR 补丁状态'))}</span>
        <div>${ds ? patchPill : `<span class="muted small">加载中…</span>`}</div>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <span style="font-weight:600">${escapeHtml(t('localization.backup_status', null, '官方原版备份'))}</span>
        <span class="small">${escapeHtml(ds?.hasBackup ? t('localization.backup_ready', null, '已安全备份 (app.asar.bak)') : t('localization.backup_missing', null, '尚未创建（应用时自动备份）'))}</span>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row">
        <div style="min-width:0">
          <div style="font-weight:600">${escapeHtml(t('localization.guard_title', null, '重复冲突防护'))}</div>
          <div class="setting-sub">${escapeHtml(guardText)}</div>
        </div>
      </div>
      <div class="row-divider"></div>
      <div class="setting-row" style="justify-content:flex-end;gap:10px">
        ${ds?.hasBackup ? `<button class="btn btn-sm" id="btn-asar-restore" ${isBusyApply ? 'disabled' : ''}>${escapeHtml(t('localization.btn.restore', null, '恢复官方原版'))}</button>` : ''}
        <button class="btn btn-primary btn-sm" id="btn-asar-apply" ${isBusyApply || !ds?.appFound ? 'disabled' : ''}>
          ${escapeHtml(isBusyApply ? t('localization.btn.applying', null, '正在校验并注入…') : t('localization.btn.apply', null, '一键应用深度汉化并热生效'))}
        </button>
      </div>
    </div>

    <div class="section-label">${escapeHtml(t('localization.section.cloud', null, '云端词库同步（途径 A 上游）'))}</div>
    <div class="card">
      <div class="setting-row">
        <div style="min-width:0">
          <div style="font-weight:600">${escapeHtml(ds ? `${sourceLabel} · v${ds.zhPackVersion} (${formatNumber(ds.zhPackEntriesCount)} 条)` : '—')}</div>
          <div class="setting-sub mono xs">${escapeHtml(ds?.zhPackUpdatedAt ? `更新时间: ${formatTimestampShort(ds.zhPackUpdatedAt)} · 源: KAIKAIKAISER/antigravity-zh-asar` : 'KAIKAIKAISER/antigravity-zh-asar')}</div>
        </div>
        <button class="btn btn-sm" id="btn-asar-sync" ${isBusySync ? 'disabled' : ''}>
          ${escapeHtml(isBusySync ? t('localization.btn.syncing', null, '正在同步…') : t('localization.btn.sync_remote', null, '从 GitHub 同步最新汉化包'))}
        </button>
      </div>
    </div>

    <div class="section-label">${escapeHtml(t('localization.section.pending', null, '新版本文本排查（途径 A 采集）'))}</div>
    <div class="card">
      <div class="setting-row">
        <div style="min-width:0;padding-right:12px">
          <div style="font-weight:600">自动差分扫描新版本未译英文</div>
          <div class="setting-sub">${escapeHtml(t('localization.pending_desc', null, 'Antigravity 自动更新后，可一键扫描前端 main.js、app.asar 与内置插件中尚未覆盖的英文 UI 文本，复制发给 Antigravity 对话即可翻译发布。'))}</div>
        </div>
        <button class="btn btn-sm" id="btn-asar-scan" ${isBusyScan ? 'disabled' : ''} style="flex-shrink:0">
          ${escapeHtml(isBusyScan ? t('localization.btn.scanning', null, '正在扫描…') : t('localization.btn.scan', null, '扫描当前版本新增文本'))}
        </button>
      </div>
      ${scan ? `
        <div class="row-divider"></div>
        <div style="padding:12px 16px">
          <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;gap:8px;flex-wrap:wrap">
            <span class="small" style="font-weight:600">v${escapeHtml(scan.appVersion)} 发现 ${scan.pendingCount} 条新增未译候选（已扫 ${escapeHtml((scan.scannedSources || []).join(' / '))}）</span>
            <button class="btn btn-primary btn-sm" id="btn-asar-copy-prompt">${escapeHtml(t('localization.btn.copy_prompt', null, '复制待译提示词给 AI'))}</button>
          </div>
          ${scan.pendingFilePath ? `<div class="muted xs mono truncate" style="margin-bottom:8px">导出文件: ${escapeHtml(scan.pendingFilePath)}</div>` : ''}
          ${scan.pendingCount > 0 ? `
            <div style="max-height:180px;overflow-y:auto;background:var(--bg-subtle, rgba(0,0,0,0.04));border-radius:6px;padding:8px 10px;font-size:12px;line-height:1.6">
              ${scan.pending.slice(0, 40).map(item => `<div class="mono truncate">• ${escapeHtml(item)}</div>`).join('')}
              ${scan.pendingCount > 40 ? `<div class="muted xs" style="margin-top:4px">… 其余 ${scan.pendingCount - 40} 条请复制提示词或查看导出 JSON</div>` : ''}
            </div>
          ` : `<div class="muted small">当前词库已完整覆盖扫描到的全部 UI 文案！</div>`}
        </div>
      ` : ''}
    </div>
  `;

  document.getElementById('btn-asar-apply')?.addEventListener('click', async () => {
    if (state.busy.asarApply) return;
    state.busy.asarApply = true;
    renderCurrentPage();
    try {
      const res = await window.gravitybox.rpc('asar_zh_apply');
      if (res?.deepStatus) state.deepLocalization = res.deepStatus;
      if (res?.status) state.statusPayload = { ...(state.statusPayload || {}), status: res.status };
      renderSidebar();
      toast(res?.result?.message || res?.error || '应用完成', !res?.ok);
    } catch (err) {
      toast(String(err?.message || err), true);
    } finally {
      state.busy.asarApply = false;
      renderCurrentPage();
    }
  });

  document.getElementById('btn-asar-restore')?.addEventListener('click', async () => {
    if (state.busy.asarApply) return;
    state.busy.asarApply = true;
    renderCurrentPage();
    try {
      const res = await window.gravitybox.rpc('asar_zh_restore');
      if (res?.deepStatus) state.deepLocalization = res.deepStatus;
      if (res?.status) state.statusPayload = { ...(state.statusPayload || {}), status: res.status };
      renderSidebar();
      toast(res?.message || res?.error || '操作完成', !res?.ok);
    } catch (err) {
      toast(String(err?.message || err), true);
    } finally {
      state.busy.asarApply = false;
      renderCurrentPage();
    }
  });

  document.getElementById('btn-asar-sync')?.addEventListener('click', async () => {
    if (state.busy.asarSync) return;
    state.busy.asarSync = true;
    renderCurrentPage();
    try {
      const res = await window.gravitybox.rpc('asar_zh_sync_remote');
      if (res?.deepStatus) state.deepLocalization = res.deepStatus;
      toast(res?.message || res?.error || '同步完成', !res?.ok);
    } catch (err) {
      toast(String(err?.message || err), true);
    } finally {
      state.busy.asarSync = false;
      renderCurrentPage();
    }
  });

  document.getElementById('btn-asar-scan')?.addEventListener('click', async () => {
    if (state.busy.asarScan) return;
    state.busy.asarScan = true;
    renderCurrentPage();
    try {
      const res = await window.gravitybox.rpc('asar_zh_scan_pending');
      if (res?.ok) {
        state.pendingScanResult = res;
        toast(`扫描完成：发现 ${res.pendingCount} 条新增未译候选`);
      } else {
        toast(res?.error || '扫描失败', true);
      }
    } catch (err) {
      toast(String(err?.message || err), true);
    } finally {
      state.busy.asarScan = false;
      renderCurrentPage();
    }
  });

  document.getElementById('btn-asar-copy-prompt')?.addEventListener('click', async () => {
    if (!state.pendingScanResult?.promptText) return;
    await window.gravitybox.copyText(state.pendingScanResult.promptText);
    toast('已复制带白名单规范的待译提示词，可直接粘贴到 Antigravity 对话');
  });
}

function renderCurrentPage() {
  const root = document.getElementById('page-root');
  if (!root) return;
  if (state.activeTab === 'overview') renderOverviewPage(root);
  else if (state.activeTab === 'accounts') renderAccountsPage(root);
  else if (state.activeTab === 'usage') renderUsagePage(root);
  else if (state.activeTab === 'localization') renderLocalizationPage(root);
  else if (state.activeTab === 'settings') renderSettingsPage(root);
  else if (state.activeTab === 'about') renderAboutPage(root);
}

async function loadDashboard() {
  const res = await window.gravitybox.rpc('dashboard_summary');
  if (res?.ok) {
    state.dashboard = res;
    if (state.activeTab === 'overview') renderCurrentPage();
  }
}

async function loadAccounts() {
  const [listRes, cfgRes, recRes] = await Promise.all([
    window.gravitybox.rpc('account_list'),
    window.gravitybox.rpc('auto_switch_get'),
    window.gravitybox.rpc('auto_switch_best'),
  ]);
  if (listRes?.ok) state.accountsPayload = listRes;
  if (cfgRes?.ok) state.autoSwitchConfig = cfgRes.config;
  if (recRes?.ok) state.recommendation = recRes;
  if (state.activeTab === 'accounts') renderCurrentPage();
}

async function loadUsage(force = false) {
  const [usageRes, listRes] = await Promise.all([
    window.gravitybox.rpc('usage_summary', {
      period: state.usagePeriod,
      accountId: state.usageAccountId === 'all' ? undefined : state.usageAccountId,
      force,
    }),
    state.accountsPayload ? Promise.resolve(state.accountsPayload) : window.gravitybox.rpc('account_list'),
  ]);
  if (listRes?.ok) state.accountsPayload = listRes;
  if (usageRes?.ok) {
    state.usageReport = usageRes;
    if (state.activeTab === 'usage') renderCurrentPage();
  }
}

async function loadMaintenanceSummary() {
  const res = await window.gravitybox.rpc('maintenance_scan', { retentionDays: 7 });
  if (res && !res.error) {
    state.maintenanceSummary = {
      safeBytes: Number(res.safeReclaimableBytes ?? res.reclaimableSafeBytes ?? 0),
      historyBytes: Number(res.historySlimmingBytes ?? res.reclaimableHistoryBytes ?? 0),
    };
    if (state.activeTab === 'settings') renderCurrentPage();
  }
}

async function loadDeepLocalization() {
  const res = await window.gravitybox.rpc('asar_zh_status');
  if (res?.ok && res.status) {
    state.deepLocalization = res.status;
    if (state.activeTab === 'localization') renderCurrentPage();
  }
}

async function refreshActiveTabData() {
  if (state.activeTab === 'overview') await loadDashboard();
  else if (state.activeTab === 'accounts') await loadAccounts();
  else if (state.activeTab === 'usage') await loadUsage(false);
  else if (state.activeTab === 'localization') await loadDeepLocalization();
  else if (state.activeTab === 'settings') await loadMaintenanceSummary();
}

async function bootstrap() {
  const initial = await window.gravitybox.getState();
  state.i18nPacks = initial.i18nPacks || {};
  state.config = initial.config || {};
  state.activeLocale = initial.activeLocale || 'zh-Hans';
  state.systemLocale = initial.systemLocale || 'zh-CN';
  state.appInfo = initial.appInfo || {};
  state.statusPayload = initial.status || null;
  state.updateState = initial.updateState || null;
  if (initial.initialTab && NAV_ITEMS.some(n => n.id === initial.initialTab)) {
    state.activeTab = initial.initialTab;
  }

  renderSidebar();
  renderCurrentPage();

  document.getElementById('btn-open-antigravity')?.addEventListener('click', () => {
    void window.gravitybox.openAntigravity();
  });

  window.gravitybox.onStatus(payload => {
    state.statusPayload = payload;
    renderSidebar();
    if (state.activeTab === 'overview' || state.activeTab === 'accounts') {
      const hasBanner = Boolean(document.getElementById('btn-safe-relaunch'));
      const needsBanner = payload?.status?.mode === 'debug-port-missing';
      if (hasBanner !== needsBanner) renderCurrentPage();
    }
  });
  window.gravitybox.onConfig(cfg => {
    state.config = cfg;
  });
  window.gravitybox.onUpdate(u => {
    state.updateState = u;
    if (state.activeTab === 'about') renderCurrentPage();
  });
  window.gravitybox.onNavigate(tab => {
    if (tab && NAV_ITEMS.some(n => n.id === tab)) {
      state.activeTab = tab;
      renderSidebar();
      renderCurrentPage();
      void refreshActiveTabData();
    }
  });

  await refreshActiveTabData();
  setInterval(() => {
    if (!document.hidden) void refreshActiveTabData();
  }, 15000);
}

void bootstrap();
