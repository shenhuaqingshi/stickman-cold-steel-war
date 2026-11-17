# 火柴人冷兵器大战（Stickman Cold Steel War）

一款面向华为鸿蒙 **HarmonyOS NEXT（API 12+ Stage 模型，华为鸿蒙平板 MatePad 大屏横屏优先）** 的纯单机离线冷兵器战争策略动作游戏。玩家作为一军统帅，既可在 **4800×2400 宏大战场**上同时指挥前锋、两翼与预备队多军团排兵布阵、包抄合围、截断粮道，也可随时一键切换**主帅英雄模式**提刀纵马冲入敌阵斩将夺旗；并在 **8 大地理板块、40 座城池雄关**组成的战略大地图上，与其余 **7 大非对称势力**展开攻伐、结盟、通商、背叛与媾和博弈。

> 姊妹仓库（macOS 原生版 Swift 6 + SwiftUI + SpriteKit）：[stickman-cold-steel-war-mac](https://github.com/shenhuaqingshi/stickman-cold-steel-war-mac)

---

## 重要说明（开发环境限制声明）

> **注意：当前开发所处的 Linux 主机未安装 DevEco Studio、HarmonyOS NEXT SDK、`ohpm` 及 `hvigorw` 编译工具链，因此无法在本机执行实际编译、模拟器运行或生成 `.hap` 安装包。**
>
> 本仓库严格按照 **DevEco Studio 5.0.x（HarmonyOS NEXT API 12 `5.0.0(12)`，Stage 模型，ArkTS 严格静态类型规范）** 标准工程结构编写，界面与数值单点真相源完全依据 `DESIGN.md` 与 `entry/src/main/ets/config/` 实现。请按下方步骤导入安装了 DevEco Studio 5.x 的开发机进行编译、平板模拟器/真机运行与打包验证。

---

## 项目工程目录结构

```text
stickman-war/
├── AppScope/
│   ├── app.json5                                 # 全局应用包名、版本号与图标配置
│   └── resources/                                # 全局多语言应用名与应用图标资源
├── entry/
│   ├── build-profile.json5                       # 模块级 Stage 构建与混淆配置
│   ├── hvigorfile.ts                             # HAP 模块构建任务入口
│   ├── obfuscation-rules.txt                     # Release 模式 ArkGuard 混淆白名单规则
│   ├── oh-package.json5                          # 模块级依赖声明（纯离线零第三方联网库）
│   └── src/
│       ├── main/
│       │   ├── module.json5                      # Stage 模型平板优先设备类型、多窗分屏与 Ability 配置
│       │   ├── ets/
│       │   │   ├── entryability/EntryAbility.ets # 平板大屏横竖屏/分屏/悬浮窗响应式监听入口
│       │   │   ├── entrybackupability/           # 本地离线存档备份恢复扩展 Ability
│       │   │   ├── common/GameConstants.ets      # 战场/大地图尺寸、平板热区、合围、粮道、外交常量
│       │   │   ├── model/GameTypes.ets           # 严格 ArkTS 静态枚举与接口定义（含多军团与骨骼动作态）
│       │   │   ├── config/                       # 16兵种、8势力、40城关静态数据单点真相源
│       │   │   └── pages/                        # 平板左右分栏响应式路由骨架页（主菜单/大地图/整军/战场/结算/存档/设置）
│       │   └── resources/                        # 页面路由表 main_pages.json、备份配置、平板字号热区与资源
│       └── ohosTest/                             # Hypium 单元测试模块与静态拓扑/数值一致性测试
├── hvigor/hvigor-config.json5                    # Hvigor 5.0 构建器配置
├── build-profile.json5                           # 工程级 SDK 版本 (5.0.0(12)) 与产物配置
├── code-linter.json5                             # ArkTS 代码静态检查规则
├── oh-package.json5                              # 工程级包描述与测试依赖 (@ohos/hypium)
├── GAME_BRIEF.md                                 # 立项需求书（含真实大战与鸿蒙平板版最高要求）
├── DESIGN.md                                     # 游戏总体设计文档（数值表/势力/外交/大地图/AI/边界/平板适配）
└── PROGRESS.md                                   # 阶段进度记录与两轮自我审查重构优化台账
```

---

## 在 DevEco Studio 中打开与平板验证步骤

### 1. 环境准备
- 安装 **DevEco Studio 5.0.0 Release** 或更高版本（内置 HarmonyOS NEXT SDK `5.0.0(12)` 及以上）。
- 首次打开工程时需拉取 `@ohos/hypium` 与 `@ohos/hamock` 开发测试包（游戏本体运行完全离线，不申请任何联网权限）。

### 2. 导入与同步工程
1. 启动 DevEco Studio，点击 **Open**，选择本项目根目录 `stickman-war`。
2. 等待 IDE 自动生成本机 `local.properties` 并完成 **Ohpm Install & Hvigor Sync**（或手动点击 **File -> Sync and Refresh Project**）。
3. 确认底部 **Build** 面板提示 `Sync Finished` 无报错。

### 3. 在鸿蒙平板模拟器（MatePad）或真机上验证
- **使用平板模拟器（推荐优先验证）**：
  1. 打开 **Tools -> Device Manager**，创建并启动一台 **HarmonyOS NEXT Tablet（MatePad 宽屏分辨率，API 12+）** 模拟器。
  2. 在顶部运行目标选择该平板设备及 `entry` 模块，点击 **Run 'entry'**（`Shift + F10`）。
  3. **平板专项核验项**：
     - 横屏状态下验证主菜单、战役大地图、战前整军、战场预览均为协调的**左右双栏（Master-Detail）大屏布局**，触控热区宽裕（≥ 48vp），无拉伸或文字截断；
     - 触发模拟器**横竖屏旋转**及华为平板**分屏（Split-Screen）/ 悬浮窗（Floating Window）**，验证窗口自适应切换不崩溃、不裁切。
- **使用华为鸿蒙平板真机（如 MatePad Pro / Air / 11.5"S）**：
  1. 开启平板“开发者选项”与“USB 调试”，连接电脑（如配有 M-Pencil 手写笔可同步测试笔尖点选体验）。
  2. 打开 **File -> Project Structure -> Project -> Signing Configs**，勾选 **Automatically generate signature** 登录华为开发者账号自动生成调试签名（IDE 会自动将签名写入 `build-profile.json5`）。
  3. 点击 **Run 'entry'** 安装至平板运行。

### 4. 运行单元测试（Hypium）
- 在工程树右键点击 `entry/src/ohosTest/ets/test/Ability.test.ets`，选择 **Run 'Ability.test'**，验证战场与平板热区规格、8 势力各 5 座初始城关与王都仓城属性、16 兵种正定性与开局行军口粮耐力、以及 40 城关无向图对称单连通测试全部通过。

---

## 打包 HAP 安装包步骤

### 方式一：打包未签名调试包（Unsigned Debug HAP）
1. 点击顶部菜单 **Build -> Build Hap(s)/APP(s) -> Build Hap(s)**。
2. 输出路径：`entry/build/default/outputs/default/entry-default-unsigned.hap`

### 方式二：打包已签名包（Signed Debug / Release HAP）
1. 在 **File -> Project Structure -> Signing Configs** 完成自动签名或正式发布证书配置。
2. 如需 Release 包，在右上角 **Build Mode** 切换为 `release`（`entry/obfuscation-rules.txt` 已配置数据模型与存档序列化字段防混淆保护），再点击 **Build -> Build Hap(s)/APP(s) -> Build Hap(s)**。
3. 输出路径：`entry/build/default/outputs/default/entry-default-signed.hap`
4. 手动安装命令：
   ```bash
   hdc install entry/build/default/outputs/default/entry-default-signed.hap
   ```

---

## 当前阶段状态与已知限制（第 1 步停点）

1. **当前停点说明**：已完成**第 1 步全部工作（补齐平板优先 Stage 模型工程骨架 + 16兵种/8势力/40城关静态配置单点真相源 + `DESIGN.md` 完整设计文档 + 两轮深度自查重构）**，严格遵照督工指示停在此处等待检查，**未提前编写第 2 步战斗模拟逻辑**。
2. **本机无编译环境**：当前 Linux 主机无 DevEco Studio 工具链，未执行本地字节码编译与真机渲染实测。
3. **后续迭代衔接**：待督工检查通过后，第 2 步将独立实现可单元测试的 `ets/core/` 战斗/AI/粮道/外交引擎，第 3 步实现高分屏平板 Canvas 百人火柴人真刀真枪骨骼动画合批渲染与四大核心界面完整闭环。
