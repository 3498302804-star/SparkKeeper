# KA自动续火花 · SparkKeeper

给自己的 iPhone 用的**抖音创作者中心「火花」自动续期**工具。原生 SwiftUI，登录态存在本机，定时在后台把每天一条的私信发出去，不依赖电脑常开。

- 目标系统：iOS 16.0 ~ 18.x
- 语言 / UI：Swift 5 + SwiftUI
- 依赖：**零第三方库**（纯 Foundation / WebKit / BackgroundTasks / AVFoundation）
- 产物：未签名 `.ipa`，自己签名安装

---

## 一、它是怎么干活的

```
BGTaskScheduler / 前台 Timer  ──►  SparkRunner（单例，互斥执行）
                                      │
                                      ├─ WebSession: 离屏 WKWebView（桌面 UA）
                                      │    ├─ 注入持久 Cookie（从 Keychain 同级的本地 JSON 恢复）
                                      │    ├─ 打开 creator.douyin.com 首页 → probeLogin 判断登录态
                                      │    └─ 打开 数据中心/关注/私信 页
                                      │
                                      ├─ DouyinJS.openAndType  → 搜索好友、打开会话、写入文本
                                      ├─ DouyinJS.submit       → 点发送（多选择器递进 + 兜底回车）
                                      └─ 失败重试 2 次（间隔 2s / 1.5s），写 RunRecord
```

### 抗风控的几个设计

| 设计 | 目的 |
|---|---|
| 离屏 WKWebView，桌面 Safari UA | 走网页端通道，不是逆向 App 协议，行为特征与真浏览器一致 |
| 时间抖动：`fireHour:fireMinute + (day*37 + hour*7) % jitterMinutes*60` 秒 | 每天发送时刻不固定，避免「秒级同一时刻」的机器特征 |
| `randomLines` 多套文案轮换 + `{date}` `{name}` 占位符 | 内容不重复 |
| `dryRun` 演练模式 | 只走流程不点发送，先验证选择器是否还有效 |
| `perTargetTimeout` / `maxScrolls` / `maxTargetsPerRun` | 限速，不在一个页面里高频操作 |
| 前台 Timer 兜底 + 后台 BGTask | 后台被系统掐掉时，回到前台立刻补一次 |

> ⚠️ 这是「模拟人在网页上点发送」，属于自动化操作。抖音的《用户协议》对自动化工具有限制，账号存在被限流/封禁的可能。请务必先开 `dryRun` 跑通、只挂自己真正在意的那几个好友，不要拿新号或主力号乱试。风险自担。

---

## 二、在 Windows 上怎么把它变成能装的 IPA

本机（你现在这台 Windows）**没有 macOS 工具链**，`xcodebuild` 跑不了，所以两条路：

### 路线 A：GitHub Actions 云端 macOS 编译（推荐，全自动）

仓库里已经带了 `.github/workflows/build-ipa.yml`。

**A-0 当前状态**：`SparkKeeper/` 目录**已经是一个 git 仓库**（`main` 分支，历史里 5 个 commit），`.gitattributes` 已强制 LF、`build_ipa.sh` 已带可执行位。你只缺一个 GitHub 远程仓库和 token。

**A-1 一条命令全自动（推荐）**

在 `SparkKeeper` 目录下双击 `build.bat`，或者打开 PowerShell 跑：

```powershell
# 先建一个 token：GitHub → Settings → Developer settings → Personal access tokens
#   → Tokens (classic) → Generate new token → 勾 repo + workflow → 复制
.\build.bat ghp_你复制的token
```

