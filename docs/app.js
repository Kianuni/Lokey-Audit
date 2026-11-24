const LAB_CASES = {
  typo: {
    raw: "renfuomeishi",
    badge: { zh: "全拼 · 邻键盲打", en: "Full Pinyin · Typo Recovery" },
    cands: ["人没事", "人若没事", "人多没事", "ren fuo mei shi"],
    title: {
      zh: "精准捞回邻键连带误触，而不打扰正常拼写",
      en: "Recovers adjacent-key thumb slips without corrupting clean typing"
    },
    body: {
      zh: "快速盲打时 f/d、u/r 极易同时带偏。落墨引擎将真实键帽几何坐标 (x, y) 送入空间噪声信道，再由端侧 LNLM-v2 语义模型结合上下文重排，把「renfuomeishi」直接拉回「人没事」，同时严守干净拼音前缀绝不误改。",
      en: "Fast thumb typing easily slips across neighboring keys like f/d or u/r. Inkstone feeds exact keycap coordinates into a spatial noisy channel and reranks via on-device LNLM-v2 semantics—restoring '人没事' cleanly while leaving unambiguous inputs untouched."
    },
    specTitle: { zh: "覆盖盲打场景", en: "Covered Patterns" },
    specBody: {
      zh: "邻键误触 · 双指并发换位 · 卷舌音/前鼻音漏敲 · 胖手指多按滤除",
      en: "Adjacent-key slips · Two-thumb transpositions · Missing retroflex/nasal finals · Fat-finger dedup"
    }
  },
  disambig: {
    raw: "qizhongkaoshi",
    badge: { zh: "句首 · 双向神经重排", en: "Sentence-Start · Bidirectional Rerank" },
    cands: ["期中考试", "其中考试", "起中考试", "其中"],
    title: {
      zh: "一句话开头没有上文，也能向右看再精准定词",
      en: "Looks right before committing even when there is zero left context"
    },
    body: {
      zh: "传统词频输入法在句首遇到同音音节（qi zhong）很容易只看局部高频选成「其中」。落墨将前向语义打分与逆向句首重排结合，并依托 64 维跨句话题记忆，在句末还没打完前就把首词校对到位，大幅减少回删返工。",
      en: "Sentence-initial homophones often get trapped by unigram frequency. Inkstone pairs forward scoring with backward sentence-initial reranking and 64-dim cross-sentence topic memory to lock the right phrase on the first pass."
    },
    specTitle: { zh: "端侧长句能力", en: "On-Device Decoding" },
    specBody: {
      zh: "支持 64 字符长句滚动解码 · 支持全简混拼（wo lai s s b）",
      en: "64-char rolling sentence buffer · Full + Jianpin mixed lattice"
    }
  },
  mixed: {
    raw: "woaiiphone",
    badge: { zh: "全拼/双拼 · 无缝混输", en: "CN + EN Mixed Lattice" },
    cands: ["我爱 iPhone", "我按 iPhone", "我爱", "iPhone"],
    title: {
      zh: "不用切英文键盘，句内直出正确大小写品牌词",
      en: "Seamless Chinese-English composition with proper casing in one pass"
    },
    body: {
      zh: "针对高频中英夹杂场景，增量维特比晶格在中文高音节流与英文常见词之间自动平衡代价，直接给出「Apple Store」「MacBook Pro」「iPhone」「GitHub」「Wi-Fi」等规范空格与大小写格式。",
      en: "The incremental Viterbi lattice scores Chinese syllable paths alongside English and mixed tokens in a single pass—preserving idiomatic casing and spacing for 'iPhone', 'MacBook Pro', 'GitHub', and 'Wi-Fi'."
    },
    specTitle: { zh: "多方案同等支持", en: "Layouts & Variants" },
    specBody: {
      zh: "26 键全拼 · 小鹤双拼 · 自然码双拼 · OpenCC 简体 / 台灣正體 / 香港標準",
      en: "26-key Full Pinyin · Xiaohe & Ziranma Shuangpin · Live OpenCC s2twp / s2hk"
    }
  },
  habit: {
    raw: "12:00 / localhost:8080 / v1.0",
    badge: { zh: "零适应成本 · 原生直觉与个人热区", en: "Native Habits · Personal Heatmap" },
    cands: ["12:00", "localhost:8080", "女孩 (nuhai)", "去哪儿 (qunar)"],
    title: {
      zh: "沿用你的老习惯，却比系统自带更懂你的拇指",
      en: "Zero re-learning for your thumbs—plus quiet self-calibration over time"
    },
    body: {
      zh: "对齐原生 u/ü 正字等价（nuhai → 女孩）、儿化简写与智能数字/时间半角识别（输入 12:00 自动半角冒号，中文语境「时间是：」自动全角）。同时本机 2×2 高斯校准模型会在 ±20% 安全包络内默默贴合你的单手拇指偏斜习惯。",
      en: "Preserves native u/ü equivalence ('nuhai' → 女孩), context-aware half-width punctuation for times/URLs/versions, swipe-left backspace clear, and a local 2×2 Gaussian thumb heatmap safely clamped within ±20% key width."
    },
    specTitle: { zh: "原生操作直觉", en: "Built-In Muscle Memory" },
    specBody: {
      zh: "空框起始候选 · 左滑⌫清空待上屏长句 · 横拖 Shift / 长按空格移动拼音光标",
      en: "Idle starter strip · Swipe-left ⌫ clear · Drag Shift or hold Space to move cursor"
    }
  }
};

