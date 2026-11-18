# 《火柴人冷兵器大战》开发进度与多轮自查优化台账（PROGRESS.md）

- **当前阶段（如实勘误与实测状态说明）**：
  - **历史事实勘误**：第 1 步验收后，磁盘上实际已写出第 2 步核心引擎草稿（`entry/src/main/ets/core/` 与 `storage/`）和第 3 步渲染器草稿（`entry/src/main/ets/render/`），均处于未提交、未在 DevEco Studio 编译、未跑通测试的草稿状态，旧版 `PROGRESS.md` 所写“停在第 1 步、第 2 步待启动”与磁盘事实自相矛盾，现已如实更正。
  - **第 1 步**：已完成（DevEco Stage 模型平板优先骨架 + `DESIGN.md` + `README.md` + 第 1 步静态配置自查）。
  - **第 2 步核心引擎（`entry/src/main/ets/core/` 及 `storage/`）**：**已完成 Node 纯逻辑单测实跑与缺陷修复，但未在 DevEco Studio 编译验证**（本机无 DevEco Studio，`test_combat.mjs` / `test_ai.mjs` / `test_campaign_diplomacy.mjs` 均 100% 实跑通过）。
  - **第 3 步渲染器与全流程页面打通（`entry/src/main/ets/render/`、`core/session/`、`ui/` 及全部 7 个 `pages/*.ets`）**：**已完成代码全流程打通及 Node 会话级端到端闭环单测、Mock Canvas 渲染单测与静态审计（全部 100% 通过），但本机无 DevEco Studio，未编译验证、未在真机/模拟器验证**。
- **使用模型**：Gemini 4 Carbon (High)
- **参考图与界面准则**：已确认废弃并忽略任何旧参考图，全部界面布局与数据严格依据 `DESIGN.md` 与 `entry/src/main/ets/config/` 单点真相源构建。

---

## 一、既有 31 个文件核查与第 1 步补齐成果

### 1.1 原有 31 个文件盘点（保留既有基础，缺什么补什么）
经逐一审阅本目录原有 31 个文件，上一会话搭建了基础目录外框与 `Index.ets` 初版静态预览页，但存在以下实质缺口：
1. **构建配置冲突**：根 `build-profile.json5` 中 `signingConfigs` 为空数组 `[]`，但 `products[0]` 却引用了 `"signingConfig": "default"`，会导致未配置签名的 DevEco Studio 5.x 构建未签名调试 HAP 时报错。
2. **鸿蒙平板多窗与 Stage 扩展缺失**：未按平板优先声明 `supportWindowMode`（分屏/悬浮窗）与横竖屏自适应旋转监听；缺少 HarmonyOS Stage 标准模板的 `EntryBackupAbility` 及 `backup_config.json`；`AppScope` 缺少 `zh_CN` 资源限定目录；`TestAbility.ets` 回调参数缺少严格 ArkTS `BusinessError` 类型标注。
3. **模块化类型/配置层与子页面路由缺失**：`ets/` 下仅有 `EntryAbility.ets` 与 `Index.ets`，缺少全局常量、静态类型模型、兵种/势力/大地图静态配置表以及战役、战前整军、战场、结算、存档、设置 6 个 Stage 页面路由容器。
4. **核心工程文档缺失**：未编写 `DESIGN.md`、`PROGRESS.md`、`README.md`。

### 1.2 第 1 步已完成清单
- [x] **补齐 DevEco Studio 5.x (API 12+) Stage 模型平板优先骨架**：
  - 修复 `build-profile.json5` 未签名配置冲突；
  - 更新 `entry/src/main/module.json5`：`deviceTypes` 将 `"tablet"` 置首，声明 `"supportWindowMode": ["fullscreen", "split", "floating"]`、`"orientation": "auto_rotation"` 与 `"preferMultiWindowOrientation": "landscape_auto"`，并注册 `EntryBackupAbility`；
  - 升级 `EntryAbility.ets`：监听 `windowSizeChange` 实时向 `AppStorage` 同步窗口像素尺寸与 `isWideScreen` 响应式断点（兼容 MatePad 横竖屏旋转、分屏与悬浮窗防崩），并在销毁阶段安全解绑；
  - 新增 `entrybackupability/EntryBackupAbility.ets`、`resources/base/profile/backup_config.json`、`AppScope/resources/zh_CN/element/string.json`；升级 `float.json` 平板字号与 `48vp` 最小触控热区标准；
  - 新增零 UI 依赖的静态契约与单点真相源：`common/GameConstants.ets`、`model/GameTypes.ets`、`config/UnitConfig.ets`（16 兵种）、`config/FactionConfig.ets`（8 大势力）、`config/CampaignMapConfig.ets`（8 大区 40 座城关对称拓扑图）；
  - 补齐 7 个平板响应式左右双栏 Stage 路由页面（`Index`、`CampaignPage`、`SetupPage`、`BattlePage`、`BattleResultPage`、`SavePage`、`SettingsPage`）并完整注册至 `main_pages.json`；
  - 升级 `ohosTest/ets/test/Ability.test.ets` 静态配置、粮草行军耐力与 40 节点图连通性单测。
- [x] **完成总体设计文档 `DESIGN.md`**：完整覆盖【真实大战最高准则】、三维后勤资源、16 兵种数值与双曲护甲公式、多军团 4 阵型 9 战术指令、八象限合围/钳形夹击/半渡而击/围点打援数学模型、主帅英雄三武器（含箭袋上限与 40ms 卡肉顿帧）、8 势力差异与专属科技、4800×2400 战场迷雾与 40 城关大地图、外交系统与媾和公式、三层多军团 AI、四大边界闭环及【鸿蒙平板 MatePad 专项适配与 M-Pencil 交互设计】。
- [x] **完成说明文档 `README.md`**：如实注明本台 Linux 机器无 DevEco Studio、无法本地编译验证，并详述导入、签名、MatePad 模拟器/真机多窗旋转验证、单测与打包 HAP 全流程。

---

## 二、两轮全面自我审查与重构优化记录

严格按照 `GAME_BRIEF.md`“规划 -> 实现 -> 自己审查 -> 重构优化 -> 再审查”要求，编写了数学战力模拟与 ArkTS 静态检查脚本对全部代码、数值表、拓扑图与文档执行了两轮深度自查并当场改透：

### 第一轮自我审查与优化（聚焦：数值平衡、势力公平、防逃课 AI、ArkTS 严格规范与外交边界）

