import Cocoa

final class AccountsPage: NSObject {
    unowned let app: Assistant
    let view: NSView

    let autoSwitchToggle = DesignSwitch()
    let autoSwitchBadgeBox = NSBox()
    let autoSwitchBadgeIcon = symbol("arrow.triangle.2.circlepath", size: 13.5, color: Design.blue)
    let autoSwitchStatusBadge = pillBadge(L10n.t("accounts.smart_switch.disabled"), color: Design.inactivePill)
    let policySubtitleLabel = text("", size: 11, color: Design.secondary)
    let configButton = button(L10n.t("accounts.smart_switch.config_btn"), target: nil, action: #selector(showPolicySettings))
    let toggleCollapseAllButton = button(L10n.t("accounts.collapse_all"), target: nil, action: #selector(toggleCollapseAllAccounts))
    let manageAccountsButton = button(L10n.t("accounts.manage_btn", fallback: "管理账号…"), target: nil, action: #selector(addAccount))
    let policyBox: NSBox
    let recommendationDivider = divider()
    let cardsStack = NSStackView()
    // B01: 页面顶部提示“N 个账号的分组沿用上次记录”（仅在没有挂载底部页脚的前提下提供轻量汇总）。
    private let staleGroupsSummary = text("", size: 11, color: .secondaryLabelColor, wrap: true)

    var accounts: [[String: Any]] = []
    var activeId = ""
    var recommendedAccountId: String? = nil
    var autoSwitchConfig: [String: Any] = [:]
    private(set) var collapsedAccountIds = Set<String>()
    private(set) var isAllCollapsedMode = false
    private var renderedFingerprint = ""
    private var recommendationFingerprint = ""
    private var accountReadError: String?
    private var policyInFlight = false
    // A05: per-account refresh feedback lives on the page (data source), not on a button instance:
    // cards are updated in place by id, and page-level state is applied to each mounted button.
    private var accountRefreshErrors: [String: String] = [:]
    // 失败时的配额时间戳：后续任一成功刷新（含“刷新全部”）更新了该账号配额后自动清掉旧错误。
    private var accountRefreshErrorStamps: [String: Int] = [:]
    // 当前挂载的卡片刷新按钮，用于把页面级状态贴到对应按钮上。
    private var refreshControlsById: [String: QuotaRefreshButton] = [:]

    private final class AccountCardViews {
        let id: String
        let cardBox: NSBox
        let titleLbl: NSTextField
        let tierPill: TierBadge
        let statusBadge: PillBadge
        let emailLbl: NSTextField
        let collapsedSummaryLabel: NSTextField
        let switchButton: NSButton
        let singleRefreshBtn: QuotaRefreshButton
        let actionsButton: NSButton
        let collapseButton: NSButton
        let actionStack: NSStackView
        let cardDivider: NSView
        let coreQuotaStack: NSStackView
        let standaloneQuotaStack: NSStackView
        let authWarningLabel: NSTextField
        let quotaWarningLabel: NSTextField
        let refreshErrorLabel: NSTextField
        let staleLabel: NSTextField
        let updateLabel: NSTextField

        init(
            id: String,
            cardBox: NSBox,
            titleLbl: NSTextField,
            tierPill: TierBadge,
            statusBadge: PillBadge,
            emailLbl: NSTextField,
            collapsedSummaryLabel: NSTextField,
            switchButton: NSButton,
            singleRefreshBtn: QuotaRefreshButton,
            actionsButton: NSButton,
            collapseButton: NSButton,
            actionStack: NSStackView,
            cardDivider: NSView,
            coreQuotaStack: NSStackView,
            standaloneQuotaStack: NSStackView,
            authWarningLabel: NSTextField,
            quotaWarningLabel: NSTextField,
            refreshErrorLabel: NSTextField,
            staleLabel: NSTextField,
            updateLabel: NSTextField
        ) {
            self.id = id
            self.cardBox = cardBox
            self.titleLbl = titleLbl
            self.tierPill = tierPill
            self.statusBadge = statusBadge
            self.emailLbl = emailLbl
            self.collapsedSummaryLabel = collapsedSummaryLabel
            self.switchButton = switchButton
            self.singleRefreshBtn = singleRefreshBtn
            self.actionsButton = actionsButton
            self.collapseButton = collapseButton
            self.actionStack = actionStack
            self.cardDivider = cardDivider
            self.coreQuotaStack = coreQuotaStack
            self.standaloneQuotaStack = standaloneQuotaStack
            self.authWarningLabel = authWarningLabel
            self.quotaWarningLabel = quotaWarningLabel
            self.refreshErrorLabel = refreshErrorLabel
            self.staleLabel = staleLabel
            self.updateLabel = updateLabel
        }
    }
    private var cardViewsById: [String: AccountCardViews] = [:]


    // B12: 待生效与回滚横幅
    let pendingRecoveryBox: NSBox
    let pendingTextLabel = text(L10n.t("accounts.pending_recovery"), size: 12, color: .labelColor)
    let rollbackButton = button(L10n.t("accounts.rollback_btn"), target: nil, action: #selector(rollbackSwitch))
    var hasPendingSwitch: Bool = false

    // B10 & U15: 推荐候选提示条
    let recommendationRow = horizontal([], spacing: 10)
    let recommendationLabel = text("", size: 12, color: .secondaryLabelColor, wrap: true)
    let switchRecommendedBtn = button(L10n.t("accounts.switch_recommended_btn"), target: nil, action: #selector(switchRecommendedAccount))

    private static let dateFormatter: DateFormatter = InterfaceText.shortDateTimeFormatter

    init(app: Assistant) {
        self.app = app
        self.isAllCollapsedMode = app.configuration?.value.accountsCollapsed ?? false
        manageAccountsButton.title = L10n.t("accounts.manage_btn", fallback: "管理账号…")
        manageAccountsButton.bezelColor = .controlAccentColor
        let refreshQuotaBtn = QuotaRefreshButton(target: nil, action: #selector(refreshAllQuotas))

        toggleCollapseAllButton.image = NSImage(
            systemSymbolName: isAllCollapsedMode ? "chevron.down" : "chevron.up",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold))
        toggleCollapseAllButton.image?.isTemplate = true
        toggleCollapseAllButton.imagePosition = .imageLeading
        toggleCollapseAllButton.title = isAllCollapsedMode ? L10n.t("accounts.expand_all") : L10n.t("accounts.collapse_all")
        toggleCollapseAllButton.toolTip = nil
        toggleCollapseAllButton.setAccessibilityLabel(isAllCollapsedMode ? L10n.t("accounts.a11y.expand_all") : L10n.t("accounts.a11y.collapse_all"))

        let headerActions = horizontal([toggleCollapseAllButton, refreshQuotaBtn, manageAccountsButton], spacing: 8)
        headerActions.detachesHiddenViews = true
        let root = pageStack(title: L10n.t("accounts.title"), actions: headerActions)
        root.spacing = Design.Spacing.page

        // B12: 待生效横幅
        let pendingIcon = symbol("arrow.uturn.backward.circle.fill", size: 16, color: Design.blue)
        rollbackButton.controlSize = .small
        rollbackButton.bezelColor = .controlAccentColor
        rollbackButton.action = #selector(rollbackSwitch)
        let pendingContent = horizontal([pendingIcon, pendingTextLabel, flexibleSpace(), rollbackButton], spacing: 10)
        pendingContent.alignment = .centerY
        let pendingBox = group([pendingContent], inset: 10)
        pendingBox.cornerRadius = 10
        pendingBox.borderWidth = 1
        pendingBox.borderColor = Design.dynamicAlpha(Design.blue, 0.3)
        pendingBox.isHidden = true
        pendingRecoveryBox = pendingBox
        root.addArrangedSubview(pendingBox)

        // 1. 紧凑备用推荐设置卡片
        autoSwitchBadgeBox.boxType = .custom
        autoSwitchBadgeBox.cornerRadius = 7
        autoSwitchBadgeBox.borderWidth = 0.5
        autoSwitchBadgeBox.contentViewMargins = .zero
        autoSwitchBadgeBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            autoSwitchBadgeBox.widthAnchor.constraint(equalToConstant: 28),
            autoSwitchBadgeBox.heightAnchor.constraint(equalToConstant: 28)
        ])
        autoSwitchBadgeBox.setAccessibilityElement(false)
        autoSwitchBadgeIcon.translatesAutoresizingMaskIntoConstraints = false
        autoSwitchBadgeIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        autoSwitchBadgeBox.addSubview(autoSwitchBadgeIcon)
        NSLayoutConstraint.activate([
            autoSwitchBadgeIcon.centerXAnchor.constraint(equalTo: autoSwitchBadgeBox.centerXAnchor),
            autoSwitchBadgeIcon.centerYAnchor.constraint(equalTo: autoSwitchBadgeBox.centerYAnchor)
        ])

        let policyTitle = text(L10n.t("accounts.smart_switch.title"), size: 13, weight: .semibold)
        policyTitle.setContentCompressionResistancePriority(.required, for: .horizontal)
        policyTitle.setContentHuggingPriority(.required, for: .horizontal)
        autoSwitchStatusBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        autoSwitchStatusBadge.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = horizontal([policyTitle, autoSwitchStatusBadge], spacing: 6)
        titleRow.alignment = .centerY

        policySubtitleLabel.lineBreakMode = .byTruncatingTail
        policySubtitleLabel.maximumNumberOfLines = 1
        policySubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let typographyColumn = vertical([titleRow, policySubtitleLabel], spacing: 2)
        typographyColumn.alignment = .leading
        typographyColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        configButton.image?.isTemplate = true
        configButton.imagePosition = .imageLeading
        configButton.controlSize = .small
        configButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        configButton.translatesAutoresizingMaskIntoConstraints = false
        configButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        configButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        configButton.setContentHuggingPriority(.required, for: .horizontal)

        autoSwitchToggle.controlSize = .small
        autoSwitchToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        autoSwitchToggle.setContentHuggingPriority(.required, for: .horizontal)

        let rightControlGroup = horizontal([configButton, autoSwitchToggle], spacing: 8)
        rightControlGroup.alignment = .centerY
        rightControlGroup.setContentHuggingPriority(.required, for: .horizontal)
        rightControlGroup.setContentCompressionResistancePriority(.required, for: .horizontal)

        let policyRow = horizontal([autoSwitchBadgeBox, typographyColumn, flexibleSpace(), rightControlGroup], spacing: 10)
        policyRow.alignment = .centerY
        policyRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true

        // 推荐候选提示行
        recommendationDivider.isHidden = true
        recommendationRow.alignment = .centerY
        recommendationLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        recommendationLabel.textColor = Design.secondary
        recommendationLabel.maximumNumberOfLines = 1
        recommendationLabel.lineBreakMode = .byTruncatingTail
        recommendationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        switchRecommendedBtn.controlSize = .small
        switchRecommendedBtn.bezelColor = Design.blue
        switchRecommendedBtn.action = #selector(switchRecommendedAccount)
        switchRecommendedBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        let recIcon = symbol("gauge.with.needle", size: 13.5, color: Design.blue)
        recommendationRow.setViews([recIcon, recommendationLabel, flexibleSpace(), switchRecommendedBtn], in: .leading)
        recommendationRow.isHidden = true

        let policyContent = vertical([policyRow, recommendationDivider, recommendationRow], spacing: 8)
        policyContent.detachesHiddenViews = true
        fillWidth(policyRow, in: policyContent)
        fillWidth(recommendationDivider, in: policyContent)
        fillWidth(recommendationRow, in: policyContent)
        let box = group([policyContent], inset: 14)
        box.cornerRadius = Design.Radius.card
        box.fillColor = Design.card
        (box as? DesignCardBox)?.enablesHoverHighlight = true
        policyBox = box
        root.addArrangedSubview(policyBox)
        staleGroupsSummary.isHidden = true
        staleGroupsSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(staleGroupsSummary)

        // 2. 卡片式多账号列表 (取代生硬的 NSTableView)
        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 12
        root.addArrangedSubview(cardsStack)

        view = scrollPage(root)
        super.init()

        toggleCollapseAllButton.target = self
        manageAccountsButton.target = self
        refreshQuotaBtn.target = self
        rollbackButton.target = self
        switchRecommendedBtn.target = self
        configButton.target = self
        autoSwitchToggle.target = self
        updateAutoSwitchState()
        autoSwitchToggle.action = #selector(savePolicy)
        autoSwitchToggle.setAccessibilityLabel(L10n.t("accounts.smart_switch.a11y"))

        updateAutoSwitchState()
        if let boot = app.cachedAccountsBootstrapPayload {
            fetch(boot)
        } else if !app.cachedAccounts.isEmpty {
            fetch(["accounts": app.cachedAccounts, "activeId": app.activeAccountId, "pendingSwitch": false])
        }
        fetch()
        fetchPolicy()
    }

    private static func formatCollapsedQuotaSummary(_ contract: QuotaPresentation.Contract) -> String {
        let now = Date()
        var parts: [String] = []
        for group in contract.displayGroups {
            if let pct = group.primaryPercentage {
                let label = group.summaryLabel.isEmpty ? group.displayName : group.summaryLabel
                let hasStaleWindow = group.primaryWindow?.effectiveStale(at: now) == true || group.windows.contains(where: { $0.effectiveStale(at: now) })
                let staleSuffix = hasStaleWindow
                    ? " (\(L10n.t("quota.stale", fallback: "已过期")))"
                    : ""
                parts.append("\(label) \(pct)%\(staleSuffix)")
            }
        }
        guard !parts.isEmpty else { return L10n.t("accounts.collapsed_pending") }
        return "· " + parts.joined(separator: " · ")
    }

    private func syncCollapseHeaderButtonState() {
        let validIds = Set(accounts.compactMap { $0["id"] as? String }.filter { !$0.isEmpty })
        guard !validIds.isEmpty else {
            toggleCollapseAllButton.isHidden = true
            return
        }
        toggleCollapseAllButton.isHidden = false

        let allCollapsed = validIds.isSubset(of: collapsedAccountIds)
        isAllCollapsedMode = allCollapsed
        let title = allCollapsed ? L10n.t("accounts.expand_all") : L10n.t("accounts.collapse_all")
        let symbolName = allCollapsed ? "chevron.down" : "chevron.up"
        if toggleCollapseAllButton.title != title {
            toggleCollapseAllButton.title = title
        }
        toggleCollapseAllButton.setAccessibilityLabel(allCollapsed ? L10n.t("accounts.a11y.expand_all") : L10n.t("accounts.a11y.collapse_all"))
        toggleCollapseAllButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold))
        toggleCollapseAllButton.image?.isTemplate = true
        toggleCollapseAllButton.toolTip = nil
        toggleCollapseAllButton.invalidateIntrinsicContentSize()
    }

    @objc func toggleCollapseAllAccounts() {
        let validIds = Set(accounts.compactMap { $0["id"] as? String }.filter { !$0.isEmpty })
        guard !validIds.isEmpty else { return }
        let shouldCollapseAll = !validIds.isSubset(of: collapsedAccountIds)
        if shouldCollapseAll {
            collapsedAccountIds.formUnion(validIds)
        } else {
            collapsedAccountIds.removeAll()
        }
        isAllCollapsedMode = shouldCollapseAll
        if app.configuration != nil {
            app.configuration.value.accountsCollapsed = shouldCollapseAll
            try? app.configuration.save()
        }
        for item in accounts {
            let id = item["id"] as? String ?? ""
            if let card = cardViewsById[id] {
                updateAccountCardViews(card, item: item)
            }
        }
        syncCollapseHeaderButtonState()
        view.layoutSubtreeIfNeeded()
    }

    @objc func toggleSingleAccountCollapse(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        guard !id.isEmpty else { return }
        if collapsedAccountIds.contains(id) {
            collapsedAccountIds.remove(id)
        } else {
            collapsedAccountIds.insert(id)
        }
        let validIds = Set(accounts.compactMap { $0["id"] as? String }.filter { !$0.isEmpty })
        let allCollapsed = !validIds.isEmpty && validIds.isSubset(of: collapsedAccountIds)
        isAllCollapsedMode = allCollapsed
        if app.configuration != nil {
            app.configuration.value.accountsCollapsed = allCollapsed
            try? app.configuration.save()
        }
        if let item = accounts.first(where: { ($0["id"] as? String) == id }),
           let card = cardViewsById[id] {
            updateAccountCardViews(card, item: item)
        }
        syncCollapseHeaderButtonState()
        view.layoutSubtreeIfNeeded()
    }

    private func makeAccountCardViews(id: String, item: [String: Any]) -> AccountCardViews {
        let email = item["email"] as? String ?? L10n.t("accounts.unnamed")
        let name = item["name"] as? String ?? ""
        let tier = AccountIdentity.normalizeTier(item["subscription_tier"] as? String)

        let displayName = AccountIdentity.displayName(name: name, email: email)
        let titleLbl = text(displayName, size: 15, weight: .semibold, color: .labelColor)
        titleLbl.lineBreakMode = .byTruncatingTail
        titleLbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLbl.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)

        let tierPill = tierBadge(tier, scale: .regular)
        tierPill.setContentHuggingPriority(.required, for: .horizontal)
        tierPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        tierPill.isHidden = tier.isEmpty

        let statusBadge = pillBadge("", color: Design.blue)
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)
        statusBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusBadge.isHidden = true

