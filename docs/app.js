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
    cands: ["人多没事", "人若没事", "人没事", "ren fuo mei shi"],
    title: {
      zh: "精准捞回邻键误触，严守干净输入不误改",
      en: "Recovers adjacent-key thumb slips while protecting clean typing"
    },
    body: {
      zh: "快速盲打时 d/f 邻键极易带偏（renduomeishi 误敲为 renfuomeishi）。落墨引擎融合真实键帽几何坐标 (x, y) 与端侧 LNLM-v2 语义重排，将「renfuomeishi」直接拉回首选「人多没事」，同时支持双指换位、漏敲补全与胖手指多按滤除。",
      en: "Fast thumb typing easily slips onto an adjacent key like d/f ('renduomeishi' typed as 'renfuomeishi'). Inkstone pairs keycap coordinates with on-device LNLM-v2 reranking—restoring '人多没事' as top candidate while also handling two-thumb transpositions and missed finals."
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

const SCHEME_DEMOS = {
  quanpin: {
    word: { zh: "零联网双拼", en: "零联网双拼 (Zero-Network Shuangpin)" },
    count: { zh: "21 键 · 标准全拼", en: "21 Taps · Full Pinyin" },
    keys: ["ling", "lian", "wang", "shuang", "pin"],
    space: "拼"
  },
  xiaohe: {
    word: { zh: "零联网双拼", en: "零联网双拼 (Xiaohe Shuangpin)" },
    count: { zh: "10 键 · 减少 52% 击键", en: "10 Taps · 52% Fewer Taps" },
    keys: ["lk", "lm", "wh", "ul", "pb"],
    space: "鹤"
  },
  ziranma: {
    word: { zh: "零联网双拼", en: "零联网双拼 (Ziranma Shuangpin)" },
    count: { zh: "10 键 · 减少 52% 击键", en: "10 Taps · 52% Fewer Taps" },
    keys: ["ly", "lm", "wh", "ud", "pn"],
    space: "自"
  }
};

const OPENCC_DEMOS = {
  sc: {
    sentence: "这款离线输入法内存占用极低，支持导入自定义词库。",
    diff: {
      zh: "所有个人记忆与上下文学习均以规范简体统一存储，切换输出标准不分裂词库。",
      en: "Personal lexicon and contextual learning stay unified in canonical Simplified internally—switching output never fragments your memory."
    }
  },
  tw: {
    sentence: "這款離線輸入法記憶體佔用極低，支援匯入自訂詞庫。",
    diff: {
      zh: "OpenCC s2twp 词级转换：内存 → 記憶體 · 支持 → 支援 · 导入 → 匯入 · 自定义 → 自訂",
      en: "OpenCC s2twp phrase conversion: 内存 → 記憶體 · 支持 → 支援 · 导入 → 匯入 · 自定义 → 自訂"
    }
  },
  hk: {
    sentence: "這款離線輸入法內存佔用極低，支持導入自定義詞庫。",
    diff: {
      zh: "OpenCC s2hk 港标字形转换，保留本机简体词库统一检索与自动学习",
      en: "OpenCC s2hk Hong Kong character standards backed by unified local lexicon indexing"
    }
  }
};

const I18N = {
  zh: {
    themeLight: "浅色",
    themeDark: "深色",
    navPack: "白霜包",
    heroKicker: "物理级零联网 · 18 份核心源码字节级可审计",
    heroTitle: "原生手感，零学习成本。<br />物理零联网的 iOS 中文输入法。",
    heroSub: "1:1 延续 iOS 26 原生手感与键位几何，零学习适应成本；内置自研「落墨 · Inkstone」输入引擎（26 键盲打热区自适应校准、双向神经网络长句语义、句内中英混输、OpenCC 词级简繁与本地自造词记忆），源码与二进制均不含任何网络框架或数据采集。",
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
    schTitle: "输入方案与 OpenCC 词级简繁",
    schSub: "全拼/小鹤/自然码即时切换 · 简体规范存储",
    schTabQP: "26 键全拼",
    schTabXH: "小鹤双拼",
    schTabZRM: "自然码双拼",
    ccTabSC: "简体中文",
    ccTabTW: "台灣正體",
    ccTabHK: "香港標準",
    swTitle: "极客细节开关与模糊音",
    swSub: "按顺手程度独立定制 · 不强迫任何改动",
    swChip: "App Group 同步",
    sw1Title: "首排按键上滑输入数字（Q–P → 1–0）",
    sw1Sub: "关闭时 Q–P 按下 0ms 即刻上屏；开启后支持上滑直出数字，不误触常规拼写",
    sw2Title: "空格左侧常驻句号键（。/ .）",
    sw2Sub: "高频句尾标点单手一键直达，不必反复切换符号页",
    sw3Title: "候选栏表情联想（哈哈 → 😂）",
    sw3Sub: "基于纯离线 Emoji 语义表实时伴随候选输出，支持一键开关",
    sw4Title: "自定义模糊音等价匹配",
    sw4Sub: "自由勾选平翘舌（zh/z、ch/c、sh/s）、前后鼻音及 n/l、f/h 等价规则",
    sw4Tag: "可独立开关",
    pipTitle: "落墨 · Inkstone 端侧离线引擎流水线",
    pipSub: "从物理触控落点到 120Hz 异步上屏的全链路纯本地计算",
    pipChip: "0 云端往返",
    pip1Title: "触控坐标采集",
    pip1Desc: "捕获真实键帽落点 (x, y) 与边缘防误触时序",
    pip2Title: "2×2 热区校准",
    pip2Desc: "按个人双拇指斜角椭圆实时微调热区（±20%）",
    pip3Title: "增量混输晶格",
    pip3Desc: "维特比解码统一权衡汉语拼音与英文短词路径",
    pip4Title: "双向神经重排",
    pip4Desc: "LNLM-v2 前向 + LNBR-v2 逆向 + 64 维话题记忆",
    pip5Title: "120Hz 异步上屏",
    pip5Desc: "气泡响应先于宿主提交，零 XPC 阻塞不掉帧",
    pipB1Title: "只读 mmap 零脏堆",
    pipB1Desc: "词典与神经权重直接只读内存映射，稳居 iOS 键盘扩展严苛内存红线以下",
    pipB2Title: "touchesBegan 零阻塞",
    pipB2Desc: "全异步合并提交 MarkedText，快速盲打时键帽反馈与候选项互不拖累",
    pipB3Title: "密码框自动隔离",
    pipB3Desc: "识别系统 isSecureTextEntry 标记后自动暂停自造词学习与一切日志记录",
    cmpKicker: "横向对比",
    cmpTitle: "为什么选择 Lokey：原生、云端第三方与 Lokey 对比",
    cmpSub: "既不牺牲系统键盘多年积累的手指肌肉记忆，也不用把日常隐私交给黑盒联网服务。",
    cmpColDim: "对比维度",
    cmpColStock: "iOS 系统自带",
    cmpColCloud: "传统联网第三方",
    cmpR1K: "物理零联网与可审计",
    cmpR1L: "0 网络框架 / 0 Socket · 核心源码字节级公开",
    cmpR1S: "系统闭源组件",
    cmpR1C: "普遍联网与云端候选",
    cmpR2K: "关闭「允许完全访问」",
    cmpR2L: "100% 离线满血整句与简繁输出",
    cmpR2S: "系统内置权限",
    cmpR2C: "功能降级或无法同步",
    cmpR3K: "iOS 26 原生手感",
    cmpR3L: "1:1 液态玻璃几何，零学习适应成本",
    cmpR3S: "原生手感基准",
    cmpR3C: "键位比例与动效常有偏移",
    cmpR4K: "盲打纠错与热区学习",
    cmpR4L: "26 键 2×2 高斯可视化热区 + 双向神经重排",
    cmpR4S: "黑盒纠错 · 无个人热区视图",
    cmpR4C: "多依赖云端模型纠错",
    cmpR5K: "外置词库与数据迁移",
    cmpR5L: "只读 mmap .lokeypack + Rime 双向迁移",
    cmpR5S: "封闭词库 · 不支持导入",
    cmpR5C: "多为专有云账号同步",
    cmpR6K: "商业模式与隐私边界",
    cmpR6L: "零广告 · 零订阅 · 核心打字永久免费",
    cmpR6S: "系统附带免费",
    cmpR6C: "常见皮肤广告或会员订阅",
    memTitle: "本机 SQLite 自造词记忆机制",
    memSub: "只记常用好词 · 不被误选词长期干扰",
    mem1Title: "分步选词自动记住个人短语",
    mem1Sub: "日常分步拼合的人名、术语与常用词自动存于 App Group 本地 SQLite，自动过滤口语短句污染",
    mem2Title: "21 天时间遗忘曲线",
    mem2Sub: "自造词权重随时间平滑半衰衰减，高频常用词稳居前排，临时词汇自然淡出",
    mem3Title: "曝光跳过自动降权",
    mem3Sub: "展示于前位却屡次未被选中的冗余自造词自动降权让位，绝不抢占日常首选",
    mem4Title: "候选栏长按一键忘词",
    mem4Sub: "在键盘候选栏或展开面板长按即可直接删除，主应用亦支持检索与左滑清理",
    sovTitle: "数据主权与 Rime 双向迁移",
    sovSub: "纯离线导出带走一切积累 · 零厂商锁定",
    sov1Title: "导出完整迁移包（.lokeybackup）",
    sov1Sub: "打包个人 SQLite 词库与 26 键触控校准模型，无需 iCloud 即可无损换机恢复",
    sov2Title: "导出标准 Rime 词表（.userdb.txt）",
    sov2Sub: "个人词汇可随时导出为开放纯文本格式，与桌面 Rime 体系互通不锁死",
    sov3Title: "独立导出触控热区校准状态（.json）",
    sov3Sub: "单独导出或检视个人 26 键拇指落点均值与斜角协方差状态",
    sov4Title: "纯离线导入个人 Rime 词表",
    sov4Sub: "支持 .dict.yaml / .userdb.txt / .txt，自动去重合并并防止低频导入词霸占日常首选",
    prcKicker: "免费边界与买断说明",
    prcTitle: "核心打字体验永久免费，绝不阉割基础手感",
    prcSub: "不做订阅制、不强制注册账号、不插播广告。所有日常输入所需核心能力对全部用户免费开放，仅高效扩展工具采用一次性买断。",
    freeTitle: "核心体验 · 永久免费",
    freeChip: "零广告 · 零账号 · 开箱主力可用",
    freeSub: "不设任何“试打字数限制”或弹出广告，装好即可完整作为日常主力中文键盘：",
    freeLi1: "26 键全拼、小鹤双拼与自然码双拼完整支持",
    freeLi2: "内置 50.6 万+ 纯净基础词库、端侧双向神经整句与盲打邻键纠错",
    freeLi3: "OpenCC 简体 / 台灣正體 / 香港標準词级实时切换与自定义模糊音",
    freeLi4: "日常自动记词、主应用查看删改与候选栏长按一键忘词",
    freeLi5: "CoreHaptics 无级线性震动、三档原生按键音与物理级零联网隔离",
    proTitle: "Lokey Pro 永久解锁",
    proSub: "纯本地效率进阶 · 买断制独立软件",
    proP1: "一次性买断",
    proP2: "支持家人共享",
    proP3: "零订阅 · 零账号",
    pro1Title: "外部 .lokeypack 词库扩展引擎",
    pro1Sub: "解锁只读零拷贝 mmap 外置词库槽位，本地校验热挂载白霜包或自定义领域包",
    pro2Title: "26 键个人拇指热区自适应校准",
    pro2Sub: "随日常打字拟合逐键落点偏移与双拇指斜角椭圆（±20%），点亮个人实测热区图",
    pro3Title: "Rime 个人词库导入与 .lokeybackup 备份",
    pro3Sub: "导入 Rime .dict.yaml / .userdb.txt，一键导出与恢复完整个人词库及热区模型",
    proFoot: "由 Apple App Store 在设备本地校验买断凭证，不接入任何第三方支付或统计 SDK；键盘扩展进程不链接 StoreKit，始终保持 0 网络框架。",
    faqKicker: "常见问题",
    faqTitle: "关于隐私、手感与词库的几个直接回答",
    fq1Q: "1. 不开启「允许完全访问」能用哪些功能？开启后会偷偷联网吗？",
    fq1A: "关闭「允许完全访问」时，26 键全拼与双拼整句、内置纯净词库、OpenCC 简繁切换、盲打邻键纠错与 Emoji 联想已 100% 离线可用。开启该权限也仅用于本机 App Group 共享容器内的偏好同步、SQLite 自造词、外部 .lokeypack 热挂载与 CoreHaptics 震动——因为宿主与键盘扩展的源码及二进制中均不含任何网络框架或 Socket 符号，物理上不具备联网能力。",
    fq2Q: "2. 目前支持哪些 iOS 屏幕尺寸与拼音方案？切过来需要学新手势吗？",
    fq2A: "支持 Max/Plus（268.5pt）、Pro/标准（250.0pt）、Mini/SE（239.0pt）与横屏（197.5pt）四档屏幕自适应高度，内置 26 键全拼、小鹤双拼与自然码双拼。手势与光学布局沿用 iOS 原生肌肉记忆（如长按空格移光标、左滑 ⌫ 清空待上屏句、数字时间自动半角），几乎零适应成本。",
    fq3Q: "3. 完全不联网怎么做到长句识别和盲打纠错？会不会耗电或内存闪退？",
    fq3A: "所有词典索引与轻量化端侧模型均随安装包或本地 .lokeypack 以只读 mmap 零拷贝方式挂载，不解压占堆内存、稳居 iOS 键盘扩展严苛内存上限之内；落墨引擎结合 26 键触控坐标、前向/逆向双向神经重排与 64 维话题记忆全部在本地 CPU 高效运行，无后台网络唤醒耗电。",
    fq4Q: "4. 如何导入 55.3 万词白霜扩展包或我自己的 Rime 词库？",
    fq4A: "从 Kianuni/lokey-frost-pack 下载预编译 rime-frost.lokeypack（或用自带零依赖 Python 3 编译器配合 --extra-dict 自行打包）存至 iPhone「文件」App 或隔空投送，选择「用 Lokey 打开」或从「词库数据 → 导入外部 .lokeypack」选取即可本机校验挂载；Rime .dict.yaml / .userdb.txt 也可在「个人词库」中纯离线导入。",
    fq5Q: "5. 怎样自己独立验证 Lokey 真的没有任何联网代码？",
    fq5A: "Kianuni/Lokey-Audit 仓库中 Shared/Engine（12 个文件）与 KeyboardExtension（6 个文件）保持 100% 字节级一致。你可以在 Mac 终端克隆仓库运行 ./scripts/audit_zero_network.sh --source-only，并用 xcodebuild test 编译出产物后运行 ./scripts/audit_zero_network.sh build/DerivedData，或亲自执行 otool -L 与 nm -u 核验全部导入符号。",
    footerBy: "由",
    footerPrivacy: "隐私政策 / Privacy",
    footerEco: "Kianuni 苹果生态工具矩阵：",
    toastCopied: "已复制到剪贴板"
  },
  en: {
    themeLight: "Light",
    themeDark: "Dark",
    navPack: "Frost Pack",
    heroKicker: "Physically Zero-Network · 18 Core Files Byte-Auditable",
    heroTitle: "Native iOS Feel, Zero Learning Curve.<br />Physically Zero-Network Chinese Keyboard.",
    heroSub: "Preserves 1:1 native iOS 26 ergonomics and geometry with zero learning curve. Powered on-device by the Inkstone engine (adaptive 26-key blind-typing heatmap calibration, bidirectional neural sentence semantics, inline CN-EN mixed input, word-level OpenCC conversion, and local user-phrase memory) with zero networking frameworks or data collection in source or binary.",
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
    schTitle: "Input Schemes & Word-Level OpenCC",
    schSub: "Live Full Pinyin / Xiaohe / Ziranma · Unified Canonical Storage",
    schTabQP: "26-Key Full",
    schTabXH: "Xiaohe",
    schTabZRM: "Ziranma",
    ccTabSC: "Simplified",
    ccTabTW: "TW (s2twp)",
    ccTabHK: "HK (s2hk)",
    swTitle: "Ergonomic Switches & Fuzzy Pinyin",
    swSub: "Optional fine-tuning without altering stock muscle memory",
    swChip: "App Group Sync",
    sw1Title: "Top-Row Flick Up for Digits (Q–P → 1–0)",
    sw1Sub: "Keep OFF for 0ms keystroke commit, or turn ON to flick digits directly from QWERTY top row",
    sw2Title: "Dedicated Period Beside Space (. / 。)",
    sw2Sub: "Reach sentence-ending punctuation one-handed without hopping symbol layers",
    sw3Title: "Candidate Emoji Suggestions (haha → 😂)",
    sw3Sub: "Offline Emoji semantic suggestions alongside Chinese candidates, toggleable anytime",
    sw4Title: "Custom Fuzzy Pinyin Equivalences",
    sw4Sub: "Independently toggle zh/z, ch/c, sh/s, an/ang, en/eng, in/ing, n/l, and f/h equivalences",
    sw4Tag: "Per-Rule",
    pipTitle: "Inkstone On-Device Engine Pipeline",
    pipSub: "End-to-end strictly local processing from physical touch to 120Hz text commit",
    pipChip: "0 Cloud Trips",
    pip1Title: "Touch Coordinates",
    pip1Desc: "Captures true keycap (x, y) landings & anti-edge timing",
    pip2Title: "2×2 Heatmap Calib",
    pip2Desc: "Applies thumb-ellipse covariance clamped within ±20%",
    pip3Title: "CN-EN Lattice",
    pip3Desc: "Incremental Viterbi unifies Chinese syllables & English tokens",
    pip4Title: "Bidirectional Neural",
    pip4Desc: "LNLM-v2 forward + LNBR-v2 backward + 64-dim topic memory",
    pip5Title: "120Hz Async Commit",
    pip5Desc: "Keycap popups fire ahead of host commit with zero XPC stall",
    pipB1Title: "Read-Only mmap Zero Heap",
    pipB1Desc: "Lexicon and weights stay memory-mapped well under iOS keyboard extension RAM limits",
    pipB2Title: "Zero touchesBegan Stalls",
    pipB2Desc: "Asynchronous MarkedText coalescing keeps rapid blind typing fluid at 120Hz",
    pipB3Title: "Secure-Field Isolation",
    pipB3Desc: "Automatically halts personal learning and logging whenever isSecureTextEntry is set",
    cmpKicker: "Side-by-Side",
    cmpTitle: "Why Switch: Lokey vs Stock iOS vs Cloud Third-Party",
    cmpSub: "Keep years of native iOS thumb muscle memory without surrendering keystrokes to black-box servers.",
    cmpColDim: "Dimension",
    cmpColStock: "Stock iOS Keyboard",
    cmpColCloud: "Cloud Third-Party",
    cmpR1K: "Zero-Network & Auditability",
    cmpR1L: "0 network frameworks / 0 sockets · Byte-auditable core",
    cmpR1S: "Closed system binary",
    cmpR1C: "Cloud lookups & telemetry common",
    cmpR2K: "Allow Full Access OFF",
    cmpR2L: "100% offline sentences & OpenCC intact",
    cmpR2S: "Built into OS",
    cmpR2C: "Features degrade or stop syncing",
    cmpR3K: "iOS 26 Native Ergonomics",
    cmpR3L: "1:1 Liquid Glass geometry, zero learning curve",
    cmpR3S: "Native baseline",
    cmpR3C: "Altered keycap ratios & animations",
    cmpR4K: "Blind-Type & Heatmap",
    cmpR4L: "Visible 26-key Gaussian heatmap + bidirectional rerank",
    cmpR4S: "Opaque correction · no calibration map",
    cmpR4C: "Often relies on cloud correction",
    cmpR5K: "Lexicon & Data Portability",
    cmpR5L: "Zero-copy mmap .lokeypack + Rime two-way import/export",
    cmpR5S: "Closed dictionary · no imports",
    cmpR5C: "Proprietary cloud account formats",
    cmpR6K: "Monetization & Ad Hygiene",
    cmpR6L: "Zero ads · Zero subscriptions · Core typing free forever",
    cmpR6S: "Included with OS",
    cmpR6C: "Theme ads or recurring VIP plans",
    memTitle: "On-Device SQLite Personal Memory",
    memSub: "Remembers phrases you actually want · drops slips cleanly",
    mem1Title: "Auto-Learns Step-Picked Phrases",
    mem1Sub: "Stores custom names, jargon, and frequent phrases locally in App Group SQLite while filtering multi-word noise",
    mem2Title: "21-Day Forgetting Curve",
    mem2Sub: "Recency scores decay smoothly over time so active everyday terms stay on top",
    mem3Title: "Skipped-Exposure Demotion",
    mem3Sub: "Redundant learned items repeatedly shown and skipped yield priority automatically",
    mem4Title: "Long-Press Candidate Forget",
    mem4Sub: "Long-press any personal entry right in the candidate bar or swipe to delete inside the app",
    sovTitle: "Data Sovereignty & Two-Way Rime",
    sovSub: "Export everything cleanly offline · zero lock-in",
    sov1Title: "Full Migration Archive (.lokeybackup)",
    sov1Sub: "Bundles personal SQLite lexicon and 26-key calibration model for lossless offline device transfers",
    sov2Title: "Standard Rime Export (.userdb.txt)",
    sov2Sub: "Take your entire personal vocabulary with you anytime in standard open Rime text format",
    sov3Title: "Standalone Heatmap Export (.json)",
    sov3Sub: "Inspect or archive your 26-key per-key mean offsets and ellipse covariance independently",
    sov4Title: "Offline Rime Lexicon Import",
    sov4Sub: "Imports .dict.yaml / .userdb.txt / .txt with automatic deduplication and safe daily-word weighting",
    prcKicker: "Fair Boundary",
    prcTitle: "Core Typing Experience Is Free Forever—Zero Handicaps",
    prcSub: "No subscriptions, no login walls, and no ads. Every daily typing capability is free permanently; Pro is an optional one-time purchase.",
    freeTitle: "Core Experience · Free Forever",
    freeChip: "0 Ads · 0 Accounts · Daily-Driver Ready",
    freeSub: "No trial character caps or nag dialogs—ready as your primary iOS keyboard out of the box:",
    freeLi1: "Full support for 26-key Pinyin, Xiaohe Shuangpin & Ziranma Shuangpin",
    freeLi2: "Built-in 506k+ clean lexicon, bidirectional neural decoding & blind-typing typo recovery",
    freeLi3: "Live OpenCC Simplified / TW / HK word-level conversion & custom fuzzy Pinyin rules",
    freeLi4: "Local auto-learned phrases, in-app browsing, and long-press forget in candidate bar",
    freeLi5: "Continuous CoreHaptics slider, native key clicks & physically zero-network isolation",
    proTitle: "Lokey Pro Lifetime Unlock",
    proSub: "Local power tools · One-time indie purchase",
    proP1: "One-Time Purchase",
    proP2: "Family Sharing",
    proP3: "No Subscription",
    pro1Title: "External .lokeypack Lexicon Engine",
    pro1Sub: "Unlocks read-only zero-copy mmap external slots to hot-mount Rime-Frost or custom packs",
    pro2Title: "26-Key Adaptive Thumb Calibration",
    pro2Sub: "Fits per-key thumb offsets and 2×2 ellipse covariance (±20%) with live heatmap inspection",
    pro3Title: "Rime Import & .lokeybackup Transfers",
    pro3Sub: "Imports Rime .dict.yaml / .userdb.txt and exports/restores full personal dictionaries & calibration",
    proFoot: "Validated locally via Apple App Store (StoreKit 2) with zero third-party payment or analytics SDKs. The keyboard extension itself never links StoreKit and stays 0-network.",
    faqKicker: "FAQ",
    faqTitle: "Straight Answers on Privacy, Feel & Lexicons",
    fq1Q: "1. What works with Allow Full Access OFF, and can it go online if turned ON?",
    fq1A: "With Allow Full Access OFF, 26-key Full Pinyin/Shuangpin sentences, the built-in clean lexicon, OpenCC conversion, blind-typing correction, and Emoji lookup all work 100% offline. Turning it ON strictly enables local App Group settings sync, SQLite user phrases, .lokeypack mounting, and CoreHaptics—both host app and keyboard binaries contain zero networking frameworks or sockets.",
    fq2Q: "2. Which screen sizes and Pinyin schemes are supported? Is there a learning curve?",
    fq2A: "Supports Max/Plus (268.5pt), Pro/Standard (250.0pt), Mini/SE (239.0pt), and Landscape (197.5pt) geometry across 26-key Full Pinyin, Xiaohe Shuangpin, and Ziranma Shuangpin. Muscle memory follows stock iOS gestures (Space cursor scrubbing, swipe-left ⌫ clear, smart half-width URLs/times).",
    fq3Q: "3. How does offline sentence reranking avoid high RAM or battery drain?",
    fq3A: "All lexicons and compact weights mount read-only via zero-copy mmap without decompressing onto the heap, staying comfortably below strict iOS keyboard extension Jetsam memory limits while executing purely on local CPU with zero background network wakeups.",
    fq4Q: "4. How do I load the 553k Rime-Frost pack or my own Rime dictionary?",
    fq4A: "Download rime-frost.lokeypack from Kianuni/lokey-frost-pack Releases (or compile custom .dict.yaml packs offline via the Python 3 compiler), save to iOS Files or AirDrop, and pick Open in Lokey or Lexicon Data → Import .lokeypack. Standard Rime .dict.yaml / .userdb.txt files can also be imported offline.",
    fq5Q: "5. How can I verify zero networking code myself?",
    fq5A: "All 18 Swift files under Shared/Engine (12) and KeyboardExtension (6) in Kianuni/Lokey-Audit match SHA-256 byte-for-byte. Clone the repo and run ./scripts/audit_zero_network.sh --source-only, build/test via xcodebuild, and run ./scripts/audit_zero_network.sh build/DerivedData or otool -L / nm -u directly.",
    footerBy: "Crafted by",
    footerPrivacy: "Privacy Policy",
    footerEco: "Kianuni Apple Ecosystem:",
    toastCopied: "Copied to clipboard"
  }
};

let currentLang = "zh";
let currentCase = "typo";
let currentScheme = "quanpin";
let currentOpencc = "sc";
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
  renderSchemeLab();
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

function renderSchemeLab() {
  const item = SCHEME_DEMOS[currentScheme];
  const wordEl = document.getElementById("schemeTargetWord");
  const countEl = document.getElementById("schemeKeyCount");
  const capsEl = document.getElementById("schemeKeycaps");
  if (!wordEl || !countEl || !capsEl) return;

  const dark = isEffectiveDark();
  wordEl.textContent = item.word[currentLang];
  countEl.textContent = item.count[currentLang];

  capsEl.innerHTML = "";
  item.keys.forEach((code) => {
    const cap = document.createElement("span");
    cap.className = "keycap " + (dark ? "keycap-charcoal" : "keycap-ivory");
    cap.textContent = code;
    capsEl.appendChild(cap);
  });

  const sp = document.createElement("span");
  sp.id = "schemeSpaceBadge";
  sp.className = "scheme-space-badge";
  sp.textContent = item.space;
  capsEl.appendChild(sp);
}

function renderOpenccLab() {
  const item = OPENCC_DEMOS[currentOpencc];
  const sentEl = document.getElementById("openccSentence");
  const diffEl = document.getElementById("openccDiff");
  if (!sentEl || !diffEl) return;
  sentEl.textContent = item.sentence;
  diffEl.textContent = item.diff[currentLang];
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
  renderSchemeLab();
  renderOpenccLab();
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

  document.querySelectorAll("[data-scheme]").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll("[data-scheme]").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      currentScheme = btn.getAttribute("data-scheme");
      renderSchemeLab();
    });
  });

  document.querySelectorAll("[data-opencc]").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll("[data-opencc]").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      currentOpencc = btn.getAttribute("data-opencc");
      renderOpenccLab();
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