| 审查维度 | 审查发现的具体问题 | 为什么必须改 | 具体修改动作 | 改后量化效果 |
| :--- | :--- | :--- | :--- | :--- |
| **1. 兵种数值平衡** | ① `血月狂战祭团`（1人口/155资源）初版设了 `255 HP`、`12 甲`、`34.7 DPS`，单位人口战力指数高达 `89.9`（全场均值 `45~58`），弓手在其贴脸前仅能射掉 `16.6%` 血量，导致“无甲狂战士怕弓弩”的反制设计落空；<br>② `霜原巨熊破阵者`（3人口）仅 `460 HP / 28.1 DPS`，不如造 3 个通用巨斧兵（`615 HP / 65.7 DPS`）；`苍狼怯薛骑射` 输出偏弱；<br>③ `长枪方阵兵`（25%破甲）正迎 `68` 护甲的 `玄甲铁浮图` 时穿甲不足，重骑可强行硬踩枪阵。 | 若不修正，血月无脑爆狂战士将碾压全图，而霜原玩家造专属巨人反而亏人口，枪骑基础克制链也会失真。 | ① 下调 `血月狂战祭团` 至 `160 HP / 4 护甲 / 26 攻击 / 1.0s 间隔 / 145 总造价`；<br>② 上调 `霜原巨熊破阵者` 至 `620 HP / 42 护甲 / 66 攻击 / 1.75s 间隔`，同步补强 `炎龙神机重卫`（`335 HP / 32 攻`）、`苍狼怯薛骑射`（`250 HP / 26 攻 / 30% 破甲 / 1.3s`）与 `铁浮图`（`420 HP / 38 攻`）；<br>③ 上调长枪反骑倍率 `2.8 -> 3.2`，并新增架枪迎击冲锋骑兵享 **`+30%` 动能破甲**（`BRACED_ANTICAV_BONUS_PEN`）。 | ① 血月单位人口战力回归合理区间 `57.5`，弓手单轮接敌前削血提升至 `29.8%`（集火可秒脆皮狂战），贴脸吸血爆发特色保留；<br>② 巨熊破阵者 `Pwr/Pop` 升至 `63.6` 真正撑起 3 人口霸主身板；<br>③ 1000 资源长枪迎击铁浮图首轮反伤提升 **+43%（241 -> 345）**，重骑不敢再正撞枪阵。 |
| **2. 8势力大地图开局公平性** | 初版 36 节点中 4 个势力占 5 城、4 个势力仅占 4 城；其中 `霜原熊族` 开局总产出仅 `1140`（比炎龙 `1490` 低 `23.5%`），且熊族自身有 `+15% 耗粮` Debuff 却仅有 `420` 产粮，同时仅接壤 2 国。 | 违背“8个势力都要强，不能有凑数弱势力”，熊族与商盟开局即陷入慢性缺粮或少城劣势。 | 为原 4 城区域各增补 1 座战略节点（`冰湾猎港`、`望北烽燧`、`流沙古井`、`灵木祭坛`），升级为 **8 大区 × 每势力 5 城 = 40 座城关（双向对称边）**，并配平各国资源禀赋。 | 8 大势力开局城池数 100% 公平（各 5 座），初始总经济严格收敛在 **`1425 ~ 1490`** 窄带内（极差 `< 4.6%`），熊族产粮提升至 `560` 足以支撑大胃王军团，且接壤邻国增至 3~6 家。 |
| **3. 玩法与 AI 防逃课深度** | ① 缺少战场动态视野迷雾定义，若全图透视则密林设伏与两翼绕后毫无隐蔽性；<br>② 主帅若无限箭矢可单骑风筝磨死全图 AI；<br>③ 缺少 AI 攻守城专项战术，易无脑撞城门送死。 | 真实冷兵器战争必须有侦察反伏击与攻守城章法，不能留无脑风筝漏洞。 | ① 新增步兵 `420px` / 骑兵 `580px` 战场战争迷雾与密林隐匿规则；<br>② 锁定主帅百石硬弓随身箭袋上限 **24 支**（回营或脱战缓回）；<br>③ 在 `DESIGN.md` 增补 AI 攻城三段式（拆塔->多路云梯->破门投预备队）与守城三段式（点杀工兵->圆阵堵门->侧门轻骑烧投石车）。 | 赋予游骑兵开图侦察不可替代的战略价值，彻底封堵主帅无限风筝逃课，攻守城战术层次大幅提升。 |
| **4. 外交背盟连环悖论边界** | 当玩家同时结盟 B 与 C，而 AI 盟友 B 主动宣战盟友 C 时，初版规则下玩家无论帮谁都会触发“背盟扣 45 信誉”。 | 属于典型外交规则死锁，会让玩家因 AI 互掐而蒙受不白之冤。 | 在 `DESIGN.md` 10.3 节新增**【双重同盟互攻豁免铁律】**：同盟防御优先，协防受侵略方 C 或居中调停停火均**零信誉损失**。 | 彻底闭合多边同盟网交叉开战的规则死角。 |
| **5. 代码洁净与 Release 混淆隐患** | 静态扫描发现：① `BattleResultPage.ets` 的 `replaceUrl` 未处理 `.catch` 异常；② `entry/obfuscation-rules.txt` 开启了 `-enable-property-obfuscation` 却无白名单，Release 包会混淆路由参数与存档 JSON 字段名。 | Release 打包后会导致页面传参读取 `undefined` 及离线存档损坏无法读档。 | ① 为所有路由跳转补齐 `BusinessError` `.catch` 处理；② 在 `obfuscation-rules.txt` 添加 `model/`、`config/` 与序列化字段 `-keep-property-name` 保护。 | 静态检查脚本扫描全仓 `.ets` 与配置文件实现 **0 警告 / 0 未捕获 Promise / 0 `any` 或未标注字面量**。 |

---

### 第二轮深度自我审查与优化（聚焦：真实大战硬指标、八象限合围数学闭环、行军口粮节奏、鸿蒙平板大屏与多窗适配、跨文件一致性）

