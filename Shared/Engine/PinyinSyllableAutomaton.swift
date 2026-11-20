import Foundation

/// Expands Pinyin syllable strings across user-configured fuzzy Pinyin pairs and common fast-typing transpositions.
public struct PinyinSyllableAutomaton: Sendable {
    public struct ExpandedSyllable: Sendable, Equatable {
        public let syllableID: UInt16
        public let canonical: String
        public let penaltyQ8: Int
        public let isSoftClipped: Bool

        public init(syllableID: UInt16, canonical: String, penaltyQ8: Int, isSoftClipped: Bool = false) {
            self.syllableID = syllableID
            self.canonical = canonical
            self.penaltyQ8 = penaltyQ8
            self.isSoftClipped = isSoftClipped
        }
    }

    /// Native iOS 26 26-key keyboard orthographic `u`/`ü` (`v`) equivalences (applied unconditionally).
    /// Because 26-key Pinyin has no dedicated `ü` key, users type `nu`/`lu`/`nue`/`lue` for `女`/`旅`/`虐`/`略`;
    /// a tiny 35 Q8 tie-break preserves exact `nuli -> 努力`, `malu -> 马路`, `jilu -> 记录` while ranking
    /// `nuhai -> 女孩`, `nusheng -> 女生`, `nuer -> 女儿`, `luyou -> 旅游`, `kaolu -> 考虑`, `xiaolu -> 效率` #1.
    private static let orthographicAliases: [String: (String, Int)] = [
        "lve": ("lue", 0),
        "nve": ("nue", 0),
        "lue": ("lve", 0),
        "nue": ("nve", 0),
        "nu": ("nv", 35),
        "lu": ("lv", 35),
        "nv": ("nu", 360),
        "lv": ("lu", 360),
    ]

    /// O(1) exact whole-syllable fast-typing shorthand aliases (dropped nuclear vowel `e`/`o`).
    private static let exactAliasMap: [String: (String, Int)] = [
        "yo": ("you", 220),
        "mn": ("men", 240),
        "rn": ("ren", 260),
        "zn": ("zen", 260),
        "shn": ("shen", 250),
        "zhn": ("zhen", 250),
        "chn": ("chen", 250),
        "hn": ("hen", 250),
        "wn": ("wen", 250),
        "gn": ("gen", 250),
        "fn": ("fen", 250),
        "bn": ("ben", 250),
        "kn": ("ken", 260),
    ]

    /// Suffix-only phonetic/rollover aliases (pure Swift `hasSuffix`, zero Objective-C bridging).
    private static let suffixFixes: [(String, String, Int)] = [
        ("mg", "ng", 220),
        ("iou", "iu", 60),
        ("uei", "ui", 60),
        ("uen", "un", 60),
    ]

    private static let softPhoneticPairs: FuzzyPinyinOptions = [
        .z_zh, .c_ch, .s_sh, .an_ang, .en_eng, .in_ing
    ]

    /// Conservative medial/vowel drop rescue on valid 3-letter `-an`/`-in` syllables (`mingtan -> 明天`, `xinzai -> 现在`).
    private static let medialDropMap: [String: String] = [
        "tan": "tian", "dan": "dian", "nan": "nian", "lan": "lian",
        "ban": "bian", "pan": "pian", "man": "mian",
        "xin": "xian", "jin": "jian", "qin": "qian",
        "lin": "lian", "min": "mian", "pin": "pian", "bin": "bian",
    ]

