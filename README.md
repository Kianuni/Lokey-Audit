# Lokey-Audit (v0.8.1 · Build 70)

**Lokey Security Audit Repository · 纯离线零联网安全审计仓库**

[中文说明](#中文说明) | [English](#english)

---

## 中文说明

`Lokey-Audit` 是 **Lokey**（iOS 26 键全拼离线输入法）的公开安全审计仓库，用于让安全研究者与用户独立验证键盘扩展的**物理级零联网隔离**、**隐私清单（Privacy Manifest）** 与**纯本地全拼解码逻辑**。

### 审计范围与源码一致性

- **`Shared/Engine/*.swift`（12 个文件）与 `KeyboardExtension/**/*.swift`（6 个文件）**：与商业版 `Lokey` 主仓库 **100% 字节级一致（SHA-256 完全匹配）**，未做任何删改或脱敏隐藏。
- **`AuditDemoApp/`**：极简 SwiftUI 宿主壳应用，仅保留键盘启用状态检测、实时试打沙盒、系统设置引导与零联网声明；省略了商业版的 `.lokeypack` 外部词库管理器、Rime 个人词库导入 UI、诊断日志浏览与 `build_ipa.sh` 打包脚本。
- **`Shared/Resources/`**：仅包含由 `scripts/build_demo_lexicon.py` 离线编译的最小化开放许可示范词库（`demo_lexicon.bin`约 4,000 词条 + 未调优中性 `LNLM-v2` 占位权重，覆盖全部 416 个标准汉语拼音音节）、最小化 `lokey_emoji.bin` 与 `lokey_opencc.bin`（不含商业版训练权重、`target-deltas.tsv`/`commit-deltas.tsv` 与 `lokey_spelling.bin`，完全不含 GPL/LGPL 数据）。构建时由 Xcode Build Phase 将 `demo_lexicon.bin` 复制为包内的 `lokey_lexicon.bin`，从而在不改动任何核心引擎 Swift 源码的前提下完成完整编译与测试。

### 快速审计与本地验证

#### 1. 源码级零联网审计
```zsh
./scripts/audit_zero_network.sh --source-only
```
扫描 `AuditDemoApp/`、`KeyboardExtension/`、`Shared/Engine/` 是否存在任何 `Network`/`CFNetwork`/`WebKit`/`SafariServices` 导入、`URLSession`/`NWConnection`/`CFSocket` 调用或 POSIX `socket`/`connect`/`getaddrinfo` 调用，并校验 `Info.plist` 与 `.entitlements`（确保无 `NSAppTransportSecurity`、`UIBackgroundModes`、`aps-environment` 等权限，仅保留 `group.com.kianuni.lokey`）。

#### 2. 生成工程并运行模拟器全量测试
```zsh
# 可选：离线或使用本地/拉取的开放许可语料重编示范词库
python3 scripts/build_demo_lexicon.py

# 生成 LokeyAudit.xcodeproj
python3 scripts/generate_xcodeproj.py

# 运行 XCTest（包含 Mach-O 二进制零联网审计、PrivacyInfo、全拼解码、hasFullAccess==false 离线测试与 VC 生命周期测试）
xcodebuild test \
  -project LokeyAudit.xcodeproj \
  -scheme LokeyAudit \
  -derivedDataPath build/DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

#### 3. 构建产物 Mach-O 二进制与 `.debug.dylib` 审计
```zsh
# 自动检查 build/DerivedData 下所有 .app 与 .appex 的 <Exec> 及 <Exec>.debug.dylib
./scripts/audit_zero_network.sh build/DerivedData
```

或手动执行 `otool -L` / `nm -u` / `codesign` 核验：
```zsh
APP_DIR="build/DerivedData/Build/Products/Debug-iphonesimulator/AuditDemoApp.app"
EXT_DIR="$APP_DIR/PlugIns/LokeyKeyboard.appex"

# 检查动态库依赖（0 个网络框架）
otool -L "$EXT_DIR/LokeyKeyboard"
otool -L "$EXT_DIR/LokeyKeyboard.debug.dylib"

# 检查未定义导入符号（0 个 Socket / URLSession / NWConnection 符号）
nm -u "$EXT_DIR/LokeyKeyboard" | grep -E 'socket|connect|getaddrinfo|URLSession|NWConnection|CFNetwork' || echo "0 network symbols"
nm -u "$EXT_DIR/LokeyKeyboard.debug.dylib" | grep -E 'socket|connect|getaddrinfo|URLSession|NWConnection|CFNetwork' || echo "0 network symbols"

# 检查内嵌权限
codesign -d --entitlements - --xml "$EXT_DIR"
```

### 许可声明
- 本仓库代码采用 **Source-Available Security Audit License**（见根目录 `LICENSE`）：允许出于安全审计与本地测试目的进行源码查阅、编译与测试，**禁止分发 `.ipa`/二进制安装包或用于商业/App Store 重新上架**。
- 示范词库使用的开放许可上游数据声明见 `LICENSES/`（`rime-pinyin-simp` Apache-2.0、`OpenCC` Apache-2.0、`Unicode Unihan & CLDR` Unicode-3.0）。

---

## English

`Lokey-Audit` is the source-available security audit repository for **Lokey** (an offline iOS 26-key Full-Pinyin keyboard). It allows researchers and users to independently verify physical zero-network isolation, Apple Privacy Manifest declarations, and offline Pinyin decoding behavior.

### Architecture & Source Parity

- **`Shared/Engine/*.swift` (12 files) & `KeyboardExtension/**/*.swift` (6 files)**: **100% byte-for-byte identical (matching SHA-256)** to the commercial `Lokey` repository, with zero redactions.
- **`AuditDemoApp/`**: Minimal SwiftUI host shell providing keyboard activation status, a live typing sandbox, iOS Settings onboarding, and zero-network documentation. Commercial `.lokeypack` pack management, Rime importer UI, diagnostic viewer, and `build_ipa.sh` are omitted.
- **`Shared/Resources/`**: Contains minimal permissive demonstration binaries compiled by `scripts/build_demo_lexicon.py`:
  - `demo_lexicon.bin`: ~4,000 permissive entries covering all 416 canonical Mandarin syllables, basic English words, clean next-word bigrams, and un-tuned neutral `LNLM-v2` weights (zero commercial `target-deltas.tsv`/`commit-deltas.tsv`, zero `lokey_spelling.bin`, zero GPL/LGPL data). Copied as `lokey_lexicon.bin` inside built app/extension/test bundles at build time so all engine & keyboard `.swift` files stay byte-identical.
  - `lokey_emoji.bin` & `lokey_opencc.bin`: Minimal permissive Emoji (`CLDR` Unicode-3.0) and OpenCC (`BYVoid/OpenCC` Apache-2.0) tables.

### Audit & Verification Commands

1. **Source & Manifest Audit**:
   ```zsh
   ./scripts/audit_zero_network.sh --source-only
   ```
2. **Regenerate Project & Run XCTest Suite**:
   ```zsh
   python3 scripts/build_demo_lexicon.py
   python3 scripts/generate_xcodeproj.py
   xcodebuild test \
     -project LokeyAudit.xcodeproj \
     -scheme LokeyAudit \
     -derivedDataPath build/DerivedData \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
   ```
3. **Built Mach-O & `.debug.dylib` Audit**:
   ```zsh
   ./scripts/audit_zero_network.sh build/DerivedData
   ```
   Or manually inspect with `otool -L`, `nm -u`, and `codesign -d --entitlements - --xml` on both `<Exec>` and `<Exec>.debug.dylib` inside `AuditDemoApp.app` and `AuditDemoApp.app/PlugIns/LokeyKeyboard.appex`.

### License
- Repository source code is governed by the **Source-Available Security Audit License** (`LICENSE`), permitting security inspection and local build/test verification while prohibiting `.ipa`/binary redistribution and commercial/App Store republishing.
- Permissive upstream data attributions for `demo_lexicon.bin`, `lokey_emoji.bin`, and `lokey_opencc.bin` are included in `LICENSES/`.
