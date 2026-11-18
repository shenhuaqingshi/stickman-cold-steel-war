/**
 * 跨模块核心运行时契约与状态接口（CoreContracts.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖）
 * 作为 combat / ai / campaign / diplomacy / storage / render / pages 并行开发的统一接口契约
 */
import {
  AiPersonality,
  ArmyCorpsRole,
  BattleScenarioType,
  BilateralDiplomacyState,
  DiplomaticStatus,
  EncirclementState,
  FactionId,
  FormationType,
  HeroWeaponType,
  PeaceOfferTerms,
  SaveSlotSummary,
  TacticalOrder,
  TerrainType,
  UnitActionState,
  UnitCategory,
  UnitTypeId,
  WeatherType
} from '../model/GameTypes';

/** 战场阵营归属枚举 */
export enum BattleSide {
  PLAYER = 'player',
  ENEMY = 'enemy'
}

/** 战场操控视角模式枚举 */
export enum BattleControlMode {
  RTS_COMMANDER = 'rts_commander',
  HERO_ACTION = 'hero_action'
}

/** 战场断粮三阶段状态枚举（对应 DESIGN.md 10.1） */
export enum BattlefieldRationStage {
  ABUNDANT = 'abundant', // 余粮充沛
  WARNING = 'warning',   // 余粮 < 15s 告警
  HUNGRY = 'hungry',     // 断粮 0~30s（士气每秒 -0.8，移速 -12%，冲锋冷却 +50%）
  STARVING = 'starving'  // 断粮 > 30s（士气每秒 -1.8，攻击 -25%，商盟无金雇佣兵离场）
}

/** 主帅生命安全两段式状态枚举（对应 DESIGN.md 10.2） */
export enum HeroVitalState {
  HEALTHY_ACTIVE = 'healthy_active',       // 正常作战（享首次落马抢救保护）
  RECOVERING_IN_CAMP = 'recovering_camp',  // 首次落马回营包扎中（45s，全军士气上限锁 65）
  WOUNDED_WEAKENED = 'wounded_weakened',   // 重创虚弱复出（35% 残血，属性 -25%，无免死）
  FALLEN_MARTYRED = 'fallen_martyred'      // 二次阵亡或本阵已破殉国
}

/** 主帅三大主动技能枚举 */
export enum HeroSkillId {
  BREAKTHROUGH_CHARGE = 'breakthrough_charge', // 破阵突击（CD 10s，猛冲 160px）
  IRON_BULWARK = 'iron_bulwark',               // 铁壁横戈（CD 8s，2s 格挡弹反+横扫）
  GRAND_WAR_CRY = 'grand_war_cry'              // 三军战吼（CD 22s，320px +18 士气唤醒溃军）
}

/** 战场终局胜负原因枚举 */
export enum BattleOutcomeReason {
  ONGOING = 'ongoing',
  ENEMY_BASE_DESTROYED = 'enemy_base_destroyed',
  ENEMY_ARMY_ROUTED = 'enemy_army_routed',
  SIEGE_DEFENSE_HELD = 'siege_defense_held',
  PLAYER_HERO_MARTYRED = 'player_hero_martyred',
  PLAYER_BASE_DESTROYED = 'player_base_destroyed',
  PLAYER_ARMY_ROUTED = 'player_army_routed',
  TRUCE_NEGOTIATED = 'truce_negotiated'
}

/** 投射物类型枚举 */
export enum ProjectileKind {
  ARROW = 'arrow',
  CROSSBOW_BOLT = 'crossbow_bolt',
  BALLISTA_SPEAR = 'ballista_spear',
  TREBUCHET_BOULDER = 'trebuchet_boulder',
  FIRE_BOMB = 'fire_bomb'
}

/** 战场地形功能区矩形/多边形近似包络 */
export interface TerrainZoneRect {
  readonly id: string;
  readonly terrain: TerrainType;
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  /** 高地海拔加成层级（0=平地，1=山坡高地，2=城头） */
  readonly elevation: number;
}

/** 战场资源采集点（金矿/林场/农庄粮垛） */
export interface BattlefieldResourceNode {
  readonly id: string;
  readonly resourceKind: 'gold' | 'wood' | 'grain';
  readonly x: number;
  readonly y: number;
  remainingAmount: number;
  readonly maxAmount: number;
}

