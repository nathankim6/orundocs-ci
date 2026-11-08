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
        let summary = waitWeb("label CONTAINS '관리자가 발급한 이메일 계정으로 로그인'", 45)
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
            // a system "Save Password?" prompt may appear; it is not tapped (tapping it races with its auto-dismissal)
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
        if !chip.waitForExistence(timeout: 60) {
            app.terminate()
            app = XCUIApplication()
            currentApp = app
            app.launchEnvironment["OD_TEST_RT"] = ProcessInfo.processInfo.environment["OD_TEST_RT"] ?? ""
            app.launch()
            chip = accountChip(app)
            via = "FALLBACK token hook"
            _ = chip.waitForExistence(timeout: 90)
        }
        record("c0-unlocked", chip.exists, "via=\(via)")
        guard chip.exists else { shot("c0-locked"); return }
        // clear the "◀ Safari" return breadcrumb left by the sign-in hand-off: go Home and reopen from SpringBoard
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
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

        // c: exam scan
        let search = any(app, "placeholderValue CONTAINS '도구 이름' OR label == 'PDF 도구 검색'")
        if search.waitForExistence(timeout: 10) {
            tapCenter(search); Thread.sleep(forTimeInterval: 1)
            app.typeText("exam-scan"); Thread.sleep(forTimeInterval: 1)
            dismissKeyboard(app)
        }
        let card = app.buttons["시험지 필기 지우기 도구 열기"]
        guard card.waitForExistence(timeout: 10) else { record("c2-exam-open", false); return }
        tapCenter(card)
        let pick = any(app, "label CONTAINS '사진 선택' AND elementType == \(btnType)")
        guard pick.waitForExistence(timeout: 15) else { record("c2-exam-open", false); return }
        tapCenter(pick)
        if let lib = waitAny([any(app, "label == 'Photo Library'"), any(app, "label == 'Photos'"), any(app, "label == '사진 보관함'")], timeout: 10) { lib.tap() }
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
        let pickEnd = Date().addingTimeInterval(60)
        repeat { Thread.sleep(forTimeInterval: 2) } while photos.count == 0 && Date() < pickEnd
        Thread.sleep(forTimeInterval: 2)
        var picked = false
        var target: XCUIElement? = nil
        let yearRx = try! NSRegularExpression(pattern: "\\b(19|20)\\d\\d\\b")
        for i in 0..<photos.count {
            let el = photos.element(boundBy: i); let l = el.label
            if yearRx.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) == nil { target = el; break }
        }
        if target == nil && photos.count > 0 { target = photos.element(boundBy: 0) }
        if let t = target {
            let addCandidates = [app.buttons["Add"], app.buttons["추가"], app.buttons["Done"]]
            selectLoop: for attempt in 0..<3 {
                t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let addEnd = Date().addingTimeInterval(5)
                while Date() < addEnd {
                    for b in addCandidates where b.exists && b.isEnabled { b.tap(); picked = true; break selectLoop }
                    if !app.buttons["Cancel"].exists && !app.buttons["Done"].exists { picked = true; break selectLoop }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                print("ODNOTE: photo selection not confirmed after attempt \(attempt + 1); retrying")
            }
        }
        record("c3-photo-picked", picked, "photos=\(photos.count)")
        let run = any(app, "label CONTAINS '필기 지우기 실행' AND elementType == \(btnType)")
        guard run.waitForExistence(timeout: 30) else { shot("c4-no-run"); record("c4-processed", false, "run button not found"); return }
        Thread.sleep(forTimeInterval: 2)
        tapCenter(run)
        let done = any(app, "label CONTAINS '처리 완료'")
        let doneOk = done.waitForExistence(timeout: 240)
        record("c4-processed", doneOk, doneOk ? done.label : "")
        guard doneOk else { shot("c4-processed"); return }
        let canvas = any(app, "label == '필기 지운 결과'")
        if canvas.exists { reveal(canvas); Thread.sleep(forTimeInterval: 1) }
        shot("c4-result")
        appshot("03")

        // Files save (PDF)
        let save = app.buttons["저장"]
        if save.waitForExistence(timeout: 5) { tapCenter(save) }
        _ = waitAny([app.buttons["Save"], app.buttons["Move"], app.buttons["Browse"]], timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        let local = waitAny([any(app, "label == 'On My iPhone'"), any(app, "label == 'On My iPad'")], timeout: 5)
        var localLabel = local.map { $0.exists ? $0.label : "gone" } ?? "none"
        if let local = local, local.exists, local.isHittable { local.tap(); Thread.sleep(forTimeInterval: 2) }
        if local == nil, app.buttons["Browse"].exists {
            app.buttons["Browse"].tap(); Thread.sleep(forTimeInterval: 2)
            for l in ["On My iPhone", "On My iPad"] where any(app, "label == '\(l)'").exists { any(app, "label == '\(l)'").tap(); localLabel = l; Thread.sleep(forTimeInterval: 2); break }
        }
        shot("c5-export-location")
        let confirm = waitAny([app.buttons["Save"], app.buttons["Move"], app.buttons["Done"]], timeout: 5)
        if let c = confirm, c.exists, c.isEnabled { c.tap() }
        let saved = any(app, "label CONTAINS '저장을 완료'")
        let savedOk = saved.waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 1)
        if savedOk { reveal(saved) }
        shot("c6-saved")
        record("c5-save-files", savedOk, "location=\(localLabel) status=\(savedOk && saved.exists ? saved.label : "")")
        if !savedOk, app.buttons["Cancel"].exists { app.buttons["Cancel"].tap(); Thread.sleep(forTimeInterval: 2) }

        // App Store shot 4: PDF 분할 with the 6-page fixture from Files
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
        let fileQ = "label BEGINSWITH 'preview-six-pages'"
        var fileTapped = false
        let navEnd = Date().addingTimeInterval(40)
        while Date() < navEnd {
            let cell = app.cells.matching(NSPredicate(format: "label CONTAINS 'preview-six-pages'")).firstMatch
            let f = any(app, fileQ)
            if cell.exists || f.exists {
                let other = app.cells.matching(NSPredicate(format: "label CONTAINS 'exam-photo'")).firstMatch
                let pickerOpen = { app.cells.matching(NSPredicate(format: "label CONTAINS 'preview-six-pages'")).firstMatch.exists }
                let tries: [(String, () -> Void)] = [
                    ("tap", { cell.tap() }),
                    ("thumbnail", { cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }),
                    ("doubleTap", { cell.doubleTap() }),
                    ("label", { f.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }),
                    ("exam-pdf", { if other.exists { other.tap() } }),
                ]
                for (name, act) in tries {
                    act(); Thread.sleep(forTimeInterval: 2.5)
                    if app.buttons["Open"].exists && app.buttons["Open"].isEnabled { app.buttons["Open"].tap(); Thread.sleep(forTimeInterval: 1.5) }
                    if !pickerOpen() { fileTapped = true; print("ODNOTE: picker accepted file via \(name)"); break }
                    print("ODNOTE: picker still open after \(name)")
                }
                if !fileTapped {
                    shot("e1-picker-stuck")
                    for b in [app.buttons["Cancel"], app.buttons["Close"]] where b.exists && b.isHittable { b.tap(); Thread.sleep(forTimeInterval: 2); break }
                    if pickerOpen(), let x = [any(app, "label == 'Close' OR identifier == 'Close'"), any(app, "label == '닫기'")].first(where: { $0.exists && $0.isHittable }) { x.tap(); Thread.sleep(forTimeInterval: 2) }
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
        Thread.sleep(forTimeInterval: 1.5)
        if app.buttons["Open"].exists && app.buttons["Open"].isEnabled { app.buttons["Open"].tap() }
        let multi = any(app, "label == '여러 페이지' AND (elementType == \(btnType) OR elementType == \(XCUIElement.ElementType.switch.rawValue))")
        let selAll = any(app, "label == '전체 선택'")
        let previewOk = waitAny([multi, selAll], timeout: 40) != nil
        if multi.exists { tapCenter(multi) }
        Thread.sleep(forTimeInterval: 5)
        // frame the preview: put the "PDF 페이지 미리보기" heading near the top of the window
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
        Thread.sleep(forTimeInterval: 5)
        shot("e2-split-preview")
        dump("e2-split-preview", app)
        appshot("04")
        let sixLabel = any(app, "label CONTAINS '6' AND label CONTAINS '페이지'")
        record("e-split-preview", fileTapped && previewOk, "fileFromFiles=\(fileTapped) previewControls=\(previewOk) pageCountLabel=\(sixLabel.exists ? sixLabel.label : "n/a")")
    }
}
