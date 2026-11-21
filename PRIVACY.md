# 隐私政策 / Privacy Policy — Lokey（落键）

**生效与更新日期 / Effective & Updated Date**：2026-11-21  
**联系邮箱 / Contact Email**：[Kianuni60@gmail.com](mailto:Kianuni60@gmail.com)  
**安全审计仓库 / Public Security Audit Repository**：<https://github.com/Kianuni/Lokey-Audit>

[中文版](#中文版) | [English](#english)

---

## 中文版

欢迎使用 **Lokey（落键）**（宿主应用 Bundle ID：`com.kianuni.lokey`，键盘扩展 Bundle ID：`com.kianuni.lokey.keyboard`）。

Lokey 是一款**纯离线、物理级零联网**的 iOS 26 键拼音输入法。我们高度重视您的输入隐私，本隐私政策清晰说明 Lokey 如何处理（以及绝不收集）您的数据。

### 1. 零数据收集与物理级零联网承诺
- **不收集、不传输任何个人数据**：Lokey **不会**收集、存储于远端、上传、出售或与任何第三方共享您的击键内容、输入文本、个人自造词、触控校准数据、设备标识符、位置信息或使用遥测。
- **物理零联网架构**：无论是否开启「允许完全访问」，Lokey 宿主应用与键盘扩展在源码与编译后 Mach-O 二进制层面均**不含** `Network`、`CFNetwork`、`WebKit`、`SafariServices` 等网络框架，也不调用 `URLSession`、`NWConnection`、`CFSocket` 或 POSIX `socket`/`connect`/`getaddrinfo` 等系统网络符号，亦不包含任何云端服务器或统计 SDK。
- **公开可审计**：您可通过公开安全审计仓库 <https://github.com/Kianuni/Lokey-Audit> 独立编译并审计全部核心引擎与键盘扩展源码，验证物理零联网隔离与隐私清单配置。

### 2. 安全输入框与敏感内容保护
- 当您在密码、验证码或系统标记为安全文本输入（`isSecureTextEntry`）的输入框中打字时，Lokey 自动触发安全字段保护策略：不进行个人词库学习，不记录诊断或选词反馈日志，也不将内容写入共享容器持久化存储。

### 3. 为什么请求「允许完全访问（Allow Full Access）」？（仅限本机跨进程同步）
在 iOS 中，「允许完全访问」本身只是开启跨进程系统能力的系统权限开关，并不代表必须联网：
- **关闭「允许完全访问」（默认即可使用核心功能）**：26 键全拼整句引擎、内置开放许可词库、简繁转换（OpenCC）及 Emoji 候选联想均 **100% 离线正常运行**。
- **开启「允许完全访问」（按需可选）**：Lokey **仅将此权限用于本机设备内部的沙盒共享容器（App Group：`group.com.kianuni.lokey`）跨进程数据读写与硬件触感，绝不会发起任何网络通信**。具体仅用于：
  1. 在宿主 App 与键盘扩展之间本机同步您的输入设置（方案、模糊音、按键音与震动强度等）；
  2. 读写本机 SQLite 个人常用词/自造词库及 26 键盲打热区校准参数；
  3. 热挂载您手动导入的外部 `.lokeypack` 词库包或恢复 `.lokeybackup` 备份；
  4. 调用 `CoreHaptics` 细腻线性马达震动与按键音效；
  5. 若您主动开启诊断日志/选词纠偏反馈开关，仅在设备本地循环缓冲保存近期统计信息，供您本人在 App 内自行查看或复制导出，不会自动发送给任何人。

### 4. 本机数据存储与您的完全控制权
所有配置与学习记录（包括 SQLite 个人记忆词库、触控热区偏移矩阵及可选诊断缓存）均**仅存储在您的 iOS 设备本地沙盒与本机 App Group 容器内**。您可以随时：
- **单条/即时删除**：在键盘候选栏或展开面板长按自选词/自造词直接删除，或在宿主 App「词库数据 → 本地常用与自造词库」左滑删除；
- **重置与清空**：一键重置 26 键触控热区校准、清空全部个人词库或本地日志；
- **迁移与导出**：随时导出 `.lokeybackup` 个人备份或自行删除本机副本；
- **彻底清除**：从设备卸载 Lokey 后，系统将移除其应用沙盒及关联的本机存储数据。

### 5. Apple 隐私清单（Privacy Manifest / `PrivacyInfo.xcprivacy`）声明
根据 Apple Privacy Manifest 规范，Lokey 宿主 App 与键盘扩展均显式声明：
- **跨应用追踪（`NSPrivacyTracking`）**：`false`（无追踪域名 `NSPrivacyTrackingDomains = []`）；
- **收集数据类型（`NSPrivacyCollectedDataTypes`）**：`[]`（零收集）；
- **Required Reason API 仅用于本机功能**：
  - `NSPrivacyAccessedAPICategoryUserDefaults`（`CA92.1`、`1C8F.1`）：在本机及 App Group 容器内读写输入法偏好与设置；
  - `NSPrivacyAccessedAPICategoryFileTimestamp`（`C617.1`）：检测本机 `.lokeypack` 词库包或共享缓存文件更新时间；
  - `NSPrivacyAccessedAPICategorySystemBootTime`（`35F9.1`）：基于本机绝对时间戳计算按键响应耗时与抖动状态，绝不用于设备指纹识别；
  - `NSPrivacyAccessedAPICategoryActiveKeyboards`（`3EC4.1`，仅宿主 App）：向您展示系统设置中是否已启用 Lokey 键盘以便引导激活。

### 6. 第三方 SDK、广告与儿童隐私
- **无第三方 SDK**：Lokey 未集成任何第三方广告、数据分析、崩溃上报或归因追踪 SDK。
- **儿童隐私**：由于 Lokey 不收集、不上传任何个人或设备数据，我们不会收集包括未满 13 岁（或您所在司法管辖区规定年龄）儿童在内的任何用户个人信息。

### 7. 隐私政策更新与联系我们
如因功能演进需要对本隐私政策进行修订，我们将在本页面更新生效日期并保持零收集、零联网的核心原则不变。若您对本政策或 Lokey 的离线安全机制有任何疑问、建议或数据隐私咨询，请联系：
- **联系邮箱**：[Kianuni60@gmail.com](mailto:Kianuni60@gmail.com)
- **审计源码仓库**：<https://github.com/Kianuni/Lokey-Audit>

---

## English

Thank you for using **Lokey** (Host App Bundle ID: `com.kianuni.lokey`; Keyboard Extension Bundle ID: `com.kianuni.lokey.keyboard`).

Lokey is an **offline-only, physically zero-network** iOS 26-key Pinyin keyboard. Protecting your typing privacy is our foundational design principle. This Privacy Policy explains what data Lokey processes locally on your device—and confirms what it never collects.

### 1. Zero Data Collection & Physical Zero-Network Isolation
- **No Collection or Transmission**: Lokey **never** collects, uploads, stores remotely, sells, or shares your keystrokes, typed text, personal phrases, touch-calibration profiles, device identifiers, location data, or usage telemetry with us or any third party.
- **Physically Air-Gapped Binary**: Both the Lokey host app and keyboard extension contain **zero** networking frameworks (`Network`, `CFNetwork`, `WebKit`, `SafariServices`), **zero** network APIs (`URLSession`, `NWConnection`, `CFSocket`), and **zero** POSIX socket symbols (`socket`, `connect`, `getaddrinfo`, etc.) at both source and compiled Mach-O binary levels.
- **Publicly Auditable**: Anyone can inspect the engine & keyboard source parity and run zero-network Mach-O verification scripts in our source-available security audit repository: <https://github.com/Kianuni/Lokey-Audit>.

### 2. Secure Text Field Protection
- When typing inside password, verification code, or system-marked secure text fields (`isSecureTextEntry`), Lokey automatically suppresses personal lexicon learning, diagnostic logging, and selection-feedback recording.

### 3. Why "Allow Full Access" May Be Requested (On-Device Only)
On iOS, "Allow Full Access" enables inter-process sandbox capabilities on your device and does not mean an app connects to the internet:
- **With Full Access OFF (Core Functionality Ready)**: The 26-key full-sentence Pinyin engine, built-in permissive lexicon, Simplified/Traditional conversion (OpenCC), and Emoji candidates work **100% offline**.
- **With Full Access ON (Optional, Strictly On-Device)**: Lokey uses this capability **exclusively for local on-device App Group container (`group.com.kianuni.lokey`) synchronization and hardware haptics—never for any network communication**. Specifically, it enables:
  1. Instant local sync of keyboard preferences (Pinyin layout, fuzzy Pinyin, sound, and haptic intensity) between the host app and keyboard extension;
  2. Reading and updating your local SQLite user lexicon and 26-key adaptive touch-heatmap calibration;
  3. Mounting external `.lokeypack` dictionaries or restoring `.lokeybackup` archives you explicitly import on your device;
  4. Rich key haptics via `CoreHaptics` and local acoustic key clicks;
  5. Optional on-device diagnostic or selection-feedback ring buffers if enabled by you—visible and exportable only by you locally on your device.

### 4. On-Device Storage & Full User Control
All preferences, personal phrases, touch-calibration offsets, and optional diagnostic buffers reside **solely inside your device's local sandbox and App Group container**. At any time, you can:
- **Delete Individual Learned Words**: Long-press any user-learned/custom candidate in the keyboard candidate bar or swipe to delete in **Lexicon Data → Local User Lexicon**;
- **Reset or Clear Everything**: Reset the 26-key touch calibration or clear all personal words and diagnostic caches inside the host app;
- **Export Your Data**: Export a local `.lokeybackup` archive directly under your control;
- **Complete Removal**: Uninstalling Lokey removes the app sandbox and its associated local data from iOS.

### 5. Apple Privacy Manifest (`PrivacyInfo.xcprivacy`) Transparency
Both Lokey targets declare in their embedded Apple Privacy Manifests:
- **`NSPrivacyTracking`**: `false` (`NSPrivacyTrackingDomains = []`)
- **`NSPrivacyCollectedDataTypes`**: `[]` (no data collected)
- **Required Reason APIs (On-Device Use Only)**:
  - `NSPrivacyAccessedAPICategoryUserDefaults` (`CA92.1`, `1C8F.1`): Local preferences and App Group state synchronization;
  - `NSPrivacyAccessedAPICategoryFileTimestamp` (`C617.1`): Local modification timestamps for `.lokeypack` files and shared caches;
  - `NSPrivacyAccessedAPICategorySystemBootTime` (`35F9.1`): High-resolution monotonic timestamps for local key-latency measurement (never for fingerprinting);
  - `NSPrivacyAccessedAPICategoryActiveKeyboards` (`3EC4.1`, Host App only): Checking whether Lokey Keyboard is enabled in iOS Settings to guide onboarding.

### 6. No Third-Party SDKs & Children's Privacy
- **Zero Third-Party SDKs**: Lokey includes no advertising networks, analytics libraries, crash reporters, or cloud services.
- **Children's Privacy**: Because Lokey collects no personal information whatsoever, we do not knowingly or unknowingly collect personal data from children under 13 (or the applicable age in your jurisdiction).

### 7. Policy Updates & Contact Us
If we update this Privacy Policy in future versions, we will revise the updated date above while maintaining our zero-collection, zero-network commitment. For privacy inquiries, security reports, or support, please contact:
- **Email**: [Kianuni60@gmail.com](mailto:Kianuni60@gmail.com)
- **Audit Repository**: <https://github.com/Kianuni/Lokey-Audit>