/** 战场城防/大营建筑实体（本阵大营、城门、城墙段、箭塔、拒马） */
export interface FortStructureEntity {
  readonly id: string;
  readonly side: BattleSide;
  readonly kind: 'base_camp' | 'gate' | 'wall_segment' | 'arrow_tower' | 'wooden_stakes';
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
  hp: number;
  readonly maxHp: number;
  isBreached: boolean;
}

/** 单名火柴人士兵运行时实体（对象池预分配复用，严禁每帧 new） */
export interface SoldierRuntimeEntity {
  active: boolean;
  readonly poolIndex: number;
  side: BattleSide;
  factionId: FactionId;
  unitType: UnitTypeId;
  category: UnitCategory;
  squadId: number;
  corpsRole: ArmyCorpsRole;
  /** 是否为该军团高辨识度执旗官（被斩杀触发军团 -15 士气） */
  isBannerBearer: boolean;
  /** 是否为沙漠商盟纯金币雇佣兵 */
  isMercenary: boolean;
  x: number;
  y: number;
  vx: number;
  vy: number;
  facingRad: number;
  hp: number;
  maxHp: number;
  actionState: UnitActionState;
  /** 当前骨骼动作相位（0.0 ~ 1.0，供 Canvas 8 关节解算使用） */
  animPhase: number;
  attackCooldown: number;
  chargeRunTime: number;
  chargeCooldown: number;
  staggerTimer: number;
  poisonTimer: number;
  /** 雾林神射潜行态或密林隐蔽态 */
  isStealthed: boolean;
  /** 对敌方可见性（战争迷雾判定结果） */
  visibleToPlayer: boolean;
  visibleToEnemy: boolean;
  /** 炎龙火雷是否已投掷 */
  grenadeUsed: boolean;
  /** 分配的阵型局部槽位偏移 */
  slotOffsetX: number;
  slotOffsetY: number;
  targetEntityIndex: number;
}

/** 作战分队/军团运行时状态（对应 1~6 号建制军团或细分大队） */
export interface SquadRuntimeState {
  readonly squadId: number;
  readonly side: BattleSide;
  readonly factionId: FactionId;
  readonly corpsRole: ArmyCorpsRole;
  readonly name: string;
  primaryUnitType: UnitTypeId;
  formation: FormationType;
  order: TacticalOrder;
  morale: number;
  isRouting: boolean;
  encirclement: EncirclementState;
  /** 八象限受敌掩码（bit 0~7） */
  threatOctantMask: number;
  centerX: number;
  centerY: number;
  facingRad: number;
  targetX: number;
  targetY: number;
  /** M-Pencil 手写笔或迂回战术航点队列 */
  waypointsX: number[];
  waypointsY: number[];
  waypointCursor: number;
  aliveCount: number;
  initialCount: number;
  bannerAlive: boolean;
  bannerLostPenaltyTimer: number;
  /** 涉水人数比例（0.0 ~ 1.0，30%~80% 触发半渡而击） */
  fordRatio: number;
   halfFordShockApplied: boolean;
}

/** 主帅英雄运行时实体状态（玩家主帅与敌方督战主帅通用） */
export interface CommanderHeroRuntime {
  readonly side: BattleSide;
  readonly factionId: FactionId;
  readonly name: string;
  x: number;
  y: number;
  vx: number;
  vy: number;
  facingRad: number;
  hp: number;
  maxHp: number;
  armor: number;
  moveSpeed: number;
  vitalState: HeroVitalState;
  recoveryTimer: number;
  activeWeapon: HeroWeaponType;
  remainingArrows: number;
  arrowRecoverTimer: number;
  attackCooldown: number;
  isBlocking: boolean;
  parryWindowTimer: number;
  ironBulwarkTimer: number;
  warCryBuffTimer: number;
  chargeCooldown: number;
  bulwarkCooldown: number;
  warCryCooldown: number;
  actionState: UnitActionState;
  animPhase: number;
  kills: number;
}

/** 飞行箭矢/弩矢/火雷/投石车巨石实体（对象池复用） */
export interface ProjectileRuntimeEntity {
  active: boolean;
  readonly poolIndex: number;
  side: BattleSide;
  kind: ProjectileKind;
  startX: number;
  startY: number;
  x: number;
  y: number;
  vx: number;
  vy: number;
  arcHeight: number;
  flightProgress: number;
  flightDuration: number;
  damage: number;
  armorPenetration: number;
  splashRadius: number;
  pierceRemaining: number;
  applyPoison: boolean;
  moraleShock: number;
}

