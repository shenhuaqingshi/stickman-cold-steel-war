/**
 * 核心数据模型与枚举定义（第 1 步：纯静态类型骨架，不含任何战斗计算逻辑）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（无 any / unknown / 未标注字面量）
 */

/** 八大势力唯一标识枚举 */
export enum FactionId {
  YANLONG = 'yanlong',       // 炎龙帝国
  CANGLANG = 'canglang',     // 苍狼汗国
  TIEYING = 'tieying',       // 铁鹰王国
  SHAMO = 'shamo',           // 沙漠商盟
  SHUANGYUAN = 'shuangyuan', // 霜原熊族
  WULIN = 'wulin',           // 雾林猎手
  XUANJIA = 'xuanjia',       // 玄甲重骑军团
  XUEYUE = 'xueyue'          // 血月祭司团
}

/** 兵种大类定位枚举 */
export enum UnitCategory {
  SUPPORT = 'support',       // 后勤辅兵/工兵
  INFANTRY = 'infantry',     // 步兵（刀盾/重步）
  POLEARM = 'polearm',       // 长柄反骑步兵
  RANGED = 'ranged',         // 远程弓弩兵
  CAVALRY = 'cavalry',       // 轻重骑兵
  SHOCK = 'shock',           // 重型破甲/狂战突击兵
  SIEGE = 'siege'            // 攻城与重型弩炮器械
}

/** 全部 16 种可招募单位 ID（8 通用兵种 + 8 势力专属王牌兵种） */
export enum UnitTypeId {
  // 8 种通用基础兵种
  SAPPER = 'sapper',                     // 辎重工兵（采金/伐木/征粮/筑垒）
  SHIELD_SWORDSMAN = 'shield_swordsman', // 刀盾步兵
  PIKEMAN = 'pikeman',                   // 长枪方阵兵
  COMPOSITE_ARCHER = 'composite_archer', // 复合弓手
  LIGHT_CAVALRY = 'light_cavalry',       // 游骑兵
  GREAT_AXEMAN = 'great_axeman',         // 重型巨斧兵
  BALLISTA = 'ballista',                 // 破甲连弩车
  TREBUCHET = 'trebuchet',               // 配重投石车

  // 8 种势力专属精锐兵种
  YANLONG_HALBERD_GRENADIER = 'yanlong_halberd_grenadier', // 炎龙神机重卫
  CANGLANG_KESHIG_HORSE_ARCHER = 'canglang_keshig',        // 苍狼怯薛骑射
  TIEYING_PAVISE_CROSSBOW = 'tieying_pavise_crossbow',     // 铁鹰重装神弩手
  SHAMO_MAMELUKE_CAMEL = 'shamo_mameluke_camel',           // 黄金马穆鲁克卫队
  SHUANGYUAN_GIANT_BREAKER = 'shuangyuan_giant_breaker',   // 霜原巨熊破阵者
  WULIN_SHADOW_SNIPER = 'wulin_shadow_sniper',             // 雾林影袭神射
  XUANJIA_CATAPHRACT = 'xuanjia_cataphract',               // 玄甲具装铁浮图
  XUEYUE_WARDRUM_BERSERKER = 'xueyue_wardrum_berserker'    // 血月狂战祭团
}

/** 部队编队阵型枚举 */
export enum FormationType {
  PHALANX_RECT = 'phalanx_rect', // 方阵（抗线防骑，正面护甲加成）
  ECHELON_LINE = 'echelon_line', // 雁行阵（最大化远程齐射火力面，降低被投石溅射）
  WEDGE_CHARGE = 'wedge_charge', // 锥形阵（骑兵/突击兵凿穿破阵，冲锋动量加成）
  CIRCLE_DEFENSE = 'circle_def'  // 圆阵（四面受敌无侧后翼弱点，防骑兵包抄）
}