    /// Resolves a candidate ASCII letter string (length 1...7) to matching syllable IDs in `lexicon`.
    public static func matchSyllables(
        raw: String,
        in lexicon: MmapLexicon,
        fuzzy: FuzzyPinyinOptions,
        allowTransposition: Bool = true,
        allowClipped: Bool = true,
        allowSoftPhonetic: Bool = false,
        allowSoftClipped: Bool = false,
        allowClippedWithTypo: Bool = false,
        wholeInputClean: Bool = false
    ) -> [ExpandedSyllable] {
        // Zero-allocation fast path for spatial neighbor hypotheses (`typos > 0`), where transposition
        // and soft-phonetic expansion are disabled (~95% of beam probes are incomplete prefixes returning `[]`).
        if !allowTransposition && !allowSoftPhonetic && !allowSoftClipped && fuzzy.isEmpty {
            let exactSID = lexicon.syllableToID[raw]
            let aliasPair = orthographicAliases[raw]
            if !allowClippedWithTypo || exactSID != nil || raw.count < 2 {
                if exactSID == nil && aliasPair == nil {
                    return []
                }
                var fast: [ExpandedSyllable] = []
                fast.reserveCapacity(2)
                if let sid = exactSID {
                    fast.append(ExpandedSyllable(syllableID: sid, canonical: raw, penaltyQ8: 0))
                }
                if let (alias, pen) = aliasPair, let aSID = lexicon.syllableToID[alias], aSID != exactSID {
                    fast.append(ExpandedSyllable(syllableID: aSID, canonical: alias, penaltyQ8: pen))
                }
                return fast
            } else {
                let clipAlias = exactAliasMap[raw]
                let clipSIDs = lexicon.clippedToSyllableIDs[raw]
                if aliasPair == nil && clipAlias == nil && clipSIDs == nil {
                    return []
                }
            }
        }

        var results: [ExpandedSyllable] = []
        results.reserveCapacity(4)

        @inline(__always)
        func insertSID(_ sid: UInt16, canonical s: String, penalty: Int, isSoftClipped: Bool = false) {
            if let idx = results.firstIndex(where: { $0.syllableID == sid }) {
                if results[idx].penaltyQ8 <= penalty {
                    return
                }
                results[idx] = ExpandedSyllable(syllableID: sid, canonical: s, penaltyQ8: penalty, isSoftClipped: isSoftClipped)
                return
            }
            results.append(ExpandedSyllable(syllableID: sid, canonical: s, penaltyQ8: penalty, isSoftClipped: isSoftClipped))
        }

        @inline(__always)
        func insert(_ s: String, penalty: Int, isSoftClipped: Bool = false) {
            guard let sid = lexicon.syllableToID[s] else { return }
            insertSID(sid, canonical: s, penalty: penalty, isSoftClipped: isSoftClipped)
        }

        // 1. Exact syllable & native 26-key orthographic aliases (`lue <-> lve`, `nue <-> nve`, `nu -> nv`, `lu -> lv`)
        insert(raw, penalty: 0)
        if let (alias, pen) = orthographicAliases[raw] {
            insert(alias, penalty: pen)
        }

        // 2. Generalized two-thumb adjacent transposition & clipped-rime recovery
        if allowTransposition && raw.count >= 2 {
            if allowClipped, let (mapped, pen) = exactAliasMap[raw] {
                insert(mapped, penalty: pen)
            }
            for (badSuf, goodSuf, pen) in suffixFixes where raw.hasSuffix(badSuf) {
                let fixed = String(raw.dropLast(badSuf.count)) + goodSuf
                insert(fixed, penalty: pen)
            }

            let isExactSingleSyl = lexicon.syllableToID[raw] != nil || raw == "lue" || raw == "nue"
            let isCleanMultiSyl = !isExactSingleSyl && lexicon.canSegmentCleanly(raw)

            // Generalized adjacent swap (`tina -> tian`, `dinanao -> 电脑`, `xaing -> xiang`, `shaung -> shuang`, `womne -> women`, `hsi -> shi`)
            // Strictly forbidden when `raw` is ALREADY a valid Mandarin syllable (`!isExactSingleSyl`: so `enne -> 嗯呢` never swaps `ne -> en` into `嗯嗯`,
            // `fangna -> 放哪` never swaps `na -> an` into `方案`, and `zoule -> 走了` / `shoule -> 收了` never swap `ou -> uo`),
            // and never collapses an existing 2-syllable lexicon phrase (`quna -> 去哪`, `ali -> 阿里`, `shia -> 是啊`) into 1 syllable!
            if raw.count <= 6 && !isExactSingleSyl {
                let blockMultiSylPhraseSwap = isCleanMultiSyl
                    && !raw.hasSuffix("ina")
                    && lexicon.hasCommonCleanTwoSyllablePhrase(raw, minScoreQ8: -3350)
                if !blockMultiSylPhraseSwap {
                    let swapPen: Int
                    if isCleanMultiSyl {
                        swapPen = raw.hasSuffix("ina") ? 320 : 1150
                    } else if wholeInputClean {
                        swapPen = 680
                    } else {
                        swapPen = 180
                    }
                    var utf8 = Array(raw.utf8)
                    for i in 0..<(utf8.count - 1) where utf8[i] != utf8[i + 1] {
                        utf8.swapAt(i, i + 1)
                        let swapped = String(decoding: utf8, as: UTF8.self)
                        insert(swapped, penalty: swapPen)
                        if let (alias, aliasPen) = orthographicAliases[swapped], aliasPen == 0 {
                            insert(alias, penalty: swapPen)
                        }
                        utf8.swapAt(i, i + 1)
                    }
                }
            }

            // O(1) 1-letter-dropped rime recovery (`tin -> tian/ting`, `no -> nao/nuo`, `do -> dao/duo`, `zhon -> zhong`, `shung -> shuang`)
            if allowClipped && raw.count >= 2 && lexicon.syllableToID[raw] == nil,
               let clippedSIDs = lexicon.clippedToSyllableIDs[raw] {
                let isThreeLetterClippedA = (raw.count == 3 && raw.last == "a")
                let clipPen = raw.count == 2 ? 280 : ((isCleanMultiSyl && !isThreeLetterClippedA) ? 360 : 230)
                for sid in clippedSIDs {
                    let canon = lexicon.idToSyllable[Int(sid)]
                    insertSID(sid, canonical: canon, penalty: clipPen)
                }
            }
        } else if allowClippedWithTypo && raw.count >= 2 && lexicon.syllableToID[raw] == nil {
            // Superimposed `错敲 + 漏敲` within the SAME syllable (`xanh -> xang -> xiang`, `zhonh -> zhong`, `shunh -> shuang`, `hn -> hen`)
            if let (mapped, pen) = exactAliasMap[raw] {
                insert(mapped, penalty: pen + 40)
            }
            if let clippedSIDs = lexicon.clippedToSyllableIDs[raw] {
                let clipPen = raw.count == 2 ? 310 : 260
                for sid in clippedSIDs.prefix(3) {
                    let canon = lexicon.idToSyllable[Int(sid)]
                    insertSID(sid, canonical: canon, penalty: clipPen)
                }
            }
        }

        // 2B. Soft valid-syllable 1-letter drop recovery (`kui -> kuai`, `ha -> hao`, `shu -> shuo`, `ze -> zen`, `me -> men`,
        //     `ka -> kan`, `he -> zhe/she/che`, `hu -> shu/chu/zhu`)
        // Enabled on multi-syllable buffers (`n >= 5`) where a missed letter happens to leave an unrelated valid syllable.
        if allowSoftClipped && raw.count >= 2,
           let softClippedSIDs = lexicon.softClippedToSyllableIDs[raw] {
            let isNasalTwoLetter = (raw == "ze" || raw == "me")
            for sid in softClippedSIDs {
                let canon = lexicon.idToSyllable[Int(sid)]
                let isRetroflexOnsetDrop = raw.hasPrefix("h")
                    && (canon.hasPrefix("zh") || canon.hasPrefix("ch") || canon.hasPrefix("sh"))
                let softClipPen: Int
                if isNasalTwoLetter {
                    softClipPen = wholeInputClean ? 340 : 320
                } else if isRetroflexOnsetDrop {
                    softClipPen = wholeInputClean ? 405 : 375
                } else if wholeInputClean {
                    softClipPen = raw.hasSuffix("an") ? 540 : ((raw.count >= 3) ? 450 : 410)
                } else {
                    softClipPen = (raw.count >= 3) ? 405 : 385
                }
                insertSID(sid, canonical: canon, penalty: softClipPen, isSoftClipped: true)
            }
        }

        // 3. Explicit user-enabled Fuzzy Pinyin expansions (low penalty: 85 Q8)
        if !fuzzy.isEmpty {
            let nonSoftResults = results.filter { !$0.isSoftClipped }
            let seeds = nonSoftResults.isEmpty ? [(raw, 0)] : nonSoftResults.map { ($0.canonical, $0.penaltyQ8) }
            for (base, basePen) in seeds {
                for variant in fuzzyVariants(of: base, options: fuzzy) {
                    insert(variant, penalty: basePen + 85)
                }
            }
        }

        // 4. Automatic conservative soft phonetic & medial-drop fallback (`zege -> 这个`, `senme -> 什么`, `mingtan -> 明天`, `xinzai -> 现在`)
        // Uses a strict 430..470 Q8 (~9..17x frequency barrier) so genuine exact words (`司机`, `自己`, `森林`, `新闻`) never lose #1.
        if allowSoftPhonetic {
            if let medialTarget = Self.medialDropMap[raw] {
                insert(medialTarget, penalty: 430)
            }
            let remainingSoft = Self.softPhoneticPairs.subtracting(fuzzy)
            if !remainingSoft.isEmpty {
                for (variant, softPen) in singleStepSoftVariants(of: raw, options: remainingSoft, wholeInputClean: wholeInputClean) {
                    insert(variant, penalty: softPen)
                }
            }
        }

        if results.count > 1 {
            results.sort {
                if $0.penaltyQ8 != $1.penaltyQ8 { return $0.penaltyQ8 < $1.penaltyQ8 }
                return $0.syllableID < $1.syllableID
            }
        }
        return results
    }