const I18N = {
  zh: {
    brandSub: "· 落键",
    navAudit: "审计仓库",
    navPack: "白霜词库包",
    heroBadge: "0 网络框架 · 源码字节级可审计 · 无需开启「允许完全访问」",
    heroTitle: "原生手感，零学习成本。<br />物理零联网的 iOS 中文输入法。",
    heroSub: "从系统自带键盘切过来，手指不需要任何适应时间。1:1 延续 iOS 26 Liquid Glass 键位几何与肌肉记忆，搭载自研「落墨 · Inkstone」离线引擎——二进制层面彻底剔除网络能力，却依然聪明跟手。",
    ctaAudit: "查看零联网审计仓库 →",
    ctaPack: "获取 55 万词白霜扩展包",
    ctaExplore: "先看核心体验 ↓",
    m1Val: "1:1 原生",
    m1Desc: "iOS 26 Liquid Glass 视觉几何与交互肌肉记忆，零适应门槛",
    m2Val: "0 联网符号",
    m2Desc: "不链接网络框架，不请求 Socket，关闭「完全访问」照样满血",
    m3Val: "50.6 万+ 词",
    m3Desc: "内置纯净基础词库 + 只读 mmap 零拷贝热挂载外置 .lokeypack",
    m4Val: "全拼 & 双拼",
    m4Desc: "26 键全拼、小鹤 / 自然码双拼与简繁实时切换",
    feelEyebrow: "ZERO LEARNING CURVE",
    feelTitle: "换过来就会用：为什么说 Lokey 没有适应成本？",
    feelSub: "第三方输入法最劝退的往往是略微偏移的键帽比例、生硬的动画和陌生的交互逻辑。Lokey 选择先 1:1 复刻系统原生的肌肉记忆，再把聪明劲藏在手指落下之后。",
    f1Tag: "视觉与几何",
    f1Title: "1:1 iOS 26 Liquid Glass 与四档屏幕几何",
    f1Desc: "键盘根视图透明透出系统原生液态玻璃胶囊底座，精确校准 Max/Plus（268.5pt）、Pro/标准（250.0pt）、Mini/SE（239.0pt）与横屏（197.5pt）四档高度；7.0pt 连续曲率纯白键帽，空闲与输入态保持 0.0pt 光学中心零跳变。",
    f2Tag: "原生肌肉记忆",
    f2Title: "不改习惯的手势与智能标点",
    f2Desc: "空输入框原生高频起始候选（我 / 你 / 在 / 这...）；左滑删除键（⌫）一键清空整段待上屏长句；横拖 Shift 或长按空格微调未上屏拼音光标；数字与时间（12:00、3.14、v1.0、localhost:8080）自动输出半角标点，无需来回切符号页。",
    f3Tag: "触感与声学",
    f3Title: "CoreHaptics 无级震动滑块 + 原生按键音",
    f3Desc: "基于 Apple CoreHaptics 提供 0%–100% 无级震动强度滑块与「关闭 / 轻柔 / 清脆」三档质感，配合三档系统原生按键音效，在主应用设置后通过 App Group 毫秒级同步至键盘。",
    f4Tag: "120Hz 响应",
    f4Title: "全异步防阻塞：手指按下零延迟",
    f4Desc: "触控路径严格隔离跨进程 XPC 阻塞，120Hz 键帽气泡先于宿主文本提交响应；原生自适应 Emoji 键盘支持离线标签快筛与 4×8 横滑，快打不掉帧。",
    labEyebrow: "INKSTONE ENGINE · 落墨离线引擎",
    labTitle: "不联网，也能跟上你的盲打节奏",
    labSub: "点击下方场景，直观查看 Lokey 如何在完全离线状态下处理邻键误触、句首同音、中英混输与个人拇指落点偏差。",
    tabTypo: "邻键盲打纠错",
    tabDisambig: "双向同音消歧",
    tabMixed: "句内中英混输",
    tabHabit: "个人热区 & 零适应细节",
    scrEyebrow: "REAL INTERFACE · 真机界面",
    scrTitle: "克制的设置体验，遵循原生系统语言",
    scrSub: "没有开屏广告，没有花哨皮肤商城。手感调校、盲打热区可视化、词库热挂载与个人记忆管理都在本地一页触达。",
    scr1Title: "手感与盲打调校（浅色）",
    scr1Desc: "0%–100% 无级震动滑块、全拼/小鹤/自然码切换、简繁标准与 26 键个人热区校准状态。",
    scr2Title: "原汁原味深色适配（深色）",
    scr2Desc: "完整遵循 iOS 26 深浅色外观与液态玻璃底栏，夜间微调参数不刺眼。",
    scr3Title: "零拷贝词库与外置包热挂载",
    scr3Desc: "实时查看只读 mmap 词库规模，支持秒级导入外部 .lokeypack、个人 Rime 词表与一键切回内置词库。",
    auditEyebrow: "VERIFIABLE ZERO-NETWORK · 独立可验证",
    auditTitle: "不是「承诺不上传」，而是压根没有联网代码",
    auditSub: "任何输入法都可以写一句“注重隐私”。Lokey 将 18 个核心引擎与键盘扩展 Swift 文件原样公开至 Lokey-Audit（SHA-256 字节级一致），欢迎直接跑 Mach-O 符号审查。",
    a1Title: "关闭「允许完全访问」即可离线使用",
    a1Desc: "全拼/双拼整句解码、内置基础词库、简繁转换与 Emoji 联想在关闭「允许完全访问」时照样 100% 离线工作。",
    a2Title: "开启完全访问仅限本机跨进程同步",
    a2Desc: "仅用于 App Group 沙盒（group.com.kianuni.lokey）内的偏好同步、个人 SQLite 自造词记忆与 CoreHaptics 线性震动，依然零网络传输。",
    a3Title: "密码框自动隔离保护",
    a3Desc: "遇到系统安全文本输入（isSecureTextEntry），自动停止个人词库学习并跳过一切本地日志写入；完整声明详见 PRIVACY.md。",
    copyBtn: "复制命令",
    packEyebrow: "OPEN LEXICON & .LOKEYPACK",
    packTitle: "自带纯净词库开箱即用，也拥抱 Rime 白霜生态",
    packSub: "内置 50.6 万条纯净基础词库，满足日常流畅输入；如果你习惯更大词量或行业词表，可通过「文件」App 或 AirDrop 离线热挂载 .lokeypack 扩展包。",
    packCardTitle: "Kianuni/lokey-frost-pack · 55.3 万词白霜扩展包",
    packCardSub: "以零拷贝只读 mmap（NSData.mappedIfSafe）直接挂载，脏堆内存趋近于零，稳居 iOS 键盘扩展严苛内存上限之下。不绑定官方签名，支持在多包间毫秒级切换或一键切回内置词库。",
    packLi1: "553,352 条中文词条 · 80,443 条简拼索引 · 21,313 条英文/混输词条",
    packLi2: "单文件内嵌 LNLM-v2 + LNBR-v2 + LNTR-v1 + LNS6-v1 四层端侧轻模型",
    packLi3: "零第三方依赖 Python 3 编译器，支持 --extra-dict 合入个人 Rime .dict.yaml",
    packBtnDl: "前往 Releases 下载词库包 →",
    packBtnRepo: "查看离线编译器仓库",
    hashTitle: "当前最新扩展包规格（v0.9.5）",
    kvFile: "发布文件",
    kvSize: "文件体积",
    kvFormat: "挂载方式",
    footerBy: "由",
    footerPrivacy: "隐私政策 / Privacy",
    footerEco: "Kianuni 苹果生态工具矩阵：",
    toastCopied: "已复制到剪贴板"
  },
  en: {
    brandSub: "· Local Key",
    navAudit: "Audit Repo",
    navPack: "Frost Pack",
    heroBadge: "0 Network Frameworks · Byte-Auditable Source · Works Without Full Access",
    heroTitle: "Native iOS Feel, Zero Learning Curve.<br />Physically Zero-Network Chinese Keyboard.",
    heroSub: "Switch from Apple's built-in keyboard with zero muscle-memory friction. 1:1 iOS 26 Liquid Glass geometry and gestures paired with the offline Inkstone engine—zero networking code inside the binary, yet fast and forgiving under blind thumb typing.",
    ctaAudit: "Inspect Lokey-Audit Repo →",
    ctaPack: "Get 553k Rime-Frost Pack",
    ctaExplore: "Explore Highlights ↓",
    m1Val: "1:1 Native",
    m1Desc: "Matches iOS 26 Liquid Glass dock geometry & stock muscle memory",
    m2Val: "0 Network Symbols",
    m2Desc: "Zero network frameworks or sockets—full decoding with Full Access OFF",
    m3Val: "506k+ Entries",
    m3Desc: "Built-in base lexicon + zero-copy mmap hot-mount for .lokeypack files",
    m4Val: "Pinyin & Shuangpin",
    m4Desc: "26-key Full Pinyin, Xiaohe & Ziranma Shuangpin, plus live OpenCC",
    feelEyebrow: "ZERO LEARNING CURVE",
    feelTitle: "Ready from Keystroke One: Why There Is Zero Adaptation Cost",
    feelSub: "Most third-party keyboards break rhythm with slightly shifted keycaps or unfamiliar gestures. Lokey preserves stock iOS ergonomics millimeter for millimeter and handles blind-typing intelligence silently underneath.",
    f1Tag: "Visual & Geometry",
    f1Title: "1:1 iOS 26 Liquid Glass & 4-Tier Screen Geometry",
    f1Desc: "Transparent root shell reveals the native iOS 26 Liquid Glass dock across Max/Plus (268.5pt), Pro/Standard (250.0pt), Mini/SE (239.0pt), and Landscape (197.5pt) with 7.0pt continuous-curve keycaps and 0.0pt optical center shift.",
    f2Tag: "Stock Muscle Memory",
    f2Title: "Familiar Gestures & Smart Half-Width Punctuation",
    f2Desc: "Stock-style high-frequency starter bar, swipe-left ⌫ to clear uncommitted sentences safely, Shift-drag or Space-hold cursor scrubbing, and smart half-width punctuation for times, decimals, and URLs (12:00, 3.14, localhost:8080).",
    f3Tag: "Haptics & Sound",
    f3Title: "Continuous CoreHaptics Slider + Native Key Clicks",
    f3Desc: "Fine-tune tactile strength smoothly from 0% to 100% with Off / Subtle / Crisp curves via CHHapticEngine and three native click sound profiles synced over local App Group.",
    f4Tag: "120Hz Responsiveness",
    f4Title: "Fully Async Pipeline: Zero Touch Blocking",
    f4Desc: "Zero cross-process XPC stalls on touchesBegan; keycap popups respond at 120Hz while marked text merges smoothly, alongside an adaptive offline-searchable Emoji picker.",
    labEyebrow: "INKSTONE ENGINE · 落墨",
    labTitle: "Smart Enough for Blind Typing, Without Ever Going Online",
    labSub: "Select a scenario below to see how Inkstone resolves adjacent-key slips, sentence-start homophones, CN-EN code-switching, and personal thumb habits strictly on-device.",
    tabTypo: "Blind-Type Recovery",
    tabDisambig: "Sentence Disambiguation",
    tabMixed: "CN + EN Lattice",
    tabHabit: "Heatmap & Native Habits",
    scrEyebrow: "REAL INTERFACE",
    scrTitle: "Restrained Settings Built in Native System Language",
    scrSub: "No ad clutter or theme stores—tactile tuning, 26-key calibration visualization, mmap lexicon switching, and SQLite personal words live cleanly in one place.",
    scr1Title: "Feel & Haptics Calibration (Light)",
    scr1Desc: "Continuous 0%–100% haptics slider, Pinyin/Shuangpin schemes, OpenCC output, and 26-key heatmap status.",
    scr2Title: "Native Dark Appearance (Dark)",
    scr2Desc: "Adapts cleanly to iOS 26 Dark Mode and Liquid Glass tab bar for comfortable late-night tuning.",
    scr3Title: "Zero-Copy Lexicon & Pack Mounting",
    scr3Desc: "Inspect read-only mmap memory stats, hot-mount .lokeypack archives or Rime tables, and roll back in one tap.",
    auditEyebrow: "VERIFIABLE ZERO-NETWORK",
    auditTitle: "Not a Promise—There Is Literally Zero Networking Code",
    auditSub: "Any keyboard can claim privacy in prose. Lokey mirrors all 18 core engine and keyboard extension Swift files byte-for-byte in Lokey-Audit so you can verify Mach-O symbols yourself.",
    a1Title: "Runs 100% Offline with Full Access OFF",
    a1Desc: "Full Pinyin/Shuangpin decoding, built-in base lexicon, OpenCC conversion, and Emoji suggestions work completely offline without enabling Allow Full Access.",
    a2Title: "Allow Full Access Stays Strictly Local",
    a2Desc: "Used solely for local App Group sandbox sync (group.com.kianuni.lokey), local SQLite user words, and CoreHaptics—with zero network frameworks linked.",
    a3Title: "Automatic Secure-Field Isolation",
    a3Desc: "Detects password and OTP fields (isSecureTextEntry) automatically, suspending user lexicon learning and local logging; full commitments live in PRIVACY.md.",
    copyBtn: "Copy Commands",
    packEyebrow: "OPEN LEXICON & .LOKEYPACK",
    packTitle: "Complete Out of the Box, Ready for 553k-Word Rime Packs",
    packSub: "Ships ready with a clean 506k+ built-in lexicon. Power users can also AirDrop or import standalone .lokeypack bundles from the iOS Files app offline.",
    packCardTitle: "Kianuni/lokey-frost-pack · 553k Rime-Frost Pack",
    packCardSub: "Mounted directly via read-only mmap (NSData.mappedIfSafe) with virtually zero dirty heap memory, keeping well below iOS extension Jetsam limits. Custom builds are equally welcome with one-tap rollback.",
    packLi1: "553,352 Chinese entries · 80,443 Jianpin keys · 21,313 EN/mixed entries",
    packLi2: "Single binary embeds LNLM-v2 + LNBR-v2 + LNTR-v1 + LNS6-v1 on-device layers",
    packLi3: "Zero-dependency Python 3 compiler supports --extra-dict for custom Rime .dict.yaml",
    packBtnDl: "Download Pack on Releases →",
    packBtnRepo: "Open Compiler Repo",
    hashTitle: "Latest Pack Specification (v0.9.5)",
    kvFile: "Release Asset",
    kvSize: "File Size",
    kvFormat: "Mount Format",
    footerBy: "Crafted by",
    footerPrivacy: "Privacy Policy",
    footerEco: "Kianuni Apple Ecosystem:",
    toastCopied: "Copied to clipboard"
  }
};