/** 战场倒地遗骸与折断旌旗环形贴花池元素（上限 150） */
export interface FallenCorpseDecal {
  active: boolean;
  x: number;
  y: number;
  rotationRad: number;
  factionId: FactionId;
  isBrokenBanner: boolean;
  alpha: number;
}

/** 受击火花/暴击飘字轻量视觉反馈事件 */
export interface CombatHitEffect {
  active: boolean;
  x: number;
  y: number;
  kind: 'slash_arc' | 'shield_spark' | 'boulder_crater' | 'morale_burst' | 'blood_splash';
  ttl: number;
  maxTtl: number;
  angleRad: number;
}

/** 玩家 RTS 编队调度输入请求 */
export interface SquadCommandRequest {
  readonly squadIds: readonly number[];
  readonly formation?: FormationType;
  readonly order?: TacticalOrder;
  readonly targetX?: number;
  readonly targetY?: number;
  readonly customWaypointsX?: readonly number[];
  readonly customWaypointsY?: readonly number[];
}

/** 玩家主帅英雄模式即时操控输入帧状态 */
export interface HeroControlInput {
  moveX: number;
  moveY: number;
  aimX: number;
  aimY: number;
  isAttackPressed: boolean;
  isBlockHeld: boolean;
}

/** 节流同步给 ArkUI 顶部/右侧面板的轻量战场 HUD 快照（4Hz 更新） */
export interface BattleHudSnapshot {
  readonly elapsedSec: number;
  readonly isPaused: boolean;
  readonly controlMode: BattleControlMode;
  readonly switchCooldownSec: number;
  readonly garrisonBellActive: boolean;
  readonly playerGold: number;
  readonly playerWood: number;
  readonly playerGrain: number;
  readonly playerRationStage: BattlefieldRationStage;
  readonly enemyRationStage: BattlefieldRationStage;
  readonly playerAliveSoldiers: number;
  readonly playerPopUsed: number;
  readonly playerPopCap: number;
  readonly enemyAliveSoldiers: number;
  readonly playerAvgMorale: number;
  readonly enemyAvgMorale: number;
  readonly heroHp: number;
  readonly heroMaxHp: number;
  readonly heroVitalState: HeroVitalState;
  readonly heroWeapon: HeroWeaponType;
  readonly heroArrows: number;
  readonly chargeCd: number;
  readonly bulwarkCd: number;
  readonly warCryCd: number;
  readonly hitStopRemainingMs: number;
  readonly outcome: BattleOutcomeReason;
}

/** 战前整军开战初始化配置参数 */
export interface BattleInitConfig {
  readonly scenarioType: BattleScenarioType;
  readonly playerFaction: FactionId;
  readonly enemyFaction: FactionId;
  readonly terrain: TerrainType;
  readonly weather: WeatherType;
  readonly playerInitialGrain: number;
  readonly enemyInitialGrain: number;
  readonly playerMoraleModifier: number;
  readonly enemyMoraleModifier: number;
  /** 玩家战前编配兵种数量表（若为空则使用势力标准百人多军团预设） */
  readonly playerArmyRoster: readonly RosterEntry[];
  readonly enemyArmyRoster: readonly RosterEntry[];
  readonly campaignNodeId: string;
  readonly siegeHoldDurationSec: number;
}

/** 兵种数量编制项 */
export interface RosterEntry {
  readonly unitType: UnitTypeId;
  readonly count: number;
  readonly corpsRole: ArmyCorpsRole;
}

/** 战场完整可读世界引用（供 Canvas 渲染器与战术 AI 读取） */
export interface BattleWorldReadonlyView {
  readonly width: number;
  readonly height: number;
  readonly scenarioType: BattleScenarioType;
  readonly primaryTerrain: TerrainType;
  readonly weather: WeatherType;
  readonly playerFaction: FactionId;
  readonly enemyFaction: FactionId;
  readonly terrainZones: readonly TerrainZoneRect[];
  readonly resourceNodes: readonly BattlefieldResourceNode[];
  readonly structures: readonly FortStructureEntity[];
  readonly soldiers: readonly SoldierRuntimeEntity[];
  readonly squads: readonly SquadRuntimeState[];
  readonly playerHero: CommanderHeroRuntime;
  readonly enemyHero: CommanderHeroRuntime;
  readonly projectiles: readonly ProjectileRuntimeEntity[];
  readonly corpses: readonly FallenCorpseDecal[];
  readonly hitEffects: readonly CombatHitEffect[];
  readonly hud: BattleHudSnapshot;
}

