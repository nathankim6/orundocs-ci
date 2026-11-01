import XCTest

/// OrunDocs simulator UI tests (CI harness only; not part of the shipped app).
/// Screenshots + hierarchy dumps go to $OD_SHOTS (passed as TEST_RUNNER_OD_SHOTS).
final class OrunUITests: XCTestCase {
    private let email = "5554ksj2@gmail.com"
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

    // MARK: a + b: gate visible, sign-in consent sheet, cancel
    func test1_GateAndCancel() {
        let app = XCUIApplication()
        currentApp = app
        app.launch()
        let login = any(app, "label CONTAINS 'Google 계정으로 로그인' AND elementType == \(XCUIElement.ElementType.button.rawValue)")
        let gateOk = login.waitForExistence(timeout: 60)
        let msg = any(app, "label CONTAINS '로그인해 주세요'")
        _ = msg.waitForExistence(timeout: 10)
        shot("a-gate")
        dump("a-gate", app)
        record("a-gate-visible", gateOk && msg.exists, "button=\(gateOk) message=\(msg.exists)")
        let subtitle = any(app, "label CONTAINS '옳은영어 김성진T 문서 작업 공간'")
        record("a-gate-subtitle-absent", !subtitle.exists, "subtitlePresent=\(subtitle.exists)")
        guard gateOk else { return }

        // ASWebAuthenticationSession consent prompt: '"OrunDocs" Wants to Use "web.app" to Sign In'
        let sbAlert = springboard.alerts.firstMatch
        let appAlert = app.alerts.firstMatch
        Thread.sleep(forTimeInterval: 2)
        var alert: XCUIElement? = nil
        for attempt in 0..<3 {
            if login.exists { tapCenter(login) }
            alert = waitAny([sbAlert, appAlert], timeout: attempt == 2 ? 20 : 10)
            if alert != nil { break }
            print("ODNOTE: consent prompt not shown after tap attempt \(attempt + 1); retrying")
        }
        shot("b-consent")
        dump("b-consent-app", app)
        dump("b-consent-springboard", springboard)
        let label = alert?.label ?? ""
        record("b-consent-shown", alert != nil && label.contains("web.app") && label.contains("Sign In"), "alert=\(label)")
        if let alert = alert {
            let cancel = alert.buttons["Cancel"].exists ? alert.buttons["Cancel"] : alert.buttons.element(boundBy: 0)
            cancel.tap()
        }
        let cancelled = any(app, "label CONTAINS '로그인을 취소했습니다'")
        let ok = cancelled.waitForExistence(timeout: 20)
        let stillLocked = login.exists
        shot("b-cancelled")
        dump("b-cancelled", app)
        record("b-cancel-message", ok, "cancelledMsg=\(ok) gateStillVisible=\(stillLocked)")
        record("b-still-locked", stillLocked && !any(app, "label CONTAINS '\(email)'").exists)
    }

