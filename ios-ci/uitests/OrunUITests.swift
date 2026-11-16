import XCTest

/// OrunDocs simulator UI tests (CI harness only; not part of the shipped app).
/// Screenshots + hierarchy dumps go to $OD_SHOTS (passed as TEST_RUNNER_OD_SHOTS).
final class OrunUITests: XCTestCase {
    private lazy var device: String = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    private lazy var outDir: URL = {
        let p = ProcessInfo.processInfo.environment["OD_SHOTS"] ?? NSTemporaryDirectory()
        let u = URL(fileURLWithPath: p, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    // MARK: helpers
    private func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        try? s.pngRepresentation.write(to: outDir.appendingPathComponent("\(device)-\(name).png"))
    }

    private func dump(_ name: String, _ app: XCUIApplication) {
        try? app.debugDescription.write(to: outDir.appendingPathComponent("\(device)-\(name).txt"), atomically: true, encoding: .utf8)
    }

    private func record(_ check: String, _ ok: Bool, _ note: String = "") {
        let line = "\(device) \(check) \(ok ? "PASS" : "FAIL") \(note)\n"
        print("ODRESULT: " + line)
        let url = outDir.appendingPathComponent("results-\(device).txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        if !ok { XCTFail("\(check) failed \(note)") }
    }

    private func any(_ root: XCUIElement, _ format: String) -> XCUIElement {
        return root.descendants(matching: .any).matching(NSPredicate(format: format)).firstMatch
    }

    private func waitAny(_ elements: [XCUIElement], timeout: TimeInterval) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            for e in elements where e.exists { return e }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < end
        return nil
    }

    private var currentApp: XCUIApplication?

    /// Scroll the web view (drag in the content column) until the element is inside the visible window.
    private func reveal(_ e: XCUIElement) {
        guard let app = currentApp, e.exists else { return }
        let win = app.windows.firstMatch.frame
        var last = CGRect.null
        var xs: [CGFloat] = [0.96, 0.6, 0.3]
        for _ in 0..<20 {
            let f = e.frame
            if f.isEmpty || win.isEmpty { return }
            if f.minY >= win.minY + 90 && f.maxY <= win.maxY - 60 { return }
            if f == last {
                // drag did not scroll (e.g. landed on a gesture-capturing widget): try another column
                xs.removeFirst()
                if xs.isEmpty { return }
            }
            last = f
            let up = f.midY > win.midY
            let x = xs[0]
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: up ? 0.7 : 0.35))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: up ? 0.4 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end)
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    private func tapCenter(_ e: XCUIElement) {
        reveal(e)
        if e.isHittable { e.tap() } else { e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        for b in [app.buttons["Done"], app.toolbars.buttons["Done"], app.keyboards.buttons["Hide keyboard"], app.buttons["Hide keyboard"], app.buttons["dismiss"]] where b.exists && b.isHittable {
            b.tap(); Thread.sleep(forTimeInterval: 1); if app.keyboards.count == 0 { return }
        }
    }

    // MARK: shared
    private let btnType = XCUIElement.ElementType.button.rawValue
    private var reviewEmail: String { (ProcessInfo.processInfo.environment["OD_REVIEW_EMAIL"] ?? "").lowercased() }
    private let safariVS = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")

    /// App Store screenshot (raw XCUIScreen PNG; alpha is stripped and sizes verified after download).
    private func appshot(_ n: String) {
        let s = XCUIScreen.main.screenshot()
        let dir = outDir.appendingPathComponent("appstore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? s.pngRepresentation.write(to: dir.appendingPathComponent("\(device)-\(n).png"))
    }

    private func loginButton(_ app: XCUIApplication) -> XCUIElement {
        any(app, "label CONTAINS '로그인 (Google' AND elementType == \(btnType)")
    }

    private func accountChip(_ app: XCUIApplication) -> XCUIElement {
        let e = reviewEmail
        return any(app, "label CONTAINS[c] '\(e.isEmpty ? "@" : e)' AND elementType == \(btnType)")
    }

    /// Find an element either in the app or in the out-of-process web authentication sheet.
    private func web(_ format: String) -> XCUIElement? {
        for root in [currentApp!, safariVS] {
            let e = any(root, format)
            if e.exists { return e }
        }
        return nil
    }

    private func waitWeb(_ format: String, _ timeout: TimeInterval) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        repeat { if let e = web(format) { return e }; Thread.sleep(forTimeInterval: 0.7) } while Date() < end
        return nil
    }

    private func hasFocus(_ e: XCUIElement) -> Bool { (e.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }

    /// Type into an out-of-process web field: make sure it has focus, type slowly, verify, retry once.
    private func typeInto(_ field: XCUIElement, _ text: String, secure: Bool) -> Bool {
        for attempt in 0..<3 {
            for i in 0..<4 where !hasFocus(field) {
                if i == 0 || i == 2 {
                    // the field may sit under the keyboard accessory bar: move focus with "Next" first
                    if let next = [currentApp!.buttons["Next"], safariVS.buttons["Next"], currentApp!.buttons["Next Field"], safariVS.buttons["Next Field"]].first(where: { $0.exists && $0.isHittable }) {
                        next.tap(); Thread.sleep(forTimeInterval: 1); continue
                    }
                }
                if i == 1, let done = [currentApp!.buttons["Done"], safariVS.buttons["Done"]].first(where: { $0.exists && $0.isHittable }) {
                    done.tap(); Thread.sleep(forTimeInterval: 1)
                }
                field.tap(); Thread.sleep(forTimeInterval: 1)
            }
            if !hasFocus(field) { print("ODNOTE: field not focused (attempt \(attempt + 1))"); continue }
            let current = (field.value as? String) ?? ""
            let placeholder = field.placeholderValue ?? ""
            if !current.isEmpty && current != placeholder {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
            }
            if secure { field.typeText(text) } else { for ch in text { field.typeText(String(ch)); Thread.sleep(forTimeInterval: 0.12) } }
            Thread.sleep(forTimeInterval: 0.5)
            let v = (field.value as? String) ?? ""
            let ok = secure ? v.count == text.count : v.lowercased() == text.lowercased()
            if ok { return true }
            print("ODNOTE: typed value mismatch (attempt \(attempt + 1), len \(v.count) vs \(text.count))")
        }
        return false
    }

    private func consentAlert(_ app: XCUIApplication, _ timeout: TimeInterval) -> XCUIElement? {
        waitAny([springboard.alerts.firstMatch, app.alerts.firstMatch], timeout: timeout)
    }

    private func tapLoginUntilConsent(_ app: XCUIApplication, _ login: XCUIElement) -> XCUIElement? {
        Thread.sleep(forTimeInterval: 4)
        for attempt in 0..<4 {
            if login.exists { tapCenter(login) }
            if let a = consentAlert(app, attempt == 3 ? 20 : 10) { return a }
            Thread.sleep(forTimeInterval: 2)
            print("ODNOTE: consent prompt not shown after tap attempt \(attempt + 1); retrying")
        }
        return nil
    }

    // MARK: a + b0: gate visible, consent prompt, cancel
    func test1_GateAndCancel() {
        let app = XCUIApplication()
        currentApp = app
        app.launch()
        let login = loginButton(app)
        let gateOk = login.waitForExistence(timeout: 60)
        let msg = any(app, "label CONTAINS '로그인해 주세요'")
        _ = msg.waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 1.5)
        shot("a-gate")
        appshot("01")
        dump("a-gate", app)
        record("a-gate-visible", gateOk && msg.exists, "button=\(gateOk ? login.label : "missing") message=\(msg.exists)")
        guard gateOk else { return }
        let alert = tapLoginUntilConsent(app, login)
        shot("b0-consent")
        let label = alert?.label ?? ""
        record("b0-consent-shown", alert != nil && label.contains("web.app"), "alert=\(label)")
        if let alert = alert {
            (alert.buttons["Cancel"].exists ? alert.buttons["Cancel"] : alert.buttons.element(boundBy: 0)).tap()
        }
        let cancelled = any(app, "label CONTAINS '로그인을 취소했습니다'")
        let ok = cancelled.waitForExistence(timeout: 20)
        shot("b0-cancelled")
        record("b0-cancel-message", ok && login.exists, "cancelledMsg=\(ok) gateStillVisible=\(login.exists)")
    }

    // MARK: b: REAL interactive sign-in (no debug hook): consent -> Continue -> email form -> callback -> unlock
    func test2_RealSignIn() {
        let app = XCUIApplication()
        currentApp = app
        app.launch() // no OD_TEST_RT: the debug hook stays inactive
        let env = ProcessInfo.processInfo.environment
        guard let em = env["OD_REVIEW_EMAIL"], let pw = env["OD_REVIEW_PASSWORD"], !em.isEmpty, !pw.isEmpty else {
            record("b-real-signin", false, "review credentials not provided"); return
        }
        let login = loginButton(app)
        guard login.waitForExistence(timeout: 60) else { record("b-real-signin", false, "gate button missing"); return }
        guard let alert = tapLoginUntilConsent(app, login) else { shot("b1-no-consent"); record("b-real-signin", false, "consent prompt not shown"); return }
        shot("b1-consent")
        let cont = alert.buttons["Continue"].exists ? alert.buttons["Continue"] : alert.buttons.element(boundBy: alert.buttons.count - 1)
        cont.tap()
        // web sheet (SafariViewService) loads https://orundocs.web.app/signin
        let summary = waitWeb("label CONTAINS '관리자가 발급한 이메일 계정으로 로그인'", 150)
        Thread.sleep(forTimeInterval: 1.5)
        shot("b2-websheet")
        try? (app.debugDescription + "\n\n==== SafariViewService ====\n" + safariVS.debugDescription)
            .write(to: outDir.appendingPathComponent("\(device)-b2-websheet.txt"), atomically: true, encoding: .utf8)
        guard let summary = summary else { record("b-real-signin", false, "web sign-in sheet / email option not found"); return }
        let hasGoogle = web("label CONTAINS 'Google 계정으로 계속'") != nil
        let hasApple = web("label CONTAINS 'Apple로 계속'") != nil
        record("b2-websheet-choices", hasGoogle && hasApple, "google=\(hasGoogle) apple=\(hasApple) emailOption=true")
        let tf = XCUIElement.ElementType.textField.rawValue, stf = XCUIElement.ElementType.secureTextField.rawValue
        let emailQ = "elementType == \(tf) AND (placeholderValue == '이메일' OR label == '이메일')"
        var emailFieldOpt: XCUIElement? = nil
        for attempt in 0..<4 {
            if attempt < 2 { summary.tap() } else { summary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            emailFieldOpt = waitWeb(emailQ, 6)
            if emailFieldOpt != nil { break }
            print("ODNOTE: email form not expanded after summary tap \(attempt + 1)")
        }
        guard let emailField = emailFieldOpt else { shot("b3-form"); record("b-real-signin", false, "email field not found"); return }
        let emailOk = typeInto(emailField, em, secure: false)
        guard let pwField = waitWeb("elementType == \(stf)", 10) else { shot("b3-form"); record("b-real-signin", false, "password field not found"); return }
        let pwOk = typeInto(pwField, pw, secure: true)
        record("b3-form-typed", emailOk && pwOk, "emailTyped=\(emailOk) passwordTyped=\(pwOk)")
        Thread.sleep(forTimeInterval: 0.5)
        shot("b3-form-filled") // password is masked by the system
        if pwOk && hasFocus(pwField) { pwField.typeText("\n") } // submits the form
        Thread.sleep(forTimeInterval: 3)
        if !accountChip(app).exists, let submit = web("label == '이메일로 로그인' AND elementType == \(btnType)"), submit.isHittable { submit.tap() }
        // callback com.orundocs.app://auth -> token refresh + allowlist -> unlock
        let chip = accountChip(app)
        let end = Date().addingTimeInterval(90)
        var unlocked = false
        while Date() < end {
            if chip.exists { unlocked = true; break }
            // The "Save Password?" alert (shown inside the web sheet) blocks the callback until dismissed.
            // Dismiss it with a coordinate tap on "Not Now" (coordinate taps cannot fail on a vanished element).
            let savePw = app.alerts.matching(NSPredicate(format: "label CONTAINS 'Save Password'")).firstMatch
            if savePw.exists {
                let notNow = savePw.buttons["Not Now"]
                if notNow.exists {
                    let f = notNow.frame
                    if !f.isEmpty { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap() }
                    print("ODNOTE: dismissed Save Password prompt")
                    Thread.sleep(forTimeInterval: 2)
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        Thread.sleep(forTimeInterval: 1.5)
        shot("b4-unlocked")
        dump("b4-unlocked", app)
        let gateGone = !loginButton(app).exists
        let err = any(app, "label CONTAINS '로그인하지 못했습니다' OR label CONTAINS '허용하지 않은' OR label CONTAINS '일치하지 않습니다'")
        record("b-real-signin", unlocked && gateGone, "chipShowsReviewEmail=\(unlocked) gateHidden=\(gateGone) errorShown=\(err.exists ? err.label : "no")")
        try? (unlocked ? "real" : "failed").write(to: outDir.appendingPathComponent("signin-\(device).flag"), atomically: true, encoding: .utf8)
    }

    // MARK: c + d + App Store shots (session persisted from test2; token hook only as fallback)
    func test3_ExamFilesMenu() {
        var app = XCUIApplication()
        currentApp = app
        app.terminate()
        Thread.sleep(forTimeInterval: 3)
        app.launch()
        var chip = accountChip(app)
        var via = "persisted real sign-in session"
        let bootstrap = ProcessInfo.processInfo.environment["OD_BOOTSTRAP_TOKEN"] == "1"
        if !chip.waitForExistence(timeout: bootstrap ? 5 : 60) {
            app.terminate()
            app = XCUIApplication()
            currentApp = app
            app.launchEnvironment["OD_TEST_RT"] = ProcessInfo.processInfo.environment["OD_TEST_RT"] ?? ""
            app.launch()
            chip = accountChip(app)
            via = bootstrap ? "BOOTSTRAP debug token hook with a fresh review-account Firebase refresh token (no UI login in this run)" : "FALLBACK token hook"
            _ = chip.waitForExistence(timeout: 90)
        }
        record("c0-unlocked", chip.exists, "via=\(via)")
        guard chip.exists else { shot("c0-locked"); return }
        // clear the "◀ Safari" return breadcrumb left by the sign-in hand-off: go Home and reopen from SpringBoard
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        let sbIcon = springboard.icons["옳은PDF"]
        let sbOk = sbIcon.waitForExistence(timeout: 5)
        shot("c0b-homescreen-icon")
        record("c0b-homescreen-icon", sbOk, "springboard icon '옳은PDF' present=\(sbOk)")
        app.activate()
        _ = chip.waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        shot("c1-home")
        appshot("02a-home-top")

        // tool library heading near the top for the App Store shot
        let total = any(app, "label CONTAINS '26 TOOLS'")
        let cards = app.buttons.matching(NSPredicate(format: "label ENDSWITH '도구 열기'"))
        _ = total.waitForExistence(timeout: 15)
        record("c1-home-26-tools", total.exists && cards.count == 26, "cards=\(cards.count)")
        if total.exists {
            reveal(total)
            let win = app.windows.firstMatch.frame
            var guardN = 0
            while total.frame.minY > win.minY + win.height * 0.22 && guardN < 6 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.6)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.45)))
                Thread.sleep(forTimeInterval: 0.8); guardN += 1
            }
            Thread.sleep(forTimeInterval: 1)
            appshot("02b-library")
            shot("c1b-library")
        }

        // d: account menu
        reveal(chip)
        tapCenter(chip)
        let del = any(app, "label == '계정 삭제' AND elementType == \(btnType)")
        let menuOk = del.waitForExistence(timeout: 8)
        let adm = any(app, "label == '관리자 페이지' AND elementType == \(btnType)").exists
        let out = any(app, "label == '로그아웃' AND elementType == \(btnType)").exists
        shot("d-account-menu")
        record("d-account-menu", menuOk && adm && out, "관리자페이지=\(adm) 로그아웃=\(out) 계정삭제=\(menuOk) (not pressed)")
        if menuOk { tapCenter(chip); Thread.sleep(forTimeInterval: 1) } // close menu without pressing anything
        if del.exists && del.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap(); Thread.sleep(forTimeInterval: 1) }