        let titleSpacer = flexibleSpace()
        titleSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let statusBadges: [NSView] = [titleLbl, tierPill, statusBadge, titleSpacer]
        let titleRow = horizontal(statusBadges, spacing: 6)
        titleRow.alignment = .centerY
        titleRow.detachesHiddenViews = true

        let emailLbl = text(email, size: 11, color: .secondaryLabelColor)
        enableTextCopy(emailLbl, title: L10n.t("common.copy_full_email"))
        emailLbl.font = .systemFont(ofSize: 11.5, weight: .regular)
        emailLbl.lineBreakMode = .byTruncatingMiddle
        emailLbl.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(242), for: .horizontal)
        emailLbl.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let collapsedSummaryLabel = text("", size: 11, weight: .medium, color: Design.inactivePill)
        collapsedSummaryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        collapsedSummaryLabel.lineBreakMode = .byTruncatingTail
        collapsedSummaryLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(248), for: .horizontal)
        collapsedSummaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        collapsedSummaryLabel.isHidden = true

        let subRowViews: [NSView] = [emailLbl, collapsedSummaryLabel, flexibleSpace()]
        let subRow = horizontal(subRowViews, spacing: 5)
        subRow.alignment = .centerY
        subRow.detachesHiddenViews = true

        let nameAndEmail = vertical([titleRow, subRow], spacing: 3)
        nameAndEmail.alignment = .leading
        nameAndEmail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fillWidth(titleRow, in: nameAndEmail); fillWidth(subRow, in: nameAndEmail)

        let accountTitle = name.isEmpty ? email : "\(name) · \(email)"

        let swBtn = button(L10n.t("accounts.switch_btn"), target: self, action: #selector(switchCardAccountById(_:)))
        swBtn.identifier = NSUserInterfaceItemIdentifier(id)
        swBtn.controlSize = .small
        swBtn.bezelColor = nil
        swBtn.toolTip = nil
        swBtn.setAccessibilityLabel(L10n.t("accounts.a11y.switch_to", ["account": accountTitle]))
        swBtn.setContentHuggingPriority(.required, for: .horizontal)
        swBtn.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let singleRefreshBtn = QuotaRefreshButton(target: self, action: #selector(refreshSingleAccountById(_:)))
        singleRefreshBtn.identifier = NSUserInterfaceItemIdentifier(id)
        singleRefreshBtn.controlSize = .small
        singleRefreshBtn.toolTip = nil
        singleRefreshBtn.isHidden = true
        singleRefreshBtn.setAccessibilityLabel(L10n.t("accounts.a11y.refresh_quota", ["account": accountTitle]))
        singleRefreshBtn.setContentHuggingPriority(.required, for: .horizontal)
        singleRefreshBtn.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let actionsButton = button("", target: self, action: #selector(showAccountActions(_:)))
        (actionsButton as? DesignButton)?.isQuietAccessory = true
        actionsButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        actionsButton.image?.isTemplate = true
        actionsButton.identifier = NSUserInterfaceItemIdentifier(id)
        actionsButton.setAccessibilityLabel(L10n.t("accounts.a11y.actions", ["account": accountTitle]))

        let collapseButton = button("", target: self, action: #selector(toggleSingleAccountCollapse(_:)))
        (collapseButton as? DesignButton)?.isQuietAccessory = true
        collapseButton.identifier = NSUserInterfaceItemIdentifier(id)
        collapseButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        collapseButton.image?.isTemplate = true
        collapseButton.toolTip = nil
        collapseButton.setAccessibilityLabel(L10n.t("accounts.a11y.collapse_details", ["account": accountTitle]))

        let actionViews: [NSView] = [swBtn, singleRefreshBtn, actionsButton, collapseButton]
        let actionStack = horizontal(actionViews, spacing: 4)
        actionStack.alignment = .centerY
        actionStack.detachesHiddenViews = true
        actionStack.setHuggingPriority(.required, for: .horizontal)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = identityHeader(identity: nameAndEmail, actions: actionStack)

        let coreQuotaStack = NSStackView()
        coreQuotaStack.orientation = .vertical
        coreQuotaStack.alignment = .leading
        coreQuotaStack.spacing = 12
        coreQuotaStack.detachesHiddenViews = true

        let standaloneQuotaStack = NSStackView()
        standaloneQuotaStack.orientation = .vertical
        standaloneQuotaStack.alignment = .leading
        standaloneQuotaStack.spacing = 12
        standaloneQuotaStack.isHidden = true
        standaloneQuotaStack.detachesHiddenViews = true

        let authWarningLabel = text(L10n.t("accounts.auth_warning"), size: 11, color: accessibleWarningColor())
        authWarningLabel.isHidden = true
        let quotaWarningLabel = text(L10n.t("accounts.quota_not_updated"), size: 11, color: accessibleWarningColor(), wrap: true)
        quotaWarningLabel.isHidden = true
        let refreshErrorLabel = text("", size: 11.5, color: accessibleWarningColor(), wrap: true)
        refreshErrorLabel.isHidden = true
        let staleLabel = text("", size: 11, color: accessibleWarningColor(), wrap: true)
        staleLabel.isHidden = true
        let updateLabel = text("", size: 11, color: .secondaryLabelColor)
        updateLabel.isHidden = true

        let cardDivider = divider()
        let cardRows: [NSView] = [
            headerRow, cardDivider, coreQuotaStack, standaloneQuotaStack,
            authWarningLabel, quotaWarningLabel, refreshErrorLabel, staleLabel, updateLabel
        ]
        let cardBox = group(cardRows, inset: 16, spacing: 12)
        (cardBox as? DesignCardBox)?.enablesHoverHighlight = true
        cardBox.setAccessibilityElement(true)
        cardBox.setAccessibilityRole(.group)
        let cardInnerStack = groupStack(cardBox)
        cardInnerStack?.spacing = 12
        cardInnerStack?.detachesHiddenViews = true
        cardBox.cornerRadius = Design.Radius.card

        return AccountCardViews(
            id: id,
            cardBox: cardBox,
            titleLbl: titleLbl,
            tierPill: tierPill,
            statusBadge: statusBadge,
            emailLbl: emailLbl,
            collapsedSummaryLabel: collapsedSummaryLabel,
            switchButton: swBtn,
            singleRefreshBtn: singleRefreshBtn,
            actionsButton: actionsButton,
            collapseButton: collapseButton,
            actionStack: actionStack,
            cardDivider: cardDivider,
            coreQuotaStack: coreQuotaStack,
            standaloneQuotaStack: standaloneQuotaStack,
            authWarningLabel: authWarningLabel,
            quotaWarningLabel: quotaWarningLabel,
            refreshErrorLabel: refreshErrorLabel,
            staleLabel: staleLabel,
            updateLabel: updateLabel
        )
    }

    private func updateAccountCardViews(_ card: AccountCardViews, item: [String: Any]) {
        let id = item["id"] as? String ?? card.id
        let email = item["email"] as? String ?? L10n.t("accounts.unnamed")
        let name = item["name"] as? String ?? ""
        let tier = AccountIdentity.normalizeTier(item["subscription_tier"] as? String)
        let isActive = id == activeId
        let isCollapsed = collapsedAccountIds.contains(id)

        let displayName = AccountIdentity.displayName(name: name, email: email)
        if card.titleLbl.stringValue != displayName { card.titleLbl.stringValue = displayName }
        if card.emailLbl.stringValue != email { card.emailLbl.stringValue = email }

        card.tierPill.title = tier
        card.tierPill.isHidden = tier.isEmpty

        if isActive {
            card.statusBadge.title = ""
            card.statusBadge.isHidden = true
        } else if id == recommendedAccountId {
            card.statusBadge.title = L10n.t("accounts.badge.recommended")
            card.statusBadge.tint = .systemGreen
            card.statusBadge.isHidden = false
        } else {
            card.statusBadge.title = ""
            card.statusBadge.isHidden = true
        }

        let accountTitle = name.isEmpty ? email : "\(name) · \(email)"
        let canSwitch = !isActive && item["disabled"] as? Bool != true && item["validation_blocked"] as? Bool != true
        card.switchButton.identifier = NSUserInterfaceItemIdentifier(id)
        card.switchButton.toolTip = nil
        card.switchButton.setAccessibilityLabel(L10n.t("accounts.a11y.switch_to", ["account": accountTitle]))
        card.collapseButton.identifier = NSUserInterfaceItemIdentifier(id)
        let chevronSymbol = isCollapsed ? "chevron.down" : "chevron.up"
        card.collapseButton.image = NSImage(systemSymbolName: chevronSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        card.collapseButton.image?.isTemplate = true
        card.collapseButton.toolTip = nil
        card.collapseButton.setAccessibilityLabel(isCollapsed ? L10n.t("accounts.a11y.expand_details", ["account": accountTitle]) : L10n.t("accounts.a11y.collapse_details", ["account": accountTitle]))
        if card.switchButton.isHidden != !canSwitch {
            card.switchButton.isHidden = !canSwitch
        }
        let isSingleRefreshing = app.refreshingAccountIds.contains(id)
        if card.singleRefreshBtn.isHidden != !isSingleRefreshing {
            card.singleRefreshBtn.isHidden = !isSingleRefreshing
        }

        card.singleRefreshBtn.identifier = NSUserInterfaceItemIdentifier(id)
        card.singleRefreshBtn.setAccessibilityLabel(L10n.t("accounts.a11y.refresh_quota", ["account": accountTitle]))
        card.actionsButton.identifier = NSUserInterfaceItemIdentifier(id)
        card.actionsButton.setAccessibilityLabel(L10n.t("accounts.a11y.actions", ["account": accountTitle]))

        let quotaContract = QuotaPresentation.contract(item)
        let summaryText = Self.formatCollapsedQuotaSummary(quotaContract)
        if card.collapsedSummaryLabel.stringValue != summaryText {
            card.collapsedSummaryLabel.stringValue = summaryText
            card.collapsedSummaryLabel.toolTip = nil
        }
        card.collapsedSummaryLabel.isHidden = !isCollapsed

        card.cardDivider.isHidden = isCollapsed
        if isCollapsed {
            card.coreQuotaStack.isHidden = true
            card.standaloneQuotaStack.isHidden = true
        } else {
            DashboardPage.syncCoreGroupBars(quotaContract.coreGroups, into: card.coreQuotaStack, compact: false)
            DashboardPage.syncStandaloneGroupBars(quotaContract.standaloneGroups, into: card.standaloneQuotaStack, compact: false)
        }

        if let readiness = item["credentialReadiness"] as? [String: Any], readiness["state"] as? String == "needs_authorization" {
            card.authWarningLabel.toolTip = nil
            card.authWarningLabel.isHidden = false
        } else {
            card.authWarningLabel.toolTip = nil
            card.authWarningLabel.isHidden = true
        }

        let refreshError = (item["quota_refresh_error"] as? String).flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || InterfaceText.isInternalDualWindowError(trimmed) ? nil : trimmed
        }
        let quotaWarning = QuotaPresentation.warningSummary(quotaContract, excluding: [refreshError].compactMap { $0 })
        if !quotaWarning.isEmpty && !isCollapsed {
            card.quotaWarningLabel.stringValue = quotaWarning
            card.quotaWarningLabel.toolTip = nil
            card.quotaWarningLabel.isHidden = false
        } else {
            card.quotaWarningLabel.toolTip = nil
            card.quotaWarningLabel.isHidden = true
        }

        let singleNotice = (app.singleAccountRefreshNotices[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = refreshError {
            card.refreshErrorLabel.stringValue = InterfaceText.quotaMessage(error)
            card.refreshErrorLabel.textColor = accessibleWarningColor()
            card.refreshErrorLabel.toolTip = nil
            card.refreshErrorLabel.isHidden = false
        } else if let singleErr = app.singleAccountRefreshErrors[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !singleErr.isEmpty {
            card.refreshErrorLabel.stringValue = InterfaceText.quotaMessage(singleErr)
            card.refreshErrorLabel.textColor = accessibleWarningColor()
            card.refreshErrorLabel.toolTip = nil
            card.refreshErrorLabel.isHidden = false
        } else if !singleNotice.isEmpty {
            card.refreshErrorLabel.stringValue = singleNotice
            card.refreshErrorLabel.textColor = .secondaryLabelColor
            card.refreshErrorLabel.toolTip = nil
            card.refreshErrorLabel.isHidden = false
        } else {
            card.refreshErrorLabel.stringValue = ""
            card.refreshErrorLabel.toolTip = nil
            card.refreshErrorLabel.isHidden = true
        }

        if !isCollapsed,
           let quota = item["quota"] as? [String: Any],
           let staleGroups = quota["stale_groups"] as? [[String: Any]], !staleGroups.isEmpty {
            let names = staleGroups.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            let stamps = staleGroups.compactMap { group -> Double? in
                if let value = group["observed_at"] as? Double { return value }
                if let value = group["observed_at"] as? Int { return Double(value) }
                if let value = group["observed_at"] as? NSNumber { return value.doubleValue }
                return nil
            }
            let latest = stamps.max().map { Self.dateFormatter.string(from: Date(timeIntervalSince1970: $0)) }
            let listSep = L10n.shared.isEnglish ? ", " : "、"
            let groupText = names.isEmpty ? L10n.t("menu_panel.quota.partial_groups") : names.joined(separator: listSep)
            let staleText = L10n.t("accounts.stale.group", ["groups": groupText]) + (latest.map { L10n.t("accounts.stale.last_sampled", ["time": $0]) } ?? "")
            card.staleLabel.stringValue = staleText
            card.staleLabel.toolTip = nil
            card.staleLabel.isHidden = false
        } else {
            card.staleLabel.stringValue = ""
            card.staleLabel.toolTip = nil
            card.staleLabel.isHidden = true
        }

        let standbyMode = app.standbyRefreshMode(item)
        let quota = item["quota"] as? [String: Any]
        let stamp = QuotaPresentation.number(quota?["last_updated"]) ?? QuotaPresentation.number(item["quota_last_updated"]) ?? 0
        if !isCollapsed, standbyMode == "snapshot_cooldown_elapsed" {
            card.updateLabel.stringValue = L10n.t("accounts.standby.reset_passed", fallback: "已到重置时间 · 切换后更新")
            card.updateLabel.textColor = Design.blue
            card.updateLabel.toolTip = L10n.t("accounts.standby.multi_device_hint")
            card.updateLabel.isHidden = false
        } else if !isCollapsed, stamp > 0 {
            let dateStr = Self.dateFormatter.string(from: Date(timeIntervalSince1970: stamp))
            if standbyMode == "snapshot_cooling" {
                card.updateLabel.stringValue = L10n.t("accounts.standby.recorded_at", ["time": dateStr], fallback: "记录于 \(dateStr) · 切换后同步")
                card.updateLabel.textColor = .secondaryLabelColor
                card.updateLabel.toolTip = L10n.t("accounts.standby.multi_device_hint")
            } else {
                let isStale = (Date().timeIntervalSince1970 - stamp) > app.quotaStaleThresholdSeconds
                let updateText = isStale ? L10n.t("accounts.updated_at_stale", ["time": dateStr]) : L10n.t("accounts.updated_at", ["time": dateStr])
                card.updateLabel.stringValue = updateText
                card.updateLabel.textColor = isStale ? accessibleWarningColor() : .secondaryLabelColor
                card.updateLabel.toolTip = nil
            }
            card.updateLabel.isHidden = false
        } else {
            card.updateLabel.stringValue = ""
            card.updateLabel.toolTip = nil
            card.updateLabel.isHidden = true
        }

        let tierSegment = tier.isEmpty ? "" : (L10n.shared.isEnglish ? ", \(tier)" : "，\(tier)")
        let role = isActive ? L10n.t("accounts.role.current") : L10n.t("accounts.role.backup")
        card.cardBox.setAccessibilityLabel(L10n.t("accounts.a11y.card", ["account": accountTitle, "tier": tierSegment, "role": role]))
        if isActive {
            card.cardBox.borderWidth = 1.25
            card.cardBox.borderColor = Design.dynamicAlpha(Design.blue, 0.40)
        } else {
            card.cardBox.borderWidth = 0.5
            card.cardBox.borderColor = Design.border
        }
    }

    private func rebuildAccountCards() {
        let state = PerformanceSignpost.begin("AccountsCardsUpdate")
        defer { PerformanceSignpost.end("AccountsCardsUpdate", state) }
        refreshControlsById.removeAll()
        updateStaleGroupsSummary()

        if accountReadError != nil || accounts.isEmpty {
            cardViewsById.removeAll()
            syncCollapseHeaderButtonState()
            cardsStack.arrangedSubviews.forEach {
                cardsStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            if let message = accountReadError {
                let failure = text(message, size: 12, color: accessibleDangerColor(), wrap: true)
                failure.setAccessibilityLabel(message)
                let row = group([failure], inset: 14)
                cardsStack.addArrangedSubview(row); fillWidth(row, in: cardsStack)
            }
            if accounts.isEmpty, accountReadError != nil { return }
            if accounts.isEmpty {
                let emptyCard = group([
                    EmptyStateView(
                        icon: "person.crop.circle.badge.plus",
                        title: L10n.t("accounts.empty.title"),
                        subtitle: L10n.t("accounts.empty.subtitle"),
                        buttonTitle: L10n.t("accounts.add_btn"),
                        target: self,
                        action: #selector(addAccount)
                    )
                ], inset: 16)
                cardsStack.addArrangedSubview(emptyCard)
                fillWidth(emptyCard, in: cardsStack)
                syncCollapseHeaderButtonState()
                return
            }
        }

        let validIds = Set(accounts.compactMap { $0["id"] as? String }.filter { !$0.isEmpty })
        collapsedAccountIds = collapsedAccountIds.intersection(validIds)
        if isAllCollapsedMode {
            for id in validIds where cardViewsById[id] == nil {
                collapsedAccountIds.insert(id)
            }
        }
        cardViewsById = cardViewsById.filter { validIds.contains($0.key) }

        var orderedBoxes: [NSView] = []
        for item in accounts {
            let id = item["id"] as? String ?? ""
            let card: AccountCardViews
            if let existing = cardViewsById[id] {
                card = existing
            } else {
                let created = makeAccountCardViews(id: id, item: item)
                cardViewsById[id] = created
                card = created
            }
            updateAccountCardViews(card, item: item)
            orderedBoxes.append(card.cardBox)
            refreshControlsById[id] = card.singleRefreshBtn
        }
        syncCollapseHeaderButtonState()

        let currentViews = cardsStack.arrangedSubviews
        let structureSame = currentViews.count == orderedBoxes.count && zip(currentViews, orderedBoxes).allSatisfy { $0 === $1 }
        if !structureSame {
            for view in currentViews {
                cardsStack.removeArrangedSubview(view)
                if !orderedBoxes.contains(where: { $0 === view }) { view.removeFromSuperview() }
            }
            for sub in cardsStack.subviews where !orderedBoxes.contains(where: { $0 === sub }) {
                sub.removeFromSuperview()
            }
            for cardBox in orderedBoxes {
                cardsStack.addArrangedSubview(cardBox)
                fillWidth(cardBox, in: cardsStack)
            }
        }

        // A05: 先应用全局/批量状态，再由页面级 per-account 状态覆盖（含失败 tooltip）。
        app.updateQuotaRefreshControls()
        applyCardRefreshState()
    }

    /// A05: 把页面级 per-account busy/error 状态贴到当前挂载的刷新按钮上。
    /// 轮询里的 app.updateQuotaRefreshControls() 会清掉按钮 tooltip，因此每次 fetch 完成后再贴一次。
    private func applyCardRefreshState() {
        for (id, control) in refreshControlsById {
            let error = accountRefreshErrors[id]
            let available = app.reachable && (app.pendingAccountTaskId == nil || app.quotaRefreshing)
            let isSingleRefreshing = app.refreshingAccountIds.contains(id)
            if control.isHidden != !isSingleRefreshing {
                control.isHidden = !isSingleRefreshing
            }
            control.setRefreshState(busy: app.quotaRefreshing || isSingleRefreshing, available: available, error: error)
            control.toolTip = nil
        }
    }

    /// B01: 页面顶部汇总；只统计真正带 stale_groups 的账号，避免把普通联网失败混为“沿用记录”。
    private func updateStaleGroupsSummary() {
        let staleAccounts = accounts.filter { item in
            guard let quota = item["quota"] as? [String: Any] else { return false }
            return (quota["stale_groups"] as? [[String: Any]])?.isEmpty == false
        }.count
        guard staleAccounts > 0 else {
            staleGroupsSummary.stringValue = ""
            staleGroupsSummary.isHidden = true
            return
        }
        staleGroupsSummary.stringValue = L10n.t("accounts.stale.summary_banner", ["count": staleAccounts])
        staleGroupsSummary.toolTip = nil
        staleGroupsSummary.isHidden = false
    }

    private func quotaStamp(for id: String) -> Int {
        guard let item = accounts.first(where: { ($0["id"] as? String) == id }) else { return 0 }
        return item["quota_last_updated"] as? Int
            ?? item["quotaLastUpdated"] as? Int
            ?? ((item["quota"] as? [String: Any])?["last_updated"] as? Int ?? 0)
    }

    func fetch(_ snapshot: [String:Any]? = nil) {
        let receive: (Result<[String:Any],Error>) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .failure(let error):
                self.accountReadError = L10n.t("accounts.read_failed", ["error": error.localizedDescription])
                self.rebuildAccountCards()
            case .success(let value):
                let recovered = self.accountReadError != nil; self.accountReadError = nil
                if recovered { self.renderedFingerprint = "" }
                self.accounts = value["accounts"] as? [[String: Any]] ?? []
                self.activeId = value["activeId"] as? String ?? (value["currentAccountId"] as? String ?? "")
                if !self.app.statusValue.liveAccountEmail.isEmpty,
                   let live = self.accounts.first(where: { ($0["email"] as? String ?? "").caseInsensitiveCompare(self.app.statusValue.liveAccountEmail) == .orderedSame }),
                   let liveID = live["id"] as? String { self.activeId = liveID }
                self.accounts = self.accounts.enumerated().sorted { left, right in
                    let l = left.element["id"] as? String == self.activeId, r = right.element["id"] as? String == self.activeId
                    return l == r ? left.offset < right.offset : l
                }.map(\.element)
                self.updateAutoSwitchState()
                let newFingerprint = "\(self.activeId):\(self.app.statusValue.liveAccountEmail):\(self.app.quotaStaleThresholdSeconds):" + self.accounts.map { item in
                    let id = item["id"] as? String ?? ""
                    let rev = item["revision"] as? String ?? ""
                    let g5Cd = item["geminiFiveHourResetCountdown"] as? String ?? ""
                    let gWCd = item["geminiWeeklyResetCountdown"] as? String ?? ""
                    let cWCd = item["claudeWeeklyResetCountdown"] as? String ?? ""
                    let aWCd = item["argonWeeklyResetCountdown"] as? String ?? ""
                    let models = item["models"] as? [[String: Any]] ?? []
                    let modelsCd = models.map { ($0["reset_countdown"] as? String) ?? "" }.joined(separator: ",")
                    let dis = (item["disabled"] as? Bool == true) ? "1" : "0"
                    let vblk = (item["validation_blocked"] as? Bool == true) ? "1" : "0"
                    let credState = (item["credentialReadiness"] as? [String: Any])?["state"] as? String ?? ""
                    let standbyMode = self.app.standbyRefreshMode(item) ?? ""
                    let singleNotice = self.app.singleAccountRefreshNotices[id] ?? ""
                    let singleErr = self.app.singleAccountRefreshErrors[id] ?? ""
                    if !rev.isEmpty {
                        return "\(id):\(item["name"] as? String ?? ""):\(rev):\(dis):\(vblk):\(credState):\(standbyMode):\(singleNotice):\(singleErr):\(g5Cd):\(gWCd):\(cWCd):\(aWCd):\(modelsCd):\(QuotaPresentation.fingerprint(item))"
                    }
                    let g5h = item["geminiFiveHourRemaining"] as? Int ?? -1
                    let gWk = item["geminiWeeklyRemaining"] as? Int ?? -1
                    let c5h = item["claudeFiveHourRemaining"] as? Int ?? -1
                    let cWk = item["claudeWeeklyRemaining"] as? Int ?? -1
                    let aWk = item["argonWeeklyRemaining"] as? Int ?? -1
                    let label = item["custom_label"] as? String ?? ""
                    
                    let tier = item["subscription_tier"] as? String ?? ""
                    let err = item["quota_refresh_error"] as? String ?? ""
                    let lastUp = item["quota_last_updated"] as? Int ?? (item["quotaLastUpdated"] as? Int ?? ((item["quota"] as? [String: Any])?["last_updated"] as? Int ?? 0))
                    let modelsKey = models.map { m in
                        let mName = m["name"] as? String ?? ""
                        let mPct = m["percentage"] as? Int ?? -1
                        let mCd = m["reset_countdown"] as? String ?? (m["resetCountdown"] as? String ?? "")
                        return "\(mName)=\(mPct)=\(mCd)"
                    }.joined(separator: ",")
                    return "\(id):\(g5h):\(gWk):\(c5h):\(cWk):\(aWk):\(label):\(tier):\(dis):\(standbyMode):\(singleNotice):\(singleErr):\(err):\(lastUp):\(modelsKey):\(QuotaPresentation.fingerprint(item))"
                }.joined(separator: "|")
                if newFingerprint != self.renderedFingerprint {
                    self.renderedFingerprint = newFingerprint
                    self.rebuildAccountCards()
                }
                let recommendationKey = newFingerprint + ":" + String(Int(Date().timeIntervalSince1970 / 60))
                if self.autoSwitchToggle.state == .on && recommendationKey != self.recommendationFingerprint {
                    self.recommendationFingerprint = recommendationKey; self.evaluateRecommendationPreview()
                }
                if let pending = value["pendingSwitch"] as? Bool {
                    self.hasPendingSwitch = pending
                } else if let pendingObj = value["pendingSwitch"] as? [String: Any], let p = pendingObj["isPending"] as? Bool {
                    self.hasPendingSwitch = p
                } else {
                    self.hasPendingSwitch = false
                }
                self.pendingRecoveryBox.isHidden = !self.hasPendingSwitch
                // A05: 清理已删除账号 / 已被其他刷新路径更新的旧失败态，再把页面级状态贴回当前按钮。
                let currentIds = Set(self.accounts.compactMap { $0["id"] as? String })
                self.accountRefreshErrors = self.accountRefreshErrors.filter { currentIds.contains($0.key) }
                self.accountRefreshErrorStamps = self.accountRefreshErrorStamps.filter { currentIds.contains($0.key) }
                for id in Array(self.accountRefreshErrorStamps.keys) where self.quotaStamp(for: id) != self.accountRefreshErrorStamps[id] {
                    self.accountRefreshErrors[id] = nil
                    self.accountRefreshErrorStamps[id] = nil
                    self.app.singleAccountRefreshErrors[id] = nil
                }
                self.applyCardRefreshState()
            }
        }
        if let snapshot { receive(.success(snapshot)) } else { app.fetchAccountList(notifyPage: false, completion: receive) }
    }


    private func currentActiveAccountPayload() -> [String: Any]? {
        if !activeId.isEmpty, let matched = accounts.first(where: { ($0["id"] as? String) == activeId }) {
            return matched
        }
        return app.resolvedActiveAccount()
    }

    private func monitoredModelSummaryLabel() -> String {
        let raw = autoSwitchConfig["monitored_model"] as? String ?? "all"
        return QuotaPresentation.monitoredModelDisplayName(raw, activeAccount: currentActiveAccountPayload(), accounts: accounts)
    }

    func updateAutoSwitchState() {
        autoSwitchToggle.isEnabled = true
        let isEnabled = autoSwitchToggle.state == .on
        let threshold = max(1, intVal(autoSwitchConfig, "reserve_percentage", fallback: intVal(autoSwitchConfig, "reservePercentage", fallback: 10)))
        let candidateMin = max(1, intVal(autoSwitchConfig, "candidate_min_percentage", fallback: intVal(autoSwitchConfig, "candidateMinPercentage", fallback: 30)))
        let rawModel = (autoSwitchConfig["monitored_model"] as? String ?? "all").trimmingCharacters(in: .whitespacesAndNewlines)
        let activeAcc = currentActiveAccountPayload()
        let effectiveKey = QuotaPresentation.effectiveMonitoredModelKey(rawModel, activeAccount: activeAcc)
        let monitored = monitoredModelSummaryLabel()

        policyBox.fillColor = Design.card
        policySubtitleLabel.stringValue = L10n.t("accounts.smart_switch.subtitle", ["monitored": monitored, "threshold": threshold, "min": candidateMin])
        let rawDisplay = QuotaPresentation.monitoredModelDisplayName(rawModel, accounts: accounts)
        if !rawModel.isEmpty, rawModel.lowercased() != "all", effectiveKey.lowercased() != rawModel.lowercased(), rawDisplay != monitored {
            policySubtitleLabel.toolTip = L10n.t("accounts.smart_switch.adapted_tooltip", ["raw": rawDisplay, "effective": monitored], fallback: "原配置监测 \(rawDisplay)，当前账号已自适应为 \(monitored)")
        } else {
            policySubtitleLabel.toolTip = nil
        }
        if isEnabled {
            policyBox.borderWidth = 0.5
            policyBox.borderColor = Design.dynamicAlpha(Design.blue, 0.32)
            autoSwitchBadgeBox.fillColor = Design.dynamicAlpha(Design.blue, 0.12)
            autoSwitchBadgeBox.borderColor = Design.dynamicAlpha(Design.blue, 0.24)
            autoSwitchBadgeIcon.contentTintColor = Design.blue
            autoSwitchStatusBadge.title = L10n.t("accounts.smart_switch.enabled_badge", ["threshold": threshold])
            autoSwitchStatusBadge.tint = Design.blue
        } else {
            policyBox.borderWidth = 0.5
            policyBox.borderColor = Design.border
            autoSwitchBadgeBox.fillColor = Design.inactivePillFill
            autoSwitchBadgeBox.borderColor = Design.inactivePillBorder
            autoSwitchBadgeIcon.contentTintColor = Design.inactivePill
            autoSwitchStatusBadge.title = L10n.t("accounts.smart_switch.disabled")
            autoSwitchStatusBadge.tint = Design.inactivePill
        }
        configButton.isEnabled = true
        configButton.alphaValue = 1.0
    }

    func fetchPolicy() {
        guard !policyInFlight else { return }
        policyInFlight = true
        app.bridge.send(["command": "auto_switch_get"]) { [weak self] response in
            guard let self else { return }
            self.policyInFlight = false
            if case .success(let value) = response, let cfg = value["config"] as? [String: Any] {
                self.autoSwitchConfig = cfg
                let isEnabled = cfg["enabled"] as? Bool == true
                self.autoSwitchToggle.state = isEnabled ? .on : .off
                self.updateAutoSwitchState()
                if isEnabled {
                    self.evaluateRecommendationPreview()
                } else {
                    // A04: 关闭后统一复位推荐条、推荐账号与按钮标识，避免残留“切换至此账号”。
                    self.clearRecommendation()
                }
            } else {
                self.updateAutoSwitchState()
            }
        }
    }

    /// A04: 唯一的推荐状态复位入口（fetchPolicy / savePolicy / 预览失败 / 开关关闭共用）。
    func clearRecommendation() {
        recommendationFingerprint = ""
        recommendedAccountId = nil
        app.cachedRecommendedAccountId = nil
        app.lastRecommendedAccountsFingerprint = ""
        recommendationLabel.stringValue = ""
        switchRecommendedBtn.identifier = nil
        switchRecommendedBtn.isHidden = true
        recommendationDivider.isHidden = true
        recommendationRow.isHidden = true
        rebuildAccountCards()
    }

    func evaluateRecommendationPreview() {
        guard autoSwitchToggle.state == .on else {
            clearRecommendation()
            return
        }
        app.bridge.send(["command": "auto_switch_best", "preview": true]) { [weak self] response in
            guard let self else { return }
            // 开关在请求期间被关闭：不要用旧响应把推荐条重新显示出来。
            guard self.autoSwitchToggle.state == .on else {
                self.clearRecommendation()
                return
            }
            if case .success(let value) = response {
                let candidate = value["account"] as? [String: Any]
                let candidateId = candidate?["id"] as? String
                let shouldSwitch = value["shouldSwitch"] as? Bool ?? false
                let reason = value["reason"] as? String ?? ""
                self.recommendedAccountId = shouldSwitch ? candidateId : nil
                self.app.cachedRecommendedAccountId = self.recommendedAccountId
                self.updateRecommendationBanner(shouldSwitch: shouldSwitch, candidate: candidate, reason: reason)
            } else {
                self.clearRecommendation()
                return
            }
            self.rebuildAccountCards()
        }
    }

    func updateRecommendationBanner(shouldSwitch: Bool, candidate: [String: Any]?, reason: String) {
        guard autoSwitchToggle.state == .on else {
            clearRecommendation()
            return
        }
        if shouldSwitch, let candidate, let cId = candidate["id"] as? String, cId != activeId {
            let email = candidate["email"] as? String ?? ""
            let name = candidate["name"] as? String ?? ""
            let displayName = name.isEmpty ? email : "\(name) · \(email)"
            recommendationLabel.stringValue = L10n.t("accounts.smart_switch.recommend_low", ["display": displayName])
            recommendationLabel.textColor = .labelColor
            recommendationLabel.toolTip = nil
            switchRecommendedBtn.identifier = NSUserInterfaceItemIdentifier(cId)
            switchRecommendedBtn.isHidden = false
            recommendationDivider.isHidden = false
            recommendationRow.isHidden = false
        } else if let candidate, let cId = candidate["id"] as? String, cId != activeId {
            let email = candidate["email"] as? String ?? ""
            let name = candidate["name"] as? String ?? ""
            let displayName = name.isEmpty ? email : "\(name) · \(email)"
            
            recommendationLabel.stringValue = reason.isEmpty ? L10n.t("accounts.smart_switch.backup_display", ["display": displayName]) : reason
            recommendationLabel.textColor = Design.secondary
            switchRecommendedBtn.isHidden = true
            recommendationDivider.isHidden = false
            recommendationRow.isHidden = false
        } else if let candidate, let cId = candidate["id"] as? String, cId == activeId {
            recommendationLabel.stringValue = L10n.t("accounts.smart_switch.best_current")
            recommendationLabel.textColor = Design.secondary
            switchRecommendedBtn.isHidden = true
            recommendationDivider.isHidden = false
            recommendationRow.isHidden = false
        } else {
            recommendationLabel.stringValue = reason.isEmpty ? L10n.t("accounts.smart_switch.no_candidate") : reason
            recommendationLabel.textColor = Design.secondary
            switchRecommendedBtn.isHidden = true
            recommendationDivider.isHidden = false
            recommendationRow.isHidden = false
        }
    }

    @objc func switchRecommendedAccount(_ sender: NSButton) {
        guard let id = recommendedAccountId, !id.isEmpty, id != activeId else { return }
        let btn = NSButton()
        btn.identifier = NSUserInterfaceItemIdentifier(id)
        switchCardAccountById(btn)
    }

    @objc func refreshSingleAccountById(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        guard !id.isEmpty, app.reachable, !app.refreshingAccountIds.contains(id) else { return }
        accountRefreshErrors[id] = nil
        accountRefreshErrorStamps[id] = nil
        let targetAccount = accounts.first(where: { ($0["id"] as? String) == id })
        let email = targetAccount?["email"] as? String ?? L10n.t("accounts.account_fallback")
        app.refreshSingleAccountQuota(id: id) { [weak self] response in
            guard let self else { return }
            switch response {
            case .failure(let error):
                self.accountRefreshErrors[id] = error.localizedDescription
                self.accountRefreshErrorStamps[id] = self.quotaStamp(for: id)
                self.app.showMessage(L10n.t("accounts.refresh.single_failed", ["email": email, "error": error.localizedDescription]), error: true)
            case .success(let value):
                self.accountRefreshErrors[id] = nil
                self.accountRefreshErrorStamps[id] = nil
                let msg = (value["standbyDeferred"] as? Bool == true)
                    ? (value["notice"] as? String ?? value["message"] as? String ?? L10n.t("accounts.refresh.single_success", ["email": email]))
                    : (value["message"] as? String ?? L10n.t("accounts.refresh.single_success", ["email": email]))
                self.app.showMessage(msg)
                self.app.refresh()
            }
            self.applyCardRefreshState()
        }
        applyCardRefreshState()
    }

    var policySheet: AccountPolicySheet?
    @objc func showPolicySettings() {
        guard let window = app.window, window.activeSheetWindow == nil else { return }
        let sheet = AccountPolicySheet(app: app, config: autoSwitchConfig) { [weak app = self.app] in app?.accountsPage?.fetchPolicy() }
        policySheet = sheet; sheet.show(in: window) { [weak self] in self?.policySheet = nil }
    }

    @objc func savePolicy() {
        let enabled = autoSwitchToggle.state == .on
        let oldEnabled = autoSwitchConfig["enabled"] as? Bool == true
        autoSwitchToggle.isEnabled = false
        updateAutoSwitchState()
        let payload: [String: Any] = [
            "command": "auto_switch_set",
            "config": [
                "enabled": enabled
            ]
        ]
        app.bridge.send(payload) { [weak self] response in
            guard let self else { return }
            self.autoSwitchToggle.isEnabled = true
            switch response {
            case .failure(let error):
                self.autoSwitchToggle.state = oldEnabled ? .on : .off
                self.updateAutoSwitchState()
                self.app.showMessage(L10n.t("accounts.smart_switch.save_failed", ["error": error.localizedDescription]), error: true)
            case .success(let value):
                self.autoSwitchConfig = value["config"] as? [String:Any] ?? self.autoSwitchConfig.merging(["enabled": enabled]) { _, new in new }
                self.updateAutoSwitchState()
                if enabled {
                    self.evaluateRecommendationPreview()
                } else {
                    // A04: 与 fetchPolicy 共用同一复位路径。
                    self.clearRecommendation()
                }
                self.app.showMessage(enabled ? L10n.t("accounts.smart_switch.enabled_msg") : L10n.t("accounts.smart_switch.disabled_msg"))
                self.app.refresh()
            }
        }
    }



    @objc func refreshAllQuotas() { app.refreshAccountQuotas() }

    var addAccountSheet: AddAccountSheet?
    @objc func addAccount() {
        guard let window = app.window, window.activeSheetWindow == nil else { return }
        let sheet = AddAccountSheet(app: app, accountCount: accounts.count) { [weak app = self.app] in app?.accountsPage?.fetch(); app?.refresh() }
        addAccountSheet = sheet
        sheet.show(in: window) { [weak self] in self?.addAccountSheet = nil }
    }

    @objc func rollbackSwitch() {
        guard let window = app.window, window.activeSheetWindow == nil else { return }
        let alert = NSAlert(); alert.messageText = L10n.t("accounts.rollback.confirm_title")
        alert.informativeText = L10n.t("accounts.rollback.confirm_body")
        alert.addButton(withTitle: L10n.t("accounts.rollback.confirm_action")); alert.addButton(withTitle: L10n.t("common.cancel"))
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            self.rollbackButton.isEnabled = false
            self.app.bridge.send(["command": "account_switch_rollback"]) { [weak self] response in
                guard let self else { return }
                self.rollbackButton.isEnabled = true
                switch response {
                case .success(let value):
                    self.app.showMessage(value["message"] as? String ?? L10n.t("accounts.rollback.restored"))
                    self.fetch()
                    self.app.refresh()
                case .failure(let error):
                    self.app.showMessage(error.localizedDescription, error: true)
                    self.fetch()
                    self.app.refresh()
                }
            }
        }
    }

    @objc func switchCardAccountById(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? (accounts.indices.contains(sender.tag) ? accounts[sender.tag]["id"] as? String ?? "" : "")
        guard !id.isEmpty, id != activeId else { return }
        let targetAccount = accounts.first(where: { ($0["id"] as? String) == id })
        let email = targetAccount?["email"] as? String ?? ""
        let name = targetAccount?["name"] as? String ?? ""
        app.requestInteractiveAccountSwitch(id: id, email: email, name: name) {
            [weak self] in self?.fetch()
        }
    }

    @objc func refreshAccountFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, !id.isEmpty else { return }
        let btn = NSButton()
        btn.identifier = NSUserInterfaceItemIdentifier(id)
        refreshSingleAccountById(btn)
    }

    @objc func showAccountActions(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let row = accounts.firstIndex(where: { $0["id"] as? String == id }) else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true, tag: Int = 0) { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = id; item.isEnabled = enabled; item.tag = tag; menu.addItem(item) }
        let isRefreshing = app.quotaRefreshing || app.refreshingAccountIds.contains(id)
        let canRefresh = app.reachable && !isRefreshing && app.pendingAccountTaskId == nil
        add(isRefreshing ? L10n.t("accounts.menu.refreshing") : L10n.t("common.refresh_quota"), #selector(refreshAccountFromMenu(_:)), enabled: canRefresh)
        menu.addItem(.separator())
        add(L10n.t("accounts.menu.rename"), #selector(renameAccount(_:)))
        add(L10n.t("accounts.menu.move_up"), #selector(moveAccount(_:)), enabled: id != activeId && row > (accounts.contains { $0["id"] as? String == activeId } ? 1 : 0), tag: -1)
        add(L10n.t("accounts.menu.move_down"), #selector(moveAccount(_:)), enabled: id != activeId && row + 1 < accounts.count, tag: 1)
        menu.addItem(.separator()); add(L10n.t("accounts.menu.remove"), #selector(deleteCardAccountByIdItem(_:)), enabled: id != activeId)
        Design.popUpMenu(menu, below: sender)
    }
    @objc func moveAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let old = accounts.firstIndex(where: { $0["id"] as? String == id }) else { return }
        let next = old + sender.tag; guard accounts.indices.contains(next), id != activeId, accounts[next]["id"] as? String != activeId else { return }
        var ids = accounts.compactMap { $0["id"] as? String }; ids.swapAt(old, next)
        app.perform(["command": "account_reorder", "ids": ids]) { [weak self] _ in self?.fetch() }
    }
    @objc func renameAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let row = accounts.first(where: { $0["id"] as? String == id }),
              let window = app.window,
              window.activeSheetWindow == nil else { return }
        let email = row["email"] as? String ?? ""
        let oldName = row["name"] as? String ?? ""

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 184), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.backgroundColor = .clear
        sheet.isOpaque = false
        let surface = SheetVisualEffectView()
        sheet.contentView = surface

        let titleLabel = text(L10n.t("accounts.rename.title"), size: 15, weight: .semibold, color: .labelColor)
        let subLabel = text(email, size: 11.5, color: Design.secondary)
        subLabel.lineBreakMode = .byTruncatingMiddle

        let field = NSTextField(string: oldName)
        field.placeholderString = L10n.t("accounts.rename.placeholder")
        field.font = .systemFont(ofSize: 12.5)
        field.setAccessibilityLabel(L10n.t("accounts.rename.a11y"))
        Design.applyControls(field)

        final class RenameSheetHandler: NSObject {
            let sheet: NSWindow
            let parent: NSWindow
            let field: NSTextField
            let oldName: String
            var observer: NSObjectProtocol?
            init(sheet: NSWindow, parent: NSWindow, field: NSTextField, oldName: String) {
                self.sheet = sheet; self.parent = parent; self.field = field; self.oldName = oldName
            }
            @objc func savePressed() {
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.count <= 80 && name != oldName else { return }
                parent.endSheet(sheet, returnCode: .OK)
            }
            @objc func cancelPressed() {
                parent.endSheet(sheet, returnCode: .cancel)
            }
        }
        let handler = RenameSheetHandler(sheet: sheet, parent: window, field: field, oldName: oldName)
        let cancelBtn = button(L10n.t("common.cancel"), target: handler, action: #selector(RenameSheetHandler.cancelPressed))
        let saveBtn = button(L10n.t("common.save"), target: handler, action: #selector(RenameSheetHandler.savePressed))
        saveBtn.bezelColor = Design.blue
        saveBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"
        saveBtn.isEnabled = false
        field.target = handler; field.action = #selector(RenameSheetHandler.savePressed)

        handler.observer = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: field, queue: .main) { _ in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            saveBtn.isEnabled = name.count <= 80 && name != oldName
        }

        let actionsRow = horizontal([flexibleSpace(), cancelBtn, saveBtn], spacing: 8)
        let stack = vertical([titleLabel, subLabel, field, divider(), actionsRow], spacing: 12)
        for v in [subLabel, field, actionsRow] { fillWidth(v, in: stack) }
        surface.addSubview(stack)
        pin(stack, to: surface, inset: 20)

        #if NATIVE_UI_TEST
        Assistant.configureHeadlessWindowIfNeeded(window)
        Assistant.configureHeadlessWindowIfNeeded(sheet)
        #endif
        window.beginSheet(sheet) { [weak self] resp in
            if let obs = handler.observer { NotificationCenter.default.removeObserver(obs) }
            withExtendedLifetime(handler) {}
            guard resp == .OK else { return }
            self?.app.perform(["command": "account_rename", "id": id, "name": field.stringValue]) { [weak self] _ in self?.fetch() }
        }
        sheet.makeFirstResponder(field)
    }
    @objc func deleteCardAccountByIdItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = accounts.first(where: { ($0["id"] as? String) == id }),
              let window = app.window else { return }
        guard id != activeId else {
            self.app.showMessage(L10n.t("accounts.delete.cannot_active"), error: true)
            return
        }
        let email = item["email"] as? String ?? ""

        let alert = NSAlert()
        alert.messageText = L10n.t("accounts.delete.confirm_title")
        alert.informativeText = L10n.t("accounts.delete.confirm_body", ["email": email])
        alert.addButton(withTitle: L10n.t("accounts.delete.confirm_action"))
        alert.addButton(withTitle: L10n.t("common.cancel"))

        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            self.app.bridge.send(["command": "account_delete", "id": id]) { [weak self] res in
                guard let self else { return }
                switch res {
                case .success:
                    self.app.showMessage(L10n.t("accounts.delete.success"))
                    self.fetch()
                    self.app.refresh()
                case .failure(let error):
                    // A06: 失败必须可见，并从后端数据源恢复列表/按钮状态（不做乐观删除）。
                    self.app.showMessage(L10n.t("accounts.delete.failed", ["error": error.localizedDescription]), error: true)
                    self.fetch()
                    self.app.updateQuotaRefreshControls()
                }
            }
        }
    }

    func update() {
        fetch()
        fetchPolicy()
    }
}