/** 主帅与 AI 战场战术指令枚举（完整覆盖冷兵器复杂战术） */
export enum TacticalOrder {
  ADVANCE = 'advance',                 // 稳步推进（保持阵型接敌）
  HOLD_GROUND = 'hold',                // 原地坚守（据守高地/桥头不盲追）
  ALL_OUT_CHARGE = 'charge',           // 全军冲锋（高速奔袭撞阵）
  RETREAT = 'retreat',                 // 交替撤退（边退边格挡回撤重整）
  FLANK = 'flank',                     // 侧翼迂回包抄（弧线绕开正面切侧后）
  PINCER_ENCIRCLE = 'pincer_encircle', // 钳形夹击合围（双翼协同封堵退路）
  FEIGNED_RETREAT = 'feigned_retreat', // 诈败诱敌（佯装后撤引敌脱离阵线入伏）
  AMBUSH_HIDE = 'ambush_hide',         // 潜伏设伏（密林/反斜面隐蔽待机半渡而击）
  RAID_SUPPLY = 'raid_supply'          // 断粮奇袭（绕过主力专门焚掠工兵与粮车）
}

/** 多军团多战线建制角色枚举（前锋、两翼、预备队、护粮各司其职） */
export enum ArmyCorpsRole {
  VANGUARD_CENTER = 'vanguard_center', // 中军前锋（正面抗线吸火）
  LEFT_WING = 'left_wing',             // 左翼机动军团（北走廊迂回/护翼）
  RIGHT_WING = 'right_wing',           // 右翼机动军团（南走廊包抄/护翼）
  REAR_RESERVE = 'rear_reserve',       // 总预备队（关键时刻堵漏或决胜突击）
  SIEGE_BATTERY = 'siege_battery',     // 远程攻城群（高地压制与拆城）
  SUPPLY_ESCORT = 'supply_escort'      // 辎重护粮队（采集护卫与反偷袭）
}

/** 火柴人单兵程序化骨骼动作状态枚举（支撑真刀真枪拼杀视觉反馈） */
export enum UnitActionState {
  IDLE_READY = 'idle_ready',               // 持械戒备呼吸态
  MARCH_RUN = 'march_run',                 // 行军奔跑摆臂迈腿态
  CHARGE_SPRINT = 'charge_sprint',         // 压低身姿全力冲锋撞阵态
  MELEE_WINDUP = 'melee_windup',           // 挥砍/刺击前摇蓄力态
  MELEE_STRIKE = 'melee_strike',           // 刀劈/枪刺/斧砸命中挥击态
  RANGED_DRAW_FIRE = 'ranged_draw_fire',   // 挽弓搭箭/踏张上弦抛射态
  SHIELD_BLOCK = 'shield_block',           // 举盾格挡火星迸溅态
  STAGGER_HIT = 'stagger_hit',             // 受击后仰/被战马撞飞击退态
  ROUT_PANIC = 'rout_panic',               // 士气崩溃弃盾抱头溃逃态
  DYING_FALL = 'dying_fall',               // 致命伤倾倒动画态
  FALLEN_CORPSE = 'fallen_corpse'          // 战场倒地遗骸态（定量留存烘托惨烈战场）
}

/** 分队受围态势枚举（八象限受敌扇区实时判定） */
export enum EncirclementState {
  CLEAR = 'clear',             // 正面正常交战
  FLANKED = 'flanked',         // 单侧或背后遭袭（伤害与士气损耗上升）
  PINCERED = 'pincered',       // 钳形夹击（双方向钝角受敌，阵型松动持续掉士气）
  ENCIRCLED = 'encircled'      // 铁桶合围（>=5扇区受敌且退路断绝，士气雪崩）
}

/** 主帅英雄模式武器切换枚举 */
export enum HeroWeaponType {
  COMMAND_SABER = 'saber',   // 统帅佩刀（配盾格挡弹反 + 扇形挥砍）
  BREAKER_SPEAR = 'spear',   // 破阵大枪（中距高破甲突刺 + 反骑）
  HEAVY_WARBOW = 'warbow'    // 百石硬弓（蓄力狙击 + 箭袋容量限制）
}

/** 战场与大地图地形类型枚举 */
export enum TerrainType {
  PLAIN = 'plain',           // 开阔平原
  HIGH_GROUND = 'highland',  // 制高点/山坡
  RIVER_FORD = 'river_ford', // 河流浅滩
  BRIDGE_PASS = 'bridge',    // 桥梁/狭窄关口
  DENSE_FOREST = 'forest',   // 迷雾密林
  DESERT_DUNE = 'desert',    // 荒漠沙丘
  SNOWFIELD = 'snowfield',   // 极寒雪原
  FORT_WALL = 'fort_wall'    // 城墙/要塞掩体
}