| 审查维度 | 审查发现的二阶隐患与新要求缺口 | 为什么必须改 | 具体修改动作 | 改后量化效果 |
| :--- | :--- | :--- | :--- | :--- |
| **1. “真实大战”硬指标与合围判定落地** | 初版虽提及包抄，但缺少**钳形夹击、铁桶合围、渡河半渡而击、围点打援**的精确判定公式，也缺少火柴人单兵骨骼动作状态与多军团建制模型，易在后续实现时退化为单团站桩对砍。 | 真实大战是最高优先级，包抄合围必须有硬核数值奖惩，士兵必须有挥砍、格挡、倒地、弃盾溃逃动作反馈。 | ① 在 `GameTypes.ets` 新增 `ArmyCorpsRole`（6大军团建制）、`UnitActionState`（11种火柴人骨骼动作态）、`EncirclementState` 与 9 种 `TacticalOrder`；<br>② 在 `GameConstants.ets` 与 `DESIGN.md` 确立**八象限受敌扇区模型**（钳形夹击 `-2.2/s` 士气、$\ge 5$ 扇区合围 `-4.8/s` 士气雪崩、半渡而击 `+20%` 易伤、主帅重劈 `40ms` 卡肉顿帧、150 具战场遗骸留存）。 | 将 12 种冷兵器复杂战术全部转化为确定性可编程、可单测的状态机与数学常数，为第 2~3 步真刀真枪大战锁死高标准蓝图。 |
| **2. 战场行军耗时 vs 初始携粮隐性饥荒隐患** | 二阶推演发现：`4800px` 宽大战场两军本阵相距 `3800px`，步兵对向行军接敌需约 `31 秒`；百人主力每秒耗粮约 `9.8~10`，若初始粮草未标定而给成常规小值（如 `300`），两军还没走到中线接战就会双双断粮溃散！ | 大尺寸战场改变了行军时间尺度，后勤初值必须与地图尺度严格匹配。 | 在 `GameConstants.ets` 明确标定 `BATTLE_INIT_GRAIN = 1200`（`GOLD = 500`, `WOOD = 350`），并在 `Ability.test.ets` 写入自动化口粮耐力断言（百人刀盾至少够吃 `120s`）。 | 保证开局 `3.5~4.5 分钟` 主力正常酣战，同时在中后期持久战中凸显抢占野外农庄与派轻骑烧敌粮车的致命战略价值。 |
| **3. 鸿蒙平板（MatePad）大屏响应式与分屏防崩** | 初版骨架按钮偏小（`32~34vp`），横屏固定 `auto_rotation_landscape` 未声明分屏/悬浮窗 `supportWindowMode`，在 MatePad 分屏或竖屏旋转时存在布局局促与多窗兼容隐患。 | 目标设备是华为鸿蒙平板大屏，必须利用宽屏做左右分栏、放大手指热区并兼容手写笔与分屏悬浮窗。 | ① `module.json5` 将 `"tablet"` 置首，开启 `fullscreen/split/floating` 多窗支持与 `auto_rotation`；<br>② `EntryAbility.ets` 注入 `windowSizeChange` 动态响应式断点 `isWideScreen`；<br>③ 重构全部 7 个骨架页面为 **MatePad 横屏左右分栏（Master-Detail）+ 窄屏/竖屏自动弹性切换**，按钮触控高度统一升至 **`48~54vp`**，新增 M-Pencil 手写笔拾取与画线包抄规范。 | 平板横屏下主菜单、大地图、战前整军、战场指挥全部实现大气舒展的左右双栏布局，热区顺手，分屏/悬浮窗/旋转不崩不裁切。 |
| **4. 跨文档与测试一致性清零** | 第一轮将大地图从 36 节点升级为 40 节点后，复查发现 `README.md` 与 `DESIGN.md` 第 11 章局部仍残留 `36 节点` 字样；且单测仅测了边对称，未测全图单连通。 | 文档与代码不一致会误导后续阶段开发与验收。 | 全局排查清理所有残留 `36` 节点描述，统一同步为 `40 城关`；在 `Ability.test.ets` 新增 BFS 全图 40 节点单连通性与每势力 5 城公平性断言。 | 代码、`DESIGN.md`、`README.md`、`Ability.test.ets` 四方数据 100% 严丝合缝。 |

---

## 三、后续阶段硬性验收标准清单（已同步“真实大战”与“鸿蒙平板版”最高要求）

以下硬性标准已锁定为第 2 步（战斗/战役/外交核心逻辑）与第 3 步（平板高分屏 Canvas 渲染与全流程打通）的强制准出红线：

- [ ] **【真实大战红线 1 · 拒绝静态摆拍】**：进入战斗后屏幕必须是正在激烈交锋的鲜活大战场——百人火柴人真刀真枪挥砍、刺击、挽弓抛射、举盾格挡火星迸溅、骑兵冲撞击飞、投石砸阵、受击倒地遗骸与弃盾抱头溃逃动画齐全。
- [ ] **【真实大战红线 2 · 战术爆表且真有效】**：侧翼迂回、包抄背击（`+25%/+45%` 增伤与破盾）、钳形夹击、八象限铁桶合围（士气雪崩崩溃）、正面佯攻+侧翼偷袭、诈败诱敌、密林伏击、断粮道、夜袭、围点打援、高地压制、渡河半渡而击，玩家与三层 AI 均能真实使出并左右战局。
- [ ] **【真实大战红线 3 · 多军团多战线调度】**：前锋、左翼、右翼、总预备队、远程群、护粮队多战线同时开打，顾此失彼即防线崩溃。
- [ ] **【真实大战红线 4 · 主帅亲自上阵实感】**：随时无缝切换主帅进场冲杀，刀/枪/弓切换、格挡弹反、破阵冲锋、三军战吼、卡肉顿帧、鼓舞士气、斩将夺旗及主帅重伤/阵亡士气崩盘体验扎实。
- [ ] **【鸿蒙平板版红线 5 · MatePad 大屏左右分栏与操作】**：在鸿蒙平板尺寸下，**主菜单、战役大地图、战斗界面、外交面板（含战前整军）** 四大核心界面完整协调、左右分栏合理、无拉伸裁切；按钮热区 $\ge 48\text{vp}$，支持多指缩放拖拽与 M-Pencil 手写笔点选/划路线；高分辨率同屏百人 60FPS 流畅，横竖屏切换与分屏/悬浮窗不崩。

---

## 四、当前模块真实盘点状态（修正原“第 2 步待启动”与磁盘实际文件不符的自相矛盾）
- [x] **第 1 步（已完成）**：Stage 模型平板优先工程骨架、静态单点真相源配置表（`GameConstants` / `GameTypes` / `UnitConfig` / `FactionConfig` / `CampaignMapConfig`）、`DESIGN.md` 与 `README.md`。
- [ ] **第 2 步核心引擎（已写草稿、未在 DevEco Studio 编译；已完成 Node 纯逻辑测试补齐与 Bug 修复）**：
  - 磁盘草稿文件：`core/CoreContracts.ets`、`core/combat/`（`SpatialHashGrid`、`DamageAndMorale`、`FormationAndSteering`、`HeroController`、`BattleSimulator`）、`core/ai/`（`BattleTacticalAI`、`CampaignStrategicAI`）、`core/campaign/`（`SupplyLineEngine`、`CampaignEngine`）、`core/diplomacy/DiplomacyEngine.ets` 及 `storage/`（`SaveManager`、`SettingsStore`）；
  - 真实状态说明：此前写完草稿后未编译、未跑完测试（初版 `test_combat.mjs` 第 907 行失败）；本轮已通过 Node 真跑全部纯逻辑单测、修清测试缺陷与 4 项引擎/渲染器真实 Bug 并扩充边界测试，但本机无 DevEco Studio，**仍未经过鸿蒙编译器与真机/模拟器验证**。