let currentLang = "zh";
let currentCase = "typo";

function renderLab() {
  const item = LAB_CASES[currentCase];
  document.getElementById("labRaw").textContent = item.raw;
  document.getElementById("labBadge").textContent = item.badge[currentLang];
  document.getElementById("labExplainTitle").textContent = item.title[currentLang];
  document.getElementById("labExplainBody").textContent = item.body[currentLang];
  document.getElementById("labSpecTitle").textContent = item.specTitle[currentLang];
  document.getElementById("labSpecBody").textContent = item.specBody[currentLang];

  const bar = document.getElementById("labCandidates");
  bar.innerHTML = "";
  item.cands.forEach((cand, idx) => {
    const el = document.createElement("span");
    el.className = idx === 0 ? "cand-pill primary" : "cand-pill";
    el.textContent = `${idx + 1}. ${cand}`;
    bar.appendChild(el);
  });
}

function applyLang(lang) {
  currentLang = lang;
  document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
  const dict = I18N[lang];
  document.querySelectorAll("[data-i18n]").forEach((el) => {
    const key = el.getAttribute("data-i18n");
    if (!dict[key]) return;
    if (key === "heroTitle") {
      el.innerHTML = dict[key];
    } else {
      el.textContent = dict[key];
    }
  });
  document.getElementById("langToggle").textContent = lang === "zh" ? "EN / 中文" : "中文 / EN";
  renderLab();
}

