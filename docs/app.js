const HEATMAP_ROWS = [
  "qwertyuiop".split(""),
  "asdfghjkl".split(""),
  "zxcvbnm".split("")
];

const HEATMAP_SAMPLES = {
  q: [6, -0.05, 0.03],
  w: [14, -0.04, 0.04],
  e: [38, -0.03, 0.05],
  r: [18, 0.02, 0.04],
  t: [22, 0.06, 0.03],
  y: [26, -0.04, 0.03],
  u: [34, -0.05, 0.04],
  i: [52, -0.07, 0.02],
  o: [30, -0.06, -0.02],
  p: [9, -0.09, -0.03],
  a: [44, 0.07, -0.02],
  s: [32, 0.05, -0.01],
  d: [28, 0.04, 0.02],
  f: [12, 0.05, 0.02],
  g: [29, 0.07, 0.01],
  h: [36, -0.05, 0.02],
  j: [24, -0.06, 0.01],
  k: [16, -0.07, -0.01],
  l: [21, -0.08, -0.03],
  z: [27, 0.08, -0.05],
  x: [19, 0.06, -0.04],
  c: [25, 0.05, -0.03],
  v: [8, 0.04, -0.03],
  b: [15, 0.06, -0.04],
  n: [58, -0.08, -0.04],
  m: [23, -0.09, -0.05]
};

const LAB_CASES = {
  typo: {
    raw: "renfuomeishi",
    badge: { zh: "全拼 · 邻键盲打", en: "Full Pinyin · Typo Recovery" },
    cands: ["人没事", "人若没事", "人多没事", "ren fuo mei shi"],
    title: {
      zh: "精准捞回邻键误触，严守干净输入不误改",
      en: "Recovers adjacent-key thumb slips while protecting clean typing"
    },
    body: {
      zh: "快速盲打时 f/d、u/r 极易带偏。落墨引擎融合真实键帽几何坐标 (x, y) 与端侧 LNLM-v2 语义重排，把「renfuomeishi」直接拉回「人没事」，同时支持双指换位、漏敲补全与胖手指多按滤除。",
      en: "Fast thumb typing easily clips adjacent keys like f/d or u/r. Inkstone pairs keycap coordinates with on-device LNLM-v2 reranking—restoring '人没事' while also handling two-thumb transpositions and missed finals."
    }
  },
  disambig: {
    raw: "qizhongkaoshi",
    badge: { zh: "句首 · 双向神经重排", en: "Sentence-Start · Bidirectional Rerank" },
    cands: ["期中考试", "其中考试", "起中考试", "其中"],
    title: {
      zh: "句首无上文也能向右看，一次命中目标长词",
      en: "Looks ahead before committing even with zero left context"
    },
    body: {
      zh: "一句开头遇到同音音节（qi zhong）时，逆向句首重排联合 64 维跨句话题记忆会在句末输入完成前校对首词，将「期中考试」顶至首选，显著减少回删返工；支持最高 64 字符长句滚动解码。",
      en: "At the start of a sentence, backward sentence-initial reranking and 64-dim cross-sentence topic memory collaborate to lock '期中考试' on pass one, supporting rolling decoding up to 64 characters."
    }
  },
  mixed: {
    raw: "woaiiphone",
    badge: { zh: "全拼/双拼 · 无缝混输", en: "CN + EN Mixed Lattice" },
    cands: ["我爱 iPhone", "我按 iPhone", "我爱", "iPhone"],
    title: {
      zh: "句内中英混合一遍上屏，自动保留规范大小写",
      en: "Single-pass CN-EN composition with idiomatic casing"
    },
    body: {
      zh: "无需反复切换中英文键盘。增量维特比晶格在合法汉语拼音与常见英文词汇间平滑平衡代价，自动输出「iPhone」「MacBook Pro」「Apple Store」「GitHub」「Wi-Fi」等标准大小写与空格格式。",
      en: "No keyboard toggling needed. The incremental Viterbi lattice scores Chinese syllable flows alongside English tokens in one pass—preserving formatting for iPhone, MacBook Pro, GitHub, and Wi-Fi."
    }
  },
  habit: {
    raw: "12:00 / nuhai / localhost:8080",
    badge: { zh: "零适应 · 原生直觉与双拼", en: "Native Habits · Shuangpin" },
    cands: ["12:00", "女孩 (nuhai)", "去哪儿 (qunar)", "localhost:8080"],
    title: {
      zh: "沿用系统直觉与双拼习惯，开箱无需任何磨合期",
      en: "Built on stock iOS typing instincts with Full & Shuangpin parity"
    },
    body: {
      zh: "原生对齐 iOS 26 u/ü 正字等价（nuhai → 女孩）、北方儿化简写与数字时间智能半角识别；同时完整内置 26 键全拼、小鹤双拼、自然码双拼、自定义模糊音及 OpenCC 简体 / 台灣正體 / 香港標準词级实时切换。",
      en: "Includes stock u/ü equivalence ('nuhai' → 女孩), context-aware half-width numerals/URLs, custom fuzzy Pinyin, Xiaohe & Ziranma Shuangpin, and live OpenCC Simplified / TW / HK word-level conversion."
    }
  }
};