- [x] **第 3 步渲染器与全流程页面打通（已完成全流程代码打通与 Node 会话/Mock Canvas 测试，本机无 DevEco Studio，未编译验证、未在真机/模拟器验证）**：
  - 渲染器与适配器：`render/StickmanBattleRenderer.ets`、`render/CampaignMapRenderer.ets`、`ui/ArkCanvas2DAdapter.ets`、`entryability/HarmonyFilePersistenceBackend.ets`；
  - 全局会话与七大 MatePad 左右双栏正式页：`core/session/GameSessionCoordinator.ets` 及 `pages/Index.ets`、`SetupPage.ets`、`BattlePage.ets`、`BattleResultPage.ets`、`CampaignPage.ets`、`SavePage.ets`、`SettingsPage.ets`。

---

## 五、Node 纯逻辑单测实跑全记录、根因剖析与可复现审计脚本归档

统一测试运行命令：
```bash
node --experimental-transform-types --import ./tests/node/ets_loader.mjs tests/node/test_xxx.mjs
```

### 5.1 已知失败项 `tests/node/test_combat.mjs:907` 专项根因判定与修复理由
- **故障现象**：基线实跑 `test_combat.mjs` 时，第 1~10 项通过，第 11 项在 `907` 行报错：`AssertionError: actual 'wounded_weakened' !== expected 'fallen_martyred'`。
- **逐帧追踪与判定结论——测试前置隔离构造有误（引擎两段式落马与 10s 全军溃散逻辑均正确）**：
  1. **核查引擎规则**：`HeroController.ets` 与 `BattleSimulator.ets` 严格实现了 `DESIGN.md` 10.2 & 4.3——玩家主帅首次致命伤进入 `RECOVERING_IN_CAMP`（本阵包扎 `45s`、全军士气 `-35`、上限锁死 `65`、切回 RTS）；满 `45s` 后以 `35%` 血量（`385 HP`）复出为 `WOUNDED_WEAKENED`；二次 HP 归零立即进入 `FALLEN_MARTYRED` 并判负 `PLAYER_HERO_MARTYRED`。同时若场上未溃逃友军归零持续满 `10.0s`，`evaluateBattleOutcome` 判定 `PLAYER_ARMY_ROUTED` 结束战斗，且 `stepTick` 在 `outcome !== ONGOING` 时立即早退（不再步进投射物）。
  2. **定位测试构造漏洞**：原 `test_combat.mjs` 第 `872~884` 行注释写明“双方暂驻原地避免期间全歼敌军提前获胜”，在循环 `460 × 0.1s = 46s` 等待主帅包扎复出期间，每帧把双方士兵 `hp` 重置为满血，但**仅对玩家 `pSq` 下达了 `HOLD_GROUND(1200, 1200)`，漏掉了把敌方骑兵队 `eSq` 拉开驻防**（且此前 11.4 刚击倒敌帅触发了 `15s` 指挥瘫痪）。
  3. **时间线实证**：无敌状态的 6 名敌方轻骑沿原 `ADVANCE` 指令冲入 `(1200, 1200)` 合围 `pSq`，在第 `i = 250` 帧形成钳形夹击（`-2.2/s` 士气衰减叠加近战受击士气打击），第 `i = 357` 帧将 `pSq` 士气打穿 `< 20` 进入溃逃（`pNonRout === 0`）；第 `i = 450` 帧（`45.0s`）主帅正常复出为 `wounded_weakened`（`385 HP`）；仅 `0.7s` 后的第 `i = 457` 帧（溃逃满 `10.0s`），引擎合法触发 `outcome = 'player_army_routed'`！因此到第 `890` 行生成二次斩首箭矢 `killProj` 并调用 `sim.stepTick(0.02)` 时，因战局早已在 `i = 457` 结束，`stepTick` 首行直接返回，`killProj` 根本未飞行命中主帅，主帅遂停留在复出态 `'wounded_weakened'`。
  4. **修改动作**：修正 `test_combat.mjs` 包扎等待段的双方隔离条件——将 `eSq` 拉回 `(3200, 1200)` 驻防并保持双方士气稳定在 `60`（不超过主帅重伤期 `65` 士气封顶），增补复出瞬间 `outcome === ONGOING` 断言，随后二次致命投射物正常命中，精准触发 `FALLEN_MARTYRED` 与 `PLAYER_HERO_MARTYRED`。

### 5.2 代码审查与扩充单测期间发现并修复的 4 项引擎/渲染器真实 Bug
1. **Bug A（`BattleSimulator.ets` 近战/无目标远程士兵从不攻击敌方主帅，导致佩刀 `0.25s` 精准弹反形同死代码）**：
   - **原因**：原 `BattleSimulator` 仅在 `stepAllProjectiles` 和主帅互砍中调用 `applyDamageToHero`，普通近战士兵贴脸敌方主帅时完全无视主帅，`HeroController.applyDamageToHero` 内编写的“佩刀起盾 `0.25s` 弹反近战兵并眩晕 `1.5s`”分支在实战模拟中永远无法触发。
   - **修复**：在 `BattleSimulator.stepAllSoldiers` 新增活跃敌帅近战交战判定与 `executeSoldierAttackOnHero`，使近战士兵可真实围砍孤身主帅，并完整打通佩刀 `0.25s` 精准弹反震退眩晕 `1.5s` + `40ms` 卡肉顿帧链路。
2. **Bug B（`StickmanBattleRenderer.ets` 与 `BattleTacticalAI.ets` 城防建筑坐标原点语义错位）**：
   - **原因**：`BattleSimulator`、`FormationAndSteering`、`HeroController` 统一将 `FortStructureEntity.x, y` 定义为矩形**左上角**（如攻城北墙 `y=240, h=930`、城门 `y=1170, h=260`、南墙 `y=1430, h=930` 严丝合缝拼接），而 `StickmanBattleRenderer` 误将 `st.x, st.y` 当作中心点减去半宽半高绘制，导致 `930px` 长城墙纵向错位达 `465px`；`BattleTacticalAI` 瞄准箭塔/城门/本阵时也未加 `width * 0.5, height * 0.5`。
   - **修复**：统一修正 `StickmanBattleRenderer.ets` 与 `BattleTacticalAI.ets` 按左上角 `st.x, st.y`（几何中心 `st.x + st.width * 0.5, st.y + st.height * 0.5`）解算，并同步校准测试桩结构物坐标。