        // c: exam scan, 20-photo local batch -> one PDF
        let examOpen = openExamTool(app)
        let header = any(app, "label CONTAINS '사진 낙서 제거' AND label CONTAINS 'PDF' AND elementType != \(btnType)")
        record("c2-exam-open", examOpen && header.exists, "header='사진 낙서 제거 → PDF' present=\(header.exists)")
        guard examOpen else { shot("c2-exam-missing"); dump("c2-exam-missing", app); return }
        shot("c2-exam-tool")
        let want = Int(ProcessInfo.processInfo.environment["OD_BATCH_N"] ?? "20") ?? 20
        var tappedN = 0, confirmedPick = false
        let importMode = ProcessInfo.processInfo.environment["OD_IMPORT"] ?? "photos"
        if importMode == "files" {
            let (n, opened, notes) = pickFiles(app, folder: "exam-batch", want: want)
            record("c3a-files-import", n == want && opened, "verifiedSelected=\(n) opened=\(opened) \(notes)")
            tappedN = n; confirmedPick = opened
            let pagesNow = app.buttons.matching(NSPredicate(format: "label ENDSWITH '번 페이지 열기'")).count
            if !(n == want && opened) && pagesNow > 0 {
                record("c3a-photos-strict-fallback", false, "not attempted: \(pagesNow) page(s) already imported by the Files picker; a fallback would mix inputs")
            } else if !(n == want && opened) {
                Thread.sleep(forTimeInterval: 2)
                let (m, ok, note) = pickPhotosStrict(app, match: "2024", want: want)
                record("c3a-photos-strict-fallback", m == want && ok, note)
                tappedN = m; confirmedPick = ok
            }
        } else {
            (tappedN, confirmedPick) = pickPhotos(app, match: "2024", want: want)
        }
        let pages = app.buttons.matching(NSPredicate(format: "label ENDSWITH '번 페이지 열기'"))
        var loaded = 0
        let loadEnd = Date().addingTimeInterval(90)
        repeat { Thread.sleep(forTimeInterval: 2); let c = pages.count; if c == loaded && c > 0 && c >= tappedN { break }; loaded = c } while Date() < loadEnd
        loaded = pages.count
        record("c3-batch-photos-loaded", loaded == want, "wanted=\(want) tappedTiles=\(tappedN) pickerConfirmed=\(confirmedPick) pagesInApp=\(loaded)")
        guard loaded > 0 else { shot("c3-no-pages"); dump("c3-no-pages", app); return }
        // crop step
        let corners = app.buttons.matching(NSPredicate(format: "label ENDSWITH '모서리'"))
        let cropTab = any(app, "label == '영역 맞추기' AND elementType == \(btnType)")
        if cropTab.exists { reveal(cropTab) }
        Thread.sleep(forTimeInterval: 1.5)
        shot("c3b-crop-step")
        record("c3b-crop-step", corners.count >= 4, "cornerHandles=\(corners.count)")
        let run = any(app, "(label CONTAINS '사진 낙서 제거' OR label CONTAINS '필기 지우기 실행') AND elementType == \(btnType)")
        guard run.waitForExistence(timeout: 30) else { shot("c4-no-run"); record("c4-processed", false, "run button not found"); return }
        Thread.sleep(forTimeInterval: 2)
        reveal(run); tapCenter(run)
        let t0 = Date()
        let endLabel = waitBatchEnd(app, timeout: TimeInterval(60 + 45 * loaded))
        let secs = Int(Date().timeIntervalSince(t0))
        let (doneN, failN) = parseBatch(endLabel ?? "")
        record("c4-processed", endLabel != nil && doneN == loaded && failN == 0, "pages=\(loaded) done=\(doneN) incomplete=\(failN) seconds=\(secs) status=\(endLabel ?? "timeout")")
        guard endLabel != nil else { shot("c4-processed-timeout"); dump("c4-timeout", app); return }
        let canvas = any(app, "label == '필기 지운 결과'")
        if canvas.exists { reveal(canvas); Thread.sleep(forTimeInterval: 1) }
        shot("c4-result")
        appshot("03")
        let firstThumb = pages.element(boundBy: 0)
        if firstThumb.exists { reveal(firstThumb); Thread.sleep(forTimeInterval: 1); shot("c4b-batch-pages"); appshot("05-batch") }