function showToast(msg) {
  const toast = document.getElementById("toast");
  toast.textContent = msg;
  toast.classList.add("show");
  setTimeout(() => toast.classList.remove("show"), 1800);
}

document.addEventListener("DOMContentLoaded", () => {
  const browserLang = (navigator.language || "").toLowerCase();
  if (browserLang && !browserLang.startsWith("zh")) {
    applyLang("en");
  } else {
    applyLang("zh");
  }

  document.getElementById("langToggle").addEventListener("click", () => {
    applyLang(currentLang === "zh" ? "en" : "zh");
  });

  document.querySelectorAll(".lab-tab").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".lab-tab").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      currentCase = btn.getAttribute("data-case");
      renderLab();
    });
  });

  document.getElementById("copyAuditBtn").addEventListener("click", async () => {
    const rawCmd = [
      "git clone https://github.com/Kianuni/Lokey-Audit.git",
      "cd Lokey-Audit",
      "./scripts/audit_zero_network.sh --source-only",
      "python3 scripts/build_demo_lexicon.py && python3 scripts/generate_xcodeproj.py",
      "xcodebuild test -project LokeyAudit.xcodeproj -scheme LokeyAudit -derivedDataPath build/DerivedData -destination 'platform=iOS Simulator,name=iPhone 17 Pro'",
      "./scripts/audit_zero_network.sh build/DerivedData"
    ].join("\n");
    try {
      await navigator.clipboard.writeText(rawCmd);
      showToast(I18N[currentLang].toastCopied);
    } catch {
      showToast(I18N[currentLang].toastCopied);
    }
  });
});