等价于直接调 PowerShell 脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\push_and_build.ps1 -Token ghp_你复制的token
```

它会依次：验证 token 归属 → 仓库不存在就自动创建 → 推送 `main` → 轮询 Actions → 构建失败打印失败步骤和日志链接 → 构建成功把 IPA 下载到 `.\out\`。

可选参数：`-Repo 仓库名`、`-Private`（建成私有库）、`-NoWait`（只推不等待）、`-OutDir 目录`。
macOS / Linux / WSL 上用 `./push_and_build.sh <token>`，流程一样。

**A-2 想要更省 Actions 额度：把仓库建成 Public**

公开仓库的 Actions 完全免费、不限分钟。代码里没有密钥（Cookie 是本机运行时才产生、存在手机沙盒里），可以放心公开。

**A-3 手动流程（不想用脚本时）**

1. 新建一个 GitHub 仓库（**Private** 也行，见下面的额度说明）。
2. 推上去：
   ```bash
   cd SparkKeeper
   git remote add origin https://github.com/<你的用户名>/<仓库名>.git
   git push -u origin main
   ```
   （`main` 分支和 commit 都已经有了，不用再 `git init` / `git add`。）
3. 打开仓库 → **Actions** → 左侧 `Build unsigned IPA`。
   - 推 `main` 会自动触发一次。
   - 也可以点右侧 **Run workflow** 手动触发，并填：
     - `bundle_id`：默认 `com.yg.sparkkeeper`。**用免费开发者账号签名的话，建议改成唯一一点的**，比如 `com.yg.sparkkeeper.yourname`，避免和别人的撞。
     - `app_name`：桌面显示名，默认 `KA自动续火花`。
4. 等 6~12 分钟（首次拉 Xcode 会慢些）。
5. 进这次 run → 底部 **Artifacts** → 下载 `SparkKeeper-unsigned-ipa.zip` → 解压得到 `SparkKeeper-unsigned.ipa`。

**踩坑提示**

- 免费 GitHub 账号的 Actions 是**公开仓库无限、私有仓库每月 2000 分钟**（macOS runner 按 10 倍计费，约 200 分钟额度）。一次构建 8 分钟左右，够用几十次。
- 如果报 `The requested device is not available` 之类，多半是 runner 镜像问题，重跑一次基本就好。
- 失败的话 Artifact 里还有一个 `build-log`，里面是完整 xcodebuild 输出，翻 `error:` 那几行。

### 路线 B：找一台 Mac（或者 macOS 虚拟机 / 云 Mac）

```bash
cd SparkKeeper
chmod +x build_ipa.sh

