import Cocoa

@main struct NativeUIFixture {
    static var assertionCount = 0
    static func check(_ condition: Bool, _ message: String) {
        assertionCount += 1
        if !condition { FileHandle.standardError.write(Data((message+"\n").utf8)); exit(1) }
    }
    static func assertNoVisibleWindowsOnScreen(_ context: String = "") {
        guard Assistant.headlessOffscreenUI else { return }
        let pid = Int(getpid())
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let visible = list.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? Int) == pid else { return false }
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard alpha > 0.0 else { return false }
            if let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let w = bounds["Width"] as? Double,
               let h = bounds["Height"] as? Double {
                return w > 0 && h > 0
            }
            return true
        }
        if !visible.isEmpty {
            let prefix = context.isEmpty ? "" : "[\(context)] "
            check(false, "\(prefix)Headless UI test leaked visible window(s) on screen: \(visible)")
        }
    }
    static func makeHeadlessHostWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: -24000, y: -24000, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        Assistant.configureHeadlessWindowIfNeeded(win)
        return win
    }
    static func pump(_ duration: TimeInterval = 0.02) {
        let safeDuration = max(0.005, duration)
        let end = Date().addingTimeInterval(safeDuration)
        let tick = min(0.005, safeDuration)
        var tickCount = 0
        repeat {
            let remaining = end.timeIntervalSinceNow
            let step = max(0.001, min(tick, remaining > 0 ? remaining : 0.002))
            RunLoop.main.run(until: Date().addingTimeInterval(step))
            tickCount += 1
            if tickCount == 1 {
                assertNoVisibleWindowsOnScreen("pump-first-tick")
            }
        } while tickCount < 2 || Date() < end
        assertNoVisibleWindowsOnScreen("pump-end")
    }
    static func waitForSheetDetach(on hostWindow: NSWindow, description: String) {
        pump()
        waitUntil(step: 0.01, description: description) {
            hostWindow.activeSheetWindow == nil && hostWindow.attachedSheet == nil
        }
    }
    @discardableResult
    static func waitUntil(
        timeout: TimeInterval = {
            if let custom = ProcessInfo.processInfo.environment["GRAVITYBOX_CI_TIMEOUT"], let val = TimeInterval(custom), val > 0 {
                return val
            }
            let isCI = ProcessInfo.processInfo.environment["CI"].map { !$0.isEmpty && $0 != "0" && $0.lowercased() != "false" } ?? false
            return isCI ? 10.0 : 3.0
        }(),
        step: TimeInterval = 0.05,
        description: String = "condition",
        condition: () -> Bool
    ) -> Bool {
        if condition() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(step))
            assertNoVisibleWindowsOnScreen("waitUntil:\(description)")
            if condition() { return true }
        }
        let satisfied = condition()
        check(satisfied, "Timed out waiting for \(description) after \(timeout)s")
        return satisfied
    }
    static func capture(_ view: NSView, _ url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in:view.bounds,to:rep)
        try rep.representation(using:.png,properties:[:])!.write(to:url)
    }
    static func allTextValues(_ v: NSView) -> [String] {
        var values: [String] = []
        if let tf = v as? NSTextField { values.append(tf.stringValue) }
        if let btn = v as? NSButton { values.append(btn.title) }
        if let pop = v as? NSPopUpButton { values.append(contentsOf: pop.itemTitles) }
        for sub in v.subviews { values.append(contentsOf: allTextValues(sub)) }
        return values
    }
    static func main() throws {
        let application = NSApplication.shared
        let interactive = CommandLine.arguments.contains("--interactive")
        Assistant.headlessOffscreenUI = !interactive
        application.setActivationPolicy(interactive ? .regular : .prohibited)
        let state = URL(fileURLWithPath:CommandLine.arguments[1]), output = URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        L10n.shared.setLanguage("zh-Hans", notify: false)
        let assistant = Assistant(state:state)
        assistant.configuration = try ConfigurationStore(state:state)
        assistant.configuration.value.navigationVersion = 5
        assistant.configuration.value.appLanguage = "zh-Hans"
        assistant.bridge = BackendBridge(resources:state,state:state)
        assistant.reachable = true
        var fixtureStatus: [String:Any] = ["mode":"adaptive","windows":1,"entries":4300,"appVersion":"2.25.0","liveAccountEmail":"alex@example.invalid","activeAccountEmail":"alex@example.invalid","accountsRevision":"fixture","pid":-1,"configuredLanguage":"zh-Hans","locale":"zh-Hans","translationEnabled":true]
        let status = fixtureStatus
        assistant.statusValue = LiveStatus(fixtureStatus)
        func bucket(_ percent: Double, reset: String = "2小时后重置") -> [String:Any] {
            ["remaining":percent/100,"known":true,"stale":false,"source":"live","observedAt":Date().timeIntervalSince1970,"resetCountdown":reset]
        }
        func account(_ id:String, _ name:String, _ email:String, _ current:Bool) -> [String:Any] {
            let windows:[String:Any] = ["gemini":["fiveHour":bucket(91),"weekly":bucket(33)],"claude":["fiveHour":bucket(current ? 0 : 100),"weekly":bucket(48)]]
            return ["id":id,"name":name,"email":email,"subscription_tier":"PRO","revision":id,"familyWindows":windows,"argonStatus":["availability":"available","quotaState":"known","period":"weekly","remaining":0.008],"quota":["last_updated":Date().timeIntervalSince1970,"source":"live"],"models":[]]
        }
        var accounts = [account("a","Alex","alex@example.invalid",true),account("b","Bob","bob@example.invalid",false),account("c","Charlie","charlie@example.invalid",false)]
        accounts[2]["subscription_tier"] = "FREE"
        accounts[2]["familyWindows"] = ["gemini":["weekly":bucket(100,reset:"6天23小时后重置")],"claude":["weekly":bucket(100,reset:"6天23小时后重置")]]
        accounts[2]["familyModelQuota"] = ["gemini":bucket(100,reset:"4小时59分后重置"),"claude":bucket(100,reset:"6天23小时后重置")]
        var activeId = "a", switches = 0, preflightState = "safe", lastLanguageCommand: String? = nil, lastHudCommandEnabled: Bool? = nil
        assistant.activeAccountId = activeId; assistant.cachedAccounts = accounts
        let models:[[String:Any]] = [
            ["model":"gemini-3.8-flash-n","totalTokens":90800000,"promptTokens":4000000,"candidatesTokens":300000,"requestCount":695,"estimatedUsd":10.77,"priced":true,"pricingStatus":"historical"],
            ["model":"gemini-3.8-flash-exp-a","totalTokens":12400000,"promptTokens":1100000,"candidatesTokens":90000,"requestCount":84,"estimatedUsd":6.40,"priced":true,"pricingStatus":"historical"],
            ["model":"claude-opus-5-5-medium","totalTokens":4500000,"promptTokens":900000,"candidatesTokens":120000,"requestCount":18,"estimatedUsd":5.25,"priced":true,"pricingStatus":"historical"],
            ["model":"claude-sonnet-4-6","totalTokens":2800000,"promptTokens":600000,"candidatesTokens":10000,"requestCount":43,"estimatedUsd":1.36,"priced":true]
        ]
        let todayHourly:[[String:Any]] = [
            ["hour":"2026-10-23 09:00","total_tokens":6200000],
            ["hour":"2026-10-23 10:00","total_tokens":14800000],
            ["hour":"2026-10-23 11:00","total_tokens":11400000],
            ["hour":"2026-10-23 14:00","total_tokens":19600000],
            ["hour":"2026-10-23 15:00","total_tokens":16200000],
            ["hour":"2026-10-23 16:00","total_tokens":12500000],
            ["hour":"2026-10-23 20:00","total_tokens":9800000],
            ["hour":"2026-10-23 21:00","total_tokens":7700000]
        ]
        let totals:[String:Any] = ["totalTokens":98200000,"promptTokens":4700000,"cachedTokens":93100000,"candidatesTokens":310000,"requestCount":756,"estimatedUsd":23.78,"pricedModels":4,"unpricedModels":0,"databasesScanned":343,"databasesDiscovered":343,"availability":"complete","scanScopeDescription":"全部 343 个会话数据库","lastScannedAt":Date().timeIntervalSince1970]
        assistant.bridge.fixtureReply = { payload in
            switch payload["command"] as? String {
            case "status": return ["ok":true,"status":fixtureStatus,"tasks":[],"taskRevision":0]
            case "account_list": return ["ok":true,"activeId":activeId,"accounts":accounts,"pendingSwitch":false]
            case "auto_switch_get": return ["ok":true,"config":["enabled":false,"strategy":"priority","monitored_model":"all"]]
            case "dashboard_summary": return ["ok":true,"accounts":accounts.first(where:{$0["id"] as? String == activeId})!.merging(["activeName":"Alex","activeEmail":"alex@example.invalid","activeTier":"PRO","liveAccountEmail":"alex@example.invalid","isLiveVerified":true]) { _, new in new },"usage":["todayTokens":98200000,"totalTokens":3000000000,"estimatedUsd":23.78,"allTimeEstimatedUsd":410.25,"requestCount":756,"totalRequestCount":27175,"todayPricedModels":4,"todayUnpricedModels":0,"pricedModels":4,"unpricedModels":0,"databasesScanned":343,"databasesDiscovered":343,"availability":"complete"]]
            case "usage_summary":
                let period = payload["period"] as? String ?? "today"
                return ["ok":true,"period":period,"snapshotId":"fixture-snapshot","summary":totals,"byModel":models,"todayHourly":todayHourly,"dailyTrends":[]]
            case "usage_events":
                let eventRows: [[String: Any]] = [
                    ["model": "gemini-3.8-flash-n", "timestamp_seconds": 1761544267, "input_tokens": 8290, "output_tokens": 374, "cached_tokens": 344104, "cache_write_tokens": 0],
                    ["model": "claude-opus-5-5-medium", "timestamp_seconds": 1761544259, "input_tokens": 6420, "output_tokens": 428, "cached_tokens": 343720, "cache_write_tokens": 0],
                    ["model": "gpt-5-turbo", "timestamp_seconds": 1761544255, "input_tokens": 5180, "output_tokens": 306, "cached_tokens": 240500, "cache_write_tokens": 0]
                ]
                return ["ok":true,"snapshot_id":"fixture-snapshot","rows":eventRows,"total":129,"scope":"全部 344 个会话数据库"]
            case "maintenance_scan":
                let reqRetention = intVal(payload, "retentionDays", fallback: 7)
                var scanEntries: [[String: Any]] = [
                    ["name": "Cache", "title": "网络与静态资源缓存", "subtitle": "界面静态资源与临时网络响应数据", "icon": "internaldrive", "category": "safe", "defaultSelected": true, "bytes": 524_288_000, "fileCount": 1820, "exists": true, "clearable": true],
                    ["name": "AgentBrowserCache", "title": "浏览器沙箱加速缓存", "subtitle": "Browser 沙箱的网页与编译缓存（保留站点登录与 Cookie）", "icon": "globe", "category": "safe", "defaultSelected": true, "bytes": 324_009_984, "fileCount": 1410, "exists": true, "clearable": true],
                    ["name": "PartitionsCache", "title": "内嵌视图子分区缓存", "subtitle": "内嵌浏览器与隔离分区的静态资源及编译缓存", "icon": "square.split.2x2", "category": "safe", "defaultSelected": true, "bytes": 96_468_992, "fileCount": 420, "exists": true, "clearable": true],
                    ["name": "OrphanAgentData", "title": "已删对话残留与临时文件", "subtitle": "含 6 个已删主对话遗留的孤儿记录、崩溃日志与临时媒体", "icon": "trash.slash", "category": "safe", "defaultSelected": true, "bytes": 48_234_496, "fileCount": 192, "exists": true, "clearable": true]
                ]
                let safeSum = 993_001_472
                var statefulSum = 0
                if reqRetention <= 7 {
                    scanEntries.append(contentsOf: [
                        ["name": "AgentSubagentDatabases", "title": "历史子智能体轨迹库", "subtitle": "7 天前共 142 个后台子智能体库（清理前自动归档 Token 账单）", "icon": "arrow.triangle.branch", "category": "stateful", "defaultSelected": false, "bytes": 856_686_592, "fileCount": 142, "exists": true, "clearable": true],
                        ["name": "AgentTaskStepLogs", "title": "历史任务与步骤输出日志", "subtitle": "7 天前对话的后台终端日志、步骤输出与 scratch 草稿", "icon": "terminal", "category": "stateful", "defaultSelected": false, "bytes": 218_103_808, "fileCount": 980, "exists": true, "clearable": true]
                    ])
                    statefulSum = 1_074_790_400
                }
                let latestSnap: [String: Any] = ["id": "GravityBox-缓存-1729900800000", "timestamp": 1729900800, "totalBytes": 312_475_648, "fileCount": 3180, "snapshotPath": "/tmp/gb-snap-latest"]
                return [
                    "ok": true,
                    "token": "fixture-token",
                    "retentionDays": reqRetention,
                    "entries": scanEntries,
                    "buckets": [
                        "runtimeCache": ["id": "runtime_cache", "bytes": safeSum, "clearableBytes": safeSum, "fileCount": 3842, "available": true],
                        "historyLogs": ["id": "history_logs", "bytes": statefulSum, "clearableBytes": statefulSum, "fileCount": statefulSum > 0 ? 1122 : 0, "subagentCount": statefulSum > 0 ? 142 : 0, "retentionDays": reqRetention, "available": statefulSum > 0]
                    ],
                    "safeBytes": safeSum,
                    "statefulBytes": statefulSum,
                    "totalBytes": safeSum + statefulSum,
                    "totalFiles": 4964,
                    "protectedEntries": [
                        ["id": "workspace", "title": "工作区与核心账号凭据", "subtitle": "User/globalStorage（OAuth 令牌库 state.vscdb）、Cookies、Local Storage 与工作区配置", "icon": "folder.badge.gearshape", "bytes": 87_031_808, "fileCount": 324, "exists": true],
                        ["id": "conversations", "title": "Agent 历史对话与上下文库", "subtitle": "受保护的主对话、已归档对话、正式产物与站点会话", "icon": "bubble.left.and.bubble.right", "bytes": 1_841_640_960, "fileCount": 201, "exists": true]
                    ],
                    "protectedBytes": 1_928_672_768,
                    "snapshots": [
                        ["id": "GravityBox-缓存-1729900800000", "timestamp": 1729900800, "totalBytes": 312_475_648, "fileCount": 3180, "items": ["Cache", "AgentBrowserCache", "OrphanAgentData"], "itemTitles": ["网络与静态资源缓存", "浏览器沙箱加速缓存", "已删对话残留与临时文件"], "movedCount": 3, "restorable": true, "interrupted": false],
                        ["id": "GravityBox-缓存-1729814400000", "timestamp": 1729814400, "totalBytes": 642_252_800, "fileCount": 1120, "items": ["AgentSubagentDatabases", "AgentTaskStepLogs"], "itemTitles": ["历史子智能体轨迹库", "历史任务与步骤输出日志"], "movedCount": 2, "restorable": true, "interrupted": false]
                    ],
                    "latestRestorableSnapshot": latestSnap,
                    "running": true,
                    "browserBusy": false,
                    "scannedAt": Int(Date().timeIntervalSince1970)
                ]
            case "account_switch_preflight": return [
                "ok": preflightState != "error",
                "safe": preflightState == "safe" || preflightState == "running_idle",
                "appRunning": preflightState == "busy" || preflightState == "running_idle",
                "stableRunning": preflightState == "running_idle",
                "hasRunningTask": preflightState == "busy",
                "error": "隔离预检失败"
            ]
            case "account_switch": switches += 1; activeId = payload["id"] as? String ?? activeId; return ["ok":true,"message":"隔离事务完成"]
            case "account_recovery_info": return ["ok":true,"available":false]
            case "language_set":
                let lang = payload["language"] as? String ?? "system"
                lastLanguageCommand = lang
                let resolved = lang == "en" ? "en" : "zh-Hans"
                fixtureStatus["configuredLanguage"] = lang
                fixtureStatus["locale"] = resolved
                fixtureStatus["translationEnabled"] = resolved == "zh-Hans"
                fixtureStatus["mode"] = resolved == "zh-Hans" ? "adaptive" : "paused"
                return ["ok":true,"status":fixtureStatus]
            case "hud_set":
                let enabled = payload["enabled"] as? Bool ?? true
                lastHudCommandEnabled = enabled
                fixtureStatus["hudEnabled"] = enabled
                return ["ok":true,"status":fixtureStatus]
            default: return ["ok":true]
            }
        }
        assistant.installApplicationMenu()
        assistant.showPanel(); pump()
        guard let window = assistant.window else { fatalError("Missing window") }
        if interactive {
            window.title = "GravityBox · 隔离 UI 预览（合成数据）"
            window.setFrame(NSRect(origin:window.frame.origin,size:NSSize(width:880,height:580)),display:true)
            window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps:true)
            withExtendedLifetime(assistant) { application.run() }
            return
        }
        // 非交互测试模式将窗口锚定在离屏坐标且不激活前台，避免测试期间在桌面闪现并切换页面
        func findViewById(_ root: NSView, _ id: String) -> NSView? {
            if root.identifier?.rawValue == id { return root }
            for sub in root.subviews {
                if let found = findViewById(sub, id) { return found }
            }
            return nil
        }
        func findFirst<T: NSView>(_ root: NSView, as type: T.Type) -> T? {
            if let match = root as? T { return match }
            for sub in root.subviews {
                if let found = findFirst(sub, as: type) { return found }
            }
            return nil
        }
        func findEnclosingBox(_ view: NSView) -> NSBox? {
            var cur: NSView? = view.superview
            while let v = cur {
                if let box = v as? NSBox { return box }
                cur = v.superview
            }
            return nil
        }
        func verifyOverviewHeaderGeometry(_ ov: DashboardPage, context: String) {
            guard let header = findViewById(ov.view, "account-identity-header"),
                  let actions = findViewById(ov.view, "account-actions") as? NSStackView,
                  let heroCard = findEnclosingBox(header) else {
                check(false, "\(context): missing overview account-identity-header / heroCard")
                return
            }
            let expectedActionsW = actions.arrangedSubviews.filter { !$0.isHidden }.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
                + CGFloat(max(0, actions.arrangedSubviews.filter { !$0.isHidden }.count - 1)) * actions.spacing
            check(abs(actions.frame.width - expectedActionsW) <= 1.0, "\(context): overview heroActions must hug button width (got \(actions.frame.width), expected \(expectedActionsW))")
            let btnRect = heroCard.convert(ov.refreshQuotaButton.bounds, from: ov.refreshQuotaButton)
            let expectedRight = heroCard.bounds.width - 14
            check(abs(btnRect.maxX - expectedRight) <= 1.0, "\(context): refreshQuotaButton must align to heroCard trailing edge (maxX=\(btnRect.maxX), expected=\(expectedRight))")
            if !ov.tierBadge.isHidden {
                let nameRect = header.convert(ov.activeAccountLabel.bounds, from: ov.activeAccountLabel)
                let tierRect = header.convert(ov.tierBadge.bounds, from: ov.tierBadge)
                let gap = tierRect.minX - nameRect.maxX
                check(gap >= 4 && gap <= 10, "\(context): tierBadge must sit beside activeAccountLabel instead of stretching right (gap=\(gap))")
            }
            if let nameFont = ov.activeAccountLabel.font, !ov.activeAccountLabel.stringValue.isEmpty {
                let neededNameW = ceil((ov.activeAccountLabel.stringValue as NSString).size(withAttributes: [.font: nameFont]).width)
                check(ov.activeAccountLabel.bounds.width >= neededNameW - 0.5, "\(context): activeAccountLabel truncated (\(ov.activeAccountLabel.bounds.width) < \(neededNameW) for '\(ov.activeAccountLabel.stringValue)')")
            }
            if !ov.activeEmailLabel.isHidden, let emailFont = ov.activeEmailLabel.font, !ov.activeEmailLabel.stringValue.isEmpty {
                let neededEmailW = ceil((ov.activeEmailLabel.stringValue as NSString).size(withAttributes: [.font: emailFont]).width)
                check(ov.activeEmailLabel.bounds.width >= neededEmailW - 0.5, "\(context): activeEmailLabel truncated (\(ov.activeEmailLabel.bounds.width) < \(neededEmailW) for '\(ov.activeEmailLabel.stringValue)')")
            }
        }
        func verifyAccountsCardsGeometry(_ page: AccountsPage, expectedCount: Int = 3, context: String) {
            check(page.cardsStack.arrangedSubviews.count == expectedCount, "\(context): expected \(expectedCount) account cards (got \(page.cardsStack.arrangedSubviews.count))")
            for (idx, boxView) in page.cardsStack.arrangedSubviews.enumerated() {
                guard let cardBox = boxView as? NSBox,
                      let header = findViewById(cardBox, "account-identity-header"),
                      let actions = findViewById(cardBox, "account-actions") as? NSStackView else {
                    continue
                }
                let visibleActions = actions.arrangedSubviews.filter { !$0.isHidden }
                check(!visibleActions.isEmpty, "\(context) card[\(idx)]: actionStack must have visible actions")
                let expectedActionsW = visibleActions.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
                    + CGFloat(max(0, visibleActions.count - 1)) * actions.spacing
                check(abs(actions.frame.width - expectedActionsW) <= 1.0, "\(context) card[\(idx)]: actionStack must hug visible buttons without absorbing empty space (got \(actions.frame.width), expected \(expectedActionsW))")
                if let lastBtn = visibleActions.last {
                    let btnRect = cardBox.convert(lastBtn.bounds, from: lastBtn)
                    let expectedRight = cardBox.bounds.width - 16
                    check(abs(btnRect.maxX - expectedRight) <= 1.0, "\(context) card[\(idx)]: trailing action must align to cardBox trailing edge (maxX=\(btnRect.maxX), expected=\(expectedRight))")
                }
                if let badge = findFirst(header, as: TierBadge.self), !badge.isHidden {
                    func allLabels(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap { allLabels($0) } }
                    if let nameLbl = allLabels(header).first(where: { $0.font?.pointSize ?? 0 >= 14.5 }) {
                        let nameRect = header.convert(nameLbl.bounds, from: nameLbl)
                        let badgeRect = header.convert(badge.bounds, from: badge)
                        let gap = badgeRect.minX - nameRect.maxX
                        check(gap >= 4 && gap <= 10, "\(context) card[\(idx)]: tierPill must stay beside name label (gap=\(gap))")
                        if let font = nameLbl.font, !nameLbl.stringValue.isEmpty {
                            let neededW = ceil((nameLbl.stringValue as NSString).size(withAttributes: [.font: font]).width)
                            check(nameLbl.bounds.width >= neededW - 0.5, "\(context) card[\(idx)]: account name truncated (\(nameLbl.bounds.width) < \(neededW))")
                        }
                    }
                }
            }
        }

        window.setFrameOrigin(NSPoint(x: -24000, y: -24000))
        var captures:[String] = []
        for (theme, appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named:appearance)
            for size in [NSSize(width:880,height:580),NSSize(width:960,height:640),NSSize(width:1100,height:760)] {
                window.setFrame(NSRect(origin:window.frame.origin,size:size),display:true)
                for page in 0..<5 {
                    assistant.selectPage(page); pump()
                    if page == 1 {
                        waitUntil(step: 0.01, description: "\(theme)-\(Int(size.width))x\(Int(size.height)) AccountsPage to settle \(accounts.count) cards") {
                            !assistant.accountListInFlight
                                && !assistant.accountListPendingRefetch
                                && assistant.accountsPage?.activeId == activeId
                                && assistant.accountsPage?.cardsStack.arrangedSubviews.count == accounts.count
                        }
                    } else if page == 2 {
                        waitUntil(step: 0.01, description: "\(theme)-\(Int(size.width))x\(Int(size.height)) UsagePage to finish loading") {
                            assistant.usagePage?.loading == false
                        }
                    }
                    window.contentView?.layoutSubtreeIfNeeded()
                    let name = "\(theme)-\(Int(size.width))x\(Int(size.height))-\(page).png"
                    try capture(window.contentView!,output.appendingPathComponent(name)); captures.append(name)
                    check(assistant.currentPage == page,"Navigation mismatch")
                    check(window.frame.width == size.width && (window.contentView?.fittingSize.width ?? 0) <= 880, "Page \(page) exceeds 880pt minimum window width")
                    if page == 0, size.width == 880, size.height == 580, let scroll = assistant.overview?.view as? NSScrollView, let document = scroll.documentView {
                        for card in [assistant.overview!.tokenMetricCard!, assistant.overview!.costMetricCard!, assistant.overview!.requestsMetricCard!] {
                            let rect = document.convert(card.bounds, from:card)
                            check(rect.minY >= scroll.contentView.bounds.minY-1 && rect.maxY <= scroll.contentView.bounds.maxY+1, "Minimum dashboard clips a metric card")
                        }
                    }
                    if page == 0, let ov = assistant.overview {
                        verifyOverviewHeaderGeometry(ov, context: "\(theme)-\(Int(size.width))x\(Int(size.height))")
                    }
                    if page == 1, let acc = assistant.accountsPage {
                        verifyAccountsCardsGeometry(acc, context: "\(theme)-\(Int(size.width))x\(Int(size.height))-expanded")
                    }
                    if page == 2 {
                        let usage = assistant.usagePage!
                        func labels(_ view:NSView)->[NSTextField] { (view as? NSTextField).map{[$0]} ?? view.subviews.flatMap{labels($0)} }
                        for targetName in ["gemini-3.8-flash-n", "gemini-3.8-flash-exp-a", "Claude Opus 5.5"] {
                            for label in labels(usage.donutLegendStack) where label.stringValue == targetName {
                                let width = (label.stringValue as NSString).size(withAttributes:[.font:label.font!]).width
                                check(label.bounds.width >= ceil(width), "Cost legend constrains model name \(targetName) at \(Int(size.width))pt width (\(label.bounds.width) < \(ceil(width)))")
                                check(label.bounds.height < 24, "Model label \(targetName) wrapped onto multiple lines at \(Int(size.width))pt width")
                            }
                        }
                        check(usage.costTitle.stringValue == "API费用估算" || usage.costTitle.stringValue == "今日费用估算" || usage.costTitle.stringValue == "API 费用估算","Title must remain API费用估算")
                        check(usage.statusSummary.stringValue.isEmpty && usage.footerBox.isHidden,"Partial pricing footer warning must stay hidden when all models are priced")
                        check(usage.donutLegendStack.fittingSize.width <= size.width-190,"Legend exceeds page")
                    }
                }
            }
            let policy = AccountPolicySheet(app:assistant,config:["strategy":"priority","monitored_model":"gemini","reserve_percentage":10,"candidate_min_percentage":30],saved:{})
            policy.show(in:window,onDismiss:{})
            policy.window.appearance = NSAppearance(named:appearance); pump()
            let policyMenuItems = policy.modelPopup.menu?.items ?? []
            check(policyMenuItems.filter { !$0.isSeparatorItem }.map(\.title) == ["全部主力模型","Gemini 全系（含 Argon）","Gemini（基础池）","Claude/GPT","Gemini 4 Argon"], "Model popup must expose adaptive Pro options with base/combined disambiguation")
            check(policyMenuItems.count == 6 && policyMenuItems[2].isSeparatorItem, "Model popup must separate combined and single-pool sections")
            check(policy.monitoredSubLabel.stringValue == "仅监测基础 Gemini 共享池，Pro 套餐下不含独立计费的 Argon", "Initial monitored scope subtitle explains Pro base Gemini boundary")
            if let geminiAllIdx = policyMenuItems.firstIndex(where: { ($0.representedObject as? String) == "gemini_all" }) {
                policy.modelPopup.selectItem(at: geminiAllIdx)
                policy.monitoredScopeChanged()
                check(policy.monitoredSubLabel.stringValue == "同时盯住基础 Gemini 与独立 Argon 周配额，任一偏低即提示切换", "Changing monitored scope updates subtitle live")
            } else {
                check(false, "Expected gemini_all menu item")
            }
            if let geminiIdx = policyMenuItems.firstIndex(where: { ($0.representedObject as? String) == "gemini" }) {
                policy.modelPopup.selectItem(at: geminiIdx)
                policy.monitoredScopeChanged()
            }
            check(policy.strategyPopup.frame.width == policy.modelPopup.frame.width, "Policy popups must share uniform width")
            check(policy.modelPopup.frame.width >= 150 && policy.modelPopup.frame.width <= 195, "Pro policy popups must tightly fit longest option without 220pt bloat (got \(policy.modelPopup.frame.width))")
            check(policy.modelPopup.frame.width >= Design.fittedPopUpWidth(policy.modelPopup) - 0.5 && policy.strategyPopup.frame.width >= Design.fittedPopUpWidth(policy.strategyPopup) - 0.5, "Policy popups must never truncate longest option")
            check((policy.window.contentView?.frame.height ?? 999) < 395, "Policy sheet content height must hug content instead of 436pt excess gap (got \(policy.window.contentView?.frame.height ?? -1))")
            check(policy.fieldsCard.frame.height <= (groupStack(policy.fieldsCard)?.fittingSize.height ?? 0) + 34, "Policy fields card must not leave blank space below 候选准入下限 (cardH=\(policy.fieldsCard.frame.height), stackFitH=\(groupStack(policy.fieldsCard)?.fittingSize.height ?? 0))")
            var dynamicAccount = accounts[0]
            dynamicAccount["standaloneModels"] = [
                ["key":"argon","displayName":"Gemini 4 Argon","availability":"available","quotaState":"known","period":"weekly","remaining":0.008],
                ["key":"carbon","displayName":"Gemini 4 Carbon","availability":"disabled","quotaState":"not_reported","period":"weekly"],
                ["key":"xenon","displayName":"Gemini 4 Xenon","availability":"available","quotaState":"known","period":"weekly","remaining":0.85]
            ]
            assistant.cachedAccounts = [dynamicAccount]
            let dynamicPolicy = AccountPolicySheet(app:assistant,config:["strategy":"priority","monitored_model":"xenon","reserve_percentage":10,"candidate_min_percentage":30],saved:{})
            check((dynamicPolicy.modelPopup.menu?.items ?? []).filter { !$0.isSeparatorItem }.map(\.title) == ["全部主力模型","Gemini 全系模型","Gemini（基础池）","Claude/GPT","Gemini 4 Argon","Gemini 4 Xenon"], "Model popup must auto-detect active standalone models while omitting disabled ones")
            check(dynamicPolicy.modelPopup.selectedItem?.title == "Gemini 4 Xenon", "Model popup must select configured dynamic model")
            check(dynamicPolicy.monitoredSubLabel.stringValue == "仅监测当前账号独立的 Gemini 4 Xenon 配额池", "Dynamic standalone scope shows targeted subtitle")
            assistant.cachedAccounts = accounts
            for popup in [policy.strategyPopup, policy.modelPopup] {
                check(popup.focusRingType == .none && popup.cell?.focusRingType == NSFocusRingType.none, "Installed popup cell must not restore the square focus bezel")
                check(popup.cell is DesignPopUpCell, "PopUp buttons must use DesignPopUpCell so menus drop cleanly below the control")
                let origin = Design.popUpOrigin(below: popup)
                check(origin.x == 0 && origin.y == popup.bounds.maxY + 6, "Flipped popup origin must place menu 6pt below control bottom")
            }
            let unflippedProbe = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 28))
            check(Design.popUpOrigin(below: unflippedProbe) == NSPoint(x: 0, y: -6), "Unflipped anchor origin must place menu 6pt below control bottom")
            policy.window.makeFirstResponder(policy.strategyPopup); pump()
            try capture(policy.window.contentView!,output.appendingPathComponent("\(theme)-policy-popup-focused.png"))
            policy.window.makeFirstResponder(policy.reserve); pump()
            check(policy.reserve.currentEditor()?.alignment == .center, "Threshold editor changed number alignment")
            try capture(policy.window.contentView!,output.appendingPathComponent("\(theme)-policy-threshold-focused.png"))
            policy.window.makeFirstResponder(policy.candidate); pump()
            check(policy.candidate.currentEditor()?.alignment == .center, "Candidate editor changed number alignment")
            try capture(policy.window.contentView!,output.appendingPathComponent("\(theme)-policy-candidate-focused.png"))
            policy.cancel(); waitForSheetDetach(on: window, description: "AccountPolicySheet to detach")
            check(LiveStatus().oauthClientConfigured == false, "LiveStatus default oauthClientConfigured must be false")
            check(LiveStatus(["mode": "adaptive"]).oauthClientConfigured == false, "LiveStatus missing oauthClientConfigured must default to false")
            check(LiveStatus(["oauthClientConfigured": true]).oauthClientConfigured == true, "LiveStatus explicit oauthClientConfigured=true must parse")

            func findLabels(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap { findLabels($0) } }
            func verifyLabelNotTruncated(_ label: NSTextField, context: String) {
                check(label.lineBreakMode != .byTruncatingMiddle, "\(context) must not middle-truncate")
                if let cell = label.cell {
                    let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude))
                    check(label.bounds.height >= floor(needed.height) - 1, "\(context) height truncated (\(label.bounds.height) < \(needed.height))")
                }
            }

            // 1) 三卡管理账号模式（第一卡「保存当前账号」主操作 + 第二卡「导入账号」 + 第三卡「导出账号」，彻底移除 Google OAuth 登录按钮）
            let prevStatusForAdd = assistant.statusValue
            assistant.statusValue = LiveStatus(fixtureStatus)
            check(assistant.statusValue.oauthClientConfigured == false, "Fixture default status must treat oauthClientConfigured as false")
            let addSheet = AddAccountSheet(app: assistant, accountCount: 3, saved: {})
            addSheet.show(in: window, onDismiss: {})
            addSheet.window.appearance = NSAppearance(named: appearance)
            addSheet.window.contentView?.layoutSubtreeIfNeeded(); pump()
            let singleContent = addSheet.window.contentView!
            check(!allTextValues(singleContent).contains { $0.contains("Google 授权登录") || $0.contains("Sign in with Google") }, "AddAccountSheet must not render removed Google OAuth button")
            check(addSheet.currentButton.isDescendant(of: singleContent) && addSheet.currentButton.isEnabled, "Three-card AddAccountSheet must present enabled currentButton")
            check(addSheet.importJsonButton.isDescendant(of: singleContent) && addSheet.importJsonButton.isEnabled, "Three-card AddAccountSheet must present enabled importJsonButton")
            check(addSheet.exportButton.isDescendant(of: singleContent) && addSheet.exportButton.isEnabled, "Three-card AddAccountSheet must present enabled exportButton when accounts exist")
            check(addSheet.currentButton.bezelColor == Design.blue && addSheet.currentButton.keyEquivalent == "\r", "Three-card currentButton must be primary blue Return button")
            check(addSheet.currentButton.toolTip == nil && addSheet.importJsonButton.toolTip == nil && addSheet.exportButton.toolTip == nil && addSheet.cancelButton.toolTip == nil, "AddAccountSheet buttons must not set toolTip")
            check(addSheet.window.initialFirstResponder === addSheet.currentButton && addSheet.window.firstResponder === addSheet.currentButton, "Initial focus must land on currentButton")
            let singleZhHeight = singleContent.frame.height
            check(singleZhHeight > 280 && singleZhHeight < 415, "Three-card AddAccountSheet height must be compact (got \(singleZhHeight))")
            let singleLabels = findLabels(singleContent)
            check(singleLabels.contains { $0.stringValue == "当前 Antigravity 账号" }, "AddAccountSheet must show current account card title")
            check(singleLabels.contains { $0.stringValue == "导入账号" }, "AddAccountSheet must show JSON import card title")
            check(singleLabels.contains { $0.stringValue == "导出账号" }, "AddAccountSheet must show JSON export card title")
            if let subLbl = singleLabels.first(where: { $0.stringValue == "导入当前 Antigravity 登录账号" }) {
                verifyLabelNotTruncated(subLbl, context: "Three-card zh save subtitle")
            } else {
                check(false, "AddAccountSheet missing zh save subtitle")
            }
            if let importSubLbl = singleLabels.first(where: { $0.stringValue == "支持导入 GravityBox 备份文件、单账号 JSON 或账号文件夹" }) {
                verifyLabelNotTruncated(importSubLbl, context: "Three-card zh import subtitle")
            } else {
                check(false, "AddAccountSheet missing zh import subtitle")
            }
            if let exportSubLbl = singleLabels.first(where: { $0.stringValue == "将已保存的 3 个账号导出为 JSON 文件（含登录凭据，请妥善保管）" }) {
                verifyLabelNotTruncated(exportSubLbl, context: "Three-card zh export subtitle")
            } else {
                check(false, "AddAccountSheet missing zh export subtitle")
            }
            check(singleLabels.contains { $0.stringValue == "alex@example.invalid" }, "AddAccountSheet must show copyable current email")
            check(!allTextValues(singleContent).contains { $0.localizedCaseInsensitiveContains("Insiders") }, "AddAccountSheet must not mention Insiders")
            try capture(singleContent, output.appendingPathComponent("\(theme)-add-account.png"))

            // 展开 feedback 与 busy 状态：同时禁用三个卡片按钮且高度紧贴内容
            addSheet.status.stringValue = "正在从 JSON 导入账号…"
            addSheet.busy(true); pump()
            check(!addSheet.currentButton.isEnabled && !addSheet.importJsonButton.isEnabled && !addSheet.exportButton.isEnabled, "Busy state must disable currentButton, importJsonButton, and exportButton")
            let singleBusyHeight = singleContent.frame.height
            check(singleBusyHeight > singleZhHeight + 8 && singleBusyHeight < 455, "Expanded feedback height must hug content (got \(singleBusyHeight))")
            addSheet.status.stringValue = ""
            addSheet.busy(false); pump()
            check(addSheet.currentButton.isEnabled && addSheet.importJsonButton.isEnabled && addSheet.exportButton.isEnabled, "Clearing busy state must re-enable all card buttons")
            check(abs(singleContent.frame.height - singleZhHeight) <= 1, "Collapsing feedback must restore compact three-card height")

            // 中英文热切换：三卡文案与按钮全部更新且高度自适应不截断
            L10n.shared.setLanguage("en", notify: true); pump()
            addSheet.window.contentView?.layoutSubtreeIfNeeded()
            let singleEnLabels = findLabels(singleContent)
            check(singleEnLabels.contains { $0.stringValue == "Current Antigravity Account" }, "English hot-switch must update card 1 title")
            check(singleEnLabels.contains { $0.stringValue == "Import Accounts" }, "English hot-switch must update card 2 title")
            check(singleEnLabels.contains { $0.stringValue == "Export Accounts" }, "English hot-switch must update card 3 title")
            check(addSheet.currentButton.title == "Save Current Account" && addSheet.importJsonButton.title == "Choose Files…" && addSheet.exportButton.title == "Export File…" && addSheet.cancelButton.title == "Cancel", "English hot-switch must update card and footer buttons")
            if let enSub = singleEnLabels.first(where: { $0.stringValue == "Import active Antigravity sign-in session" }) {
                verifyLabelNotTruncated(enSub, context: "Three-card en save subtitle")
            } else {
                check(false, "English hot-switch missing card 1 subtitle")
            }
            if let enImportSub = singleEnLabels.first(where: { $0.stringValue == "Import GravityBox backup files, single-account JSON files, or a folder" }) {
                verifyLabelNotTruncated(enImportSub, context: "Three-card en import subtitle")
            } else {
                check(false, "English hot-switch missing card 2 subtitle")
            }
            if let enExportSub = singleEnLabels.first(where: { $0.stringValue == "Export 3 saved account(s) as a JSON file (includes credentials; store securely)" }) {
                verifyLabelNotTruncated(enExportSub, context: "Three-card en export subtitle")
            } else {
                check(false, "English hot-switch missing card 3 subtitle")
            }
            check(singleContent.frame.height < 425, "Three-card English sheet height must remain compact (got \(singleContent.frame.height))")
            L10n.shared.setLanguage("zh-Hans", notify: true); pump()
            addSheet.dismiss(); waitForSheetDetach(on: window, description: "AddAccountSheet to detach")

            // 2) 0 账号时导出按钮自动禁用；同时验证导入与导出控制流
            let emptyManageSheet = AddAccountSheet(app: assistant, accountCount: 0, saved: {})
            check(!emptyManageSheet.exportButton.isEnabled, "Export button must be disabled when 0 accounts are saved")
            emptyManageSheet.busy(false)
            check(!emptyManageSheet.exportButton.isEnabled, "Clearing busy state must keep export button disabled when 0 accounts are saved")

            var oauthStatusRaw = fixtureStatus
            oauthStatusRaw["oauthClientConfigured"] = true
            let withOAuthStatus = LiveStatus(oauthStatusRaw)
            let mergedWithoutOAuthField = assistant.mergeStatusSnapshot(["mode": "connected"], previous: withOAuthStatus)
            check(mergedWithoutOAuthField.oauthClientConfigured == true, "mergeStatusSnapshot must preserve oauthClientConfigured when omitted from partial status payloads")
            assistant.statusValue = withOAuthStatus
            var importSavedCallbackFired = false
            var expiredNoticeCaptured: (String, String)? = nil
            let oauthSheet = AddAccountSheet(app: assistant, accountCount: 3, saved: { importSavedCallbackFired = true })
            oauthSheet.show(in: window, onDismiss: {})
            oauthSheet.window.appearance = NSAppearance(named: appearance)
            oauthSheet.window.contentView?.layoutSubtreeIfNeeded(); pump()
            let oauthContent = oauthSheet.window.contentView!
            check(oauthSheet.currentButton.isDescendant(of: oauthContent) && oauthSheet.importJsonButton.isDescendant(of: oauthContent) && oauthSheet.exportButton.isDescendant(of: oauthContent), "AddAccountSheet must keep three-card layout regardless of oauthClientConfigured")
            check(!allTextValues(oauthContent).contains { $0.contains("Google 授权登录") || $0.contains("Sign in with Google") }, "AddAccountSheet must never show removed Google OAuth button")
            let prevFixtureReplyForImport = assistant.bridge.fixtureReply
            var exportedPayloadFromSheet: [String: Any]? = nil
            assistant.bridge.fixtureReply = { payload in
                if (payload["command"] as? String) == "account_import_json" {
                    return ["ok": true, "imported": 2, "updated": 1, "skipped": [["source": "bad.json", "reason": "缺少有效的 refresh_token"]], "expiredWithoutRefreshConfig": 1]
                }
                if (payload["command"] as? String) == "account_export_backup" {
                    exportedPayloadFromSheet = payload
                    return ["ok": true, "path": payload["path"] as? String ?? "", "count": 3]
                }
                return prevFixtureReplyForImport?(payload) ?? ["ok": true]
            }
            oauthSheet.filePickerHook = { [URL(fileURLWithPath: "/tmp/mock-accounts-backup.json")] }
            oauthSheet.expiredNoticeHook = { title, body in expiredNoticeCaptured = (title, body) }
            oauthSheet.importFromJson(); pump()
            check(importSavedCallbackFired, "Successful JSON import must trigger saved callback")
            check(expiredNoticeCaptured?.0 == "部分导入账号的短期凭据已过期" && (expiredNoticeCaptured?.1.contains("1 个账号") == true), "JSON import with expiredWithoutRefreshConfig > 0 must surface expired credential notice")

            let exportSheet = AddAccountSheet(app: assistant, accountCount: 3, saved: {})
            exportSheet.show(in: window, onDismiss: {})
            exportSheet.exportConfirmHook = { true }
            exportSheet.exportSavePanelHook = { defaultName in
                check(defaultName.hasPrefix("gravitybox-accounts-backup-") && defaultName.hasSuffix(".json"), "Export accounts default filename must match gravitybox-accounts-backup-YYYYMMDD.json")
                return URL(fileURLWithPath: "/tmp/\(defaultName)")
            }
            exportSheet.exportAccounts(); pump()
            assistant.bridge.fixtureReply = prevFixtureReplyForImport
            check((exportedPayloadFromSheet?["confirmed"] as? Bool) == true && (exportedPayloadFromSheet?["path"] as? String)?.hasPrefix("/tmp/gravitybox-accounts-backup-") == true, "Export accounts inside Manage Accounts sheet must send account_export_backup with confirmed: true")
            exportSheet.dismiss(); waitForSheetDetach(on: window, description: "Export AddAccountSheet to detach")
            assistant.statusValue = prevStatusForAdd
            let logSheet = UsageLogController(app:assistant,period:"today")
            logSheet.show(in:window,onDismiss:{})
            logSheet.sheet.appearance = NSAppearance(named:appearance); pump()
            check(logSheet.refreshButton.title == "刷新" && logSheet.exportButton.title == "导出…", "UsageLogController must unify refresh and export buttons")
            logSheet.sheet.makeFirstResponder(logSheet.pageNumber); pump()
            check(logSheet.pageNumber.currentEditor()?.alignment == .center, "Page number editor must stay centered")
            logSheet.sheet.makeFirstResponder(nil); pump()
            try capture(logSheet.sheet.contentView!,output.appendingPathComponent("\(theme)-usage-log.png"))
            logSheet.closeSheet(); waitForSheetDetach(on: window, description: "UsageLogController to detach")
            assistant.selectPage(3); pump()
            let maintSheet = assistant.preferencesController?.maintenanceSheet ?? MaintenanceSheetController(app: assistant)
            maintSheet.sheet.appearance = NSAppearance(named: appearance)
            maintSheet.cachePage.fetch(force: true); pump()
            waitUntil(step: 0.01, description: "maintSheet initial scan to complete") { !maintSheet.cachePage.busy }
            maintSheet.sheet.contentView?.layoutSubtreeIfNeeded(); pump()
            check(maintSheet.sheet.frame.width == MaintenanceSheetController.sheetWidth, "Maintenance sheet must use compact 620pt width")
            check(maintSheet.cachePage.retentionPopup.itemTitles == ["清理 7 天前", "清理 30 天前", "清理全部非活跃"], "Maintenance sheet must expose 3 inline retention window choices")
            check(maintSheet.cachePage.retentionPopup.fittingSize.width <= 126 && maintSheet.cachePage.retentionPopup.fittingSize.width >= Design.fittedPopUpWidth(maintSheet.cachePage.retentionPopup) - 0.5, "Maintenance retentionPopup must tightly fit longest option without excess width (got \(maintSheet.cachePage.retentionPopup.fittingSize.width), expected ~\(Design.fittedPopUpWidth(maintSheet.cachePage.retentionPopup)))")
            check(maintSheet.cachePage.historySubtitleLabel.stringValue.contains("保留近 7 天"), "Maintenance 7d retention must disclose 7-day preservation: \(maintSheet.cachePage.historySubtitleLabel.stringValue)")
            maintSheet.cachePage.retentionPopup.selectItem(at: 1)
            maintSheet.cachePage.retentionWindowChanged(); pump()
            waitUntil(step: 0.01, description: "maintSheet 30d retention scan to complete") { !maintSheet.cachePage.busy }
            maintSheet.sheet.contentView?.layoutSubtreeIfNeeded()
            check(maintSheet.cachePage.historySubtitleLabel.stringValue.contains("保留近 30 天"), "Maintenance 30d retention must dynamically disclose 30-day preservation: \(maintSheet.cachePage.historySubtitleLabel.stringValue)")
            maintSheet.cachePage.retentionPopup.selectItem(at: 2)
            maintSheet.cachePage.retentionWindowChanged(); pump()
            waitUntil(step: 0.01, description: "maintSheet 0d retention scan to complete") { !maintSheet.cachePage.busy }
            maintSheet.sheet.contentView?.layoutSubtreeIfNeeded()
            check(maintSheet.cachePage.historySubtitleLabel.stringValue.contains("清理所有非活跃对话"), "Maintenance 0d retention must dynamically explain all inactive cleanup: \(maintSheet.cachePage.historySubtitleLabel.stringValue)")
            let zeroDayNatW = (maintSheet.cachePage.historySubtitleLabel.stringValue as NSString).size(withAttributes: [.font: maintSheet.cachePage.historySubtitleLabel.font!]).width
            check(maintSheet.cachePage.historySubtitleLabel.bounds.width + 1.5 >= floor(zeroDayNatW), "Maintenance 0d historySubtitleLabel must not truncate (\(maintSheet.cachePage.historySubtitleLabel.stringValue)): \(maintSheet.cachePage.historySubtitleLabel.bounds.width) < \(zeroDayNatW)")
            maintSheet.cachePage.retentionPopup.selectItem(at: 0)
            maintSheet.cachePage.retentionWindowChanged(); pump()
            waitUntil(step: 0.01, description: "maintSheet 7d restore scan to complete") { !maintSheet.cachePage.busy }
            maintSheet.sheet.contentView?.layoutSubtreeIfNeeded()
            check(maintSheet.cachePage.runtimeCacheSwitch.state == .on && maintSheet.cachePage.historyLogsSwitch.state == .off, "Maintenance default switches must enable runtime cache and keep history logs off")
            check(maintSheet.cachePage.selectedScopes == ["runtime_cache"], "Maintenance default selectedScopes must contain runtime_cache only")
            check(maintSheet.cachePage.clearButton.isEnabled && maintSheet.cachePage.clearButton.title == "一键清理", "Maintenance primary CTA must display 一键清理")
            check(!maintSheet.cachePage.restoreLatestButton.isHidden && maintSheet.cachePage.restoreLatestButton.title == "撤回上次清理", "Maintenance footer card must expose single-click 撤回上次清理 when restorable snapshot exists")
            check(!maintSheet.cachePage.sheetDoneButton.isHidden && maintSheet.cachePage.sheetDoneButton.title == "完成", "Maintenance sheet must display 完成 button")
            check(maintSheet.cachePage.sheetDoneButton.frame.minY < maintSheet.cachePage.view.frame.minY, "Maintenance 完成 button must sit in pinned bottom footer below card area")
            check(maintSheet.cachePage.sheetDoneButton.frame.maxX >= maintSheet.cachePage.clearButton.frame.minX, "Maintenance 完成 button must align at bottom-right")
            for maintLbl in [maintSheet.cachePage.reclaimableTitleLabel, maintSheet.cachePage.reclaimableValueLabel, maintSheet.cachePage.heroSubtitleLabel, maintSheet.cachePage.safeLegendLabel, maintSheet.cachePage.statefulLegendLabel, maintSheet.cachePage.protectedLegendLabel, maintSheet.cachePage.runtimeTitleLabel, maintSheet.cachePage.runtimeSubtitleLabel, maintSheet.cachePage.historyTitleLabel, maintSheet.cachePage.historySubtitleLabel, maintSheet.cachePage.recoveryTitleLabel, maintSheet.cachePage.recoverySubtitleLabel] where !maintLbl.isHidden && !maintLbl.stringValue.isEmpty {
                let natW = (maintLbl.stringValue as NSString).size(withAttributes: [.font: maintLbl.font!]).width
                check(maintLbl.bounds.width + 1.5 >= floor(natW), "Maintenance label must not truncate (\(maintLbl.stringValue)): \(maintLbl.bounds.width) < \(natW)")
            }
            try capture(maintSheet.sheet.contentView!, output.appendingPathComponent("\(theme)-maintenance-sheet.png"))
            maintSheet.closeSheet(); pump()
            let allAccounts = accounts
            accounts = [allAccounts[2]]; activeId = "c"; assistant.activeAccountId = "c"; assistant.cachedAccounts = accounts
            window.setFrame(NSRect(origin:window.frame.origin,size:NSSize(width:880,height:580)),display:true)
            assistant.selectPage(1); pump()
            assistant.accountsPage?.fetch()
            waitUntil(step: 0.01, description: "AccountsPage activeId to sync to c") {
                !assistant.accountListInFlight
                    && !assistant.accountListPendingRefetch
                    && assistant.accountsPage?.activeId == "c"
                    && assistant.accountsPage?.cardsStack.arrangedSubviews.count == 1
            }
            func quotaBars(_ view:NSView)->[QuotaBarView] { (view as? QuotaBarView).map{[$0]} ?? view.subviews.flatMap{quotaBars($0)} }
            let modelBars = quotaBars(window.contentView!).filter{$0.titleLabel.stringValue.contains("模型配额")}
            check(modelBars.count == 2 && modelBars.allSatisfy{$0.percentageKnown && $0.percentage == 100}, "FREE model quota must render known on both account rows")
            for bar in modelBars where !bar.resetLabel.stringValue.isEmpty {
                let naturalW = (bar.resetLabel.stringValue as NSString).size(withAttributes: [.font: bar.resetLabel.font!]).width
                check(bar.resetLabel.bounds.width + 1.0 >= floor(naturalW), "Model quota resetLabel (\(bar.resetLabel.stringValue)) must not truncate at 880pt minimum width (\(bar.resetLabel.bounds.width) < \(naturalW))")
            }
            check(assistant.accountsPage?.activeId == "c", "AccountsPage must preserve configured activeId when liveAccountEmail is not in saved accounts")
            try capture(window.contentView!,output.appendingPathComponent("\(theme)-free-model-quota.png"))
            let freeMenuPanel = MenuPanelController(app: assistant)
            let freeHost = makeHeadlessHostWindow(width: MenuPanelController.panelWidth, height: MenuPanelController.defaultPanelHeight)
            freeHost.appearance = NSAppearance(named: appearance)
            freeHost.contentViewController = freeMenuPanel
            freeMenuPanel.selectTab(1, persist: false); freeMenuPanel.panelWillOpen(); pump()
            freeHost.setContentSize(freeMenuPanel.preferredContentSize); freeHost.contentView?.layoutSubtreeIfNeeded(); pump()
            check(freeMenuPanel.quotaEmailLabel.stringValue == "charlie@example.invalid", "Full email lost on MenuPanelController")
            check(freeMenuPanel.quotaGemini5h.titleLabel.stringValue == "模型配额" && freeMenuPanel.quotaGemini5h.valueLabel.stringValue == "100%", "Menu must show FREE model quota")
            check(freeMenuPanel.quotaClaude5h.resetLabel.stringValue.contains("6天23小时"), "Menu must preserve the real long model reset")
            try capture(freeHost.contentView!,output.appendingPathComponent("\(theme)-free-model-menu.png"))
            freeHost.orderOut(nil)
            waitUntil(step: 0.01, description: "freeMenuPanel account_list requests to settle before restoring 3 accounts") {
                !assistant.accountListInFlight && !assistant.accountListPendingRefetch
            }
            accounts = allAccounts; activeId = "a"; assistant.activeAccountId = "a"; assistant.cachedAccounts = accounts
            assistant.accountsPage?.fetch()
            waitUntil(step: 0.01, description: "AccountsPage to restore all 3 accounts and activeId a") {
                !assistant.accountListInFlight
                    && !assistant.accountListPendingRefetch
                    && assistant.accountsPage?.activeId == "a"
                    && assistant.accountsPage?.cardsStack.arrangedSubviews.count == 3
            }
        }
        assistant.accountsPage!.fetch(); pump()
        waitUntil(step: 0.01, description: "AccountsPage initial 3 cards before countdown tick") {
            !assistant.accountListInFlight
                && !assistant.accountListPendingRefetch
                && assistant.accountsPage?.cardsStack.arrangedSubviews.count == 3
        }
        let initialCards = assistant.accountsPage!.cardsStack.arrangedSubviews
        check(initialCards.count == 3, "Expected 3 account cards before countdown tick")
        accounts[0]["geminiFiveHourResetCountdown"] = "1小时59分后重置"
        assistant.accountsPage!.fetch(); pump()
        waitUntil(step: 0.01, description: "AccountsPage countdown tick fetch to settle") {
            !assistant.accountListInFlight && !assistant.accountListPendingRefetch
        }
        let updatedCards = assistant.accountsPage!.cardsStack.arrangedSubviews
        check(updatedCards.count == initialCards.count && zip(initialCards, updatedCards).allSatisfy { $0 === $1 }, "Countdown tick must update account cards in place without rebuilding card views")
        assistant.preferencesController?.showMaintenanceSheet(); pump()
        let liveCache = assistant.cachePage!
        let initialScopeRows = liveCache.scopeStack.arrangedSubviews
        liveCache.fetch(force: true); pump()
        waitUntil(step: 0.01, description: "liveCache scan to settle") { !liveCache.busy }
        let updatedScopeRows = liveCache.scopeStack.arrangedSubviews
        check(updatedScopeRows.count == 3 && zip(initialScopeRows, updatedScopeRows).allSatisfy { $0 === $1 }, "3-card CachePage must retain fixed 2-switch scope views across scans without rebuilding")
        let baseSelectedBytes = liveCache.selectedReclaimableBytes
        let baseConfirmBody = liveCache.buildRunningClearConfirmationBody()
        check(baseConfirmBody.contains("4") && (baseConfirmBody.contains("3,842") || baseConfirmBody.contains("3842")), "Stage-2 running confirmation must dynamically disclose selected category and file counts: \(baseConfirmBody)")
        liveCache.runtimeInfoButton.performClick(nil); pump()
        check(liveCache.activePopoverKind == .runtime && liveCache.detailPopover?.behavior == .transient && liveCache.runtimeInfoButton.isActivePopover, "Clicking runtimeInfoButton must open transient runtime NSPopover")
        let rtPopTexts = allTextValues(liveCache.detailPopover!.contentViewController!.view)
        check(rtPopTexts.contains("应用运行缓存明细") && rtPopTexts.contains("网络与静态资源缓存") && rtPopTexts.contains("浏览器沙箱加速缓存"), "Runtime popover must render itemized cache titles: \(rtPopTexts)")
        liveCache.legendProtectedTrigger.performClick(nil); pump()
        check(liveCache.activePopoverKind == .protected && !liveCache.runtimeInfoButton.isActivePopover && liveCache.legendProtectedTrigger.isActivePopover, "Clicking protected legend must replace runtime popover with protected popover")
        let protPopTexts = allTextValues(liveCache.detailPopover!.contentViewController!.view)
        check(protPopTexts.contains("受自动保护的核心数据") && protPopTexts.contains("永不触碰") && protPopTexts.contains("工作区与核心账号凭据") && protPopTexts.contains("Agent 历史对话与上下文库"), "Protected popover must render positive core-data inventory: \(protPopTexts)")
        liveCache.historyInfoButton.performClick(nil); pump()
        check(liveCache.activePopoverKind == .history && liveCache.historyInfoButton.isActivePopover, "Clicking historyInfoButton must open history logs popover")
        let histPopTexts = allTextValues(liveCache.detailPopover!.contentViewController!.view)
        check(histPopTexts.contains { $0.contains("后台运行日志明细") } && histPopTexts.contains("历史子智能体轨迹库") && histPopTexts.contains { $0.contains("账单保护") }, "History popover must disclose subagent DBs and billing archive guard: \(histPopTexts)")
        liveCache.recoveryTriggerView.performClick(nil); pump()
        check(liveCache.activePopoverKind == .snapshot && liveCache.recoveryTriggerView.isActivePopover, "Clicking recoveryTriggerView with restorable snapshot must open snapshot audit popover")
        let snapPopTexts = allTextValues(liveCache.detailPopover!.contentViewController!.view)
        check(snapPopTexts.contains("上次清理快照清单") && snapPopTexts.contains("网络与静态资源缓存") && snapPopTexts.contains { $0.contains("3,180") || $0.contains("3180") }, "Snapshot popover must disclose staged file count and item titles: \(snapPopTexts)")
        liveCache.recoveryTriggerView.performClick(nil); pump()
        check(liveCache.activePopoverKind == nil && liveCache.detailPopover == nil, "Clicking same trigger again must toggle popover closed")
        liveCache.historyLogsSwitch.state = .on
        liveCache.historyScopeToggled()
        let combinedConfirmBody = liveCache.buildRunningClearConfirmationBody()
        check(liveCache.selectedScopes == ["runtime_cache", "history_logs"] && liveCache.selectedReclaimableBytes > baseSelectedBytes && combinedConfirmBody.contains("6") && (combinedConfirmBody.contains("4,964") || combinedConfirmBody.contains("4964")), "Toggling historyLogsSwitch on must dynamically add history_logs scope, Hero bytes, and confirmation counts")
        liveCache.historyLogsSwitch.state = .off
        liveCache.historyScopeToggled()
        check(liveCache.selectedScopes == ["runtime_cache"] && liveCache.selectedReclaimableBytes == baseSelectedBytes, "Toggling historyLogsSwitch off must restore runtime_cache-only Hero bytes")
        assistant.preferencesController?.maintenanceSheet?.closeSheet(); waitForSheetDetach(on: window, description: "MaintenanceSheetController to detach")

        // Verify three-tab MenuPanelController (用量｜配额｜账号)
        let menuPanel = assistant.ensureMenuPanelController()
        let panelHost = makeHeadlessHostWindow(width: MenuPanelController.panelWidth, height: MenuPanelController.defaultPanelHeight)
        panelHost.contentViewController = menuPanel
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            panelHost.appearance = NSAppearance(named: appearance)
            menuPanel.selectTab(0, persist: false); menuPanel.panelWillOpen(); pump()
            panelHost.setContentSize(menuPanel.preferredContentSize); panelHost.contentView?.layoutSubtreeIfNeeded(); pump()
            check(menuPanel.brandLabel.superview?.superview?.superview?.frame.maxY == menuPanel.view.bounds.height, "Header bar must stay pinned to the top edge on Usage tab")
            try capture(panelHost.contentView!, output.appendingPathComponent("\(theme)-menu-panel-usage.png"))
            menuPanel.selectTab(1, persist: false); pump()
            panelHost.setContentSize(menuPanel.preferredContentSize); panelHost.contentView?.layoutSubtreeIfNeeded(); pump()
            check(menuPanel.brandLabel.superview?.superview?.superview?.frame.maxY == menuPanel.view.bounds.height, "Header bar must stay pinned to the top edge on Quota tab")
            try capture(panelHost.contentView!, output.appendingPathComponent("\(theme)-menu-panel-quota.png"))
            menuPanel.selectTab(2, persist: false); pump()
            panelHost.setContentSize(menuPanel.preferredContentSize); panelHost.contentView?.layoutSubtreeIfNeeded(); pump()
            check(menuPanel.brandLabel.superview?.superview?.superview?.frame.maxY == menuPanel.view.bounds.height, "Header bar must stay pinned to the top edge on Accounts tab")
            try capture(panelHost.contentView!, output.appendingPathComponent("\(theme)-menu-panel-accounts.png"))
        }
        menuPanel.selectTab(0, persist: false); menuPanel.panelWillOpen(); pump()
        let multiModelHeight = menuPanel.preferredContentSize.height
        check(menuPanel.selectedTab == 0, "Menu panel must default to Usage tab (0)")
        check(menuPanel.usageFooterLabel.stringValue.hasPrefix("更新于 "), "Menu usage footer must use concise 更新于 timestamp")
        check(menuPanel.usageFooterLabel.superview === menuPanel.usageRoot, "Menu usage footer must reside directly in usageRoot, outside modelsCard")
        check(menuPanel.tokensTile.valueLabel.stringValue == "98.2M", "Menu usage tab must match Usage KPI tokens")
        check(menuPanel.requestsTile.valueLabel.stringValue == "756", "Menu usage tab must match Usage KPI requests")
        check(menuPanel.costTile.valueLabel.stringValue == "$23.78", "Menu usage tab must match Usage KPI cost")
        check(menuPanel.tokensTile.toolTip == nil, "Tokens tile must not have tooltip per requirement")
        let metricTiles = [menuPanel.tokensTile, menuPanel.requestsTile, menuPanel.costTile, menuPanel.cacheTile]
        for tile in metricTiles {
            check(tile.iconView.image != nil, "\(tile.metricKey) tile must contain micro colored SF Symbol")
            check(tile.frame.height >= 54 && tile.frame.height <= 56, "\(tile.metricKey) tile must maintain 54~56pt compact height")
            check(tile.accessibilityRole() == .group, "\(tile.metricKey) tile must be a read-only group, not interactive button")
            check(!((tile as AnyObject) is NSControl), "\(tile.metricKey) tile must not inherit from NSControl")
            check(tile.titleLabel.font?.pointSize == 11.5, "\(tile.metricKey) tile title font must be 11.5pt")
            check(tile.valueLabel.font?.pointSize == 20, "\(tile.metricKey) tile value font must be 20pt")
            func subviewsRecursive(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap { subviewsRecursive($0) } }
            let allSubviews = subviewsRecursive(tile)
            check(allSubviews.filter { $0 is NSImageView }.count == 1, "\(tile.metricKey) tile must contain only 1 micro icon and no chevron arrow")
            let visibleTextFields = allSubviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden && !($0.superview?.isHidden ?? false) }
            check(visibleTextFields.count == 2 && tile.statusBadge.isHidden, "\(tile.metricKey) tile must contain only title and value visible labels when status badge is hidden")
        }
        panelHost.appearance = NSAppearance(named: .aqua); panelHost.contentView?.layoutSubtreeIfNeeded(); pump()
        check(menuPanel.contentScroll.contentView.frame.width == MenuPanelController.panelWidth && (menuPanel.contentScroll.verticalScroller?.frame.width ?? 0) == 0, "Menu panel content must never reserve a scroller gutter or squeeze content width")
        menuPanel.selectChartDimension(.requests, persist: false)
        check(menuPanel.trendChart.dimension == .requests, "Menu trend chart must support switching to requests dimension")
        menuPanel.selectChartDimension(.tokens, persist: false)
        let baselineUsageFitHeight = menuPanel.usageRoot.fittingSize.height
        let samplePt = menuPanel.trendChart.convert(NSPoint(x: 60, y: 40), to: nil)
        let hoverEvent = NSEvent.mouseEvent(with: .mouseMoved, location: samplePt, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        menuPanel.trendChart.mouseMoved(with: hoverEvent)
        check(menuPanel.trendChart.toolTip == nil, "Menu trend chart must not have hover tooltip per requirement")
        check(menuPanel.trendCoverageLabel.alphaValue == 1.0, "Trend coverage label must be visible on hover")
        check(menuPanel.usageRoot.fittingSize.height == baselineUsageFitHeight, "Menu usage view fitting height must remain stable on trend hover without jitter")
        menuPanel.trendChart.resetHoverState()
        check(menuPanel.trendCoverageLabel.alphaValue == 0.0, "Trend coverage label must be hidden when hover resets")
        check(menuPanel.usageRoot.fittingSize.height == baselineUsageFitHeight, "Menu usage view fitting height must remain stable after hover reset")
        check(!menuPanel.toggleModelsButton.isHidden && menuPanel.toggleModelsButton.title.contains("展开其余 1 个模型"), "Menu model list must default to top 3 and offer inline expansion")
        let firstThreeModels = Array(menuPanel.modelsListStack.arrangedSubviews.prefix(3))
        menuPanel.toggleAllModelsPressed()
        check(menuPanel.showAllModels && menuPanel.toggleModelsButton.title.contains("收起"), "Menu model list must expand all models in place")
        check(zip(firstThreeModels, menuPanel.modelsListStack.arrangedSubviews.prefix(3)).allSatisfy { $0 === $1 }, "Expanding model list must reuse existing model row views without rebuilding")
        for sub in menuPanel.modelsListStack.arrangedSubviews {
            guard let modelRow = sub as? MenuModelUsageRow else { continue }
            check(!((modelRow as AnyObject) is NSControl), "MenuModelUsageRow must be a read-only NSView, not NSControl")
            check(modelRow.accessibilityRole() == .group, "MenuModelUsageRow must have group accessibility role")
            func rowSubviews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap { rowSubviews($0) } }
            let subs = rowSubviews(modelRow)
            check(subs.filter { $0 is NSButton }.isEmpty, "MenuModelUsageRow must contain 0 NSButtons (no headerButton)")
            check(subs.filter { $0 is NSImageView }.count == 1, "MenuModelUsageRow must contain only 1 icon and no chevronView")
            let visibleRowTextFields = subs.compactMap { $0 as? NSTextField }.filter { !$0.isHidden && !($0.superview?.isHidden ?? false) }
            check(visibleRowTextFields.count == 2 && modelRow.statusBadge.isHidden, "MenuModelUsageRow must contain exactly 2 visible labels without detailLabel when statusBadge is hidden")
            check(subs.filter { $0 is MenuMeterBar }.count == 1, "MenuModelUsageRow must contain shareBar")
        }
        check(menuPanel.contentScroll.contentView.frame.width == MenuPanelController.panelWidth && (menuPanel.contentScroll.verticalScroller?.frame.width ?? 0) == 0, "Expanded menu panel must never reserve a scroller gutter or squeeze content width")
        menuPanel.toggleAllModelsPressed()
        // Verify single-model Usage tab shrinks height to fit content with zero bottom blank gap
        if var singleModelReport = assistant.cachedUsageReportsByPeriod["today"] {
            singleModelReport["byModel"] = [models[0]]
            singleModelReport["snapshotId"] = "single-model-snap"
            assistant.cachedUsageReportsByPeriod["today"] = singleModelReport
            menuPanel.onUsageReportUpdated(period: "today", result: .success(singleModelReport))
            panelHost.appearance = NSAppearance(named: .aqua)
            panelHost.setContentSize(menuPanel.preferredContentSize); panelHost.contentView?.layoutSubtreeIfNeeded(); pump()
            check(menuPanel.preferredContentSize.height < multiModelHeight - 60, "Single-model usage tab must shrink height to eliminate bottom blank space")
            try capture(panelHost.contentView!, output.appendingPathComponent("light-menu-panel-usage-single-model.png"))
        }
        menuPanel.selectTab(1, persist: false); pump()
        check(menuPanel.selectedTab == 1 && menuPanel.headerRefreshButton.title == "刷新" && menuPanel.headerRefreshButton.toolTip == nil, "Quota tab must keep fixed button title and zero hover tooltip")
        check(menuPanel.quotaAccountNameLabel.stringValue == "Alex" && menuPanel.quotaGemini5h.valueLabel.stringValue == "91%", "Quota tab must display active account identity and contract quota")
        check(menuPanel.quotaStatusBadge.isHidden, "Quota tab must hide redundant current/selected pill badge when live account matches")
        let quotaGroupTexts = allTextValues(menuPanel.quotaGroupsContainer)
        check(quotaGroupTexts.contains("Gemini 4 Argon") && !quotaGroupTexts.contains("Gemini 4 Carbon"), "PRO menu quota tab must render real Argon without synthesizing fake Carbon")
        check(!quotaGroupTexts.contains(where: { $0.contains("周期未知") }), "Menu quota tab must never display 周期未知")
        check(menuPanel.quotaFooterLabel.stringValue.hasPrefix("更新于 ") && !menuPanel.quotaFooterLabel.stringValue.contains("采样于"), "Quota tab footer must use concise 更新于 timestamp")
        check(menuPanel.quotaFooterLabel.superview === menuPanel.quotaRoot, "Quota tab footer must reside directly in quotaRoot")
        menuPanel.selectTab(2, persist: false); pump()
        check(menuPanel.selectedTab == 2 && menuPanel.headerRefreshButton.title == "刷新" && menuPanel.headerRefreshButton.toolTip == nil, "Accounts tab must keep fixed button title and zero hover tooltip")
        check(menuPanel.accountsCountLabel.stringValue == "3 个账号" && menuPanel.expandedAccountIds.contains("a"), "Accounts tab must list all accounts with active account expanded")
        menuPanel.toggleAccountExpanded("b")
        check(menuPanel.expandedAccountIds.contains("b"), "Clicking backup account row must expand its 5-window quota details without switching")
        for sub in menuPanel.accountsCardsStack.arrangedSubviews {
            if let card = sub as? MenuExpandableAccountCardView {
                check(card.stateButton.frame.width >= 16 && card.stateButton.frame.origin.x >= 0, "Account card stateButton must be clearly visible and uncrushed")
                check(card.nameLabel.frame.width >= 20, "Account card nameLabel must not be compressed down to ellipsis")
                let headerStack = card.headerButton.subviews.compactMap { $0 as? NSStackView }.first
                check(headerStack?.arrangedSubviews.count == 2, "Account card header stack must contain exactly 2 arranged subviews (topTitleRow and emailLabel), summaryLabel must be removed")
                check(headerStack?.arrangedSubviews.contains(card.emailLabel) == true, "Account card header stack must contain emailLabel")
                func cardSubviews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap { cardSubviews($0) } }
                let allHeaderLabels = cardSubviews(card.headerButton).compactMap { $0 as? NSTextField }
                check(allHeaderLabels.allSatisfy { !$0.stringValue.contains("小时") && !$0.stringValue.contains("每周") }, "Account card header must not duplicate text quota summary")
            }
        }
        var switchedAccountId: String? = nil
        var toggledAccountId: String? = nil
        if let firstCard = menuPanel.accountsCardsStack.arrangedSubviews.first as? MenuExpandableAccountCardView {
            let firstTexts = allTextValues(firstCard)
            check(!firstTexts.contains("当前账号") && !firstTexts.contains("已选记录"), "Menu accounts first card must not display redundant 当前账号 or 已选记录 pill")
            firstCard.onSwitchAccount = { switchedAccountId = $0 }
            firstCard.onToggleExpand = { toggledAccountId = $0 }
            firstCard.headerButton.performClick(nil)
            check(toggledAccountId == firstCard.accountId && switchedAccountId == nil, "Clicking account header must toggle expand without triggering switch")
        }
        if let secondCard = menuPanel.accountsCardsStack.arrangedSubviews.dropFirst().first as? MenuExpandableAccountCardView {
            secondCard.onSwitchAccount = { switchedAccountId = $0 }
            secondCard.onToggleExpand = { toggledAccountId = $0 }
            secondCard.stateButton.performClick(nil)
            check(switchedAccountId == secondCard.accountId, "Clicking account stateButton must trigger account switch independently")
        }

        // Package C: MenuPanelController edge states & switches
        check(menuPanel.openAntigravityBtn.title == "打开 Antigravity", "MenuPanel openAntigravityBtn title must be 打开 Antigravity")
        check(menuPanel.openMainBtn.title.hasPrefix("打开") && menuPanel.openMainBtn.title.hasSuffix("↗"), "MenuPanel openMainBtn title must be 打开... ↗")

        // Tab 0 (Usage) empty models & toggle
        menuPanel.selectTab(0, persist: false); pump()
        if var emptyModelReport = assistant.cachedUsageReportsByPeriod["today"] {
            emptyModelReport["byModel"] = []
            emptyModelReport["snapshotId"] = "empty-models-snap"
            assistant.cachedUsageReportsByPeriod["today"] = emptyModelReport
            menuPanel.onUsageReportUpdated(period: "today", result: .success(emptyModelReport))
            check(menuPanel.modelsHeaderCountLabel.stringValue == "暂无记录", "Empty models must show 暂无记录")
            check(allTextValues(menuPanel.modelsListStack).contains { $0.contains("当前时间范围暂无模型调用记录") }, "Empty models must show placeholder")
            check(menuPanel.toggleModelsButton.isHidden == true, "Empty models must hide toggleModelsButton")
        }

        // Tab 0 period switching
        menuPanel.selectPeriod(1, persist: false); pump()
        check(menuPanel.trendTitleLabel.stringValue == "近 7 天趋势", "Period 1 must show 近 7 天趋势")
        menuPanel.selectPeriod(3, persist: false); pump()
        check(menuPanel.trendTitleLabel.stringValue == "全部趋势", "Period 3 must show 全部趋势")
        menuPanel.selectPeriod(0, persist: false); pump()

        // Tab 0 offline state
        assistant.reachable = false
        assistant.cachedUsageReportsByPeriod.removeValue(forKey: "today")
        menuPanel.selectTab(0, persist: false); pump()
        check(menuPanel.usageScopeLabel.stringValue == "正在等待本机服务…", "Offline Tab 0 must show 正在等待本机服务…")
        check(menuPanel.usageFooterLabel.stringValue == "本机服务离线", "Offline Tab 0 footer must show 本机服务离线")
        check(menuPanel.tokensTile.valueLabel.stringValue == "—", "Offline metric tiles must show —")

        // Tab 0 unavailable state
        assistant.reachable = true
        let unavailableReport: [String: Any] = ["summary": ["availability": "unavailable"]]
        assistant.cachedUsageReportsByPeriod["today"] = unavailableReport
        menuPanel.onUsageReportUpdated(period: "today", result: .success(unavailableReport)); pump()
        check(menuPanel.usageScopeLabel.stringValue == "所选会话数据库均读取失败", "Unavailable Tab 0 must show 所选会话数据库均读取失败")
        check(menuPanel.usageFooterLabel.stringValue.contains("统计暂不可用"), "Unavailable Tab 0 footer must show 统计暂不可用")

        // Tab 1 (Quota) empty & live unsaved
        let savedFixtureAccounts = accounts
        let savedMenuAccounts = assistant.cachedAccounts
        let savedActiveId = assistant.activeAccountId
        let savedLiveStatus = assistant.statusValue

        accounts = []
        assistant.cachedAccounts = []
        assistant.activeAccountId = ""
        fixtureStatus["liveAccountEmail"] = ""
        assistant.statusValue = LiveStatus(["mode": "adaptive", "liveAccountEmail": ""])
        menuPanel.selectTab(1, persist: false); pump()
        check(menuPanel.quotaAccountNameLabel.stringValue == "尚未保存账号", "Empty quota tab must show 尚未保存账号")
        check(menuPanel.quotaEmptyButton.isHidden == false, "Empty quota tab must show quotaEmptyButton")
        check(menuPanel.quotaGroupsContainer.isHidden == true, "Empty quota tab must hide quotaGroupsContainer")

        fixtureStatus["liveAccountEmail"] = "unsaved@example.invalid"
        assistant.statusValue = LiveStatus(["mode": "adaptive", "liveAccountEmail": "unsaved@example.invalid"])
        menuPanel.selectTab(1, persist: false); pump()
        check(menuPanel.quotaAccountNameLabel.stringValue == "运行中账号尚未保存", "Unsaved live account must show 运行中账号尚未保存")
        check(menuPanel.quotaEmailLabel.stringValue.contains("unsaved@example.invalid"), "Unsaved live account must show email in subtitle")

        // Tab 1 refreshing state & global multi-account summary isolation
        accounts = savedFixtureAccounts
        assistant.cachedAccounts = savedMenuAccounts
        assistant.activeAccountId = savedActiveId
        assistant.quotaRefreshError = "已读取 1 个账号；2 个刷新失败。详情见账号卡片。"
        menuPanel.selectTab(1, persist: false); pump()
        check(menuPanel.quotaWarningLabel.isHidden == true, "Multi-account partial summary must not pollute healthy current account warning label")
        assistant.quotaRefreshError = "刷新超时，请重试；保留上次配额"
        menuPanel.selectTab(1, persist: false); pump()
        check(menuPanel.quotaWarningLabel.isHidden == false && menuPanel.quotaWarningLabel.stringValue == "配额查询超时", "Transport/timeout global error must still display on current quota tab")
        assistant.quotaRefreshError = nil
        assistant.quotaRefreshing = true
        menuPanel.selectTab(1, persist: false); pump()
        check(menuPanel.quotaFooterLabel.stringValue == "正在刷新配额…", "Refreshing quota must show 正在刷新配额…")
        assistant.quotaRefreshing = false

        // Tab 2 (Accounts) empty online & offline
        accounts = []
        assistant.cachedAccounts = []
        assistant.reachable = true
        menuPanel.selectTab(2, persist: false); pump()
        check(menuPanel.accountsCountLabel.stringValue == "0 个账号", "Empty accounts count must be 0 个账号")
        check(allTextValues(menuPanel.accountsCardsStack).contains { $0.contains("暂无账号，请前往主界面添加") }, "Empty accounts tab must show guidance")

        assistant.reachable = false
        menuPanel.selectTab(2, persist: false); pump()
        check(allTextValues(menuPanel.accountsCardsStack).contains { $0.contains("正在等待本机服务读取账号列表…") }, "Offline accounts tab must show waiting message")

        // Restore accounts and reports
        accounts = savedFixtureAccounts
        assistant.reachable = true
        assistant.cachedAccounts = savedMenuAccounts
        assistant.activeAccountId = savedActiveId
        fixtureStatus["liveAccountEmail"] = savedLiveStatus.liveAccountEmail
        assistant.statusValue = savedLiveStatus
        assistant.cachedUsageReportsByPeriod["today"] = [
            "summary": totals,
            "byModel": models,
            "todayHourly": todayHourly
        ]
        menuPanel.selectTab(0, persist: false); pump()
        assistant.openMainWindowFromMenuPanel(tab: 0, usagePeriod: 2); pump()
        check(assistant.currentPage == 2 && assistant.usageSelectedPeriod == 2, "Footer deep-link from Usage tab must navigate to UsagePage and carry selected period")
        check(assistant.usagePage!.donutChart.totalUsd == 23.78, "Donut chart must receive total equivalent USD")
        check(!assistant.usagePage!.donutChart.isHidden, "Donut chart must be visible when priced models exist")
        do {
            let sixModels: [[String: Any]] = models + [
                ["model": "gemini-4-hydrogen", "totalTokens": 1200000, "promptTokens": 400000, "candidatesTokens": 50000, "requestCount": 14, "estimatedUsd": 2.40, "priced": true],
                ["model": "gemini-4-carbon", "totalTokens": 800000, "promptTokens": 250000, "candidatesTokens": 40000, "requestCount": 9, "estimatedUsd": 1.15, "priced": true]
            ]
            let usage = assistant.usagePage!
            usage.applyUsagePayload([
                "ok": true, "period": "30d", "snapshotId": "six-model-snapshot",
                "summary": totals.merging(["estimatedUsd": 27.33]) { _, n in n },
                "byModel": sixModels, "todayHourly": [], "dailyTrends": []
            ], period: "30d", segIdx: 2, requestKey: "six-model-test")
            window.contentView?.layoutSubtreeIfNeeded(); pump()
            func findRequestCard(_ v: NSView) -> NSView? {
                if v.identifier?.rawValue == "requests-cache-card" { return v }
                for s in v.subviews { if let found = findRequestCard(s) { return found } }
                return nil
            }
            if let reqCard = findRequestCard(usage.view) {
                let trackFrame = reqCard.convert(usage.cacheTrack.bounds, from: usage.cacheTrack)
                let bottomGap = reqCard.isFlipped ? (reqCard.bounds.height - trackFrame.maxY) : trackFrame.minY
                check(usage.donutLegendStack.arrangedSubviews.count == 5, "6 priced models must render 5 legend rows (got \(usage.donutLegendStack.arrangedSubviews.count))")
                check(bottomGap <= 34, "requests-cache-card must distribute slack symmetrically instead of leaving large bottom gap below cacheTrack (bottomGap=\(bottomGap))")
            } else {
                check(false, "requests-cache-card must exist in UsagePage")
            }
        }
        // Verify rapid page switching does not leave blank view host or drop views
        assistant.selectPage(0); assistant.selectPage(1); assistant.selectPage(0); pump()
        check(assistant.currentPage == 0, "Rapid switching must end on page 0")
        check(assistant.pageHost.subviews.contains(where: { $0 === assistant.overview!.view }), "Overview view must remain in pageHost after rapid switching")
        check(assistant.overview!.view.alphaValue == 1.0, "Overview view alpha must be 1.0 after completing transition")

        let ov = assistant.overview!
        assistant.cachedUsageReportsByPeriod["today"] = [
            "summary": totals,
            "byModel": models,
            "todayHourly": todayHourly
        ]
        ov.update(force: true)
        let curHour = Calendar.current.component(.hour, from: Date())
        let expectedCurHourPrefix = String(format: "今日 %02d:00 · ", locale: Locale(identifier: "en_US_POSIX"), curHour)
        check(ov.trendDetailLabel.stringValue.hasPrefix(expectedCurHourPrefix), "Overview trend detail must default to current hour (got \(ov.trendDetailLabel.stringValue))")
        if ov.todayTrendChart.points.count == 24 {
            ov.todayTrendChart.onHoverPoint?(ov.todayTrendChart.points[0])
            check(ov.trendDetailLabel.stringValue == "今日 00:00 · 0 Token", "Overview trend detail must show 今日 00:00 · 0 Token when hovering 00:00 (got \(ov.trendDetailLabel.stringValue))")
            ov.todayTrendChart.onHoverPoint?(ov.todayTrendChart.points[14])
            check(ov.trendDetailLabel.stringValue == "今日 14:00 · 19.6M Token", "Overview trend detail must show 今日 14:00 · 19.6M Token when hovering 14:00 (got \(ov.trendDetailLabel.stringValue))")
            ov.todayTrendChart.onHoverPoint?(nil)
            check(ov.trendDetailLabel.stringValue.hasPrefix(expectedCurHourPrefix), "Overview trend detail must restore current hour when hover exits")
        }
        ov.syncTrendDetailLabel(currentHour: 3)
        check(ov.trendDetailLabel.stringValue == "今日 03:00 · 0 Token" || ov.trendDetailLabel.stringValue == "今日 03:00 · 尚未到达", "Overview trend detail helper must format 03:00 accurately (got \(ov.trendDetailLabel.stringValue))")
        ov.syncTrendDetailLabel()
        check(ov.rightBentoTitleLabel.stringValue == "今日活跃模型", "Overview right Bento card title must be 今日活跃模型")
        check(ov.rightBentoCountBadge.title == "Top 2 / 共 4 个", "Overview right Bento count badge must show Top 2 / 共 4 个")
        check(ov.bentoRightStack.arrangedSubviews.count == 2, "Overview Bento right stack must display 2 subrows")
        func findButtons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap { findButtons($0) } }
        check(!findButtons(ov.view).contains { $0.title == "管理账号" }, "Overview hero card must not display 管理账号 button")
        if let firstBox = ov.bentoRightStack.arrangedSubviews.first as? NSBox {
            func findBadges(_ v: NSView) -> [PillBadge] { (v as? PillBadge).map { [$0] } ?? v.subviews.flatMap { findBadges($0) } }
            func findShareBars(_ v: NSView) -> [BentoShareBarView] { (v as? BentoShareBarView).map { [$0] } ?? v.subviews.flatMap { findShareBars($0) } }
            check(findBadges(firstBox).allSatisfy { $0.isHidden }, "Active model row must move USD into subtitle without showing a pill badge")
            check(findShareBars(firstBox).count == 1 && findShareBars(firstBox)[0].fraction > 0.7, "Active model subrow must render token share progress bar")
            check(firstBox.accessibilityLabel()?.contains("Gemini 3.8 Flash") == true || firstBox.accessibilityLabel()?.contains("gemini-3.8-flash") == true, "Subrow box must expose VoiceOver accessibility label")
            check(firstBox.toolTip == nil || firstBox.toolTip?.isEmpty == true, "Overview Bento subrows must be read-only without deep-link tooltip")
            check(firstBox.accessibilityRole() == .group, "Subrow box must be an accessible display group, not a button")
        }

        // Test single active model in Overview Bento
        assistant.cachedUsageReportsByPeriod["today"] = [
            "byModel": [models[0]],
            "todayHourly": todayHourly
        ]
        ov.update(force: true)
        check(ov.rightBentoTitleLabel.stringValue == "今日活跃模型", "Single model Bento title must remain 今日活跃模型")
        check(ov.rightBentoCountBadge.title == "1 个模型", "Single model Bento badge must show 1 个模型")
        check(ov.bentoRightStack.arrangedSubviews.count == 2, "Single model Bento must maintain exactly 2 subrows for layout symmetry")
        func allLabels(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map{[$0]} ?? view.subviews.flatMap{allLabels($0)} }
        let singleLabels = allLabels(ov.bentoRightStack).map { $0.stringValue }
        check(singleLabels.contains(where: { $0.contains("占今日全部调用") }), "Single model Bento must state 占今日全部调用")
        check(singleLabels.contains("查看更多模型统计"), "Single model Bento row 2 must provide guide card 查看更多模型统计")

        // Test zero / inactive models in Overview Bento (e.g. 0 tokens & 0 requests)
        assistant.cachedUsageReportsByPeriod["today"] = [
            "byModel": [["model": "inactive-model", "totalTokens": 0, "requestCount": 0]],
            "todayHourly": []
        ]
        ov.update(force: true)
        check(ov.rightBentoTitleLabel.stringValue == "今日活跃模型", "Zero model Bento title must remain 今日活跃模型")
        check(ov.rightBentoCountBadge.title == "暂无调用", "Zero/inactive model Bento badge must show 暂无调用")
        check(ov.bentoRightStack.arrangedSubviews.count == 2, "Empty state Bento must display exactly 2 symmetrical subrows")
        let emptyLabels = allLabels(ov.bentoRightStack).map { $0.stringValue }
        check(emptyLabels.contains("今日暂无模型调用"), "Empty state Bento row 1 must show 今日暂无模型调用")
        check(emptyLabels.contains("模型用量明细"), "Empty state Bento row 2 must show 模型用量明细")
        for box in ov.bentoRightStack.arrangedSubviews.compactMap({ $0 as? NSBox }) {
            check(box.toolTip == nil || box.toolTip?.isEmpty == true, "Both empty state rows must be read-only without deep-link tooltip")
            check(box.accessibilityRole() == .group, "Both empty state rows must be accessible display groups, not buttons")
        }

        // Restore fixture data
        assistant.cachedUsageReportsByPeriod["today"] = [
            "summary": totals,
            "byModel": models,
            "todayHourly": todayHourly
        ]
        ov.update(force: true)
        panelHost.orderOut(nil)

        assistant.activeAccountId = "a"
        assistant.confirmSwitchForTesting = { _, reply in reply(true) }
        assistant.switchAccountByIdFromMenu("b")
        check(assistant.activeAccountId == "a","Menu must not optimistically change current identity")
        waitUntil(description: "account switch to complete") {
            switches >= 1 && !assistant.accountSwitchInFlight
        }
        check(switches == 1, "Confirmed fixture switch must run exactly once")
        let opensBeforeIdleSwitch = assistant.openedApplications
        preflightState = "running_idle"
        assistant.switchAccountByIdFromMenu("c")
        waitUntil(description: "running_idle switch to complete and relaunch") {
            switches >= 2 && !assistant.accountSwitchInFlight && assistant.openedApplications > opensBeforeIdleSwitch
        }
        check(switches == 2 && assistant.openedApplications == opensBeforeIdleSwitch + 1, "Switching while Antigravity was running must automatically relaunch Antigravity")
        switches = 1; assistant.activeAccountId = "a"; activeId = "a"
        preflightState = "safe"
        preflightState = "busy"; assistant.switchAccountByIdFromMenu("c"); pump()
        check(switches == 1,"Running official app must block switching")
        preflightState = "error"; assistant.switchAccountByIdFromMenu("c"); pump()
        check(switches == 1,"Failed preflight must not execute")
        preflightState = "safe"; assistant.confirmSwitchForTesting = { _, reply in reply(false) }
        assistant.switchAccountByIdFromMenu("c"); pump(); check(switches == 1,"Cancelled confirmation must not execute")
        let summary = QuotaPresentation.menuAccountSummary(accounts[0]); check(summary.contains("Claude/GPT") && summary.contains("已耗尽"),"Menu must disclose exhausted family")

        // 校验菜单栏图标纯净性：无论配额是否耗尽（当前账号 a 的 Claude 为 0%），图标始终保持纯净 Template 图标，绝不附带警告圆点
        let statusButton = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let baseIcon = assistant.baseMenuConnectedIcon()
        check(baseIcon != nil, "baseMenuConnectedIcon must load valid icon")
        check(baseIcon?.size == NSSize(width: 20, height: 20), "baseMenuConnectedIcon size must be 20x20")
        check(baseIcon?.isTemplate == true, "baseMenuConnectedIcon must be marked as template for system auto-tinting")
        assistant.updateStatusItemState(buttonOverride: statusButton)
        check(statusButton.image === baseIcon, "Status item image must be baseMenuConnectedIcon")
        check(statusButton.image?.isTemplate == true, "Status item image must remain template without warning dot")
        check(statusButton.alphaValue == 1.0, "Connected status icon must maintain full opacity (1.0)")
        let pausedStatus: [String: Any] = ["mode": "paused", "windows": 1, "entries": 4300, "appVersion": "2.25.0", "liveAccountEmail": "alex@example.invalid", "activeAccountEmail": "alex@example.invalid", "accountsRevision": "fixture", "pid": -1]
        assistant.statusValue = LiveStatus(pausedStatus)
        assistant.updateStatusItemState(buttonOverride: statusButton)
        check(statusButton.alphaValue == 1.0, "Pausing translation must not reduce menu bar icon opacity")
        assistant.statusValue = LiveStatus(status)

        DesktopApplicationTarget.installedChannelsOverride = ["stable", "insiders"]
        Assistant.applicationChannel = "insiders"
        assistant.configuration.value.applicationChannel = "insiders"
        check(assistant.targetApplication.label == "Antigravity" && assistant.targetApplication.name == "Antigravity", "Unified target label and name must always be Antigravity")
        check(assistant.targetApplication.supportsAccountSwitch == true, "Stable Antigravity must support account switching")
        check(assistant.targetApplication.channel == "stable", "Legacy channel cannot redirect native target")
        check(assistant.targetApplication.bundleIdentifier == "com.google.antigravity", "Native target must be stable")
        check(DesktopApplicationTarget.installedChannels() == ["stable"], "Insiders must not be discoverable")
        let stableSettings = PreferencesController(app: assistant)
        check(!allTextValues(stableSettings.view).contains { $0.localizedCaseInsensitiveContains("Insiders") || $0.contains("目标应用") }, "Settings UI must not display target application switcher or Insiders text")
        check(stableSettings.manageCacheBtn.title == "管理存储…", "Storage settings row button must display 管理存储…")
        check(stableSettings.pricingSyncCheckBtn.title == "立即检查" && stableSettings.pricingSyncCheckBtn.intrinsicContentSize.height == 28, "Pricing check button must use fixed-width InlineRefreshButton matching global 28pt height")
        stableSettings.pricingSyncCheckBtn.setBusy(true, available: true)
        check(stableSettings.pricingSyncCheckBtn.isActivitySpinning && stableSettings.pricingSyncCheckBtn.title == "立即检查", "Pricing check button must spin in place without title jump")
        stableSettings.pricingSyncCheckBtn.setBusy(false, available: true)
        stableSettings.refreshStorageRowState(force: true); pump()
        check(!stableSettings.storageBadge.isHidden && stableSettings.storageBadge.title.hasPrefix("可释放 "), "Storage settings row must display reclaimable space pill badge")
        check(!allTextValues(stableSettings.view).contains("检查更新") && !allTextValues(stableSettings.view).contains("关于"), "Settings UI must extract 关于 section out into its own top-level sidebar tab")
        assistant.selectPage(4); pump()
        let aboutPage = assistant.aboutPage!
        check(assistant.names == ["总览", "账号", "用量", "设置", "关于"], "Sidebar must contain 5 top-level tabs ending with 关于")
        check(aboutPage.checkUpdateBtn.title == "检查更新", "About page must display 检查更新 button")
        check(aboutPage.statusLine.isHidden && aboutPage.updateStatusLabel.stringValue.isEmpty, "About page must hide idle status subtitle line")
        check(assistant.installUpdateButton?.isHidden == true, "Sidebar installUpdateButton must stay hidden when no update is available")
        assistant.updateManager.simulateRelease(AppReleaseInfo(
            version: "1.1.0",
            tagName: "v1.1.0",
            title: "GravityBox v1.1.0",
            changelog: "### 更新亮点\n- 新增 GitHub Release 检查更新与后台预下载\n- 毛玻璃更新 Sheet 展示完整 Changelog\n```bash\nsudo xattr -rd com.apple.quarantine /Applications/GravityBox.app\n```\n### 附件 SHA-256 校验\n```text\n7a88a030118d8e58a5f265bf0de61d00f9d26c115d56bad41e52f0969f3b3346  GravityBox-1.0.1-arm64.dmg\n```",
            publishedDate: "2026-11-04",
            htmlURL: URL(string: "https://github.com/Enzoo404/gravitybox/releases/tag/v1.1.0")!,
            dmgURL: nil,
            sha256URL: nil
        ))
        aboutPage.refreshUpdateState()
        check(!aboutPage.installNowBtn.isHidden && aboutPage.updateStatusLabel.stringValue.contains("v1.1.0"), "About page must display inline update prompt and 立即更新 button when update is available")
        check(assistant.installUpdateButton?.isHidden == false && assistant.installUpdateButton?.title == "安装更新" && assistant.installUpdateButton?.badgeText == "v1.1.0" && assistant.installUpdateButton?.isUpdatePrompt == true, "Sidebar must display 安装更新 prompt capsule above 打开 Antigravity when update is available")
        if let installBtn = assistant.installUpdateButton, let openBtn = assistant.launchApplicationButton, let bStack = installBtn.superview as? NSStackView {
            let installIdx = bStack.arrangedSubviews.firstIndex(of: installBtn) ?? -1
            let openIdx = bStack.arrangedSubviews.firstIndex(of: openBtn) ?? -1
            check(installIdx >= 0 && openIdx == installIdx + 1, "安装更新 capsule must sit directly above 打开 Antigravity in sidebar bottomStack")
        }
        // Capture Hero/Overview with sidebar 安装更新 capsule visible
        assistant.selectPage(0); window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 960, height: 640)), display: true); pump()
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded(); pump()
            try capture(window.contentView!, output.appendingPathComponent("\(theme)-hero-install-update-capsule.png"))
        }
        assistant.selectPage(4); pump()
        check(aboutPage.releaseNotesBtn.title == "更新日志 ↗" && !aboutPage.releaseNotesBtn.isHidden, "About page must display 更新日志 ↗ button when release is available")
        if let rel = assistant.updateManager.availableRelease {
            let formattedNotes = AppUpdateManager.formatReleaseNotes(rel.changelog)
            check(formattedNotes.contains("• 新增 GitHub Release 检查更新"), "Release notes formatter must format markdown list items into bullets")
            check(!formattedNotes.contains("```") && !formattedNotes.contains("###"), "Release notes formatter must strip raw markdown code fences and heading hashes")
            check(!formattedNotes.contains("sudo xattr") && !formattedNotes.contains("SHA-256"), "Release notes formatter must strip terminal quarantine commands and SHA-256 footer blocks")
        }
        do {
            let updaterScript = AppUpdateManager.buildDetachedUpdaterScript(
                myPid: 12345,
                stagedAppPath: "/tmp/staged/GravityBox.app",
                targetAppPath: "/Applications/GravityBox.app",
                workDirPath: "/tmp/staged",
                dmgFilePath: "/tmp/updates/v1.0.4/GravityBox-1.0.4-arm64.dmg"
            )
            check(updaterScript.contains("HUP TERM INT QUIT PIPE") && updaterScript.contains("kill -9 12345") && updaterScript.contains("--install-update"), "Detached updater must wait for its parent then invoke the transactional helper")
            check(!updaterScript.contains("rm -rf") && !updaterScript.contains("ditto"), "Detached launcher must never delete or copy over the live app")
            check(AppUpdateManager.extractGravityBoxDMGVersion(from: "GravityBox-1.0.4-arm64.dmg") == "1.0.4", "Must extract version from standard arm64 DMG filename")
            check(AppUpdateManager.extractGravityBoxDMGVersion(from: "GravityBox-v1.0.3-universal.dmg.sha256") == "1.0.3", "Must extract version from v-prefixed DMG sha256 sidecar")
            check(AppUpdateManager.extractGravityBoxDMGVersion(from: "OtherApp-1.0.4-arm64.dmg") == nil, "Must ignore unrelated DMG filenames")

            // Test cleanupObsoleteUpdateArtifacts across state/updates and Downloads
            let fm = FileManager.default
            let oldUpdateDir = state.appendingPathComponent("updates/v1.0.3", isDirectory: true)
            let currUpdateDir = state.appendingPathComponent("updates/v1.0.4", isDirectory: true)
            let newerUpdateDir = state.appendingPathComponent("updates/v1.1.0", isDirectory: true)
            let staleInstallDir = state.appendingPathComponent("updates/install-stale", isDirectory: true)
            let staleTxDir = state.appendingPathComponent("updates/transactions/install-aborted", isDirectory: true)
            let confirmedTxDir = state.appendingPathComponent("updates/transactions/install-confirmed", isDirectory: true)
            let fakeDownloadsDir = state.appendingPathComponent("test-downloads", isDirectory: true)
            for dir in [oldUpdateDir, currUpdateDir, newerUpdateDir, staleInstallDir, staleTxDir, confirmedTxDir, fakeDownloadsDir] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let confirmedReceipt = UpdateInstallReceipt(phase: "confirmed", token: "tok", targetPath: "/Applications/GravityBox.app", backupPath: "/Applications/.GravityBox-backup-test.app", expectedVersion: "1.0.5", newAppHash: "abc", oldAppHash: "def", dmgPath: "")
            try confirmedReceipt.save(to: confirmedTxDir.appendingPathComponent(UpdateInstaller.receiptName))
            let confirmedStagedApp = confirmedTxDir.appendingPathComponent("GravityBox.app")
            let confirmedHelper = confirmedTxDir.appendingPathComponent("installer")
            try fm.createDirectory(at: confirmedStagedApp, withIntermediateDirectories: true)
            try Data("helper".utf8).write(to: confirmedHelper)
            let oldCachedDMG = oldUpdateDir.appendingPathComponent("GravityBox-1.0.3-arm64.dmg")
            let currCachedDMG = currUpdateDir.appendingPathComponent("GravityBox-1.0.4-arm64.dmg")
            let newerCachedDMG = newerUpdateDir.appendingPathComponent("GravityBox-1.1.0-arm64.dmg")
            let newerPartDMG = newerUpdateDir.appendingPathComponent("download-temp.dmg.part")
            let dlOldDMG = fakeDownloadsDir.appendingPathComponent("GravityBox-1.0.3-arm64.dmg")
            let dlCurrDMG = fakeDownloadsDir.appendingPathComponent("GravityBox-1.0.4-arm64.dmg")
            let dlCurrSha = fakeDownloadsDir.appendingPathComponent("GravityBox-1.0.4-arm64.dmg.sha256")
            let dlNewerDMG = fakeDownloadsDir.appendingPathComponent("GravityBox-1.1.0-arm64.dmg")
            let dlUnrelated = fakeDownloadsDir.appendingPathComponent("Antigravity-2.29.0.dmg")
            for f in [oldCachedDMG, currCachedDMG, newerCachedDMG, newerPartDMG, dlOldDMG, dlCurrDMG, dlCurrSha, dlNewerDMG, dlUnrelated] {
                try Data("dummy".utf8).write(to: f)
            }
            let previousCleanedVersion = assistant.configuration.value.lastCleanedVersion
            let unconfirmedCount = assistant.updateManager.cleanupObsoleteUpdateArtifacts(
                restartedAfterUpdate: true,
                currentVersionOverride: "1.0.4",
                downloadsDirectory: fakeDownloadsDir,
                detachMountedVolumes: false
            )
            check(unconfirmedCount == 0, "Startup, version change and restarted-after-update flags alone must never trigger cleanup")
            for f in [oldCachedDMG, currCachedDMG, newerCachedDMG, newerPartDMG, dlOldDMG, dlCurrDMG, dlCurrSha] {
                check(fm.fileExists(atPath: f.path), "Unconfirmed update must retain packages and checksums")
            }
            check(assistant.configuration.value.lastCleanedVersion == previousCleanedVersion, "Unconfirmed launch must not advance cleanup marker")
            let cleanedCount = assistant.updateManager.cleanupObsoleteUpdateArtifacts(
                successfulLaunchConfirmed: true,
                restartedAfterUpdate: true,
                currentVersionOverride: "1.0.4",
                downloadsDirectory: fakeDownloadsDir,
                detachMountedVolumes: false
            )
            check(cleanedCount >= 6, "cleanupObsoleteUpdateArtifacts must clean obsolete update folders, part files, and <=1.0.4 Downloads DMGs")
            check(!fm.fileExists(atPath: oldUpdateDir.path) && !fm.fileExists(atPath: currUpdateDir.path) && !fm.fileExists(atPath: staleInstallDir.path) && !fm.fileExists(atPath: staleTxDir.path), "Obsolete updates/v<=1.0.4 and install-* directories must be removed")
            check(!fm.fileExists(atPath: confirmedStagedApp.path) && !fm.fileExists(atPath: confirmedHelper.path) && fm.fileExists(atPath: confirmedTxDir.appendingPathComponent(UpdateInstaller.receiptName).path), "Confirmed transaction must clean staged GravityBox.app and installer while retaining install-receipt.json")
            check(fm.fileExists(atPath: newerCachedDMG.path) && !fm.fileExists(atPath: newerPartDMG.path), "Newer pre-downloaded DMG (v1.1.0 > 1.0.4) must be preserved while .dmg.part is cleaned")
            check(!fm.fileExists(atPath: dlOldDMG.path) && !fm.fileExists(atPath: dlCurrDMG.path) && !fm.fileExists(atPath: dlCurrSha.path), "Downloads DMGs and .sha256 for versions <= 1.0.4 must be cleaned")
            check(fm.fileExists(atPath: dlNewerDMG.path) && fm.fileExists(atPath: dlUnrelated.path), "Downloads DMGs for newer versions (>1.0.4) and unrelated apps must be preserved")
            check(assistant.configuration.value.lastCleanedVersion == "1.0.4", "cleanupObsoleteUpdateArtifacts must persist lastCleanedVersion = 1.0.4")
            try? fm.removeItem(at: state.appendingPathComponent("updates"))
            try? fm.removeItem(at: fakeDownloadsDir)

            check(aboutPage.autoUpdateSwitch.state == .off, "Auto update switch on About page must default to off")
            aboutPage.autoUpdateSwitch.state = .on
            aboutPage.toggleAutoUpdate()
            check(assistant.configuration.value.autoUpdateEnabled == true, "Toggling About autoUpdateSwitch to on must persist autoUpdateEnabled = true")
            aboutPage.autoUpdateSwitch.state = .off
            aboutPage.toggleAutoUpdate()
            check(assistant.configuration.value.autoUpdateEnabled == false, "Toggling About autoUpdateSwitch to off must persist autoUpdateEnabled = false")
            aboutPage.autoUpdateSwitch.state = .on
            aboutPage.toggleAutoUpdate()
            check(assistant.configuration.value.autoUpdateEnabled == true, "Toggling About autoUpdateSwitch back to on must persist autoUpdateEnabled = true")

            assistant.selectPage(0); pump()
            assistant.checkForUpdatesFromMenu(); pump()
            check(assistant.currentPage == 4 && window.activeSheetWindow == nil, "checkForUpdatesFromMenu must navigate inline to About page without opening legacy update sheet")

            if let maintSheet = assistant.preferencesController?.maintenanceSheet {
                maintSheet.show(in: window); pump()
                maintSheet.cachePage.runtimeInfoButton.performClick(nil); pump()
                check(window.activeSheetWindow === maintSheet.sheet && maintSheet.cachePage.detailPopover != nil, "Maintenance sheet and detailPopover must attach before dismissAllSheetsAndPopovers verification")
                assistant.dismissAllSheetsAndPopovers(); waitForSheetDetach(on: window, description: "dismissAllSheetsAndPopovers to detach")
                check(window.activeSheetWindow == nil && maintSheet.cachePage.detailPopover == nil && maintSheet.cachePage.activePopoverKind == nil, "dismissAllSheetsAndPopovers must cleanly end attached modal sheets and detail popovers")
            }
        }

        // Package D: AboutPage states and system specs
        let sampleRelease = AppReleaseInfo(
            version: "1.1.0",
            tagName: "v1.1.0",
            title: "GravityBox v1.1.0",
            changelog: "### 更新亮点\n- 新增功能",
            publishedDate: "2026-11-04",
            htmlURL: URL(string: "https://github.com/Enzoo404/gravitybox/releases/tag/v1.1.0")!,
            dmgURL: nil,
            sha256URL: nil
        )
        assistant.updateManager.simulateDownloading(sampleRelease)
        aboutPage.refreshUpdateState()
        check(aboutPage.cancelDownloadBtn.isHidden == false && aboutPage.updateMetaLabel.stringValue == "下载中", "About page downloading state must show cancel button and 下载中")

        let fakeReadyDMG = state.appendingPathComponent("fake-ready.dmg")
        assistant.updateManager.simulateReadyToInstall(sampleRelease, dmgURL: fakeReadyDMG)
        aboutPage.refreshUpdateState()
        check(aboutPage.installNowBtn.isHidden == false && aboutPage.updateMetaLabel.stringValue == "已校验", "About page readyToInstall state must show installNowBtn and 已校验")

        assistant.updateManager.simulateFailed("本地校验异常")
        aboutPage.refreshUpdateState()
        check(aboutPage.checkUpdateBtn.isHidden == false && aboutPage.updateMetaLabel.stringValue == "可重试" && aboutPage.releaseNotesBtn.isHidden, "About page failed state must show checkUpdateBtn, 可重试 and hide releaseNotesBtn")

        check(!aboutPage.versionSpecLabel.stringValue.isEmpty, "About page versionSpecLabel must not be empty")
        check(aboutPage.versionSpecLabel.stringValue.contains("Antigravity") && !aboutPage.versionSpecLabel.stringValue.contains("Build "), "About page versionSpecLabel must display Antigravity version without Build number")
        let aboutTexts = allTextValues(aboutPage.view)
        check(aboutTexts.contains("自动检查更新") && aboutTexts.contains("运行信息") && aboutTexts.contains("目标应用") && aboutTexts.contains("GravityBox 数据目录"), "Simplified About page must render 自动检查更新, 运行信息, 目标应用 and GravityBox 数据目录")
        check(!aboutTexts.contains("系统环境") && !aboutTexts.contains("构建与环境") && !aboutTexts.contains("本地数据与隐私原则") && !aboutTexts.contains("macOS · arm64") && !aboutTexts.contains { $0.contains("查看历史发行版本") }, "Simplified About page must omit redundant OS, build, privacy, arm64 pill and Releases subtitle rows")
        check(aboutPage.revealDataBtn.title == "在访达中显示", "About page revealDataBtn title must be 在访达中显示")
        check(aboutPage.githubReleasesBtn.title == "GitHub ↗", "About page githubReleasesBtn title must be GitHub ↗")

        assistant.updateManager.simulateRelease(nil)
        aboutPage.refreshUpdateState()
        check(!aboutPage.checkUpdateBtn.isHidden && aboutPage.installNowBtn.isHidden, "Clearing available release must restore 检查更新 button on About page")
        check(!aboutPage.statusLine.isHidden && aboutPage.updateStatusLabel.stringValue == "已是最新版本", "About page must display 已是最新版本 status after checking up-to-date")
        check(assistant.installUpdateButton?.isHidden == true, "Clearing available release must hide sidebar installUpdateButton again")
        check(aboutPage.releaseNotesBtn.isHidden && window.activeSheetWindow == nil, "Clearing available release must hide releaseNotesBtn without opening modal update sheet")
        // Verify unified inactive PillBadge styling across neutral/secondary tints
        let lightApp = NSAppearance(named: .aqua)!
        let darkApp = NSAppearance(named: .darkAqua)!
        for c in [Design.inactivePill, Design.secondary, NSColor.secondaryLabelColor, NSColor.systemGray] {
            check(PillBadge.isNeutralOrInactiveTint(c, in: lightApp), "Neutral/inactive tint must be recognized in Light mode")
            check(PillBadge.isNeutralOrInactiveTint(c, in: darkApp), "Neutral/inactive tint must be recognized in Dark mode")
        }
        check(!PillBadge.isNeutralOrInactiveTint(Design.blue, in: lightApp), "Active blue tint must not be treated as neutral/inactive")
        for scale in [TierBadge.Scale.regular, .compact] {
            check(scale.iconSize(for: .free) == 0, "FREE TierBadge must not reserve icon space for a bullseye")
            check(scale.iconSize(for: .pro) > 0, "PRO TierBadge must retain single-sparkle icon space")
            check(scale.iconSize(for: .ultra) > scale.iconSize(for: .pro), "ULTRA TierBadge must retain twin-sparkle icon space")
            let freeBadge = TierBadge("FREE", scale: scale)
            let proBadge = TierBadge("PRO", scale: scale)
            freeBadge.frame = NSRect(origin: .zero, size: freeBadge.intrinsicContentSize)
            freeBadge.layoutSubtreeIfNeeded()
            if let freeLbl = freeBadge.subviews.compactMap({ $0 as? NSTextField }).first {
                let leftGap = freeLbl.frame.minX
                let rightGap = freeBadge.bounds.width - freeLbl.frame.maxX
                check(abs(leftGap - rightGap) <= 1.0, "FREE TierBadge text must sit symmetrically centered without leading bullseye offset (left=\(leftGap), right=\(rightGap))")
            }
            check(proBadge.intrinsicContentSize.width > 0 && freeBadge.intrinsicContentSize.width > 0, "TierBadge intrinsic width must be positive")
        }

        // Capture Overview in idle (0 active models, 0 hourly tokens) to verify unified inactive capsules
        assistant.selectPage(0); window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 960, height: 640)), display: true); pump()
        assistant.cachedUsageReportsByPeriod["today"] = [
            "summary": totals,
            "byModel": [],
            "todayHourly": []
        ]
        assistant.overview!.updateReadinessMatrix()
        check(assistant.overview!.todayPeakBadge.title == "24 小时分布" && assistant.overview!.rightBentoCountBadge.title == "暂无调用", "Overview idle badges must show 24 小时分布 and 暂无调用")
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded()
            try capture(window.contentView!, output.appendingPathComponent("\(theme)-overview-idle-pills.png"))
        }
        assistant.cachedUsageReportsByPeriod["today"] = [
            "summary": totals,
            "byModel": models,
            "todayHourly": todayHourly
        ]
        assistant.overview!.updateReadinessMatrix()

        // Verify AccountsPage unified & per-card collapse/expand behavior and removal of Backup button
        assistant.selectPage(1); pump()
        let accPage = assistant.accountsPage!
        accPage.fetch(); pump()
        waitUntil(step: 0.01, description: "AccountsPage fetch to settle before collapse checks") {
            !assistant.accountListInFlight
                && !assistant.accountListPendingRefetch
                && accPage.cardsStack.arrangedSubviews.count == 3
        }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.layoutSubtreeIfNeeded(); pump()
        func allAccButtons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap { allAccButtons($0) } }
        check(!allAccButtons(accPage.view).contains { $0.title == "备份…" || $0.title == "导出备份…" }, "AccountsPage header must remove standalone 备份… and 导出备份… buttons")
        check(accPage.manageAccountsButton.title == "管理账号…" && accPage.manageAccountsButton.toolTip == nil, "AccountsPage header must expose 管理账号… button")
        check((accPage.toggleCollapseAllButton as? DesignButton)?.isQuietAccessory == false, "AccountsPage 收起配额/展开配额 button must match global capsule button style")
        check(accPage.autoSwitchStatusBadge.title == "已停用", "Smart switch disabled state must retain 已停用 pill badge")
        let offSubtitle = accPage.policySubtitleLabel.stringValue
        check(offSubtitle.contains("需手动确认切换"), "Standby advisor subtitle must clarify manual confirmation before switching: \(offSubtitle)")
        accPage.autoSwitchToggle.state = .on
        accPage.updateAutoSwitchState()
        check(accPage.autoSwitchStatusBadge.title.hasPrefix("已启用"), "Smart switch enabled state must display 已启用 pill badge")
        check(accPage.policySubtitleLabel.stringValue == offSubtitle, "Smart switch subtitle must stay consistent between ON and OFF states")
        accPage.autoSwitchToggle.state = .off
        accPage.updateAutoSwitchState()
        check(!accPage.toggleCollapseAllButton.isHidden && accPage.toggleCollapseAllButton.title == "收起配额", "AccountsPage header must show 收起配额 button when cards are expanded")
        let expandedFirstCardHeight = accPage.cardsStack.arrangedSubviews.first?.bounds.height ?? 0
        check(expandedFirstCardHeight > 180, "Expanded account card height must include full quota bars (>180pt)")
        verifyAccountsCardsGeometry(accPage, context: "accounts-all-expanded")

        accPage.toggleCollapseAllAccounts(); pump()
        window.contentView?.layoutSubtreeIfNeeded(); pump()
        check(accPage.isAllCollapsedMode && accPage.collapsedAccountIds.count == 3, "Clicking 收起配额 must collapse all 3 account cards")
        check(accPage.toggleCollapseAllButton.title == "展开配额", "Header button title must switch to 展开配额 when all cards are collapsed")
        check(assistant.configuration.value.accountsCollapsed == true, "Collapsing all accounts must persist accountsCollapsed = true in configuration")
        let collapsedFirstCardHeight = accPage.cardsStack.arrangedSubviews.first?.bounds.height ?? 0
        check(collapsedFirstCardHeight > 40 && collapsedFirstCardHeight < expandedFirstCardHeight - 100, "Collapsed account card height must shrink by >100pt (got \(collapsedFirstCardHeight) vs \(expandedFirstCardHeight))")
        let collapsedTexts = allTextValues(accPage.cardsStack)
        check(collapsedTexts.contains { $0.contains("Gemini 91%") && $0.contains("Claude/GPT 0%") }, "Collapsed account card must display inline quota summary")
        verifyAccountsCardsGeometry(accPage, context: "accounts-all-collapsed")
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded(); pump()
            try capture(window.contentView!, output.appendingPathComponent("\(theme)-accounts-collapsed.png"))
        }

        // Toggle single account card expand while others stay collapsed
        let singleBtn = NSButton()
        singleBtn.identifier = NSUserInterfaceItemIdentifier("a")
        accPage.toggleSingleAccountCollapse(singleBtn); pump()
        window.contentView?.layoutSubtreeIfNeeded(); pump()
        check(!accPage.collapsedAccountIds.contains("a") && accPage.collapsedAccountIds.contains("b"), "Per-card collapse button must expand account a while keeping b collapsed")
        check(accPage.toggleCollapseAllButton.title == "收起配额", "When any card is expanded, header button must offer 收起配额")
        verifyAccountsCardsGeometry(accPage, context: "accounts-mixed-collapsed")

        // Collapse all again, then expand all
        accPage.toggleCollapseAllAccounts(); pump()
        check(accPage.collapsedAccountIds.count == 3 && accPage.toggleCollapseAllButton.title == "展开配额", "Clicking 收起配额 when partially expanded must collapse all cards")
        accPage.toggleCollapseAllAccounts(); pump()
        check(accPage.collapsedAccountIds.isEmpty && accPage.toggleCollapseAllButton.title == "收起配额" && assistant.configuration.value.accountsCollapsed == false, "Clicking 展开配额 must expand all cards and persist accountsCollapsed = false")

        let stableAccounts = AccountsPage(app: assistant)
        stableAccounts.updateAutoSwitchState()
        check(stableAccounts.autoSwitchToggle.isEnabled && stableAccounts.configButton.isEnabled, "All account switch controls must remain enabled for stable Antigravity")
        check(!allTextValues(stableAccounts.view).contains { $0.localizedCaseInsensitiveContains("Insiders") }, "Accounts UI must not mention Insiders")
        check(Assistant.desiredActivationPolicy(isWindowVisible: false, isWindowMiniaturized: false, isQuitting: false) == .accessory, "Closed main window must return to .accessory menu-bar-only mode")
        check(Assistant.desiredActivationPolicy(isWindowVisible: true, isWindowMiniaturized: false, isQuitting: false) == .regular, "Visible main window must use .regular mode for Stage Manager and Dock")
        check(Assistant.desiredActivationPolicy(isWindowVisible: false, isWindowMiniaturized: true, isQuitting: false) == .regular, "Miniaturized main window must stay .regular instead of dropping Dock association")
        check(Assistant.desiredActivationPolicy(isWindowVisible: true, isWindowMiniaturized: false, isQuitting: true) == .accessory, "Quitting app must revert to .accessory")
        let stableAdd = AddAccountSheet(app: assistant) {}
        check(stableAdd.currentButton.isEnabled, "Save current account must remain enabled")
        stableAdd.busy(false)
        check(stableAdd.currentButton.isEnabled, "Leaving busy state must keep save current account enabled")
        check(!allTextValues(stableAdd.window.contentView!).contains { $0.localizedCaseInsensitiveContains("Insiders") }, "AddAccountSheet UI must not mention Insiders")
        assistant.pageHost.subviews.forEach { $0.removeFromSuperview() }
        assistant.preferencesController = stableSettings
        assistant.currentPage = -1
        assistant.selectPage(3); window.setContentSize(NSSize(width: 1060, height: 760)); pump()
        try capture(window.contentView!, output.appendingPathComponent("stable-settings.png"))

        // Verify languagePopup, More menu language submenu, reachability, and live zh-Hans <-> en hot-switching
        check(stableSettings.languagePopup.isEnabled == true, "languagePopup must be enabled for supported Antigravity")
        check((stableSettings.hudSwitch as AnyObject) is DesignSwitch && (stableAccounts.autoSwitchToggle as AnyObject) is DesignSwitch, "Switches must use DesignSwitch to stay blue when window is unfocused")
        check(stableSettings.languagePopup.cell is DesignPopUpCell, "languagePopup must use DesignPopUpCell")
        check(stableSettings.languagePopup.fittingSize.width <= 110 && stableSettings.languagePopup.fittingSize.width >= Design.fittedPopUpWidth(stableSettings.languagePopup) - 0.5, "Chinese languagePopup must tightly fit longest option (got \(stableSettings.languagePopup.fittingSize.width))")
        check(stableSettings.refresh.fittingSize.width <= 112 && stableSettings.refresh.fittingSize.width >= Design.fittedPopUpWidth(stableSettings.refresh) - 0.5, "Chinese refresh popup must tightly fit longest option (got \(stableSettings.refresh.fittingSize.width))")
        check(stableSettings.languagePopup.itemArray.compactMap { $0.representedObject as? String } == ["system", "zh-Hans", "en"], "languagePopup must expose system, zh-Hans, and en options")
        check((stableSettings.languagePopup.selectedItem?.representedObject as? String) == "zh-Hans", "languagePopup must select zh-Hans when configuredLanguage=zh-Hans")
        check(stableSettings.languagePopup.toolTip == nil && stableSettings.hudSwitch.toolTip == nil, "Settings language/hud controls must not display hover tooltips")

        let unsupportedPrev = assistant.statusValue
        assistant.statusValue = LiveStatus(["mode": "unsupported", "appVersion": "2.25.0"])
        stableSettings.update()
        check(stableSettings.languagePopup.isEnabled == false && stableSettings.hudSwitch.isEnabled == false, "languagePopup and hudSwitch must disable in unsupported mode")
        assistant.statusValue = unsupportedPrev
        stableSettings.update()

        // Verify More Menu (…) includes 显示语言 submenu directly above 对话状态栏
        let moreMenu = assistant.buildMoreMenu()
        let moreTitles = moreMenu.items.map(\.title)
        if let langIdx = moreTitles.firstIndex(of: "显示语言"), let hudIdx = moreTitles.firstIndex(of: "对话状态栏") {
            check(hudIdx == langIdx + 1, "对话状态栏 must sit directly below 显示语言 in More menu")
            let subCodes = moreMenu.items[langIdx].submenu?.items.compactMap { $0.representedObject as? String } ?? []
            check(subCodes == ["system", "zh-Hans", "en"], "显示语言 submenu must expose system, zh-Hans, and en items")
            let checkedItem = moreMenu.items[langIdx].submenu?.items.first { ($0.representedObject as? String) == "zh-Hans" }
            check(checkedItem?.state == .on, "显示语言 submenu must checkmark active configured language")
        } else {
            check(false, "More menu must contain both 显示语言 and 对话状态栏")
        }

        // Verify global zero-tooltip requirement across all pages and menu panel
        func hasNonEmptyTooltip(_ v: NSView) -> String? {
            if let tip = v.toolTip, !tip.isEmpty { return "\(type(of: v)): \(tip)" }
            for sub in v.subviews {
                if let found = hasNonEmptyTooltip(sub) { return found }
            }
            return nil
        }
        for pageView: NSView in [assistant.overview!.view, assistant.accountsPage!.view, assistant.usagePage!.view, stableSettings.view!, aboutPage.view, menuPanel.view] {
            let found = hasNonEmptyTooltip(pageView)
            check(found == nil, "Global tooltip cleanup violated on view: \(found ?? "")")
        }

        // Verify unreachable backend disables HUD switch & menu toggle while preserving language selection
        assistant.reachable = false
        stableSettings.update()
        check(stableSettings.hudSwitch.isEnabled == false && stableSettings.hudSwitch.toolTip == nil, "hudSwitch must disable without tooltip when backend is unreachable")
        let menuDisabled = assistant.buildMoreMenu()
        check(menuDisabled.items.first { $0.title == "对话状态栏" }?.isEnabled == false, "Menu bar HUD toggle must be disabled when backend is unreachable")
        assistant.reachable = true
        stableSettings.update()
        check(stableSettings.hudSwitch.isEnabled == true, "hudSwitch must re-enable once backend becomes reachable")

        // Verify live global hot-switch to English across main window, more menu, and menu panel
        var enCaptures: [String] = []
        let enFontWindowSize = NSSize(width: 880, height: 580)
        assistant.setGlobalLanguage("en"); pump()
        check(lastLanguageCommand == "en", "setGlobalLanguage(en) must send language_set(en)")
        check(L10n.shared.currentLocale == "en" && assistant.configuration.value.appLanguage == "en", "setGlobalLanguage(en) must update L10n locale and configuration")
        check(assistant.statusValue.translationEnabled == false, "English mode must disable Antigravity translation injection")
        check(assistant.names == ["Overview", "Accounts", "Usage", "Settings", "About"], "Sidebar tabs must hot-switch to English: \(assistant.names)")
        check(assistant.launchApplicationButton?.title == "Open Antigravity", "Sidebar primary CTA must hot-switch to English")
        if let enWinItems = NSApp.windowsMenu?.items {
            let enWinTitles = enWinItems.map(\.title)
            check(["Close Window", "Minimize", "Zoom"].allSatisfy { enWinTitles.contains($0) }, "English Window menu must expose Close Window, Minimize, and Zoom: \(enWinTitles)")
            let zoomItem = enWinItems.first { $0.title == "Zoom" }
            check(zoomItem?.action == #selector(NSWindow.performZoom(_:)) && zoomItem?.target == nil, "English Zoom menu item must dispatch performZoom(_:) via responder chain")
        } else {
            check(false, "NSApp.windowsMenu must be installed in English mode")
        }
        let enMoreMenu = assistant.buildMoreMenu()
        let enMoreTitles = enMoreMenu.items.map(\.title)
        check(enMoreTitles.contains("Display Language") && enMoreTitles.contains("Session HUD") && enMoreTitles.contains("Settings…"), "More menu must hot-switch to English: \(enMoreTitles)")

        window.setContentSize(enFontWindowSize)
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for page in 0..<5 {
                assistant.selectPage(page); pump(); window.contentView?.layoutSubtreeIfNeeded()
                let capName = "en-\(theme)-880x580-\(page).png"
                try capture(window.contentView!, output.appendingPathComponent(capName))
                enCaptures.append(capName)
                check((window.contentView?.fittingSize.width ?? 0) <= 880, "English page \(page) (\(theme)) exceeds 880pt minimum window width")
            }
        }
        // Assert no CJK Han leakage on static Settings & About UI views when active locale is English
        assistant.selectPage(3); pump()
        let enSettings = assistant.preferencesController!
        check((enSettings.languagePopup.selectedItem?.representedObject as? String) == "en", "English Settings languagePopup must select en")
        check(enSettings.languagePopup.fittingSize.width <= 136 && enSettings.languagePopup.fittingSize.width >= Design.fittedPopUpWidth(enSettings.languagePopup) - 0.5, "English languagePopup must tightly fit longest option (got \(enSettings.languagePopup.fittingSize.width))")
        check(enSettings.refresh.fittingSize.width <= 128 && enSettings.refresh.fittingSize.width >= Design.fittedPopUpWidth(enSettings.refresh) - 0.5, "English refresh popup must tightly fit longest option (got \(enSettings.refresh.fittingSize.width))")
        let hanPattern = "[\\u4E00-\\u9FFF]"
        let allowedNativeNames = Set(L10n.shared.supportedLocales.map(\.nativeName))
        let localizedViews: [(String, NSView)] = [("Settings", enSettings.view!), ("About", assistant.aboutPage!.view)]
        for (label, view) in localizedViews {
            let leaks = allTextValues(view).filter { !allowedNativeNames.contains($0) && $0.range(of: hanPattern, options: .regularExpression) != nil }
            check(leaks.isEmpty, "English \(label) page must not contain untranslated Chinese labels: \(leaks)")
        }

        // Capture Light/Dark English MenuPanel usage snapshots
        let enMenuPanel = assistant.ensureMenuPanelController()
        let enPanelHost = makeHeadlessHostWindow(width: MenuPanelController.panelWidth, height: MenuPanelController.defaultPanelHeight)
        enPanelHost.contentViewController = enMenuPanel
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            enPanelHost.appearance = NSAppearance(named: appearance)
            enMenuPanel.selectTab(0, persist: false); enMenuPanel.panelWillOpen(); pump()
            enPanelHost.setContentSize(enMenuPanel.preferredContentSize); enPanelHost.contentView?.layoutSubtreeIfNeeded(); pump()
            let panelName = "en-\(theme)-menu-panel-usage.png"
            try capture(enPanelHost.contentView!, output.appendingPathComponent(panelName))
            enCaptures.append(panelName)
        }
        check(enMenuPanel.tokensTile.titleLabel.stringValue == "Tokens" && enMenuPanel.requestsTile.titleLabel.stringValue == "Requests" && enMenuPanel.costTile.titleLabel.stringValue == "Est. API Cost", "English MenuPanel KPI tiles must use English titles")
        enPanelHost.orderOut(nil)

        // Hot-switch back to Simplified Chinese and verify restoration
        assistant.setGlobalLanguage("zh-Hans"); pump()
        check(lastLanguageCommand == "zh-Hans" && L10n.shared.currentLocale == "zh-Hans", "setGlobalLanguage(zh-Hans) must restore Simplified Chinese locale")
        check(assistant.names == ["总览", "账号", "用量", "设置", "关于"], "Sidebar tabs must restore to Chinese")
        if let zhWinItems = NSApp.windowsMenu?.items {
            let zhWinTitles = zhWinItems.map(\.title)
            check(["关闭窗口", "最小化", "缩放"].allSatisfy { zhWinTitles.contains($0) }, "Chinese Window menu must expose 关闭窗口, 最小化, and 缩放: \(zhWinTitles)")
            let zoomItem = zhWinItems.first { $0.title == "缩放" }
            check(zoomItem?.action == #selector(NSWindow.performZoom(_:)) && zoomItem?.target == nil, "Chinese 缩放 menu item must dispatch performZoom(_:) via responder chain")
            check(!window.collectionBehavior.contains(.fullScreenPrimary), "Main window must keep + zoom button behavior without fullScreenPrimary")
        } else {
            check(false, "NSApp.windowsMenu must be installed in Chinese mode")
        }
        window.appearance = nil
        window.setContentSize(NSSize(width: 1060, height: 760))
        assistant.selectPage(3); pump()
        fixtureStatus["translationEnabled"] = true
        fixtureStatus["mode"] = "adaptive"
        assistant.statusValue = LiveStatus(fixtureStatus)
        let restoredSettings = assistant.preferencesController!
        restoredSettings.update()
        check(restoredSettings.hudSwitch.isEnabled == true && restoredSettings.hudSwitch.state == .on, "hudSwitch must default to on and enabled when translation is active")
        restoredSettings.hudSwitch.state = .off
        restoredSettings.toggleHud()
        pump()
        check(lastHudCommandEnabled == false && assistant.configuration.value.hudEnabled == false, "Turning off hudSwitch must send hud_set(false) and persist hudEnabled=false")
        restoredSettings.hudSwitch.state = .on
        restoredSettings.toggleHud()
        pump()
        check(lastHudCommandEnabled == true && assistant.configuration.value.hudEnabled == true, "Turning on hudSwitch must send hud_set(true) and persist hudEnabled=true")

        DesktopApplicationTarget.installedChannelsOverride = ["stable"]
        check(DesktopApplicationTarget.bothInstalled == false, "Single-app mode must report bothInstalled == false")
        check(DesktopApplicationTarget.effectiveChannel(configured: "insiders") == "stable", "Single-app mode must auto-fallback to sole installed app")
        DesktopApplicationTarget.installedChannelsOverride = ["insiders"]
        check(DesktopApplicationTarget.installedChannels().isEmpty, "Insiders alone is not a supported installation")
        check(DesktopApplicationTarget.preferredLaunchPath() == "/Applications/Antigravity.app", "Launch must not fall back to Insiders")
        DesktopApplicationTarget.installedChannelsOverride = nil

        // Exercise the real download/cache path with local fixture bytes; no external requests or installation.
        let updateRoot = state.appendingPathComponent("update-integrity-fixtures")
        try FileManager.default.createDirectory(at: updateRoot, withIntermediateDirectories: true)
        let fakeDMG = updateRoot.appendingPathComponent("source.dmg")
        try Data("synthetic package".utf8).write(to: fakeDMG)
        let malformed = updateRoot.appendingPathComponent("malformed.sha256")
        try Data("invalid".utf8).write(to: malformed)
        let wrongName = updateRoot.appendingPathComponent("wrong-name.sha256")
        try Data((String(repeating: "0", count: 64) + "  Other.dmg\n").utf8).write(to: wrongName)
        let mismatch = updateRoot.appendingPathComponent("mismatch.sha256")
        try Data((String(repeating: "0", count: 64) + "  GravityBox-9.9.9-arm64.dmg\n").utf8).write(to: mismatch)
        let sources: [URL?] = [nil, updateRoot.appendingPathComponent("missing.sha256"), malformed, wrongName, mismatch]
        for source in sources {
            let release = AppReleaseInfo(version: "9.9.9", tagName: "v9.9.9", title: "fixture", changelog: "", publishedDate: "", htmlURL: URL(string: "https://example.invalid")!, dmgURL: fakeDMG, sha256URL: source)
            var finished = false, accepted = false
            assistant.updateManager.preDownloadRelease(release, silent: false) { result in
                if case .success = result { accepted = true }
                finished = true
            }
            waitUntil(description: "preDownloadRelease to finish") {
                finished
            }
            check(finished && !accepted && assistant.updateManager.downloadedDMGURL == nil, "Invalid or missing checksum must never produce an installable package")
        }
        let cachedDMG = state.appendingPathComponent("updates/v9.9.9/GravityBox-9.9.9-arm64.dmg")
        try FileManager.default.createDirectory(at: cachedDMG.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("previously verified synthetic package".utf8).write(to: cachedDMG)
        let cachedHash = try UpdatePackageIntegrity.fileHash(cachedDMG)
        try Data("\(cachedHash)  \(cachedDMG.lastPathComponent)\n".utf8).write(to: cachedDMG.appendingPathExtension("sha256"))
        try AppUpdateManager.verifyCachedDownload(cachedDMG)
        try Data("tampered cached package".utf8).write(to: cachedDMG)
        var rejectedCache = false
        do { try AppUpdateManager.verifyCachedDownload(cachedDMG) } catch { rejectedCache = true }
        check(rejectedCache, "Cached packages must be rehashed before installation")
        assistant.updateManager.simulateRelease(nil)

        Assistant.applicationChannel = "stable"
        assistant.configuration.value.applicationChannel = "stable"
        // Failed account changes must never export stale contents under the new account name.
        do {
            let isolated = Assistant(state: state.appendingPathComponent("usage-query-contract"))
            isolated.configuration = try ConfigurationStore(state: isolated.state)
            isolated.bridge = BackendBridge(resources: state, state: isolated.state)
            isolated.reachable = true
            var fail = false
            isolated.bridge.fixtureReply = { request in
                if fail { return ["ok": false, "error": "synthetic read failure"] }
                return ["ok": true, "period": request["period"] as? String ?? "today", "selectedAccountId": "all", "snapshotId": "stable-query-snapshot", "summary": ["availability": "complete", "totalTokens": 150, "requestCount": 1, "databasesScanned": 1, "databasesDiscovered": 1], "byModel": [], "dailyTrends": [], "todayHourly": []]
            }
            let page = UsagePage(app: isolated)
            pump()
            fail = true; page.fetch(force: true); pump()
            check(page.statusSummary.stringValue.contains("读取失败"), "Failure feedback must be present")
            fail = false; page.fetch(force: true); pump()
            check(!page.statusSummary.stringValue.contains("读取失败"), "Same snapshot success must clear an earlier failure")
            page.periodSegment.selectedSegment = 1
            fail = true; page.fetch(force: true); pump()
            check(!page.exportButton.isEnabled, "A period mismatch must disable stale export")
            if let overview = assistant.dashboardPage {
                overview.renderSummary([
                    "accounts": ["activeEmail": "test@example.invalid", "activeName": "Test", "activeTier": "PRO", "isLiveVerified": true],
                    "usage": ["todayTokens": 100, "totalTokens": 1000, "estimatedUsd": 0.1, "allTimeEstimatedUsd": 1.0, "requestCount": 1, "totalRequestCount": 10, "databasesScanned": 378, "databasesDiscovered": 378, "failedDatabasesCount": 0, "skippedLargeRecords": 0, "unknownTimeRecords": 0, "hasError": false, "availability": "partial"]
                ], isStaleFallback: false)
                check(overview.usageQualityLabel.isHidden, "Overview usageQualityLabel must remain hidden when 378/378 DBs succeeded with 0 failed/skipped/unknown despite partial historical availability")
            }
            page.updateReadStatus(["databasesScanned": 378, "databasesDiscovered": 378, "failedDatabasesCount": 0, "skippedLargeRecords": 0, "unknownTimeRecords": 0, "unpricedModels": 0, "availability": "partial", "pricing_warnings": ["旧JSON含缺少来源或归属证据的记录，原件已保留；请查看只读账本预览", "历史金额凭据缺少原始用量或时间，已单独保留待核对，不计入Token和请求数"]])
            check(page.footerBox.isHidden, "Usage footerBox must remain hidden in healthy state even with read-only legacy archive notes")
            page.updateReadStatus(["databasesScanned": 377, "databasesDiscovered": 378, "failedDatabasesCount": 1, "skippedLargeRecords": 0, "unknownTimeRecords": 0, "unpricedModels": 0, "availability": "partial"])
            check(!page.footerBox.isHidden && page.statusSummary.stringValue.contains("1"), "Usage footerBox must appear when failedDatabasesCount > 0")
            let pricingSheet = PricingSyncSheetController(app: isolated)

            // Package A: Modal sheet lifecycle, healed count, badge varieties, empty state and recheck
            let testParentWindow = makeHeadlessHostWindow(width: 800, height: 600)
            pricingSheet.show(in: testParentWindow, payload: [
                "synced": true,
                "count": 3,
                "healedCount": 12,
                "version": "2026-11-13",
                "status": ["lastCheckAt": 1794539810722.0, "modelCount": 3],
                "prices": [
                    "gemini-custom": [
                        "input": 0.5, "output": 2.5, "cached": 0.05,
                        "provenance": ["platform": "Custom", "checkedAt": "2026-11-13"]
                    ],
                    "gemini-expired": [
                        "input": 1.0, "output": 5.0, "cached": 0.1,
                        "provenance": ["platform": "Google Cloud", "checkedAt": "2026-01-01"]
                    ],
                    "gemini-legacy": [
                        "input": 0.8, "output": 4.0, "cached": 0.08
                    ]
                ],
                "pricingStatus": ["gemini-custom": "user", "gemini-expired": "expired", "gemini-legacy": "historical"]
            ])
            check(pricingSheet.sheet.sheetParent === testParentWindow, "PricingSyncSheetController must attach to parent window")
            check(pricingSheet.renderedSummaryLines.contains { $0.contains("gemini-custom [自定义]") }, "Must render user pricing status as 自定义")
            check(pricingSheet.renderedSummaryLines.contains { $0.contains("gemini-expired [已过期]") }, "Must render expired pricing status as 已过期")
            check(pricingSheet.renderedSummaryLines.contains { $0.contains("gemini-legacy [参考估算]") }, "Must render default pricing status as 参考估算")
            check(pricingSheet.subtitleLabel.stringValue.contains("已自动补齐 12 条历史未计价记录"), "Must display auto-healed count in subtitle")
            check(allTextValues(pricingSheet.sheet.contentView!).contains("价格基准已同步并补齐历史记录"), "Must display healed title")
            pricingSheet.closeSheet()
            waitForSheetDetach(on: testParentWindow, description: "PricingSyncSheetController to detach")
            check(testParentWindow.attachedSheet == nil, "PricingSyncSheetController must cleanly detach on close")

            // Empty prices dictionary
            pricingSheet.apply(payload: ["synced": true, "prices": [:]])
            check(allTextValues(pricingSheet.sheet.contentView!).contains("暂无可用的模型价格基准记录"), "Empty prices must render empty label")

            // Recheck button
            check(pricingSheet.recheckBtn.title == "重新检查" && pricingSheet.recheckBtn.frame.width >= 88, "Recheck button must be titled 重新检查 with width >= 88")
            pricingSheet.recheck()
            pump()

            // Triggering pricingSheet from PreferencesController
            let testPrefs = PreferencesController(app: isolated)
            isolated.window = testParentWindow
            let prevReply = isolated.bridge.fixtureReply
            isolated.bridge.fixtureReply = { payload in
                if payload["command"] as? String == "pricing_sync_check" {
                    return ["ok": true, "synced": true, "prices": ["model-a": ["input": 1.0, "output": 2.0, "cached": 0.1]]]
                }
                return prevReply?(payload) ?? ["ok": true]
            }
            testPrefs.checkPricingSync()
            pump()
            check(testPrefs.pricingSheet != nil && testPrefs.pricingSheet?.sheet.sheetParent === testParentWindow, "checkPricingSync must show pricingSheet attached to window")
            testPrefs.pricingSheet?.closeSheet()
            waitForSheetDetach(on: testParentWindow, description: "Preferences pricingSheet to detach")
            isolated.bridge.fixtureReply = prevReply

            pricingSheet.apply(payload: [
                "synced": true,
                "count": 2,
                "version": "2026-11-13",
                "status": ["lastCheckAt": 1794539810722.0, "modelCount": 2],
                "prices": [
                    "gemini-3.8-flash": [
                        "input": 0.75, "output": 3.75, "cached": 0.075,
                        "provenance": ["platform": "Google Cloud 标准 Global API", "checkedAt": "2026-11-12", "validUntil": "2026-12-31T23:59:59Z", "sourceUrl": "https://cloud.google.com/vertex-ai/generative-ai/pricing"]
                    ],
                    "gemini-4-hydrogen": [
                        "input": 1.5, "output": 7.5, "cached": 0.075, "cacheWrite": 0,
                        "provenance": ["platform": "Google Cloud 标准 Global API", "checkedAt": "2026-11-13", "sourceUrl": "https://cloud.google.com/model-garden/pricing?hl=en"]
                    ]
                ],
                "pricingStatus": ["gemini-3.8-flash": "confirmed", "gemini-4-hydrogen": "confirmed"],
            ])
            check(pricingSheet.sheet.contentView != nil, "PricingSyncSheetController must populate native sheet view")
            check(hasNonEmptyTooltip(pricingSheet.sheet.contentView!) == nil, "PricingSyncSheetController must have zero hover tooltips even with sourceUrl")
            func allPricingButtons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap { allPricingButtons($0) } }
            check(!allPricingButtons(pricingSheet.sheet.contentView!).contains { $0.title == "复制价格表" }, "PricingSyncSheetController must remove 复制价格表 button")
            check(pricingSheet.closeBtn.title == "完成", "PricingSyncSheetController exit button must be titled 完成")
            check(pricingSheet.subtitleLabel.isHidden && pricingSheet.subtitleLabel.stringValue.isEmpty, "PricingSyncSheetController must hide header subtitle on normal synced state")
            check(pricingSheet.summaryPill.title.hasPrefix("已同步 ") && pricingSheet.summaryPill.title.hasSuffix("· 2 款"), "PricingSyncSheetController pill must display latest sync time and active count: \(pricingSheet.summaryPill.title)")
            check(!pricingSheet.historicalNoteLabel.isHidden && pricingSheet.historicalNoteLabel.stringValue.contains("已下架模型"), "PricingSyncSheetController must explain historical pricing retention")
            check(pricingSheet.renderedSummaryLines.contains { $0.contains("官方定价 2026-11-12 · 优惠至 2026-12-31") } && !pricingSheet.renderedSummaryLines.contains { $0.contains("核对 2026") }, "PricingSyncSheetController must use Plan 1 date wording")
            try capture(pricingSheet.sheet.contentView!, output.appendingPathComponent("light-pricing-sheet.png"))
            pricingSheet.apply(payload: [
                "synced": false,
                "error": "offline",
                "status": ["lastCheckAt": 1794539910722.0, "modelCount": 1],
                "prices": [
                    "gemini-4-hydrogen": ["input": 1.5, "output": 7.5, "cached": 0.075]
                ],
                "pricingStatus": ["gemini-4-hydrogen": "confirmed"],
            ])
            check(!pricingSheet.subtitleLabel.isHidden && pricingSheet.subtitleLabel.stringValue == "检查提示：offline", "PricingSyncSheetController must show concise failure reason without unit suffix")
            check(pricingSheet.summaryPill.title.hasSuffix("· 1 款"), "PricingSyncSheetController pill must display failed check time and active count: \(pricingSheet.summaryPill.title)")

            // Real-time active / tier-aware / unpriced live / collapsible retired section assertions (zh-Hans)
            let tierPricingPayload: [String: Any] = [
                "synced": true,
                "version": "2026-11-16",
                "status": ["lastCheckAt": 1794539910722.0, "modelCount": 6],
                "unpricedLiveModels": [
                    ["key": "gemini-4.5-live", "displayName": "Gemini 4.5 Live", "disabled": false],
                    ["key": "gemini-4.5-locked", "displayName": "Gemini 4.5 Locked", "disabled": true]
                ],
                "prices": [
                    "gemini-4-other": ["input": 1.2, "output": 6.0, "cached": 0.12],
                    "gemini-4-carbon": ["input": 2.0, "output": 10.0, "cached": 0.2],
                    "gemini-4-argon": ["input": 1.5, "output": 7.5, "cached": 0.15],
                    "gemini-3.8-flash": ["input": 0.75, "output": 3.75, "cached": 0.075]
                ],
                "retiredPrices": [
                    "gemini-2.5-pro": ["input": 1.25, "output": 10.0, "cached": 0.31],
                    "claude-3.5-sonnet": ["input": 3.0, "output": 15.0, "cached": 0.3]
                ],
                "pricingStatus": [
                    "gemini-3.8-flash": "confirmed",
                    "gemini-4-argon": "confirmed",
                    "gemini-4-carbon": "confirmed",
                    "gemini-4-other": "confirmed",
                    "gemini-2.5-pro": "historical",
                    "claude-3.5-sonnet": "confirmed"
                ],
                "modelCatalogState": [
                    "gemini-4.5-live": ["availability": "unpriced_live", "displayName": "Gemini 4.5 Live"],
                    "gemini-4.5-locked": ["availability": "unpriced_live", "displayName": "Gemini 4.5 Locked"],
                    "gemini-3.8-flash": ["availability": "available", "displayName": "Gemini 3.8 Flash", "activeTier": "PRO"],
                    "gemini-4-argon": ["availability": "tier_locked", "displayName": "Gemini 4 Argon", "activeTier": "FREE"],
                    "gemini-4-carbon": ["availability": "other_tier_only", "displayName": "Gemini 4 Carbon", "availableInTiers": ["ULTRA"], "activeTier": "PRO"],
                    "gemini-4-other": ["availability": "other_tier_only", "displayName": "Gemini 4 Other", "availableInTiers": []],
                    "gemini-2.5-pro": ["availability": "retired", "displayName": "Gemini 2.5 Pro"],
                    "claude-3.5-sonnet": ["availability": "retired", "displayName": "Claude 3.5 Sonnet"]
                ]
            ]
            pricingSheet.retiredExpanded = true
            pricingSheet.show(in: testParentWindow, payload: tierPricingPayload)
            pump()
            check(pricingSheet.retiredExpanded == false, "PricingSyncSheetController.show must reset retiredExpanded to false")
            check(pricingSheet.summaryPill.title.hasSuffix("· 6 款"), "summaryPill must count only active + unpriced live (6), excluding retired: \(pricingSheet.summaryPill.title)")
            check(pricingSheet.renderedSummaryLines.count == 6, "renderedSummaryLines must contain 6 active/unpriced entries (got \(pricingSheet.renderedSummaryLines.count))")
            check(pricingSheet.renderedSummaryLines[0].contains("gemini-4.5-live [新上线 · 待定价]"), "First card must be unpriced live model: \(pricingSheet.renderedSummaryLines)")
            check(pricingSheet.renderedSummaryLines[1].contains("gemini-4.5-locked [新上线 · 暂未解锁]"), "Disabled unpriced live model must fold into single combined badge: \(pricingSheet.renderedSummaryLines)")
            check(pricingSheet.renderedSummaryLines[2].hasPrefix("gemini-3.8-flash [已核对]"), "Available rank must precede tier_locked: \(pricingSheet.renderedSummaryLines)")
            check(pricingSheet.renderedSummaryLines[3].hasPrefix("gemini-4-argon [已核对]") && pricingSheet.renderedSummaryLines[3].contains("[暂未解锁]"), "tier_locked rank must follow available")
            check(pricingSheet.renderedSummaryLines[4].hasPrefix("gemini-4-carbon [已核对]") && pricingSheet.renderedSummaryLines[4].contains("[限 ULTRA]"), "other_tier_only must sort Gemini-first by family/series and include named tiers")
            check(pricingSheet.renderedSummaryLines[5].hasPrefix("gemini-4-other [已核对]") && pricingSheet.renderedSummaryLines[5].contains("[其他套餐]"), "other_tier_only with empty availableInTiers must use generic badge")
            check(!pricingSheet.renderedSummaryLines.contains { $0.contains("gemini-2.5-pro") || $0.contains("claude-3.5-sonnet") }, "retiredPrices must be absent from renderedSummaryLines")
            check(pricingSheet.retiredToggleBtn?.isBordered == false && pricingSheet.retiredToggleBtn?.title == "▸ 已下架模型（2 款 · 仅用于历史账单核算）", "Collapsed retiredToggleBtn must show collapsed count title: \(pricingSheet.retiredToggleBtn?.title ?? "nil")")
            check(pricingSheet.retiredListStack?.isHidden == true, "retiredListStack must be hidden by default")
            check(pricingSheet.renderedRetiredSummaryLines.count == 2 && pricingSheet.renderedRetiredSummaryLines[0].contains("gemini-2.5-pro [参考估算]") && pricingSheet.renderedRetiredSummaryLines[1].contains("claude-3.5-sonnet [已核对]"), "renderedRetiredSummaryLines must sort Gemini before third-party models: \(pricingSheet.renderedRetiredSummaryLines)")
            let visibleSheetTexts = allTextValues(pricingSheet.sheet.contentView!)
            check(pricingSheet.subtitleLabel.isHidden && pricingSheet.subtitleLabel.stringValue.isEmpty, "Sheet header subtitle must stay hidden when unpriced banner already explains it: \(pricingSheet.subtitleLabel.stringValue)")
            check(visibleSheetTexts.contains("Gemini 4 Argon") && visibleSheetTexts.contains("Gemini 4.5 Live") && visibleSheetTexts.contains { $0.contains("检测到 2 组新上线模型暂未公布公开单价") }, "Sheet must render displayName and unified unpriced summary banner")
            func findPricingScrollView(_ v: NSView) -> NSScrollView? {
                if let sv = v as? NSScrollView { return sv }
                for sub in v.subviews { if let found = findPricingScrollView(sub) { return found } }
                return nil
            }
            var preExpandScrollY: CGFloat?
            if let sv = findPricingScrollView(pricingSheet.sheet.contentView!) {
                let docH = sv.documentView?.bounds.height ?? 0
                let clipH = sv.contentView.bounds.height
                let targetY = min(30.0, max(0.0, docH - clipH))
                sv.contentView.scroll(to: NSPoint(x: 0, y: targetY))
                sv.reflectScrolledClipView(sv.contentView)
                preExpandScrollY = sv.contentView.bounds.origin.y
            }
            pricingSheet.retiredToggleBtn?.performClick(nil); pump()
            check(pricingSheet.retiredExpanded == true && pricingSheet.retiredListStack?.isHidden == false, "Clicking retiredToggleBtn must expand retiredListStack")
            check(pricingSheet.retiredToggleBtn?.title == "▾ 已下架模型（2 款 · 仅用于历史账单核算）", "Expanded retiredToggleBtn must show expanded count title: \(pricingSheet.retiredToggleBtn?.title ?? "nil")")
            if let beforeY = preExpandScrollY, let sv = findPricingScrollView(pricingSheet.sheet.contentView!) {
                let afterY = sv.contentView.bounds.origin.y
                check(abs(afterY - beforeY) <= 1.0, "Expanding retired section must not jump scroll to bottom (before=\(beforeY), after=\(afterY))")
            }
            pricingSheet.retiredToggleBtn?.performClick(nil); pump()
            check(pricingSheet.retiredExpanded == false && pricingSheet.retiredListStack?.isHidden == true, "Clicking retiredToggleBtn again must collapse retiredListStack")
            pricingSheet.closeSheet(); waitForSheetDetach(on: testParentWindow, description: "Tiered PricingSyncSheetController to detach")

            // Retired-only payload must show toggle button without empty-state message
            pricingSheet.apply(payload: [
                "synced": true,
                "prices": [:],
                "retiredPrices": ["gemini-2.5-pro": ["input": 1.25, "output": 10.0, "cached": 0.31]],
                "pricingStatus": ["gemini-2.5-pro": "historical"],
                "modelCatalogState": ["gemini-2.5-pro": ["availability": "retired", "displayName": "Gemini 2.5 Pro"]],
                "status": ["modelCount": 0]
            ])
            check(pricingSheet.retiredToggleBtn != nil && !allTextValues(pricingSheet.sheet.contentView!).contains("暂无可用的模型价格基准记录"), "Retired-only payload must not show empty-state label")
            var checks = 0
            let manager = isolated.updateManager
            manager.checkTransport = { request, completion in
                checks += 1
                DispatchQueue.global().async {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)
                    completion(nil, response, nil)
                }
            }
            manager.checkForUpdates(silent: true)
            manager.checkForUpdates(silent: false)
            waitUntil(step: 0.01, description: "first background 403 update check to finish") {
                if case .checking = manager.state { return false }
                return true
            }
            pump()
            check(checks == 1, "Overlapping update checks must share the main-thread busy gate")
            manager.checkForUpdates(silent: false)
            waitUntil(step: 0.01, description: "retry background 403 update check to finish") {
                if case .checking = manager.state { return false }
                return checks == 2
            }
            pump()
            check(checks == 2, "A background 403 must reset busy state so retry can run")
            for (input, expected) in [(999, "999"), (1000, "1K"), (999499, "999K"), (999500, "1M"), (999999, "1M"), (1_000_000, "1M"), (999_500_000, "1B")] {
                check(InterfaceText.formatCompactTokens(input) == expected, "Compact number boundary must match HUD: \(input)")
            }
            let appPaths = ["/Applications/Antigravity.app"]
            check(
                Assistant.hasRunningAntigravityProcess(
                    psOutput: "/Applications/Antigravity.app/Contents/MacOS/Electron\n",
                    appPaths: appPaths
                ) == true,
                "Executable inside Antigravity.app/Contents must count as running"
            )
            check(
                Assistant.hasRunningAntigravityProcess(
                    psOutput: "/bin/zsh -c ls /Applications/Antigravity.app/Contents/Resources\n",
                    appPaths: appPaths
                ) == false,
                "Unrelated process mentioning app path in arguments must not block switching"
            )
            check(
                Assistant.hasRunningAntigravityProcess(
                    psOutput: "/Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --subclient_type hub\n",
                    appPaths: appPaths,
                    includeLanguageServer: true
                ) == true,
                "Standalone language_server must still block full quit when includeLanguageServer=true"
            )
            check(
                Assistant.hasRunningAntigravityProcess(
                    psOutput: "/Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --subclient_type hub\n",
                    appPaths: appPaths,
                    includeLanguageServer: false
                ) == false,
                "Safe debug relaunch must ignore external/detached language_server when includeLanguageServer=false"
            )
            check(
                Assistant.hasRunningAntigravityProcess(
                    psOutput: "/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper --type=gpu-process\n",
                    appPaths: appPaths,
                    includeLanguageServer: false
                ) == true,
                "Safe debug relaunch must still drain Electron helper processes when includeLanguageServer=false"
            )
            check(
                Assistant.parseDevToolsActivePort("55777\n/devtools/browser/mock-id\n") == 55777 &&
                Assistant.parseDevToolsActivePort("0\n/devtools/browser/mock-id\n") == nil &&
                Assistant.parseDevToolsActivePort("not-a-port\n") == nil,
                "parseDevToolsActivePort must accept valid TCP ports and reject invalid values"
            )
            check(
                Assistant.hasDebugPortArgument(
                    inPsOutput: "/Applications/Antigravity.app/Contents/MacOS/Antigravity --remote-debugging-port=0\n",
                    appPaths: appPaths
                ) == true &&
                Assistant.hasDebugPortArgument(
                    inPsOutput: "/Applications/Antigravity.app/Contents/MacOS/Antigravity\n",
                    appPaths: appPaths
                ) == false &&
                Assistant.hasDebugPortArgument(
                    inPsOutput: "/Applications/Other.app/Contents/MacOS/Other --remote-debugging-port=0\n",
                    appPaths: appPaths
                ) == false,
                "hasDebugPortArgument must strictly match Antigravity main executable with --remote-debugging-port"
            )
            isolated.suppressLifecycleAutoQuit(seconds: 60.0)
            let longDeadline = isolated.suppressLifecycleAutoQuitUntil
            isolated.suppressLifecycleAutoQuit(seconds: 5.0)
            check(
                isolated.suppressLifecycleAutoQuitUntil >= longDeadline,
                "Shorter lifecycle auto-quit suppression must not shorten an existing longer deadline"
            )

            // Package E: AssistantAccountUsage switch menu and cache invalidation
            isolated.cachedAccounts = []
            let emptyAccountMenu = isolated.buildAccountSwitchMenu()
            check(emptyAccountMenu.items.contains { $0.title == "暂无可用账号快照" }, "Empty account switch menu must show 暂无可用账号快照")
            isolated.cachedAccounts = accounts
            isolated.activeAccountId = "a"
            let fullAccountMenu = isolated.buildAccountSwitchMenu()
            check(fullAccountMenu.items.contains { $0.title == "管理账号…" }, "Account switch menu must contain 管理账号…")
            check(fullAccountMenu.items.contains { $0.title.contains("Alex") && $0.title.contains("PRO") }, "Account switch menu must show account name and tier")

            isolated.cachedUsageReportsByPeriod["today"] = ["summary": totals]
            check(!isolated.cachedUsageReportsByPeriod.isEmpty, "Usage report cache must be populated")
            isolated.invalidateUsageReportCache()
            check(isolated.cachedUsageReportsByPeriod.isEmpty, "invalidateUsageReportCache must clear cachedUsageReportsByPeriod")
            testParentWindow.orderOut(nil)
        }

        // Exercise the real countdown view, rather than a JS reimplementation of its old colors.
        let countdown = QuotaBarView(percentage: 80, resetText: "6天12小时后重置")
        check(countdown.resetLabel.textColor == Design.secondary, "Normal countdown stays neutral")
        countdown.update(percentage: 5, resetText: "3小时后重置")
        check(countdown.resetLabel.textColor == Design.secondary, "Low percentage does not turn a normal reset time into an urgent notice")
        countdown.update(percentage: 50, resetText: "即将重置")
        check(countdown.resetLabel.textColor != Design.secondary, "Imminent reset uses warning color")
        countdown.update(percentage: 50, resetText: "重置时间已过")
        check(countdown.resetLabel.textColor != Design.secondary, "Expired reset uses warning color")

        // Production account quota updates reuse card views, including unchanged snapshots.
        do {
            if assistant.accountsPage == nil { assistant.selectPage(1); pump() }
            let page = assistant.accountsPage!
            let windows = ["gemini":["fiveHour":bucket(80),"weekly":bucket(90)],"claude":["fiveHour":bucket(100),"weekly":bucket(70)]]
            let base: [String: Any] = ["id":"gate-account", "email":"gate@example.invalid", "revision":"gate-revision", "familyWindows":windows]
            page.fetch(["accounts":[base], "activeId":"gate-account"])
            let cards = page.cardsStack.arrangedSubviews
            page.fetch(["accounts":[base], "activeId":"gate-account"])
            check(zip(cards,page.cardsStack.arrangedSubviews).allSatisfy { $0 === $1 }, "Identical snapshots retain card views")
            func quotaViews(_ view: NSView) -> [QuotaBarView] { (view as? QuotaBarView).map{[$0]} ?? view.subviews.flatMap{quotaViews($0)} }
            for (family, key, percent, title) in [("gemini","fiveHour",40.0,"Gemini · 5 小时"),("gemini","weekly",85.0,"Gemini · 每周"),("claude","fiveHour",50.0,"Claude/GPT · 5 小时")] {
                var changed = base
                var nextWindows = windows; nextWindows[family]?[key] = bucket(percent)
                changed["familyWindows"] = nextWindows
                page.fetch(["accounts":[changed], "activeId":"gate-account"])
                check(quotaViews(page.view).contains { $0.titleLabel.stringValue == title && $0.percentageKnown && $0.percentage == Int(percent) }, "Production card refresh observes \(family)/\(key)")
                check(page.cardsStack.arrangedSubviews.count == cards.count && zip(cards,page.cardsStack.arrangedSubviews).allSatisfy { $0 === $1 }, "Account quota changes reuse existing card views")
                let cardTexts = allTextValues(page.cardsStack)
                check(!cardTexts.contains("当前账号") && !cardTexts.contains("已选记录"), "Accounts page active card must not display redundant 当前账号 or 已选记录 pill")
            }
        }

        // Production dashboard identity handling includes mismatch, missing identity and offline states.
        do {
            if assistant.dashboardPage == nil { assistant.selectPage(0); pump() }
            let page = assistant.dashboardPage!
            for (verified, liveEmail, expectedStatus) in [(true,"other@example.invalid","账号不一致"),(true,"gate@example.invalid",""),(true,"",""),(false,"","")] {
                page.renderSummary(["accounts":["activeEmail":"gate@example.invalid", "isLiveVerified":verified, "liveAccountEmail":liveEmail]], isStaleFallback:false)
                check(page.accountStatusLabel.stringValue == expectedStatus, "Production dashboard identity status for \(liveEmail)")
                check(page.activeEmailLabel.stringValue == "gate@example.invalid", "Identity warning preserves saved email")
                check(page.currentAccountPill.isHidden, "Dashboard must hide redundant currentAccountPill across verified/mismatch/offline states")
                let dashTexts = allTextValues(page.view)
                check(!dashTexts.contains("当前账号") && !dashTexts.contains("已选记录"), "Dashboard must never render 当前账号 or 已选记录 pill")
            }
        }

        // Phase A 1.1.1 regressions: P0-04/P0-06/P0-07, P1-01/P1-09/P1-21/P1-24/P1-25/P1-27/P1-28/P1-29
        do {
            let p1Host = Assistant(state: state.appendingPathComponent("p1-regressions"))
            p1Host.configuration = try ConfigurationStore(state: p1Host.state)
            p1Host.bridge = BackendBridge(resources: state, state: p1Host.state)
            p1Host.reachable = true
            var usageEventsFetches = 0
            p1Host.bridge.fixtureReply = { request in
                let cmd = request["command"] as? String ?? ""
                if cmd == "usage_events" {
                    usageEventsFetches += 1
                    let offset = request["offset"] as? Int ?? 0
                    return [
                        "ok": true, "snapshotId": "log-snap", "generated_at": 1700000000,
                        "scope": "2 DBs", "total": 450,
                        "rows": [["model": "gemini-test", "timestamp_seconds": 1700000000, "input_tokens": 100 + offset, "output_tokens": 50, "cached_tokens": 25, "cache_write_tokens": 25]]
                    ]
                }
                if cmd == "maintenance_scan" {
                    return [
                        "ok": true, "token": "scan-tok-1", "running": false,
                        "retentionDays": request["retentionDays"] as? Int ?? 7,
                        "scannedAt": 1700000000, "totalBytes": 4096, "totalFiles": 4,
                        "entries": [
                            ["name": "Cache", "bytes": 2048, "fileCount": 2, "clearable": true, "category": "safe"],
                            ["name": "GPUCache", "bytes": 1024, "fileCount": 1, "clearable": true, "category": "safe"],
                            ["name": "Code Cache", "bytes": 1024, "fileCount": 1, "clearable": true, "category": "safe"]
                        ],
                        "snapshots": [
                            ["id": "snap-1", "timestamp": 1700000000, "totalBytes": 1024, "restorable": true, "items": ["Cache"]],
                            ["id": "snap-2", "timestamp": 1699990000, "totalBytes": 1024, "restorable": true, "items": ["GPUCache"]]
                        ]
                    ]
                }
                return [
                    "ok": true, "period": request["period"] as? String ?? "today",
                    "selectedAccountId": "all", "snapshotId": "p109-snap",
                    "summary": [
                        "availability": "complete",
                        "totalTokens": 300,
                        "promptTokens": 50,
                        "cachedTokens": 50,
                        "cacheWriteTokens": 100,
                        "requestCount": 3,
                        "estimatedUsd": 0.15,
                        "databasesScanned": 2,
                        "databasesDiscovered": 2
                    ],
                    "byModel": [["model": "claude-sonnet-4.5", "totalTokens": 300, "inputTokens": 50, "outputTokens": 100, "requestCount": 3, "priced": false]],
                    "dailyTrends": [],
                    "todayHourly": [["hour": "2026-11-15 10:00", "totalTokens": 300, "requestCount": 3]]
                ]
            }

            // P0-04 + P1-09: usage page cacheWriteTokens denominator + structured pricing_warning_codes
            let uPage = UsagePage(app: p1Host)
            uPage.fetch(force: true); pump()
            check(uPage.cacheRateMetric.stringValue == "25.0%", "P1-09: UsagePage cacheHitRate denominator must include cacheWriteTokens (expected 25.0%, got \(uPage.cacheRateMetric.stringValue))")
            uPage.updateReadStatus([
                "databasesScanned": 2, "databasesDiscovered": 2,
                "pricing_warning_codes": ["legacy_json_migrated", "legacy_ledger_migrated", "historical_receipts_locked"],
                "pricing_warnings": ["Custom localized migration", "Another internal migration", "Locked receipts notice"]
            ])
            check(uPage.footerBox.isHidden, "P0-04: pricing_warning_codes must filter internal migration warnings regardless of text")
            uPage.updateReadStatus([
                "databasesScanned": 2, "databasesDiscovered": 2,
                "pricing_warnings": ["Legacy JSON archive", "Legacy ledger preserved", "Historical cost receipts"]
            ])
            check(uPage.footerBox.isHidden, "P0-04: English legacy warning prefixes must remain filtered")
            uPage.updateReadStatus([
                "databasesScanned": 2, "databasesDiscovered": 2,
                "pricing_warning_codes": ["pricing_rate_anomaly"],
                "pricing_warnings": ["Pricing interval check needed"]
            ])
            check(!uPage.footerBox.isHidden && uPage.statusSummary.stringValue.contains("Pricing interval check needed"), "P0-04: Unknown warning codes must stay visible")
            check(InterfaceText.isInternalDualWindowError("Dual window unavailable") && InterfaceText.isInternalDualWindowError("双周期缺失") && !InterfaceText.isInternalDualWindowError("HTTP 500"), "P0-04: Dual window error helper must handle English and Chinese")

            // P1-09 + P1-28 + P0-07: MenuPanel cacheWriteTokens, unavailable clearing, cachedRecommendedAccountId + language reopen
            L10n.shared.setLanguage("zh-Hans", notify: false)
            p1Host.cachedUsageReportsByPeriod["today"] = [
                "snapshotId": "menu-p109",
                "summary": [
                    "availability": "complete",
                    "totalTokens": 300,
                    "promptTokens": 50,
                    "cachedTokens": 50,
                    "cacheWriteTokens": 100,
                    "requestCount": 3,
                    "estimatedUsd": 0.15,
                    "databasesScanned": 2,
                    "databasesDiscovered": 2
                ],
                "byModel": [["model": "gemini-test", "totalTokens": 300]],
                "todayHourly": [["hour": "2026-11-15 10:00", "totalTokens": 300, "requestCount": 3]]
            ]
            p1Host.cachedAccounts = [
                ["id": "a", "email": "a@example.invalid", "name": "Alpha", "subscription_tier": "PRO"],
                ["id": "b", "email": "b@example.invalid", "name": "Beta", "subscription_tier": "PRO"]
            ]
            p1Host.activeAccountId = "a"
            p1Host.cachedRecommendedAccountId = "b"
            let mPanel = p1Host.ensureMenuPanelController()
            mPanel.selectTab(0, persist: false); mPanel.panelWillOpen(); pump()
            check(mPanel.cacheTile.valueLabel.stringValue == "25.0%", "P1-09: MenuPanel cacheTile must include cacheWriteTokens in denominator")
            check(!mPanel.trendChart.buckets.isEmpty && !mPanel.modelsListStack.arrangedSubviews.isEmpty, "MenuPanel chart and models must populate on complete data")

            p1Host.cachedUsageReportsByPeriod["today"] = ["summary": ["availability": "unavailable"]]
            mPanel.panelWillOpen(); pump()
            check(mPanel.trendChart.buckets.isEmpty && mPanel.modelsListStack.arrangedSubviews.isEmpty && mPanel.modelsHeaderCountLabel.stringValue.isEmpty && mPanel.toggleModelsButton.isHidden, "P1-28: Unavailable state must clear old MenuPanel trend chart and model rows")

            mPanel.selectTab(2, persist: false); mPanel.panelWillOpen(); pump()
            check(allTextValues(mPanel.accountsCardsStack).contains("推荐备用"), "P0-07: MenuPanel must read cachedRecommendedAccountId even before AccountsPage opens")
            p1Host.setGlobalLanguage("en"); pump()
            check(p1Host.menuPanelController == nil && p1Host.menuPanel?.contentView == nil && p1Host.menuPanel?.contentViewController == nil, "P0-07: Closed panel controller and contentView must clear on language switch")
            let panelCtrlForTest = p1Host.ensureMenuPanelController()
            let floatingPanel = p1Host.ensureMenuPanel(hosting: panelCtrlForTest)
            check(floatingPanel.styleMask.contains(.nonactivatingPanel) && floatingPanel.canBecomeKey && !floatingPanel.canBecomeMain && !floatingPanel.hidesOnDeactivate, "MenuFloatingPanel must use non-activating keyable panel so background/Stage Manager clicks open reliably without pulling main window")
            check(floatingPanel.contentViewController == nil && floatingPanel.contentView === panelCtrlForTest.view, "MenuFloatingPanel must attach controller.view directly without contentViewController to prevent preferredContentSize layout conflicts")
            check(panelCtrlForTest.preferredContentSize == .zero, "MenuPanelController hosted in MenuFloatingPanel must clear preferredContentSize so AppKit does not install priority-501 height constraints")
            check(floatingPanel.collectionBehavior.contains(.canJoinAllSpaces) && floatingPanel.collectionBehavior.contains(.fullScreenAuxiliary) && floatingPanel.collectionBehavior.contains(.canJoinAllApplications) && floatingPanel.collectionBehavior.contains(.ignoresCycle), "MenuFloatingPanel must stay reachable across Spaces, full-screen apps, and Stage Manager")
            check(floatingPanel.level == .statusBar && floatingPanel.level.rawValue < NSWindow.Level.popUpMenu.rawValue, "MenuFloatingPanel must sit at .statusBar level (25) so screenshot tools can snap to it and NSMenu layers above it")
            let rootView = panelCtrlForTest.view as? MenuPanelRootView
            check(rootView != nil && rootView?.maskImage != nil && (rootView?.layer?.cornerRadius ?? -1) == 0 && (rootView?.layer?.borderWidth ?? -1) == 0 && rootView?.subviews.last is MenuPanelRimOverlayView, "MenuPanelRootView must use maskImage rounded clipping and top MenuPanelRimOverlayView without layer cornerRadius/border artifacts")
            floatingPanel.setFrame(NSRect(x: 400, y: 300, width: MenuPanelController.panelWidth, height: 420), display: false)
            let anchoredMaxY = floatingPanel.frame.maxY
            p1Host.resizeMenuPanel(to: NSSize(width: MenuPanelController.panelWidth, height: 500), animate: false)
            check(abs(floatingPanel.frame.maxY - anchoredMaxY) <= 1 && abs(floatingPanel.frame.height - 500) <= 1, "Resizing MenuFloatingPanel upward must keep top edge anchored below menu bar (beforeMaxY=\(anchoredMaxY), after=\(floatingPanel.frame))")
            p1Host.resizeMenuPanel(to: NSSize(width: MenuPanelController.panelWidth, height: 360), animate: false)
            check(abs(floatingPanel.frame.maxY - anchoredMaxY) <= 1 && abs(floatingPanel.frame.height - 360) <= 1, "Resizing MenuFloatingPanel downward must keep top edge anchored below menu bar (beforeMaxY=\(anchoredMaxY), after=\(floatingPanel.frame))")
            p1Host.menuPanelController = nil
            p1Host.menuPanel?.contentView = nil
            let reopenedPanel = p1Host.ensureMenuPanelController()
            reopenedPanel.selectTab(2, persist: false); reopenedPanel.panelWillOpen(); pump()
            check(allTextValues(reopenedPanel.accountsCardsStack).contains("Recommended") && !allTextValues(reopenedPanel.accountsCardsStack).contains("推荐备用"), "P0-07: Recreated MenuPanel must preserve recommendation badge in English")

            // P1-28: UsageLog jumpToPage single fetch on blurred Enter
            let sheetHostWin = makeHeadlessHostWindow(width: 820, height: 620)
            let logCtrl = UsageLogController(app: p1Host, period: "today")
            logCtrl.show(in: sheetHostWin) {}
            pump()
            check(usageEventsFetches == 1, "UsageLog initial show must trigger one fetch")
            logCtrl.sheet.makeFirstResponder(logCtrl.pageNumber)
            logCtrl.pageNumber.stringValue = "2"
            logCtrl.jumpToPage(); pump()
            check(usageEventsFetches == 2, "P1-28: UsageLog jumpToPage + focus loss must not double-fetch usage_events (got \(usageEventsFetches))")
            logCtrl.closeSheet(); waitForSheetDetach(on: sheetHostWin, description: "P1-28 UsageLogController to detach")

            // P1-28: Maintenance busy-state locks scanButton, clearButton, switches, retentionPopup & restoreLatestButton
            L10n.shared.setLanguage("zh-Hans", notify: false)
            let cacheCtrl = CachePage(app: p1Host)
            cacheCtrl.fetch(force: true); pump()
            cacheCtrl.fetch(force: true)
            check(cacheCtrl.busy && !cacheCtrl.scanButton.isEnabled && !cacheCtrl.retentionPopup.isEnabled && !cacheCtrl.clearButton.isEnabled && !cacheCtrl.runtimeCacheSwitch.isEnabled && !cacheCtrl.historyLogsSwitch.isEnabled && !cacheCtrl.restoreLatestButton.isEnabled, "P1-28: Maintenance busy state must disable all interactive controls during scan")
            pump()
            check(!cacheCtrl.busy && cacheCtrl.scanButton.isEnabled && cacheCtrl.runtimeCacheSwitch.isEnabled && cacheCtrl.restoreLatestButton.isEnabled, "Maintenance scan completion must restore interactive controls")

            // Verify blocked sub-items (e.g. symlinked GPUCache) are silently skipped in 2-bucket projection & smart_clear dispatches scopes cleanly
            var smartClearedScopes: [String] = []
            let prevP1Reply = p1Host.bridge.fixtureReply
            p1Host.bridge.fixtureReply = { request in
                let cmd = request["command"] as? String ?? ""
                if cmd == "maintenance_scan" {
                    return [
                        "ok": true, "token": "scan-tok-partial-block", "running": false,
                        "retentionDays": 7, "scannedAt": 1700000010, "totalBytes": 3072, "totalFiles": 3,
                        "trashDir": "/tmp/gb-fallback-trash", "usingFallbackTrash": true,
                        "entries": [
                            ["name": "Cache", "bytes": 2048, "fileCount": 2, "clearable": true, "category": "safe", "defaultSelected": true],
                            ["name": "Code Cache", "bytes": 1024, "fileCount": 1, "clearable": true, "category": "safe", "defaultSelected": true],
                            ["name": "GPUCache", "bytes": 0, "fileCount": 0, "clearable": false, "reason": "缓存含符号链接，已跳过", "category": "safe", "defaultSelected": true]
                        ],
                        "snapshots": []
                    ]
                }
                if cmd == "maintenance_smart_clear" {
                    smartClearedScopes = (request["scopes"] as? [String]) ?? []
                    return ["ok": true, "moved": 2, "clearedBytes": 3072, "trashDir": "/tmp/gb-fallback-trash", "usingFallbackTrash": true, "supersededSnapshotPaths": []]
                }
                return prevP1Reply?(request) ?? ["ok": true]
            }
            cacheCtrl.fetch(force: true); pump()
            check(cacheCtrl.clearButton.isEnabled && cacheCtrl.runtimeBucketBytes == 3072 && cacheCtrl.restoreLatestButton.isHidden && cacheCtrl.usingFallbackTrash && cacheCtrl.activeTrashPath == "/tmp/gb-fallback-trash", "Blocked sub-item must be silently skipped while keeping healthy runtime bucket enabled")
            cacheCtrl.clearSelectedCaches(); pump()
            check(smartClearedScopes == ["runtime_cache"], "clearSelectedCaches must dispatch maintenance_smart_clear with active scopes")
            p1Host.bridge.fixtureReply = prevP1Reply
            sheetHostWin.orderOut(nil)

            // P0-06: Open modal sheets remain alive & interactive while background window re-localizes on language change
            assistant.setGlobalLanguage("zh-Hans"); pump()
            assistant.selectPage(3); pump()
            let sheetObj = PricingSyncSheetController(app: assistant)
            assistant.preferencesController?.pricingSheet = sheetObj
            sheetObj.show(in: window, payload: ["synced": true, "prices": [:], "status": ["modelCount": 0]]) { [weak prefs = assistant.preferencesController] in
                prefs?.pricingSheet = nil
            }
            pump()
            check(window.activeSheetWindow === sheetObj.sheet, "P0-06: PricingSyncSheetController must attach before language switch")
            assistant.setGlobalLanguage("en"); pump()
            check(window.activeSheetWindow === sheetObj.sheet && sheetObj.closeBtn.target != nil, "P0-06: PricingSyncSheetController must stay retained and responsive across live language change")
            check(assistant.names == ["Overview", "Accounts", "Usage", "Settings", "About"], "P0-06: Background main window must re-localize while modal sheet stays open")
            sheetObj.closeBtn.performClick(nil); waitForSheetDetach(on: window, description: "P0-06 PricingSyncSheetController to detach")
            check(window.activeSheetWindow == nil, "P0-06: PricingSyncSheetController close button must dismiss cleanly after language switch")

            assistant.selectPage(1); pump()
            let policySheet = AccountPolicySheet(app: assistant, config: ["strategy": "priority", "monitored_model": "gemini", "reserve_percentage": 10, "candidate_min_percentage": 30]) {}
            assistant.accountsPage?.policySheet = policySheet
            policySheet.show(in: window) { [weak page = assistant.accountsPage] in
                page?.policySheet = nil
            }
            pump()
            check(window.activeSheetWindow === policySheet.window, "P0-06: AccountPolicySheet must attach before language switch")
            assistant.setGlobalLanguage("zh-Hans"); pump()
            check(window.activeSheetWindow === policySheet.window && assistant.names == ["总览", "账号", "用量", "设置", "关于"], "P0-06: AccountPolicySheet must stay open while background window switches back to Chinese")
            policySheet.cancel(); waitForSheetDetach(on: window, description: "P0-06 AccountPolicySheet to detach")
            check(window.activeSheetWindow == nil, "P0-06: AccountPolicySheet cancel must work after language switch")

            // P1-01, P1-21, P1-25, P1-27, P1-29 English assertions
            assistant.setGlobalLanguage("en"); pump()
            let updateBuild = assistant.updateManager.currentBuildDisplay
            check((Int(updateBuild) ?? 0) >= 10101, "P1-01: UpdateManager currentBuildDisplay fallback/build must be >= 10101 (got \(updateBuild))")
            let updaterScript = AppUpdateManager.buildDetachedUpdaterScript(myPid: 99999, workDirPath: "/tmp/gb-upd", i18nDirPath: "/tmp/gb-upd/i18n", appLanguage: "en")
            let expectedUpdaterExport = String(AppUpdateManager.shellQuote("export GRAVITYBOX_I18N_DIR=" + AppUpdateManager.shellQuote("/tmp/gb-upd/i18n") + " GRAVITYBOX_LANGUAGE=" + AppUpdateManager.shellQuote("en")).dropFirst().dropLast())
            check(updaterScript.contains(expectedUpdaterExport), "P1-21: Updater script must propagate GRAVITYBOX_I18N_DIR and GRAVITYBOX_LANGUAGE")
            let cleanedNotes = AppUpdateManager.formatReleaseNotes("## Checksum\nsha256: abc\n## Release Notes\n- English layout polish\n")
            check(!cleanedNotes.contains("Checksum") && cleanedNotes.contains("English layout polish"), "P1-25: Boilerplate heading filter must drop English Checksum sections")
            let wideRefreshBtn = InlineRefreshButton("Check for Updates", width: 124, target: nil, action: #selector(PricingSyncSheetController.closeSheet))
            check(wideRefreshBtn.intrinsicContentSize.width > 124, "P1-27: InlineRefreshButton must expand beyond 124pt for longer English label (got \(wideRefreshBtn.intrinsicContentSize.width))")

            assistant.selectPage(0); pump()
            check(assistant.dashboardPage?.usageMetric.allowsDefaultTighteningForTruncation == true, "P1-27: Overview cost metric must enable allowsDefaultTighteningForTruncation")
            let enModelRow = ModelUsageRow(name: "unpriced-test", tokens: "100", input: "50", output: "50", requests: 1, cost: L10n.t("menu_panel.usage.unpriced"), share: 100, isUnpriced: true)
            check(enModelRow.costLabel.textColor == Design.secondary && enModelRow.costLabel.stringValue != "未计价", "P1-25: English unpriced model row must style cleanly without Chinese sentinel")

            let enUsagePage = UsagePage(app: p1Host)
            enUsagePage.fetch(force: true); pump()
            let usageTexts = allTextValues(enUsagePage.view)
            check(usageTexts.allSatisfy { $0.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) == nil }, "P1-29: English UsagePage must not leak Chinese characters: \(usageTexts.filter { $0.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil })")
            let enMaintSheet = MaintenanceSheetController(app: p1Host)
            enMaintSheet.cachePage.fetch(force: true); pump()
            enMaintSheet.sheet.contentView?.layoutSubtreeIfNeeded(); pump()
            let maintTexts = allTextValues(enMaintSheet.sheet.contentView!)
            check(maintTexts.allSatisfy { $0.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) == nil }, "English MaintenanceSheetController must not leak Chinese characters: \(maintTexts.filter { $0.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil })")
            check(hasNonEmptyTooltip(enMaintSheet.sheet.contentView!) == nil, "MaintenanceSheetController must have zero hover tooltips")
            for enLbl in [enMaintSheet.cachePage.reclaimableTitleLabel, enMaintSheet.cachePage.reclaimableValueLabel, enMaintSheet.cachePage.heroSubtitleLabel, enMaintSheet.cachePage.safeLegendLabel, enMaintSheet.cachePage.statefulLegendLabel, enMaintSheet.cachePage.protectedLegendLabel, enMaintSheet.cachePage.runtimeTitleLabel, enMaintSheet.cachePage.runtimeSubtitleLabel, enMaintSheet.cachePage.historyTitleLabel, enMaintSheet.cachePage.historySubtitleLabel, enMaintSheet.cachePage.recoveryTitleLabel, enMaintSheet.cachePage.recoverySubtitleLabel] where !enLbl.isHidden && !enLbl.stringValue.isEmpty {
                let natW = (enLbl.stringValue as NSString).size(withAttributes: [.font: enLbl.font!]).width
                check(enLbl.bounds.width + 1.5 >= floor(natW), "English Maintenance label must not truncate (\(enLbl.stringValue)): \(enLbl.bounds.width) < \(natW)")
            }
            // Verify all 4 Maintenance NSPopover kinds & running confirmation in English mode (both minimal fixture & Chinese-titled main fixture) emit zero CJK & zero tooltips
            let enMainCache = assistant.cachePage ?? CachePage(app: assistant)
            enMainCache.fetch(force: true); pump()
            for (hostLabel, targetCache) in [("minimal", enMaintSheet.cachePage), ("mainFixture", enMainCache)] {
                let confirmEn = targetCache.buildRunningClearConfirmationBody()
                check(confirmEn.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) == nil && (confirmEn.contains("selected categories") || confirmEn.contains("selected category")), "English \(hostLabel) confirmation body must not leak CJK: \(confirmEn)")
                for kind in [CachePage.DetailKind.runtime, .history, .protected, .snapshot] {
                    targetCache.openDetailPopover(kind, relativeTo: targetCache.runtimeInfoButton)
                    guard let popView = targetCache.detailPopover?.contentViewController?.view else {
                        check(false, "English \(hostLabel) popover \(kind.rawValue) must build contentViewController")
                        continue
                    }
                    let popTexts = allTextValues(popView)
                    let popLeaks = popTexts.filter { $0.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil }
                    check(popLeaks.isEmpty, "English \(hostLabel) \(kind.rawValue) popover must not leak Chinese characters: \(popLeaks)")
                    check(hasNonEmptyTooltip(popView) == nil, "English \(hostLabel) \(kind.rawValue) popover must have zero hover tooltips")
                    if kind == .runtime {
                        check(popTexts.contains("App Runtime Caches") && popTexts.contains("Network & Static Asset Cache"), "English \(hostLabel) runtime popover must localize catalog titles: \(popTexts)")
                    } else if kind == .protected {
                        check(popTexts.contains("Protected Core Data") && popTexts.contains("Never Touched"), "English \(hostLabel) protected popover must render Never Touched badge: \(popTexts)")
                    } else if kind == .snapshot {
                        check(popTexts.contains("Last Cleanup Snapshot") && popTexts.contains("Network & Static Asset Cache"), "English \(hostLabel) snapshot popover must localize snapshot itemTitles: \(popTexts)")
                    }
                }
                targetCache.dismissDetailPopover()
            }

            // English pricing sheet localization & live language switch coverage
            let enPricingHost = Assistant(state: state.appendingPathComponent("en-pricing-sheet"))
            enPricingHost.configuration = try ConfigurationStore(state: enPricingHost.state)
            enPricingHost.bridge = BackendBridge(resources: state, state: enPricingHost.state)
            let enPricingPayload: [String: Any] = [
                "synced": true,
                "status": ["lastCheckAt": 1794539910722.0, "modelCount": 4],
                "unpricedLiveModels": [
                    ["key": "gemini-4.5-live", "displayName": "Gemini 4.5 Live", "disabled": false]
                ],
                "prices": [
                    "gemini-3.8-flash": ["input": 0.75, "output": 3.75, "cached": 0.075],
                    "gemini-4-argon": ["input": 1.5, "output": 7.5, "cached": 0.15],
                    "gemini-4-carbon": ["input": 2.0, "output": 10.0, "cached": 0.2]
                ],
                "retiredPrices": [
                    "claude-3.5-sonnet": ["input": 3.0, "output": 15.0, "cached": 0.3],
                    "gemini-2.5-pro": ["input": 1.25, "output": 10.0, "cached": 0.31]
                ],
                "pricingStatus": [
                    "gemini-3.8-flash": "confirmed",
                    "gemini-4-argon": "confirmed",
                    "gemini-4-carbon": "confirmed",
                    "claude-3.5-sonnet": "confirmed",
                    "gemini-2.5-pro": "historical"
                ],
                "modelCatalogState": [
                    "gemini-4.5-live": ["availability": "unpriced_live", "displayName": "Gemini 4.5 Live"],
                    "gemini-3.8-flash": ["availability": "available", "displayName": "Gemini 3.8 Flash"],
                    "gemini-4-argon": ["availability": "tier_locked", "displayName": "Gemini 4 Argon"],
                    "gemini-4-carbon": ["availability": "other_tier_only", "displayName": "Gemini 4 Carbon", "availableInTiers": ["ULTRA"]],
                    "claude-3.5-sonnet": ["availability": "retired", "displayName": "Claude 3.5 Sonnet"],
                    "gemini-2.5-pro": ["availability": "retired", "displayName": "Gemini 2.5 Pro"]
                ]
            ]
            assistant.setGlobalLanguage("zh-Hans"); pump()
            let enPricingSheet = PricingSyncSheetController(app: enPricingHost)
            enPricingSheet.show(in: window, payload: enPricingPayload)
            pump()
            check(enPricingSheet.retiredToggleBtn?.title == "▸ 已下架模型（2 款 · 仅用于历史账单核算）", "Live switch test starts in zh-Hans before switching to en")
            assistant.setGlobalLanguage("en"); pump()
            check(enPricingSheet.retiredToggleBtn?.title == "▸ Deprecated Models (2 · Historical Ledger Only)", "Live setGlobalLanguage(\"en\") must localize collapsed toggle title: \(enPricingSheet.retiredToggleBtn?.title ?? "nil")")
            enPricingSheet.retiredToggleBtn?.performClick(nil); pump()
            check(enPricingSheet.retiredToggleBtn?.title == "▾ Deprecated Models (2 · Historical Ledger Only)", "Expanded English toggle title must match spec: \(enPricingSheet.retiredToggleBtn?.title ?? "nil")")
            let enPricingTexts = allTextValues(enPricingSheet.sheet.contentView!)
            check(enPricingSheet.subtitleLabel.isHidden && enPricingSheet.subtitleLabel.stringValue.isEmpty, "English pricing sheet header subtitle must stay hidden when unpriced banner is shown: \(enPricingSheet.subtitleLabel.stringValue)")
            check(enPricingTexts.contains("New · Unpriced") && enPricingTexts.contains("Locked") && enPricingTexts.contains("ULTRA Only") && enPricingTexts.contains("Deprecated") && enPricingTexts.contains { $0.contains("Detected 1 newly launched model(s) without public rates yet") }, "English pricing sheet must localize all badges and unified banner: \(enPricingTexts)")
            let enPricingCjkLeaks = enPricingTexts.filter { $0.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil }
            check(enPricingCjkLeaks.isEmpty, "English pricing sheet must not leak Chinese characters: \(enPricingCjkLeaks)")
            enPricingSheet.closeSheet(); waitForSheetDetach(on: window, description: "English PricingSyncSheetController to detach")

            assistant.setGlobalLanguage("zh-Hans"); pump()

            // Antigravity hostOrder native ordering + 0-to-1 pill decluttering + non-truncated model IDs
            let orderedHostSheet = PricingSyncSheetController(app: enPricingHost)
            let hostOrderPayload: [String: Any] = [
                "synced": true,
                "status": ["lastCheckAt": 1794539910722.0, "modelCount": 11],
                "prices": [
                    "claude-sonnet-4-6": ["input": 3.0, "output": 15.0, "cached": 0.3],
                    "gemini-3-flash": ["input": 0.5, "output": 3.0, "cached": 0.05],
                    "claude-opus-4-6": ["input": 5.0, "output": 25.0, "cached": 0.5, "cacheWrite": 6.25],
                    "gemini-4-carbon": ["input": 2.0, "output": 10.0, "cached": 0.1, "provenance": ["checkedAt": "2026-11-13", "validUntil": "2026-11-30T23:59:59Z", "sourceUrl": "https://cloud.google.com/model-garden/pricing?hl=en"]],
                    "gpt-oss-120b": ["input": 0.15, "output": 0.6, "cached": 0.075],
                    "claude-sonnet-5-5": ["input": 2.0, "output": 10.0, "cached": 0.1, "cacheWrite": 2.5],
                    "claude-opus-5-5": ["input": 4.0, "output": 20.0, "cached": 0.2, "cacheWrite": 5.0],
                    "gemini-3.8-flash": ["input": 0.75, "output": 3.75, "cached": 0.075],
                    "gemini-4-hydrogen": ["input": 1.5, "output": 7.5, "cached": 0.075],
                    "gemini-4-argon": ["input": 1.5, "output": 7.5, "cached": 0.075],
                    "gemini-4-neon": ["input": 2.5, "output": 12.5, "cached": 0.25]
                ],
                "pricingStatus": [
                    "gemini-4-neon": "confirmed",
                    "gemini-4-argon": "confirmed",
                    "gemini-4-hydrogen": "confirmed",
                    "gemini-3.8-flash": "confirmed",
                    "claude-opus-5-5": "confirmed",
                    "claude-sonnet-5-5": "confirmed",
                    "gpt-oss-120b": "historical",
                    "gemini-4-carbon": "confirmed",
                    "gemini-3-flash": "historical",
                    "claude-opus-4-6": "confirmed",
                    "claude-sonnet-4-6": "confirmed"
                ],
                "modelCatalogState": [
                    "gemini-4-neon": ["availability": "available", "displayName": "Gemini 4 Neon", "hostOrder": 0],
                    "gemini-4-argon": ["availability": "available", "displayName": "Gemini 4 Argon", "hostOrder": 1],
                    "gemini-4-hydrogen": ["availability": "available", "displayName": "Gemini 4 Hydrogen", "hostOrder": 2],
                    "gemini-3.8-flash": ["availability": "available", "displayName": "Gemini 3.8 Flash", "hostOrder": 3],
                    "claude-opus-5-5": ["availability": "available", "displayName": "Claude Opus 5.5", "hostOrder": 4],
                    "claude-sonnet-5-5": ["availability": "available", "displayName": "Claude Sonnet 5.5", "hostOrder": 5],
                    "gpt-oss-120b": ["availability": "available", "displayName": "GPT-OSS 120B", "hostOrder": 6],
                    "gemini-4-carbon": ["availability": "tier_locked", "displayName": "Gemini 4 Carbon", "hostOrder": 7],
                    "gemini-3-flash": ["availability": "other_tier_only", "displayName": "Gemini 3 Flash", "availableInTiers": ["FREE"]],
                    "claude-opus-4-6": ["availability": "other_tier_only", "displayName": "Claude Opus 4.6", "availableInTiers": ["FREE"]],
                    "claude-sonnet-4-6": ["availability": "other_tier_only", "displayName": "Claude Sonnet 4.6", "availableInTiers": ["FREE"]]
                ]
            ]
            orderedHostSheet.show(in: window, payload: hostOrderPayload)
            pump()
            let orderedKeys = orderedHostSheet.renderedSummaryLines.compactMap { $0.split(separator: " ").first.map(String.init) }
            check(orderedKeys == [
                "gemini-4-neon", "gemini-4-argon", "gemini-4-hydrogen", "gemini-3.8-flash",
                "claude-opus-5-5", "claude-sonnet-5-5", "gpt-oss-120b", "gemini-4-carbon",
                "gemini-3-flash", "claude-opus-4-6", "claude-sonnet-4-6"
            ], "Option 1 must follow Antigravity hostOrder for current plan then Gemini-first other plans (got \(orderedKeys))")
            func countPills(in view: NSView) -> Int {
                (view is PillBadge ? 1 : 0) + view.subviews.reduce(0) { $0 + countPills(in: $1) }
            }
            func collectTextFields(_ v: NSView) -> [NSTextField] {
                ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap { collectTextFields($0) }
            }
            let cards = orderedHostSheet.listStack.arrangedSubviews.compactMap { $0 as? DesignCardBox }
            check(cards.count == 11, "Expected 11 model cards (got \(cards.count))")
            check(cards.allSatisfy { countPills(in: $0) <= 1 }, "Every pricing card must show at most 1 pill badge")
            check(countPills(in: cards[0]) == 0, "Confirmed available model card (gemini-4-neon) must show 0 pills for visual clarity")
            check(countPills(in: cards[6]) == 0 && allTextValues(cards[6]).contains { $0.contains("参考估算") }, "Historical available card (gpt-oss-120b) must show 0 pills and move 参考估算 to line 2 metadata")
            check(countPills(in: cards[7]) == 1 && allTextValues(cards[7]).contains("暂未解锁"), "Locked current-plan card must show single 暂未解锁 pill")
            let orderedTexts = allTextValues(orderedHostSheet.sheet.contentView!)
            check(orderedTexts.contains("当前账号模型") && orderedTexts.contains("其他套餐模型"), "Section headers must separate current and other plan models")
            check(!orderedTexts.contains("已核对"), "Verified available cards must omit redundant 已核对 pills")
            orderedHostSheet.sheet.contentView?.layoutSubtreeIfNeeded()
            check(abs(orderedHostSheet.listScroll.bounds.height - (orderedHostSheet.listCard.bounds.height - 20)) <= 1.0, "Pricing listScroll must fill listCard vertically without bottom blank gap (scrollH=\(orderedHostSheet.listScroll.bounds.height), cardH=\(orderedHostSheet.listCard.bounds.height))")
            if let carbonKeyLabel = collectTextFields(cards[7]).first(where: { $0.stringValue == "gemini-4-carbon" }) {
                let natW = (carbonKeyLabel.stringValue as NSString).size(withAttributes: [.font: carbonKeyLabel.font!]).width
                check(carbonKeyLabel.bounds.width + 1.0 >= ceil(natW), "Model key label must not truncate when single pill + moved date free row width (\(carbonKeyLabel.bounds.width) < \(natW))")
            } else {
                check(false, "Expected full gemini-4-carbon key label on locked card")
            }
            orderedHostSheet.closeSheet(); waitForSheetDetach(on: window, description: "Ordered PricingSyncSheetController to detach")

            assistant.setGlobalLanguage("zh-Hans"); pump()

            // Dynamic per-tier quotaGroups across Overview, Accounts, MenuPanel, and ModelIcons
            check(ModelIcons.brands(for: "Orchestrator (Argon)") == ["gemini"], "Orchestrator group resolves Gemini brand icon")

            let ultraAcc: [String: Any] = [
                "id": "ultra-1",
                "name": "Ultra User",
                "email": "ultra@example.invalid",
                "subscription_tier": "ULTRA",
                "status": "normal",
                "is_current": true,
                "quotaGroups": [
                    [
                        "key": "gemini",
                        "displayName": "Gemini",
                        "summaryLabel": "Gemini",
                        "brands": ["gemini"],
                        "isStandalone": false,
                        "availability": "available",
                        "quotaState": "known",
                        "windows": [
                            ["id": "five_hour", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.64, "stale": false, "resetCountdown": "4小时后重置"],
                            ["id": "weekly", "period": "weekly", "label": "每周", "known": true, "remaining": 0.64, "stale": false, "resetCountdown": "6天后重置"]
                        ]
                    ],
                    [
                        "key": "claude_gpt",
                        "displayName": "Claude/GPT",
                        "summaryLabel": "Claude/GPT",
                        "brands": ["claude", "gpt"],
                        "isStandalone": false,
                        "availability": "available",
                        "quotaState": "known",
                        "windows": [
                            ["id": "five_hour", "period": "5h", "label": "5 小时", "known": true, "remaining": 1.0, "stale": false, "resetCountdown": "5小时后重置"],
                            ["id": "weekly", "period": "weekly", "label": "每周", "known": true, "remaining": 1.0, "stale": false, "resetCountdown": "7天后重置"]
                        ]
                    ]
                ]
            ]
            let proAcc: [String: Any] = [
                "id": "pro-1",
                "name": "Pro User",
                "email": "pro@example.invalid",
                "subscription_tier": "PRO",
                "status": "normal",
                "is_current": true,
                "quotaGroups": [
                    ["key": "gemini", "displayName": "Gemini", "summaryLabel": "Gemini", "brands": ["gemini"], "isStandalone": false, "availability": "available", "quotaState": "known", "windows": [["id": "five_hour", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.53, "stale": false], ["id": "weekly", "period": "weekly", "label": "每周", "known": true, "remaining": 0.53, "stale": false]]],
                    ["key": "claude_gpt", "displayName": "Claude/GPT", "summaryLabel": "Claude/GPT", "brands": ["claude", "gpt"], "isStandalone": false, "availability": "available", "quotaState": "known", "windows": [["id": "five_hour", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.76, "stale": false], ["id": "weekly", "period": "weekly", "label": "每周", "known": true, "remaining": 0.76, "stale": false]]],
                    ["key": "argon", "displayName": "Gemini 4 Argon", "summaryLabel": "Argon", "brands": ["gemini"], "isStandalone": true, "availability": "available", "quotaState": "known", "windows": [["id": "weekly", "period": "weekly", "label": "每周", "known": true, "remaining": 0.64, "stale": false, "resetCountdown": "6天后重置"]]]
                ]
            ]
            let freeAcc: [String: Any] = [
                "id": "free-1",
                "name": "Free User",
                "email": "free@example.invalid",
                "subscription_tier": "FREE",
                "status": "normal",
                "is_current": true,
                "familyWindows": [
                    "gemini": ["model_quota": ["remaining": 1.0, "known": true, "stale": false]],
                    "claude": ["model_quota": ["remaining": 0.8, "known": true, "stale": false]]
                ],
                "argonStatus": ["availability": "disabled", "quotaState": "not_reported"]
            ]

            let ultraDashAcc: [String: Any] = [
                "activeEmail": "ultra@example.invalid",
                "activeName": "Ultra User",
                "activeTier": "ULTRA",
                "isLiveVerified": true,
                "quotaGroups": ultraAcc["quotaGroups"] ?? []
            ]
            let proDashAcc: [String: Any] = [
                "activeEmail": "pro@example.invalid",
                "activeName": "Pro User",
                "activeTier": "PRO",
                "isLiveVerified": true,
                "quotaGroups": proAcc["quotaGroups"] ?? []
            ]
            let freeDashAcc: [String: Any] = [
                "activeEmail": "free@example.invalid",
                "activeName": "Free User",
                "activeTier": "FREE",
                "isLiveVerified": true,
                "familyWindows": freeAcc["familyWindows"] ?? [:],
                "argonStatus": freeAcc["argonStatus"] ?? [:]
            ]

            let dashHost = Assistant(state: state.appendingPathComponent("dyn-dash"))
            dashHost.configuration = try ConfigurationStore(state: dashHost.state)
            dashHost.bridge = BackendBridge(resources: state, state: dashHost.state)
            dashHost.reachable = false

            let ultraDash = DashboardPage(app: dashHost)
            ultraDash.view.frame = NSRect(x: 0, y: 0, width: 920, height: 760)
            ultraDash.renderSummary(["accounts": ultraDashAcc], isStaleFallback: false)
            ultraDash.view.layoutSubtreeIfNeeded(); pump()
            let ultraDashTexts = allTextValues(ultraDash.view)
            check(ultraDash.standaloneDivider.isHidden && ultraDash.standaloneQuotaStack.isHidden, "Ultra overview must hide standalone divider and rows")
            check(!ultraDashTexts.contains(where: { $0.contains("Argon") || $0.contains("Carbon") || $0.contains("周期未知") }), "Ultra overview must not show Argon, Carbon, or 周期未知")
            check(ultraDash.trendTitleLabel.stringValue == "今日时段消耗" && ultraDash.trendTitleLabel.bounds.width >= 60, "Overview trend title must remain visible without collapsing to 0pt")
            check(ultraDash.trendDetailLabel.stringValue.hasPrefix("今日 ") && ultraDash.trendDetailLabel.bounds.width >= 110, "Overview trend detail subtitle must have enough horizontal room without truncating at 920px (got width=\(ultraDash.trendDetailLabel.bounds.width))")
            check(ultraDash.todayPeakBadge.frame.minX > ultraDash.trendTitleLabel.frame.maxX + 8, "Overview peak pill badge must align to trailing edge after trend title")
            check(ultraDash.todayTrendChart.bounds.height > 100 && ultraDash.todayTrendChart.bounds.height <= 114.5, "Overview trend chart must cap vertical bar height at <= 114pt while keeping compact clarity (got \(ultraDash.todayTrendChart.bounds.height))")

            let proDash = DashboardPage(app: dashHost)
            proDash.view.frame = NSRect(x: 0, y: 0, width: 920, height: 760)
            proDash.renderSummary(["accounts": proDashAcc], isStaleFallback: false)
            proDash.view.layoutSubtreeIfNeeded(); pump()
            let proDashTexts = allTextValues(proDash.view)
            check(!proDash.standaloneDivider.isHidden && !proDash.standaloneQuotaStack.isHidden, "Pro overview must show standalone Argon row")
            check(proDashTexts.contains("Gemini 4 Argon · 每周") && !proDashTexts.contains(where: { $0.contains("Carbon") || $0.contains("周期未知") }), "Pro overview must show Gemini 4 Argon · 每周 without Carbon or 周期未知")

            let freeDash = DashboardPage(app: dashHost)
            freeDash.view.frame = NSRect(x: 0, y: 0, width: 920, height: 760)
            freeDash.renderSummary(["accounts": freeDashAcc], isStaleFallback: false)
            freeDash.view.layoutSubtreeIfNeeded(); pump()
            check(freeDash.standaloneDivider.isHidden && freeDash.standaloneQuotaStack.isHidden, "Free overview with disabled Argon must show zero standalone rows")

            // Future unknown multi-window standalone pool (5h + weekly + daily) & ModelIcons graceful fallback
            check(ModelIcons.brands(for: "Nova Models").isEmpty && ModelIcons.image("nova") == nil && ModelIcons.fallbackIcon() != nil, "Unknown future pool degrades cleanly to fallback icon without mislabeling or crashing")
            let fallbackHeader = MenuQuotaHelpers.groupHeader("Nova Models", brands: ["nova"], fontSize: 11.5, iconSize: 13)
            check((fallbackHeader as? NSStackView)?.arrangedSubviews.contains(where: { $0 is NSImageView }) == true, "MenuQuotaHelpers.groupHeader renders fallback sparkles icon for unknown future pool")
            let futureIso5h = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600 + 25 * 60))
            let futureIsoDaily = ISO8601DateFormatter().string(from: Date().addingTimeInterval(11 * 3600 + 10 * 60))
            let futureIsoWeekly = ISO8601DateFormatter().string(from: Date().addingTimeInterval(4 * 24 * 3600 + 2 * 3600))
            let multiWinStandaloneAcc: [String: Any] = [
                "activeEmail": "future@example.invalid",
                "activeName": "Future User",
                "activeTier": "PRO",
                "isLiveVerified": true,
                "quotaLastUpdated": Date().timeIntervalSince1970,
                "quotaGroups": [
                    ["key": "gemini", "displayName": "Gemini", "brands": ["gemini"], "isStandalone": false, "availability": "available", "quotaState": "known", "windows": [["id": "5h", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.85, "stale": false, "resetTime": futureIso5h]]],
                    ["key": "claude_gpt", "displayName": "Claude/GPT", "brands": ["claude", "gpt"], "isStandalone": false, "availability": "available", "quotaState": "known", "windows": [["id": "5h", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.90, "stale": false, "resetTime": futureIso5h]]],
                    ["key": "gemini-pro-orchestrator-neon", "displayName": "Orchestrator (Neon)", "brands": ["gemini"], "isStandalone": true, "availability": "unknown", "quotaState": "stale", "windows": [["id": "model", "period": "unspecified", "label": "模型配额", "known": true, "remaining": 1.0, "stale": true]]],
                    [
                        "key": "nova-models",
                        "displayName": "Nova Models",
                        "brands": ["nova"],
                        "isStandalone": true,
                        "availability": "available",
                        "quotaState": "known",
                        "windows": [
                            ["id": "5h", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.72, "stale": false, "resetTime": futureIso5h],
                            ["id": "weekly", "period": "weekly", "label": "每周", "known": true, "remaining": 0.44, "stale": false, "resetTime": futureIsoWeekly]
                        ]
                    ],
                    [
                        "key": "pulse-daily",
                        "displayName": "Pulse Daily",
                        "brands": [],
                        "isStandalone": true,
                        "availability": "available",
                        "quotaState": "known",
                        "windows": [
                            ["id": "daily", "period": "daily", "label": "每日", "known": true, "remaining": 0.61, "stale": false, "resetTime": futureIsoDaily]
                        ]
                    ]
                ]
            ]
            let multiWinDash = DashboardPage(app: dashHost)
            multiWinDash.view.frame = NSRect(x: 0, y: 0, width: 920, height: 760)
            multiWinDash.renderSummary(["accounts": multiWinStandaloneAcc], isStaleFallback: false)
            multiWinDash.view.layoutSubtreeIfNeeded(); pump()
            let multiWinTexts = allTextValues(multiWinDash.view)
            check(!multiWinDash.standaloneDivider.isHidden && !multiWinDash.standaloneQuotaStack.isHidden, "Future multi-window standalone pools render standalone section")
            check(multiWinTexts.contains("Nova Models · 5 小时") && multiWinTexts.contains("Nova Models · 每周") && multiWinTexts.contains("Pulse Daily · 每日"), "Dashboard renders all 5h, weekly, and daily windows for future standalone pools")
            check(!multiWinTexts.contains(where: { $0.contains("Orchestrator") }), "Dashboard must never render Orchestrator meta-models as standalone pools")

            let singleWindowFreeGroups: [[String: Any]] = [
                [
                    "key": "gemini",
                    "displayName": "Gemini",
                    "summaryLabel": "Gemini",
                    "brands": ["gemini"],
                    "isStandalone": false,
                    "availability": "available",
                    "quotaState": "known",
                    "windows": [
                        ["id": "weekly", "period": "weekly", "label": "每周", "known": true, "remaining": 1.0, "stale": false, "resetCountdown": "6天23小时后重置"]
                    ]
                ],
                [
                    "key": "claude_gpt",
                    "displayName": "Claude/GPT",
                    "summaryLabel": "Claude/GPT",
                    "brands": ["claude", "gpt"],
                    "isStandalone": false,
                    "availability": "available",
                    "quotaState": "known",
                    "windows": [
                        ["id": "weekly", "period": "weekly", "label": "每周", "known": true, "remaining": 1.0, "stale": false, "resetCountdown": "6天23小时后重置"]
                    ]
                ]
            ]
            let singleWinFreeDashAcc: [String: Any] = [
                "activeEmail": "free1w@example.invalid",
                "activeName": "Alex",
                "activeTier": "FREE",
                "isLiveVerified": true,
                "quotaLastUpdated": Date().timeIntervalSince1970,
                "quotaGroups": singleWindowFreeGroups
            ]
            let singleWinFreeDash = DashboardPage(app: dashHost)
            singleWinFreeDash.view.frame = NSRect(x: 0, y: 0, width: 920, height: 760)
            singleWinFreeDash.renderSummary(["accounts": singleWinFreeDashAcc], isStaleFallback: false)
            singleWinFreeDash.view.layoutSubtreeIfNeeded(); pump()
            check(singleWinFreeDash.coreQuotaStack.arrangedSubviews.count == 1, "Single-window FREE core groups must pair side-by-side into 1 two-column row")
            if let pairedRow = singleWinFreeDash.coreQuotaStack.arrangedSubviews.first as? NSStackView {
                check(pairedRow.arrangedSubviews.count == 2 && pairedRow.arrangedSubviews.allSatisfy { $0 is QuotaBarView }, "Paired FREE core row must render two QuotaBarViews side-by-side")
            }

            for (tierName, dashPage) in [("ULTRA", ultraDash), ("PRO", proDash), ("FREE", freeDash), ("FREE-1W", singleWinFreeDash)] {
                if let scroll = dashPage.view as? NSScrollView, let doc = scroll.documentView {
                    let bentoBottom = doc.convert(dashPage.bentoRow.bounds, from: dashPage.bentoRow).maxY
                    let viewportH = scroll.contentView.bounds.height
                    check(abs(viewportH - 708) <= 1.0 && abs(bentoBottom - (viewportH - 16)) <= 2.0, "\(tierName) overview must adaptively expand vertically to fill viewport down to 16pt bottom margin (bentoBottom=\(bentoBottom), viewportH=\(viewportH))")
                } else {
                    check(false, "Overview view must be an NSScrollView")
                }
            }
            check(ultraDash.refreshQuotaButton.intrinsicContentSize.width <= 96 && ultraDash.refreshQuotaButton.intrinsicContentSize.width >= 84, "Chinese QuotaRefreshButton must use compact width (got \(ultraDash.refreshQuotaButton.intrinsicContentSize.width))")
            let idleRefreshW = ultraDash.refreshQuotaButton.intrinsicContentSize.width
            ultraDash.refreshQuotaButton.setRefreshState(busy: true, available: true, error: nil)
            ultraDash.refreshQuotaButton.frame = NSRect(x: 0, y: 0, width: idleRefreshW, height: 28)
            ultraDash.refreshQuotaButton.layoutSubtreeIfNeeded()
            check(ultraDash.refreshQuotaButton.intrinsicContentSize.width == idleRefreshW && ultraDash.refreshQuotaButton.spinner.frame.minX >= 10, "Busy QuotaRefreshButton must preserve constant width while centering spinner+label group")
            ultraDash.refreshQuotaButton.setRefreshState(busy: false, available: true, error: nil)

            // Capture 1024x710 Dark verification screenshots for Ultra / Pro / Free Overview and 3-tier Accounts
            let prevWinSize = window.frame.size
            window.appearance = NSAppearance(named: .darkAqua)
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1024, height: 710)), display: true)
            assistant.selectPage(0); pump()
            var tierMetricHeights: [String: CGFloat] = [:]
            var tierModelCounts: [String: Int] = [:]
            var tierBadges: [String: String] = [:]
            for (slug, accPayload) in [("ultra", ultraDashAcc), ("pro", proDashAcc), ("free", singleWinFreeDashAcc)] {
                var enriched = accPayload
                enriched["quotaLastUpdated"] = Date().timeIntervalSince1970
                assistant.overview!.renderSummary([
                    "accounts": enriched,
                    "usage": ["todayTokens": 303_000_000, "totalTokens": 3_770_000_000, "estimatedUsd": 75.37, "allTimeEstimatedUsd": 679.89, "requestCount": 2381, "totalRequestCount": 33949, "todayPricedModels": 4, "todayUnpricedModels": 0, "pricedModels": 4, "unpricedModels": 0, "databasesScanned": 343, "databasesDiscovered": 343, "availability": "complete", "todayByModel": models, "todayHourly": todayHourly]
                ], isStaleFallback: false)
                window.contentView?.layoutSubtreeIfNeeded(); pump()
                window.contentView?.layoutSubtreeIfNeeded()
                verifyOverviewHeaderGeometry(assistant.overview!, context: "1024x710-\(slug)")
                tierMetricHeights[slug] = assistant.overview!.tokenMetricCard?.bounds.height ?? 0
                tierModelCounts[slug] = assistant.overview!.bentoRightStack.arrangedSubviews.count
                tierBadges[slug] = assistant.overview!.rightBentoCountBadge.title
                try capture(window.contentView!, output.appendingPathComponent("verify-dark-overview-\(slug).png"))
            }
            let proMetricH = tierMetricHeights["pro"] ?? 0
            let ultraMetricH = tierMetricHeights["ultra"] ?? 0
            let freeMetricH = tierMetricHeights["free"] ?? 0
            check(proMetricH >= 132 && abs(proMetricH - ultraMetricH) <= 2.0 && abs(proMetricH - freeMetricH) <= 2.0, "1024x710 KPI cards must stay tall and uniform across PRO/ULTRA/FREE (got pro=\(proMetricH), ultra=\(ultraMetricH), free=\(freeMetricH))")
            check(tierModelCounts["pro"] == 2 && tierBadges["pro"] == "Top 2 / 共 4 个", "1024x710 PRO overview must render Top 2 active models (got \(tierModelCounts["pro"] ?? -1), \(tierBadges["pro"] ?? ""))")
            check(tierModelCounts["ultra"] == 2 && tierBadges["ultra"] == "Top 2 / 共 4 个", "1024x710 ULTRA overview must render Top 2 active models (got \(tierModelCounts["ultra"] ?? -1), \(tierBadges["ultra"] ?? ""))")
            check(tierModelCounts["free"] == 3 && tierBadges["free"] == "Top 3 / 共 4 个", "1024x710 1-row FREE overview must auto-expand to Top 3 active models (got \(tierModelCounts["free"] ?? -1), \(tierBadges["free"] ?? ""))")
            let singleWinFreeCardAcc: [String: Any] = [
                "id": "free-1w",
                "name": "Alex",
                "email": "free1w@example.invalid",
                "subscription_tier": "FREE",
                "status": "normal",
                "quota": ["last_updated": Date().timeIntervalSince1970],
                "quotaGroups": singleWindowFreeGroups
            ]
            var ultraCardWithStamp = ultraAcc; ultraCardWithStamp["quota"] = ["last_updated": Date().timeIntervalSince1970]
            var proCardWithStamp = proAcc; proCardWithStamp["quota"] = ["last_updated": Date().timeIntervalSince1970]; proCardWithStamp["is_current"] = false
            assistant.selectPage(1); pump()
            assistant.accountsPage!.fetch(["accounts": [ultraCardWithStamp, proCardWithStamp, singleWinFreeCardAcc], "activeId": "ultra-1"]); pump()
            window.contentView?.layoutSubtreeIfNeeded(); pump()
            try capture(window.contentView!, output.appendingPathComponent("verify-dark-accounts-3tiers.png"))
            assistant.quotaRefreshing = true
            assistant.updateQuotaRefreshControls()
            window.contentView?.layoutSubtreeIfNeeded(); pump()
            try capture(window.contentView!, output.appendingPathComponent("verify-dark-accounts-refreshing.png"))
            assistant.quotaRefreshing = false
            assistant.updateQuotaRefreshControls()
            window.setFrame(NSRect(origin: window.frame.origin, size: prevWinSize), display: true)

            let dynAccountsHost = Assistant(state: state.appendingPathComponent("dyn-quota-groups"))
            dynAccountsHost.configuration = try ConfigurationStore(state: dynAccountsHost.state)
            dynAccountsHost.bridge = BackendBridge(resources: state, state: dynAccountsHost.state)
            dynAccountsHost.reachable = true
            dynAccountsHost.cachedAccounts = [ultraAcc, proAcc]
            dynAccountsHost.activeAccountId = "ultra-1"
            dynAccountsHost.statusValue = LiveStatus(["running": true, "runningChannel": "stable", "liveAccountEmail": "ultra@example.invalid"])
            dynAccountsHost.bridge.fixtureReply = { request in
                let cmd = request["command"] as? String ?? ""
                if cmd == "account_list" {
                    return ["ok": true, "accounts": [ultraAcc, proAcc], "activeId": "ultra-1"]
                }
                if cmd == "smart_switch_status" || cmd == "auto_switch_get" {
                    return ["ok": true, "config": ["enabled": true, "strategy": "priority", "monitored_model": "argon", "reserve_percentage": 10, "candidate_min_percentage": 30]]
                }
                return ["ok": true]
            }
            let dynAccountsPage = AccountsPage(app: dynAccountsHost)
            dynAccountsPage.view.frame = NSRect(x: 0, y: 0, width: 920, height: 760)
            dynAccountsPage.fetch(["accounts": [ultraAcc, proAcc], "activeId": "ultra-1"]); pump()
            dynAccountsPage.fetchPolicy(); pump()
            check(dynAccountsPage.policySubtitleLabel.stringValue == "监测 Gemini · 剩余 ≤ 10% 时推荐备用（≥ 30%，需手动确认切换）", "Ultra active account must display pooled Gemini summary even if saved policy says argon")
            check((dynAccountsPage.policySubtitleLabel.toolTip ?? "").contains("自适应为 Gemini"), "Ultra active account policy subtitle tooltip explains cross-tier adaptation")
            var capturedSavedMonitored: String?
            let prevDynFixture = dynAccountsHost.bridge.fixtureReply
            dynAccountsHost.bridge.fixtureReply = { request in
                if (request["command"] as? String) == "auto_switch_set",
                   let cfg = request["config"] as? [String: Any] {
                    capturedSavedMonitored = cfg["monitored_model"] as? String
                }
                return prevDynFixture?(request) ?? ["ok": true]
            }
            let ultraScopedPolicy = AccountPolicySheet(app: dynAccountsHost, config: ["strategy": "priority", "monitored_model": "argon", "reserve_percentage": 10, "candidate_min_percentage": 30], saved: {})
            ultraScopedPolicy.window.contentView?.layoutSubtreeIfNeeded()
            check((ultraScopedPolicy.modelPopup.menu?.items ?? []).filter { !$0.isSeparatorItem }.map(\.title) == ["全部可用模型", "Gemini", "Claude/GPT"], "Ultra active account policy popup must not leak standby Pro account's Gemini 4 Argon")
            check(ultraScopedPolicy.modelPopup.selectedItem?.title == "Gemini", "Ultra active account policy popup must remap argon selection to Gemini")
            ultraScopedPolicy.save(); pump()
            check(capturedSavedMonitored == "argon", "Saving Ultra policy sheet without modifying monitored scope must preserve underlying argon config")
            dynAccountsHost.bridge.fixtureReply = prevDynFixture
            var ultraWithNeon = ultraAcc
            ultraWithNeon["models"] = [
                ["name": "gemini-4-neon", "model_id": "gemini-4-neon", "display_name": "Gemini 4 Neon", "disabled": false]
            ]
            check(QuotaPresentation.monitoredScopeSubtitle(for: "gemini", activeAccount: ultraWithNeon) == "Ultra 套餐已将 Argon、Carbon 与 Neon 并入此共享池，一并监测", "Ultra gemini subtitle dynamically lists newly pooled Neon model")
            check(ultraScopedPolicy.strategyPopup.frame.width == ultraScopedPolicy.modelPopup.frame.width, "Ultra policy popups must share uniform width")
            check(ultraScopedPolicy.modelPopup.frame.width <= 130 && ultraScopedPolicy.modelPopup.frame.width >= Design.fittedPopUpWidth(ultraScopedPolicy.modelPopup) - 0.5, "Ultra policy popups must shrink tightly to longest option without 220pt bloat (got \(ultraScopedPolicy.modelPopup.frame.width))")
            check((ultraScopedPolicy.window.contentView?.frame.height ?? 999) < 395 && ultraScopedPolicy.fieldsCard.frame.height <= (groupStack(ultraScopedPolicy.fieldsCard)?.fittingSize.height ?? 0) + 34, "Ultra policy sheet must hug content without bottom blank space (contentH=\(ultraScopedPolicy.window.contentView?.frame.height ?? -1), cardH=\(ultraScopedPolicy.fieldsCard.frame.height))")
            check(ultraScopedPolicy.monitoredSubLabel.stringValue == "Ultra 套餐已将 Argon 与 Carbon 并入此共享池，一并监测", "Ultra policy popup explains Argon/Carbon inclusion")
            if let ultraCardBox = dynAccountsPage.cardsStack.arrangedSubviews.first {
                let ultraExpandedTexts = allTextValues(ultraCardBox)
                check(!ultraExpandedTexts.contains(where: { $0.contains("Argon") || $0.contains("Carbon") || $0.contains("周期未知") }), "Ultra expanded account card omits Argon, Carbon, and 周期未知")
            } else {
                check(false, "Expected Ultra expanded account card")
            }
            if let proCardBox = dynAccountsPage.cardsStack.arrangedSubviews.dropFirst().first {
                let proExpandedTexts = allTextValues(proCardBox)
                check(proExpandedTexts.contains("Gemini 4 Argon · 每周") && !proExpandedTexts.contains(where: { $0.contains("Carbon") || $0.contains("周期未知") }), "Pro expanded account card shows Gemini 4 Argon · 每周 without Carbon")
            } else {
                check(false, "Expected Pro expanded account card")
            }
            dynAccountsPage.toggleCollapseAllAccounts(); pump()
            let dynAccountsTexts = allTextValues(dynAccountsPage.cardsStack)
            check(dynAccountsTexts.contains { $0.contains("Gemini 64%") && $0.contains("Claude/GPT 100%") && !$0.contains("Argon") }, "Ultra account summary omits Argon/Carbon")
            check(dynAccountsTexts.contains { $0.contains("Gemini 53%") && $0.contains("Claude/GPT 76%") && $0.contains("Argon 64%") }, "Pro account summary includes Argon 64%")

            let dynMenu = MenuPanelController(app: dynAccountsHost)
            dynMenu.loadViewIfNeeded()
            dynMenu.selectTab(1, persist: false); pump()
            let dynMenuQuotaTexts = allTextValues(dynMenu.quotaGroupsContainer)
            check(dynMenuQuotaTexts.contains("Gemini") && dynMenuQuotaTexts.contains("Claude/GPT") && !dynMenuQuotaTexts.contains(where: { $0.contains("Argon") || $0.contains("Carbon") || $0.contains("周期未知") }), "Ultra menu quota tab omits Argon, Carbon, and 周期未知")
            dynMenu.selectTab(2, persist: false); pump()
            if let ultraCard = dynMenu.accountsCardsStack.arrangedSubviews.compactMap({ $0 as? MenuExpandableAccountCardView }).first {
                let ultraCardTexts = allTextValues(ultraCard.detailContainer)
                check(!ultraCardTexts.contains(where: { $0.contains("Argon") || $0.contains("Carbon") || $0.contains("周期未知") }), "Ultra menu account card omits Argon, Carbon, and 周期未知")
            } else {
                check(false, "Expected Ultra MenuExpandableAccountCardView")
            }
        }

        // Verify debug-port-missing status, menu panel & overview safe relaunch guidance UI, and safeRelaunchAntigravityForDebug flow
        do {
            let debugStatus = LiveStatus(["mode": "debug-port-missing"])
            check(debugStatus.title == "未开启调试端口", "LiveStatus debug-port-missing title must be 未开启调试端口 (got \(debugStatus.title))")
            check(debugStatus.color == .systemOrange, "LiveStatus debug-port-missing color must be .systemOrange")
            check(debugStatus.enabled == false, "LiveStatus debug-port-missing enabled must be false")

            let prevStatus = assistant.statusValue
            let prevReachable = assistant.reachable
            assistant.reachable = true
            assistant.statusValue = LiveStatus(["mode": "connected", "windows": 1, "entries": 4300])

            let dbgStatusBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            assistant.updateStatusItemState(buttonOverride: dbgStatusBtn)
            check(dbgStatusBtn.subviews.first(where: { $0.identifier?.rawValue == "status-item-attention-dot" })?.isHidden == true, "Menu bar attention dot must stay hidden when connected")

            let dbgMenu = MenuPanelController(app: assistant)
            let dbgPanelHost = makeHeadlessHostWindow(width: MenuPanelController.panelWidth, height: MenuPanelController.defaultPanelHeight)
            dbgPanelHost.contentViewController = dbgMenu
            dbgMenu.loadViewIfNeeded()
            dbgMenu.syncFromAssistant(); pump()
            check(dbgMenu.debugPortBannerBox.isHidden == true && dbgMenu.safeRelaunchBtn.isHidden == true, "MenuPanel must hide debugPortBannerBox and safeRelaunchBtn when connected")
            check(dbgMenu.openAntigravityBtn.isHidden == false && dbgMenu.openAntigravityBtn.title == "打开 Antigravity", "MenuPanel openAntigravityBtn must remain visible and intact when connected")

            let dbgOverview = DashboardPage(app: assistant)
            dbgOverview.view.frame = NSRect(x: 0, y: 0, width: 920, height: 700)
            dbgOverview.update(); pump()
            check(dbgOverview.debugPortBannerBox.isHidden == true && dbgOverview.safeRelaunchButton.isHidden == true, "DashboardPage must hide debugPortBannerBox and safeRelaunchButton when connected")

            assistant.statusValue = LiveStatus(["mode": "debug-port-missing", "running": true])
            assistant.updateStatusItemState(buttonOverride: dbgStatusBtn)
            check(dbgStatusBtn.subviews.first(where: { $0.identifier?.rawValue == "status-item-attention-dot" })?.isHidden == false, "Menu bar attention dot must appear in amber orange when mode is debug-port-missing")
            check(dbgStatusBtn.image?.isTemplate == true, "Base menu bar icon must remain a template image while showing attention dot")
            dbgMenu.syncFromAssistant(); pump()
            dbgPanelHost.setContentSize(dbgMenu.preferredContentSize)
            dbgPanelHost.contentView?.layoutSubtreeIfNeeded(); pump()
            check(dbgMenu.debugPortBannerBox.isHidden == false && dbgMenu.safeRelaunchBtn.isHidden == false, "MenuPanel must display debugPortBannerBox and safeRelaunchBtn in debug-port-missing mode")
            check(dbgMenu.safeRelaunchBtn.title == "安全重启以连接", "MenuPanel safeRelaunchBtn title must match requirement")
            check(dbgMenu.safeRelaunchBtn.bezelColor == nil && dbgMenu.safeRelaunchBtn.intrinsicContentSize.height == 24, "MenuPanel safeRelaunchBtn must use compact 24pt translucent glass style without heavy blue fill")
            check(dbgMenu.safeRelaunchBtn.toolTip == nil, "MenuPanel safeRelaunchBtn must not set tooltip")
            check(dbgMenu.openAntigravityBtn.isHidden == false && dbgMenu.openAntigravityBtn.title == "打开 Antigravity", "MenuPanel openAntigravityBtn must remain unaffected in debug-port-missing mode")
            let dbgMenuTexts = allTextValues(dbgMenu.debugPortBannerBox)
            check(dbgMenuTexts.contains("未开启调试端口") && dbgMenuTexts.contains(where: { $0.contains("调试端口") }), "MenuPanel debug banner must present clear cause copy")

            dbgOverview.update(); pump()
            dbgOverview.view.layoutSubtreeIfNeeded(); pump()
            check(dbgOverview.debugPortBannerBox.isHidden == false && dbgOverview.safeRelaunchButton.isHidden == false, "DashboardPage must display debugPortBannerBox and safeRelaunchButton in debug-port-missing mode")
            check(dbgOverview.safeRelaunchButton.bezelColor == nil && dbgOverview.safeRelaunchButton.intrinsicContentSize.height == 24, "DashboardPage safeRelaunchButton must use compact 24pt glass style without heavy blue fill")
            check(dbgOverview.safeRelaunchButton.title == "安全重启以连接", "DashboardPage safeRelaunchButton title must match requirement")
            check(dbgOverview.safeRelaunchButton.toolTip == nil, "DashboardPage safeRelaunchButton must not set tooltip")
            let dbgOverviewTexts = allTextValues(dbgOverview.debugPortBannerBox)
            check(dbgOverviewTexts.contains("未开启调试端口") && dbgOverviewTexts.contains(where: { $0.contains("调试端口") }), "DashboardPage debug banner must present clear cause copy")

            check(Assistant.remoteDebuggingArguments == ["--remote-debugging-port=0"], "Cold launch and relaunch must inject --remote-debugging-port=0")

            // Test safeRelaunchAntigravityForDebug direct execution (no secondary confirmation modal or forced main window pop), graceful exit + relaunch path, and timeout path
            var simulatedRunning = true
            var terminateCalls = 0
            let opensBeforeMenuClick = assistant.openedApplications
            let mainWinVisibleBeforeMenuClick = assistant.window?.isVisible == true
            assistant.setSafeRelaunchTestingHooks(SafeRelaunchTestingHooks(
                isRunning: { simulatedRunning },
                terminate: {
                    terminateCalls += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
                        simulatedRunning = false
                    }
                },
                timeoutSeconds: 2.0,
                pollIntervalMilliseconds: 20
            ))
            dbgMenu.safeRelaunchBtn.performClick(nil)
            waitUntil(description: "safeRelaunchAntigravityForDebug direct menu banner execution") {
                assistant.openedApplications == opensBeforeMenuClick + 1
            }
            check(terminateCalls == 1 && assistant.openedApplications == opensBeforeMenuClick + 1, "Menu banner safe relaunch must directly terminate gracefully and reopen Antigravity without a redundant modal alert")
            check((assistant.window?.isVisible == true) == mainWinVisibleBeforeMenuClick, "Menu banner safe relaunch must not force-open the main window")

            simulatedRunning = true
            let opensBeforeSafeConfirm = assistant.openedApplications
            assistant.setSafeRelaunchTestingHooks(SafeRelaunchTestingHooks(
                isRunning: { simulatedRunning },
                terminate: {
                    terminateCalls += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) {
                        simulatedRunning = false
                    }
                },
                timeoutSeconds: 2.0,
                pollIntervalMilliseconds: 20
            ))
            dbgOverview.safeRelaunchButton.performClick(nil)
            waitUntil(description: "safeRelaunchAntigravityForDebug graceful exit and relaunch") {
                assistant.openedApplications == opensBeforeSafeConfirm + 1
            }
            check(terminateCalls == 2 && assistant.openedApplications == opensBeforeSafeConfirm + 1, "Overview safe relaunch must terminate gracefully and reopen Antigravity with --remote-debugging-port=0")

            // Clicking openAntigravity while in debug-port-missing must route through safeRelaunchAntigravityForDebug instead of focusing the non-debug instance
            assistant.statusValue = LiveStatus(["mode": "debug-port-missing", "running": true])
            simulatedRunning = true
            let opensBeforeOpenBtnInDebugMissing = assistant.openedApplications
            assistant.setSafeRelaunchTestingHooks(SafeRelaunchTestingHooks(
                isRunning: { simulatedRunning },
                terminate: {
                    terminateCalls += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) {
                        simulatedRunning = false
                    }
                },
                timeoutSeconds: 2.0,
                pollIntervalMilliseconds: 20
            ))
            assistant.openAntigravity()
            waitUntil(description: "openAntigravity in debug-port-missing triggers safe relaunch") {
                assistant.openedApplications == opensBeforeOpenBtnInDebugMissing + 1
            }
            check(terminateCalls == 3 && assistant.openedApplications == opensBeforeOpenBtnInDebugMissing + 1, "openAntigravity during debug-port-missing must execute safe relaunch instead of silently activating the non-debug app")

            // Timeout path: Antigravity stays running past timeout, must report manual quit guidance and never reopen or force-kill
            var stuckRunning = true
            let opensBeforeTimeout = assistant.openedApplications
            assistant.showMessage("", error: false)
            assistant.setSafeRelaunchTestingHooks(SafeRelaunchTestingHooks(
                isRunning: { stuckRunning },
                terminate: { terminateCalls += 1 },
                timeoutSeconds: 0.2,
                pollIntervalMilliseconds: 20
            ))
            assistant.safeRelaunchAntigravityForDebug()
            waitUntil(description: "safeRelaunchAntigravityForDebug timeout guidance") {
                assistant.lastOperationError?.contains("手动退出") == true
            }
            stuckRunning = false
            check(assistant.openedApplications == opensBeforeTimeout, "Safe relaunch timeout must not reopen Antigravity while still running")
            assistant.showMessage("", error: false)

            // P1-02: Wait for lingering Antigravity helper/language_server subprocesses before relaunching, and retry transient LaunchServices open failures
            var mainAppAlive = true
            var helperSubprocessAlive = true
            var subprocPollsWhileMainExited = 0
            var launchAttemptsSeen: [Int] = []
            let opensBeforeSubprocDrain = assistant.openedApplications
            assistant.setSafeRelaunchTestingHooks(SafeRelaunchTestingHooks(
                isRunning: { mainAppAlive },
                hasSubprocesses: {
                    if !mainAppAlive && helperSubprocessAlive {
                        subprocPollsWhileMainExited += 1
                        if subprocPollsWhileMainExited >= 2 {
                            helperSubprocessAlive = false
                        }
                    }
                    return helperSubprocessAlive
                },
                terminate: {
                    mainAppAlive = false
                },
                relaunchAttempt: { attempt, done in
                    launchAttemptsSeen.append(attempt)
                    // Simulate transient LaunchServices rejection on attempt 1 while old job finishes tearing down
                    done(attempt >= 2)
                },
                timeoutSeconds: 2.0,
                pollIntervalMilliseconds: 15,
                relaunchRetryDelayMilliseconds: 15
            ))
            assistant.safeRelaunchAntigravityForDebug()
            check(assistant.openedApplications == opensBeforeSubprocDrain, "Safe relaunch must wait for lingering subprocesses before reopening")
            waitUntil(description: "safeRelaunchAntigravityForDebug subprocess drain and retry relaunch") {
                assistant.openedApplications == opensBeforeSubprocDrain + 1
            }
            check(subprocPollsWhileMainExited >= 2, "Safe relaunch must poll subprocess liveness after main app exits (polls=\(subprocPollsWhileMainExited))")
            check(launchAttemptsSeen == [1, 2], "Safe relaunch must retry transient launch failure before succeeding (attempts=\(launchAttemptsSeen))")

            // F-03: Exhausted safe relaunch failure must use safe-relaunch error copy (never misleading "Account switched")
            assistant.showMessage("", error: false)
            var failedAttempts = 0
            assistant.setSafeRelaunchTestingHooks(SafeRelaunchTestingHooks(
                isRunning: { false },
                hasSubprocesses: { false },
                terminate: {},
                relaunchAttempt: { _, done in
                    failedAttempts += 1
                    done(false)
                },
                timeoutSeconds: 1.0,
                pollIntervalMilliseconds: 10,
                relaunchRetryDelayMilliseconds: 10
            ))
            assistant.safeRelaunchAntigravityForDebug()
            waitUntil(description: "safeRelaunchAntigravityForDebug exhausted failure message") {
                assistant.lastOperationError?.contains("未能自动重新打开 Antigravity") == true
            }
            check(failedAttempts == 3, "Safe relaunch must try 3 times before reporting failure (got \(failedAttempts))")
            check(!(assistant.lastOperationError?.contains("账号已切换") ?? false), "Safe relaunch failure must not claim account was switched: \(assistant.lastOperationError ?? "")")
            assistant.showMessage("", error: false)
            assistant.setSafeRelaunchTestingHooks(nil)

            // P2-03: Switching global language while in debug-port-missing keeps debug-port-missing synchronously when HUD is enabled (no banner flash), and transitions to paused only when both translation and HUD are disabled
            let dbgLangHost = Assistant(state: state.appendingPathComponent("dbg-lang-host"))
            dbgLangHost.configuration = try ConfigurationStore(state: dbgLangHost.state)
            dbgLangHost.bridge = BackendBridge(resources: state, state: dbgLangHost.state)
            dbgLangHost.reachable = true
            var dbgHudOn = true
            var dbgCurrentLang = "zh-Hans"
            dbgLangHost.bridge.fixtureReply = { payload in
                let cmd = payload["command"] as? String ?? ""
                if cmd == "language_set" {
                    dbgCurrentLang = payload["language"] as? String ?? "zh-Hans"
                }
                if cmd == "language_set" || cmd == "status" {
                    let resolved = dbgCurrentLang == "en" ? "en" : "zh-Hans"
                    let nextMode = (resolved == "en" && !dbgHudOn) ? "paused" : "debug-port-missing"
                    return ["ok": true, "status": ["mode": nextMode, "running": true, "hudEnabled": dbgHudOn, "configuredLanguage": dbgCurrentLang, "locale": resolved, "translationEnabled": resolved != "en"], "tasks": [], "taskRevision": 0]
                }
                return ["ok": true]
            }
            dbgLangHost.configuration.value.hudEnabled = true
            dbgLangHost.statusValue = LiveStatus(["mode": "debug-port-missing", "running": true, "hudEnabled": true, "configuredLanguage": "zh-Hans", "locale": "zh-Hans", "translationEnabled": true])
            dbgLangHost.setGlobalLanguage("en")
            check(dbgLangHost.statusValue.mode == "debug-port-missing", "P2-03: setGlobalLanguage(en) with HUD enabled must preserve debug-port-missing synchronously without flashing paused")
            pump()
            check(dbgLangHost.statusValue.mode == "debug-port-missing", "P2-03: debug-port-missing must remain steady after language_set reply when HUD is enabled")

            dbgHudOn = false
            dbgLangHost.configuration.value.hudEnabled = false
            dbgLangHost.statusValue = LiveStatus(["mode": "debug-port-missing", "running": true, "hudEnabled": false, "configuredLanguage": "zh-Hans", "locale": "zh-Hans", "translationEnabled": true])
            dbgLangHost.setGlobalLanguage("en")
            check(dbgLangHost.statusValue.mode == "paused", "P2-03: setGlobalLanguage(en) with HUD disabled must transition to paused")
            pump()
            _ = L10n.shared.setLanguage("zh-Hans", notify: true); pump()

            // Connection restored -> banners hide
            assistant.statusValue = LiveStatus(["mode": "connected", "windows": 1, "entries": 4300])
            dbgMenu.syncFromAssistant(); pump()
            dbgOverview.update(); pump()
            check(dbgMenu.debugPortBannerBox.isHidden == true && dbgMenu.safeRelaunchBtn.isHidden == true, "MenuPanel safe relaunch banner must hide once connected")
            check(dbgOverview.debugPortBannerBox.isHidden == true && dbgOverview.safeRelaunchButton.isHidden == true, "DashboardPage safe relaunch banner must hide once connected")

            // English locale check for debug-port-missing
            _ = L10n.shared.setLanguage("en", notify: false)
            let enDebugStatus = LiveStatus(["mode": "debug-port-missing"])
            check(enDebugStatus.title == "Debug Port Not Enabled", "English LiveStatus debug-port-missing title mismatch (got \(enDebugStatus.title))")
            _ = L10n.shared.setLanguage("zh-Hans", notify: false)

            assistant.statusValue = prevStatus
            assistant.reachable = prevReachable
            dbgPanelHost.orderOut(nil)
        }

        // Unpriced / partial pricing UI decoupling, model badges, and PricingSyncSheet variant folding (zh-Hans & en)
        do {
            let partialHost = Assistant(state: state.appendingPathComponent("partial-pricing-ui"))
            partialHost.configuration = try ConfigurationStore(state: partialHost.state)
            partialHost.bridge = BackendBridge(resources: state, state: partialHost.state)
            partialHost.reachable = true
            let sampleModels: [[String: Any]] = [
                ["model": "gemini-5-nova", "totalTokens": 12_100_000, "promptTokens": 11_000_000, "candidatesTokens": 100_000, "cachedTokens": 1_000_000, "requestCount": 58, "estimatedUsd": 0.0, "priced": false, "partiallyPriced": false, "unpricedTokens": 12_100_000],
                ["model": "gemini-4-hydrogen", "totalTokens": 11_000_000, "promptTokens": 1_000_000, "candidatesTokens": 100_000, "cachedTokens": 9_900_000, "requestCount": 69, "estimatedUsd": 3.16, "priced": true, "partiallyPriced": false, "unpricedTokens": 0, "pricingStatus": "confirmed"]
            ]
            partialHost.bridge.fixtureReply = { payload in
                let cmd = payload["command"] as? String ?? ""
                if cmd == "dashboard_summary" {
                    return [
                        "ok": true,
                        "accounts": [
                            "activeName": "Alex", "activeEmail": "alex@example.invalid", "activeTier": "ULTRA",
                            "liveAccountEmail": "alex@example.invalid", "isLiveVerified": true,
                            "quotaGroups": [
                                ["id": "gemini", "displayName": "Gemini", "fiveHourRemaining": 94, "weeklyRemaining": 88]
                            ]
                        ],
                        "usage": [
                            "todayTokens": 23_100_000, "totalTokens": 4_730_000_000, "estimatedUsd": 3.16, "allTimeEstimatedUsd": 930.70,
                            "requestCount": 127, "totalRequestCount": 38964,
                            "todayPricedModels": 1, "todayUnpricedModels": 1, "pricedModels": 2, "unpricedModels": 1,
                            "databasesScanned": 10, "databasesDiscovered": 10, "availability": "complete",
                            "todayByModel": sampleModels, "todayHourly": []
                        ]
                    ]
                }
                if cmd == "usage_summary" {
                    return [
                        "ok": true, "period": payload["period"] as? String ?? "all", "snapshotId": "partial-snap-1",
                        "summary": [
                            "totalTokens": 4_730_000_000, "promptTokens": 100_000_000, "cachedTokens": 4_600_000_000, "candidatesTokens": 30_000_000,
                            "requestCount": 38964, "estimatedUsd": 930.70, "pricedModels": 2, "unpricedModels": 1,
                            "databasesScanned": 10, "databasesDiscovered": 10, "availability": "complete", "lastScannedAt": Date().timeIntervalSince1970
                        ],
                        "byModel": sampleModels, "models": sampleModels, "dailyTrends": [], "todayHourly": []
                    ]
                }
                return ["ok": true]
            }

            _ = L10n.shared.setLanguage("zh-Hans", notify: true); pump()
            let partialWindow = makeHeadlessHostWindow(width: 960, height: 640)
            partialHost.window = partialWindow
            let partialOverview = DashboardPage(app: partialHost)
            let partialUsage = UsagePage(app: partialHost)
            let ovBox = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 580))
            ovBox.addSubview(partialOverview.view); pin(partialOverview.view, to: ovBox)
            partialWindow.contentView = ovBox
            partialOverview.fetch(); pump()
            ovBox.layoutSubtreeIfNeeded(); pump()

            check(partialOverview.usageMetric.stringValue == "$3.16", "Partial overview KPI must show pure USD without prefix: \(partialOverview.usageMetric.stringValue)")
            check(partialOverview.costMetricCard?.statusBadge?.isHidden == false && partialOverview.costMetricCard?.statusBadge?.title == "部分计价", "Overview cost card must display 部分计价 status badge")
            check(partialOverview.usageDetail.stringValue == "含 1 款待定价 · 累计部分 $930.70", "Overview cost detail must surface pending count and partial total: \(partialOverview.usageDetail.stringValue)")
            let zhCostNatW = (partialOverview.usageMetric.stringValue as NSString).size(withAttributes: [.font: partialOverview.usageMetric.font!]).width
            check(partialOverview.usageMetric.bounds.width + 1.0 >= ceil(zhCostNatW), "Overview pure USD value must not truncate (\(partialOverview.usageMetric.bounds.width) < \(zhCostNatW))")
            let bentoTexts = allTextValues(partialOverview.bentoRightStack)
            check(bentoTexts.contains("待定价"), "Overview bento active models must show 待定价 pill for unpriced model: \(bentoTexts)")

            let usgBox = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 580))
            usgBox.addSubview(partialUsage.view); pin(partialUsage.view, to: usgBox)
            partialWindow.contentView = usgBox
            partialUsage.fetch(force: true); pump()
            usgBox.layoutSubtreeIfNeeded(); pump()
            check(partialUsage.usdMetric.stringValue == "$930.70", "UsagePage KPI must show pure USD without prefix: \(partialUsage.usdMetric.stringValue)")
            check(!partialUsage.costStatusBadge.isHidden && partialUsage.costStatusBadge.title == "部分计价", "UsagePage cost card must show 部分计价 pill")
            check(!partialUsage.usdDetail.isHidden && partialUsage.usdDetail.stringValue.contains("含 1 款待定价模型"), "UsagePage usdDetail must explain pending model: \(partialUsage.usdDetail.stringValue)")

            let partialMenu = partialHost.ensureMenuPanelController()
            let partialPanelHost = makeHeadlessHostWindow(width: MenuPanelController.panelWidth, height: MenuPanelController.defaultPanelHeight)
            partialPanelHost.contentViewController = partialMenu
            partialMenu.selectTab(0, persist: false); partialMenu.panelWillOpen(); pump()
            partialPanelHost.setContentSize(partialMenu.preferredContentSize); partialPanelHost.contentView?.layoutSubtreeIfNeeded(); pump()
            check(partialMenu.costTile.valueLabel.stringValue == "$930.70", "MenuPanel costTile must display pure $930.70 without prefix: \(partialMenu.costTile.valueLabel.stringValue)")
            check(!partialMenu.costTile.statusBadge.isHidden && partialMenu.costTile.statusBadge.title == "部分", "MenuPanel costTile must show 部分 status badge")
            check(partialMenu.usageFooterLabel.stringValue.contains("1 款模型待定价"), "MenuPanel footer must note pending models: \(partialMenu.usageFooterLabel.stringValue)")
            let menuCostNatW = (partialMenu.costTile.valueLabel.stringValue as NSString).size(withAttributes: [.font: partialMenu.costTile.valueLabel.font!]).width
            check(partialMenu.costTile.valueLabel.bounds.width + 1.0 >= ceil(menuCostNatW), "MenuPanel pure USD value must not truncate (\(partialMenu.costTile.valueLabel.bounds.width) < \(menuCostNatW))")
            let menuModelsTexts = allTextValues(partialMenu.modelsListStack)
            check(menuModelsTexts.contains("待定价"), "MenuPanel models list must show 待定价 badge on unpriced row: \(menuModelsTexts)")

            // PricingSyncSheetController variant folding check (5 Neon/Nova variants -> 1 card + unified banner + subtitle)
            let foldedSheet = PricingSyncSheetController(app: partialHost)
            foldedSheet.show(in: partialWindow, payload: [
                "synced": true,
                "status": ["lastCheckAt": 1794539910722.0, "modelCount": 2],
                "unpricedLiveModels": [
                    ["key": "gemini-5-nova-high", "displayName": "Gemini 5 Nova (High)", "disabled": false],
                    ["key": "gemini-5-nova-xhigh", "displayName": "Gemini 5 Nova (XHigh)", "disabled": false],
                    ["key": "gemini-5-nova-medium", "displayName": "Gemini 5 Nova (Medium)", "disabled": false],
                    ["key": "gemini-5-nova-low", "displayName": "Gemini 5 Nova (Low)", "disabled": false],
                    ["key": "gemini-pro-orchestrator-nova", "displayName": "Orchestrator (Nova)", "disabled": false],
                ],
                "prices": [
                    "gemini-4-hydrogen": ["input": 1.5, "output": 7.5, "cached": 0.075]
                ],
                "pricingStatus": ["gemini-4-hydrogen": "confirmed"],
                "modelCatalogState": ["gemini-4-hydrogen": ["availability": "available", "displayName": "Gemini 4 Hydrogen"]],
            ])
            pump()
            check(foldedSheet.summaryPill.title.hasSuffix("· 2 款"), "Folded PricingSyncSheet must count grouped unpriced + priced as 2: \(foldedSheet.summaryPill.title)")
            check(foldedSheet.renderedSummaryLines.count == 2, "5 Nova variants must fold into 1 unpriced group + 1 priced card (got \(foldedSheet.renderedSummaryLines.count))")
            let foldedZhTexts = allTextValues(foldedSheet.sheet.contentView!)
            check(foldedZhTexts.contains("涵盖变体：Low · Medium · High · XHigh · Orchestrator"), "Folded group card must list combined variants: \(foldedZhTexts)")

            // Non-Gemini / standalone orchestrator rows must never fabricate gemini-4-<codename>; sibling matching + hostOrder must work cleanly
            let standaloneNonGeminiOrch = PricingSyncSheetController.groupUnpricedLiveModels([
                ["key": "gemini-pro-orchestrator-opus", "displayName": "Orchestrator (Opus)", "disabled": false],
                ["key": "gemini-flash-worker-agy", "displayName": "Orchestrator (Claude Opus 6)", "disabled": false],
            ])
            check(standaloneNonGeminiOrch.count == 2, "Standalone non-Gemini orchestrators remain distinct without fabricating gemini-4-*")
            check(standaloneNonGeminiOrch[0].key == "gemini-pro-orchestrator-opus" && standaloneNonGeminiOrch[0].displayName == "Orchestrator (Opus)", "Must not fabricate gemini-4-opus for unmatched Opus orchestrator (got \(standaloneNonGeminiOrch[0]))")
            check(standaloneNonGeminiOrch[1].key == "gemini-flash-worker-agy" && standaloneNonGeminiOrch[1].displayName == "Orchestrator (Claude Opus 6)", "Must preserve canonical key/displayName for unmatched Claude Opus orchestrator (got \(standaloneNonGeminiOrch[1]))")

            let pairedNonGeminiOrch = PricingSyncSheetController.groupUnpricedLiveModels([
                ["key": "claude-opus-6-high", "displayName": "Claude Opus 6 (High)", "disabled": false, "hostOrder": 2],
                ["key": "gemini-flash-worker-agy", "displayName": "Claude Opus 6 (Orchestrator)", "disabled": false, "hostOrder": 2],
                ["key": "gemini-5-zephyr-extra", "displayName": "Gemini 5 Zephyr (Extra)", "disabled": false, "hostOrder": 0],
            ])
            check(pairedNonGeminiOrch.count == 2, "Paired non-Gemini orchestrator folds into its sibling while respecting hostOrder")
            check(pairedNonGeminiOrch[0].key == "gemini-5-zephyr" && pairedNonGeminiOrch[0].displayName == "Gemini 5 Zephyr" && pairedNonGeminiOrch[0].variants == ["Extra"], "Unpriced grouping honors backend hostOrder and -extra variant (got \(pairedNonGeminiOrch[0]))")
            check(pairedNonGeminiOrch[1].key == "claude-opus-6" && pairedNonGeminiOrch[1].displayName == "Claude Opus 6" && pairedNonGeminiOrch[1].variants == ["High", "Orchestrator"], "Non-Gemini orchestrator folds into matching Claude sibling cleanly (got \(pairedNonGeminiOrch[1]))")

            let customHostOrder = PricingSyncSheetController.sortCurrentPlanKeys(
                ["gemini-4-neon", "gemini-4-zephyr", "claude-opus-5-5"],
                catalogState: [
                    "gemini-4-zephyr": ["availability": "available", "hostOrder": 0],
                    "claude-opus-5-5": ["availability": "available", "hostOrder": 1],
                    "gemini-4-neon": ["availability": "available", "hostOrder": 2],
                ]
            )
            check(customHostOrder == ["gemini-4-zephyr", "claude-opus-5-5", "gemini-4-neon"], "sortCurrentPlanKeys must follow backend hostOrder without hardcoded codename precedence (got \(customHostOrder))")

            _ = L10n.shared.setLanguage("en", notify: true); pump()
            let enPartialOverview = DashboardPage(app: partialHost)
            let enPartialUsage = UsagePage(app: partialHost)
            let enPartialMenu = MenuPanelController(app: partialHost)
            let enOvBox = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 580))
            enOvBox.addSubview(enPartialOverview.view); pin(enPartialOverview.view, to: enOvBox)
            partialWindow.contentView = enOvBox
            enPartialOverview.fetch(); pump()
            enOvBox.layoutSubtreeIfNeeded(); pump()

            let enUsgBox = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 580))
            enUsgBox.addSubview(enPartialUsage.view); pin(enPartialUsage.view, to: enUsgBox)
            partialWindow.contentView = enUsgBox
            enPartialUsage.fetch(force: true); pump()
            enUsgBox.layoutSubtreeIfNeeded(); pump()

            partialPanelHost.contentViewController = enPartialMenu
            enPartialMenu.selectTab(0, persist: false); enPartialMenu.panelWillOpen(); pump()
            partialPanelHost.setContentSize(enPartialMenu.preferredContentSize); partialPanelHost.contentView?.layoutSubtreeIfNeeded(); pump()

            check(enPartialOverview.costMetricCard?.statusBadge?.title == "Partial" && enPartialOverview.usageMetric.stringValue == "$3.16", "English Overview partial card must keep pure USD and Partial pill")
            check(!enPartialMenu.costTile.statusBadge.isHidden && enPartialMenu.costTile.statusBadge.title == "Partial" && enPartialMenu.costTile.valueLabel.stringValue == "$930.70", "English MenuPanel costTile must keep pure USD and Partial pill")
            check(!enPartialUsage.costStatusBadge.isHidden && enPartialUsage.costStatusBadge.title == "Partial" && enPartialUsage.usdMetric.stringValue == "$930.70", "English UsagePage cost must keep pure USD and Partial pill")
            let foldedEnTexts = allTextValues(foldedSheet.sheet.contentView!)
            check(foldedEnTexts.contains("Includes variants: Low · Medium · High · XHigh · Orchestrator"), "English folded group card must localize variants list: \(foldedEnTexts)")
            let partialEnLeaks = (allTextValues(enOvBox) + allTextValues(enUsgBox) + allTextValues(enPartialMenu.view) + foldedEnTexts)
                .filter { $0.range(of: "[\\u4E00-\\u9FFF]", options: .regularExpression) != nil }
            check(partialEnLeaks.isEmpty, "English partial-pricing views must not leak Chinese characters: \(partialEnLeaks)")

            foldedSheet.closeSheet(); waitForSheetDetach(on: partialWindow, description: "Folded PricingSyncSheetController to detach")
            partialPanelHost.orderOut(nil)
            partialWindow.orderOut(nil)
            _ = L10n.shared.setLanguage("zh-Hans", notify: true); pump()
        }

        // Backup account stale quota refresh sync between Main App (AccountsPage) and Menu Bar (MenuPanelController)
        do {
            let syncHost = Assistant(state: state.appendingPathComponent("quota-menu-sync-host"))
            syncHost.configuration = try ConfigurationStore(state: syncHost.state)
            syncHost.bridge = BackendBridge(resources: state, state: syncHost.state)
            syncHost.reachable = true
            let nowTs = Date().timeIntervalSince1970
            let staleTs = nowTs - 1800
            let activeAcc: [String: Any] = [
                "id": "acc-main",
                "email": "main@example.invalid",
                "name": "MainUser",
                "subscription_tier": "PRO",
                "quota_last_updated": Int(nowTs),
                "quota": ["last_updated": nowTs, "subscription_tier": "PRO"],
                "quotaGroups": [
                    [
                        "key": "gemini",
                        "displayName": "Gemini",
                        "summaryLabel": "Gemini",
                        "brands": ["gemini"],
                        "isStandalone": false,
                        "availability": "available",
                        "quotaState": "known",
                        "windows": [
                            ["id": "5h", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.90, "stale": false, "resetCountdown": "4 小时 10 分后重置"],
                            ["id": "weekly", "period": "weekly", "label": "每周", "known": true, "remaining": 0.85, "stale": false, "resetCountdown": "5 天 2 小时后重置"]
                        ]
                    ]
                ]
            ]
            let makeBackupAccount: (_ stale5h: Bool, _ staleWeekly: Bool, _ known5h: Bool, _ ts: Double, _ rev: String) -> [String: Any] = { stale5h, staleWeekly, known5h, ts, rev in
                [
                    "id": "acc-backup",
                    "email": "backup@example.invalid",
                    "name": "BackupUser",
                    "subscription_tier": "PRO",
                    "revision": rev,
                    "quota_last_updated": Int(ts),
                    "quota": ["last_updated": ts, "subscription_tier": "PRO"],
                    "quotaGroups": [
                        [
                            "key": "gemini",
                            "displayName": "Gemini",
                            "summaryLabel": "Gemini",
                            "brands": ["gemini"],
                            "isStandalone": false,
                            "availability": "available",
                            "quotaState": (stale5h && staleWeekly) ? "stale" : "known",
                            "windows": [
                                [
                                    "id": "5h",
                                    "period": "5h",
                                    "label": "5 小时",
                                    "known": known5h,
                                    "remaining": known5h ? 0.88 : NSNull(),
                                    "stale": stale5h,
                                    "resetCountdown": known5h ? "4 小时 30 分后重置" : ""
                                ],
                                [
                                    "id": "weekly",
                                    "period": "weekly",
                                    "label": "每周",
                                    "known": true,
                                    "remaining": 0.92,
                                    "stale": staleWeekly,
                                    "resetCountdown": "6 天 1 小时后重置"
                                ]
                            ]
                        ]
                    ]
                ]
            }

            var currentBackup = makeBackupAccount(true, true, false, staleTs, "rev-stale:ready")
            var currentPoolRev = "pool-rev-1"
            syncHost.statusValue = LiveStatus(["running": true, "runningChannel": "stable", "liveAccountEmail": "main@example.invalid", "accountsRevision": currentPoolRev])
            syncHost.bridge.fixtureReply = { payload in
                let cmd = payload["command"] as? String ?? ""
                if cmd == "account_list" {
                    return [
                        "ok": true,
                        "activeId": "acc-main",
                        "currentAccountId": "acc-main",
                        "accounts": [activeAcc, currentBackup],
                        "pendingSwitch": false
                    ]
                }
                if cmd == "quota_refresh" {
                    currentBackup = makeBackupAccount(false, false, true, nowTs, "rev-fresh:ready")
                    currentPoolRev = "pool-rev-2"
                    return [
                        "ok": true,
                        "partial": false,
                        "message": "配额已刷新",
                        "account": currentBackup,
                        "quota": currentBackup["quota"] as Any,
                        "subscription_tier": "PRO"
                    ]
                }
                if cmd == "status" {
                    return [
                        "ok": true,
                        "status": [
                            "mode": "connected",
                            "running": true,
                            "runningChannel": "stable",
                            "liveAccountEmail": "main@example.invalid",
                            "accountsRevision": currentPoolRev
                        ],
                        "tasks": [],
                        "taskRevision": 1
                    ]
                }
                return ["ok": true]
            }

            // 1. Initial stale load into both Main App (AccountsPage) and MenuPanelController (Tab 2 expanded backup card)
            let syncAccountsPage = AccountsPage(app: syncHost)
            syncHost.accountsPage = syncAccountsPage
            let syncMenu = syncHost.ensureMenuPanelController()
            let syncMenuWin = makeHeadlessHostWindow(width: MenuPanelController.panelWidth, height: MenuPanelController.defaultPanelHeight)
            syncMenuWin.contentViewController = syncMenu
            syncHost.fetchAccountList(notifyPage: true); pump()
            syncMenu.panelWillOpen(); syncMenu.selectTab(2, persist: true); pump()
            syncMenu.toggleAccountExpanded("acc-backup"); pump()

            let backupCardInMenu = syncMenu.accountsCardsStack.arrangedSubviews.compactMap { $0 as? MenuExpandableAccountCardView }.first { $0.accountId == "acc-backup" }
            check(backupCardInMenu != nil, "Menu accounts tab must mount backup account card")
            check(backupCardInMenu?.quotaRowViews.first?.valueLabel.stringValue == "已过期", "Stale unknown 5h window in menu backup card must initially render 已过期 (got \(backupCardInMenu?.quotaRowViews.first?.valueLabel.stringValue ?? ""))")

            // Verify partial window staleness in Main App collapsed summary (5h fresh, weekly stale -> still marks 已过期)
            currentBackup = makeBackupAccount(false, true, true, staleTs, "rev-partial-stale:ready")
            syncAccountsPage.fetch(["accounts": [activeAcc, currentBackup], "activeId": "acc-main", "pendingSwitch": false]); pump()
            if !syncAccountsPage.isAllCollapsedMode {
                syncAccountsPage.toggleCollapseAllAccounts(); pump()
            }
            let partialCollapsedTexts = allTextValues(syncAccountsPage.cardsStack)
            check(partialCollapsedTexts.contains { $0.contains("Gemini 88% (已过期)") }, "Collapsed summary in Main App must disclose (已过期) when any window in the group is stale: \(partialCollapsedTexts)")

            // 2. Simulate in-flight account_list race: old account_list starts while backup is still stale, then backup updates before old account_list returns
            currentBackup = makeBackupAccount(true, true, false, staleTs, "rev-stale:ready")
            syncHost.menuTracking = false
            syncHost.fetchAccountList(notifyPage: true) // in-flight request #1 captures stale snapshot
            check(syncHost.accountListInFlight == true, "First fetchAccountList must mark accountListInFlight")
            currentBackup = makeBackupAccount(false, false, true, nowTs, "rev-fresh:ready")
            syncHost.fetchAccountList(notifyPage: true) // request #2 arrives while #1 is still in flight
            check(syncHost.accountListPendingRefetch == true, "fetchAccountList during in-flight account_list must queue accountListPendingRefetch instead of dropping")
            waitUntil(step: 0.01, description: "queued accountListPendingRefetch to complete") {
                !syncHost.accountListInFlight && !syncHost.accountListPendingRefetch
            }
            pump()
            check(backupCardInMenu?.quotaRowViews.first?.valueLabel.stringValue == "88%", "Queued accountListPendingRefetch must replace stale in-flight payload with fresh 88% in MenuPanelController (got \(backupCardInMenu?.quotaRowViews.first?.valueLabel.stringValue ?? ""))")

            // 2b. Reset backup to stale, then run single-account refresh in Main App while menu popover is closed
            currentBackup = makeBackupAccount(true, true, false, staleTs, "rev-stale-2:ready")
            syncHost.fetchAccountList(notifyPage: true)
            waitUntil(step: 0.01, description: "stale backup reset fetchAccountList to complete") {
                !syncHost.accountListInFlight && !syncHost.accountListPendingRefetch
            }
            pump()
            check(backupCardInMenu?.quotaRowViews.first?.valueLabel.stringValue == "已过期", "Menu backup card must reset to 已过期 before single-account refresh")
            syncHost.refreshSingleAccountQuota(id: "acc-backup")
            waitUntil(step: 0.01, description: "single-account quota refresh and account_list sync to complete") {
                !syncHost.refreshingAccountIds.contains("acc-backup")
                    && !syncHost.accountListInFlight
                    && !syncHost.accountListPendingRefetch
            }
            pump()

            // Verify MenuPanelController and cachedAccounts both reflect the fresh quota without reopening or manual refresh in menu bar
            check(backupCardInMenu?.quotaRowViews.first?.valueLabel.stringValue == "88%", "Menu backup account 5h quota must update from 已过期 to 88% after Main App refresh (got \(backupCardInMenu?.quotaRowViews.first?.valueLabel.stringValue ?? ""))")
            check(!(backupCardInMenu?.quotaRowViews.first?.resetLabel.stringValue.contains("过期") ?? true), "Menu backup account 5h resetLabel must clear 数据已过期 after Main App refresh")
            check(!(backupCardInMenu?.quotaRowViews.last?.resetLabel.stringValue.contains("过期") ?? true), "Menu backup account weekly resetLabel must clear 数据已过期 after Main App refresh")
            let refreshedCollapsedTexts = allTextValues(syncAccountsPage.cardsStack)
            check(refreshedCollapsedTexts.contains { $0.contains("Gemini 88%") && !$0.contains("已过期") }, "Main App collapsed summary must also clear (已过期) after refresh: \(refreshedCollapsedTexts)")

            // 3. Verify opening MenuPanelController on Tab 2 when lastAccountListFetchAt is >= 15s old proactively refetches account_list
            currentBackup = makeBackupAccount(false, false, true, nowTs + 10, "rev-fresh-2:ready")
            if var g = (currentBackup["quotaGroups"] as? [[String: Any]])?.first,
               var ws = g["windows"] as? [[String: Any]], !ws.isEmpty {
                ws[0]["remaining"] = 0.96
                g["windows"] = ws
                currentBackup["quotaGroups"] = [g]
            }
            syncHost.lastAccountListFetchAt = Date(timeIntervalSinceNow: -20)
            syncMenu.panelWillOpen(); pump()
            waitUntil(step: 0.01, description: "MenuPanel reopen account_list refetch to complete") {
                !syncHost.accountListInFlight && !syncHost.accountListPendingRefetch
            }
            check(backupCardInMenu?.quotaRowViews.first?.valueLabel.stringValue == "96%", "Reopening MenuPanelController after 15s staleness window must proactively refetch account_list and render 96% (got \(backupCardInMenu?.quotaRowViews.first?.valueLabel.stringValue ?? ""))")
            syncMenuWin.orderOut(nil)
        }

        // Verify ModelUsageFold merges thinking variants (-low / -high / -xhigh) while preserving -n / -exp-a
        do {
            let folded = ModelUsageFold.foldThinkingVariants([
                ["model": "gemini-4-neon-high", "totalTokens": 1000, "promptTokens": 600, "candidatesTokens": 400, "requestCount": 2, "estimatedUsd": 0.12, "priced": true],
                ["model": "gemini-4-neon-xhigh", "totalTokens": 2500, "promptTokens": 1500, "candidatesTokens": 1000, "requestCount": 3, "estimatedUsd": 0.30, "priced": true],
                ["model": "gemini-4-neon-low", "totalTokens": 500, "promptTokens": 300, "candidatesTokens": 200, "requestCount": 1, "estimatedUsd": 0.06, "priced": true],
                ["model": "gemini-3.8-flash-n", "totalTokens": 800, "promptTokens": 500, "candidatesTokens": 300, "requestCount": 4, "estimatedUsd": 0.04, "priced": true],
            ])
            check(folded.count == 2, "Thinking effort variants of gemini-4-neon must fold into 1 row while keeping -n separate (got \(folded.count))")
            check((folded.first?["model"] as? String) == "gemini-4-neon", "Folded model key must be gemini-4-neon (got \(folded.first?["model"] ?? ""))")
            check(intVal(folded[0], "totalTokens") == 4000, "Folded totalTokens must sum to 4000")
            check(intVal(folded[0], "requestCount") == 6, "Folded requestCount must sum to 6")
            check(abs(doubleVal(folded[0], "estimatedUsd") - 0.48) < 1e-6, "Folded estimatedUsd must sum to 0.48")
            check((folded[1]["model"] as? String) == "gemini-3.8-flash-n", "Non-thinking -n suffix must remain distinct")
        }

        // OPT-08 / OPT-11 / OPT-12 / OPT-16: Claude Fable/Mythos & GPT-6+ safe sorting, MenuPanel warningSummary/outdated footer/15s refresh & keyboard navigation
        do {
            L10n.shared.setLanguage("zh-Hans", notify: false)
            let futureHost = Assistant(state: state.appendingPathComponent("opt-future-pricing"))
            futureHost.configuration = try ConfigurationStore(state: futureHost.state)
            futureHost.bridge = BackendBridge(resources: state, state: futureHost.state)
            futureHost.reachable = true
            let futureSheet = PricingSyncSheetController(app: futureHost)
            let futurePayload: [String: Any] = [
                "synced": true,
                "status": ["lastCheckAt": 1794539910722.0, "modelCount": 5],
                "prices": [
                    "claude-opus-5-5": ["input": 4.0, "output": 20.0, "cached": 0.2],
                    "claude-fable-5-2": ["input": 8.0, "output": 40.0, "cached": 0.2],
                    "claude-mythos-5-2": ["input": 8.0, "output": 40.0, "cached": 0.2],
                    "gpt-6.2-astra": ["input": 8.0, "output": 40.0, "cached": 0.4],
                    "gpt-6-luna": ["input": 0.1, "output": 0.5, "cached": 0.01],
                ],
                "pricingStatus": [
                    "claude-opus-5-5": "confirmed",
                    "claude-fable-5-2": "confirmed",
                    "claude-mythos-5-2": "confirmed",
                    "gpt-6.2-astra": "confirmed",
                    "gpt-6-luna": "confirmed",
                ],
                "modelCatalogState": [
                    "claude-opus-5-5": ["availability": "available", "displayName": "Claude Opus 5.5"],
                    "claude-fable-5-2": ["availability": "available", "displayName": "Claude Fable 5.2"],
                    "claude-mythos-5-2": ["availability": "available", "displayName": "Claude Mythos 5.2"],
                    "gpt-6.2-astra": ["availability": "available", "displayName": "GPT-6.2 Astra"],
                    "gpt-6-luna": ["availability": "available", "displayName": "GPT-6 Luna"],
                ]
            ]
            futureSheet.show(in: window, payload: futurePayload)
            pump()
            let sortedFutureKeys = futureSheet.renderedSummaryLines.compactMap { $0.split(separator: " ").first.map(String.init) }
            check(sortedFutureKeys.count == 5, "Future models must render without NSRangeException crash (got \(sortedFutureKeys.count))")
            if let opusIdx = sortedFutureKeys.firstIndex(of: "claude-opus-5-5"),
               let fableIdx = sortedFutureKeys.firstIndex(of: "claude-fable-5-2"),
               let astraIdx = sortedFutureKeys.firstIndex(of: "gpt-6.2-astra"),
               let lunaIdx = sortedFutureKeys.firstIndex(of: "gpt-6-luna") {
                check(opusIdx < fableIdx, "Claude 5.5 must sort before Claude Fable 5.2")
                check(astraIdx < lunaIdx, "GPT-6.2 Astra must sort before GPT-6 Luna")
            } else {
                check(false, "Expected all future model keys in renderedSummaryLines: \(sortedFutureKeys)")
            }
            futureSheet.closeSheet(); waitForSheetDetach(on: window, description: "Future PricingSyncSheetController to detach")

            let optHost = Assistant(state: state.appendingPathComponent("opt-menu-panel"))
            optHost.configuration = try ConfigurationStore(state: optHost.state)
            optHost.bridge = BackendBridge(resources: state, state: optHost.state)
            optHost.reachable = true
            optHost.menuTracking = true
            var usageCalls = 0
            var recommendCalls = 0
            optHost.bridge.fixtureReply = { req in
                let cmd = req["command"] as? String ?? ""
                if cmd == "usage_summary" {
                    usageCalls += 1
                    return [
                        "ok": true, "period": "today", "snapshotId": "opt11-snap-\(usageCalls)",
                        "summary": ["availability": "complete", "totalTokens": 1200, "requestCount": 2, "estimatedUsd": 0.25, "pricedModels": 1, "unpricedModels": 0],
                        "byModel": [["model": "gemini-3.6-flash", "totalTokens": 1200, "requestCount": 2, "estimatedUsd": 0.25, "priced": true, "pricingStatus": "expired"]],
                        "dailyTrends": [], "todayHourly": []
                    ]
                }
                if cmd == "auto_switch_best" {
                    recommendCalls += 1
                    return ["ok": true, "shouldSwitch": true, "account": ["id": "opt-b"]]
                }
                return ["ok": true]
            }
            optHost.cachedAccounts = [
                [
                    "id": "opt-a", "email": "opta@example.invalid", "subscription_tier": "PRO",
                    "quotaWarnings": ["NO_MODEL_RECORDS: 未返回模型配额记录"],
                    "quotaWarningCodes": ["NO_MODEL_RECORDS"]
                ],
                ["id": "opt-b", "email": "optb@example.invalid", "subscription_tier": "PRO"]
            ]
            optHost.activeAccountId = "opt-a"
            optHost.lastFetchedAccountsRevision = "rev-opt-1"
            let optMenu = optHost.ensureMenuPanelController()
            optMenu.selectTab(0, persist: false); pump()
            let callsAfterOpen = usageCalls
            check(callsAfterOpen >= 1, "OPT-11: Initial MenuPanel Tab 0 should fetch usage_summary")
            optHost.usageLastFetchTimeByPeriod["today"] = Date(timeIntervalSinceNow: -20)
            optMenu.syncFromAssistant(updateSize: false)
            pump()
            check(usageCalls > callsAfterOpen, "OPT-11: Stale 15s usage cache while MenuPanel Tab 0 is shown must auto-refresh usage_summary")
            check(optMenu.usageFooterLabel.stringValue.contains("价格待核对") || optMenu.usageFooterLabel.stringValue.contains("定价已过期"), "OPT-11: MenuPanel usage footer must indicate expired model pricing")

            optMenu.selectTab(1, persist: false); pump()
            check(!optMenu.quotaWarningLabel.isHidden && !optMenu.quotaWarningLabel.stringValue.isEmpty, "OPT-11: MenuPanel quota tab must display QuotaPresentation.warningSummary")

            optMenu.selectTab(2, persist: false); pump()
            check(recommendCalls == 1 && optHost.cachedRecommendedAccountId == "opt-b", "OPT-12: MenuPanel standalone mode must query auto_switch_best(preview) and populate cachedRecommendedAccountId")
            check(allTextValues(optMenu.accountsCardsStack).contains("推荐备用"), "OPT-12: MenuPanel accounts card must show 推荐备用 badge without opening AccountsPage")
            let optACard = optMenu.accountsCardsStack.arrangedSubviews.compactMap { $0 as? MenuExpandableAccountCardView }.first { $0.accountId == "opt-a" }
            check((optACard?.warningLabel.isHidden == false) && !(optACard?.warningLabel.stringValue.isEmpty ?? true), "OPT-11: MenuExpandableAccountCardView must display QuotaPresentation.warningSummary")

            // OPT-16: Segmented tabs left/right keyboard navigation
            let segTabs = MenuSegmentedTabsView(items: ["A", "B", "C"], style: .primaryTabs, accessibilityLabel: "TestTabs")
            segTabs.moveSelection(by: 1)
            check(segTabs.selectedIndex == 1, "OPT-16: MenuSegmentedTabsView right arrow moves selection to index 1")
            segTabs.moveSelection(by: -1)
            check(segTabs.selectedIndex == 0, "OPT-16: MenuSegmentedTabsView left arrow moves selection back to index 0")
            let designSeg = DesignSegmentedControl(labels: ["One", "Two", "Three"])
            designSeg.moveSelection(by: 2)
            check(designSeg.selectedSegment == 2, "OPT-16: DesignSegmentedControl right arrow moves selection to index 2")
        }

        // Standby cooling UX: auto-refresh eligibility, plain-language reset labels, and deferred single-account notices
        do {
            L10n.shared.setLanguage("zh-Hans", notify: false)
            let standbyHost = Assistant(state: state.appendingPathComponent("standby-cooling-ux"))
            standbyHost.configuration = try ConfigurationStore(state: standbyHost.state)
            standbyHost.bridge = BackendBridge(resources: state, state: standbyHost.state)
            standbyHost.reachable = true
            standbyHost.menuTracking = true

            check(!standbyHost.isEligibleForAutoQuotaRefresh(["id": "a", "standbyRefreshStatus": ["mode": "snapshot_cooling"]]), "isEligibleForAutoQuotaRefresh must return false for snapshot_cooling")
            check(!standbyHost.isEligibleForAutoQuotaRefresh(["id": "b", "standbyRefreshStatus": ["mode": "snapshot_cooldown_elapsed"]]), "isEligibleForAutoQuotaRefresh must return false for snapshot_cooldown_elapsed")
            check(standbyHost.isEligibleForAutoQuotaRefresh(["id": "c", "standbyRefreshStatus": ["mode": "live_active"]]), "isEligibleForAutoQuotaRefresh must return true for live_active")
            check(standbyHost.isEligibleForAutoQuotaRefresh(["id": "d", "standbyRefreshStatus": ["mode": "cloud_auto"]]), "isEligibleForAutoQuotaRefresh must return true for cloud_auto")

            let overdueIso = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -3600))
            let futureIso = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: 4 * 3600))
            let sampleTs = Date().timeIntervalSince1970 - 1800
            let standbyAccountsList: [[String: Any]] = [
                [
                    "id": "sb-active", "email": "active@example.invalid", "subscription_tier": "PRO",
                    "standbyRefreshStatus": ["mode": "live_active", "hasLocalOAuthClient": false, "canBackgroundRefresh": true],
                    "quota": ["last_updated": Date().timeIntervalSince1970],
                    "quotaGroups": [[
                        "key": "gemini", "displayName": "Gemini", "brands": ["gemini"], "isStandalone": false, "availability": "available", "quotaState": "known",
                        "windows": [["id": "5h", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.85, "stale": false, "resetTime": futureIso]]
                    ]]
                ],
                [
                    "id": "sb-cooling", "email": "cooling@example.invalid", "subscription_tier": "PRO",
                    "standbyRefreshStatus": ["mode": "snapshot_cooling", "hasLocalOAuthClient": false, "canBackgroundRefresh": false],
                    "quota": ["last_updated": sampleTs],
                    "quotaGroups": [[
                        "key": "gemini", "displayName": "Gemini", "brands": ["gemini"], "isStandalone": false, "availability": "available", "quotaState": "known",
                        "windows": [["id": "5h", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.72, "stale": true, "resetTime": futureIso]]
                    ]]
                ],
                [
                    "id": "sb-elapsed", "email": "elapsed@example.invalid", "subscription_tier": "PRO",
                    "standbyRefreshStatus": ["mode": "snapshot_cooldown_elapsed", "hasLocalOAuthClient": false, "canBackgroundRefresh": false, "cooldownElapsedFamilies": ["gemini"]],
                    "quota": ["last_updated": sampleTs],
                    "quotaGroups": [[
                        "key": "gemini", "displayName": "Gemini", "brands": ["gemini"], "isStandalone": false, "availability": "available", "quotaState": "known",
                        "windows": [["id": "5h", "period": "5h", "label": "5 小时", "known": true, "remaining": 0.20, "stale": true, "resetTime": overdueIso]]
                    ]]
                ]
            ]
            let deferredNotice = L10n.t("account_cloud.err.missing_oauth_client")
            standbyHost.bridge.fixtureReply = { req in
                let cmd = req["command"] as? String ?? ""
                if cmd == "account_list" {
                    return ["ok": true, "accounts": standbyAccountsList, "activeId": "sb-active", "currentAccountId": "sb-active"]
                }
                if cmd == "quota_refresh" {
                    return ["ok": true, "standbyDeferred": true, "notice": deferredNotice]
                }
                if cmd == "auto_switch_best" {
                    return ["ok": true, "shouldSwitch": false]
                }
                return ["ok": true]
            }
            standbyHost.cachedAccounts = standbyAccountsList
            standbyHost.activeAccountId = "sb-active"
            let standbyMenu = standbyHost.ensureMenuPanelController()
            standbyMenu.selectTab(2, persist: false); pump()
            standbyHost.refreshSingleAccountQuota(id: "sb-elapsed")
            waitUntil(step: 0.01, description: "standby deferred single-account refresh notice") {
                !standbyHost.refreshingAccountIds.contains("sb-elapsed")
                    && !standbyHost.accountListInFlight
            }
            pump()
            check(standbyHost.singleAccountRefreshErrors["sb-elapsed"] == nil, "standbyDeferred must not populate singleAccountRefreshErrors")
            check(standbyHost.singleAccountRefreshNotices["sb-elapsed"] == deferredNotice, "standbyDeferred must store notice in singleAccountRefreshNotices")
            let coolingMenuCard = standbyMenu.accountsCardsStack.arrangedSubviews.compactMap { $0 as? MenuExpandableAccountCardView }.first { $0.accountId == "sb-cooling" }
            let elapsedMenuCard = standbyMenu.accountsCardsStack.arrangedSubviews.compactMap { $0 as? MenuExpandableAccountCardView }.first { $0.accountId == "sb-elapsed" }
            check(coolingMenuCard?.timestampLabel.stringValue.contains("切换后同步") == true && coolingMenuCard?.timestampLabel.textColor == .secondaryLabelColor, "Menu cooling card footer shows plain recorded timestamp in secondaryLabelColor")
            check(elapsedMenuCard?.timestampLabel.stringValue == L10n.t("accounts.standby.reset_passed") && elapsedMenuCard?.timestampLabel.textColor == Design.blue, "Menu elapsed card footer shows reset_passed in Design.blue")
            check(elapsedMenuCard?.quotaRowViews.first?.resetLabel.stringValue == L10n.t("accounts.standby.likely_reset"), "Menu elapsed card window shows compact 预计已重置 instead of 已过期")
            check(elapsedMenuCard?.warningLabel.isHidden == false && elapsedMenuCard?.warningLabel.stringValue == deferredNotice && elapsedMenuCard?.warningLabel.textColor == .secondaryLabelColor, "Menu elapsed card displays deferred notice in neutral secondaryLabelColor")

            let standbyAccountsPage = AccountsPage(app: standbyHost)
            standbyAccountsPage.fetch(["accounts": standbyAccountsList, "activeId": "sb-active", "pendingSwitch": false]); pump()
            let standbyPageTexts = allTextValues(standbyAccountsPage.cardsStack)
            check(standbyPageTexts.contains { $0.contains(L10n.t("accounts.standby.likely_reset_sync")) }, "AccountsPage wide card shows 预计已重置 · 切换后更新 for overdue standby window: \(standbyPageTexts)")
            check(standbyPageTexts.contains { $0 == L10n.t("accounts.standby.reset_passed") }, "AccountsPage wide card shows reset_passed footer")
            check(standbyPageTexts.contains { $0 == deferredNotice }, "AccountsPage wide card displays deferred notice")

            standbyHost.confirmSwitchForTesting = { _, cb in cb(true) }
            standbyHost.requestInteractiveAccountSwitch(id: "sb-elapsed", email: "elapsed@example.invalid", name: "")
            waitUntil(step: 0.01, description: "standby switch clears singleAccountRefreshNotices") {
                !standbyHost.accountSwitchInFlight && standbyHost.singleAccountRefreshNotices["sb-elapsed"] == nil
            }
            check(standbyHost.singleAccountRefreshNotices["sb-elapsed"] == nil, "Successful switch must clear singleAccountRefreshNotices for target account")
        }

        let result:[String:Any] = ["stableOnlySelectionPassed":true,"nativeLayouts":captures.count,"captures":captures,"enCaptures":enCaptures,"menuCaptures":6,"safeSwitchSharedFlowPassed":true,"emailWidthPassed":true,"partialPricingPassed":true,"headlessNoVisibleWindowLeaksPassed":true,"nativeAssertions":assertionCount,"scope":"isolated synthetic AppKit fixture; not installed-app acceptance"]
        window.orderOut(nil)
        assertNoVisibleWindowsOnScreen("after-main-window-orderOut")
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("native-ui-results.json"))
        print("\(captures.count) current-page native layouts, \(enCaptures.count) English layouts, and 6 menu states; fixture checks passed")
    }
}