        // Files save (one PDF with all pages)
        let save = app.buttons["저장"]
        if save.waitForExistence(timeout: 5) { tapCenter(save) }
        _ = waitAny([app.buttons["Save"], app.buttons["Move"], app.buttons["Browse"]], timeout: 120)
        Thread.sleep(forTimeInterval: 2)
        let local = waitAny([any(app, "label == 'On My iPhone'"), any(app, "label == 'On My iPad'")], timeout: 20)
        var localLabel = local.map { $0.exists ? $0.label : "gone" } ?? "none"
        if let local = local, local.exists, local.isHittable { local.tap(); Thread.sleep(forTimeInterval: 2) }
        if local == nil, app.buttons["Browse"].exists {
            app.buttons["Browse"].tap(); Thread.sleep(forTimeInterval: 2)
            for l in ["On My iPhone", "On My iPad"] where any(app, "label == '\(l)'").exists { any(app, "label == '\(l)'").tap(); localLabel = l; Thread.sleep(forTimeInterval: 2); break }
        }
        shot("c5-export-location")
        let confirm = waitAny([app.buttons["Save"], app.buttons["Move"], app.buttons["Done"]], timeout: 30)
        if let c = confirm, c.exists, c.isEnabled { c.tap() }
        let saved = any(app, "label CONTAINS '저장을 완료'")
        let savedOk = saved.waitForExistence(timeout: 120)
        Thread.sleep(forTimeInterval: 1)
        if savedOk { reveal(saved) }
        shot("c6-saved")
        record("c5-save-files", savedOk, "location=\(localLabel) status=\(savedOk && saved.exists ? saved.label : "")")
        if !savedOk, app.buttons["Cancel"].exists { app.buttons["Cancel"].tap(); Thread.sleep(forTimeInterval: 2) }

        // share sheet (native UIActivityViewController)
        let share = app.buttons["공유"]
        var shareOk = false
        if share.waitForExistence(timeout: 5) {
            reveal(share); tapCenter(share)
            let sheet = waitAny([app.otherElements["ActivityListView"], app.cells["Save to Files"], app.buttons["Close"]], timeout: 60)
            Thread.sleep(forTimeInterval: 2)
            shot("c7-share-sheet")
            shareOk = sheet != nil
            if app.buttons["Close"].exists && app.buttons["Close"].isHittable { app.buttons["Close"].tap() }
            else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
            Thread.sleep(forTimeInterval: 2)
        }
        record("c7-share-sheet", shareOk)