3. **Bug C（`BattleSimulator.ets` 沙漠商盟断粮期雇佣兵退场条件被本阵保底产金永久阻断 & 应急民夫计数同步）**：
   - **原因**：`stepLogisticsAndEconomy` 首行先加本阵保底产金 `+1.62 金/s`，而外籍雇佣兵在断粮期不消耗折银军饷，导致只要大营未破 `playerGold <= 0` 永远为假，`DESIGN.md` 10.1“商盟断粮饥溃且无金时外籍雇佣兵退场”永不触发；此外 `spawnFreeEmergencySapper` 未同步累加 `playerAliveCount / playerPopUsed` 与 `hudDirty`。
   - **修复**：在断粮期（`grain <= 0`）令商盟外籍雇佣兵按人数扣减应急折银军饷（`0.35 金/人·秒`），耗尽金币且断粮 `>30s`（`STARVING`）时真实触发雇佣军集体离场；同步补齐 `spawnFreeEmergencySapper` 与 `dismissMercenaries` 的人口与 `hudDirty` 更新。
4. **Bug D（`DiplomacyEngine.ets` 战前边缘讹诈仅判断负向金币，遗漏索城/索粮讹诈破裂开战）**：
   - **原因**：`executePeaceNegotiation` 在 `NEUTRAL` 态谈判破裂分支仅判断了 `terms.goldIndemnity < 0`，若求方 `goldIndemnity === 0` 但强索对方城池或分期纳粮（`breakdown.offerValue < 0`）遭斥退，未按 `DESIGN.md` 10.4 触发当回合直接宣战。
   - **修复**：将讹诈判定条件修正为 `breakdown.offerValue < 0`，覆盖索金、索粮、索城全部战前讹诈形态。

### 5.3 各轮次 Node 单测真跑结果完整台账

| 轮次 | 执行测试套件 | 结果 | 详情（失败位置 / 原因 / 本轮修复内容） |
| :--- | :--- | :---: | :--- |
| **Round 1（基线首跑）** | `test_combat.mjs`<br>`test_ai.mjs`<br>`test_campaign_diplomacy.mjs`<br>`test_renderer.mjs` | **1 败 3 过**<br>（`combat` 10/11 败于 L907；`ai` 15/15 过；`campaign` 10/10 过；`renderer` 5/5 过） | `test_combat.mjs:907` 报错 `actual 'wounded_weakened' !== expected 'fallen_martyred'`。经逐帧排查确认为测试包扎等待循环未拉开无敌敌骑 `eSq`，致 `pSq` 溃逃满 `10s` 在 `i=457` 提前触发 `player_army_routed` 终局。 |
| **Round 2（修 L907 + 修引擎 Bug A/B/C）** | 四套全跑 | **4 套全过**<br>（`combat` 12/12，`ai` 15/15，`campaign` 10/10，`renderer` 5/5） | 修复 `test_combat.mjs` 包扎期敌我驻防隔离，同时落地 `BattleSimulator` 近战攻帅、`StickmanBattleRenderer` 与 `BattleTacticalAI` 城防左上角坐标修正及商盟折银逻辑，原有全部用例跑通。 |
| **Round 3（扩充四大引擎新边界与闭环单测后首跑）** | 新增 `combat` 13~15、`ai` 16、`campaign` 11~12、`renderer` [6/6] 后全跑 | **4 套均检出新用例适配问题** | ① `test_combat` 13B 败于 `L1073`（RTS 模式下主帅自卫先手震晕贴脸巨斧兵，需设 `attackCooldown=1.0` 测受击）；<br>② `test_ai` 16 调错方法名 `tick`（实为 `step(world, dtSec)`）；<br>③ `test_campaign` 11 净分落入 `counter_offer` 档（调整筹码落入 `<-20` `rejected_breakdown`），12 调错方法名（实为 `setupReliefAmbush`）；<br>④ `test_renderer` [6/6] 误读 `strokeCalls`（实为 `mockCtx.strokeCount`）。 |
| **Round 4（修正新用例调用签名后再跑）** | 四套全跑 | **2 过 2 败**<br>（`ai` 16/16 过、`campaign` 12/12 过；`combat` 败于 14A，`renderer` 败于 [6/6]） | ① `test_combat` 13A/13B/13C 全部通过！14A 败因：`BattleInitConfig` 无 `playerInitialGold` 字段，开局恒为 `500` 金，改为实打实招募 4 名游骑兵（`4×125=500`）耗至 `0` 金；<br>② `test_renderer` [6/6] 败因：攻城战 3 秒时相机对准 `x=3350` 处于战争迷雾遮蔽区，`visibleSoldiers=0`。 |
| **Round 5（修正 14A 耗金与攻城视口后再跑）** | `test_combat.mjs`<br>`test_renderer.mjs` | **2 套继续收敛** | ① `test_combat` 14A（`25s` 免费刷应急民夫）通过！14B 败因：初始给 `15` 粮耗时 `10.3s` 才归零，`36s` 时断粮仅 `25.7s < 30s`（仍处 `hungry`），改为 `playerInitialGrain: 0`；<br>② `test_renderer` [6/6] 核对 `BattleSimulator` 攻城战地图宽 `5600`（城墙位于 `wallX = 4020`），改为直接读取 `realBattleView.structures` 校验北墙+城门+南墙无缝拼接与 `recordedFillRects` 精确匹配。 |
| **Round 6（验证渲染闭环与商盟折银速率）** | 四套全跑 | **3 过 1 败**<br>（`ai` 16/16、`campaign` 12/12、`renderer` 6/6 全过；`combat` 败于 14B） | `test_renderer.mjs` 全部 6 大模块 100% 通过！`test_combat` 14B 中 4 名纯金步兵每秒折银 `1.40` 小于商盟大营保底产金 `1.62`，补充外籍巨斧雇佣团编制（共 16 名雇佣兵）压倒保底产金。 |
| **Round 7（验证雇佣兵退场后大营回金时序）** | `test_combat.mjs` | **定位帧时序细节** | 第 `30.1s` 金币归零并已成功触发全部 16 名雇佣兵离场，随后至 `36.0s` 的 `5.9s` 内因雇佣兵已清空，大营保底回升了 `9` 金；将采样点校准至刚满 `30.5s` 饥溃退场时刻。 |
| **Round 8（最终全量回归验证）** | **`test_combat.mjs`**<br>**`test_ai.mjs`**<br>**`test_campaign_diplomacy.mjs`**<br>**`test_renderer.mjs`** | **4 套 100% 全部通过** | - `test_combat.mjs`：**15 / 15 通过**（330 人混战基准 `avg=1.46ms, p95=1.76ms < 5ms`）<br>- `test_ai.mjs`：**16 / 16 通过**<br>- `test_campaign_diplomacy.mjs`：**12 / 12 通过**<br>- `test_renderer.mjs`：**6 / 6 通过**（300 人 `stroke=25`、600 人 `stroke=23`、真实攻城城墙左上角无缝拼接） |

