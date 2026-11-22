import Cocoa
import ServiceManagement

final class PreferencesController: NSObject {
    static let refreshIntervals = [0, 5, 10, 15, 30, 60]

    unowned let app: Assistant
    var view: NSView!
    let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var languageSubtitleField: NSTextField?
    let hudSwitch = DesignSwitch()
    let pricingSyncSwitch = DesignSwitch()
    var pricingSyncCheckBtn: InlineRefreshButton!
    let refresh = NSPopUpButton(frame: .zero, pullsDown: false)
    let login = DesignSwitch()
    let syncLifecycleSwitch = DesignSwitch()
    let storageBadge = pillBadge("", color: Design.blue)
    static var defaultStorageSubtitle: String {
        L10n.t("settings.storage.default_subtitle", fallback: "清理无损缓存与历史日志，保留核心数据")
    }
    let storageSubtitleLabel = text(PreferencesController.defaultStorageSubtitle, size: 11, color: Design.secondary, wrap: true)
    var manageCacheBtn: NSButton!
    var pricingSheet: PricingSyncSheetController?
    private var lastStorageScanAt: Date = .distantPast
    private var storageScanInFlight = false

    init(app: Assistant) {
        self.app = app
        super.init()
        rebuildLanguagePopup()
        languagePopup.isEnabled = app.statusValue.mode != "unsupported"
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.setAccessibilityLabel(L10n.t("settings.language.title", fallback: "显示语言"))
        languagePopup.translatesAutoresizingMaskIntoConstraints = false

        hudSwitch.controlSize = .small
        hudSwitch.state = app.effectiveHudEnabled() ? .on : .off
        hudSwitch.isEnabled = app.reachable && app.statusValue.mode != "unsupported"
        hudSwitch.target = self; hudSwitch.action = #selector(toggleHud); hudSwitch.setAccessibilityLabel(L10n.t("settings.hud.title", fallback: "对话状态栏"))

        login.controlSize = .small
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self; login.action = #selector(toggleLogin); login.setAccessibilityLabel(L10n.t("settings.login.title", fallback: "登录时启动"))

        syncLifecycleSwitch.controlSize = .small
        syncLifecycleSwitch.state = app.configuration.value.syncAntigravityLifecycle ? .on : .off
        syncLifecycleSwitch.target = self; syncLifecycleSwitch.action = #selector(toggleSyncLifecycle)
        syncLifecycleSwitch.setAccessibilityLabel(L10n.t("settings.sync_lifecycle.title", fallback: "跟随 Antigravity 启停"))

        refresh.addItems(withTitles: [
            L10n.t("settings.refresh.manual", fallback: "手动刷新"),
            L10n.t("settings.refresh.5m", fallback: "每 5 分钟"),
            L10n.t("settings.refresh.10m", fallback: "每 10 分钟"),
            L10n.t("settings.refresh.15m", fallback: "每 15 分钟"),
            L10n.t("settings.refresh.30m", fallback: "每 30 分钟"),
            L10n.t("settings.refresh.60m", fallback: "每 60 分钟")
        ])
        refresh.selectItem(at: Self.refreshIntervals.firstIndex(of: app.configuration.value.quotaRefreshMinutes) ?? 0)
        refresh.target = self; refresh.action = #selector(refreshChanged); refresh.setAccessibilityLabel(L10n.t("settings.refresh.title", fallback: "配额刷新间隔"))
        refresh.translatesAutoresizingMaskIntoConstraints = false

        pricingSyncSwitch.controlSize = .small
        pricingSyncSwitch.state = app.configuration.value.autoPricingSyncEnabled ? .on : .off
        pricingSyncSwitch.target = self; pricingSyncSwitch.action = #selector(togglePricingSync)
        pricingSyncSwitch.setAccessibilityLabel(L10n.t("settings.pricing_sync.title", fallback: "自动更新价格基准"))
        pricingSyncCheckBtn = InlineRefreshButton(L10n.t("settings.pricing_sync.check_now", fallback: "立即检查"), width: 104, target: self, action: #selector(checkPricingSync))
        pricingSyncCheckBtn.setAccessibilityLabel(L10n.t("settings.pricing_sync.check_a11y", fallback: "检查价格更新"))
        let pricingControlGroup = horizontal([pricingSyncCheckBtn, pricingSyncSwitch], spacing: 8)
        pricingControlGroup.alignment = .centerY

        let languageRow = settingRow(icon: "globe", tint: .systemGreen, title: L10n.t("settings.language.title", fallback: "显示语言"), subtitle: languageSubtitleText(), control: languagePopup)
        if let rowStack = languageRow as? NSStackView,
           let captionsStack = rowStack.arrangedSubviews.dropFirst().first as? NSStackView,
           let subField = captionsStack.arrangedSubviews.dropFirst().first as? NSTextField {
            languageSubtitleField = subField
        }
        let enhanceGroup = vertical([
            languageRow,
            divider(),
            settingRow(icon: "chart.bar.xaxis", tint: .systemIndigo, title: L10n.t("settings.hud.title", fallback: "对话状态栏"), subtitle: L10n.t("settings.hud.subtitle", fallback: "在 Antigravity 输入框下方显示轮次、Token 与上下文"), control: hudSwitch)
        ], spacing: 12)
        for child in enhanceGroup.arrangedSubviews { fillWidth(child, in: enhanceGroup) }

        let dataSyncGroup = vertical([
            settingRow(icon: "arrow.clockwise", tint: Design.blue, title: L10n.t("settings.refresh.title", fallback: "配额刷新间隔"), subtitle: L10n.t("settings.refresh.subtitle", fallback: "定时更新已保存账号的剩余配额"), control: refresh),
            divider(),
            settingRow(icon: "dollarsign.circle", tint: Design.blue, title: L10n.t("settings.pricing_sync.title", fallback: "自动更新价格基准"), subtitle: L10n.t("settings.pricing_sync.subtitle", fallback: "自动同步公开模型费率，每 24 小时检查一次"), control: pricingControlGroup)
        ], spacing: 12)
        for child in dataSyncGroup.arrangedSubviews { fillWidth(child, in: dataSyncGroup) }

        storageBadge.isHidden = true
        storageBadge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        manageCacheBtn = button(L10n.t("settings.storage.manage_btn", fallback: "管理存储…"), target: self, action: #selector(showMaintenanceSheet))
        let storageRow = settingRow(
            icon: "internaldrive",
            tint: .systemOrange,
            title: L10n.t("settings.storage.title", fallback: "存储与维护"),
            badge: storageBadge,
            subtitle: "",
            control: manageCacheBtn
        )
        storageSubtitleLabel.maximumNumberOfLines = 1
        storageSubtitleLabel.lineBreakMode = .byTruncatingTail
        storageSubtitleLabel.toolTip = nil
        if let rowStack = storageRow as? NSStackView,
           let captionsStack = rowStack.arrangedSubviews.dropFirst().first as? NSStackView {
            captionsStack.addArrangedSubview(storageSubtitleLabel)
        }
        let systemAndStorageGroup = vertical([
            settingRow(icon: "power", tint: .systemGray, title: L10n.t("settings.login.title", fallback: "登录时启动"), subtitle: L10n.t("settings.login.subtitle", fallback: "登录 macOS 时自动在菜单栏驻留"), control: login),
            divider(),
            settingRow(icon: "link", tint: .systemTeal, title: L10n.t("settings.sync_lifecycle.title", fallback: "跟随 Antigravity 启停"), subtitle: L10n.t("settings.sync_lifecycle.subtitle", fallback: "随 Antigravity 自动启动并同步退出"), control: syncLifecycleSwitch),
            divider(),
            storageRow
        ], spacing: 12)
        for child in systemAndStorageGroup.arrangedSubviews { fillWidth(child, in: systemAndStorageGroup) }

        let enhanceCard = group([enhanceGroup], inset: 16)
        enhanceCard.cornerRadius = Design.Radius.card
        let dataSyncCard = group([dataSyncGroup], inset: 16)
        dataSyncCard.cornerRadius = Design.Radius.card
        let systemAndStorageCard = group([systemAndStorageGroup], inset: 16)
        systemAndStorageCard.cornerRadius = Design.Radius.card

        func sectionGroup(_ title: String, card: NSView) -> NSStackView {
            let hdr = text(title, size: 11.5, weight: .semibold, color: Design.secondary)
            let grp = vertical([hdr, card], spacing: 6)
            fillWidth(hdr, in: grp)
            fillWidth(card, in: grp)
            return grp
        }

        let root = pageStack(title: L10n.t("settings.title", fallback: "设置"))
        root.spacing = 14
        root.addArrangedSubview(sectionGroup(L10n.t("settings.section.enhance", fallback: "Antigravity 增强"), card: enhanceCard))
        root.addArrangedSubview(sectionGroup(L10n.t("settings.section.quota_pricing", fallback: "配额与计价"), card: dataSyncCard))
        root.addArrangedSubview(sectionGroup(L10n.t("settings.section.system_storage", fallback: "系统与存储"), card: systemAndStorageCard))
        view = scrollPage(root); Design.applyControls(view)
    }

    var maintenanceSheet: MaintenanceSheetController?

    @objc func showMaintenanceSheet() {
        guard let window = app.window else { return }
        if let active = window.activeSheetWindow, active !== maintenanceSheet?.sheet { return }
        if maintenanceSheet == nil {
            maintenanceSheet = MaintenanceSheetController(app: app)
        }
        maintenanceSheet?.show(in: window) { [weak self, weak app = self.app] in
            self?.maintenanceSheet = nil
            if let app, app.pendingLocalizedRebuildAfterMaintenance, self?.pricingSheet == nil, app.cachePage?.busy != true {
                app.pendingLocalizedRebuildAfterMaintenance = false
                app.cachePage = nil
                app.preferencesController = nil
                if app.currentPage == 3 {
                    app.navigate(3, force: true)
                }
                return
            }
            app?.preferencesController?.refreshStorageRowState(force: true)
        }
    }

    func applyStorageScanPayload(_ value: [String: Any]) {
        let now = Date()
        lastStorageScanAt = now
        app.lastMaintenanceScanPayload = value
        app.lastMaintenanceScanAt = now
        let buckets = value["buckets"] as? [String: Any]
        let rtBucket = buckets?["runtimeCache"] as? [String: Any] ?? [:]
        let histBucket = buckets?["historyLogs"] as? [String: Any] ?? [:]
        let safeBytes = Int64(intVal(rtBucket, "clearableBytes", fallback: intVal(value, "safeBytes")))
        let statefulBytes = Int64(intVal(histBucket, "clearableBytes", fallback: intVal(value, "statefulBytes")))
        if safeBytes >= 10 * 1024 * 1024 {
            let formatted = ByteCountFormatter.string(fromByteCount: safeBytes, countStyle: .file)
            storageBadge.title = L10n.t("settings.storage.reclaimable", ["size": formatted], fallback: "可释放 \(formatted)")
            storageBadge.tint = Design.blue
            storageBadge.isHidden = false
        } else if statefulBytes >= 50 * 1024 * 1024 {
            let formatted = ByteCountFormatter.string(fromByteCount: statefulBytes, countStyle: .file)
            storageBadge.title = L10n.t("settings.storage.slimmable", ["size": formatted], fallback: "可瘦身 \(formatted)")
            storageBadge.tint = Design.secondary
            storageBadge.isHidden = false
        } else if safeBytes + statefulBytes > 0 {
            storageBadge.title = L10n.t("settings.storage.healthy", fallback: "状态良好")
            storageBadge.tint = Design.secondary
            storageBadge.isHidden = false
        } else {
            storageBadge.isHidden = true
        }
        if safeBytes > 0 && statefulBytes > 0 {
            let safeStr = ByteCountFormatter.string(fromByteCount: safeBytes, countStyle: .file)
            let statefulStr = ByteCountFormatter.string(fromByteCount: statefulBytes, countStyle: .file)
            storageSubtitleLabel.stringValue = L10n.t("settings.storage.detail_subtitle", ["safe": safeStr, "stateful": statefulStr], fallback: "运行缓存 \(safeStr)，另有 \(statefulStr) 后台日志可按需释放")
        } else {
            storageSubtitleLabel.stringValue = Self.defaultStorageSubtitle
        }
        storageSubtitleLabel.toolTip = nil
    }

    func refreshStorageRowState(force: Bool = false) {
        guard app.reachable else { return }
        guard !storageScanInFlight else { return }
        if !force && Date().timeIntervalSince(lastStorageScanAt) < 60.0 {
            return
        }
        storageScanInFlight = true
        let retentionDays = app.cachePage?.selectedRetentionDays ?? 7
        app.bridge.send(["command": "maintenance_scan", "retentionDays": retentionDays]) { [weak self] result in
            guard let self else { return }
            self.storageScanInFlight = false
            if case .success(let value) = result {
                self.applyStorageScanPayload(value)
            }
        }
    }

    private func languageSubtitleText() -> String {
        L10n.t("settings.language.subtitle", fallback: "同时决定 GravityBox 与 Antigravity 的界面语言，不改动官方应用")
    }

    private var renderedLanguagePopupKey = ""

    private func rebuildLanguagePopup() {
        let configured = app.effectiveConfiguredLanguage()
        let localesKey = ([L10n.shared.currentLocale] + L10n.shared.supportedLocales.map(\.code)).joined(separator: "|")
        if renderedLanguagePopupKey != localesKey {
            renderedLanguagePopupKey = localesKey
            languagePopup.removeAllItems()
            let systemTitle = L10n.t("language.system", fallback: "跟随系统")
            languagePopup.addItem(withTitle: systemTitle)
            languagePopup.lastItem?.representedObject = "system"
            languagePopup.menu?.addItem(.separator())
            for meta in L10n.shared.supportedLocales {
                languagePopup.addItem(withTitle: meta.nativeName)
                languagePopup.lastItem?.representedObject = meta.code
            }
            if languagePopup.cell is DesignPopUpCell {
                Design.syncPopUpWidth(languagePopup)
            } else {
                languagePopup.invalidateIntrinsicContentSize()
            }
        }
        if let idx = languagePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == configured }) {
            if languagePopup.indexOfSelectedItem != idx { languagePopup.selectItem(at: idx) }
        } else if let idx = languagePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == L10n.shared.currentLocale }) {
            if languagePopup.indexOfSelectedItem != idx { languagePopup.selectItem(at: idx) }
        } else if languagePopup.indexOfSelectedItem != 0 {
            languagePopup.selectItem(at: 0)
        }
    }

    func update() {
        rebuildLanguagePopup()
        languageSubtitleField?.stringValue = languageSubtitleText()
        languagePopup.setAccessibilityLabel(L10n.t("settings.language.title", fallback: "显示语言"))
        languagePopup.isEnabled = app.statusValue.mode != "unsupported"
        hudSwitch.state = app.effectiveHudEnabled() ? .on : .off
        hudSwitch.isEnabled = app.reachable && app.statusValue.mode != "unsupported"
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        syncLifecycleSwitch.state = app.configuration.value.syncAntigravityLifecycle ? .on : .off
        let refreshTitles = [
            L10n.t("settings.refresh.manual", fallback: "手动刷新"),
            L10n.t("settings.refresh.5m", fallback: "每 5 分钟"),
            L10n.t("settings.refresh.10m", fallback: "每 10 分钟"),
            L10n.t("settings.refresh.15m", fallback: "每 15 分钟"),
            L10n.t("settings.refresh.30m", fallback: "每 30 分钟"),
            L10n.t("settings.refresh.60m", fallback: "每 60 分钟")
        ]
        for (idx, itemTitle) in refreshTitles.enumerated() where idx < refresh.numberOfItems {
            refresh.item(at: idx)?.title = itemTitle
        }
        refresh.selectItem(at: Self.refreshIntervals.firstIndex(of: app.configuration.value.quotaRefreshMinutes) ?? 0)
        if refresh.cell is DesignPopUpCell {
            Design.syncPopUpWidth(refresh)
        } else {
            refresh.invalidateIntrinsicContentSize()
        }
        manageCacheBtn?.title = L10n.t("settings.storage.manage_btn", fallback: "管理存储…")
        if let cachedScan = app.lastMaintenanceScanPayload {
            applyStorageScanPayload(cachedScan)
        } else {
            storageSubtitleLabel.stringValue = Self.defaultStorageSubtitle
        }
        refreshStorageRowState()
        pricingSyncSwitch.state = app.configuration.value.autoPricingSyncEnabled ? .on : .off
        pricingSyncSwitch.isEnabled = app.reachable
        if let checkBtn = pricingSyncCheckBtn {
            checkBtn.title = L10n.t("settings.pricing_sync.check_now", fallback: "立即检查")
            checkBtn.invalidateIntrinsicContentSize()
            checkBtn.setAccessibilityLabel(L10n.t("settings.pricing_sync.check_a11y", fallback: "检查价格更新"))
            checkBtn.setBusy(checkBtn.isBusy, available: app.reachable)
        }
    }

    @objc func languageChanged() {
        guard let selected = languagePopup.selectedItem?.representedObject as? String else { return }
        DispatchQueue.main.async { [weak self] in
            self?.app.setGlobalLanguage(selected)
        }
    }

    @objc func togglePricingSync() {
        let enabled = pricingSyncSwitch.state == .on
        pricingSyncSwitch.isEnabled = false
        app.bridge.send(["command": "pricing_sync_set", "enabled": enabled]) { [weak self] result in
            guard let self else { return }
            self.pricingSyncSwitch.isEnabled = true
            if case .success = result {
                self.app.configuration.value.autoPricingSyncEnabled = enabled
                try? self.app.configuration.save()
            } else {
                self.pricingSyncSwitch.state = self.app.configuration.value.autoPricingSyncEnabled ? .on : .off
                self.app.showMessage(L10n.t("settings.pricing_sync.update_failed", fallback: "未能更新自动价格同步设置"), error: true)
            }
        }
    }

    @objc func checkPricingSync() {
        guard pricingSyncCheckBtn?.isBusy != true else { return }
        pricingSyncCheckBtn?.setBusy(true, available: true)
        app.bridge.send(["command": "pricing_sync_check"]) { [weak self] result in
            guard let self else { return }
            self.pricingSyncCheckBtn?.setBusy(false, available: self.app.reachable)
            switch result {
            case .success(let payload):
                if payload["synced"] as? Bool == true {
                    self.app.invalidateUsageReportCache()
                    self.app.overview?.fetch()
                    self.app.usagePage?.fetch(force: true)
                }
                if let window = self.app.window, window.activeSheetWindow == nil || window.activeSheetWindow === self.pricingSheet?.sheet {
                    if self.pricingSheet == nil {
                        self.pricingSheet = PricingSyncSheetController(app: self.app)
                    }
                    self.pricingSheet?.show(in: window, payload: payload) { [weak self, weak app = self.app] in
                        self?.pricingSheet = nil
                        if let app, app.pendingLocalizedRebuildAfterMaintenance, self?.maintenanceSheet == nil, app.cachePage?.busy != true {
                            app.pendingLocalizedRebuildAfterMaintenance = false
                            app.cachePage = nil
                            app.preferencesController = nil
                            if app.currentPage == 3 {
                                app.navigate(3, force: true)
                            }
                        }
                    }
                } else {
                    let count = (payload["status"] as? [String: Any])?["modelCount"] as? Int
                        ?? ((payload["prices"] as? [String: Any])?.count ?? (payload["count"] as? Int ?? 0))
                    let ok = payload["synced"] as? Bool == true
                    let errStr = payload["error"] as? String ?? L10n.t("settings.pricing_sync.default_error", fallback: "未能同步远端价格")
                    self.app.showMessage(ok ? L10n.t("settings.pricing_sync.synced", ["count": count], fallback: "价格基准已同步（生效 \(count) 款模型）") : L10n.t("settings.pricing_sync.check_failed", ["error": errStr], fallback: "检查提示：\(errStr)"), error: !ok)
                }
            case .failure(let err):
                self.app.showMessage(L10n.t("settings.pricing_sync.sync_failed", ["error": err.localizedDescription], fallback: "同步失败：\(err.localizedDescription)"), error: true)
            }
        }
    }

    @objc func toggleHud() {
        let target = hudSwitch.state == .on
        app.setHudEnabled(target)
    }

    @objc func toggleSyncLifecycle() {
        let previous = app.configuration.value.syncAntigravityLifecycle
        let next = syncLifecycleSwitch.state == .on
        app.configuration.value.syncAntigravityLifecycle = next
        do {
            try app.configuration.save()
            app.syncLifecycleAgentRegistration()
        } catch {
            app.configuration.value.syncAntigravityLifecycle = previous
            syncLifecycleSwitch.state = previous ? .on : .off
            showError(error)
        }
    }

    @objc func refreshChanged() {
        let previous = app.configuration.value.quotaRefreshMinutes
        let idx = max(0, min(Self.refreshIntervals.count - 1, refresh.indexOfSelectedItem))
        app.configuration.value.quotaRefreshMinutes = Self.refreshIntervals[idx]
        do {
            try app.configuration.save()
            app.configureQuotaRefreshTimer()
            app.fetchAccountList(notifyPage: true)
            app.overview?.fetch()
            app.updateViews()
        }
        catch {
            app.configuration.value.quotaRefreshMinutes = previous
            refresh.selectItem(at: Self.refreshIntervals.firstIndex(of: previous) ?? 0)
            showError(error)
        }
    }

    @objc func toggleLogin() {
        do {
            if login.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            showError(error)
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func showError(_ error: Error) { app.showMessage(error.localizedDescription, error: true) }
}