        // PDF 분할: open the saved batch PDF from Files and check its page count in the preview
        let back = any(app, "label == '← 모든 도구' AND elementType == \(btnType)")
        if back.exists { tapCenter(back); Thread.sleep(forTimeInterval: 2) }
        let split = app.buttons["PDF 분할 도구 열기"]
        if !split.waitForExistence(timeout: 6) {
            let side = any(app, "label == '모든 도구' AND elementType == \(btnType)")
            if side.exists { side.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); Thread.sleep(forTimeInterval: 2) }
            let sf = any(app, "placeholderValue CONTAINS '도구 이름' OR label == 'PDF 도구 검색'")
            if sf.exists {
                tapCenter(sf); Thread.sleep(forTimeInterval: 1)
                let cur = (sf.value as? String) ?? ""
                if !cur.isEmpty && !cur.contains("도구 이름") { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: cur.count + 2)) }
                app.typeText("분할"); Thread.sleep(forTimeInterval: 1)
                dismissKeyboard(app)
            }
        }
        guard split.waitForExistence(timeout: 10) else { shot("e0-no-split"); dump("e0-no-split", app); record("e-split-preview", false, "split card not found"); return }
        tapCenter(split)
        let choose = any(app, "label CONTAINS '파일 선택' AND elementType == \(btnType)")
        guard choose.waitForExistence(timeout: 10) else { record("e-split-preview", false, "choose button not found"); return }
        Thread.sleep(forTimeInterval: 1)
        tapCenter(choose)
        var fileTapped = false
        var pickedName = "none"
        let navEnd = Date().addingTimeInterval(60)
        while Date() < navEnd && !fileTapped {
            let batchCell = app.cells.matching(NSPredicate(format: "label CONTAINS '필기제거'")).firstMatch
            if batchCell.exists {
                Thread.sleep(forTimeInterval: 3)
                dump("e1-picker-files", app)
                let acts: [(String, () -> Void)] = [
                    ("tap", { batchCell.tap() }),
                    ("tap-after-wait", { Thread.sleep(forTimeInterval: 3); if batchCell.exists { batchCell.tap() } }),
                    ("thumbnail", { batchCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }),
                    ("doubleTap", { batchCell.doubleTap() }),
                ]
                for (name, act) in acts {
                    act(); Thread.sleep(forTimeInterval: 2.5)
                    if app.buttons["Open"].exists && app.buttons["Open"].isEnabled { app.buttons["Open"].tap(); Thread.sleep(forTimeInterval: 1.5) }
                    if !batchCell.exists { fileTapped = true; pickedName = "batch-pdf via " + name; break }
                    print("ODNOTE: picker still open after batch-pdf \(name)")
                }
                if !fileTapped {
                    shot("e1-picker-stuck")
                    for b in [app.buttons["Cancel"], app.buttons["Close"]] where b.exists && b.isHittable { b.tap(); Thread.sleep(forTimeInterval: 2); break }
                }
                break
            }
            let cf = any(app, "label == 'Choose Files'")
            if cf.exists && cf.isHittable { cf.tap(); Thread.sleep(forTimeInterval: 2); continue }
            if let l = [any(app, "label == 'On My iPhone' AND elementType != \(XCUIElement.ElementType.navigationBar.rawValue)"), any(app, "label == 'On My iPad' AND elementType != \(XCUIElement.ElementType.navigationBar.rawValue)")].first(where: { $0.exists && $0.isHittable }) { l.tap(); Thread.sleep(forTimeInterval: 2); continue }
            if app.buttons["Browse"].exists && app.buttons["Browse"].isHittable { app.buttons["Browse"].tap(); Thread.sleep(forTimeInterval: 2); continue }
            Thread.sleep(forTimeInterval: 1)
        }
        if !fileTapped { shot("e1-picker"); dump("e1-picker", app) }
        let multi = any(app, "label == '여러 페이지' AND (elementType == \(btnType) OR elementType == \(XCUIElement.ElementType.switch.rawValue))")
        let selAll = any(app, "label == '전체 선택'")
        let previewOk = waitAny([multi, selAll], timeout: 60) != nil
        Thread.sleep(forTimeInterval: 3)
        let heading = any(app, "label == 'PDF 페이지 미리보기'")
        if heading.exists {
            reveal(heading)
            let win = app.windows.firstMatch.frame
            var n = 0
            while heading.exists && heading.frame.minY > win.minY + win.height * 0.14 && n < 10 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.6)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.45)))
                Thread.sleep(forTimeInterval: 0.8); n += 1
            }
        } else if multi.exists { reveal(multi) }
        if multi.exists && multi.isHittable { multi.tap() }
        Thread.sleep(forTimeInterval: 6)
        shot("e2-split-preview")
        dump("e2-split-preview", app)
        appshot("04")
        let countLabel = any(app, "label CONTAINS '페이지' AND (label CONTAINS '/ ' OR label BEGINSWITH '\(loaded)페이지')")
        let totalEl = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '/ '")).firstMatch
        let totalTxt = totalEl.exists ? totalEl.label : (countLabel.exists ? countLabel.label : "n/a")
        let pdfPagesOk = pickedName.hasPrefix("batch-pdf") && (totalTxt.contains("/ \(loaded)") || totalTxt.contains("\(loaded)페이지"))
        record("e-split-preview", fileTapped && previewOk, "file=\(pickedName) previewControls=\(previewOk) pageCount=\(totalTxt)")
        record("e2-batch-pdf-pages-in-app-preview", pdfPagesOk, "expected \(loaded) pages in saved PDF; preview shows=\(totalTxt) file=\(pickedName) (authoritative count: host pdf-lib readback of the Files output)")
    }

    // MARK: 4.1.0 helpers
    private func openExamTool(_ app: XCUIApplication) -> Bool {
        let back = any(app, "label == '← 모든 도구' AND elementType == \(btnType)")
        if back.exists { tapCenter(back); Thread.sleep(forTimeInterval: 2) }
        let search = any(app, "placeholderValue CONTAINS '도구 이름' OR label == 'PDF 도구 검색'")
        if search.waitForExistence(timeout: 10) {
            tapCenter(search); Thread.sleep(forTimeInterval: 1)
            let cur = (search.value as? String) ?? ""
            if !cur.isEmpty && !cur.contains("도구 이름") { app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: cur.count + 2)) }
            app.typeText("exam-scan"); Thread.sleep(forTimeInterval: 1)
            dismissKeyboard(app)
        }
        let card = app.buttons.matching(NSPredicate(format: "label ENDSWITH '도구 열기' AND (label CONTAINS '필기' OR label CONTAINS '낙서')")).firstMatch
        guard card.waitForExistence(timeout: 10) else { return false }
        tapCenter(card)
        return any(app, "label CONTAINS '사진 선택' AND elementType == \(btnType)").waitForExistence(timeout: 15)
    }

    /// Import via the native Files (document) picker: "사진 선택" -> "Choose Files" -> On My iPad/exam-batch -> select all
    /// `want` JPEGs -> Open. Selection is verified per cell (isSelected) before Open; on any doubt it cancels.
    /// Returns (verified-selected count, opened, notes).
    private func pickFiles(_ app: XCUIApplication, folder: String, want: Int) -> (Int, Bool, String) {
        var notes: [String] = []
        let pick = any(app, "label CONTAINS '사진 선택' AND elementType == \(btnType)")
        tapCenter(pick)
        guard let choose = waitAny([any(app, "label == 'Choose Files'"), any(app, "label == '파일 선택'")], timeout: 10) else {
            shot("files-0-no-menu"); dump("files-0-no-menu", app); return (0, false, "Choose Files option not found")
        }
        choose.tap(); Thread.sleep(forTimeInterval: 3)
        shot("files-1-picker"); dump("files-1-picker", app)
        let fileCells = app.cells.matching(NSPredicate(format: "label BEGINSWITH 'batch-' AND label CONTAINS 'jpg'"))
        let navEnd = Date().addingTimeInterval(45)
        var path: [String] = []
        while Date() < navEnd && fileCells.count == 0 {
            let folderCell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch
            if folderCell.exists && folderCell.isHittable { folderCell.tap(); path.append("folder"); Thread.sleep(forTimeInterval: 2.5); continue }
            let loc = [any(app, "label == 'On My iPad' AND elementType != \(XCUIElement.ElementType.navigationBar.rawValue) AND elementType != \(XCUIElement.ElementType.staticText.rawValue)"),
                       any(app, "label == 'On My iPhone' AND elementType != \(XCUIElement.ElementType.navigationBar.rawValue) AND elementType != \(XCUIElement.ElementType.staticText.rawValue)"),
                       any(app, "label == 'On My iPad'"), any(app, "label == 'On My iPhone'")].first(where: { $0.exists && $0.isHittable })
            if let l = loc, !path.contains("location") { l.tap(); path.append("location"); Thread.sleep(forTimeInterval: 2.5); continue }
            if app.buttons["Browse"].exists && app.buttons["Browse"].isHittable && !path.contains("browse") { app.buttons["Browse"].tap(); path.append("browse"); Thread.sleep(forTimeInterval: 2.5); continue }
            Thread.sleep(forTimeInterval: 1)
        }
        notes.append("nav=" + path.joined(separator: ">"))
        shot("files-2-folder"); dump("files-2-folder", app)
        guard fileCells.count > 0 else { cancelPicker(app); return (0, false, notes.joined(separator: " ") + " fixture files not visible") }
        // selection mode: some layouts need an explicit "Select" first
        if app.buttons["Select"].exists && app.buttons["Select"].isHittable { app.buttons["Select"].tap(); notes.append("Select-button"); Thread.sleep(forTimeInterval: 1.5) }
        else if let more = [app.buttons["More"], app.buttons["OverflowBarButtonItem"]].first(where: { $0.exists && $0.isHittable }) {
            more.tap(); Thread.sleep(forTimeInterval: 1.5); dump("files-2b-more-menu", app)
            let sel = any(app, "label == 'Select' AND (elementType == \(btnType) OR elementType == \(XCUIElement.ElementType.menuItem.rawValue) OR elementType == \(XCUIElement.ElementType.cell.rawValue))")
            if sel.exists && sel.isHittable { sel.tap(); notes.append("More>Select"); Thread.sleep(forTimeInterval: 1.5) }
            else { notes.append("no Select in More menu"); app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap(); Thread.sleep(forTimeInterval: 1) }
        } else { notes.append("no Select control (assuming multi-select mode)") }
        shot("files-2c-select-mode"); dump("files-2c-select-mode", app)
        var selected = Set<String>()
        var idle = 0
        for _ in 0..<8 {
            var progressed = false
            let n = fileCells.count
            for i in 0..<n where selected.count < want {
                let c = fileCells.element(boundBy: i)
                guard c.exists, c.isHittable else { continue }
                let l = c.label
                if selected.contains(l) { continue }
                if c.isSelected { selected.insert(l); progressed = true; continue }
                for _ in 0..<2 {
                    c.tap()
                    let e = Date().addingTimeInterval(2)
                    while Date() < e && !c.isSelected { Thread.sleep(forTimeInterval: 0.25) }
                    if c.isSelected { break }
                }
                if c.isSelected { selected.insert(l); progressed = true }
                // a single-selection picker would close (or open the file) on the first tap: stop and report
                if !fileCells.firstMatch.exists { notes.append("picker closed after tap (single selection?)"); return (selected.count, true, notes.joined(separator: " ")) }
            }
            if selected.count >= want { break }
            idle = progressed ? 0 : idle + 1
            if idle >= 2 { break }
            let cv = app.collectionViews.firstMatch
            if cv.exists { cv.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
            Thread.sleep(forTimeInterval: 1.2)
        }
        shot("files-3-selected"); dump("files-3-selected", app)
        let summary = any(app, "label CONTAINS 'Selected' OR label CONTAINS '선택됨'")
        notes.append("verifiedSelectedCells=\(selected.count) selectionLabel=\(summary.exists ? summary.label : "n/a")")
        guard selected.count == want else { notes.append("not all selected -> cancelled, not opened"); cancelPicker(app); return (selected.count, false, notes.joined(separator: " ")) }
        let open = [app.buttons["Open"], app.buttons["열기"], app.navigationBars.buttons["Open"]].first(where: { $0.exists })
        guard let o = open, o.isEnabled else { notes.append("Open button missing/disabled"); cancelPicker(app); return (selected.count, false, notes.joined(separator: " ")) }
        o.tap(); notes.append("Open")
        return (selected.count, true, notes.joined(separator: " "))
    }

    private func cancelPicker(_ app: XCUIApplication) {
        for b in [app.buttons["Cancel"], app.buttons["Close"], app.buttons["취소"]] where b.exists && b.isHittable { b.tap(); Thread.sleep(forTimeInterval: 2); return }
    }

    /// Strict PHPicker fallback: upper-right tile taps (the iPad 'Sort and Filter' button overlaps the lower-left of the
    /// bottom-left tile, run 43828012879) and confirm only when every wanted tile reports Selected and the counter equals want.
    private func pickPhotosStrict(_ app: XCUIApplication, match: String, want: Int) -> (Int, Bool, String) {
        let pick = any(app, "label CONTAINS '사진 선택' AND elementType == \(btnType)")
        tapCenter(pick)
        if let lib = waitAny([any(app, "label == 'Photo Library'"), any(app, "label == 'Photos'")], timeout: 10) { lib.tap() }
        let tiles = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo, ' AND label CONTAINS %@", match))
        let end = Date().addingTimeInterval(60)
        repeat { Thread.sleep(forTimeInterval: 2) } while tiles.count == 0 && Date() < end
        Thread.sleep(forTimeInterval: 3)
        for round in 0..<3 {
            for i in 0..<tiles.count {
                let t = tiles.element(boundBy: i)
                guard t.exists, !t.isSelected else { continue }
                t.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.22)).tap()
                let e = Date().addingTimeInterval(2.5)
                while Date() < e && !t.isSelected { Thread.sleep(forTimeInterval: 0.25) }
            }
            let sel = (0..<tiles.count).filter { tiles.element(boundBy: $0).isSelected }.count
            if sel >= want { break }
            print("ODNOTE: strict photo round \(round + 1): selected=\(sel)")
        }
        let sel = (0..<tiles.count).filter { tiles.element(boundBy: $0).isSelected }.count
        let counter = pickerCount(app) ?? -1
        shot("photos-strict-selected"); dump("photos-strict-selected", app)
        let note = "tilesMatching=\(tiles.count) selectedTiles=\(sel) pickerCounter=\(counter)"
        guard sel == want && counter == want else { cancelPicker(app); for b in [app.buttons["Close"], app.buttons["Cancel"]] where b.exists { b.tap(); break }; return (sel, false, note + " -> cancelled, not confirmed") }
        let done = [app.buttons["Done"], app.buttons["Add"]].first(where: { $0.exists && $0.isEnabled })
        done?.tap()
        return (sel, done != nil, note + " confirm=" + (done?.label ?? "none"))
    }

    /// Selected-count shown by the system photo picker ("18 Photos, Locations Included" pill seen in run 43821174005).
    private func pickerCount(_ app: XCUIApplication) -> Int? {
        let q = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ Photos?([ ,].*)?$"))
        let rx = try! NSRegularExpression(pattern: "^([0-9]+) Photo")
        for i in 0..<min(q.count, 6) {
            let l = q.element(boundBy: i).label
            if let m = rx.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)), let r = Range(m.range(at: 1), in: l) { return Int(l[r]) }
        }
        return nil
    }

    /// Multi-select PHPicker tiles whose label contains `match`. Every tap is verified against the picker's own
    /// selected-count; a tap that did not register is repeated once. Returns (picker-reported count, confirm tapped).
    private func pickPhotos(_ app: XCUIApplication, match: String, want: Int) -> (Int, Bool) {
        let pick = any(app, "label CONTAINS '사진 선택' AND elementType == \(btnType)")
        tapCenter(pick)
        if let lib = waitAny([any(app, "label == 'Photo Library'"), any(app, "label == 'Photos'"), any(app, "label == '사진 보관함'")], timeout: 10) { lib.tap() }
        let all = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
        let end = Date().addingTimeInterval(60)
        repeat { Thread.sleep(forTimeInterval: 2) } while all.count == 0 && Date() < end
        Thread.sleep(forTimeInterval: 3)
        shot("pick-grid-\(want)")
        dump("pick-grid-\(want)", app)
        let tiles = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo, ' AND label CONTAINS %@", match))
        var done = Set<String>()
        var count = pickerCount(app) ?? 0
        var counterSeen = false, retried = 0, missed = 0, noCounter = false
        let win = app.windows.firstMatch.frame
        var idle = 0
        for _ in 0..<14 {
            var progressed = false
            for i in 0..<tiles.count where count < want {
                let t = tiles.element(boundBy: i)
                guard t.exists else { continue }
                let l = t.label, f = t.frame
                if done.contains(l) || f.isEmpty { continue }
                if f.minY < win.minY + 120 || f.maxY > win.maxY - 110 { continue }
                if noCounter {
                    // picker exposes no selected-count element: single tap; pages loaded in the app are the authoritative check
                    t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); Thread.sleep(forTimeInterval: 0.8)
                    count += 1; done.insert(l); progressed = true; continue
                }
                var registered = false
                for attempt in 0..<2 {
                    // run 43828012879: iPad 'Sort and Filter' button {433,958,36,36} overlaps the lower-left of the
                    // bottom-left tile, so tap the tile's upper-right area instead of its centre
                    t.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.25)).tap()
                    let wEnd = Date().addingTimeInterval(3)
                    while Date() < wEnd {
                        if let c = pickerCount(app) { counterSeen = true; if c > count { count = c; registered = true; break } }
                        if t.isSelected && pickerCount(app) == nil { registered = true; count += 1; break }
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                    if registered { break }
                    if attempt == 0 { retried += 1; print("ODNOTE: tile tap not registered (\(l)); repeating once") }
                }
                if !registered && !counterSeen && done.isEmpty {
                    // no counter visible at all: this tile was tapped twice (toggled off) -> tap once more and switch mode
                    noCounter = true
                    t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); Thread.sleep(forTimeInterval: 0.8)
                    count += 1; done.insert(l); progressed = true
                    print("ODNOTE: picker selected-count element not found; falling back to single taps")
                    continue
                }
                if !registered { missed += 1 }
                done.insert(l); progressed = true
            }
            if count >= want { break }
            idle = progressed ? 0 : idle + 1
            if idle >= 3 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.4)
            Thread.sleep(forTimeInterval: 1.2)
        }
        shot("pick-selected-\(want)")
        dump("pick-selected-\(want)", app)
        // confirm: labelled Add/Done, else the checkmark button in the picker's top bar right of the search field
        var confirmed = false, how = "none"
        let cEnd = Date().addingTimeInterval(10)
        while Date() < cEnd && !confirmed {
            for b in [app.buttons["Add"], app.buttons["Done"], app.buttons["추가"], app.buttons["완료"]] where b.exists && b.isEnabled && b.isHittable {
                how = "label:" + b.label; b.tap(); confirmed = true; break
            }
            if !confirmed {
                let sf = app.searchFields.firstMatch
                if sf.exists {
                    let sfr = sf.frame
                    let btns = app.buttons.allElementsBoundByIndex.filter { $0.exists && abs($0.frame.midY - sfr.midY) < 40 && $0.frame.minX > sfr.maxX - 2 && $0.frame.width < 90 }
                    if let b = btns.first, b.isEnabled {
                        how = "topbar-right-of-search id='\(b.identifier)' label='\(b.label)'"
                        b.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); confirmed = true
                    }
                }
            }
            if !confirmed { Thread.sleep(forTimeInterval: 0.5) }
        }
        print("ODNOTE: picker want=\(want) pickerCount=\(count) counterSeen=\(counterSeen) retriedTaps=\(retried) missed=\(missed) confirm=\(how)")
        record("pick-\(want)-selection", count == want && confirmed, "pickerCount\(noCounter ? "(assumed, no counter)" : "")=\(count) counterSeen=\(counterSeen) retriedTaps=\(retried) unregisteredTiles=\(missed) confirm=\(how)")
        return (count, confirmed)
    }

    private func waitBatchEnd(_ app: XCUIApplication, timeout: TimeInterval) -> String? {
        let done = any(app, "label CONTAINS '처리가 끝났습니다' OR label CONTAINS '처리를 취소했습니다'")
        return done.waitForExistence(timeout: timeout) ? done.label : nil
    }

    private func parseBatch(_ s: String) -> (Int, Int) {
        let rx = try! NSRegularExpression(pattern: "(\\d+)장 완료 · (\\d+)장 미완료")
        guard let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) else { return (-1, -1) }
        return (Int(s[a]) ?? -1, Int(s[b]) ?? -1)
    }

    // MARK: forged session must be denied (debug hook seeds a fake refresh token; online verification must reject it)
    func test1b_ForgedTokenDenied() {
        let app = XCUIApplication()
        currentApp = app
        app.terminate()
        app.launchEnvironment["OD_TEST_RT"] = "forged-refresh-token-" + String(repeating: "Q9", count: 60)
        app.launch()
        let denied = any(app, "label CONTAINS '허용되지 않은' OR label CONTAINS '허용이 취소'")
        let deniedOk = denied.waitForExistence(timeout: 60)
        Thread.sleep(forTimeInterval: 1.5)
        let locked = loginButton(app).exists
        let unlocked = any(app, "label CONTAINS '@' AND elementType == \(btnType)").exists
        shot("a2-forged-denied")
        record("a2-forged-token-denied", deniedOk && locked && !unlocked, "deniedMessage=\(deniedOk ? denied.label : "none") gateLocked=\(locked) chipShown=\(unlocked)")
        app.terminate()
    }

    // MARK: one real GPT page (iPhone only; OD_GPT=1). Gates: radio, per-batch consent, native confirm. No retries.
    func test4_GPTOnePage() {
        guard ProcessInfo.processInfo.environment["OD_GPT"] == "1" else { return }
        let app = XCUIApplication()
        currentApp = app
        app.terminate(); Thread.sleep(forTimeInterval: 2)
        app.launch()
        guard accountChip(app).waitForExistence(timeout: 60) else { record("g0-unlocked", false, "persisted session missing"); return }
        guard openExamTool(app) else { record("g1-exam-open", false); return }
        let (n, ok) = pickPhotos(app, match: "2024", want: 1)
        let pages = app.buttons.matching(NSPredicate(format: "label ENDSWITH '번 페이지 열기'"))
        let loadEnd = Date().addingTimeInterval(30)
        while pages.count < 1 && Date() < loadEnd { Thread.sleep(forTimeInterval: 1) }
        record("g1-one-photo", pages.count == 1, "tapped=\(n) confirmed=\(ok) pages=\(pages.count)")
        guard pages.count == 1 else { shot("g1-no-photo"); return }
        let radio = any(app, "label CONTAINS 'GPT AI(온라인'")
        guard radio.waitForExistence(timeout: 10) else { record("g2-gpt-radio", false, "radio missing"); return }
        reveal(radio); radio.tap(); Thread.sleep(forTimeInterval: 1.5)
        let consent = any(app, "label CONTAINS 'OpenAI로 전송하고'")
        let consentShown = consent.waitForExistence(timeout: 8)
        shot("g2-gpt-selected")
        record("g2-gpt-radio", consentShown, "radioValue=\(String(describing: radio.value)) consentCheckboxShown=\(consentShown)")
        guard consentShown else { dump("g2-gpt", app); return }
        let run = any(app, "label CONTAINS '사진 낙서 제거' AND elementType == \(btnType)")
        // gate 1: run without consent must be refused locally (no network)
        reveal(run); tapCenter(run)
        let needConsent = any(app, "label CONTAINS '동의가 필요합니다'")
        let g1 = needConsent.waitForExistence(timeout: 10)
        let alert = app.alerts.firstMatch
        record("g3-consent-required", g1 && !alert.exists, "refusedWithoutConsent=\(g1) dialogShown=\(alert.exists)")
        shot("g3-no-consent")
        let errQ = "label CONTAINS '서버가 아직' OR label CONTAINS 'AI 응답' OR label CONTAINS 'AI 이미지' OR label CONTAINS '인터넷 연결이 필요' OR label CONTAINS '온라인 로그인 확인' OR label CONTAINS 'AI 요청 결과' OR label CONTAINS '전송할 사진' OR label CONTAINS '전송 크기' OR label CONTAINS '사용 한도' OR label CONTAINS 'AI 사용 권한' OR label CONTAINS '처리하지 못했습니다' OR label CONTAINS 'AI 처리에 실패'"
        func armAndRun() -> XCUIElement? {
            reveal(consent); consent.tap(); Thread.sleep(forTimeInterval: 1)
            reveal(run); tapCenter(run)
            let end = Date().addingTimeInterval(60)
            while Date() < end {
                if alert.exists { return alert }
                if any(app, errQ).exists { return nil }
                Thread.sleep(forTimeInterval: 1)
            }
            return nil
        }
        func okButton(_ a: XCUIElement) -> XCUIElement {
            [a.buttons["OK"], a.buttons["Ok"], a.buttons["확인"]].first(where: { $0.exists }) ?? a.buttons.element(boundBy: a.buttons.count - 1)
        }
        // gate 2: native confirm -> Cancel must not send
        guard let a1 = armAndRun() else {
            let e = any(app, errQ); shot("g4-no-confirm"); dump("g4-no-confirm", app)
            record("g4-native-confirm", false, "no confirm dialog; status=\(e.exists ? e.label : "none (timeout)")"); return
        }
        let confirmText = a1.label + " " + a1.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | ")
        shot("g4-confirm-dialog")
        (a1.buttons["Cancel"].exists ? a1.buttons["Cancel"] : a1.buttons.element(boundBy: 0)).tap()
        let cancelled = any(app, "label CONTAINS 'AI 전송을 취소했습니다'").waitForExistence(timeout: 10)
        record("g4-native-confirm", confirmText.contains("GPT AI") && cancelled, "dialog='\(confirmText.prefix(160))' cancelRespected=\(cancelled)")
        // real single GPT page: consent + confirm OK, wait once, no retry
        guard let a2 = armAndRun() else {
            let e = any(app, errQ); shot("g5-no-confirm"); record("g5-gpt-page", false, "second confirm missing; status=\(e.exists ? e.label : "none")"); return
        }
        okButton(a2).tap()
        let t0 = Date()
        let endLabel = waitBatchEnd(app, timeout: 240)
        let secs = Int(Date().timeIntervalSince(t0))
        let (d, f) = parseBatch(endLabel ?? "")
        let canvas = any(app, "label == '필기 지운 결과'")
        if canvas.exists { reveal(canvas); Thread.sleep(forTimeInterval: 1.5) }
        shot("g5-gpt-result")
        dump("g5-gpt-result", app)
        let pageErr = any(app, errQ)
        record("g5-gpt-page", endLabel != nil && d == 1 && f == 0, "seconds=\(secs) status=\(endLabel ?? "no end status within 240 s (not retried)") pageError=\(pageErr.exists ? pageErr.label : "none")")
    }

    // MARK: App Review screen recording flow (runs only with OD_RECORD=1; screen is recorded by simctl on the host)
    private func beat(_ t: TimeInterval = 1.3) { Thread.sleep(forTimeInterval: t) }
    private func mark(_ step: String) {
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, step)
        let url = outDir.appendingPathComponent("markers.txt")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        shot("rv-" + step)
    }

    func test9_ReviewRecording() {
        let env = ProcessInfo.processInfo.environment
        guard env["OD_RECORD"] == "1" else { return }
        guard let em = env["OD_DEMO_EMAIL"], let pw = env["OD_DEMO_PASSWORD"], !em.isEmpty, !pw.isEmpty else {
            record("rv-credentials", false, "demo credentials missing"); return
        }
        let app = XCUIApplication()
        currentApp = app
        // 1. launch from the Home Screen
        XCUIDevice.shared.press(.home)
        beat(2)
        var fromHome = false
        let icon = springboard.icons["OrunDocs"]
        for _ in 0..<4 {
            if icon.exists && icon.isHittable { break }
            springboard.swipeLeft(); beat(1)
        }
        if icon.exists && icon.isHittable { mark("01-home-screen"); icon.tap(); fromHome = true } else { app.launch() }
        _ = app.wait(for: .runningForeground, timeout: 30)
        let login = loginButton(app)
        let gateOk = login.waitForExistence(timeout: 60)
        beat(2)
        mark("02-gate")
        record("rv-1-launch-gate", gateOk, "fromHomeScreen=\(fromHome)")
        guard gateOk else { return }

        // 2. real sign-in with the deletion demo account
        guard let alert = tapLoginUntilConsent(app, login) else { record("rv-2-signin", false, "consent prompt not shown"); return }
        beat(1.5)
        mark("03-consent")
        (alert.buttons["Continue"].exists ? alert.buttons["Continue"] : alert.buttons.element(boundBy: alert.buttons.count - 1)).tap()
        guard let summary = waitWeb("label CONTAINS '관리자가 발급한 이메일 계정으로 로그인'", 150) else { mark("03b-websheet-missing"); record("rv-2-signin", false, "web sign-in page not loaded"); return }
        beat(1.5)
        mark("04-web-signin")
        let tf = XCUIElement.ElementType.textField.rawValue, stf = XCUIElement.ElementType.secureTextField.rawValue
        var emailField: XCUIElement? = nil
        for attempt in 0..<4 {
            if attempt < 2 { summary.tap() } else { summary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            emailField = waitWeb("elementType == \(tf) AND (placeholderValue == '이메일' OR label == '이메일')", 6)
            if emailField != nil { break }
        }
        guard let ef = emailField else { record("rv-2-signin", false, "email form not expanded"); return }
        beat()
        let emailOk = typeInto(ef, em, secure: false)
        guard let pf = waitWeb("elementType == \(stf)", 10) else { record("rv-2-signin", false, "password field missing"); return }
        let pwOk = typeInto(pf, pw, secure: true)
        beat()
        mark("05-credentials-typed")
        if pwOk && hasFocus(pf) { pf.typeText("\n") }
        beat(3)
        if let submit = web("label == '이메일로 로그인' AND elementType == \(btnType)"), submit.isHittable, !any(app, "label CONTAINS[c] '\(em.lowercased())'").exists { submit.tap() }
        let chip = any(app, "label CONTAINS[c] '\(em.lowercased())' AND elementType == \(btnType)")
        let end = Date().addingTimeInterval(120)
        var dismissed = false
        while Date() < end && !chip.exists {
            let savePw = app.alerts.matching(NSPredicate(format: "label CONTAINS 'Save Password'")).firstMatch
            if savePw.exists, savePw.buttons["Not Now"].exists {
                let f = savePw.buttons["Not Now"].frame
                if !f.isEmpty { if !dismissed { mark("06-save-password-prompt") }; beat(1); app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap(); dismissed = true }
                beat(2)
            }
            Thread.sleep(forTimeInterval: 1)
        }
        beat(2)
        mark("07-unlocked")
        record("rv-2-signin", emailOk && pwOk && chip.exists, "emailTyped=\(emailOk) pwTyped=\(pwOk) savePasswordDismissed=\(dismissed) unlocked=\(chip.exists)")
        guard chip.exists else { return }

        // 3. home -> exam scan -> result -> save -> share
        let total = any(app, "label CONTAINS '26 TOOLS'")
        if total.waitForExistence(timeout: 10) { reveal(total); beat(2); mark("08-tool-library") }
        let card = app.buttons["시험지 필기 지우기 도구 열기"]
        guard card.waitForExistence(timeout: 10) else { record("rv-3-exam", false, "exam card missing"); return }
        reveal(card); beat(); tapCenter(card)
        let pick = any(app, "label CONTAINS '사진 선택' AND elementType == \(btnType)")
        guard pick.waitForExistence(timeout: 15) else { record("rv-3-exam", false, "exam tool not opened"); return }
        beat(1.5); mark("09-exam-tool")
        tapCenter(pick)
        if let lib = waitAny([any(app, "label == 'Photo Library'"), any(app, "label == 'Photos'")], timeout: 10) { beat(); lib.tap() }
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
        let pickEnd = Date().addingTimeInterval(60)
        repeat { Thread.sleep(forTimeInterval: 2) } while photos.count == 0 && Date() < pickEnd
        beat(2)
        var target: XCUIElement? = nil
        let yearRx = try! NSRegularExpression(pattern: "\\b(19|20)\\d\\d\\b")
        for i in 0..<photos.count {
            let el = photos.element(boundBy: i); let l = el.label
            if yearRx.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) == nil { target = el; break }
        }
        if target == nil && photos.count > 0 { target = photos.element(boundBy: 0) }
        mark("10-photo-picker")
        if let t = target {
            selectLoop: for _ in 0..<3 {
                t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let addEnd = Date().addingTimeInterval(5)
                while Date() < addEnd {
                    for b in [app.buttons["Add"], app.buttons["Done"]] where b.exists && b.isEnabled { beat(1); b.tap(); break selectLoop }
                    if !app.buttons["Cancel"].exists && !app.buttons["Done"].exists { break selectLoop }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        let run = any(app, "label CONTAINS '필기 지우기 실행' AND elementType == \(btnType)")
        guard run.waitForExistence(timeout: 30) else { record("rv-3-exam", false, "photo not loaded"); return }
        beat(2); reveal(run); beat(); mark("11-crop-step")
        tapCenter(run)
        let done = any(app, "label CONTAINS '처리 완료'")
        let doneOk = done.waitForExistence(timeout: 240)
        beat(1.5)
        let canvas = any(app, "label == '필기 지운 결과'")
        if canvas.exists { reveal(canvas) }
        beat(2.5); mark("12-result")
        record("rv-3-exam-processed", doneOk, doneOk ? done.label : "")
        guard doneOk else { return }
        let save = app.buttons["저장"]
        if save.waitForExistence(timeout: 5) { reveal(save); beat(); tapCenter(save) }
        _ = waitAny([app.buttons["Save"], app.buttons["Move"], app.buttons["Browse"]], timeout: 90)
        beat(1.5)
        if let local = waitAny([any(app, "label == 'On My iPhone'")], timeout: 20), local.isHittable { local.tap(); beat(1.5) }
        mark("13-files-sheet")
        if let c = waitAny([app.buttons["Save"], app.buttons["Move"]], timeout: 30), c.isEnabled { c.tap() }
        let saved = any(app, "label CONTAINS '저장을 완료'")
        let savedOk = saved.waitForExistence(timeout: 30)
        if savedOk { reveal(saved) }
        beat(2); mark("14-saved")
        record("rv-3-save-files", savedOk, savedOk && saved.exists ? saved.label : "")
        let share = app.buttons["공유"]
        if share.waitForExistence(timeout: 5) { reveal(share); beat(); tapCenter(share) }
        let sheet = waitAny([app.otherElements["ActivityListView"], app.buttons["Close"], app.cells["Save to Files"]], timeout: 20)
        beat(3); mark("15-share-sheet")
        record("rv-3-share-sheet", sheet != nil)
        if app.buttons["Close"].exists && app.buttons["Close"].isHittable { app.buttons["Close"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() }
        beat(2)

        // 4. back home -> PDF 분할 tool screen
        let back = any(app, "label == '← 모든 도구' AND elementType == \(btnType)")
        if back.exists { reveal(back); beat(); tapCenter(back); beat(2) }
        let split = app.buttons["PDF 분할 도구 열기"]
        if !split.waitForExistence(timeout: 6) {
            let side = any(app, "label == '모든 도구' AND elementType == \(btnType)")
            if side.exists { side.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); beat(2) }
        }
        var splitOk = false
        if split.waitForExistence(timeout: 10) {
            reveal(split); beat(1.5); tapCenter(split)
            splitOk = any(app, "label CONTAINS '파일 선택' AND elementType == \(btnType)").waitForExistence(timeout: 10)
            beat(3); mark("16-split-tool")
        }
        record("rv-4-split-tool", splitOk)

        // 5. account chip -> 계정 삭제 -> OK -> gate "계정을 삭제했습니다"
        reveal(chip); beat(); tapCenter(chip)
        let del = any(app, "label == '계정 삭제' AND elementType == \(btnType)")
        guard del.waitForExistence(timeout: 8) else { record("rv-5-delete", false, "account menu missing"); return }
        beat(2); mark("17-account-menu")
        del.tap()
        let confirmAlert = app.alerts.firstMatch
        var confirmed = false
        if confirmAlert.waitForExistence(timeout: 10) {
            beat(2); mark("18-delete-confirm")
            let ok = [confirmAlert.buttons["OK"], confirmAlert.buttons["확인"]].first(where: { $0.exists }) ?? confirmAlert.buttons.element(boundBy: confirmAlert.buttons.count - 1)
            ok.tap(); confirmed = true
        }
        let gone = any(app, "label CONTAINS '계정을 삭제했습니다'")
        let goneOk = gone.waitForExistence(timeout: 30)
        beat(3); mark("19-deleted-gate")
        record("rv-5-delete", confirmed && goneOk && loginButton(app).exists, "confirmDialog=\(confirmed) deletedMessage=\(goneOk)")
        beat(2)
    }
}