### 5.4 可复现审计脚本归档（`tools/`）与扫描结果
已将静态规范审计脚本与数值/大地图拓扑审计脚本迁入仓库 `tools/` 目录（均采用相对脚本路径自动定位仓库根目录，任何机器克隆后直接执行即可复现，发现问题返回非零退出码）：
1. `python3 tools/audit_arkts.py`：扫描全仓 **33 个 `.ets` 文件**（含新增 `core/`、`render/`、`storage/`、`config/`、`pages/`、`ohosTest/`），检查 `any/unknown`、`Record`、展开运算符、对象解构、纯逻辑层 `@kit.ArkUI` 耦合违规、路由未捕获 Promise、`main_pages.json` 对齐、`obfuscation-rules.txt` 属性白名单及中英资源对称性 —— **实跑结果：`Found 0 code/config issues`（退出码 `0`）**。
2. `python3 tools/audit_round1.py`：解析 `UnitConfig.ets`（16 兵种）与 `CampaignMapConfig.ets`（40 城关、78 条无交叉双向道路），验算战力/人口效率、等资源克制对局、无向图双向对称性、道路数精确等于 `78` 且 `0` 交叉、BFS `40/40` 单连通性与 8 势力开局 5 城经济极差 —— **实跑结果：8 势力总产出极差 `4.56% < 6%`，`0 ERRORS`（退出码 `0`）**。

---

## 六、大地图道路数专项裁定与拓扑收口记录（第 1 步收口核验）

### 6.1 裁定结论：精确锁定 **78 条** 对称双向无交叉道路
针对此前 `DESIGN.md` 写 78 条道路、`CampaignMapConfig.ets` 实配 82 条无向边（含 1 处道路悬空交叉）、测试仅断言 `>= 78` 的不一致问题，正式裁定战役大地图道路数为 **`78` 条**，理由如下：
1. **消除唯一道路交叉，实现 100% 平面图拓扑（`Crossings: 1 -> 0`）**：
   - 原 82 边拓扑中，`cl_pass（白狼山口, 1520,440）<-> yl_ferry（洛水渡口, 1480,980）` 与 `cl_pasture（牧马滩, 1660,680）<-> ty_bridge（蓝河铁桥, 1120,980）` 在旷野呈十字交叉。冷兵器时代不存在立体跨线桥，两条行军要道在无城塞/渡口节点处悬空相交违背真实地理常识，且会在平板 Canvas 动态绘制翠绿/琥珀/猩红三级粮道时造成线条穿插干扰。删去跨越 `cl_pasture` 的弦边 `cl_pass <-> yl_ferry` 后，全图实现 **0 道路交叉**。
2. **剪除 3 条绕过前线关隘/驿站的跨城长弦，强化冷兵器“咽喉要塞 / 围点打援 / 截断粮道”战略纵深**：
   - 删 `sy_capital（巨熊冰堡）<-> sy_fjord（冰湾猎港）`（长 `712.0px`，距中间仓城 `sy_camp 雪松林寨` 仅 `111px`）：消除贴城绕过的重复长弦，使 `雪松林寨` 真正成为连接王都与冰湾猎港的必经北境枢纽；
   - 删 `cl_fort（风蚀古堡）<-> xj_capital（玄甲棱堡）`（长 `664.8px`）：原边越过玄甲外围两座边防重镇 `xj_beacon（望北烽燧）` 与 `xj_plain（铁蹄平原城）` 直插王都，削弱了边关屏障作用；删后攻打玄甲王都必须先拔除外围边关，与其余诸侯王都防御纵深一致；
   - 删 `cl_river（饮马河营）<-> xj_plain（铁蹄平原城）`（长 `718.1px`，原全图第 3 长边）：消除绕开边境要塞 `cl_fort（风蚀古堡）` 的超长斜跨捷径，确立 `风蚀古堡` 在草原—高原交界处的咽喉锁钥价值。
3. **拓扑健康度与跨端设计基准全面统一**：
   - 与 `DESIGN.md` 第 235 行设计基准及姊妹篇 Mac 版（`78` 条道路）严格一致；
   - 全图 40 节点保持 100% 双向对称与单连通（`40/40`），节点度数收敛至更均衡的 **`3 ~ 5`**（消除原唯一 6 度拥挤节点 `yl_ferry`，且无任何 `< 3` 度的死胡同节点）；
   - 8 大势力各自内部 5 城 100% 连通，开局全部 40 城至本方仓城最短跳数均 `<= 1`（全员 `FULL_SUPPLY`），各国接壤邻国数（`3 ~ 6` 家）与开局总经济极差（`4.56% < 6%`）保持不变。

### 6.2 本步修改文件清单
1. `entry/src/main/ets/config/CampaignMapConfig.ets`：删除 `cl_pass<->yl_ferry`、`sy_capital<->sy_fjord`、`cl_fort<->xj_capital`、`cl_river<->xj_plain` 共 4 条无向边（8 处对称邻接表项），收敛至精确 **78 条** 无交叉双向道路，并同步文件头注释；
2. `entry/src/main/ets/common/GameConstants.ets`：新增单点真相源常量 `CAMPAIGN_ROAD_COUNT: number = 78`；
3. `entry/src/ohosTest/ets/test/Ability.test.ets`：在 `assertCampaignGraphSymmetricAndFullyConnected` 中新增 `directedEdgeCount === GameConstants.CAMPAIGN_ROAD_COUNT * 2`（78 条无向道路）精确断言；
4. `DESIGN.md`：统一第 33、205、235、350、377 行大地图道路与拓扑描述为“40 节点、78 条无交叉对称双向道路”，并将第 235 行初始经济配平区间同步为实测窄带 `1425 ~ 1490`；
5. `tests/node/test_campaign_diplomacy.mjs`（第 48 行）：收紧为精确断言 `assert.equal(audit.undirectedRoadCount, 78)`；
6. `tests/node/test_renderer.mjs`（第 766 行）：收紧为精确断言 `assert.equal(roadEdges.length, 78, ...)`；
7. `tools/audit_round1.py`：新增无向道路数精确等于 `78` 与道路几何交叉数精确等于 `0` 的自动化拓扑审计；
8. `PROGRESS.md`：如实增补本节道路数裁定、理由、改动文件清单与全量实跑通过数。