    private static func singleStepSoftVariants(
        of syl: String,
        options: FuzzyPinyinOptions,
        wholeInputClean: Bool
    ) -> [(String, Int)] {
        var out: [(String, Int)] = []
        out.reserveCapacity(4)
        // Deleting an explicitly pressed `'h'` (`zh/ch/sh -> z/c/s`) or `'g'` (`-ang/-eng/-ing -> -an/-en/-in`)
        // when the user has NOT enabled Fuzzy Pinyin carries a higher barrier (`760 Q8` when `wholeInputClean`),
        // preventing `gang -> gan` (`我刚到地下 -> *我感到地下`) or `chi -> ci` (`明天吃什么 -> *明天词什么`) from hijacking clean sentences.
        let dropExplicitKeyPen = wholeInputClean ? 760 : 600
        let addNasalGPen = wholeInputClean ? 470 : 390
        if options.contains(.z_zh) {
            if syl.hasPrefix("zh") { out.append(("z" + syl.dropFirst(2), dropExplicitKeyPen)) }
            else if syl.hasPrefix("z") { out.append(("zh" + syl.dropFirst(1), 470)) }
        }
        if options.contains(.c_ch) {
            if syl.hasPrefix("ch") { out.append(("c" + syl.dropFirst(2), dropExplicitKeyPen)) }
            else if syl.hasPrefix("c") { out.append(("ch" + syl.dropFirst(1), 470)) }
        }
        if options.contains(.s_sh) {
            if syl.hasPrefix("sh") { out.append(("s" + syl.dropFirst(2), dropExplicitKeyPen)) }
            else if syl.hasPrefix("s") { out.append(("sh" + syl.dropFirst(1), 470)) }
        }
        if options.contains(.an_ang) {
            if syl.hasSuffix("ang") { out.append((String(syl.dropLast(3)) + "an", dropExplicitKeyPen)) }
            else if syl.hasSuffix("an") { out.append((String(syl.dropLast(2)) + "ang", addNasalGPen)) }
        }
        if options.contains(.en_eng) {
            if syl.hasSuffix("eng") {
                let engToEnPen = (syl == "heng") ? (wholeInputClean ? 480 : 440) : dropExplicitKeyPen
                out.append((String(syl.dropLast(3)) + "en", engToEnPen))
            } else if syl.hasSuffix("en") {
                out.append((String(syl.dropLast(2)) + "eng", addNasalGPen))
            }
        }
        if options.contains(.in_ing) {
            if syl.hasSuffix("ing") { out.append((String(syl.dropLast(3)) + "in", dropExplicitKeyPen)) }
            else if syl.hasSuffix("in") { out.append((String(syl.dropLast(2)) + "ing", addNasalGPen)) }
        }
        return out
    }