    // MARK: c + d: unlock with real token refresh + allowlist, home, exam tool, save, share
    func test2_UnlockAndExam() {
        guard let rt = ProcessInfo.processInfo.environment["OD_TEST_RT"], !rt.isEmpty else {
            record("c-unlock", false, "OD_TEST_RT not provided to test runner"); return
        }
        let app = XCUIApplication()
        app.launchEnvironment["OD_TEST_RT"] = rt
        currentApp = app
        app.launch()
        let account = any(app, "label CONTAINS '\(email)'")
        let unlocked = account.waitForExistence(timeout: 90)
        Thread.sleep(forTimeInterval: 1.5)
        shot("c-unlocked")
        dump("c-unlocked", app)
        let gateGone = !any(app, "label CONTAINS 'Google 계정으로 로그인' AND elementType == \(XCUIElement.ElementType.button.rawValue)").exists
        record("c-unlock", unlocked && gateGone, "accountChip=\(unlocked) gateHidden=\(gateGone)")
        guard unlocked else { return }

        // d: home tool library
        let total = any(app, "label CONTAINS '26 TOOLS'")
        let cards = app.buttons.matching(NSPredicate(format: "label ENDSWITH '도구 열기'"))
        let totalOk = total.waitForExistence(timeout: 15)
        let n = cards.count
        // scroll the library into view for the screenshot
        let search = any(app, "placeholderValue CONTAINS '도구 이름' OR label == 'PDF 도구 검색'")
        _ = search.waitForExistence(timeout: 10)
        shot("d1-home")
        // scroll the home page so content passes under the status bar (iOS status-bar backdrop check)
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.3)))
            Thread.sleep(forTimeInterval: 1)
        }
        Thread.sleep(forTimeInterval: 1)
        shot("d1b-home-scrolled")
        record("d1-home-26-tools", totalOk && n == 26, "label26TOOLS=\(totalOk) cards=\(n)")
        if device == "ipad" && ProcessInfo.processInfo.environment["OD_FULL_IPAD"] == nil { /* iPad: still try the rest */ }

        // open exam tool via search
        if search.exists {
            tapCenter(search)
            Thread.sleep(forTimeInterval: 1)
            app.typeText("exam-scan")
            Thread.sleep(forTimeInterval: 1)
            dismissKeyboard(app)
        }
        let card = app.buttons["시험지 필기 지우기 도구 열기"]
        let cardOk = card.waitForExistence(timeout: 10)
        let n2 = cards.count
        shot("d2-search")
        record("d2-search-filter", cardOk && n2 == 1, "examCard=\(cardOk) visibleCards=\(n2)")
        guard cardOk else { dump("d2-search", app); return }
        tapCenter(card)
        let pick = any(app, "label CONTAINS '사진 선택' AND elementType == \(XCUIElement.ElementType.button.rawValue)")
        let pickOk = pick.waitForExistence(timeout: 15)
        shot("d3-exam-tool")
        record("d3-exam-open", pickOk)
        guard pickOk else { dump("d3-exam", app); return }

        // file input -> menu -> Photo Library -> PHPicker
        tapCenter(pick)
        let lib = waitAny([any(app, "label == 'Photo Library'"), any(app, "label == 'Photos'"), any(app, "label == 'Choose Photo'"),
                           any(app, "label == '사진 보관함'")], timeout: 10)
        shot("d4-input-menu")
        dump("d4-input-menu", app)
        if let lib = lib { lib.tap() }
        // PHPicker can show "Loading..." for a while on a fresh simulator: wait up to 60 s for tiles
        var photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo, '"))
        var photoCount = 0
        let pickEnd = Date().addingTimeInterval(60)
        repeat {
            Thread.sleep(forTimeInterval: 2)
            photoCount = photos.count
        } while photoCount == 0 && Date() < pickEnd
        Thread.sleep(forTimeInterval: 1)
        photoCount = photos.count
        if photoCount == 0 {
            photos = app.collectionViews.cells
            photoCount = photos.count
        }
        shot("d5-photo-picker")
        dump("d5-photo-picker", app)
        var picked = false
        var pickedLabel = ""
        if photoCount > 0 {
            // newest photo = the fixture added by simctl addmedia (current-year labels carry no year)
            var last = photos.element(boundBy: 0)
            let yearRx = try! NSRegularExpression(pattern: "\\b(19|20)\\d\\d\\b")
            for i in 0..<photoCount {
                let el = photos.element(boundBy: i)
                let l = el.label
                if yearRx.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) == nil { last = el; break }
            }
            pickedLabel = last.label
            // PHPicker tiles live in a remote view: tap by coordinate, never scroll the host
            last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            picked = true
            Thread.sleep(forTimeInterval: 1.5)
            let addCandidates = [app.buttons["Add"], app.buttons["추가"], app.buttons["Done"], app.navigationBars.buttons["Add"]]
            let addEnd = Date().addingTimeInterval(6)
            addLoop: while Date() < addEnd {
                for b in addCandidates where b.exists && b.isEnabled { b.tap(); break addLoop }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        record("d5-photo-picked", picked, "lib=\(lib != nil) photos=\(photoCount) picked=\(pickedLabel)")

        let run = any(app, "label CONTAINS '필기 지우기 실행' AND elementType == \(XCUIElement.ElementType.button.rawValue)")
        let runOk = run.waitForExistence(timeout: 30)
        shot("d6-photo-loaded")
        guard runOk else { record("d6-run", false, "run button not found"); dump("d6-loaded", app); return }
        Thread.sleep(forTimeInterval: 2)
        tapCenter(run)
        let done = any(app, "label CONTAINS '처리 완료'")
        let doneOk = done.waitForExistence(timeout: 240)
        Thread.sleep(forTimeInterval: 1)
        if doneOk { reveal(done) }
        shot("d7-processed")
        let canvas = any(app, "label == '필기 지운 결과'")
        if doneOk && canvas.exists { reveal(canvas); Thread.sleep(forTimeInterval: 0.5); shot("d7b-result") }
        record("d7-processed", doneOk, doneOk ? done.label : "")
        guard doneOk else { dump("d7-processed", app); return }

        // Save as PDF -> Files export sheet
        let save = app.buttons["저장"]
        if save.waitForExistence(timeout: 5) { tapCenter(save) }
        _ = waitAny([app.buttons["Save"], app.buttons["Move"], app.buttons["Browse"]], timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        shot("d8-export-sheet")
        dump("d8-export-sheet", app)
        let local = waitAny([any(app, "label == 'On My iPhone'"), any(app, "label == 'On My iPad'"),
                             any(app, "label == '나의 iPhone'"), any(app, "label == '나의 iPad'")], timeout: 5)
        var localLabel = local.map { $0.exists ? $0.label : "gone" } ?? "none"
        if let local = local, local.exists, local.isHittable { local.tap(); Thread.sleep(forTimeInterval: 2) }
        shot("d9-export-location")
        dump("d9-export-location", app)
        if local == nil, app.buttons["Browse"].exists {
            app.buttons["Browse"].tap(); Thread.sleep(forTimeInterval: 2)
            for l in ["On My iPhone", "On My iPad"] where any(app, "label == '\(l)'").exists { any(app, "label == '\(l)'").tap(); localLabel = l; Thread.sleep(forTimeInterval: 2); break }
        }
        let confirm = waitAny([app.buttons["Save"], app.buttons["Move"], app.buttons["Done"], app.buttons["Copy"], app.buttons["Export"]], timeout: 5)
        let confirmLabel = (confirm?.exists ?? false) ? confirm!.label : "none"
        if let c = confirm, c.isEnabled { c.tap() }
        let saved = any(app, "label CONTAINS '저장을 완료'")
        let savedOk = saved.waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)
        if savedOk { reveal(saved) }
        shot("d10-saved")
        if !savedOk { dump("d10-saved", app) }
        record("d8-save-files", savedOk, "location=\(localLabel) confirm=\(confirmLabel) status=\(savedOk && saved.exists ? saved.label : "")")
        if !savedOk {
            // close whatever sheet is still up so share can be attempted
            if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
            Thread.sleep(forTimeInterval: 2)
        }

        // Share sheet
        let share = app.buttons["공유"]
        if share.waitForExistence(timeout: 5) { tapCenter(share) }
        let sheet = waitAny([app.otherElements["ActivityListView"], app.buttons["Close"], app.cells["Save to Files"],
                             app.buttons["Save to Files"], app.staticTexts["Save to Files"], app.cells["Copy"],
                             any(app, "label CONTAINS 'Save to Files' OR label == 'AirDrop' OR label == 'Copy'")], timeout: 20)
        if let sheet = sheet {
            let end = Date().addingTimeInterval(10)
            while Date() < end && sheet.descendants(matching: .cell).count + sheet.descendants(matching: .button).count == 0 { Thread.sleep(forTimeInterval: 0.5) }
        }
        Thread.sleep(forTimeInterval: 3)
        shot("d11-share-sheet")
        dump("d11-share-sheet", app)
        let sheetInfo = (sheet?.exists ?? false) ? "\(sheet!.identifier) \(sheet!.label)" : (sheet == nil ? "none" : "gone")
        record("d11-share-sheet", sheet != nil, "found=\(sheetInfo)")
        if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        Thread.sleep(forTimeInterval: 2)
        shot("d12-after-share")
    }
}