/** 天气与昼夜状态枚举 */
export enum WeatherType {
  CLEAR_DAY = 'clear_day',   // 晴朗白昼
  HEAVY_FOG = 'heavy_fog',   // 浓雾弥漫
  RAIN_MUD = 'rain_mud',     // 暴雨泥泞
  BLIZZARD = 'blizzard',     // 凛冽暴雪
  NIGHT = 'night'            // 幽暗黑夜
}

/** 战役关卡战斗类型枚举 */
export enum BattleScenarioType {
  FIELD_PITCHED = 'field_pitched', // 标准野战会战
  SIEGE_ASSAULT = 'siege_assault', // 攻城攻坚战
  SIEGE_DEFENSE = 'siege_defense', // 据城死守战
  AMBUSH = 'ambush',               // 峡谷/密林伏击战
  CONVOY_ESCORT = 'convoy_escort', // 粮道护送/劫粮战
  NIGHT_RAID = 'night_raid'        // 劫营夜袭战
}

/** 外交条约状态枚举 */
export enum DiplomaticStatus {
  WAR = 'war',                       // 交战状态
  TRUCE = 'truce',                   // 停战协定期（毁约触发背盟惩罚）
  NEUTRAL = 'neutral',               // 中立状态
  NON_AGGRESSION = 'non_aggression', // 互不侵犯条约
  TRADE_PACT = 'trade_pact',         // 通商协定
  ALLIANCE = 'alliance',             // 军事攻守同盟
  VASSAL = 'vassal'                  // 朝贡附庸关系
}

/** AI 战略与战术性格原型枚举 */
export enum AiPersonality {
  IMPERIAL_METHODICAL = 'imperial_methodical', // 王道推进（重步攻城、守信死战）
  NOMAD_OPPORTUNIST = 'nomad_opportunist',     // 游牧掠夺（两翼包抄、见弱则攻）
  FORTRESS_COUNTER = 'fortress_counter',       // 稳健筑垒（高地强弩、防守反击）
  MERCHANT_PRAGMATIC = 'merchant_pragmatic',   // 金元算计（雇佣混编、重金交易）
  HONOR_BERSERK_BEAR = 'honor_bear',           // 豪迈勇武（正面硬刚、敬重强者）
  GUERRILLA_TRAPPER = 'guerrilla_trapper',     // 诡道伏击（诱敌深入、密林陷阱）
  IRON_SHOCK_ELITE = 'iron_shock_elite',       // 傲慢铁血（具装凿穿、宁折不弯）
  ZEALOT_SWARM = 'zealot_swarm'                // 狂热扩张（夜袭人海、献祭死斗）
}

/** 三维资源消耗结构 */
export interface ResourceCost {
  readonly gold: number;
  readonly wood: number;
  readonly grain: number;
}

/** 单位静态数值配置接口（严格对齐 DESIGN.md 兵种表） */
export interface UnitStaticStats {
  readonly id: UnitTypeId;
  readonly name: string;
  readonly category: UnitCategory;
  /** 若为 null 表示全势力通用，否则仅对应势力（或商盟雇佣特定池）可招募 */
  readonly exclusiveFaction: FactionId | null;
  readonly hp: number;
  readonly attack: number;
  /** 破甲比例（0.0 ~ 1.0，无视目标对应比例的护甲减伤） */
  readonly armorPenetration: number;
  /** 基础护甲值（点） */
  readonly armor: number;
  /** 正面盾牌远程减伤率（0.0 ~ 0.85） */
  readonly shieldRangedBlock: number;
  /** 攻击距离（逻辑 px，近战约 22~48，远程 280~950） */
  readonly attackRange: number;
  /** 最小盲区射程（逻辑 px，投石车/连弩车近身无法开火） */
  readonly minRange: number;
  /** 攻击间隔（秒/次） */
  readonly attackIntervalSec: number;
  /** 基础移动速度（逻辑 px/秒） */
  readonly moveSpeed: number;
  /** 冲锋伤害倍率（助跑成型后首击倍率，非冲锋单位为 1.0） */
  readonly chargeMultiplier: number;
  /** 反骑伤害倍率（迎击冲锋骑兵时的伤害倍率，普通单位 1.0） */
  readonly antiCavalryMultiplier: number;
  /** 招募资源花费 */
  readonly cost: ResourceCost;
  /** 训练耗时（秒） */
  readonly buildTimeSec: number;
  /** 占用人口数 */
  readonly popCap: number;
  /** 战场每秒消耗粮草值 */
  readonly grainUpkeepPerSec: number;
  /** 兵种战术特色简述 */
  readonly traitDesc: string;
}

