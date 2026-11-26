import Foundation
import SQLite3
import UIKit
import XCTest

private final class AuditMockTextDocumentProxy: NSObject, UITextDocumentProxy {
    var documentContextBeforeInput: String? = ""
    var documentContextAfterInput: String? = ""
    var selectedText: String? = nil
    var documentInputMode: UITextInputMode? = nil
    var documentIdentifier: UUID = UUID()
    @objc var isSecureTextEntry: Bool = false

    private(set) var setMarkedTextCalls: [String] = []
    private(set) var insertedTexts: [String] = []
    private(set) var unmarkCount: Int = 0
    private(set) var deleteBackwardCount: Int = 0
    private(set) var currentMarkedText: String? = nil

    var hasText: Bool {
        !(documentContextBeforeInput ?? "").isEmpty || !(currentMarkedText ?? "").isEmpty
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {}

    func setMarkedText(_ markedText: String, selectedRange: NSRange) {
        currentMarkedText = markedText
        setMarkedTextCalls.append(markedText)
    }

    func unmarkText() {
        unmarkCount += 1
        if let text = currentMarkedText, !text.isEmpty {
            insertedTexts.append(text)
            documentContextBeforeInput = (documentContextBeforeInput ?? "") + text
        }
        currentMarkedText = nil
    }

    func insertText(_ text: String) {
        insertedTexts.append(text)
        documentContextBeforeInput = (documentContextBeforeInput ?? "") + text
        currentMarkedText = nil
    }

    func deleteBackward() {
        deleteBackwardCount += 1
        if var str = documentContextBeforeInput, !str.isEmpty {
            str.removeLast()
            documentContextBeforeInput = str
        }
    }
}

final class LokeyAuditTests: XCTestCase {

    // MARK: - Helpers

    private func makeIsolatedSession(
        settings: LokeySettings = LokeySettings()
    ) throws -> (lexicon: MmapLexicon, store: UserLexiconStore, decoder: ViterbiDecoder, session: LokeySessionController, tempDir: URL) {
        let testBundle = Bundle(for: LokeyAuditTests.self)
        let lexURL = try XCTUnwrap(
            testBundle.url(forResource: "lokey_lexicon", withExtension: "bin")
                ?? Bundle.main.url(forResource: "lokey_lexicon", withExtension: "bin"),
            "Bundled lokey_lexicon.bin (copied from demo_lexicon.bin) must exist"
        )
        let lexicon = try MmapLexicon(contentsOf: lexURL)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokey_audit_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("user_lexicon.sqlite3")
        let store = UserLexiconStore(databaseURL: dbURL, broadcastChanges: false, asyncPersistence: false)
        let decoder = ViterbiDecoder(lexicon: lexicon, spatialModel: SpatialTouchModel(), userStore: store)
        let session = LokeySessionController(
            decoder: decoder,
            settings: settings,
            persistTouchCalibration: false,
            decodeCandidatesInBackground: false
        )
        return (lexicon, store, decoder, session, tempDir)
    }

    private func collectButtons(in view: UIView) -> [UIButton] {
        var result: [UIButton] = []
        if let btn = view as? UIButton, !btn.isHidden, let title = btn.currentTitle, !title.isEmpty {
            result.append(btn)
        }
        for sub in view.subviews {
            result.append(contentsOf: collectButtons(in: sub))
        }
        return result
    }

    // MARK: - 1. Zero-Network Physical Isolation (64-bit Mach-O & Manifests)

    func testZeroNetworkPhysicalIsolation_MachOAndManifests() throws {
        let appBundleURL = Bundle.main.bundleURL
        let extBundleURL = appBundleURL.appendingPathComponent("PlugIns/LokeyKeyboard.appex", isDirectory: true)
        let targets: [(name: String, bundleURL: URL, execName: String)] = [
            ("AuditDemoApp.app", appBundleURL, "AuditDemoApp"),
            ("LokeyKeyboard.appex", extBundleURL, "LokeyKeyboard"),
        ]

        let forbiddenDylibSubstrings = [
            "Network.framework",
            "CFNetwork.framework",
            "WebKit.framework",
            "SafariServices.framework",
            "NetworkExtension.framework",
            "SystemConfiguration.framework",
            "AdSupport.framework",
            "AppTrackingTransparency.framework",
            "MultipeerConnectivity.framework",
            "LinkPresentation.framework",
        ]
        let forbiddenImportedSymbols: Set<String> = [
            "_NSURLSession",
            "_OBJC_CLASS_$_NSURLSession",
            "_OBJC_CLASS_$_NSURLConnection",
            "_OBJC_CLASS_$_WKWebView",
            "_OBJC_CLASS_$_SFSafariViewController",
            "_NWConnection",
            "_nw_connection_create",
            "_CFSocketCreate",
            "_CFStreamCreatePairWithSocket",
            "_SCNetworkReachabilityCreateWithName",
            "_getaddrinfo",
            "_gethostbyname",
            "_socket",
            "_connect",
            "_sendto",
            "_recvfrom",
        ]

        func readU32LE(_ data: Data, _ offset: Int) -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else { return 0 }
            return data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
        }