### 6.3 四套 Node 测试与两个审计脚本重跑结果（100% 通过）
| 验证项 | 运行命令 | 实跑通过数 / 结果 |
| :--- | :--- | :--- |
| **1. 战斗物理与主帅核心单测** | `node --experimental-transform-types --import ./tests/node/ets_loader.mjs tests/node/test_combat.mjs` | **15 / 15 通过** |
| **2. 三层战场战术与战略大地图 AI 单测** | `node --experimental-transform-types --import ./tests/node/ets_loader.mjs tests/node/test_ai.mjs` | **16 / 16 通过** |
| **3. 战役粮道、外交博弈与存档单测** | `node --experimental-transform-types --import ./tests/node/ets_loader.mjs tests/node/test_campaign_diplomacy.mjs` | **12 / 12 通过**（含 `undirectedRoadCount === 78` 精确断言） |
| **4. 战场骨骼合批与战略大地图渲染单测** | `node --experimental-transform-types --import ./tests/node/ets_loader.mjs tests/node/test_renderer.mjs` | **6 / 6 通过**（含 `roadEdges.length === 78` 精确断言） |
| **5. ArkTS 严格规范与工程配置审计** | `python3 tools/audit_arkts.py` | **33 / 33 个 `.ets` 文件 + 3 项工程配置检查全部通过**（`Found 0 code/config issues`，退出码 `0`） |
| **6. 数值平衡与 40 城 78 路平面拓扑审计** | `python3 tools/audit_round1.py` | **16 兵种 + 6 组克制对局 + 40 节点 / 78 条道路 / 0 交叉 / 40/40 连通 + 8 势力经济公平性（极差 `4.56%`）全部通过**（`0 ERRORS`，退出码 `0`） |

---

## 七、第二步（第 3 步全流程页面打通）：改动文件、各环节测试台账与未验证边界声明

### 7.1 本步新增与修改文件完整清单（严格仅修改 `~/workspace/stickman-war` 内文件）
1. **跨页面会话与底层适配层（新增 3 个文件，更新 5 个文件）**：
   - 新增 `entry/src/main/ets/core/session/GameSessionCoordinator.ets`：零 `@kit.ArkUI` 耦合的全流程会话协调中心，打通主菜单选势力、战前整军（遭遇战/守城/自定义）、真实战场模拟（`BattleSimulator` + `BattleTacticalAI` 闭环，含敌帅 `GRAND_WAR_CRY` 触发）、战后战俘处置与战役回写、40 城 78 路大地图行军/设伏/外交谈判/背盟门禁、7 家 AI 回合自动演化及 `SaveManager` / `SettingsStore` 协同；
   - 新增 `entry/src/main/ets/ui/ArkCanvas2DAdapter.ets`：`CanvasRenderingContext2D` 到 `ICanvas2DContext` 的严格名义类型适配器（满足 `arkts-no-structural-typing`，零 `any/unknown`，每页仅初始化 1 次）；
   - 新增 `entry/src/main/ets/entryability/HarmonyFilePersistenceBackend.ets` 及更新 `entry/src/main/ets/entryability/EntryAbility.ets`：基于 `@kit.CoreFileKit` (`fileIo`) 的离线应用沙箱持久化适配器（含只读/预览器内存回退容错），在 `EntryAbility.onCreate` 自动挂载；
   - 更新 `entry/src/main/ets/core/combat/BattleSimulator.ets`：新增 `triggerEnemyHeroSkill`，打通战术 AI 驱动敌帅释放三军战吼链路；
   - 更新 `entry/src/main/ets/render/StickmanBattleRenderer.ets` 与 `entry/src/main/ets/render/CampaignMapRenderer.ets`：新增 `setLodPolicyMode` 与 `setStylusPickRadiusPx`，使设置页远景骨骼 LOD 策略与 M-Pencil 灵敏度半径实时作用于双渲染器；
   - 更新 `entry/obfuscation-rules.txt`：补全 `CoreContracts`、`storage/` 及全部存档/设置序列化字段 `-keep-property-name` 白名单保护。
2. **七大 MatePad 横屏左右双栏页面全流程落地（全部按钮与交互热区 `>= 48vp`）**：
   - `entry/src/main/ets/pages/Index.ets`：左栏 6 大模式入口与进行中战役一键续玩卡片（36%）+ 右栏 8 大势力纹章卡片、专属王牌兵种与三阶科技检阅主视图（64%）；
   - `entry/src/main/ets/pages/SetupPage.ets`：左栏敌我势力切换、地形天象、携行军粮与 6 军团建制导航（38%）+ 右栏 16 兵种克制详评与实时增减编配主视图（62%）；
   - `entry/src/main/ets/pages/BattlePage.ets`：左栏 RTS 六军团/4 阵型/9 战术指令/大营补兵劫粮 或 亲自上阵英雄三兵刃（佩刀盾反/破阵大枪/24 箭硬弓）/大尺寸虚拟摇杆/三大技能操控台（30%，支持左右手摇杆对调）+ 右栏 4800×2400 / 5600×2600 实时火柴人骨骼交锋 Canvas 主视口（70%，支持双指捏合缩放、小地图秒跳、框选编队、M-Pencil 画线生成包抄航点、4Hz HUD 节流与终局结算跳转）；
   - `entry/src/main/ets/pages/BattleResultPage.ets`：左栏胜负战报、双方投入/阵亡/伤愈与主帅斩将统计（46%）+ 右栏物资缴获、战役战俘【收编入伍 / 遣返换赎金】抉择、孤城士气打击、晋升回写与大一统终局横幅（54%）；
   - `entry/src/main/ets/pages/CampaignPage.ets`：左栏【城关与行军（含夜袭/劫粮/围点打援/背盟二次确认强阻断）】、【外交纵横（正式宣战/互不侵犯/丝路通商/军事同盟/馈赠/朝贡附庸/挑拨离间/双重同盟居中调停/量化媾和估值预览与一键接受反报价）】、【整军与科技（含沙漠商盟纯金币雇佣契约与三阶专属科技）】三页签（36%）+ 右栏 3600×2400 战略大地图 40 城 78 路动态粮道与小地图 Canvas 主视口（64%）；
   - `entry/src/main/ets/pages/SavePage.ets`：左栏 `SaveManager` 6 个离线槽位（槽位 0 自动 + 槽位 1~5 手动）列表（58%）+ 右栏保存/读档进大地图/清空槽位与统帅累计战绩档案（42%）；
   - `entry/src/main/ets/pages/SettingsPage.ets`：左栏平板窗口像素与手写笔实时参数遥测（36%）+ 右栏 `SettingsStore` 60/30 FPS、骨骼 LOD 档位、左右手虚拟摇杆、M-Pencil 灵敏度与画线开关、音效音量与 40ms 重劈震屏开关（64%）。