    public static func fuzzyVariants(of syl: String, options: FuzzyPinyinOptions) -> [String] {
        let variants: Set<String> = [syl]

        // Initial consonant fuzzy pairs
        var initialExpanded: Set<String> = [syl]
        for s in variants {
            if options.contains(.z_zh) {
                if s.hasPrefix("zh") {
                    initialExpanded.insert("z" + s.dropFirst(2))
                } else if s.hasPrefix("z") {
                    initialExpanded.insert("zh" + s.dropFirst(1))
                }
            }
            if options.contains(.c_ch) {
                if s.hasPrefix("ch") {
                    initialExpanded.insert("c" + s.dropFirst(2))
                } else if s.hasPrefix("c") {
                    initialExpanded.insert("ch" + s.dropFirst(1))
                }
            }
            if options.contains(.s_sh) {
                if s.hasPrefix("sh") {
                    initialExpanded.insert("s" + s.dropFirst(2))
                } else if s.hasPrefix("s") {
                    initialExpanded.insert("sh" + s.dropFirst(1))
                }
            }
            if options.contains(.n_l) {
                if s.hasPrefix("n") {
                    initialExpanded.insert("l" + s.dropFirst(1))
                } else if s.hasPrefix("l") {
                    initialExpanded.insert("n" + s.dropFirst(1))
                }
            }
            if options.contains(.f_h) {
                if s.hasPrefix("f") {
                    initialExpanded.insert("h" + s.dropFirst(1))
                } else if s.hasPrefix("h") && !s.hasPrefix("hm") {
                    initialExpanded.insert("f" + s.dropFirst(1))
                }
            }
            if options.contains(.r_l) {
                if s.hasPrefix("r") {
                    initialExpanded.insert("l" + s.dropFirst(1))
                } else if s.hasPrefix("l") {
                    initialExpanded.insert("r" + s.dropFirst(1))
                }
            }
        }

        // Final rime fuzzy pairs
        var allExpanded = initialExpanded
        for s in initialExpanded {
            if options.contains(.an_ang) {
                if s.hasSuffix("ang") {
                    allExpanded.insert(String(s.dropLast(3)) + "an")
                } else if s.hasSuffix("an") {
                    allExpanded.insert(String(s.dropLast(2)) + "ang")
                }
            }
            if options.contains(.en_eng) {
                if s.hasSuffix("eng") {
                    allExpanded.insert(String(s.dropLast(3)) + "en")
                } else if s.hasSuffix("en") {
                    allExpanded.insert(String(s.dropLast(2)) + "eng")
                }
            }
            if options.contains(.in_ing) {
                if s.hasSuffix("ing") {
                    allExpanded.insert(String(s.dropLast(3)) + "in")
                } else if s.hasSuffix("in") {
                    allExpanded.insert(String(s.dropLast(2)) + "ing")
                }
            }
        }

        allExpanded.remove(syl)
        return Array(allExpanded)
    }
}