const I18N = {
  zh: {
    brandSub: "· 落键",
    themeLight: "浅色",
    themeDark: "深色",
    navPack: "白霜包",
    heroKicker: "物理级零联网 · 18 份核心源码字节级可审计",
    heroTitle: "原生手感，零学习成本。<br />物理零联网的 iOS 中文输入法。",
    heroSub: "从系统自带键盘切换过来，手指无需任何适应时间。1:1 延续 iOS 26 液态玻璃键位几何与操作直觉，搭载自研「落墨 · Inkstone」离线引擎——二进制内彻底不含网络能力，却依然聪明跟手。",
    ctaAudit: "查看零联网审计仓 →",
    ctaPack: "获取 55 万词白霜包",
    cardScheme: "全拼 / 双拼",
    cardEngineSub: "落墨 · 32 维双向神经整句引擎",
    cardStatusText: "无需「允许完全访问」· 100% 离线盲打",
    cardOfflineTag: "纯离线",
    hm1Label: "原生手感",
    hm1Sub: "零学习适应成本",
    hm2Label: "基础词库",
    hm2Val: "50.6万 词",
    hm2Sub: "mmap 零拷贝挂载",
    hm3Label: "盲打热区",
    hm3Val: "26 键",
    hm3Sub: "±20% 个人自适应",
    cardAction: "探索下方互动体验台与零联网审计",
    feelKicker: "手感与交互",
    feelTitle: "换过来就会用：为什么说 Lokey 零学习成本？",
    feelSub: "第三方输入法最劝退的往往是微偏的键位比例与陌生的交互规则。Lokey 先 1:1 复刻系统原生键盘的肌肉记忆，再把触感调校与纠错能力悄悄做透。",
    gTitle: "快捷手势",
    gChip: "原生交互",
    keySpace: "空格",
    g1Title: "长按空格移光标",
    g1Desc: "长按空格滑动正文光标；输入中也可横滑 ⇧ 改拼音",
    g2Title: "左滑一键清空",
    g2Desc: "在退格键向左轻扫，整句重输不累手",
    g3Pill: "自选词",
    g3Title: "长按候选删词",
    g3Desc: "长按候选栏中的自选词或自造词即可删除",
    g4Title: "上滑数与纯英锁",
    g4Desc: "可选 Q–P 上滑出数字 · 长按 123 锁纯英",
    rTitle: "原生系统规格对齐",
    r1Title: "1:1 液态玻璃与四档屏幕几何",
    r1Sub: "全透明根视图透出原生 Liquid Glass 底座；精确对齐 Max/Plus (268.5pt)、Pro (250.0pt)、Mini/SE (239.0pt) 与横屏 (197.5pt)，空闲/输入态 0.0pt 光学跳变。",
    r2Title: "CoreHaptics 无级震动与原生声学",
    r2Sub: "0%–100% 连续震动滑块（关闭 / 轻柔 / 清脆）配合三档系统原生按键音效，经 App Group 毫秒级同步至键盘。",
    r3Title: "全异步 120Hz 零延迟响应",
    r3Sub: "触控路径严守零 XPC 阻塞，120Hz 键帽气泡先于宿主文本提交响应；空框内置原生高频起始候选条（我 / 你 / 在 / 这...）。",
    r4Title: "智能半角标点与原生 Emoji 面板",
    r4Sub: "输入 12:00、3.14、v1.0、localhost:8080 自动保持英文半角，中文语境自动全角；自带 4×8 横滑 Emoji 面板与离线标签快筛。",
    labKicker: "落墨引擎 · 互动体验",
    labTitle: "不联网，也能默默贴合你的拇指与语境",
    labSub: "点击下方「26 键盲打热区云图」的任意按键查看真实偏移拟合方式，或切换右侧场景查看纯离线整句解码效果。",
    hmTitle: "26 键盲打热区云图",
    hmSub: "示例预览 · 2×2 协方差高斯校准 · 上限 ±20%",
    hmChip: "点按交互",
    hmLegAnchor: "实测键心锚点",
    hmLegWash: "键帽墨晕浓淡代表落点频次",
    hmLegCount: "26/26 键",
    inkTitle: "落墨 · Inkstone 离线解码",
    inkSub: "全拼 · 小鹤/自然码双拼 · OpenCC 简繁",
    tabTypo: "邻键纠错",
    tabDisambig: "双向消歧",
    tabMixed: "中英混输",
    tabHabit: "原生习惯",
    scrKicker: "真机外观",
    scrTitle: "克制纯粹，遵循原生系统语言",
    scrSub: "零开屏广告、零冗余弹窗，完整的手感调校、盲打热区可视化、词库热挂载与个人词条管理全部内置。",
    scr1Title: "手感与盲打调校（浅色模式）",
    scr1Desc: "0%–100% 无级震动滑块、全拼/小鹤/自然码切换与 26 键个人热区开关。",
    scr2Title: "夜间深色适配（深色模式）",
    scr2Desc: "完整适配 iOS 26 深色外观与液态玻璃底栏，夜间调校不刺眼。",
    scr3Title: "零拷贝词库与 .lokeypack 热挂载",
    scr3Desc: "实时查看只读 mmap 词库规模，支持外部 .lokeypack 热挂载与个人 Rime 词表管理。",
    auditKicker: "独立零联网验证",
    auditTitle: "不是口头承诺隐私，而是二进制里没有联网代码",
    auditSub: "18 份核心引擎与键盘扩展 Swift 文件在 Lokey-Audit 字节级公开，欢迎亲自运行源码扫描与 Mach-O 符号审查。",
    shTitle: "100% 物理零联网承诺",
    shSub: "无网络框架、Socket 系统调用或远端遥测",
    shZ1: "网络权限与框架",
    shZ2: "Socket / HTTP 符号",
    shZ3: "敏感词过滤干预",
    shP1Title: "关闭「允许完全访问」（默认即用）",
    shP1Badge: "核心可用",
    shP1Desc: "26 键全拼/双拼整句、内置词库、OpenCC 简繁与 Emoji 联想 100% 离线生效",
    shP2Title: "开启「允许完全访问」（按需可选）",
    shP2Badge: "仅本机容器",
    shP2Desc: "仅用于本机 App Group 同步偏好、SQLite 自造词、外部 .lokeypack 与震动音效；安全输入框（isSecureTextEntry）自动隔离",
    shBtn: "前往 Lokey-Audit 审计 18 份核心源码",
    copyBtn: "复制审计命令",
    termFootNote: "完整 Apple Privacy Manifest 声明",
    packKicker: "词库扩展生态",
    packTitle: "自带纯净基础词库，亦支持 55.3 万词白霜扩展热挂载",
    packSub: "外置 .lokeypack 是纯粹的被动静态二进制数据文件；通过「文件」App 或隔空投送导入后在本机校验 SHA-256，并以零拷贝只读 mmap 热挂载，随时一键切回内置词库。",
    packCardHead: "Kianuni/lokey-frost-pack · 白霜外置词库包（v0.9.5）",
    packMmapTag: "mmap 零拷贝",
    pkStat1: "中文词条",
    pkStat2: "简拼 · 混输",
    pkStat3: "单文件体积",
    pkRow1Title: "下载预编译 rime-frost.lokeypack",
    pkRow1Sub: "前往 GitHub Releases 获取成品词库包与 .sha256，内嵌四层端侧神经打分与上下文消歧权重",
    pkRow2Title: "零依赖 Python 3 离线编译器与 Rime 定制",
    pkRow2Sub: "使用 --extra-dict 合入个人 Rime .dict.yaml 专业词表；支持在 Lokey 主应用导入 Rime .userdb.txt",
    copySha: "复制",
    footerBy: "由",
    footerPrivacy: "隐私政策 / Privacy",
    footerEco: "Kianuni 苹果生态工具矩阵：",
    toastCopied: "已复制到剪贴板"
  },
  en: {
    brandSub: "· Local Key",
    themeLight: "Light",
    themeDark: "Dark",
    navPack: "Frost Pack",
    heroKicker: "Physically Zero-Network · 18 Core Files Byte-Auditable",
    heroTitle: "Native iOS Feel, Zero Learning Curve.<br />Physically Zero-Network Chinese Keyboard.",
    heroSub: "Switch from Apple's built-in keyboard with zero muscle-memory friction. 1:1 iOS 26 Liquid Glass ergonomics paired with the offline Inkstone engine—literally zero networking code in the binary, yet fast and forgiving.",
    ctaAudit: "Inspect Lokey-Audit Repo →",
    ctaPack: "Get 553k Rime-Frost Pack",
    cardScheme: "Full / Shuangpin",
    cardEngineSub: "Inkstone · 32-Dim Bidirectional Sentence Engine",
    cardStatusText: "No Full Access Needed · 100% Offline Typing",
    cardOfflineTag: "Offline Only",
    hm1Label: "Ergonomics",
    hm1Sub: "Zero learning curve",
    hm2Label: "Base Lexicon",
    hm2Val: "506k Words",
    hm2Sub: "Zero-copy mmap",
    hm3Label: "Touch Model",
    hm3Val: "26 Keys",
    hm3Sub: "±20% local adaptive",
    cardAction: "Explore Interactive Lab & Audit Verification Below",
    feelKicker: "Feel & Ergonomics",
    feelTitle: "Ready from Keystroke One: Why Zero Learning Cost Matters",
    feelSub: "Shifted key proportions and unfamiliar gestures slow down most third-party keyboards. Lokey faithfully mirrors stock iOS muscle memory before layering tactile tuning and blind-typing recovery underneath.",
    gTitle: "Quick Gestures",
    gChip: "Native Touch",
    keySpace: "Space",
    g1Title: "Hold Space for Cursor",
    g1Desc: "Slide cursor smoothly on Space; drag ⇧ horizontally mid-pinyin to edit raw input",
    g2Title: "Swipe Left to Clear",
    g2Desc: "Sweep left on ⌫ to clear the pending sentence cleanly without deleting committed text",
    g3Pill: "User Word",
    g3Title: "Hold Candidate to Forget",
    g3Desc: "Long-press any personal or learned phrase in the candidate bar to forget it",
    g4Title: "Flick Digits & EN Lock",
    g4Desc: "Optional Q–P flick-up digits · Long-press 123 to lock pure English mode",
    rTitle: "Native iOS 26 Spec Alignment",
    r1Title: "1:1 Liquid Glass & 4-Tier Geometry",
    r1Sub: "Transparent root view exposes stock Liquid Glass; tuned for Max/Plus (268.5pt), Pro (250.0pt), Mini/SE (239.0pt) & Landscape (197.5pt) with 0.0pt optical shift.",
    r2Title: "Continuous CoreHaptics & Clicks",
    r2Sub: "0%–100% haptic intensity slider (Off / Subtle / Crisp) paired with 3 native system click sound levels synced via local App Group.",
    r3Title: "Fully Async 120Hz Pipeline",
    r3Sub: "Zero XPC stalls on touchesBegan; keycap popups respond at 120Hz before host commits, with stock-style idle starter candidates.",
    r4Title: "Smart Punctuation & Emoji Picker",
    r4Sub: "Times, decimals, versions & URLs (12:00, 3.14, localhost:8080) stay half-width while Chinese prose keeps full-width marks; 4×8 Emoji grid with offline tag search.",
    labKicker: "Inkstone Interactive Lab",
    labTitle: "Quietly Adapts to Your Thumbs & Context, Offline",
    labSub: "Tap any key on the 26-Key Touch Heatmap below to inspect per-key offset calibration, or switch Inkstone test cases on the right.",
    hmTitle: "26-Key Blind-Type Heatmap",
    hmSub: "Sample Preview · 2×2 Covariance Gaussian · Clamp ±20%",
    hmChip: "Interactive",
    hmLegAnchor: "Calibrated key centroid",
    hmLegWash: "Ink intensity shows tap frequency",
    hmLegCount: "26/26 Keys",
    inkTitle: "Inkstone Offline Decoder",
    inkSub: "Full Pinyin · Xiaohe / Ziranma · OpenCC",
    tabTypo: "Typo Recovery",
    tabDisambig: "Sentence Rerank",
    tabMixed: "CN + EN Lattice",
    tabHabit: "Native Habits",
    scrKicker: "On-Device UI",
    scrTitle: "Clean, Native-First iOS Interface",
    scrSub: "Zero ads or clutter—tactile sliders, 26-key calibration cloud map, mmap lexicon switching, and local user-lexicon controls live on device.",
    scr1Title: "Feel & Haptics Calibration (Light)",
    scr1Desc: "Continuous CoreHaptics slider, Full/Xiaohe/Ziranma layout switcher, and touch calibration toggle.",
    scr2Title: "OLED Dark Appearance (Dark)",
    scr2Desc: "Follows iOS 26 Dark Mode and Liquid Glass tab bar for comfortable late-night adjustments.",
    scr3Title: "Zero-Copy Lexicon & Pack Mount",
    scr3Desc: "Inspect read-only mmap lexicon metrics, hot-mount .lokeypack bundles, and manage personal Rime entries.",
    auditKicker: "Verifiable Zero-Network",
    auditTitle: "Not a Privacy Claim—Literally Zero Networking Code",
    auditSub: "All 18 core engine and keyboard extension Swift files are mirrored byte-for-byte in Lokey-Audit so you can inspect Mach-O symbols yourself.",
    shTitle: "100% Physically Zero-Network",
    shSub: "No network frameworks, socket syscalls, or remote telemetry",
    shZ1: "Network Frameworks",
    shZ2: "Socket / HTTP Symbols",
    shZ3: "Censored Word Lists",
    shP1Title: "Allow Full Access OFF (Default Ready)",
    shP1Badge: "Core Works",
    shP1Desc: "Full Pinyin/Shuangpin decoding, base lexicon, OpenCC conversion & Emoji run 100% offline",
    shP2Title: "Allow Full Access ON (Strictly Local)",
    shP2Badge: "On-Device Only",
    shP2Desc: "Used solely for local App Group settings sync, SQLite personal phrases, .lokeypack mounting & haptics; secure text fields stay isolated",
    shBtn: "Audit 18 Core Swift Files on Lokey-Audit",
    copyBtn: "Copy Commands",
    termFootNote: "Full Apple Privacy Manifest declarations",
    packKicker: "Lexicon Ecosystem",
    packTitle: "Ready Out of the Box, Extensible to 553k Words",
    packSub: ".lokeypack bundles are passive static binaries verified via SHA-256 on device and mounted via zero-copy read-only mmap—roll back to the built-in lexicon in one tap.",
    packCardHead: "Kianuni/lokey-frost-pack · Rime-Frost Pack (v0.9.5)",
    packMmapTag: "Zero-Copy mmap",
    pkStat1: "Chinese Entries",
    pkStat2: "Jianpin · Mixed",
    pkStat3: "Single-File Size",
    pkRow1Title: "Download Prebuilt rime-frost.lokeypack",
    pkRow1Sub: "Fetch precompiled .lokeypack & .sha256 from Releases with 4 on-device reranking layers",
    pkRow2Title: "Zero-Dependency Python 3 Compiler & Rime Import",
    pkRow2Sub: "Merge custom Rime .dict.yaml via --extra-dict or import .userdb.txt directly inside Lokey",
    copySha: "Copy",
    footerBy: "Crafted by",
    footerPrivacy: "Privacy Policy",
    footerEco: "Kianuni Apple Ecosystem:",
    toastCopied: "Copied to clipboard"
  }
};