3. **单测、审计与文档同步更新**：
   - 更新 `tools/audit_arkts.py`（新增全部 `pages/*.ets` 按钮与交互容器 `>= 48vp` 触控高度强校验）、`tests/node/test_combat.mjs`（新增第 16 项遭遇战全流程会话闭环单测）、`tests/node/test_campaign_diplomacy.mjs`（新增第 13 项战役大地图+外交+背盟门禁+行军会战+战俘回写+存读档+设置全流程闭环单测）、`tests/node/test_renderer.mjs`（新增 LOD 策略与手写笔半径联动校验）、`README.md` 与 `PROGRESS.md`。

### 7.2 分环节实跑测试与审计记录（每改完一个环节即跑满 4 套测试 + 2 个审计）
| 推进环节 | 四套 Node 测试结果 | 两个 Python 审计结果 | 过程问题与修复记录 |
| :--- | :--- | :--- | :--- |
| **环节 A：会话协调器 `GameSessionCoordinator` + 沙箱/画布适配器 + 渲染器设置钩子** | `combat` 15/15、`ai` 16/16、`campaign` 12/12、`renderer` 6/6 全过 | `audit_arkts` 36 文件 `0 issues`；`audit_round1` `0 ERRORS` | 一次性通过，无违规。 |
| **环节 B：`Index` → `SetupPage` → `BattlePage`（RTS+主帅上阵）→ `BattleResultPage` 闭环** | `combat` 15/15、`ai` 16/16、`campaign` 12/12、`renderer` 6/6 全过 | `audit_arkts` 36 文件 `0 issues`；`audit_round1` `0 ERRORS` | 一次性通过，无未捕获路由 Promise 或纯逻辑耦合。 |
| **环节 C：`CampaignPage`（40城78路+外交+内政）+ `SavePage` + `SettingsPage` 闭环** | `combat` 15/15、`ai` 16/16、`campaign` 12/12、`renderer` 6/6 全过 | `audit_arkts` 36 文件 `0 issues`；`audit_round1` `0 ERRORS` | 自检脚本检出 3 处未使用导入（`BilateralDiplomacyState`、`getUnitConfigById`、`UnitStaticStats`），当场清理归零。 |
| **环节 D：新增端到端会话闭环单测与 `>=48vp` 热区审计首跑** | `combat` **16/16** 过、`ai` **16/16** 过、`renderer` **6/6** 过；`campaign` **12/13**（新用例败于 L1257） | `audit_arkts` 36 文件（含 `>=48vp` 热区检查）`0 issues`；`audit_round1` `0 ERRORS` | `test_campaign_diplomacy.mjs:1257` 败因：先缔结了 `ALLIANCE` 再调用 `marchPlayerArmyToNode('ty_fort')`，按引擎与 `DESIGN.md` 规则军事同盟合法开放借道驻军（和平移防不触发背盟），而 `NON_AGGRESSION` 强行进军或对盟友宣战才触发背盟门禁。 |
| **环节 D 修正后终验（校准互不侵犯进军阻断 vs 同盟借道 + 盟友宣战背盟告警）** | **`test_combat.mjs`：16 / 16 通过**<br>**`test_ai.mjs`：16 / 16 通过**<br>**`test_campaign_diplomacy.mjs`：13 / 13 通过**<br>**`test_renderer.mjs`：6 / 6 通过** | **`audit_arkts.py`：36 / 36 `.ets` 文件 + 配置 + `>=48vp` 热区检查通过（`0 issues`）**<br>**`audit_round1.py`：16 兵种 + 40 城 78 路 0 交叉 + 8 国经济极差 `4.56%` 通过（`0 ERRORS`）** | **四套 Node 单测（共 51 项测试模块）与两套静态/拓扑审计 100% 全部通过！** |

### 7.3 已验证范围与未验证项如实声明（重要红线说明）
- **本机已实跑验证项**：
  1. 战斗物理、双曲护甲减伤、长枪 `+30%` 动能破甲反骑、八象限包抄/钳形夹击/铁桶合围/半渡而击、士气迟滞防抖、断粮三级惩罚、战争迷雾、主帅三兵刃/24支箭袋/0.25s精准弹反/三大技能/两段式落马及 330 人同屏帧耗时基准（`< 5ms`）；
  2. 三层战场战术 AI（7 大作战教条 + 攻守城三段式）与大地图 7 国战略 AI（自主攻伐、两线求和、反霸权合纵、断粮道与护仓城）；
  3. 40 城 78 条无交叉平面道路拓扑、BFS 补给线跳数与同盟借道、全套外交博弈（宣战、量化媾和与反报价封顶、互不侵犯、丝路通商、军事同盟、朝贡附庸、挑拨离间、背盟重罚与双重同盟防御豁免）、`SaveManager` 6 槽离线序列化防崩与 `SettingsStore` 参数持久化；
  4. `StickmanBattleRenderer` 与 `CampaignMapRenderer` 的 Mock Canvas 合批绘制（`stroke < 25`）、视口裁剪、多级 LOD、手写笔/手指拾取与小地图坐标正逆变换，以及 `GameSessionCoordinator` 跨页面全流程状态流转闭环；
  5. 全仓 36 个 `.ets` 文件的 ArkTS 严格静态规范扫描、路由异常捕获、`obfuscation-rules.txt` 白名单与全部 7 个页面 `>= 48vp` 平板触控热区扫描。
- **未验证项（必须如实声明）**：
  - **本机无 DevEco Studio（亦无 HarmonyOS NEXT SDK、`ohpm`、`hvigorw` 编译工具链），未执行 ArkTS/HAP 编译验证，未在鸿蒙真机或模拟器上验证实际 UI 布局呈现、Canvas 帧率表现与多指/M-Pencil 手势交互。**