/** 战后结算摘要契约 */
export interface BattleSettlementSummary {
  readonly scenarioType: BattleScenarioType;
  readonly campaignNodeId: string;
  readonly playerFaction: FactionId;
  readonly enemyFaction: FactionId;
  readonly isVictory: boolean;
  readonly outcomeReason: BattleOutcomeReason;
  readonly durationSec: number;
  readonly playerInitialTotal: number;
  readonly playerKilled: number;
  readonly playerWoundedRecovered: number;
  readonly enemyInitialTotal: number;
  readonly enemyKilled: number;
  readonly capturedPrisoners: number;
  readonly lootedGold: number;
  readonly lootedWood: number;
  readonly lootedGrain: number;
  readonly heroKills: number;
  readonly commanderExpGained: number;
}

// ==================== 战役、粮道与外交核心契约 ====================

/** 大地图节点补给线连通等级 */
export enum SupplyLineGrade {
  FULL_SUPPLY = 'full_supply',         // d <= 2，100% 补给
  EXTENDED_MARCH = 'extended_march',   // d == 3，耗粮 +25%，携粮 -15%
  OVEREXTENDED = 'overextended',       // d >= 4，耗粮 +50%
  SEVERED = 'severed'                  // d == Infinity，粮道被断
}

/** 节点补给评估结果 */
export interface SupplyEvaluationResult {
  readonly nodeId: string;
  readonly grade: SupplyLineGrade;
  readonly hops: number;
  readonly nearestDepotNodeId: string;
  readonly pathNodeIds: readonly string[];
  readonly upkeepMultiplier: number;
  readonly initialGrainMultiplier: number;
}

/** 媾和谈判三档量化评估结果 */
export enum PeaceOutcomeKind {
  ACCEPTED = 'accepted',
  COUNTER_OFFER = 'counter_offer',
  REJECTED_BREAKDOWN = 'rejected_breakdown'
}

/** 媾和谈判评估返回结构 */
export interface PeaceEvaluationResult {
  readonly kind: PeaceOutcomeKind;
  readonly netScore: number;
  readonly explanation: string;
  readonly counterTerms: PeaceOfferTerms | null;
}

/** 背盟或宣战影响评估结果（含双重同盟防御豁免判定） */
export interface BetrayalAssessment {
  readonly isBetrayalTriggered: boolean;
  readonly explanation: string;
  readonly credibilityDelta: number;
  readonly globalRelationDelta: number;
  readonly vendettaTurns: number;
  readonly battleMoralePenalty: number;
}

/** 大地图城关动态运行时状态 */
export interface CampaignNodeRuntime {
  readonly nodeId: string;
  owner: FactionId;
  garrisonStrength: number;
  defenseHp: number;
  isolatedTurns: number;
  hasAmbushTrap: boolean;
  supplyGrade: SupplyLineGrade;
  supplyHops: number;
}

/** 大地图势力动态运行时状态 */
export interface FactionCampaignRuntime {
  readonly factionId: FactionId;
  readonly isAlive: boolean;
  gold: number;
  wood: number;
  grain: number;
  credibility: number;
  unlockedTechIds: string[];
  commanderLevel: number;
  commanderExp: number;
  betrayalMoralePenaltyBattles: number;
  commanderInjuredTurns: number;
  fieldArmyRoster: RosterEntry[];
  armyLocationNodeId: string;
}

/** 战役全局可序列化存档状态 */
export interface CampaignSaveState {
  readonly schemaVersion: number;
  turnNumber: number;
  playerFaction: FactionId;
  nodes: CampaignNodeRuntime[];
  factions: FactionCampaignRuntime[];
  diplomacy: BilateralDiplomacyState[];
  totalBattlesFought: number;
  totalBattlesWon: number;
  totalEnemiesKilled: number;
  recentLogs: string[];
}

export {
  AiPersonality,
  ArmyCorpsRole,
  BattleScenarioType,
  BilateralDiplomacyState,
  DiplomaticStatus,
  EncirclementState,
  FactionId,
  FormationType,
  HeroWeaponType,
  PeaceOfferTerms,
  SaveSlotSummary,
  TacticalOrder,
  TerrainType,
  UnitActionState,
  UnitCategory,
  UnitTypeId,
  WeatherType
};