/** 势力专属科技节点配置 */
export interface FactionTechItem {
  readonly id: string;
  readonly name: string;
  readonly effectSummary: string;
  readonly cost: ResourceCost;
}

/** 八大势力静态配置接口 */
export interface FactionStaticConfig {
  readonly id: FactionId;
  readonly name: string;
  readonly bannerTitle: string;
  readonly primaryColor: string;
  readonly accentColor: string;
  readonly specialtyTag: string;
  readonly exclusiveUnitId: UnitTypeId;
  readonly aiPersonality: AiPersonality;
  readonly capitalNodeId: string;
  readonly homeTerrain: TerrainType;
  readonly bonusSummary: string;
  readonly weaknessSummary: string;
  readonly startingCredibility: number;
  readonly uniqueTechs: readonly FactionTechItem[];
}

/** 战役大地图节点类型枚举 */
export enum CampaignNodeType {
  CAPITAL_CITADEL = 'capital', // 王都巨城（高城防、核心仓城、高产金粮）
  FORTRESS_PASS = 'pass',      // 险要雄关（一夫当关、守军护甲士气加成）
  GRANARY_TOWN = 'granary',    // 粮仓重镇（提供高额粮草与补给中继）
  RESOURCE_HUB = 'resource',   // 矿山/林场/商埠（高额金币或木材产出）
  CROSSING_OUTPOST = 'outpost' // 渡口/绿洲前哨（交通咽喉）
}

/** 战役大地图节点静态配置接口 */
export interface CampaignNodeConfig {
  readonly id: string;
  readonly name: string;
  readonly regionIndex: number;
  readonly regionName: string;
  readonly nodeType: CampaignNodeType;
  /** 大地图逻辑坐标 X (0 ~ 3600) */
  readonly x: number;
  /** 大地图逻辑坐标 Y (0 ~ 2400) */
  readonly y: number;
  readonly initialOwner: FactionId;
  readonly terrain: TerrainType;
  readonly defenseLevel: number;
  readonly goldYield: number;
  readonly woodYield: number;
  readonly grainYield: number;
  /** 是否可作为远征补给线根源仓城 */
  readonly isSupplyDepot: boolean;
  /** 相邻连通节点 ID 列表（无向边） */
  readonly neighbors: readonly string[];
}

/** 双边外交关系数据结构 */
export interface BilateralDiplomacyState {
  readonly factionA: FactionId;
  readonly factionB: FactionId;
  /** 关系值 [-100, +100] */
  relation: number;
  status: DiplomaticStatus;
  /** 停战或条约剩余回合数 */
  remainingTurns: number;
  /** 世仇禁谈剩余回合数（背盟触发） */
  vendettaLockTurns: number;
}

/** 媾和/外交谈判条件报价单接口 */
export interface PeaceOfferTerms {
  readonly proposer: FactionId;
  readonly target: FactionId;
  readonly goldIndemnity: number;
  readonly grainTributePerTurn: number;
  readonly cededNodeIds: readonly string[];
  readonly truceTurns: number;
}

/** 本地存档槽位摘要信息 */
export interface SaveSlotSummary {
  readonly slotIndex: number;
  readonly title: string;
  readonly factionId: FactionId;
  readonly turnNumber: number;
  readonly controlledNodes: number;
  readonly updatedAtIso: string;
  readonly isEmpty: boolean;
}

/** Stage 页面路由显式参数接口（遵循 arkts-no-untyped-obj-literals 规范） */
export interface RouteLaunchParams {
  readonly modeKey: string;
  readonly modeTitle: string;
  readonly factionId: FactionId;
}