./build_ipa.sh                  # 出未签名 IPA → build/SparkKeeper-unsigned.ipa
# 或者，本机已有开发者证书：
TEAM_ID=你的10位TeamID ./build_ipa.sh signed   # 出已签名 IPA
```

也可以用 Xcode 直接开 `SparkKeeper.xcodeproj`：选中 target → Signing & Capabilities → 填 Team → 选真机 → ⌘R。
（直接 ⌘R 装到手机上，本质上就是「自己签名安装」最省事的方式，只是没法把 IPA 发给别人。）

---

## 三、自己签名安装（关键一步）

未签名 IPA 直接装是不行的，iOS 要求可执行文件有有效签名。下面按「有没有电脑」分。

### 3.1 前置：搞清楚你要用哪种证书

| 方式 | 证书来源 | 有效期 | 能装几个 App | 需要电脑吗 | 说明 |
|---|---|---|---|---|---|
| **免费 Apple ID 自签** | Xcode / Sideloadly 自动生成 | **7 天**（到期重签） | 同时最多 3 个 | 首次需要 | 零成本，最稳，适合只给自己用 |
| **付费开发者账号** | developer.apple.com（$99/年） | **1 年** | 100 台设备 | 首次需要 | 想长期挂着不折腾就买这个 |
| **企业证书 / 共享证书** | 网上买的 `.p12` + `.mobileprovision` | 看卖家，随时可能被吊销 | 不限 | 不一定 | **别用**。掉签、封号、隐私风险都在这条路上 |
| **TrollStore** | 不需要证书 | 永久 | 不限 | 不需要 | 仅限能装 TrollStore 的系统版本（见 3.5） |

**建议**：先走免费 Apple ID 自签，7 天重签一次，确认这 App 真的对你有用，再考虑买开发者账号。

### 3.2 免费 Apple ID 自签（Windows，用 Sideloadly）

1. 装 **iTunes**（从 Apple 官网下，不要 Microsoft Store 版）和 **iCloud**（同样官网版），都登录你的 Apple ID。这俩是给 Sideloadly 提供驱动和 `AFC` 服务的。
2. 装 **Sideloadly**（sideloadly.io）。
3. iPhone 用数据线连电脑 → 手机上点「信任此电脑」。
4. Sideloadly 界面：
   - **IPA**：拖入 `SparkKeeper-unsigned.ipa`
   - **Apple ID**：填你的 Apple ID
   - **Bundle ID**：如果提示冲突，改一下最后一段，比如 `com.yg.sparkkeeper.a1`
   - 勾上 **Sideloadly! Sideload via Apple ID**（用免费证书）
5. 点 **Start** → 输入 Apple ID 密码 → 可能要求输入**双重认证验证码**（在手机上收）。
6. 成功后手机桌面出现「KA自动续火花」。**第一次点开会被拦**：设置 → 通用 → VPN与设备管理 → 开发者 App → 点你的 Apple ID → 信任。
7. iOS 16+ 还要开 **开发者模式**：设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机 → 重启后确认。

**7 天到期怎么办**：Sideloadly 再点一次 Start 覆盖安装，数据（登录 Cookie、好友列表、历史记录）都在 `Application Support/sparkkeeper.json` 里，覆盖安装不丢。

### 3.3 免费 Apple ID 自签（有 Mac，用 Xcode）

最省事，也最不容易出问题：

1. Xcode → Settings → Accounts → 加你的 Apple ID → 选中 → **Manage Certificates** → `+` → **Apple Development**。
2. 打开 `SparkKeeper.xcodeproj` → target SparkKeeper → Signing & Capabilities：
   - 勾 **Automatically manage signing**
   - Team 选你的 Personal Team
   - Bundle Identifier 改成全局唯一的，比如 `com.yg.sparkkeeper.<你的名字拼音>`
3. 手机连上，顶部选你的设备，⌘R。
4. 手机信任步骤同上（通用 → VPN与设备管理 → 信任；隐私与安全性 → 开发者模式）。

### 3.4 已在手机上的「重签」工具（无电脑续签）

**AltStore / SideStore**

- AltStore 需要一台电脑（AltServer）在**同一 WiFi** 下做首次安装，之后可在手机上自助续签。
- SideStore 更进一步，配好配对文件后完全不需要电脑。
- 装完后把 IPA 用 AltStore 打开 → 输入 Apple ID → 7 天自动续。

**ESign / 轻松签 / Scarlet 之类**

- 走「导入 `.p12` + `.mobileprovision` → 签名 → 安装」流程。
- 证书得你自己有。**不要用来路不明的共享证书**，那等于把设备 UDID 交给陌生人。
- 需要先装这些工具的「描述文件版」或者用别的方式引导安装，这一步本身就有门槛。

### 3.5 TrollStore（如果你的系统刚好在范围内）

TrollStore 利用 CoreTrust 漏洞，装完的 App **永不过期、无需证书**。支持范围（截至写这份文档）：

- iOS 14.0 beta 2 ~ 14.8.1
- iOS 15.0 ~ 15.5 beta 4、15.6 beta 1~3
- iOS 16.0 ~ 16.6.1、16.7 RC、17.0

**iOS 17.0.1 及以上不行**（漏洞已修）。安装方式：装 TrollStore 的安装器（TrollInstallerX / TrollHelper 等，看你系统版本选）→ 装好后把 `SparkKeeper-unsigned.ipa` 用 TrollStore 打开 → Install。

> 如果你手机是 iOS 17.0.1 以上，别在 TrollStore 上浪费时间，直接走 3.2。

---

## 四、第一次打开要做什么

1. **账号页 → 「+ 添加账号」** → 起个名字（比如「主号」）。
2. 点进这个账号 → **「登录抖音」** → 弹出网页登录页，扫码或账号密码登录。
   - 登录成功后网页会跳回创作者中心，**等它加载完再点「完成」**，让 Cookie 落盘。
3. 点 **「选择好友」** → 自动读取你的私信好友列表 → 勾上要续火花的那几个人。
4. **设置页**：
   - `schedulerEnabled` 打开
   - `fireHour` / `fireMinute`：设成你希望的时段（建议早上 9 点附近，配 25 分钟抖动）
   - `jitterMinutes`：25（默认）
   - `template`：文案模板，支持 `{date}` 和 `{name}`
   - `randomLines`：加几套备用文案，会随机轮换
   - **`dryRun` 先打开！** 这一步会走完整流程但不点发送，用来验证选择器
5. 回首页 → **「立即运行」** → 看首页的实时日志。
   - 日志里出现 `openFriend ok` / `typed` / `submit ok` 就说明链路通了。
   - 如果卡在 `findFriend` 为空，说明抖音改版了，需要用「诊断」功能重新抓选择器（见第五节）。
6. 确认 dryRun 全绿 → 关掉 dryRun → 再点一次「立即运行」，去手机上看火花是不是真的续上了。

### 后台能活多久

- iOS 不给普通 App 长驻后台。这里的策略是：**BGTaskScheduler 定时唤醒 + 静音音频保活 + 前台 Timer 兜底**。
- 静音音频保活（`BackgroundKeeper`）在插电、低电量模式关闭时通常能撑很久，但不是官方允许的用途，App Store 会拒（我们本来也不上架，自己签）。
- **最稳的做法**：把 App 加进「引导式访问」或者干脆在充电时切到前台放着。或者接受「不总是准时」，只要每天醒一次就行——`scheduleNext` 会在下次启动时按「今天是否已发过」重新算。

---

## 五、抖音改版了怎么办（选择器失效）

抖音的 DOM class 是混淆的，几个月就变一次。`Engine/DouyinJS.swift` 里所有选择器都是**三层递进**的：

1. 先试稳定语义属性（`aria-label`、`data-e2e`、`placeholder`、文本内容）
2. 再试结构关系（`[contenteditable]`、`input[type=text]` 的父级按钮）
3. 最后试可见性兜底（遍历可点击元素，找文字里含「发送」的那个）

真失效了，用 App 内置的 **「诊断」** 页面：

- 它会 dump 当前页面的 `names` / `classes` / `buttons` / `scrollable` / `login` / `editor` / `url` / `title`
- 把 `editor` 那一段的结果发我，或者自己照着改 `DouyinJS.swift` 里的 `editorEl` / `sendButton`
- 改完重新打 IPA、重签安装

---

## 六、工程结构

```
SparkKeeper/
├── SparkKeeper.xcodeproj/
│   ├── project.pbxproj                  # objectVersion 56 / Xcode 14 兼容
│   └── xcshareddata/xcschemes/SparkKeeper.xcscheme
├── SparkKeeper/
│   ├── App.swift                        # @main，注册 BGTask、申请通知权限
│   ├── Engine/
│   │   ├── WebSession.swift             # 离屏 WKWebView + Promise 桥 + Cookie 导入导出
│   │   ├── DouyinJS.swift               # 全部注入脚本（core / openAndType / submit / state / probeLogin / diagnose）
│   │   ├── SparkRunner.swift            # 单账号执行流程、重试、写历史
│   │   └── Scheduler.swift              # BGTaskScheduler + 前台 Timer + 通知 + 静音保活
│   ├── Model/
│   │   ├── Models.swift                 # Target / Account / RunRecord / AppSettings / StoredCookie（全部容错解码）
│   │   └── Store.swift                  # @MainActor ObservableObject，JSON 落盘，抖动公式
│   ├── UI/
│   │   ├── HomeView.swift               # 账号列表、好友选择、立即运行
│   │   ├── SettingsView.swift           # 定时/文案/限速/演练
│   │   ├── HistoryView.swift            # 运行记录按天分组
│   │   └── SessionViews.swift           # 登录 WebView、好友选择器、诊断
│   ├── Intents/SparkIntent.swift        # 快捷指令「续火花」
│   └── Support/Info.plist               # 后台模式 / BGTask 标识 / 仅竖屏
├── SparkKeeper/Assets.xcassets/         # AppIcon（1024 单尺寸）+ AccentColor
├── tools/make_icon.py                   # Pillow 生成图标
├── build_ipa.sh                         # macOS 一键出未签名/已签名 IPA
├── build.bat                            # Windows 双击即用（参数是你的 token）
├── push_and_build.ps1                   # Windows：自动建库 + 推送 + 等构建 + 下载 IPA
├── push_and_build.sh                    # macOS/Linux/WSL：同上
├── .gitattributes                       # 强制 LF，避免 macOS runner 上脚本报 bad interpreter
├── .github/workflows/build-ipa.yml      # 云端 macOS 编译
└── README.md
```

### 数据存在哪

`Application Support/sparkkeeper.json`，包含：

- `accounts[]`：账号标题、抖音号、好友列表（含 `lastSent` / `lastOk`）、**cookies**（明文 `StoredCookie`）
- `history[]`：最近 400 条运行记录
- `settings`：全部设置

> ⚠️ **Cookie 是明文存在沙盒里的**。同沙盒里的其他代码（比如你装的别的描述文件型工具）理论上读得到。别在公共设备上装。想更安全就自己在 `Store.swift` 里加一层 Keychain 封装——但 Keychain 在重签后可能因为 entitlements 变化而读不到，权衡一下。

---

## 七、常见问题

**Q：装上去点开闪退**
A：99% 是签名不对。确认用的是自己 Apple ID 生成的证书，且在手机上「信任」过；iOS 16+ 确认开发者模式已开。

**Q：日志显示 `notLoggedIn`**
A：Cookie 过期了。进账号页重新登录一次。

**Q：日志显示 `findFriend` 返回 0**
A：好友列表没拉到，或者抖音改了搜索框。先确认网页版私信页面里能看到这个好友；再跑「诊断」。

**Q：发了但对方没收到**
A：可能是 `submit` 点到了错误的按钮（比如点到了「表情」）。开 `dryRun` 复现，看诊断里的 `buttons` 里「发送」按钮长什么样。

**Q：能不能多账号**
A：可以，每个账号有独立的 `storeId`（独立的 WKWebsiteDataStore），Cookie 不串。

**Q：会不会被封号**
A：会有限流/封禁风险，这是自动化操作的固有代价。抖动 + 文案轮换 + 每天一次 + 只挂少数几个好友，能把风险压到很低，但不为零。

**Q：能上架 App Store 吗**
A：不能。用了静音音频保活、自动化操作第三方平台，这两条都违反审核条款。本来也设计成自签。

---

## 八、许可

自己用。代码给你了，改坏了别找我。