        for target in targets {
            let plistURL = target.bundleURL.appendingPathComponent("Info.plist")
            let plistData = try Data(contentsOf: plistURL)
            let plist = try XCTUnwrap(
                try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
                "\(target.name) Info.plist must deserialize"
            )
            XCTAssertNil(plist["NSAppTransportSecurity"])
            XCTAssertNil(plist["UIBackgroundModes"])
            XCTAssertNil(plist["NSLocalNetworkUsageDescription"])
            XCTAssertNil(plist["NSBonjourServices"])
            XCTAssertEqual(plist["LokeyAppGroupID"] as? String, "group.com.kianuni.lokey")

            var machOUrls = [target.bundleURL.appendingPathComponent(target.execName)]
            let debugDylibURL = target.bundleURL.appendingPathComponent("\(target.execName).debug.dylib")
            if FileManager.default.fileExists(atPath: debugDylibURL.path) {
                machOUrls.append(debugDylibURL)
            }

            var totalParsedDylibs = 0
            for binURL in machOUrls {
                let binLabel = binURL.lastPathComponent
                let machO = try Data(contentsOf: binURL)
                XCTAssertGreaterThan(machO.count, 16_384, "\(binLabel) Mach-O must exist")
                XCTAssertEqual(readU32LE(machO, 0), 0xFEED_FACF, "\(binLabel) must be 64-bit Mach-O")

                let ncmds = Int(readU32LE(machO, 16))
                XCTAssertGreaterThan(ncmds, 5)

                var cmdOffset = 32
                var dylibPaths: [String] = []
                var symOff = 0
                var nSyms = 0
                var strOff = 0
                var strSize = 0

                for _ in 0..<ncmds {
                    guard cmdOffset + 8 <= machO.count else { break }
                    let cmd = readU32LE(machO, cmdOffset)
                    let cmdSize = Int(readU32LE(machO, cmdOffset + 4))
                    guard cmdSize >= 8, cmdOffset + cmdSize <= machO.count else { break }

                    if cmd == 0x0C || cmd == 0x8000_0018 || cmd == 0x8000_001F || cmd == 0x20 {
                        let nameOff = Int(readU32LE(machO, cmdOffset + 8))
                        if nameOff >= 8 && nameOff < cmdSize {
                            let strSlice = machO[(cmdOffset + nameOff)..<(cmdOffset + cmdSize)]
                            let nulIdx = strSlice.firstIndex(of: 0) ?? strSlice.endIndex
                            if let path = String(data: strSlice[strSlice.startIndex..<nulIdx], encoding: .utf8) {
                                dylibPaths.append(path)
                            }
                        }
                    } else if cmd == 0x02 && cmdSize >= 24 {
                        symOff = Int(readU32LE(machO, cmdOffset + 8))
                        nSyms = Int(readU32LE(machO, cmdOffset + 12))
                        strOff = Int(readU32LE(machO, cmdOffset + 16))
                        strSize = Int(readU32LE(machO, cmdOffset + 20))
                    }
                    cmdOffset += cmdSize
                }

                totalParsedDylibs += dylibPaths.count
                for dylib in dylibPaths {
                    for forbidden in forbiddenDylibSubstrings {
                        XCTAssertFalse(
                            dylib.localizedCaseInsensitiveContains(forbidden),
                            "\(binLabel) links forbidden network framework: \(dylib)"
                        )
                    }
                }

                XCTAssertGreaterThan(nSyms, 0)
                if symOff > 0, strOff > 0, symOff + nSyms * 16 <= machO.count, strOff + strSize <= machO.count {
                    machO.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        for i in 0..<nSyms {
                            let entryOff = symOff + i * 16
                            let nType = raw.load(fromByteOffset: entryOff + 4, as: UInt8.self)
                            guard (nType & 0x0E) == 0x00, (nType & 0x01) != 0 else { continue }
                            let strx = Int(raw.loadUnaligned(fromByteOffset: entryOff, as: UInt32.self).littleEndian)
                            guard strx > 0 && strx < strSize else { continue }
                            let cPtr = base.advanced(by: strOff + strx).assumingMemoryBound(to: CChar.self)
                            let symName = String(cString: cPtr)
                            XCTAssertFalse(
                                forbiddenImportedSymbols.contains(symName),
                                "\(binLabel) imports forbidden network symbol: \(symName)"
                            )
                        }
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(totalParsedDylibs, 3)

            let mainExecData = try Data(contentsOf: target.bundleURL.appendingPathComponent(target.execName))
            XCTAssertNotNil(mainExecData.range(of: Data("com.apple.security.application-groups".utf8)))
            XCTAssertNotNil(mainExecData.range(of: Data("group.com.kianuni.lokey".utf8)))
            for forbiddenEnt in ["aps-environment", "com.apple.developer.networking", "com.apple.developer.ubiquity"] {
                XCTAssertNil(mainExecData.range(of: Data(forbiddenEnt.utf8)))
            }
        }
    }

    // MARK: - 2. PrivacyInfo.xcprivacy, Bundle IDs, Versions & App Group Compliance

    func testPrivacyManifestsBundleIDsAndVersions() throws {
        let hostBundle = Bundle.main
        XCTAssertEqual(hostBundle.bundleIdentifier, "com.kianuni.lokey.audit")
        XCTAssertEqual(hostBundle.object(forInfoDictionaryKey: "LokeyAppGroupID") as? String, "group.com.kianuni.lokey")
        XCTAssertEqual(hostBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.0")
        XCTAssertEqual(hostBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "102")
        XCTAssertEqual(hostBundle.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool, false)
        XCTAssertEqual(hostBundle.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool, false)
        XCTAssertNil(hostBundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes"))
        XCTAssertNil(hostBundle.object(forInfoDictionaryKey: "UTExportedTypeDeclarations"))

        let extURL = try XCTUnwrap(hostBundle.builtInPlugInsURL?.appendingPathComponent("LokeyKeyboard.appex", isDirectory: true))
        let extBundle = try XCTUnwrap(Bundle(url: extURL))
        XCTAssertEqual(extBundle.bundleIdentifier, "com.kianuni.lokey.audit.keyboard")
        XCTAssertEqual(extBundle.object(forInfoDictionaryKey: "LokeyAppGroupID") as? String, "group.com.kianuni.lokey")
        XCTAssertEqual(extBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "1.0")
        XCTAssertEqual(extBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "102")

        XCTAssertEqual(Bundle(for: LokeyAuditTests.self).bundleIdentifier, "com.kianuni.lokey.audit.tests")

        for (bundle, requiresActiveKeyboards) in [(hostBundle, true), (extBundle, false)] {
            let privacyURL = try XCTUnwrap(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
            let data = try Data(contentsOf: privacyURL)
            let plist = try XCTUnwrap(
                try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            )
            XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
            XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty, true)
            XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty, true)

            let apiTypes = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
            var reasonsByType: [String: [String]] = [:]
            for item in apiTypes {
                if let type = item["NSPrivacyAccessedAPIType"] as? String,
                   let reasons = item["NSPrivacyAccessedAPITypeReasons"] as? [String] {
                    reasonsByType[type] = reasons
                }
            }
            XCTAssertEqual(Set(reasonsByType["NSPrivacyAccessedAPICategoryUserDefaults"] ?? []), Set(["CA92.1", "1C8F.1"]))
            XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
            XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
            if requiresActiveKeyboards {
                XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryActiveKeyboards"], ["3EC4.1"])
            }
        }
    }

    // MARK: - 3. Demo Lexicon Mmap Load, Validation, LNLM Safety & OpenCC/Emoji

    func testDemoLexiconMmapLoadBoundsAndLNLMSafety() throws {
        let hostBundle = Bundle.main
        let extBundle = try XCTUnwrap(Bundle(url: XCTUnwrap(hostBundle.builtInPlugInsURL?.appendingPathComponent("LokeyKeyboard.appex", isDirectory: true))))
        let testBundle = Bundle(for: LokeyAuditTests.self)

        XCTAssertNotNil(extBundle.url(forResource: "lokey_lexicon", withExtension: "bin"), "LokeyKeyboard.appex must bundle lokey_lexicon.bin")
        XCTAssertNotNil(extBundle.url(forResource: "lokey_emoji", withExtension: "bin"), "LokeyKeyboard.appex must bundle lokey_emoji.bin")
        XCTAssertNotNil(extBundle.url(forResource: "lokey_opencc", withExtension: "bin"), "LokeyKeyboard.appex must bundle lokey_opencc.bin")
        XCTAssertNotNil(extBundle.url(forResource: "lokey_hanzi_meta", withExtension: "bin"), "LokeyKeyboard.appex must bundle lokey_hanzi_meta.bin")
        XCTAssertNil(extBundle.url(forResource: "lokey_spelling", withExtension: "bin"), "Lokey-Audit omits lokey_spelling.bin")

        let lexURL = try XCTUnwrap(testBundle.url(forResource: "lokey_lexicon", withExtension: "bin"))
        let nsData = try NSData(contentsOf: lexURL, options: [.mappedIfSafe])
        let summary = try LokeyLexiconPackManager.validatePack(nsData: nsData, computeHash: true, validateRecords: true)
        XCTAssertEqual(summary.syllableCount, 416)
        XCTAssertGreaterThanOrEqual(summary.wordCount, 3000)

        let rawLex = UnsafeRawBufferPointer(start: nsData.bytes, count: nsData.length)
        let lnlmMeta = try NeuralSentenceScorer.validateLNLMv2(in: rawLex, minimumOffset: 72)
        XCTAssertGreaterThan(lnlmMeta.charCount, 0)
        XCTAssertEqual(lnlmMeta.wordCount, 0)

        let lexicon = try MmapLexicon(contentsOf: lexURL)
        XCTAssertEqual(lexicon.totalSyllables, 416)
        XCTAssertGreaterThanOrEqual(lexicon.totalWordRecords, 3000)
        XCTAssertGreaterThan(lexicon.totalEmojiRecords, 0)
        XCTAssertTrue(lexicon.neuralLM.isLoaded)
        XCTAssertEqual(lexicon.neuralLM.version, 2)

        // Truncated / bad-magic rejection
        XCTAssertThrowsError(try MmapLexicon(data: Data([0x01, 0x02])))
        var badMagicData = Data(count: 128)
        badMagicData[0] = 0x42
        XCTAssertThrowsError(try MmapLexicon(data: badMagicData))

        // Corrupt / NaN / Inf / huge MLP weight rejection without SIGTRAP
        let mutable = Data(referencing: nsData)
        let lnlmOff = Int(mutable.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: mutable.count - 8, as: UInt32.self))
        })
        let mlpOff = Int(mutable.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: lnlmOff + 28, as: UInt32.self))
        })
        let badPatterns: [UInt32] = [0x7FC0_0000, 0x7F80_0000, 0xFF80_0000, 0x7000_0000, 0xF000_0000]
        for pattern in badPatterns {
            var corrupted = mutable
            for wIdx in 0..<6336 {
                var le = pattern.littleEndian
                withUnsafeBytes(of: &le) { corrupted.replaceSubrange((mlpOff + wIdx * 4)..<(mlpOff + (wIdx + 1) * 4), with: $0) }
            }
            XCTAssertThrowsError(
                try LokeyLexiconPackManager.validatePack(nsData: corrupted as NSData, computeHash: false, validateRecords: true),
                "validatePack must reject non-finite or overflowing MLP weights"
            )
            // Verify MmapLexicon + NeuralSentenceScorer clamps extreme/NaN inputs safely without SIGTRAP
            let badLex = try MmapLexicon(nsData: corrupted as NSData)
            let pred = badLex.neuralLM.prepareStepPredictor(lastWord: "我们", hidden: badLex.neuralLM.hBos)
            let rec = badLex.neuralLM.wordRecord(for: "你好")
            let directScore = badLex.neuralLM.scorePreloadedCandidate(
                predictor: pred,
                record: rec,
                singleCharRun: 0,
                isEndOfSentence: true
            )
            XCTAssertGreaterThanOrEqual(directScore, NeuralSentenceScorer.minBonusQ8)
            XCTAssertLessThanOrEqual(directScore, NeuralSentenceScorer.maxBonusQ8)
        }

        // OpenCC checks
        XCTAssertEqual(OpenCCConverter.shared.convert("软件和鼠标", mode: .traditionalTW), "軟體和滑鼠")
        XCTAssertEqual(OpenCCConverter.shared.convert("头发发财 皇后在后面", mode: .traditionalTW), "頭髮發財 皇后在後面")
        XCTAssertEqual(OpenCCConverter.shared.convert("软件和鼠标", mode: .traditionalHK), "軟件和鼠標")
    }

    // MARK: - 4. 26-Key Full-Pinyin Decoding

    func test26KeyFullPinyinDecoding() throws {
        let env = try makeIsolatedSession()
        defer {
            env.store.close()
            try? FileManager.default.removeItem(at: env.tempDir)
        }

        let decoder = env.decoder
        XCTAssertEqual(decoder.decode("nihao").candidates.first?.text, "你好")
        XCTAssertEqual(decoder.decode("zhongguo").candidates.first?.text, "中国")
        XCTAssertEqual(decoder.decode("beijing").candidates.first?.text, "北京")
        XCTAssertEqual(decoder.decode("pinyin").candidates.first?.text, "拼音")
        XCTAssertEqual(decoder.decode("wo").candidates.first?.text, "我")

        let sentenceCands = decoder.decode("womenmingtianjian").candidates.map(\.text)
        XCTAssertTrue(
            sentenceCands.contains(where: { $0.contains("我们") && $0.contains("明天") }),
            "Expected multi-syllable decode containing 我们明天, got \(sentenceCands)"
        )

        let xianCands = decoder.decode("xi'an").candidates.map(\.text)
        XCTAssertTrue(xianCands.contains("西安"), "Expected 西安 for xi'an, got \(xianCands)")

        let zgCands = decoder.decode("zg").candidates.map(\.text)
        XCTAssertTrue(zgCands.contains("中国"), "Expected jianpin 中国 for zg, got \(zgCands)")

        let luyouCands = decoder.decode("luyou").candidates.map(\.text)
        XCTAssertTrue(luyouCands.contains("旅游"), "Expected u/ü equivalence 旅游 for luyou, got \(luyouCands)")

        let iphoneCands = decoder.decode("iphone").candidates.map(\.text)
        XCTAssertTrue(iphoneCands.contains("iPhone"), "Expected English candidate iPhone, got \(iphoneCands)")

        let hahaCands = decoder.decode("haha").candidates.map(\.text)
        XCTAssertTrue(hahaCands.contains("😂"), "Expected inline emoji 😂 for haha, got \(hahaCands)")

        // Session candidate selection & commit
        for ch in "zhongguo" {
            env.session.handleLetterTap(char: ch)
        }
        let commit = env.session.selectCandidate(at: 0)
        if case let .commitText(text, _) = commit {
            XCTAssertEqual(text, "中国")
        } else {
            XCTFail("Expected .commitText on selecting candidate 0")
        }
    }

    // MARK: - 5. hasFullAccess == false Offline Behavior

    func testHasFullAccessFalseOfflineBehavior() throws {
        let offlineSettings = LokeySettings(
            hapticStrength: .light,
            isKeyClickSoundEnabled: true,
            enableSpatialCorrection: true,
            enableEmojiCandidates: true
        )
        let env = try makeIsolatedSession(settings: offlineSettings)
        defer {
            env.store.close()
            try? FileManager.default.removeItem(at: env.tempDir)
        }

        for ch in "nihao" {
            env.session.handleLetterTap(char: ch)
        }
        let res = env.session.handleSpace()
        if case let .commitText(committed, _) = res {
            XCTAssertEqual(committed, "你好")
        } else {
            XCTFail("Expected offline space commit for nihao")
        }

        // Verify KeyboardViewController & KeyGridView offline behavior with hasFullAccess == false
        let vc = KeyboardViewController()
        let proxy = AuditMockTextDocumentProxy()
        vc.customTextDocumentProxyForTesting = proxy
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 402.0, height: KeyboardTheme.standardPortraitKeyboardHeight)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()

        XCTAssertFalse(vc.hasFullAccess, "Host test runner must run with hasFullAccess == false")
        let grid = try XCTUnwrap(vc.view.subviews.compactMap { $0 as? KeyGridView }.first)
        XCTAssertFalse(grid.hasFullAccess)
        grid.hasFullAccessProvider = { false }
        grid.isKeyClickSoundEnabled = true
        // Exercises the UIDevice.current.playInputClick() offline branch cleanly
        grid.playKeySound(type: .standard)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - 6. Raw-Key Preedit Invariant

    func testRawKeyPreeditInvariant() throws {
        let env = try makeIsolatedSession()
        defer {
            env.store.close()
            try? FileManager.default.removeItem(at: env.tempDir)
        }

        let inputs = [
            "beijing",
            "xi'an",
            "zhrgr",
            "Wojintian",
            "womenmingtianjian",
            "123abcXYZ",
        ]

        for raw in inputs {
            let decRes = env.decoder.decode(raw)
            XCTAssertEqual(
                decRes.preeditDisplay.replacingOccurrences(of: "'", with: ""),
                raw.replacingOccurrences(of: "'", with: ""),
                "ViterbiDecoder violated Raw-Key Preedit Invariant for '\(raw)'"
            )

            env.session.resetComposing()
            for ch in raw {
                env.session.handleLetterTap(char: ch, isShifted: ch.isUppercase)
            }
            XCTAssertEqual(
                env.session.currentDecode.preeditDisplay.replacingOccurrences(of: "'", with: ""),
                raw.replacingOccurrences(of: "'", with: ""),
                "LokeySessionController violated Raw-Key Preedit Invariant for '\(raw)'"
            )
        }
    }

    // MARK: - 7. KeyboardViewController Lifecycle & Input Flow

    func testKeyboardViewControllerLifecycleAndInputFlow() throws {
        let vc = KeyboardViewController()
        let proxy = AuditMockTextDocumentProxy()
        vc.customTextDocumentProxyForTesting = proxy

        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 402.0, height: KeyboardTheme.standardPortraitKeyboardHeight)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()

        let grid = try XCTUnwrap(vc.view.subviews.compactMap { $0 as? KeyGridView }.first)
        let bar = try XCTUnwrap(vc.view.subviews.compactMap { $0 as? CandidateBarView }.first)
        _ = try XCTUnwrap(vc.view.subviews.compactMap { $0 as? ExpandedCandidateGridView }.first)
        _ = try XCTUnwrap(vc.view.subviews.compactMap { $0 as? KeyCalloutBubbleView }.first)

        vc.beginAppearanceTransition(true, animated: false)
        vc.endAppearanceTransition()
        vc.textDidChange(nil)

        let spatial = SpatialTouchModel()
        for ch in "nihao" {
            let pt = spatial.center(for: ch) ?? CGPoint(x: 0.5, y: 0.5)
            grid.onLetterTap?(ch, pt, false, 0)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        vc.finishCandidateDecoding()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))

        XCTAssertTrue(grid.isComposing)
        XCTAssertFalse(proxy.setMarkedTextCalls.isEmpty, "Composing must drive setMarkedText")

        let candButtons = collectButtons(in: bar).filter { $0.tag >= 0 }.sorted { $0.tag < $1.tag }
        XCTAssertFalse(candButtons.isEmpty, "CandidateBarView must display decoded candidates")
        XCTAssertEqual(candButtons.first?.currentTitle, "你好")

        // Commit top candidate via spacebar
        grid.onSpaceTap?()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertTrue((proxy.documentContextBeforeInput ?? "").contains("你好"))

        // Type another char, backspace, and return
        let ptB = spatial.center(for: "w") ?? CGPoint(x: 0.5, y: 0.5)
        grid.onLetterTap?("w", ptB, false, 0)
        grid.onLetterTap?("o", spatial.center(for: "o") ?? CGPoint(x: 0.5, y: 0.5), false, 0)
        vc.finishCandidateDecoding()
        grid.onBackspaceTap?()
        vc.finishCandidateDecoding()
        grid.onReturnTap?()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertTrue((proxy.documentContextBeforeInput ?? "").contains("w"))

        proxy.documentIdentifier = UUID()
        proxy.documentContextBeforeInput = ""
        vc.textDidChange(nil)
        XCTAssertEqual(vc.activeSessionForTesting?.topicMemoryVector, .zero)

        NotificationCenter.default.post(name: NSNotification.Name.NSExtensionHostDidEnterBackground, object: nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertEqual(vc.activeSessionForTesting?.topicMemoryVector, .zero)

        vc.didReceiveMemoryWarning()
        vc.beginAppearanceTransition(false, animated: false)
        vc.endAppearanceTransition()
        XCTAssertEqual(vc.activeSessionForTesting?.topicMemoryVector, .zero)
    }

    func testRawBufferNegativeOffsetBoundsAndCandidateUIMemoryHygiene() throws {
        let sampleBytes: [UInt8] = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0]
        sampleBytes.withUnsafeBytes { raw in
            for badOffset in [-1, -2, -4, -8, Int.min, Int.max, raw.count] {
                XCTAssertEqual(MmapLexicon.loadU16(raw, at: badOffset), 0)
                XCTAssertEqual(MmapLexicon.loadI16(raw, at: badOffset), 0)
                XCTAssertEqual(MmapLexicon.loadU32(raw, at: badOffset), 0)
                XCTAssertEqual(MmapLexicon.loadU64BE(raw, at: badOffset), 0)
                XCTAssertEqual(LokeyLexiconPackManager.readU16(raw, at: badOffset), 0)
                XCTAssertEqual(LokeyLexiconPackManager.readU32(raw, at: badOffset), 0)
                XCTAssertEqual(NeuralSentenceScorer.loadU16(raw, at: badOffset), 0)
                XCTAssertEqual(NeuralSentenceScorer.loadU32(raw, at: badOffset), 0)
                XCTAssertEqual(OpenCCConverter.loadU16(raw, at: badOffset), 0)
                XCTAssertEqual(OpenCCConverter.loadU32(raw, at: badOffset), 0)
            }
            XCTAssertEqual(MmapLexicon.loadU16(raw, at: 8), 0xA090)
            XCTAssertEqual(MmapLexicon.loadU16(raw, at: 9), 0)
            XCTAssertEqual(OpenCCConverter.loadU32(raw, at: 6), 0xA0908070)
            XCTAssertEqual(OpenCCConverter.loadU32(raw, at: 7), 0)
            XCTAssertEqual(NeuralSentenceScorer.loadU32(raw, at: 6), 0xA0908070)
            XCTAssertEqual(NeuralSentenceScorer.loadU32(raw, at: 7), 0)
            sampleBytes.withUnsafeBufferPointer { rhs in
                XCTAssertEqual(NeuralSentenceScorer.compareArbitraryPoolBytes(raw, poolOffset: -1, poolSize: 4, offset: 0, length: 2, against: rhs), -1)
                XCTAssertEqual(NeuralSentenceScorer.compareArbitraryPoolBytes(raw, poolOffset: 8, poolSize: 4, offset: 0, length: 2, against: rhs), -1)
                XCTAssertEqual(NeuralSentenceScorer.compareArbitraryPoolBytes(raw, poolOffset: 0, poolSize: 10, offset: 0, length: 10, against: rhs), 0)
            }
        }
        XCTAssertEqual(
            LokeyLexiconPackManager.sanitizedPackFileName(from: "lokeypack-preview-12345678-1234-1234-1234-123456789abc-rime-frost.lokeypack"),
            "rime-frost.lokeypack"
        )
        XCTAssertEqual(
            LokeyLexiconPackManager.displayPackName(fromFileName: "lokeypack-preview-12345678-1234-1234-1234-123456789abc-rime-frost.lokeypack"),
            "rime-frost"
        )

        let env = try makeIsolatedSession()
        defer {
            env.store.close()
            try? FileManager.default.removeItem(at: env.tempDir)
        }
        _ = env.store.importCustomPhrases(
            [UserLexiconStore.ImportedPhraseSeed(surface: "怎噶", syllables: ["zen", "ga"], useCount: 5)],
            conflictPolicy: .mergeHigherWeight
        )
        var corrSettings = LokeySettings()
        corrSettings.enableSpatialCorrection = true
        XCTAssertTrue(env.decoder.decode("zwnga", settings: corrSettings).candidates.prefix(5).contains(where: { $0.text == "怎噶" }))

        // Verify `CandidateBarView.trimUnusedPoolIfIdle()` shrinks expanded pool while idle candidates remain visible
        let bar = CandidateBarView(frame: CGRect(x: 0, y: 0, width: 1200, height: 44))
        let wideCands = (0..<36).map { idx in
            LokeyCandidate(text: "字\(idx)", consumedInputCount: 2, matchedSyllables: ["zi"], scoreQ8: -100 - idx, kind: .lexiconPhrase)
        }
        bar.update(candidates: wideCands, highlightFirst: true, expanded: false)
        let expandedPoolCount = bar.poolCapacityForTesting
        XCTAssertGreaterThan(expandedPoolCount, 20)

        bar.frame = CGRect(x: 0, y: 0, width: 393, height: 44)
        let idleCands = ["的", "了", "我", "是", "在", "不", "有", "你", "好", "也", "就", "都", "要", "会"].map {
            LokeyCandidate(text: $0, consumedInputCount: 0, matchedSyllables: [], scoreQ8: 0, kind: .lexiconPhrase)
        }
        bar.update(candidates: idleCands, highlightFirst: false, expanded: false)
        bar.trimUnusedPoolIfIdle()
        XCTAssertLessThan(bar.poolCapacityForTesting, expandedPoolCount)
        XCTAssertLessThanOrEqual(bar.poolCapacityForTesting, 14)
        XCTAssertEqual(bar.candidateButton(at: 0).currentTitle, "的")

        bar.update(candidates: [], highlightFirst: false, expanded: false)
        bar.trimUnusedPoolIfIdle()
        XCTAssertEqual(bar.poolCapacityForTesting, 12)

        // Verify `ExpandedCandidateGridView` deallocates cleanly while `CADisplayLink` is scheduled
        let prevDiagEnabled = LokeyDiagnosticLogger.shared.isEnabled
        let prevSecure = LokeyDiagnosticLogger.shared.isSecureContext
        LokeyDiagnosticLogger.shared.isEnabled = true
        LokeyDiagnosticLogger.shared.isSecureContext = false
        defer {
            LokeyDiagnosticLogger.shared.isEnabled = prevDiagEnabled
            LokeyDiagnosticLogger.shared.isSecureContext = prevSecure
        }

        weak var weakGrid: ExpandedCandidateGridView?
        autoreleasepool {
            let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 300))
            let grid = ExpandedCandidateGridView(frame: CGRect(x: 0, y: 0, width: 393, height: 224))
            weakGrid = grid
            win.addSubview(grid)
            win.isHidden = false
            grid.isHidden = false
            grid.beginOpenTrace(start: CACurrentMediaTime())
            grid.layoutSubviews()
        }
        XCTAssertNil(weakGrid)
    }

    func testExternalPackDeletePreservesCoexistingPackAndRejectsPathTraversal() throws {
        let fm = FileManager.default
        let rootDir = fm.temporaryDirectory.appendingPathComponent("lokey_audit_pack_del_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: rootDir) }

        let lexiconsDir = rootDir.appendingPathComponent("Lexicons", isDirectory: true)
        try fm.createDirectory(at: lexiconsDir, withIntermediateDirectories: true)
        let suiteName = "com.kianuni.lokey.audit.packdel.\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let demoLexURL = try XCTUnwrap(Bundle(for: LokeyAuditTests.self).url(forResource: "lokey_lexicon", withExtension: "bin"))
        let packData = try Data(contentsOf: demoLexURL)
        let srcURL = rootDir.appendingPathComponent("rime-frost.lokeypack")
        try packData.write(to: srcURL)

        let activeMeta = try LokeyLexiconPackManager.installPack(
            from: srcURL,
            preferredFileName: "rime-frost.lokeypack",
            packName: "rime-frost",
            activate: true,
            in: lexiconsDir,
            defaults: testDefaults
        )

        let legacyFileName = "lokeypack-preview-12345678-1234-1234-1234-123456789abc-rime-frost.lokeypack"
        let legacyPackURL = lexiconsDir.appendingPathComponent(legacyFileName)
        let legacyMetaURL = lexiconsDir.appendingPathComponent(legacyFileName + ".json")
        try packData.write(to: legacyPackURL)
        let legacyMeta = LokeyLexiconPackMetadata(
            packId: "\(legacyFileName)#legacy",
            packName: "rime-frost-legacy",
            fileName: legacyFileName,
            wordCount: activeMeta.wordCount,
            syllableCount: activeMeta.syllableCount,
            englishCount: activeMeta.englishCount,
            associationCount: activeMeta.associationCount,
            fileSizeBytes: activeMeta.fileSizeBytes,
            source: "外部导入 (.lokeypack)",
            sha256: activeMeta.sha256,
            installedAt: activeMeta.installedAt - 20
        )
        try JSONEncoder().encode(legacyMeta).write(to: legacyMetaURL)

        XCTAssertEqual(LokeyLexiconPackManager.listInstalledPacks(in: lexiconsDir).count, 2)
        try LokeyLexiconPackManager.deletePack(fileName: legacyFileName, in: lexiconsDir, defaults: testDefaults)
        XCTAssertFalse(fm.fileExists(atPath: legacyPackURL.path))
        XCTAssertFalse(fm.fileExists(atPath: legacyMetaURL.path))
        XCTAssertTrue(fm.fileExists(atPath: lexiconsDir.appendingPathComponent("rime-frost.lokeypack").path))
        XCTAssertEqual(LokeyLexiconPackManager.activePackMetadata(in: lexiconsDir, defaults: testDefaults)?.fileName, "rime-frost.lokeypack")

        for bad in ["", ".", "..", "../rime-frost.lokeypack", "sub/pack.lokeypack", "active_pack.json"] {
            XCTAssertThrowsError(try LokeyLexiconPackManager.deletePack(fileName: bad, in: lexiconsDir, defaults: testDefaults))
            XCTAssertThrowsError(try LokeyLexiconPackManager.activatePack(fileName: bad, in: lexiconsDir, defaults: testDefaults))
        }

        try LokeyLexiconPackManager.deletePack(fileName: "rime-frost.lokeypack", in: lexiconsDir, defaults: testDefaults)
        XCTAssertTrue(LokeyLexiconPackManager.listInstalledPacks(in: lexiconsDir).isEmpty)
        XCTAssertNil(LokeyLexiconPackManager.activePackMetadata(in: lexiconsDir, defaults: testDefaults))
    }

    func testHanziFilterShortcutsOneHandedAndShuangpinParity() throws {
        let meta = try XCTUnwrap(HanziMetadataTable.shared, "LokeyKeyboard/Tests must bundle lokey_hanzi_meta.bin")
        XCTAssertEqual(meta.lookup("祎")?.radicalLabel, "礻")
        XCTAssertEqual(meta.lookup("熠")?.radicalLabel, "火")
        XCTAssertEqual(HanziMetadataTable.displayRadicalLabel("讠", scriptMode: .traditionalTW), "言")
        XCTAssertEqual(HanziMetadataTable.displayRadicalLabel("钅", scriptMode: .traditionalHK), "金")

        let emojiURL = try XCTUnwrap(Bundle(for: LokeyAuditTests.self).url(forResource: "lokey_emoji", withExtension: "bin"))
        let emojiData = try Data(contentsOf: emojiURL)
        XCTAssertLessThanOrEqual(emojiData.count, 16_384, "Lokey-Audit must bundle minimal permissive demo lokey_emoji.bin")

        let env = try makeIsolatedSession()
        defer {
            env.store.close()
            try? FileManager.default.removeItem(at: env.tempDir)
        }

        XCTAssertTrue(env.store.upsertShortcut(code: "yx", phrase: "audit@lokey.local", rank: 1))
        for ch in "yx" { _ = env.session.handleLetterTap(char: ch) }
        XCTAssertEqual(env.session.currentDecode.candidates.first?.text, "audit@lokey.local")
        env.session.resetComposing()

        let rimeWeightsSample = "\u{FEFF}#@/db_type\tstabledb\r\n次选\tdz\t20\r\n首选\tdz\t80\r\n异常\tdz\tnan\r\n"
        XCTAssertEqual(env.store.importCustomPhraseText(rimeWeightsSample, replaceExisting: false), 3)
        XCTAssertTrue(env.store.allShortcuts().filter({ $0.code == "stabledb" }).isEmpty)
        let dzShortcuts = env.store.allShortcuts().filter { $0.code == "dz" }
        XCTAssertEqual(Array(dzShortcuts.prefix(2).map(\.phrase)), ["首选", "次选"])
        XCTAssertEqual(Array(dzShortcuts.prefix(2).map(\.rank)), [1, 2])

        env.store.recordCommit(surface: "发财", syllables: ["fa", "cai"], isCustomComposed: true)
        var twSettings = LokeySettings()
        twSettings.chineseScriptMode = .traditionalTW
        env.session.settings = twSettings
        for ch in "facai" { _ = env.session.handleLetterTap(char: ch) }
        let twCand = try XCTUnwrap(env.session.currentDecode.candidates.first(where: { $0.text == "發財" }))
        XCTAssertTrue(env.session.deleteExplicitUserCandidate(twCand, canonical: nil))
        XCTAssertFalse(env.session.deleteExplicitUserCandidate(twCand, canonical: nil))
        env.session.resetComposing()

        var spSettings = LokeySettings()
        spSettings.pinyinScheme = .xiaohe
        spSettings.chineseScriptMode = .traditionalTW
        spSettings.enableDateTimeShortcuts = true
        env.session.settings = spSettings
        for ch in "xq" { _ = env.session.handleLetterTap(char: ch) }
        let xqCands = env.session.currentDecode.candidates.map(\.text)
        XCTAssertGreaterThanOrEqual(xqCands.count, 5)
        XCTAssertTrue(xqCands[3].hasPrefix("星期"))
        XCTAssertTrue(xqCands[4].hasPrefix("週"))
        env.session.resetComposing()

        env.session.settings = LokeySettings()
        for ch in "yi" { _ = env.session.handleLetterTap(char: ch) }
        let catalog = try XCTUnwrap(env.session.buildExpandedFilterCatalog(metaTable: meta))
        XCTAssertFalse(catalog.pinyinOptions.isEmpty)

        let grid = KeyGridView(frame: CGRect(x: 0, y: 0, width: 393.0, height: 206.0))
        grid.pinyinScheme = .xiaohe
        grid.showShuangpinKeyHints = true
        grid.oneHandedMode = .left
        grid.layoutIfNeeded()
        XCTAssertEqual(grid.debugSubHintText(for: .letter("q")), "iu")
        XCTAssertEqual(grid.oneHandedRestoreButtonForTesting?.isHidden, false)
    }
}