let currentLang = "zh";
let currentCase = "typo";
let selectedKey = "n";
let userThemeOverride = null; // null follows system

function isEffectiveDark() {
  if (userThemeOverride === "dark") return true;
  if (userThemeOverride === "light") return false;
  return Boolean(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
}

function renderThemeUI() {
  const dark = isEffectiveDark();
  if (userThemeOverride) {
    document.documentElement.setAttribute("data-theme", userThemeOverride);
  } else {
    document.documentElement.removeAttribute("data-theme");
  }
  document.getElementById("themeLightBtn").classList.toggle("active", !dark);
  document.getElementById("themeDarkBtn").classList.toggle("active", dark);

  const lexImg = document.getElementById("lexiconScreenImg");
  if (lexImg) {
    lexImg.src = dark ? "./assets/lexicon-dark.png" : "./assets/lexicon-light.png";
  }

  const hmCap = document.getElementById("hmSelectedKeycap");
  if (hmCap) {
    hmCap.classList.toggle("keycap-charcoal", dark);
    hmCap.classList.toggle("keycap-ivory", !dark);
  }
  renderHeatmap();
}

function renderHeatmap() {
  const deck = document.getElementById("heatmapDeck");
  if (!deck) return;
  const dark = isEffectiveDark();
  deck.innerHTML = "";

  HEATMAP_ROWS.forEach((row) => {
    const rowEl = document.createElement("div");
    rowEl.className = "heatmap-row";
    row.forEach((ch) => {
      const [samples, dx, dy] = HEATMAP_SAMPLES[ch];
      const intensity = Math.min(1, samples / 48);
      const offX = (dx * 40 * 1.9).toFixed(1);
      const offY = (dy * 40 * 1.9).toFixed(1);

      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "heat-key" + (selectedKey === ch ? " selected" : "");
      btn.setAttribute("aria-label", `Key ${ch.toUpperCase()}`);

      const washColor = dark
        ? `radial-gradient(circle, rgba(255,255,255,${(0.11 + 0.24 * intensity).toFixed(2)}) 0%, rgba(255,255,255,0) 72%)`
        : `radial-gradient(circle, rgba(24,26,34,${(0.11 + 0.28 * intensity).toFixed(2)}) 0%, rgba(24,26,34,${(0.04 + 0.11 * intensity).toFixed(2)}) 45%, rgba(24,26,34,0) 74%)`;

      btn.innerHTML = `
        <span class="heat-key-face">
          <span class="heat-wash" style="background:${washColor}; transform:translate(${offX}px, ${offY}px);"></span>
          <span class="heat-origin-ring"></span>
          <span class="heat-centroid-dot" style="transform:translate(${offX}px, ${offY}px);"></span>
          <span class="heat-letter">${ch.toUpperCase()}</span>
        </span>
      `;
      btn.addEventListener("click", () => {
        selectedKey = ch;
        renderHeatmap();
        renderHeatmapTelemetry();
      });
      rowEl.appendChild(btn);
    });
    deck.appendChild(rowEl);
  });
  renderHeatmapTelemetry();
}

function renderHeatmapTelemetry() {
  const [samples, dx, dy] = HEATMAP_SAMPLES[selectedKey];
  const dxStr = (dx >= 0 ? "+" : "") + (dx * 100).toFixed(1) + "%";
  const dyStr = (dy >= 0 ? "+" : "") + (dy * 100).toFixed(1) + "%";

  document.getElementById("hmSelectedKeycap").textContent = selectedKey.toUpperCase();
  if (currentLang === "zh") {
    document.getElementById("hmTelemetryTitle").textContent = `示意 ${samples} 次 · 键心微调 (${dxStr}, ${dyStr})`;
    document.getElementById("hmTelemetrySub").textContent = "已拟合 2×2 拇指斜角椭圆协方差 · 纯本机保存";
  } else {
    document.getElementById("hmTelemetryTitle").textContent = `Preview ${samples} taps · Center Shift (${dxStr}, ${dyStr})`;
    document.getElementById("hmTelemetrySub").textContent = "Fitted 2×2 thumb ellipse covariance · Stored strictly on-device";
  }
}

function renderLab() {
  const item = LAB_CASES[currentCase];
  document.getElementById("labRaw").textContent = item.raw;
  document.getElementById("labBadge").textContent = item.badge[currentLang];
  document.getElementById("labExplainTitle").textContent = item.title[currentLang];
  document.getElementById("labExplainBody").textContent = item.body[currentLang];

  const bar = document.getElementById("labCandidates");
  bar.innerHTML = "";
  item.cands.forEach((cand, idx) => {
    const el = document.createElement("span");
    el.className = idx === 0 ? "cand-btn primary" : "cand-btn";
    el.textContent = `${idx + 1}. ${cand}`;
    bar.appendChild(el);
  });
}

function applyLang(lang) {
  currentLang = lang;
  document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
  document.getElementById("langZhBtn").classList.toggle("active", lang === "zh");
  document.getElementById("langEnBtn").classList.toggle("active", lang === "en");

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
  renderHeatmapTelemetry();
  renderLab();
}

function showToast(msg) {
  const toast = document.getElementById("toast");
  toast.textContent = msg;
  toast.classList.add("show");
  setTimeout(() => toast.classList.remove("show"), 1800);
}

async function copyText(str) {
  try {
    await navigator.clipboard.writeText(str);
  } catch {
    // Fallback silent ignore on non-HTTPS previews
  }
  showToast(I18N[currentLang].toastCopied);
}

document.addEventListener("DOMContentLoaded", () => {
  const browserLang = (navigator.language || "").toLowerCase();
  applyLang(browserLang && !browserLang.startsWith("zh") ? "en" : "zh");
  renderThemeUI();

  if (window.matchMedia) {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    if (mq.addEventListener) {
      mq.addEventListener("change", () => {
        if (!userThemeOverride) renderThemeUI();
      });
    }
  }

  document.getElementById("langZhBtn").addEventListener("click", () => applyLang("zh"));
  document.getElementById("langEnBtn").addEventListener("click", () => applyLang("en"));

  document.getElementById("themeLightBtn").addEventListener("click", () => {
    userThemeOverride = "light";
    renderThemeUI();
  });
  document.getElementById("themeDarkBtn").addEventListener("click", () => {
    userThemeOverride = "dark";
    renderThemeUI();
  });

  document.querySelectorAll(".inkstone-tabs .seg-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".inkstone-tabs .seg-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      currentCase = btn.getAttribute("data-case");
      renderLab();
    });
  });

  document.getElementById("copyAuditBtn").addEventListener("click", () => {
    copyText([
      "git clone https://github.com/Kianuni/Lokey-Audit.git",
      "cd Lokey-Audit",
      "./scripts/audit_zero_network.sh --source-only",
      "python3 scripts/build_demo_lexicon.py && python3 scripts/generate_xcodeproj.py",
      "xcodebuild test -project LokeyAudit.xcodeproj -scheme LokeyAudit -derivedDataPath build/DerivedData -destination 'platform=iOS Simulator,name=iPhone 17 Pro'",
      "./scripts/audit_zero_network.sh build/DerivedData"
    ].join("\n"));
  });

  document.getElementById("copyShaBtn").addEventListener("click", () => {
    copyText("de32f3c0e561026752e56392c2cd5cdd912a73424da2ff9b9fae80d04d4ee348");
  });
});
