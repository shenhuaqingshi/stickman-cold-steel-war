/**
 * 鸿蒙平板冷兵器大战核心物理与多军团实时战斗模拟引擎（BattleSimulator.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖，对象池零每帧 GC）
 */
import { GameConstants } from '../../common/GameConstants';
import { getUnitConfigById, UNIT_STATIC_CONFIGS } from '../../config/UnitConfig';
import { UnitStaticStats } from '../../model/GameTypes';
import {
  ArmyCorpsRole,
  BattleControlMode,
  BattlefieldRationStage,
  BattlefieldResourceNode,
  BattleHudSnapshot,
  BattleInitConfig,
  BattleOutcomeReason,
  BattleScenarioType,
  BattleSettlementSummary,
  BattleSide,
  BattleWorldReadonlyView,
  CombatHitEffect,
  CommanderHeroRuntime,
  EncirclementState,
  FactionId,
  FallenCorpseDecal,
  FormationType,
  FortStructureEntity,
  HeroControlInput,
  HeroSkillId,
  HeroVitalState,
  HeroWeaponType,
  ProjectileKind,
  ProjectileRuntimeEntity,
  RosterEntry,
  SoldierRuntimeEntity,
  SquadCommandRequest,
  SquadRuntimeState,
  TacticalOrder,
  TerrainType,
  TerrainZoneRect,
  UnitActionState,
  UnitCategory,
  UnitTypeId,
  WeatherType
} from '../CoreContracts';
import {
  applySquadMoraleAndHysteresis,
  canObserverSpotTarget,
  classifyEncirclementFromMask,
  computeAttackIncomingAngleDeg,
  computeDirectionalModifiers,
  computeEffectiveArmor,
  computeFinalHitDamage,
  computeHyperbolicMitigation,
  computeMoraleArmorMultiplier,
  computeMoraleAttackMultiplier,
  computeObserverVisionRadius,
  computeRangedShieldMultiplier,
  computeSquadContinuousMoraleRate,
  DamageFormulaParams,
  DirectionalCombatModifiers,
  evaluateRationStage,
  hasPinceredOctantPair,
  isBracedAntiCavalryTriggered,
  scanSquadOctantEncirclement
} from './DamageAndMorale';
import {
  applyUnitSeparationAndFortCollision,
  assignSquadFormationSlots,
  canTerrainSupportCharge,
  computeEffectiveSoldierSpeed,
  refreshSquadMetricsAndFordRatio,
  sampleTerrainAtPoint,
  TerrainSampleResult,
  updateSquadOrderGuidance
} from './FormationAndSteering';
import {
  applyDamageToHero,
  CommanderHeroEntity,
  executeHeroSkill,
  HERO_MODE_SWITCH_CD_SEC,
  HeroStepEvents,
  stepCommanderHero
} from './HeroController';
import { SpatialHashGrid } from './SpatialHashGrid';

const EFFECT_POOL_CAPACITY: number = 120;
const MAMELUKE_SPOOK_RADIUS_SQ: number = 160.0 * 160.0;
const CHARGE_RUN_THRESHOLD_SEC: number = 2.5;
const BASE_CHARGE_COOLDOWN_SEC: number = 8.0;

/** O(1) 兵种静态配置表检索映射 */
const UNIT_CONFIG_MAP: Map<UnitTypeId, UnitStaticStats> = new Map<UnitTypeId, UnitStaticStats>();
for (let i: number = 0; i < UNIT_STATIC_CONFIGS.length; i++) {
  UNIT_CONFIG_MAP.set(UNIT_STATIC_CONFIGS[i].id, UNIT_STATIC_CONFIGS[i]);
}

function fastUnitStats(unitId: UnitTypeId): UnitStaticStats {
  const found: UnitStaticStats | undefined = UNIT_CONFIG_MAP.get(unitId);
  if (found !== undefined) {
    return found;
  }
  const fallback: UnitStaticStats | undefined = getUnitConfigById(UnitTypeId.SHIELD_SWORDSMAN);
  return fallback as UnitStaticStats;
}

// ==================== 预分配具象池实体类（固定隐藏类，零未标注对象字面量） ====================

class TerrainZoneItem implements TerrainZoneRect {
  public readonly id: string;
  public readonly terrain: TerrainType;
  public readonly x: number;
  public readonly y: number;
  public readonly width: number;
  public readonly height: number;
  public readonly elevation: number;

  constructor(
    id: string,
    terrain: TerrainType,
    x: number,
    y: number,
    width: number,
    height: number,
    elevation: number
  ) {
    this.id = id;
    this.terrain = terrain;
    this.x = x;
    this.y = y;
    this.width = width;
    this.height = height;
    this.elevation = elevation;
  }
}

class ResourceNodeItem implements BattlefieldResourceNode {
  public readonly id: string;
  public readonly resourceKind: 'gold' | 'wood' | 'grain';
  public readonly x: number;
  public readonly y: number;
  public remainingAmount: number;
  public readonly maxAmount: number;

  constructor(
    id: string,
    resourceKind: 'gold' | 'wood' | 'grain',
    x: number,
    y: number,
    maxAmount: number
  ) {
    this.id = id;
    this.resourceKind = resourceKind;
    this.x = x;
    this.y = y;
    this.remainingAmount = maxAmount;
    this.maxAmount = maxAmount;
  }
}

class FortStructureItem implements FortStructureEntity {
  public readonly id: string;
  public readonly side: BattleSide;
  public readonly kind: 'base_camp' | 'gate' | 'wall_segment' | 'arrow_tower' | 'wooden_stakes';
  public readonly x: number;
  public readonly y: number;
  public readonly width: number;
  public readonly height: number;
  public hp: number;
  public readonly maxHp: number;
  public isBreached: boolean = false;
  public attackTimer: number = 0;

  constructor(
    id: string,
    side: BattleSide,
    kind: 'base_camp' | 'gate' | 'wall_segment' | 'arrow_tower' | 'wooden_stakes',
    x: number,
    y: number,
    width: number,
    height: number,
    maxHp: number
  ) {
    this.id = id;
    this.side = side;
    this.kind = kind;
    this.x = x;
    this.y = y;
    this.width = width;
    this.height = height;
    this.hp = maxHp;
    this.maxHp = maxHp;
  }
}

class SoldierPoolItem implements SoldierRuntimeEntity {
  public active: boolean = false;
  public readonly poolIndex: number;
  public side: BattleSide = BattleSide.PLAYER;
  public factionId: FactionId = FactionId.YANLONG;
  public unitType: UnitTypeId = UnitTypeId.SHIELD_SWORDSMAN;
  public category: UnitCategory = UnitCategory.INFANTRY;
  public squadId: number = 0;
  public corpsRole: ArmyCorpsRole = ArmyCorpsRole.VANGUARD_CENTER;
  public isBannerBearer: boolean = false;
  public isMercenary: boolean = false;
  public x: number = 0;
  public y: number = 0;
  public vx: number = 0;
  public vy: number = 0;
  public facingRad: number = 0;
  public hp: number = 100;
  public maxHp: number = 100;
  public actionState: UnitActionState = UnitActionState.IDLE_READY;
  public animPhase: number = 0;
  public attackCooldown: number = 0;
  public chargeRunTime: number = 0;
  public chargeCooldown: number = 0;
  public staggerTimer: number = 0;
  public poisonTimer: number = 0;
  public isStealthed: boolean = false;
  public visibleToPlayer: boolean = true;
  public visibleToEnemy: boolean = true;
  public grenadeUsed: boolean = false;
  public slotOffsetX: number = 0;
  public slotOffsetY: number = 0;
  public targetEntityIndex: number = -1;

  constructor(poolIndex: number) {
    this.poolIndex = poolIndex;
  }
}

class SquadRuntimeItem implements SquadRuntimeState {
  public readonly squadId: number;
  public readonly side: BattleSide;
  public readonly factionId: FactionId;
  public readonly corpsRole: ArmyCorpsRole;
  public readonly name: string;
  public primaryUnitType: UnitTypeId;
  public formation: FormationType;
  public order: TacticalOrder;
  public morale: number;
  public isRouting: boolean = false;
  public encirclement: EncirclementState = EncirclementState.CLEAR;
  public threatOctantMask: number = 0;
  public centerX: number;
  public centerY: number;
  public facingRad: number;
  public targetX: number;
  public targetY: number;
  public waypointsX: number[] = [];
  public waypointsY: number[] = [];
  public waypointCursor: number = 0;
  public aliveCount: number = 0;
  public initialCount: number = 0;
  public bannerAlive: boolean = true;
  public bannerLostPenaltyTimer: number = 0;
  public fordRatio: number = 0;
  public halfFordShockApplied: boolean = false;

  constructor(
    squadId: number,
    side: BattleSide,
    factionId: FactionId,
    corpsRole: ArmyCorpsRole,
    name: string,
    primaryUnitType: UnitTypeId,
    formation: FormationType,
    order: TacticalOrder,
    morale: number,
    centerX: number,
    centerY: number,
    facingRad: number,
    targetX: number,
    targetY: number
  ) {
    this.squadId = squadId;
    this.side = side;
    this.factionId = factionId;
    this.corpsRole = corpsRole;
    this.name = name;
    this.primaryUnitType = primaryUnitType;
    this.formation = formation;
    this.order = order;
    this.morale = morale;
    this.centerX = centerX;
    this.centerY = centerY;
    this.facingRad = facingRad;
    this.targetX = targetX;
    this.targetY = targetY;
  }
}

class ProjectilePoolItem implements ProjectileRuntimeEntity {
  public active: boolean = false;
  public readonly poolIndex: number;
  public side: BattleSide = BattleSide.PLAYER;
  public kind: ProjectileKind = ProjectileKind.ARROW;
  public startX: number = 0;
  public startY: number = 0;
  public x: number = 0;
  public y: number = 0;
  public vx: number = 0;
  public vy: number = 0;
  public arcHeight: number = 0;
  public flightProgress: number = 0;
  public flightDuration: number = 1.0;
  public damage: number = 15;
  public armorPenetration: number = 0.15;
  public splashRadius: number = 0;
  public pierceRemaining: number = 1;
  public applyPoison: boolean = false;
  public moraleShock: number = 0;

  constructor(poolIndex: number) {
    this.poolIndex = poolIndex;
  }
}

class CorpseDecalItem implements FallenCorpseDecal {
  public active: boolean = false;
  public x: number = 0;
  public y: number = 0;
  public rotationRad: number = 0;
  public factionId: FactionId = FactionId.YANLONG;
  public isBrokenBanner: boolean = false;
  public alpha: number = 1.0;
}

class HitEffectItem implements CombatHitEffect {
  public active: boolean = false;
  public x: number = 0;
  public y: number = 0;
  public kind: 'slash_arc' | 'shield_spark' | 'boulder_crater' | 'morale_burst' | 'blood_splash' =
    'slash_arc';
  public ttl: number = 0;
  public maxTtl: number = 0.25;
  public angleRad: number = 0;
}

class HeroInputState implements HeroControlInput {
  public moveX: number = 0;
  public moveY: number = 0;
  public aimX: number = 0;
  public aimY: number = 0;
  public isAttackPressed: boolean = false;
  public isBlockHeld: boolean = false;
}

// ==================== 核心战斗模拟器主类 ====================

export class BattleSimulator {
  private readonly config: BattleInitConfig;
  private readonly worldWidth: number;
  private readonly worldHeight: number;
  private readonly spatialGrid: SpatialHashGrid;

  // 预分配静态池与实体列表
  private readonly terrainZones: TerrainZoneItem[] = [];
  private readonly resourceNodes: ResourceNodeItem[] = [];
  private readonly structures: FortStructureItem[] = [];
  private readonly soldiers: SoldierPoolItem[] = [];
  private readonly squads: SquadRuntimeItem[] = [];
  private readonly playerSquads: SquadRuntimeItem[] = [];
  private readonly enemySquads: SquadRuntimeItem[] = [];
  private readonly projectiles: ProjectilePoolItem[] = [];
  private readonly corpses: CorpseDecalItem[] = [];
  private readonly hitEffects: HitEffectItem[] = [];

  private readonly playerHero: CommanderHeroEntity;
  private readonly enemyHero: CommanderHeroEntity;
  private playerBaseCamp: FortStructureItem | null = null;
  private enemyBaseCamp: FortStructureItem | null = null;

  // 预分配单兵扩展定长数组（零对象分配）
  private readonly soldierIdleCombatSec: Float32Array;
  private readonly soldierSearchTimer: Float32Array;
  private readonly soldierCarryAmount: Float32Array;
  private readonly soldierCarryKind: Int8Array; // 0:无 1:金 2:木 3:粮
  private readonly projLastHitSoldier: Int32Array;

  // 零分配查询缓冲
  private readonly queryBufA: Int32Array;
  private readonly queryBufB: Int32Array;
  private readonly octantScratch: Int32Array;
  private readonly squadGuideOut: Float64Array = new Float64Array(2);
  private readonly squadTargetMapX: Float64Array = new Float64Array(64);
  private readonly squadTargetMapY: Float64Array = new Float64Array(64);
  private readonly squadUnderFireSec: Float32Array = new Float32Array(64);
  private readonly mamelukePlayerX: Float64Array = new Float64Array(128);
  private readonly mamelukePlayerY: Float64Array = new Float64Array(128);
  private readonly mamelukeEnemyX: Float64Array = new Float64Array(128);
  private readonly mamelukeEnemyY: Float64Array = new Float64Array(128);
  private readonly obsX: Float64Array = new Float64Array(620);
  private readonly obsY: Float64Array = new Float64Array(620);
  private readonly obsRadius: Float64Array = new Float64Array(620);
  private readonly terrainSampleA: TerrainSampleResult = new TerrainSampleResult();
  private readonly terrainSampleB: TerrainSampleResult = new TerrainSampleResult();
  private readonly dmgParams: DamageFormulaParams = new DamageFormulaParams();
  private readonly dirModScratch: DirectionalCombatModifiers = new DirectionalCombatModifiers();
  private readonly heroEvents: HeroStepEvents = new HeroStepEvents();
  private readonly heroInput: HeroInputState = new HeroInputState();

  // 环形覆盖游标
  private corpseWriteCursor: number = 0;
  private effectWriteCursor: number = 0;
  private prngState: number = 0x9e3779b9;

  // 全局资源、粮道、控制与结算状态
  private elapsedSec: number = 0;
  private isPaused: boolean = false;
  private controlMode: BattleControlMode = BattleControlMode.RTS_COMMANDER;
  private switchCooldownSec: number = 0;
  private garrisonBellActive: boolean = false;
  private hitStopRemainingMs: number = 0;
  private outcome: BattleOutcomeReason = BattleOutcomeReason.ONGOING;

  private playerGold: number = GameConstants.BATTLE_INIT_GOLD;
  private playerWood: number = GameConstants.BATTLE_INIT_WOOD;
  private playerGrain: number;
  private enemyGold: number = GameConstants.BATTLE_INIT_GOLD;
  private enemyWood: number = GameConstants.BATTLE_INIT_WOOD;
  private enemyGrain: number;

  private playerZeroGrainSec: number = 0;
  private enemyZeroGrainSec: number = 0;
  private playerRationStage: BattlefieldRationStage = BattlefieldRationStage.ABUNDANT;
  private enemyRationStage: BattlefieldRationStage = BattlefieldRationStage.ABUNDANT;
  private playerEmergencySapperSec: number = 0;
  private enemyEmergencySapperSec: number = 0;
  private playerCampRaidCd: number = 0;
  private enemyCampRaidCd: number = 0;
  private playerRaidLootedGrain: number = 0;

  private playerBloodFrenzySec: number = 0;
  private enemyBloodFrenzySec: number = 0;
  private enemyCommandParalysisSec: number = 0;
  private octantScanAccumSec: number = 0.5;
  private hudSyncAccumSec: number = 0.25;
  private hudDirty: boolean = true;
  private playerAllRoutingSec: number = 0;
  private enemyAllRoutingSec: number = 0;

  private playerInitialTotal: number = 0;
  private enemyInitialTotal: number = 0;
  private playerAliveCount: number = 0;
  private enemyAliveCount: number = 0;
  private playerPopUsed: number = 0;
  private enemyPopUsed: number = 0;
  private playerAvgMorale: number = GameConstants.MORALE_BASE;
  private enemyAvgMorale: number = GameConstants.MORALE_BASE;

  private cachedHud: BattleHudSnapshot;
  private cachedWorldView: BattleWorldReadonlyView;

  constructor(config: BattleInitConfig) {
    this.config = config;
    const isSiege: boolean =
      config.scenarioType === BattleScenarioType.SIEGE_ASSAULT ||
      config.scenarioType === BattleScenarioType.SIEGE_DEFENSE;

    this.worldWidth = isSiege
      ? GameConstants.SIEGE_BATTLEFIELD_WIDTH
      : GameConstants.BATTLEFIELD_WIDTH;
    this.worldHeight = isSiege
      ? GameConstants.SIEGE_BATTLEFIELD_HEIGHT
      : GameConstants.BATTLEFIELD_HEIGHT;

    this.spatialGrid = new SpatialHashGrid(
      this.worldWidth,
      this.worldHeight,
      GameConstants.SPATIAL_GRID_CELL_SIZE,
      GameConstants.MAX_UNIT_POOL_SIZE
    );

    const poolCap: number = GameConstants.MAX_UNIT_POOL_SIZE;
    this.soldierIdleCombatSec = new Float32Array(poolCap);
    this.soldierSearchTimer = new Float32Array(poolCap);
    this.soldierCarryAmount = new Float32Array(poolCap);
    this.soldierCarryKind = new Int8Array(poolCap);
    this.projLastHitSoldier = new Int32Array(GameConstants.MAX_PROJECTILE_POOL_SIZE);
    this.projLastHitSoldier.fill(-1);

    this.queryBufA = new Int32Array(poolCap);
    this.queryBufB = new Int32Array(poolCap);
    this.octantScratch = new Int32Array(poolCap);

    // 1. 预分配四大核心池（零动态扩容）
    for (let i: number = 0; i < poolCap; i++) {
      this.soldiers.push(new SoldierPoolItem(i));
    }
    for (let i: number = 0; i < GameConstants.MAX_PROJECTILE_POOL_SIZE; i++) {
      this.projectiles.push(new ProjectilePoolItem(i));
    }
    for (let i: number = 0; i < GameConstants.MAX_FALLEN_CORPSE_DECAL; i++) {
      this.corpses.push(new CorpseDecalItem());
    }
    for (let i: number = 0; i < EFFECT_POOL_CAPACITY; i++) {
      this.hitEffects.push(new HitEffectItem());
    }

    this.playerGrain = Math.max(0, config.playerInitialGrain);
    this.enemyGrain = Math.max(0, config.enemyInitialGrain);

    // 2. 构建三路立体地形、野外资源点与城防本阵建筑
    this.initBattlefieldTerrainAndNodes(isSiege);
    this.initStructures(isSiege);

    // 3. 初始化双方统帅英雄
    const pHeroX: number = 680.0;
    const pHeroY: number = this.worldHeight * 0.5;
    const eHeroX: number = this.worldWidth - 680.0;
    const eHeroY: number = this.worldHeight * 0.5;
    this.playerHero = new CommanderHeroEntity(
      BattleSide.PLAYER,
      config.playerFaction,
      pHeroX,
      pHeroY,
      0
    );
    this.enemyHero = new CommanderHeroEntity(
      BattleSide.ENEMY,
      config.enemyFaction,
      eHeroX,
      eHeroY,
      Math.PI
    );

    // 4. 初始化双方多军团百人战线部队
    this.initSideArmy(
      BattleSide.PLAYER,
      config.playerFaction,
      config.playerArmyRoster,
      config.playerMoraleModifier
    );
    this.initSideArmy(
      BattleSide.ENEMY,
      config.enemyFaction,
      config.enemyArmyRoster,
      config.enemyMoraleModifier
    );

    // 夜袭场景：进攻方开局震慑敌军 -15 士气（DESIGN.md 7.2）
    if (config.scenarioType === BattleScenarioType.NIGHT_RAID) {
      for (let i: number = 0; i < this.enemySquads.length; i++) {
        applySquadMoraleAndHysteresis(this.enemySquads[i], -15.0, false, false);
      }
    }

    // 5. 首帧同步空间哈希、分队质心、视野迷雾与只读快照
    this.spatialGrid.rebuildFromSoldiers(this.soldiers);
    this.refreshAllSquadStatsAndEncirclement(true);
    this.updateFogOfWar();
    this.cachedHud = this.createHudSnapshot();
    this.cachedWorldView = this.createWorldView();
    this.hudDirty = false;
  }

  // ==================== 标准公开接口（14 项核心方法） ====================

  public getWorldView(): BattleWorldReadonlyView {
    if (this.hudDirty) {
      this.cachedHud = this.createHudSnapshot();
      this.cachedWorldView = this.createWorldView();
      this.hudDirty = false;
    }
    return this.cachedWorldView;
  }

  public getHudSnapshot(): BattleHudSnapshot {
    if (this.hudDirty) {
      this.cachedHud = this.createHudSnapshot();
      this.cachedWorldView = this.createWorldView();
      this.hudDirty = false;
    }
    return this.cachedHud;
  }

  public setPaused(paused: boolean): void {
    this.isPaused = paused;
    this.hudDirty = true;
  }

  public negotiateFieldTruce(): void {
    if (this.outcome === BattleOutcomeReason.ONGOING) {
      this.outcome = BattleOutcomeReason.TRUCE_NEGOTIATED;
      this.hudDirty = true;
    }
  }

  public toggleGarrisonBell(): boolean {
    this.garrisonBellActive = !this.garrisonBellActive;
    this.hudDirty = true;
    return this.garrisonBellActive;
  }

  public updateHeroInput(input: HeroControlInput): void {
    this.heroInput.moveX = input.moveX;
    this.heroInput.moveY = input.moveY;
    this.heroInput.aimX = input.aimX;
    this.heroInput.aimY = input.aimY;
    this.heroInput.isAttackPressed = input.isAttackPressed;
    this.heroInput.isBlockHeld = input.isBlockHeld;
  }

  public toggleControlMode(): boolean {
    if (this.outcome !== BattleOutcomeReason.ONGOING || this.switchCooldownSec > 0) {
      return false;
    }
    if (
      this.controlMode === BattleControlMode.RTS_COMMANDER &&
      (this.playerHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP ||
        this.playerHero.vitalState === HeroVitalState.FALLEN_MARTYRED)
    ) {
      return false;
    }
    this.controlMode =
      this.controlMode === BattleControlMode.RTS_COMMANDER
        ? BattleControlMode.HERO_ACTION
        : BattleControlMode.RTS_COMMANDER;
    this.switchCooldownSec = HERO_MODE_SWITCH_CD_SEC;
    this.hudDirty = true;
    return true;
  }

  public switchHeroWeapon(weapon: HeroWeaponType): void {
    if (this.playerHero.activeWeapon !== weapon) {
      this.playerHero.activeWeapon = weapon;
      this.playerHero.isBlocking = false;
      this.playerHero.parryWindowTimer = 0;
      this.hudDirty = true;
    }
  }

  public triggerHeroSkill(skill: HeroSkillId): boolean {
    if (this.outcome !== BattleOutcomeReason.ONGOING) {
      return false;
    }
    this.heroEvents.reset();
    const enemyNonRouting: number = this.countNonRoutingSoldiers(BattleSide.ENEMY);
    const ok: boolean = executeHeroSkill(
      this.playerHero,
      skill,
      this.soldiers,
      this.playerSquads,
      this.enemySquads,
      this.enemyHero,
      this.enemyBaseCamp,
      enemyNonRouting,
      this.enemyInitialTotal,
      this.spatialGrid,
      this.worldWidth,
      this.worldHeight,
      this.heroEvents
    );
    if (ok) {
      this.consumeHeroEvents(BattleSide.PLAYER, this.heroEvents);
      this.hudDirty = true;
    }
    return ok;
  }

  public triggerEnemyHeroSkill(skill: HeroSkillId): boolean {
    if (this.outcome !== BattleOutcomeReason.ONGOING || this.enemyCommandParalysisSec > 0) {
      return false;
    }
    this.heroEvents.reset();
    const playerNonRouting: number = this.countNonRoutingSoldiers(BattleSide.PLAYER);
    const ok: boolean = executeHeroSkill(
      this.enemyHero,
      skill,
      this.soldiers,
      this.enemySquads,
      this.playerSquads,
      this.playerHero,
      this.playerBaseCamp,
      playerNonRouting,
      this.playerInitialTotal,
      this.spatialGrid,
      this.worldWidth,
      this.worldHeight,
      this.heroEvents
    );
    if (ok) {
      this.consumeHeroEvents(BattleSide.ENEMY, this.heroEvents);
      this.hudDirty = true;
    }
    return ok;
  }

  public issueSquadCommand(req: SquadCommandRequest): void {
    const idsLen: number = req.squadIds.length;
    for (let i: number = 0; i < idsLen; i++) {
      const sqId: number = req.squadIds[i];
      if (sqId < 0 || sqId >= this.squads.length) {
        continue;
      }
      const sq: SquadRuntimeItem = this.squads[sqId];
      // 溃逃分队脱离控制；敌帅瘫痪 15s 期间敌军无法变阵或调度预备队
      if (sq.aliveCount <= 0 || sq.isRouting) {
        continue;
      }
      if (sq.side === BattleSide.ENEMY && this.enemyCommandParalysisSec > 0) {
        continue;
      }

      let formationChanged: boolean = false;
      if (req.formation !== undefined && sq.formation !== req.formation) {
        sq.formation = req.formation;
        formationChanged = true;
      }
      if (req.order !== undefined) {
        sq.order = req.order;
        if (req.order === TacticalOrder.HOLD_GROUND && req.targetX === undefined) {
          sq.targetX = sq.centerX;
          sq.targetY = sq.centerY;
        }
      }
      if (req.targetX !== undefined && req.targetY !== undefined) {
        sq.targetX = Math.max(48.0, Math.min(this.worldWidth - 48.0, req.targetX));
        sq.targetY = Math.max(48.0, Math.min(this.worldHeight - 48.0, req.targetY));
      }

      if (
        req.customWaypointsX !== undefined &&
        req.customWaypointsY !== undefined &&
        req.customWaypointsX.length > 0
      ) {
        sq.waypointsX.length = 0;
        sq.waypointsY.length = 0;
        const wCount: number = Math.min(req.customWaypointsX.length, req.customWaypointsY.length);
        for (let w: number = 0; w < wCount; w++) {
          sq.waypointsX.push(req.customWaypointsX[w]);
          sq.waypointsY.push(req.customWaypointsY[w]);
        }
        sq.waypointCursor = 0;
      } else if (req.targetX !== undefined) {
        sq.waypointsX.length = 0;
        sq.waypointsY.length = 0;
        sq.waypointCursor = 0;
      }

      if (formationChanged) {
        assignSquadFormationSlots(sq, this.soldiers);
      }
    }
  }

  public recruitUnit(
    side: BattleSide,
    unitType: UnitTypeId,
    corpsRole: ArmyCorpsRole
  ): boolean {
    if (this.outcome !== BattleOutcomeReason.ONGOING) {
      return false;
    }
    const stats: UnitStaticStats | undefined = UNIT_CONFIG_MAP.get(unitType);
    if (stats === undefined) {
      return false;
    }
    const faction: FactionId =
      side === BattleSide.PLAYER ? this.config.playerFaction : this.config.enemyFaction;

    // 专属兵种归属与苍狼禁造投石车校验
    if (stats.exclusiveFaction !== null && stats.exclusiveFaction !== faction) {
      return false;
    }
    if (faction === FactionId.CANGLANG && unitType === UnitTypeId.TREBUCHET) {
      return false;
    }

    const currentPop: number = side === BattleSide.PLAYER ? this.playerPopUsed : this.enemyPopUsed;
    if (currentPop + stats.popCap > GameConstants.DEFAULT_ARMY_POP_CAP) {
      return false;
    }

    const freeIdx: number = this.findFreeSoldierSlot();
    if (freeIdx === -1) {
      return false;
    }

    const camp: FortStructureItem | null =
      side === BattleSide.PLAYER ? this.playerBaseCamp : this.enemyBaseCamp;
    if (camp === null || camp.isBreached || camp.hp <= 0) {
      return false;
    }

    // 计算含势力特性的招募花费
    let goldCost: number = stats.cost.gold;
    let woodCost: number = stats.cost.wood;
    let grainCost: number = stats.cost.grain;
    let recruitedAsMercenary: boolean = false;

    if (faction === FactionId.YANLONG) {
      if (stats.category === UnitCategory.SIEGE) {
        goldCost = Math.round(goldCost * 0.80);
        woodCost = Math.round(woodCost * 0.80);
        grainCost = Math.round(grainCost * 0.80);
      } else if (stats.category === UnitCategory.CAVALRY) {
        goldCost = Math.round(goldCost * 1.15);
      }
    } else if (faction === FactionId.TIEYING && stats.category === UnitCategory.SHOCK) {
      goldCost = Math.round(goldCost * 1.10);
    }

    const curGold: number = side === BattleSide.PLAYER ? this.playerGold : this.enemyGold;
    const curWood: number = side === BattleSide.PLAYER ? this.playerWood : this.enemyWood;
    const curGrain: number = side === BattleSide.PLAYER ? this.playerGrain : this.enemyGrain;

    if (
      faction === FactionId.SHAMO &&
      unitType !== UnitTypeId.SAPPER &&
      unitType !== UnitTypeId.SHAMO_MAMELUKE_CAMEL
    ) {
      // 沙漠商盟支持纯金币雇佣军征召（木/粮不足时折算为纯金币契约）
      recruitedAsMercenary = true;
      if (curWood < woodCost || curGrain < grainCost) {
        const pureGold: number = Math.round(goldCost + woodCost * 0.8 + grainCost * 0.8);
        if (curGold < pureGold) {
          return false;
        }
        goldCost = pureGold;
        woodCost = 0;
        grainCost = 0;
      }
    }

    if (curGold < goldCost || curWood < woodCost || curGrain < grainCost) {
      return false;
    }

    if (side === BattleSide.PLAYER) {
      this.playerGold -= goldCost;
      this.playerWood -= woodCost;
      this.playerGrain -= grainCost;
    } else {
      this.enemyGold -= goldCost;
      this.enemyWood -= woodCost;
      this.enemyGrain -= grainCost;
    }

    const squad: SquadRuntimeItem = this.findOrCreateSquadForRecruit(
      side,
      faction,
      corpsRole,
      unitType
    );
    const spawnX: number =
      side === BattleSide.PLAYER
        ? camp.x + camp.width + 26.0 + (freeIdx % 5) * 10.0
        : camp.x - 26.0 - (freeIdx % 5) * 10.0;
    const spawnY: number = camp.y + camp.height * 0.5 + ((freeIdx % 7) - 3) * 14.0;

    this.activateSoldierInPool(
      freeIdx,
      side,
      faction,
      unitType,
      squad.squadId,
      corpsRole,
      spawnX,
      spawnY,
      side === BattleSide.PLAYER ? 0 : Math.PI,
      squad.aliveCount === 0,
      recruitedAsMercenary
    );

    squad.initialCount++;
    squad.aliveCount++;
    if (side === BattleSide.PLAYER) {
      this.playerInitialTotal++;
      this.playerAliveCount++;
      this.playerPopUsed += stats.popCap;
    } else {
      this.enemyInitialTotal++;
      this.enemyAliveCount++;
      this.enemyPopUsed += stats.popCap;
    }

    assignSquadFormationSlots(squad, this.soldiers);
    this.spatialGrid.insert(freeIdx, spawnX, spawnY);
    this.hudDirty = true;
    return true;
  }

  public stepTick(dtSec: number): void {
    if (this.isPaused || this.outcome !== BattleOutcomeReason.ONGOING || dtSec <= 0) {
      return;
    }
    const clampedDt: number = Math.min(0.10, dtSec);
    this.elapsedSec += clampedDt;

    if (this.switchCooldownSec > 0) {
      this.switchCooldownSec = Math.max(0, this.switchCooldownSec - clampedDt);
    }
    if (this.enemyCommandParalysisSec > 0) {
      this.enemyCommandParalysisSec = Math.max(0, this.enemyCommandParalysisSec - clampedDt);
    }
    if (this.playerCampRaidCd > 0) {
      this.playerCampRaidCd = Math.max(0, this.playerCampRaidCd - clampedDt);
    }
    if (this.enemyCampRaidCd > 0) {
      this.enemyCampRaidCd = Math.max(0, this.enemyCampRaidCd - clampedDt);
    }
    if (this.playerBloodFrenzySec > 0) {
      this.playerBloodFrenzySec = Math.max(0, this.playerBloodFrenzySec - clampedDt);
    }
    if (this.enemyBloodFrenzySec > 0) {
      this.enemyBloodFrenzySec = Math.max(0, this.enemyBloodFrenzySec - clampedDt);
    }

    // 处理重劈 40ms 卡肉顿帧（Hit-Stop 期间先消耗冻结时长，运动缩放减速以增强顿挫感）
    let simDt: number = clampedDt;
    if (this.hitStopRemainingMs > 0) {
      const decMs: number = clampedDt * 1000.0;
      if (this.hitStopRemainingMs > decMs) {
        this.hitStopRemainingMs -= decMs;
        simDt = clampedDt * 0.15;
      } else {
        const leftoverMs: number = decMs - this.hitStopRemainingMs;
        this.hitStopRemainingMs = 0;
        simDt = Math.max(clampedDt * 0.25, leftoverMs * 0.001);
      }
      this.hudDirty = true;
    }

    // 1. O(N) 重建空间均匀哈希网格并刷新当前坐标视野迷雾
    this.spatialGrid.rebuildFromSoldiers(this.soldiers);
    this.updateFogOfWar();

    // 2. 后勤耗粮、断粮三级状态、本阵保底军饷与零金零工兵 25s 应急民夫检测
    this.stepLogisticsAndEconomy(simDt);

    // 3. 更新分队质心、涉水比、每 0.5s 八象限包抄合围扫描与持续士气演化
    this.octantScanAccumSec += simDt;
    const doOctantScan: boolean = this.octantScanAccumSec >= 0.50;
    if (doOctantScan) {
      this.octantScanAccumSec = 0;
    }
    this.refreshAllSquadStatsAndEncirclement(doOctantScan);
    this.stepSquadMoraleAndGuidance(simDt);

    // 4. 步进双方主帅英雄状态机
    this.heroEvents.reset();
    const enemyNonRouting: number = this.countNonRoutingSoldiers(BattleSide.ENEMY);
    stepCommanderHero(
      this.playerHero,
      simDt,
      this.controlMode === BattleControlMode.HERO_ACTION,
      this.heroInput,
      this.playerBaseCamp,
      this.enemyBaseCamp,
      this.soldiers,
      this.playerSquads,
      this.enemySquads,
      this.enemyHero,
      enemyNonRouting,
      this.enemyInitialTotal,
      this.spatialGrid,
      this.worldWidth,
      this.worldHeight,
      this.heroEvents
    );
    this.consumeHeroEvents(BattleSide.PLAYER, this.heroEvents);

    this.heroEvents.reset();
    const playerNonRouting: number = this.countNonRoutingSoldiers(BattleSide.PLAYER);
    stepCommanderHero(
      this.enemyHero,
      simDt,
      false,
      this.heroInput,
      this.enemyBaseCamp,
      this.playerBaseCamp,
      this.soldiers,
      this.enemySquads,
      this.playerSquads,
      this.playerHero,
      playerNonRouting,
      this.playerInitialTotal,
      this.spatialGrid,
      this.worldWidth,
      this.worldHeight,
      this.heroEvents
    );
    this.consumeHeroEvents(BattleSide.ENEMY, this.heroEvents);

    // 5. 步进全部活跃士兵（弹簧槽位移动、局部避障、架枪迎骑、16 兵种拼杀与工兵采集）
    this.stepAllSoldiers(simDt);

    // 6. 步进守城箭塔自动防御与本阵警钟民夫协防射击
    this.stepFortStructuresDefense(simDt);

    // 7. 步进飞行箭矢、钢弩、火雷与投石车巨石碰撞结算
    this.stepAllProjectiles(simDt);

    // 8. 步进轻量视觉特效生命周期与动态战争迷雾
    this.stepVisualEffects(simDt);
    this.updateFogOfWar();

    // 9. 检查终局胜负条件并标记只读 HUD 脏位（惰性按需生成，stepTick 内零对象分配）
    this.evaluateBattleOutcome(simDt);
    this.hudDirty = true;
  }

  public buildSettlementSummary(): BattleSettlementSummary {
    this.recountArmyTotals();
    const isVictory: boolean =
      this.outcome === BattleOutcomeReason.ENEMY_BASE_DESTROYED ||
      this.outcome === BattleOutcomeReason.ENEMY_ARMY_ROUTED ||
      this.outcome === BattleOutcomeReason.SIEGE_DEFENSE_HELD;

    const playerKilled: number = Math.max(0, this.playerInitialTotal - this.playerAliveCount);
    const enemyKilled: number = Math.max(0, this.enemyInitialTotal - this.enemyAliveCount);
    const playerWoundedRecovered: number = Math.floor(
      playerKilled * (isVictory ? 0.35 : 0.18)
    );

    let routingEnemies: number = 0;
    for (let i: number = 0; i < this.soldiers.length; i++) {
      const s: SoldierPoolItem = this.soldiers[i];
      if (s.active && s.hp > 0 && s.side === BattleSide.ENEMY && this.squads[s.squadId].isRouting) {
        routingEnemies++;
      }
    }

    const capturedPrisoners: number = isVictory
      ? Math.floor(routingEnemies * 0.65 + enemyKilled * 0.15)
      : 0;
    const lootedGold: number = isVictory
      ? Math.round(this.enemyGold * 0.50 + enemyKilled * 3.0)
      : 0;
    const lootedWood: number = isVictory
      ? Math.round(this.enemyWood * 0.40 + enemyKilled * 2.0)
      : 0;
    const lootedGrain: number = Math.round(
      this.playerRaidLootedGrain + (isVictory ? this.enemyGrain * 0.60 : 0)
    );
    const commanderExpGained: number = Math.round(
      enemyKilled * 4.0 + this.playerHero.kills * 12.0 + (isVictory ? 150.0 : 40.0)
    );

    const summary: BattleSettlementSummary = {
      scenarioType: this.config.scenarioType,
      campaignNodeId: this.config.campaignNodeId,
      playerFaction: this.config.playerFaction,
      enemyFaction: this.config.enemyFaction,
      isVictory: isVictory,
      outcomeReason: this.outcome,
      durationSec: this.elapsedSec,
      playerInitialTotal: this.playerInitialTotal,
      playerKilled: playerKilled,
      playerWoundedRecovered: playerWoundedRecovered,
      enemyInitialTotal: this.enemyInitialTotal,
      enemyKilled: enemyKilled,
      capturedPrisoners: capturedPrisoners,
      lootedGold: lootedGold,
      lootedWood: lootedWood,
      lootedGrain: lootedGrain,
      heroKills: this.playerHero.kills,
      commanderExpGained: commanderExpGained
    };
    return summary;
  }

  /** 供调试与单测读取底层空间哈希网格实例 */
  public getSpatialGrid(): SpatialHashGrid {
    return this.spatialGrid;
  }

  /** 查询敌军指挥官是否处于被击倒后的 15s 瘫痪期 */
  public getEnemyCommandParalysisSec(): number {
    return this.enemyCommandParalysisSec;
  }

  // ==================== 战场初始化构建细节 ====================

  private initBattlefieldTerrainAndNodes(isSiege: boolean): void {
    const w: number = this.worldWidth;
    const h: number = this.worldHeight;
    const midX: number = w * 0.5;
    const midY: number = h * 0.5;

    // 北翼迂回走廊：制高点山脊 + 迷雾密林伏击区
    this.terrainZones.push(
      new TerrainZoneItem('north_ridge', TerrainType.HIGH_GROUND, midX - 680, 140, 620, 420, 1)
    );
    this.terrainZones.push(
      new TerrainZoneItem('north_woods', TerrainType.DENSE_FOREST, midX + 60, 140, 620, 420, 0)
    );

    // 南翼补给走廊：密林伏击区 + 南侧高坡
    this.terrainZones.push(
      new TerrainZoneItem('south_woods', TerrainType.DENSE_FOREST, midX - 640, h - 560, 600, 420, 0)
    );
    this.terrainZones.push(
      new TerrainZoneItem('south_knoll', TerrainType.HIGH_GROUND, midX + 80, h - 560, 580, 420, 1)
    );

    // 中路主决战区：非攻城标准野战配置中央河流浅滩与中心石桥
    if (!isSiege) {
      if (this.config.terrain === TerrainType.RIVER_FORD) {
        this.terrainZones.push(
          new TerrainZoneItem('center_ford_full', TerrainType.RIVER_FORD, midX - 210, 80, 420, h - 160, 0)
        );
      } else if (
        this.config.terrain === TerrainType.PLAIN ||
        this.config.terrain === TerrainType.BRIDGE_PASS
      ) {
        this.terrainZones.push(
          new TerrainZoneItem('center_ford_north', TerrainType.RIVER_FORD, midX - 150, 660, 300, 430, 0)
        );
        this.terrainZones.push(
          new TerrainZoneItem('center_ford_south', TerrainType.RIVER_FORD, midX - 150, midY + 110, 300, 430, 0)
        );
        this.terrainZones.push(
          new TerrainZoneItem('center_stone_bridge', TerrainType.BRIDGE_PASS, midX - 170, midY - 110, 340, 220, 0)
        );
      }
    } else {
      // 攻城战城头掩体高地（elevation = 2）
      const wallX: number =
        this.config.scenarioType === BattleScenarioType.SIEGE_ASSAULT ? w - 1550 : 1490;
      this.terrainZones.push(
        new TerrainZoneItem('siege_rampart_top', TerrainType.FORT_WALL, wallX - 40, 260, 140, h - 520, 2)
      );
    }

    // 野外六大战略资源点（金矿、林场、农庄粮垛对称分布）
    this.resourceNodes.push(new ResourceNodeItem('res_p_gold', 'gold', 1120, 340, 900));
    this.resourceNodes.push(new ResourceNodeItem('res_p_wood', 1080 > 0 ? 'wood' : 'wood', 1060, h - 360, 800));
    this.resourceNodes.push(new ResourceNodeItem('res_p_grain', 'grain', 1420, h - 420, 1000));

    this.resourceNodes.push(new ResourceNodeItem('res_e_gold', 'gold', w - 1120, 340, 900));
    this.resourceNodes.push(new ResourceNodeItem('res_e_wood', 'wood', w - 1060, h - 360, 800));
    this.resourceNodes.push(new ResourceNodeItem('res_e_grain', 'grain', w - 1420, h - 420, 1000));
  }

  private initStructures(isSiege: boolean): void {
    const w: number = this.worldWidth;
    const h: number = this.worldHeight;
    const midY: number = h * 0.5;

    const pHpMult: number = this.config.playerFaction === FactionId.YANLONG ? 1.20 : 1.0;
    const eHpMult: number = this.config.enemyFaction === FactionId.YANLONG ? 1.20 : 1.0;

    const pCamp: FortStructureItem = new FortStructureItem(
      'player_base_camp',
      BattleSide.PLAYER,
      'base_camp',
      360,
      midY - 110,
      180,
      220,
      Math.round(2800 * pHpMult)
    );
    const eCamp: FortStructureItem = new FortStructureItem(
      'enemy_base_camp',
      BattleSide.ENEMY,
      'base_camp',
      w - 540,
      midY - 110,
      180,
      220,
      Math.round(2800 * eHpMult)
    );
    this.playerBaseCamp = pCamp;
    this.enemyBaseCamp = eCamp;
    this.structures.push(pCamp);
    this.structures.push(eCamp);

    // 本阵前哨警戒箭塔与防骑拒马
    this.structures.push(
      new FortStructureItem('player_camp_tower', BattleSide.PLAYER, 'arrow_tower', 600, midY - 220, 64, 64, Math.round(1100 * pHpMult))
    );
    this.structures.push(
      new FortStructureItem('player_camp_stakes', BattleSide.PLAYER, 'wooden_stakes', 650, midY + 140, 48, 96, 600)
    );
    this.structures.push(
      new FortStructureItem('enemy_camp_tower', BattleSide.ENEMY, 'arrow_tower', w - 664, midY - 220, 64, 64, Math.round(1100 * eHpMult))
    );
    this.structures.push(
      new FortStructureItem('enemy_camp_stakes', BattleSide.ENEMY, 'wooden_stakes', w - 698, midY + 140, 48, 96, 600)
    );

    // 攻城/守城要塞城墙、城门与双翼箭塔
    if (isSiege) {
      const defSide: BattleSide =
        this.config.scenarioType === BattleScenarioType.SIEGE_DEFENSE
          ? BattleSide.PLAYER
          : BattleSide.ENEMY;
      const defMult: number = defSide === BattleSide.PLAYER ? pHpMult : eHpMult;
      const wallX: number = defSide === BattleSide.PLAYER ? 1520 : w - 1580;

      this.structures.push(
        new FortStructureItem('fort_wall_north', defSide, 'wall_segment', wallX, 240, 68, midY - 370, Math.round(3200 * defMult))
      );
      this.structures.push(
        new FortStructureItem('fort_main_gate', defSide, 'gate', wallX, midY - 130, 68, 260, Math.round(2200 * defMult))
      );
      this.structures.push(
        new FortStructureItem('fort_wall_south', defSide, 'wall_segment', wallX, midY + 130, 68, midY - 370, Math.round(3200 * defMult))
      );
      this.structures.push(
        new FortStructureItem('fort_tower_north', defSide, 'arrow_tower', wallX - 10, midY - 230, 76, 76, Math.round(1500 * defMult))
      );
      this.structures.push(
        new FortStructureItem('fort_tower_south', defSide, 'arrow_tower', wallX - 10, midY + 154, 76, 76, Math.round(1500 * defMult))
      );
    }
  }

  private buildDefaultFactionRoster(factionId: FactionId): RosterEntry[] {
    const list: RosterEntry[] = [];
    // 1. 中军前锋（刀盾抗线 + 长枪反骑）
    list.push({ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 24, corpsRole: ArmyCorpsRole.VANGUARD_CENTER });
    list.push({ unitType: UnitTypeId.PIKEMAN, count: 20, corpsRole: ArmyCorpsRole.VANGUARD_CENTER });

    // 2. 左翼军团（北走廊机动包抄）
    const leftUnit: UnitTypeId = this.pickWingUnitForFaction(factionId, true);
    const leftCount: number = fastUnitStats(leftUnit).popCap >= 3 ? 10 : 16;
    list.push({ unitType: leftUnit, count: leftCount, corpsRole: ArmyCorpsRole.LEFT_WING });

    // 3. 右翼军团（南走廊迂回突袭）
    const rightUnit: UnitTypeId = this.pickWingUnitForFaction(factionId, false);
    const rightCount: number = fastUnitStats(rightUnit).popCap >= 3 ? 10 : 16;
    list.push({ unitType: rightUnit, count: rightCount, corpsRole: ArmyCorpsRole.RIGHT_WING });

    // 4. 总预备队（势力王牌精锐 + 破甲巨斧）
    const eliteUnit: UnitTypeId = this.getFactionExclusiveUnit(factionId);
    const eliteCount: number = fastUnitStats(eliteUnit).popCap >= 3 ? 10 : 16;
    list.push({ unitType: eliteUnit, count: eliteCount, corpsRole: ArmyCorpsRole.REAR_RESERVE });
    list.push({ unitType: UnitTypeId.GREAT_AXEMAN, count: 12, corpsRole: ArmyCorpsRole.REAR_RESERVE });

    // 5. 远程攻城群（复合弓手 + 连弩车 + 投石车；苍狼汗国禁造投石车改配怯薛骑射）
    list.push({ unitType: UnitTypeId.COMPOSITE_ARCHER, count: 18, corpsRole: ArmyCorpsRole.SIEGE_BATTERY });
    list.push({ unitType: UnitTypeId.BALLISTA, count: 2, corpsRole: ArmyCorpsRole.SIEGE_BATTERY });
    if (factionId === FactionId.CANGLANG) {
      list.push({
        unitType: UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER,
        count: 6,
        corpsRole: ArmyCorpsRole.SIEGE_BATTERY
      });
    } else {
      list.push({ unitType: UnitTypeId.TREBUCHET, count: 2, corpsRole: ArmyCorpsRole.SIEGE_BATTERY });
    }

    // 6. 辎重护粮队（工兵采金伐木抢粮）
    list.push({ unitType: UnitTypeId.SAPPER, count: 8, corpsRole: ArmyCorpsRole.SUPPLY_ESCORT });
    return list;
  }

  private getFactionExclusiveUnit(factionId: FactionId): UnitTypeId {
    if (factionId === FactionId.YANLONG) {
      return UnitTypeId.YANLONG_HALBERD_GRENADIER;
    }
    if (factionId === FactionId.CANGLANG) {
      return UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER;
    }
    if (factionId === FactionId.TIEYING) {
      return UnitTypeId.TIEYING_PAVISE_CROSSBOW;
    }
    if (factionId === FactionId.SHAMO) {
      return UnitTypeId.SHAMO_MAMELUKE_CAMEL;
    }
    if (factionId === FactionId.SHUANGYUAN) {
      return UnitTypeId.SHUANGYUAN_GIANT_BREAKER;
    }
    if (factionId === FactionId.WULIN) {
      return UnitTypeId.WULIN_SHADOW_SNIPER;
    }
    if (factionId === FactionId.XUANJIA) {
      return UnitTypeId.XUANJIA_CATAPHRACT;
    }
    return UnitTypeId.XUEYUE_WARDRUM_BERSERKER;
  }

  private pickWingUnitForFaction(factionId: FactionId, isLeft: boolean): UnitTypeId {
    if (factionId === FactionId.CANGLANG) {
      return isLeft ? UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER : UnitTypeId.LIGHT_CAVALRY;
    }
    if (factionId === FactionId.SHAMO) {
      return isLeft ? UnitTypeId.SHAMO_MAMELUKE_CAMEL : UnitTypeId.LIGHT_CAVALRY;
    }
    if (factionId === FactionId.XUANJIA) {
      return isLeft ? UnitTypeId.XUANJIA_CATAPHRACT : UnitTypeId.LIGHT_CAVALRY;
    }
    if (factionId === FactionId.WULIN && isLeft) {
      return UnitTypeId.WULIN_SHADOW_SNIPER;
    }
    if (factionId === FactionId.XUEYUE && !isLeft) {
      return UnitTypeId.XUEYUE_WARDRUM_BERSERKER;
    }
    return UnitTypeId.LIGHT_CAVALRY;
  }

  private initSideArmy(
    side: BattleSide,
    factionId: FactionId,
    rosterInput: readonly RosterEntry[],
    moraleModifier: number
  ): void {
    const roster: readonly RosterEntry[] =
      rosterInput.length > 0 ? rosterInput : this.buildDefaultFactionRoster(factionId);

    for (let i: number = 0; i < roster.length; i++) {
      const entry: RosterEntry = roster[i];
      if (entry.count <= 0) {
        continue;
      }
      // 苍狼汗国若外部传入投石车，自动转换为连弩车遵守势力铁律
      const resolvedUnit: UnitTypeId =
        factionId === FactionId.CANGLANG && entry.unitType === UnitTypeId.TREBUCHET
          ? UnitTypeId.BALLISTA
          : entry.unitType;

      const stats: UnitStaticStats = fastUnitStats(resolvedUnit);
      const spawnCoord: Float64Array = this.computeCorpsSpawnAndTarget(
        side,
        entry.corpsRole,
        i
      );
      const spawnX: number = spawnCoord[0];
      const spawnY: number = spawnCoord[1];
      const targetX: number = spawnCoord[2];
      const targetY: number = spawnCoord[3];
      const facing: number = side === BattleSide.PLAYER ? 0 : Math.PI;

      const defaultFormation: FormationType = this.pickDefaultFormation(stats.category, entry.corpsRole);
      const defaultOrder: TacticalOrder = this.pickInitialTacticalOrder(side, entry.corpsRole, factionId);
      const initMorale: number = this.computeInitialSquadMorale(
        factionId,
        resolvedUnit,
        stats.category,
        moraleModifier
      );

      const squadId: number = this.squads.length;
      const corpsLabel: string = this.formatCorpsTitle(entry.corpsRole, stats.name);
      const squad: SquadRuntimeItem = new SquadRuntimeItem(
        squadId,
        side,
        factionId,
        entry.corpsRole,
        corpsLabel,
        resolvedUnit,
        defaultFormation,
        defaultOrder,
        initMorale,
        spawnX,
        spawnY,
        facing,
        targetX,
        targetY
      );
      this.squads.push(squad);
      if (side === BattleSide.PLAYER) {
        this.playerSquads.push(squad);
      } else {
        this.enemySquads.push(squad);
      }

      const isShamoMerc: boolean =
        factionId === FactionId.SHAMO &&
        resolvedUnit !== UnitTypeId.SHAMO_MAMELUKE_CAMEL &&
        resolvedUnit !== UnitTypeId.SAPPER &&
        (entry.corpsRole !== ArmyCorpsRole.VANGUARD_CENTER ||
          stats.category === UnitCategory.SHOCK ||
          stats.category === UnitCategory.CAVALRY);

      let spawnedInSquad: number = 0;
      for (let u: number = 0; u < entry.count; u++) {
        const slotIdx: number = this.findFreeSoldierSlot();
        if (slotIdx === -1) {
          break;
        }
        const jitterX: number = ((u % 5) - 2) * 14.0;
        const jitterY: number = (Math.floor(u / 5) - 2) * 15.0;
        const isBanner: boolean = u === 0 && resolvedUnit !== UnitTypeId.SAPPER;

        this.activateSoldierInPool(
          slotIdx,
          side,
          factionId,
          resolvedUnit,
          squadId,
          entry.corpsRole,
          Math.max(48.0, Math.min(this.worldWidth - 48.0, spawnX + jitterX)),
          Math.max(48.0, Math.min(this.worldHeight - 48.0, spawnY + jitterY)),
          facing,
          isBanner,
          isShamoMerc
        );
        spawnedInSquad++;
        if (side === BattleSide.PLAYER) {
          this.playerInitialTotal++;
          this.playerAliveCount++;
          this.playerPopUsed += stats.popCap;
        } else {
          this.enemyInitialTotal++;
          this.enemyAliveCount++;
          this.enemyPopUsed += stats.popCap;
        }
      }

      squad.initialCount = spawnedInSquad;
      squad.aliveCount = spawnedInSquad;
      squad.bannerAlive = resolvedUnit !== UnitTypeId.SAPPER && spawnedInSquad > 0;
      assignSquadFormationSlots(squad, this.soldiers);

      // 根据初始阵型槽位直接对齐士兵开场站位，呈现严整壮观的冷兵器大战列阵
      const cosF: number = Math.cos(facing);
      const sinF: number = Math.sin(facing);
      for (let p: number = 0; p < this.soldiers.length; p++) {
        const s: SoldierPoolItem = this.soldiers[p];
        if (s.active && s.squadId === squadId) {
          s.x = Math.max(
            48.0,
            Math.min(this.worldWidth - 48.0, spawnX + s.slotOffsetX * cosF - s.slotOffsetY * sinF)
          );
          s.y = Math.max(
            48.0,
            Math.min(this.worldHeight - 48.0, spawnY + s.slotOffsetX * sinF + s.slotOffsetY * cosF)
          );
        }
      }
    }
  }

  private computeCorpsSpawnAndTarget(
    side: BattleSide,
    role: ArmyCorpsRole,
    subIndex: number
  ): Float64Array {
    const w: number = this.worldWidth;
    const h: number = this.worldHeight;
    const midX: number = w * 0.5;
    const midY: number = h * 0.5;
    const isPlayer: boolean = side === BattleSide.PLAYER;
    const out: Float64Array = new Float64Array(4);

    if (role === ArmyCorpsRole.VANGUARD_CENTER) {
      const yShift: number = (subIndex % 2 === 0 ? -75.0 : 75.0);
      out[0] = isPlayer ? 1180.0 : w - 1180.0;
      out[1] = midY + yShift;
      out[2] = isPlayer ? midX + 260.0 : midX - 260.0;
      out[3] = midY + yShift * 0.5;
      return out;
    }
    if (role === ArmyCorpsRole.LEFT_WING) {
      out[0] = isPlayer ? 1120.0 : w - 1120.0;
      out[1] = 360.0;
      out[2] = isPlayer ? w - 1350.0 : 1350.0;
      out[3] = 420.0;
      return out;
    }
    if (role === ArmyCorpsRole.RIGHT_WING) {
      out[0] = isPlayer ? 1120.0 : w - 1120.0;
      out[1] = h - 360.0;
      out[2] = isPlayer ? w - 1350.0 : 1350.0;
      out[3] = h - 420.0;
      return out;
    }
    if (role === ArmyCorpsRole.SIEGE_BATTERY) {
      const sShift: number = (subIndex % 3 - 1) * 70.0;
      out[0] = isPlayer ? 940.0 : w - 940.0;
      out[1] = midY + sShift;
      out[2] = isPlayer ? midX - 240.0 : midX + 240.0;
      out[3] = midY + sShift;
      return out;
    }
    if (role === ArmyCorpsRole.SUPPLY_ESCORT) {
      out[0] = isPlayer ? 760.0 : w - 760.0;
      out[1] = h - 380.0;
      out[2] = isPlayer ? 1120.0 : w - 1120.0;
      out[3] = h - 380.0;
      return out;
    }
    // REAR_RESERVE 总预备队
    const rShift: number = (subIndex % 2 === 0 ? -60.0 : 60.0);
    out[0] = isPlayer ? 820.0 : w - 820.0;
    out[1] = midY + rShift;
    out[2] = isPlayer ? midX - 100.0 : midX + 100.0;
    out[3] = midY + rShift;
    return out;
  }

  private pickDefaultFormation(category: UnitCategory, role: ArmyCorpsRole): FormationType {
    if (category === UnitCategory.RANGED || category === UnitCategory.SIEGE) {
      return FormationType.ECHELON_LINE;
    }
    if (
      category === UnitCategory.CAVALRY ||
      category === UnitCategory.SHOCK ||
      role === ArmyCorpsRole.LEFT_WING ||
      role === ArmyCorpsRole.RIGHT_WING
    ) {
      return FormationType.WEDGE_CHARGE;
    }
    return FormationType.PHALANX_RECT;
  }

  private pickInitialTacticalOrder(
    side: BattleSide,
    role: ArmyCorpsRole,
    factionId: FactionId
  ): TacticalOrder {
    if (
      this.config.scenarioType === BattleScenarioType.SIEGE_DEFENSE &&
      side === BattleSide.PLAYER &&
      (role === ArmyCorpsRole.VANGUARD_CENTER || role === ArmyCorpsRole.SIEGE_BATTERY)
    ) {
      return TacticalOrder.HOLD_GROUND;
    }
    if (
      this.config.scenarioType === BattleScenarioType.SIEGE_ASSAULT &&
      side === BattleSide.ENEMY &&
      (role === ArmyCorpsRole.VANGUARD_CENTER || role === ArmyCorpsRole.SIEGE_BATTERY)
    ) {
      return TacticalOrder.HOLD_GROUND;
    }
    if (role === ArmyCorpsRole.LEFT_WING || role === ArmyCorpsRole.RIGHT_WING) {
      return factionId === FactionId.CANGLANG ? TacticalOrder.PINCER_ENCIRCLE : TacticalOrder.FLANK;
    }
    return TacticalOrder.ADVANCE;
  }

  private computeInitialSquadMorale(
    factionId: FactionId,
    unitType: UnitTypeId,
    category: UnitCategory,
    modifier: number
  ): number {
    let m: number = GameConstants.MORALE_BASE + modifier;
    if (
      factionId === FactionId.CANGLANG &&
      (category === UnitCategory.INFANTRY || category === UnitCategory.POLEARM)
    ) {
      m -= 5.0; // 苍狼步兵抗线士气 -5
    }
    if (
      factionId === FactionId.SHAMO &&
      (category === UnitCategory.INFANTRY || category === UnitCategory.POLEARM)
    ) {
      m -= 6.0; // 沙漠商盟本土步兵初始士气 -6
    }
    if (unitType === UnitTypeId.XUEYUE_WARDRUM_BERSERKER && m < 50.0) {
      m = 50.0;
    }
    return Math.max(25.0, Math.min(GameConstants.MORALE_MAX, m));
  }

  private formatCorpsTitle(role: ArmyCorpsRole, unitName: string): string {
    if (role === ArmyCorpsRole.VANGUARD_CENTER) {
      return `中军前锋·${unitName}`;
    }
    if (role === ArmyCorpsRole.LEFT_WING) {
      return `左翼军团·${unitName}`;
    }
    if (role === ArmyCorpsRole.RIGHT_WING) {
      return `右翼军团·${unitName}`;
    }
    if (role === ArmyCorpsRole.REAR_RESERVE) {
      return `总预备队·${unitName}`;
    }
    if (role === ArmyCorpsRole.SIEGE_BATTERY) {
      return `远程攻城·${unitName}`;
    }
    return `辎重护粮·${unitName}`;
  }

  private findFreeSoldierSlot(): number {
    for (let i: number = 0; i < this.soldiers.length; i++) {
      if (!this.soldiers[i].active) {
        return i;
      }
    }
    return -1;
  }

  private findOrCreateSquadForRecruit(
    side: BattleSide,
    faction: FactionId,
    role: ArmyCorpsRole,
    unitType: UnitTypeId
  ): SquadRuntimeItem {
    const list: SquadRuntimeItem[] = side === BattleSide.PLAYER ? this.playerSquads : this.enemySquads;
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].corpsRole === role && list[i].primaryUnitType === unitType && !list[i].isRouting) {
        return list[i];
      }
    }
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].corpsRole === role && !list[i].isRouting) {
        return list[i];
      }
    }

    const stats: UnitStaticStats = fastUnitStats(unitType);
    const coords: Float64Array = this.computeCorpsSpawnAndTarget(side, role, 0);
    const sqId: number = this.squads.length;
    const sq: SquadRuntimeItem = new SquadRuntimeItem(
      sqId,
      side,
      faction,
      role,
      this.formatCorpsTitle(role, stats.name),
      unitType,
      this.pickDefaultFormation(stats.category, role),
      TacticalOrder.ADVANCE,
      GameConstants.MORALE_BASE,
      coords[0],
      coords[1],
      side === BattleSide.PLAYER ? 0 : Math.PI,
      coords[2],
      coords[3]
    );
    this.squads.push(sq);
    list.push(sq);
    return sq;
  }

  private activateSoldierInPool(
    poolIdx: number,
    side: BattleSide,
    factionId: FactionId,
    unitType: UnitTypeId,
    squadId: number,
    corpsRole: ArmyCorpsRole,
    x: number,
    y: number,
    facingRad: number,
    isBannerBearer: boolean,
    isMercenary: boolean
  ): void {
    const stats: UnitStaticStats = fastUnitStats(unitType);
    const hpMult: number = factionId === FactionId.SHUANGYUAN ? 1.15 : 1.0; // 霜原熊族全军生命 +15%
    const maxHp: number = Math.round(stats.hp * hpMult);

    const s: SoldierPoolItem = this.soldiers[poolIdx];
    s.active = true;
    s.side = side;
    s.factionId = factionId;
    s.unitType = unitType;
    s.category = stats.category;
    s.squadId = squadId;
    s.corpsRole = corpsRole;
    s.isBannerBearer = isBannerBearer;
    s.isMercenary = isMercenary;
    s.x = x;
    s.y = y;
    s.vx = 0;
    s.vy = 0;
    s.facingRad = facingRad;
    s.hp = maxHp;
    s.maxHp = maxHp;
    s.actionState = UnitActionState.IDLE_READY;
    s.animPhase = (poolIdx % 10) * 0.1;
    s.attackCooldown = (poolIdx % 5) * 0.08;
    s.chargeRunTime = 0;
    s.chargeCooldown = 0;
    s.staggerTimer = 0;
    s.poisonTimer = 0;
    s.isStealthed = unitType === UnitTypeId.WULIN_SHADOW_SNIPER;
    s.visibleToPlayer = side === BattleSide.PLAYER;
    s.visibleToEnemy = side === BattleSide.ENEMY;
    s.grenadeUsed = false;
    s.slotOffsetX = 0;
    s.slotOffsetY = 0;
    s.targetEntityIndex = -1;

    this.soldierIdleCombatSec[poolIdx] = 5.0;
    this.soldierSearchTimer[poolIdx] = 0;
    this.soldierCarryAmount[poolIdx] = 0;
    this.soldierCarryKind[poolIdx] = 0;
  }

  // ==================== 后勤断粮、保底军饷与应急民夫 ====================

  private stepLogisticsAndEconomy(dtSec: number): void {
    // 1. 本阵保底产出（+1.2 金/s, +0.5 木/s，防零经济死锁 DESIGN.md 10.4）
    if (this.playerBaseCamp !== null && !this.playerBaseCamp.isBreached && this.playerBaseCamp.hp > 0) {
      const goldMultP: number = this.config.playerFaction === FactionId.SHAMO ? 1.35 : 1.0;
      this.playerGold += 1.2 * goldMultP * dtSec;
      this.playerWood += 0.5 * dtSec;
    }
    if (this.enemyBaseCamp !== null && !this.enemyBaseCamp.isBreached && this.enemyBaseCamp.hp > 0) {
      const goldMultE: number = this.config.enemyFaction === FactionId.SHAMO ? 1.35 : 1.0;
      this.enemyGold += 1.2 * goldMultE * dtSec;
      this.enemyWood += 0.5 * dtSec;
    }

    // 2. 统计双方全军耗粮速率、工兵存活数与外籍雇佣兵数量
    let pUpkeep: number = 0;
    let eUpkeep: number = 0;
    let pSappers: number = 0;
    let eSappers: number = 0;
    let pMercs: number = 0;
    let eMercs: number = 0;

    for (let i: number = 0; i < this.soldiers.length; i++) {
      const s: SoldierPoolItem = this.soldiers[i];
      if (!s.active || s.hp <= 0) {
        continue;
      }
      const stats: UnitStaticStats = fastUnitStats(s.unitType);
      let unitUpkeep: number = stats.grainUpkeepPerSec;

      sampleTerrainAtPoint(s.x, s.y, this.terrainZones, this.config.terrain, this.terrainSampleA);
      if (
        this.terrainSampleA.terrain === TerrainType.DESERT_DUNE &&
        s.factionId !== FactionId.SHAMO
      ) {
        unitUpkeep *= 1.30;
      } else if (
        this.terrainSampleA.terrain === TerrainType.SNOWFIELD &&
        s.factionId !== FactionId.SHUANGYUAN
      ) {
        unitUpkeep *= 1.25;
      }
      if (this.config.weather === WeatherType.BLIZZARD && s.factionId !== FactionId.SHUANGYUAN) {
        unitUpkeep *= 1.15;
      }
      if (s.factionId === FactionId.SHUANGYUAN) {
        unitUpkeep *= 1.15; // 霜原熊族食量 +15%
      }

      if (s.side === BattleSide.PLAYER) {
        pUpkeep += unitUpkeep;
        if (s.unitType === UnitTypeId.SAPPER) {
          pSappers++;
        }
        if (s.isMercenary) {
          pMercs++;
        }
      } else {
        eUpkeep += unitUpkeep;
        if (s.unitType === UnitTypeId.SAPPER) {
          eSappers++;
        }
        if (s.isMercenary) {
          eMercs++;
        }
      }
    }

    // 3. 玩家断粮阶段更新（断粮期间沙漠商盟外籍雇佣兵索要应急军饷折银）
    this.playerGrain = Math.max(0, this.playerGrain - pUpkeep * dtSec);
    if (this.playerGrain <= 0) {
      this.playerZeroGrainSec += dtSec;
      if (this.config.playerFaction === FactionId.SHAMO && pMercs > 0) {
        this.playerGold = Math.max(0, this.playerGold - pMercs * 0.35 * dtSec);
      }
    } else {
      this.playerZeroGrainSec = 0;
    }
    this.playerRationStage = evaluateRationStage(
      this.playerGrain,
      pUpkeep,
      this.playerZeroGrainSec
    );

    // 4. 敌方断粮阶段更新
    this.enemyGrain = Math.max(0, this.enemyGrain - eUpkeep * dtSec);
    if (this.enemyGrain <= 0) {
      this.enemyZeroGrainSec += dtSec;
      if (this.config.enemyFaction === FactionId.SHAMO && eMercs > 0) {
        this.enemyGold = Math.max(0, this.enemyGold - eMercs * 0.35 * dtSec);
      }
    } else {
      this.enemyZeroGrainSec = 0;
    }
    this.enemyRationStage = evaluateRationStage(this.enemyGrain, eUpkeep, this.enemyZeroGrainSec);

    // 5. 沙漠商盟断粮饥溃 (>30s) 且无金时，外籍雇佣兵直接离场
    if (
      this.config.playerFaction === FactionId.SHAMO &&
      this.playerRationStage === BattlefieldRationStage.STARVING &&
      this.playerGold <= 0
    ) {
      this.dismissMercenaries(BattleSide.PLAYER);
    }
    if (
      this.config.enemyFaction === FactionId.SHAMO &&
      this.enemyRationStage === BattlefieldRationStage.STARVING &&
      this.enemyGold <= 0
    ) {
      this.dismissMercenaries(BattleSide.ENEMY);
    }

    // 6. 零金（<35）+ 零工兵 25s 自动免费征召 1 名应急民夫（DESIGN.md 10.4）
    if (
      pSappers === 0 &&
      this.playerGold < 35.0 &&
      this.playerBaseCamp !== null &&
      !this.playerBaseCamp.isBreached &&
      this.playerBaseCamp.hp > 0
    ) {
      this.playerEmergencySapperSec += dtSec;
      if (this.playerEmergencySapperSec >= 25.0) {
        this.playerEmergencySapperSec = 0;
        this.spawnFreeEmergencySapper(BattleSide.PLAYER);
      }
    } else {
      this.playerEmergencySapperSec = 0;
    }

    if (
      eSappers === 0 &&
      this.enemyGold < 35.0 &&
      this.enemyBaseCamp !== null &&
      !this.enemyBaseCamp.isBreached &&
      this.enemyBaseCamp.hp > 0
    ) {
      this.enemyEmergencySapperSec += dtSec;
      if (this.enemyEmergencySapperSec >= 25.0) {
        this.enemyEmergencySapperSec = 0;
        this.spawnFreeEmergencySapper(BattleSide.ENEMY);
      }
    } else {
      this.enemyEmergencySapperSec = 0;
    }
  }

  private dismissMercenaries(side: BattleSide): void {
    let dismissedAny: boolean = false;
    for (let i: number = 0; i < this.soldiers.length; i++) {
      const s: SoldierPoolItem = this.soldiers[i];
      if (s.active && s.side === side && s.isMercenary) {
        s.active = false;
        s.hp = 0;
        dismissedAny = true;
      }
    }
    if (dismissedAny) {
      this.hudDirty = true;
    }
  }

  private spawnFreeEmergencySapper(side: BattleSide): void {
    const freeIdx: number = this.findFreeSoldierSlot();
    const camp: FortStructureItem | null =
      side === BattleSide.PLAYER ? this.playerBaseCamp : this.enemyBaseCamp;
    if (freeIdx === -1 || camp === null) {
      return;
    }
    const faction: FactionId =
      side === BattleSide.PLAYER ? this.config.playerFaction : this.config.enemyFaction;
    const sq: SquadRuntimeItem = this.findOrCreateSquadForRecruit(
      side,
      faction,
      ArmyCorpsRole.SUPPLY_ESCORT,
      UnitTypeId.SAPPER
    );
    const sx: number = camp.x + camp.width * 0.5;
    const sy: number = camp.y + camp.height + 16.0;
    this.activateSoldierInPool(
      freeIdx,
      side,
      faction,
      UnitTypeId.SAPPER,
      sq.squadId,
      ArmyCorpsRole.SUPPLY_ESCORT,
      sx,
      sy,
      side === BattleSide.PLAYER ? 0 : Math.PI,
      sq.aliveCount === 0,
      false
    );
    sq.initialCount++;
    sq.aliveCount++;
    const sapperPop: number = fastUnitStats(UnitTypeId.SAPPER).popCap;
    if (side === BattleSide.PLAYER) {
      this.playerInitialTotal++;
      this.playerAliveCount++;
      this.playerPopUsed += sapperPop;
    } else {
      this.enemyInitialTotal++;
      this.enemyAliveCount++;
      this.enemyPopUsed += sapperPop;
    }
    assignSquadFormationSlots(sq, this.soldiers);
    this.spatialGrid.insert(freeIdx, sx, sy);
    this.hudDirty = true;
  }

  /**
   * 劫掠敌方大营随军粮车：当场夺取 150 应急粮草（苍狼汗国翻倍为 300）解除饥荒
   */
  public triggerSupplyCampRaid(raiderSide: BattleSide): number {
    if (raiderSide === BattleSide.PLAYER) {
      if (this.playerCampRaidCd > 0) {
        return 0;
      }
      this.playerCampRaidCd = 18.0;
      const loot: number = this.config.playerFaction === FactionId.CANGLANG ? 300.0 : 150.0;
      this.enemyGrain = Math.max(0, this.enemyGrain - 150.0);
      this.playerGrain += loot;
      this.playerZeroGrainSec = 0;
      this.playerRaidLootedGrain += loot;
      this.playerRationStage = evaluateRationStage(this.playerGrain, 1.0, 0);
      this.hudDirty = true;
      return loot;
    } else {
      if (this.enemyCampRaidCd > 0) {
        return 0;
      }
      this.enemyCampRaidCd = 18.0;
      const loot: number = this.config.enemyFaction === FactionId.CANGLANG ? 300.0 : 150.0;
      this.playerGrain = Math.max(0, this.playerGrain - 150.0);
      this.enemyGrain += loot;
      this.enemyZeroGrainSec = 0;
      this.enemyRationStage = evaluateRationStage(this.enemyGrain, 1.0, 0);
      this.hudDirty = true;
      return loot;
    }
  }

  // ==================== 八象限扫描、士气演化与分队导航 ====================

  private refreshAllSquadStatsAndEncirclement(runOctantScan: boolean): void {
    const pCampX: number = this.playerBaseCamp !== null ? this.playerBaseCamp.x : 400.0;
    const pCampY: number =
      this.playerBaseCamp !== null ? this.playerBaseCamp.y + 110.0 : this.worldHeight * 0.5;
    const eCampX: number =
      this.enemyBaseCamp !== null ? this.enemyBaseCamp.x : this.worldWidth - 400.0;
    const eCampY: number =
      this.enemyBaseCamp !== null ? this.enemyBaseCamp.y + 110.0 : this.worldHeight * 0.5;

    for (let i: number = 0; i < this.squads.length; i++) {
      const sq: SquadRuntimeItem = this.squads[i];
      refreshSquadMetricsAndFordRatio(
        sq,
        this.soldiers,
        this.terrainZones,
        this.config.terrain
      );
      if (runOctantScan) {
        if (sq.side === BattleSide.PLAYER) {
          scanSquadOctantEncirclement(
            sq,
            this.soldiers,
            this.enemyHero,
            this.spatialGrid,
            pCampX,
            pCampY,
            this.octantScratch,
            160.0
          );
        } else {
          scanSquadOctantEncirclement(
            sq,
            this.soldiers,
            this.playerHero,
            this.spatialGrid,
            eCampX,
            eCampY,
            this.octantScratch,
            160.0
          );
        }
      }
    }
    this.recountArmyTotals();
  }

  private stepSquadMoraleAndGuidance(dtSec: number): void {
    const pHeroRecovering: boolean =
      this.playerHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP;
    const eHeroRecovering: boolean =
      this.enemyHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP;
    const pHeroAlive: boolean =
      this.playerHero.vitalState === HeroVitalState.HEALTHY_ACTIVE ||
      this.playerHero.vitalState === HeroVitalState.WOUNDED_WEAKENED;
    const eHeroAlive: boolean =
      this.enemyHero.vitalState === HeroVitalState.HEALTHY_ACTIVE ||
      this.enemyHero.vitalState === HeroVitalState.WOUNDED_WEAKENED;

    // 计算敌我主力质心作为接敌朝向参考焦点
    let pFocusX: number = 800.0;
    let pFocusY: number = this.worldHeight * 0.5;
    let pFocusCount: number = 0;
    let eFocusX: number = this.worldWidth - 800.0;
    let eFocusY: number = this.worldHeight * 0.5;
    let eFocusCount: number = 0;

    for (let i: number = 0; i < this.squads.length; i++) {
      const sq: SquadRuntimeItem = this.squads[i];
      if (sq.aliveCount > 0 && !sq.isRouting) {
        if (sq.side === BattleSide.PLAYER) {
          pFocusX = (pFocusX * pFocusCount + sq.centerX) / (pFocusCount + 1);
          pFocusY = (pFocusY * pFocusCount + sq.centerY) / (pFocusCount + 1);
          pFocusCount++;
        } else {
          eFocusX = (eFocusX * eFocusCount + sq.centerX) / (eFocusCount + 1);
          eFocusY = (eFocusY * eFocusCount + sq.centerY) / (eFocusCount + 1);
          eFocusCount++;
        }
      }
    }

    const pBaseX: number = this.playerBaseCamp !== null ? this.playerBaseCamp.x + 90.0 : 420.0;
    const pBaseY: number = this.playerBaseCamp !== null ? this.playerBaseCamp.y + 110.0 : this.worldHeight * 0.5;
    const eBaseX: number =
      this.enemyBaseCamp !== null ? this.enemyBaseCamp.x + 90.0 : this.worldWidth - 420.0;
    const eBaseY: number =
      this.enemyBaseCamp !== null ? this.enemyBaseCamp.y + 110.0 : this.worldHeight * 0.5;

    for (let i: number = 0; i < this.squads.length; i++) {
      const sq: SquadRuntimeItem = this.squads[i];
      if (sq.aliveCount <= 0) {
        continue;
      }
      if (sq.bannerLostPenaltyTimer > 0) {
        sq.bannerLostPenaltyTimer = Math.max(0, sq.bannerLostPenaltyTimer - dtSec);
      }
      if (i < this.squadUnderFireSec.length && this.squadUnderFireSec[i] > 0) {
        this.squadUnderFireSec[i] = Math.max(0, this.squadUnderFireSec[i] - dtSec);
      }

      const isPlayer: boolean = sq.side === BattleSide.PLAYER;
      const heroX: number = isPlayer ? this.playerHero.x : this.enemyHero.x;
      const heroY: number = isPlayer ? this.playerHero.y : this.enemyHero.y;
      const heroActive: boolean = isPlayer ? pHeroAlive : eHeroAlive;
      const auraSq: number =
        (sq.centerX - heroX) * (sq.centerX - heroX) + (sq.centerY - heroY) * (sq.centerY - heroY);
      const inHeroAura: boolean = heroActive && auraSq <= 350.0 * 350.0;

      const hasMerc: boolean =
        sq.factionId === FactionId.SHAMO &&
        sq.primaryUnitType !== UnitTypeId.SHAMO_MAMELUKE_CAMEL &&
        sq.primaryUnitType !== UnitTypeId.SAPPER;

      let rate: number = computeSquadContinuousMoraleRate(
        sq,
        isPlayer ? this.playerRationStage : this.enemyRationStage,
        isPlayer ? this.playerGold : this.enemyGold,
        hasMerc,
        inHeroAura,
        this.config.weather
      );
      // 正遭受远程箭雨轰击期间（4s 内受创）取消脱战自然回士气
      if (
        i < this.squadUnderFireSec.length &&
        this.squadUnderFireSec[i] > 0 &&
        sq.threatOctantMask === 0 &&
        (isPlayer ? this.playerRationStage : this.enemyRationStage) !== BattlefieldRationStage.HUNGRY &&
        (isPlayer ? this.playerRationStage : this.enemyRationStage) !== BattlefieldRationStage.STARVING
      ) {
        rate -= 1.2;
      }

      const newlyRouted: boolean = applySquadMoraleAndHysteresis(
        sq,
        rate * dtSec,
        isPlayer ? pHeroRecovering : eHeroRecovering,
        false
      );
      if (newlyRouted) {
        this.onSquadBrokeIntoRout(sq);
      }

      // 敌我无外部新目标且已抵达旧航点时，自动牵引向敌军前线或敌营推进，确保大战持续激烈交火
      if (
        !sq.isRouting &&
        sq.corpsRole !== ArmyCorpsRole.SUPPLY_ESCORT &&
        sq.order !== TacticalOrder.HOLD_GROUND &&
        sq.order !== TacticalOrder.RETREAT &&
        sq.order !== TacticalOrder.AMBUSH_HIDE &&
        (sq.side === BattleSide.PLAYER || this.enemyCommandParalysisSec <= 0)
      ) {
        const dxT: number = sq.targetX - sq.centerX;
        const dyT: number = sq.targetY - sq.centerY;
        if (dxT * dxT + dyT * dyT < 90.0 * 90.0 && sq.waypointCursor >= sq.waypointsX.length) {
          sq.targetX = isPlayer ? eFocusX : pFocusX;
          sq.targetY = isPlayer ? eFocusY : pFocusY;
        }
      }

      updateSquadOrderGuidance(
        sq,
        dtSec,
        isPlayer ? pBaseX : eBaseX,
        isPlayer ? pBaseY : eBaseY,
        isPlayer ? eFocusX : pFocusX,
        isPlayer ? eFocusY : pFocusY,
        this.worldWidth,
        this.worldHeight,
        this.squadGuideOut
      );

      if (i < this.squadTargetMapX.length) {
        this.squadTargetMapX[i] = this.squadGuideOut[0];
        this.squadTargetMapY[i] = this.squadGuideOut[1];
      }
    }
  }

  /** 当某支分队刚崩溃进入溃逃时，结算玄甲重骑 50% 冲锋冷却重置及苍狼/敌方士气激励 */
  private onSquadBrokeIntoRout(routedSquad: SquadRuntimeItem): void {
    const victorSide: BattleSide =
      routedSquad.side === BattleSide.PLAYER ? BattleSide.ENEMY : BattleSide.PLAYER;
    const victorSquads: SquadRuntimeItem[] =
      victorSide === BattleSide.PLAYER ? this.playerSquads : this.enemySquads;
    const victorHeroDown: boolean =
      victorSide === BattleSide.PLAYER
        ? this.playerHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP
        : this.enemyHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP;

    for (let i: number = 0; i < victorSquads.length; i++) {
      const vsq: SquadRuntimeItem = victorSquads[i];
      if (vsq.aliveCount <= 0) {
        continue;
      }
      const dx: number = vsq.centerX - routedSquad.centerX;
      const dy: number = vsq.centerY - routedSquad.centerY;
      if (dx * dx + dy * dy <= 280.0 * 280.0) {
        const boost: number = vsq.factionId === FactionId.XUANJIA ? 12.0 : 6.0;
        applySquadMoraleAndHysteresis(vsq, boost, victorHeroDown, false);
      }
    }

    // 玄甲重骑军团特性：击溃敌队重置 50% 冲锋冷却！
    for (let i: number = 0; i < this.soldiers.length; i++) {
      const s: SoldierPoolItem = this.soldiers[i];
      if (
        s.active &&
        s.hp > 0 &&
        s.side === victorSide &&
        (s.factionId === FactionId.XUANJIA || s.unitType === UnitTypeId.XUANJIA_CATAPHRACT) &&
        s.category === UnitCategory.CAVALRY
      ) {
        const dx: number = s.x - routedSquad.centerX;
        const dy: number = s.y - routedSquad.centerY;
        if (dx * dx + dy * dy <= 280.0 * 280.0) {
          s.chargeCooldown *= 0.50;
        }
      }
    }
  }

  // ==================== 单兵运动、16 兵种特色战斗与工兵采集 ====================

  private stepAllSoldiers(dtSec: number): void {
    // 预收集本帧活跃黄金马穆鲁克坐标（支撑 O(1) 惊马光环检索）
    let pMamelukeCount: number = 0;
    let eMamelukeCount: number = 0;
    for (let i: number = 0; i < this.soldiers.length; i++) {
      const s: SoldierPoolItem = this.soldiers[i];
      if (s.active && s.hp > 0 && s.unitType === UnitTypeId.SHAMO_MAMELUKE_CAMEL) {
        if (s.side === BattleSide.PLAYER && pMamelukeCount < this.mamelukePlayerX.length) {
          this.mamelukePlayerX[pMamelukeCount] = s.x;
          this.mamelukePlayerY[pMamelukeCount] = s.y;
          pMamelukeCount++;
        } else if (s.side === BattleSide.ENEMY && eMamelukeCount < this.mamelukeEnemyX.length) {
          this.mamelukeEnemyX[eMamelukeCount] = s.x;
          this.mamelukeEnemyY[eMamelukeCount] = s.y;
          eMamelukeCount++;
        }
      }
    }

    for (let i: number = 0; i < this.soldiers.length; i++) {
      const s: SoldierPoolItem = this.soldiers[i];
      if (!s.active || s.hp <= 0) {
        continue;
      }

      const sq: SquadRuntimeItem = this.squads[s.squadId];
      const stats: UnitStaticStats = fastUnitStats(s.unitType);
      const isPlayer: boolean = s.side === BattleSide.PLAYER;

      // 1. 计时器更新与雾林毒伤结算
      this.soldierIdleCombatSec[i] += dtSec;
      if (this.soldierSearchTimer[i] > 0) {
        this.soldierSearchTimer[i] -= dtSec;
      }
      if (s.attackCooldown > 0) {
        s.attackCooldown = Math.max(0, s.attackCooldown - dtSec);
      }
      if (s.chargeCooldown > 0) {
        s.chargeCooldown = Math.max(0, s.chargeCooldown - dtSec);
      }
      if (s.poisonTimer > 0) {
        s.poisonTimer = Math.max(0, s.poisonTimer - dtSec);
        s.hp -= 4.0 * dtSec;
        if (s.hp <= 0) {
          this.killSoldier(s, null);
          continue;
        }
      }

      sampleTerrainAtPoint(s.x, s.y, this.terrainZones, this.config.terrain, this.terrainSampleA);
      const curTerrain: TerrainType = this.terrainSampleA.terrain;
      const curElev: number = this.terrainSampleA.elevation;

      // 雾林影袭神射潜行进入检测（密林静止 1.2s、脱战 4s 或潜伏设伏态）
      if (s.unitType === UnitTypeId.WULIN_SHADOW_SNIPER && !sq.isRouting) {
        if (
          sq.order === TacticalOrder.AMBUSH_HIDE ||
          (curTerrain === TerrainType.DENSE_FOREST && this.soldierIdleCombatSec[i] >= 1.2) ||
          this.soldierIdleCombatSec[i] >= 4.0
        ) {
          s.isStealthed = true;
        }
      } else if (
        sq.order === TacticalOrder.AMBUSH_HIDE &&
        (curTerrain === TerrainType.DENSE_FOREST ||
          this.config.weather === WeatherType.HEAVY_FOG ||
          this.config.weather === WeatherType.NIGHT) &&
        this.soldierIdleCombatSec[i] >= 1.0
      ) {
        s.isStealthed = true;
      }

      // 受击硬直中无法移动或攻击
      if (s.staggerTimer > 0) {
        s.staggerTimer = Math.max(0, s.staggerTimer - dtSec);
        s.actionState = UnitActionState.STAGGER_HIT;
        s.chargeRunTime = 0;
        continue;
      }

      // 溃逃逃兵奔向本方地图边缘，抵达边缘直接溃散离场
      if (sq.isRouting) {
        s.actionState = UnitActionState.ROUT_PANIC;
        s.isStealthed = false;
        s.chargeRunTime = 0;
        const fleeDirX: number = isPlayer ? -1.0 : 1.0;
        s.facingRad = isPlayer ? Math.PI : 0;
        const routSpd: number = stats.moveSpeed * 1.10;
        s.vx = fleeDirX * routSpd;
        s.vy = 0;
        s.x += s.vx * dtSec;
        if ((isPlayer && s.x <= 24.0) || (!isPlayer && s.x >= this.worldWidth - 24.0)) {
          s.active = false;
          s.hp = 0;
        }
        s.animPhase = (s.animPhase + dtSec * 4.2) % 1.0;
        continue;
      }

      // 辎重工兵专属采集与本阵警钟入营协防逻辑
      if (s.unitType === UnitTypeId.SAPPER) {
        this.stepSapperUnit(s, sq, stats, dtSec);
        continue;
      }

      // 检查黄金马穆鲁克 160px 惊马光环
      let spookedByCamel: boolean = false;
      if (
        s.category === UnitCategory.CAVALRY &&
        s.unitType !== UnitTypeId.SHAMO_MAMELUKE_CAMEL
      ) {
        const mCount: number = isPlayer ? eMamelukeCount : pMamelukeCount;
        const mxArr: Float64Array = isPlayer ? this.mamelukeEnemyX : this.mamelukePlayerX;
        const myArr: Float64Array = isPlayer ? this.mamelukeEnemyY : this.mamelukePlayerY;
        for (let m: number = 0; m < mCount; m++) {
          const dmx: number = s.x - mxArr[m];
          const dmy: number = s.y - myArr[m];
          if (dmx * dmx + dmy * dmy <= MAMELUKE_SPOOK_RADIUS_SQ) {
            spookedByCamel = true;
            break;
          }
        }
      }

      const ownHero: CommanderHeroEntity = isPlayer ? this.playerHero : this.enemyHero;
      const warCryActive: boolean =
        ownHero.warCryBuffTimer > 0 &&
        (s.x - ownHero.x) * (s.x - ownHero.x) + (s.y - ownHero.y) * (s.y - ownHero.y) <=
          340.0 * 340.0;
      const bloodFrenzyActive: boolean = isPlayer
        ? this.playerBloodFrenzySec > 0
        : this.enemyBloodFrenzySec > 0;

      const maxMoveSpd: number = computeEffectiveSoldierSpeed(
        stats.moveSpeed,
        stats.armor,
        s.category,
        s.factionId,
        sq.formation,
        sq.bannerLostPenaltyTimer > 0,
        sq.morale,
        curTerrain,
        this.config.weather,
        isPlayer ? this.playerRationStage : this.enemyRationStage,
        s.poisonTimer > 0,
        spookedByCamel,
        warCryActive,
        bloodFrenzyActive
      );

      // 计算有效攻击射程（高地+20%，城头+25%，铁鹰远程+12%，霜原远程-10%，暴雨-20%）
      const effRange: number = this.computeEffectiveAttackRange(
        stats,
        s.factionId,
        curTerrain,
        curElev
      );

      // 索敌（优先复用已锁定存活目标，远程装填期无需每帧全局扫描）
      let targetSoldier: SoldierPoolItem | null = null;
      if (s.targetEntityIndex >= 0 && s.targetEntityIndex < this.soldiers.length) {
        const cand: SoldierPoolItem = this.soldiers[s.targetEntityIndex];
        if (
          cand.active &&
          cand.hp > 0 &&
          cand.side !== s.side &&
          (isPlayer ? cand.visibleToPlayer : cand.visibleToEnemy)
        ) {
          const cdx: number = cand.x - s.x;
          const cdy: number = cand.y - s.y;
          const cDistSq: number = cdx * cdx + cdy * cdy;
          const maxKeepRange: number = Math.max(effRange + 45.0, 170.0);
          if (cDistSq <= maxKeepRange * maxKeepRange && cDistSq >= stats.minRange * stats.minRange) {
            targetSoldier = cand;
          } else {
            s.targetEntityIndex = -1;
          }
        } else {
          s.targetEntityIndex = -1;
        }
      }

      const needTargetNow: boolean =
        targetSoldier === null &&
        this.soldierSearchTimer[i] <= 0 &&
        (effRange <= 65.0 || s.attackCooldown <= 0.12);

      if (needTargetNow) {
        const searchR: number = Math.max(effRange, 165.0);
        targetSoldier = this.acquireBestEnemyTarget(s, searchR, stats.minRange);
        if (targetSoldier !== null) {
          s.targetEntityIndex = targetSoldier.poolIndex;
        } else {
          this.soldierSearchTimer[i] = 0.16;
        }
      }

      // L3 本能反应：长枪方阵兵 / 神机重卫检测到 140px 内敌骑冲来时自动停步正面架枪！
      let autoBraceHalt: boolean = false;
      if (
        (s.unitType === UnitTypeId.PIKEMAN ||
          s.unitType === UnitTypeId.YANLONG_HALBERD_GRENADIER) &&
        targetSoldier !== null &&
        targetSoldier.category === UnitCategory.CAVALRY
      ) {
        const cDx: number = targetSoldier.x - s.x;
        const cDy: number = targetSoldier.y - s.y;
        const cDistSq: number = cDx * cDx + cDy * cDy;
        const cavSpdSq: number =
          targetSoldier.vx * targetSoldier.vx + targetSoldier.vy * targetSoldier.vy;
        if (
          cDistSq <= 140.0 * 140.0 &&
          (targetSoldier.chargeRunTime > 0.35 || cavSpdSq > 60.0 * 60.0)
        ) {
          autoBraceHalt = true;
          s.vx = 0;
          s.vy = 0;
          s.chargeRunTime = 0;
          s.facingRad = Math.atan2(cDy, cDx);
          if (s.attackCooldown > 0.1) {
            s.actionState = UnitActionState.IDLE_READY;
          }
        }
      }

      // 炎龙神机重卫首接敌投掷震天火雷（45px~155px 内触发一次）
      if (
        s.unitType === UnitTypeId.YANLONG_HALBERD_GRENADIER &&
        !s.grenadeUsed &&
        targetSoldier !== null
      ) {
        const gDx: number = targetSoldier.x - s.x;
        const gDy: number = targetSoldier.y - s.y;
        const gDistSq: number = gDx * gDx + gDy * gDy;
        if (gDistSq >= 36.0 * 36.0 && gDistSq <= 155.0 * 155.0) {
          s.grenadeUsed = true;
          s.attackCooldown = Math.max(s.attackCooldown, 0.85);
          s.facingRad = Math.atan2(gDy, gDx);
          s.actionState = UnitActionState.RANGED_DRAW_FIRE;
          this.soldierIdleCombatSec[i] = 0;
          const bombDmg: number = this.config.weather === WeatherType.RAIN_MUD ? 22.0 : 44.0;
          this.spawnProjectile(
            s.side,
            ProjectileKind.FIRE_BOMB,
            s.x,
            s.y,
            targetSoldier.x,
            targetSoldier.y,
            52.0,
            0.48,
            bombDmg,
            0.60,
            68.0,
            1,
            false,
            12.0
          );
          continue;
        }
      }

      // 苍狼怯薛骑射“曼古歹”边退边射风筝机制
      let keshigKiting: boolean = false;
      if (
        s.unitType === UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER &&
        targetSoldier !== null &&
        sq.order !== TacticalOrder.ALL_OUT_CHARGE
      ) {
        const targetSq: SquadRuntimeItem = this.squads[targetSoldier.squadId];
        const kDx: number = targetSoldier.x - s.x;
        const kDy: number = targetSoldier.y - s.y;
        const kDistSq: number = kDx * kDx + kDy * kDy;
        if (kDistSq < 150.0 * 150.0 && targetSq.morale >= 35.0 && !targetSq.isRouting) {
          keshigKiting = true;
          const kDist: number = Math.max(1.0, Math.sqrt(kDistSq));
          s.vx = (-kDx / kDist) * maxMoveSpd * 0.88;
          s.vy = (-kDy / kDist) * maxMoveSpd * 0.88;
          s.x += s.vx * dtSec;
          s.y += s.vy * dtSec;
          s.facingRad = Math.atan2(kDy, kDx);
          s.actionState = UnitActionState.RANGED_DRAW_FIRE;
        }
      }

      // 判断目标是否已在攻击射程内
      let inAttackRange: boolean = false;
      if (targetSoldier !== null) {
        const tDx: number = targetSoldier.x - s.x;
        const tDy: number = targetSoldier.y - s.y;
        const tDistSq: number = tDx * tDx + tDy * tDy;
        if (tDistSq <= effRange * effRange && tDistSq >= stats.minRange * stats.minRange) {
          inAttackRange = true;
        }
      }

      // 检查是否抵近敌方主帅或敌方城墙/城门/大营直接交战
      const opposingHero: CommanderHeroItem =
        s.side === BattleSide.PLAYER ? this.enemyHero : this.playerHero;
      const oppHeroActive: boolean =
        opposingHero.hp > 0 &&
        (opposingHero.vitalState === HeroVitalState.HEALTHY_ACTIVE ||
          opposingHero.vitalState === HeroVitalState.WOUNDED_WEAKENED);
      let targetHero: CommanderHeroItem | null = null;
      let engageHero: CommanderHeroItem | null = null;
      if (!inAttackRange && oppHeroActive) {
        const hDx: number = opposingHero.x - s.x;
        const hDy: number = opposingHero.y - s.y;
        const hDistSq: number = hDx * hDx + hDy * hDy;
        if (stats.attackRange <= 60.0) {
          const heroMeleeReach: number = effRange + 10.0;
          if (hDistSq <= heroMeleeReach * heroMeleeReach) {
            targetHero = opposingHero;
          } else if (targetSoldier === null && hDistSq <= 180.0 * 180.0) {
            engageHero = opposingHero;
          }
        } else if (
          targetSoldier === null &&
          hDistSq <= effRange * effRange &&
          hDistSq >= stats.minRange * stats.minRange &&
          hDistSq <= 420.0 * 420.0
        ) {
          targetHero = opposingHero;
        }
      }

      let targetStructure: FortStructureItem | null = null;
      if (!inAttackRange && targetHero === null) {
        targetStructure = this.findAttackableEnemyStructure(s, effRange);
      }

      if ((inAttackRange && targetSoldier !== null) || targetHero !== null || targetStructure !== null) {
        if (!keshigKiting) {
          s.vx = 0;
          s.vy = 0;
        }
        if (targetSoldier !== null && inAttackRange) {
          if (sq.formation === FormationType.CIRCLE_DEFENSE) {
            s.facingRad = Math.atan2(s.y - sq.centerY, s.x - sq.centerX);
          } else if (
            s.unitType === UnitTypeId.TIEYING_PAVISE_CROSSBOW &&
            s.attackCooldown > 0.30
          ) {
            // 铁鹰重装神弩手装填期转身背大盾（减免 60% 远程伤害）
            s.facingRad = Math.atan2(s.y - targetSoldier.y, s.x - targetSoldier.x);
            s.actionState = UnitActionState.SHIELD_BLOCK;
          } else {
            s.facingRad = Math.atan2(targetSoldier.y - s.y, targetSoldier.x - s.x);
          }

          if (s.attackCooldown <= 0) {
            this.executeSoldierAttackOnUnit(s, sq, stats, targetSoldier, spookedByCamel, warCryActive);
          } else if (
            s.unitType !== UnitTypeId.TIEYING_PAVISE_CROSSBOW &&
            !keshigKiting
          ) {
            s.actionState =
              s.attackCooldown < 0.22
                ? UnitActionState.MELEE_WINDUP
                : stats.shieldRangedBlock >= 0.35
                  ? UnitActionState.SHIELD_BLOCK
                  : UnitActionState.IDLE_READY;
          }
        } else if (targetHero !== null) {
          s.facingRad = Math.atan2(targetHero.y - s.y, targetHero.x - s.x);
          if (s.attackCooldown <= 0) {
            this.executeSoldierAttackOnHero(s, sq, stats, targetHero, warCryActive);
          } else {
            s.actionState =
              s.attackCooldown < 0.22
                ? UnitActionState.MELEE_WINDUP
                : stats.shieldRangedBlock >= 0.35
                  ? UnitActionState.SHIELD_BLOCK
                  : UnitActionState.IDLE_READY;
          }
        } else if (targetStructure !== null) {
          const stCx: number = targetStructure.x + targetStructure.width * 0.5;
          const stCy: number = targetStructure.y + targetStructure.height * 0.5;
          s.facingRad = Math.atan2(stCy - s.y, stCx - s.x);
          if (s.attackCooldown <= 0) {
            this.executeSoldierAttackOnStructure(s, stats, targetStructure, warCryActive);
          }
        }
      } else if (!autoBraceHalt && !keshigKiting) {
        // 弹簧槽位导航移动与冲锋助跑计时
        const guideX: number =
          s.squadId < this.squadTargetMapX.length ? this.squadTargetMapX[s.squadId] : sq.targetX;
        const guideY: number =
          s.squadId < this.squadTargetMapY.length ? this.squadTargetMapY[s.squadId] : sq.targetY;

        let destX: number;
        let destY: number;
        if (
          targetSoldier !== null &&
          sq.order !== TacticalOrder.HOLD_GROUND &&
          sq.order !== TacticalOrder.RETREAT &&
          sq.formation !== FormationType.CIRCLE_DEFENSE
        ) {
          destX = targetSoldier.x;
          destY = targetSoldier.y;
        } else if (
          engageHero !== null &&
          sq.order !== TacticalOrder.HOLD_GROUND &&
          sq.order !== TacticalOrder.RETREAT &&
          sq.formation !== FormationType.CIRCLE_DEFENSE
        ) {
          destX = engageHero.x;
          destY = engageHero.y;
        } else {
          const anchorDx: number = guideX - sq.centerX;
          const anchorDy: number = guideY - sq.centerY;
          const anchorDist: number = Math.sqrt(anchorDx * anchorDx + anchorDy * anchorDy);
          const stepAhead: number = Math.min(anchorDist, maxMoveSpd * 0.65);
          const virtCx: number =
            anchorDist > 2.0 ? sq.centerX + (anchorDx / anchorDist) * stepAhead : sq.centerX;
          const virtCy: number =
            anchorDist > 2.0 ? sq.centerY + (anchorDy / anchorDist) * stepAhead : sq.centerY;
          const cosF: number = Math.cos(sq.facingRad);
          const sinF: number = Math.sin(sq.facingRad);
          destX = virtCx + s.slotOffsetX * cosF - s.slotOffsetY * sinF;
          destY = virtCy + s.slotOffsetX * sinF + s.slotOffsetY * cosF;
        }

        const mDx: number = destX - s.x;
        const mDy: number = destY - s.y;
        const mDistSq: number = mDx * mDx + mDy * mDy;

        if (mDistSq > 9.0 && sq.formation !== FormationType.CIRCLE_DEFENSE) {
          const mDist: number = Math.sqrt(mDistSq);
          const orderSpdBoost: number =
            sq.order === TacticalOrder.ALL_OUT_CHARGE
              ? 1.12
              : sq.order === TacticalOrder.RETREAT
                ? 0.72
                : 1.0;
          const stepSpd: number = Math.min(maxMoveSpd * orderSpdBoost, mDist / Math.max(0.016, dtSec));
          s.vx = (mDx / mDist) * stepSpd;
          s.vy = (mDy / mDist) * stepSpd;
          s.x += s.vx * dtSec;
          s.y += s.vy * dtSec;

          if (sq.order !== TacticalOrder.RETREAT && sq.order !== TacticalOrder.FEIGNED_RETREAT) {
            s.facingRad = Math.atan2(s.vy, s.vx);
          } else {
            s.facingRad = sq.facingRad;
          }

          // 骑兵/突击兵连续高速助跑 2.5s 触发冲锋撞阵态
          if (
            stats.chargeMultiplier > 1.0 &&
            s.chargeCooldown <= 0 &&
            stepSpd >= maxMoveSpd * 0.85 &&
            canTerrainSupportCharge(curTerrain, s.category) &&
            sq.order !== TacticalOrder.RETREAT
          ) {
            s.chargeRunTime += dtSec;
            s.actionState =
              s.chargeRunTime >= CHARGE_RUN_THRESHOLD_SEC
                ? UnitActionState.CHARGE_SPRINT
                : UnitActionState.MARCH_RUN;
          } else {
            s.chargeRunTime = Math.max(0, s.chargeRunTime - dtSec * 1.5);
            s.actionState = UnitActionState.MARCH_RUN;
          }

          // 拒马反骑刺伤检测
          if (s.category === UnitCategory.CAVALRY) {
            this.checkWoodenStakesHazard(s);
          }
        } else {
          s.vx = 0;
          s.vy = 0;
          s.chargeRunTime = Math.max(0, s.chargeRunTime - dtSec * 2.0);
          if (sq.formation === FormationType.CIRCLE_DEFENSE) {
            s.facingRad = Math.atan2(s.y - sq.centerY, s.x - sq.centerX);
          } else {
            s.facingRad = sq.facingRad;
          }
          s.actionState = UnitActionState.IDLE_READY;
        }
      }

      if (s.active && s.hp > 0) {
        applyUnitSeparationAndFortCollision(
          s,
          this.soldiers,
          this.structures,
          this.spatialGrid,
          dtSec,
          this.worldWidth,
          this.worldHeight
        );
        s.animPhase = (s.animPhase + dtSec * 2.6) % 1.0;
      }
    }
  }

  private stepSapperUnit(
    s: SoldierPoolItem,
    sq: SquadRuntimeItem,
    stats: UnitStaticStats,
    dtSec: number
  ): void {
    const isPlayer: boolean = s.side === BattleSide.PLAYER;
    const ownCamp: FortStructureItem | null = isPlayer ? this.playerBaseCamp : this.enemyBaseCamp;
    if (ownCamp === null || ownCamp.isBreached) {
      return;
    }
    const campCx: number = ownCamp.x + ownCamp.width * 0.5;
    const campCy: number = ownCamp.y + ownCamp.height * 0.5;

    // 玩家开启本阵警钟：工兵暂停采集退入大营掩体（获远程减免并通过箭孔协防投射）
    if (isPlayer && this.garrisonBellActive) {
      const dxC: number = campCx - s.x;
      const dyC: number = campCy - s.y;
      const dSq: number = dxC * dxC + dyC * dyC;
      if (dSq > 42.0 * 42.0) {
        const d: number = Math.sqrt(dSq);
        s.vx = (dxC / d) * stats.moveSpeed * 1.15;
        s.vy = (dyC / d) * stats.moveSpeed * 1.15;
        s.x += s.vx * dtSec;
        s.y += s.vy * dtSec;
        s.facingRad = Math.atan2(s.vy, s.vx);
        s.actionState = UnitActionState.MARCH_RUN;
      } else {
        s.vx = 0;
        s.vy = 0;
        s.actionState = UnitActionState.SHIELD_BLOCK;
        if (s.attackCooldown <= 0) {
          const threat: SoldierPoolItem | null = this.acquireBestEnemyTarget(s, 220.0, 0);
          if (threat !== null) {
            s.attackCooldown = 1.45;
            s.facingRad = Math.atan2(threat.y - s.y, threat.x - s.x);
            this.spawnProjectile(
              s.side,
              ProjectileKind.ARROW,
              s.x,
              s.y,
              threat.x,
              threat.y,
              28.0,
              0.38,
              12.0,
              0.10,
              0,
              1,
              false,
              0
            );
          }
        }
      }
      return;
    }

    const idx: number = s.poolIndex;
    // 满载 15 单位资源时运回本阵入库
    if (this.soldierCarryAmount[idx] >= 15.0) {
      const dxC: number = campCx - s.x;
      const dyC: number = campCy - s.y;
      const dSq: number = dxC * dxC + dyC * dyC;
      if (dSq <= 95.0 * 95.0) {
        const amt: number = this.soldierCarryAmount[idx];
        const kind: number = this.soldierCarryKind[idx];
        if (kind === 1) {
          const gMult: number = s.factionId === FactionId.SHAMO ? 1.35 : 1.0;
          if (isPlayer) {
            this.playerGold += amt * gMult;
          } else {
            this.enemyGold += amt * gMult;
          }
        } else if (kind === 2) {
          if (isPlayer) {
            this.playerWood += amt;
          } else {
            this.enemyWood += amt;
          }
        } else if (kind === 3) {
          if (isPlayer) {
            this.playerGrain += amt;
            this.playerZeroGrainSec = 0;
          } else {
            this.enemyGrain += amt;
            this.enemyZeroGrainSec = 0;
          }
        }
        this.soldierCarryAmount[idx] = 0;
        this.soldierCarryKind[idx] = 0;
        this.hudDirty = true;
      } else {
        const d: number = Math.sqrt(dSq);
        s.vx = (dxC / d) * stats.moveSpeed;
        s.vy = (dyC / d) * stats.moveSpeed;
        s.x += s.vx * dtSec;
        s.y += s.vy * dtSec;
        s.facingRad = Math.atan2(s.vy, s.vx);
        s.actionState = UnitActionState.MARCH_RUN;
      }
      return;
    }

    // 寻路前往最近的己方半场野外资源点开采（缺粮时优先农庄）
    const preferGrain: boolean = isPlayer
      ? this.playerGrain < 450.0
      : this.enemyGrain < 450.0;
    let bestNode: ResourceNodeItem | null = null;
    let bestScore: number = 1e18;
    for (let n: number = 0; n < this.resourceNodes.length; n++) {
      const rn: ResourceNodeItem = this.resourceNodes[n];
      if (rn.remainingAmount <= 0) {
        continue;
      }
      const dSq: number = (rn.x - s.x) * (rn.x - s.x) + (rn.y - s.y) * (rn.y - s.y);
      const weight: number = preferGrain && rn.resourceKind === 'grain' ? 0.35 : 1.0;
      if (dSq * weight < bestScore) {
        bestScore = dSq * weight;
        bestNode = rn;
      }
    }

    if (bestNode !== null) {
      const dxN: number = bestNode.x - s.x;
      const dyN: number = bestNode.y - s.y;
      const dSq: number = dxN * dxN + dyN * dyN;
      if (dSq <= 48.0 * 48.0) {
        s.vx = 0;
        s.vy = 0;
        s.actionState = UnitActionState.MELEE_STRIKE;
        const harvest: number = Math.min(bestNode.remainingAmount, 7.5 * dtSec);
        bestNode.remainingAmount -= harvest;
        this.soldierCarryAmount[idx] += harvest;
        this.soldierCarryKind[idx] =
          bestNode.resourceKind === 'gold' ? 1 : bestNode.resourceKind === 'wood' ? 2 : 3;
      } else {
        const d: number = Math.sqrt(dSq);
        s.vx = (dxN / d) * stats.moveSpeed;
        s.vy = (dyN / d) * stats.moveSpeed;
        s.x += s.vx * dtSec;
        s.y += s.vy * dtSec;
        s.facingRad = Math.atan2(s.vy, s.vx);
        s.actionState = UnitActionState.MARCH_RUN;
      }
      sq.targetX = bestNode.x;
      sq.targetY = bestNode.y;
    }
  }

  private computeEffectiveAttackRange(
    stats: UnitStaticStats,
    factionId: FactionId,
    terrain: TerrainType,
    elevation: number
  ): number {
    if (stats.attackRange <= 60.0) {
      return stats.attackRange;
    }
    let r: number = stats.attackRange;
    if (factionId === FactionId.TIEYING) {
      r *= 1.12; // 铁鹰远程射程 +12%
    } else if (factionId === FactionId.SHUANGYUAN && stats.category === UnitCategory.RANGED) {
      r *= 0.90; // 霜原远程射程 -10%
    }
    if (terrain === TerrainType.FORT_WALL || elevation >= 2) {
      r *= 1.25; // 城头射程 +25%
    } else if (terrain === TerrainType.HIGH_GROUND || elevation >= 1) {
      r *= 1.20; // 高地射程 +20%
    }
    if (this.config.weather === WeatherType.RAIN_MUD && stats.category === UnitCategory.RANGED) {
      r *= 0.80; // 暴雨弓弦受潮射程 -20%
    }
    return r;
  }

  private acquireBestEnemyTarget(
    seeker: SoldierPoolItem,
    maxRange: number,
    minRange: number
  ): SoldierPoolItem | null {
    const isPlayer: boolean = seeker.side === BattleSide.PLAYER;
    const wantSupplyRaid: boolean =
      this.squads[seeker.squadId].order === TacticalOrder.RAID_SUPPLY;
    const candCount: number = this.spatialGrid.queryRadius(
      this.soldiers,
      seeker.x,
      seeker.y,
      maxRange,
      this.queryBufA
    );

    const minRangeSq: number = minRange * minRange;
    let best: SoldierPoolItem | null = null;
    let bestScore: number = 1e18;

    for (let i: number = 0; i < candCount; i++) {
      const c: SoldierPoolItem = this.soldiers[this.queryBufA[i]];
      if (c.side === seeker.side || !c.active || c.hp <= 0) {
        continue;
      }
      if (isPlayer && !c.visibleToPlayer) {
        continue;
      }
      if (!isPlayer && !c.visibleToEnemy) {
        continue;
      }
      const dx: number = c.x - seeker.x;
      const dy: number = c.y - seeker.y;
      const dSq: number = dx * dx + dy * dy;
      if (dSq < minRangeSq) {
        continue;
      }
      let score: number = dSq;
      if (wantSupplyRaid && c.unitType === UnitTypeId.SAPPER) {
        score *= 0.15;
      }
      if (score < bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best;
  }

  private findAttackableEnemyStructure(
    attacker: SoldierPoolItem,
    effRange: number
  ): FortStructureItem | null {
    const reach: number = Math.max(effRange, 36.0);
    for (let i: number = 0; i < this.structures.length; i++) {
      const st: FortStructureItem = this.structures[i];
      if (st.side === attacker.side || st.isBreached || st.hp <= 0) {
        continue;
      }
      const cx: number = Math.max(st.x, Math.min(st.x + st.width, attacker.x));
      const cy: number = Math.max(st.y, Math.min(st.y + st.height, attacker.y));
      const dx: number = cx - attacker.x;
      const dy: number = cy - attacker.y;
      if (dx * dx + dy * dy <= reach * reach) {
        return st;
      }
    }
    return null;
  }

  private checkWoodenStakesHazard(cav: SoldierPoolItem): void {
    for (let i: number = 0; i < this.structures.length; i++) {
      const st: FortStructureItem = this.structures[i];
      if (
        st.kind !== 'wooden_stakes' ||
        st.side === cav.side ||
        st.isBreached ||
        st.hp <= 0
      ) {
        continue;
      }
      if (
        cav.x >= st.x - 10.0 &&
        cav.x <= st.x + st.width + 10.0 &&
        cav.y >= st.y - 10.0 &&
        cav.y <= st.y + st.height + 10.0
      ) {
        const isCharging: boolean = cav.chargeRunTime >= 1.2;
        cav.hp -= isCharging ? 85.0 : 18.0;
        cav.vx = 0;
        cav.vy = 0;
        cav.chargeRunTime = 0;
        cav.chargeCooldown = BASE_CHARGE_COOLDOWN_SEC;
        cav.staggerTimer = 0.70;
        st.hp -= 45.0;
        if (st.hp <= 0) {
          st.hp = 0;
          st.isBreached = true;
        }
        if (cav.hp <= 0) {
          this.killSoldier(cav, null);
        }
        return;
      }
    }
  }

  /**
   * 士兵对敌兵执行近战劈刺或远程发射（含全部 16 兵种独有机制）
   */
  private executeSoldierAttackOnUnit(
    attacker: SoldierPoolItem,
    attackerSq: SquadRuntimeItem,
    attackerStats: UnitStaticStats,
    target: SoldierPoolItem,
    spookedByCamel: boolean,
    warCryActive: boolean
  ): void {
    this.soldierIdleCombatSec[attacker.poolIndex] = 0;

    // 计算攻击间隔（含血月狂战士损血每 10% 攻速 +6% 与主帅战吼 +15%）
    let spdFactor: number = warCryActive ? 1.15 : 1.0;
    if (attacker.unitType === UnitTypeId.XUEYUE_WARDRUM_BERSERKER && attacker.maxHp > 0) {
      const missingRatio: number = Math.max(0, 1.0 - attacker.hp / attacker.maxHp);
      const stacks: number = Math.floor(missingRatio * 10.0);
      spdFactor += stacks * 0.06;
    }
    attacker.attackCooldown = attackerStats.attackIntervalSec / spdFactor;

    const isRangedWeapon: boolean = attackerStats.attackRange > 60.0;
    if (isRangedWeapon) {
      attacker.actionState = UnitActionState.RANGED_DRAW_FIRE;
      attacker.animPhase = 0;

      // 雾林影袭神射破隐首箭：180% 暴击 + 3s 神经毒减速
      let critMult: number = 1.0;
      let applyPoison: boolean = false;
      if (attacker.unitType === UnitTypeId.WULIN_SHADOW_SNIPER && attacker.isStealthed) {
        critMult = 1.80;
        applyPoison = true;
      }
      attacker.isStealthed = false;

      const rationStage: BattlefieldRationStage =
        attacker.side === BattleSide.PLAYER ? this.playerRationStage : this.enemyRationStage;
      const rationMult: number =
        rationStage === BattlefieldRationStage.STARVING ? 0.75 : 1.0;
      const moraleMult: number = computeMoraleAttackMultiplier(attackerSq.morale);

      sampleTerrainAtPoint(
        attacker.x,
        attacker.y,
        this.terrainZones,
        this.config.terrain,
        this.terrainSampleA
      );
      let envMult: number = 1.0;
      if (
        attacker.factionId === FactionId.TIEYING &&
        this.terrainSampleA.elevation >= 1
      ) {
        envMult *= 1.15;
      }
      if (
        attacker.factionId === FactionId.XUEYUE &&
        this.config.weather === WeatherType.NIGHT
      ) {
        envMult *= 1.15;
      }

      const projDmg: number =
        attackerStats.attack * moraleMult * rationMult * envMult * critMult;

      let kind: ProjectileKind = ProjectileKind.ARROW;
      let arcH: number = 42.0;
      let splashR: number = 0;
      let pierce: number = 1;
      let moraleShock: number = 0;
      let speedPx: number = 460.0;

      if (attacker.unitType === UnitTypeId.TIEYING_PAVISE_CROSSBOW) {
        kind = ProjectileKind.CROSSBOW_BOLT;
        arcH = 8.0;
        speedPx = 560.0;
      } else if (attacker.unitType === UnitTypeId.BALLISTA) {
        kind = ProjectileKind.BALLISTA_SPEAR;
        arcH = 4.0;
        pierce = 3; // 连弩车直线贯穿 3 人
        speedPx = 640.0;
      } else if (attacker.unitType === UnitTypeId.TREBUCHET) {
        kind = ProjectileKind.TREBUCHET_BOULDER;
        arcH = 145.0;
        splashR = 82.0;
        moraleShock = 10.0;
        speedPx = 310.0;
      }

      const dx0: number = target.x - attacker.x;
      const dy0: number = target.y - attacker.y;
      const dist0: number = Math.max(20.0, Math.sqrt(dx0 * dx0 + dy0 * dy0));
      const estDur: number = dist0 / speedPx;
      // 弹道提前量预判（使弓弩与投石能真实命中行军与迂回移动目标）
      const leadScale: number = splashR > 0 ? 0.65 : 0.80;
      const aimX: number = target.x + target.vx * estDur * leadScale;
      const aimY: number = target.y + target.vy * estDur * leadScale;
      const dx: number = aimX - attacker.x;
      const dy: number = aimY - attacker.y;
      const dist: number = Math.max(20.0, Math.sqrt(dx * dx + dy * dy));
      const dur: number = dist / speedPx;

      this.spawnProjectile(
        attacker.side,
        kind,
        attacker.x,
        attacker.y,
        aimX,
        aimY,
        arcH,
        dur,
        projDmg,
        attackerStats.armorPenetration,
        splashR,
        pierce,
        applyPoison,
        moraleShock
      );
      return;
    }

    // ==================== 近战劈砍 / 突刺 / 骑兵撞阵 / 架枪反制 ====================
    attacker.actionState = UnitActionState.MELEE_STRIKE;
    attacker.animPhase = 0;
    attacker.isStealthed = false;

    const targetSq: SquadRuntimeItem = this.squads[target.squadId];
    const targetStats: UnitStaticStats = fastUnitStats(target.unitType);

    // 检测正面架枪长枪兵 / 神机重卫反制冲锋骑兵：长枪反刺优先停马破冲锋！
    const attackerCharging: boolean =
      attacker.chargeRunTime >= CHARGE_RUN_THRESHOLD_SEC && attacker.chargeCooldown <= 0;

    const targetIncomingDeg: number = computeAttackIncomingAngleDeg(
      target.facingRad,
      target.x,
      target.y,
      attacker.x,
      attacker.y
    );
    const targetCircleActive: boolean =
      targetSq.formation === FormationType.CIRCLE_DEFENSE &&
      targetSq.bannerLostPenaltyTimer <= 0 &&
      !targetSq.isRouting;

    if (
      attacker.category === UnitCategory.CAVALRY &&
      attackerCharging &&
      isBracedAntiCavalryTriggered(
        target.unitType,
        target.actionState,
        Math.sqrt(target.vx * target.vx + target.vy * target.vy),
        targetStats.moveSpeed,
        targetSq.isRouting,
        targetIncomingDeg,
        targetCircleActive,
        true
      )
    ) {
      // 骑兵一头撞上正面架枪方阵：先承受 320%/220% 反骑 + 30% 动能破甲穿刺并强制停马清零冲锋！
      attacker.chargeRunTime = 0;
      attacker.chargeCooldown = BASE_CHARGE_COOLDOWN_SEC;
      attacker.vx = 0;
      attacker.vy = 0;
      attacker.staggerTimer = 0.85;
      attacker.actionState = UnitActionState.STAGGER_HIT;
      this.resolveDirectMeleeHit(
        target,
        targetSq,
        targetStats,
        attacker,
        attackerSq,
        attackerStats,
        false,
        true,
        false
      );
      if (!attacker.active || attacker.hp <= 0) {
        return;
      }
    }

    // 攻击方自身是否为架枪迎击冲锋态敌骑
    const targetCavCharging: boolean =
      target.category === UnitCategory.CAVALRY &&
      (target.chargeRunTime >= 0.8 ||
        target.actionState === UnitActionState.CHARGE_SPRINT ||
        target.vx * target.vx + target.vy * target.vy >= 65.0 * 65.0);
    const attackerCircleActive: boolean =
      attackerSq.formation === FormationType.CIRCLE_DEFENSE &&
      attackerSq.bannerLostPenaltyTimer <= 0 &&
      !attackerSq.isRouting;
    const attackerToTargetDeg: number = computeAttackIncomingAngleDeg(
      attacker.facingRad,
      attacker.x,
      attacker.y,
      target.x,
      target.y
    );
    const bracedCounterTriggered: boolean = isBracedAntiCavalryTriggered(
      attacker.unitType,
      UnitActionState.IDLE_READY,
      Math.sqrt(attacker.vx * attacker.vx + attacker.vy * attacker.vy),
      attackerStats.moveSpeed,
      attackerSq.isRouting,
      attackerToTargetDeg,
      attackerCircleActive,
      targetCavCharging
    );

    if (bracedCounterTriggered) {
      target.vx = 0;
      target.vy = 0;
      target.chargeRunTime = 0;
      target.chargeCooldown = Math.max(target.chargeCooldown, BASE_CHARGE_COOLDOWN_SEC);
      target.staggerTimer = Math.max(target.staggerTimer, 0.85);
      target.actionState = UnitActionState.STAGGER_HIT;
    }

    const useChargeHit: boolean =
      attackerCharging &&
      attacker.chargeRunTime >= CHARGE_RUN_THRESHOLD_SEC &&
      attackerStats.chargeMultiplier > 1.0;

    if (useChargeHit) {
      attacker.chargeRunTime = 0;
      const attackerRation: BattlefieldRationStage =
        attacker.side === BattleSide.PLAYER ? this.playerRationStage : this.enemyRationStage;
      const cdMult: number =
        attacker.category === UnitCategory.CAVALRY &&
        (attackerRation === BattlefieldRationStage.HUNGRY ||
          attackerRation === BattlefieldRationStage.STARVING)
          ? 1.50
          : 1.0;
      attacker.chargeCooldown = BASE_CHARGE_COOLDOWN_SEC * cdMult;
    }

    const dealtDmg: number = this.resolveDirectMeleeHit(
      attacker,
      attackerSq,
      attackerStats,
      target,
      targetSq,
      targetStats,
      useChargeHit,
      bracedCounterTriggered,
      spookedByCamel
    );

    // 血月狂战祭团近战吸血（22%）
    if (attacker.unitType === UnitTypeId.XUEYUE_WARDRUM_BERSERKER && dealtDmg > 0) {
      attacker.hp = Math.min(attacker.maxHp, attacker.hp + dealtDmg * 0.22);
    }

    // 霜原巨熊破阵者：扇形重锤震飞前排（主目标及 110° 扇区敌兵一并震飞击退）
    if (attacker.unitType === UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
      if (
        target.active &&
        target.hp > 0 &&
        target.unitType !== UnitTypeId.SHUANGYUAN_GIANT_BREAKER
      ) {
        const pRad0: number = Math.atan2(target.y - attacker.y, target.x - attacker.x);
        target.x += Math.cos(pRad0) * 28.0;
        target.y += Math.sin(pRad0) * 28.0;
        target.staggerTimer = Math.max(target.staggerTimer, 0.65);
        target.actionState = UnitActionState.STAGGER_HIT;
      }
      this.applyMeleeSectorCleave(attacker, attackerSq, attackerStats, target, 44.0, 55.0, 0.65, 28.0, 0.65, 3);
    } else if (attacker.unitType === UnitTypeId.GREAT_AXEMAN) {
      // 重型巨斧兵：半圆破甲横扫溅射
      this.applyMeleeSectorCleave(attacker, attackerSq, attackerStats, target, 34.0, 60.0, 0.50, 8.0, 0.20, 2);
    } else if (attacker.unitType === UnitTypeId.XUANJIA_CATAPHRACT && useChargeHit) {
      // 玄甲具装铁浮图：冲锋凿穿首层薄弱步兵直踏后排
      this.applyMeleeSectorCleave(attacker, attackerSq, attackerStats, target, 32.0, 75.0, 0.55, 20.0, 0.45, 2);
      attacker.x += Math.cos(attacker.facingRad) * 22.0;
      attacker.y += Math.sin(attacker.facingRad) * 22.0;
    }
  }

  private resolveDirectMeleeHit(
    attacker: SoldierPoolItem,
    attackerSq: SquadRuntimeItem,
    attackerStats: UnitStaticStats,
    target: SoldierPoolItem,
    targetSq: SquadRuntimeItem,
    targetStats: UnitStaticStats,
    isChargeStrike: boolean,
    isBracedAntiCav: boolean,
    spookedByCamel: boolean
  ): number {
    this.soldierIdleCombatSec[target.poolIndex] = 0;
    target.isStealthed = false;

    sampleTerrainAtPoint(
      attacker.x,
      attacker.y,
      this.terrainZones,
      this.config.terrain,
      this.terrainSampleA
    );
    sampleTerrainAtPoint(
      target.x,
      target.y,
      this.terrainZones,
      this.config.terrain,
      this.terrainSampleB
    );

    // 计算受击目标总有效基础护甲（含势力、阵型、涉水、动摇修正）
    const effTargetArmor: number = this.computeTargetModifiedArmor(
      target,
      targetSq,
      targetStats,
      this.terrainSampleB.terrain
    );

    const incomingDeg: number = computeAttackIncomingAngleDeg(
      target.facingRad,
      target.x,
      target.y,
      attacker.x,
      attacker.y
    );
    const isCircle: boolean =
      targetSq.formation === FormationType.CIRCLE_DEFENSE &&
      targetSq.bannerLostPenaltyTimer <= 0 &&
      !targetSq.isRouting;
    const isBridge: boolean = this.terrainSampleB.terrain === TerrainType.BRIDGE_PASS;

    let chargeMult: number = 1.0;
    if (isChargeStrike) {
      chargeMult = attackerStats.chargeMultiplier;
      if (
        attackerSq.formation === FormationType.WEDGE_CHARGE &&
        attackerSq.bannerLostPenaltyTimer <= 0
      ) {
        chargeMult *= 1.25;
      }
      if (attacker.factionId === FactionId.XUANJIA && attacker.category === UnitCategory.CAVALRY) {
        chargeMult *= 1.30;
      }
      if (this.terrainSampleA.elevation > this.terrainSampleB.elevation) {
        chargeMult *= 1.15;
      }
      if (spookedByCamel && attacker.category === UnitCategory.CAVALRY) {
        chargeMult *= 0.75; // 马穆鲁克惊马光环降低 25% 冲锋伤害
      }
    }

    let antiCavMult: number = 1.0;
    let bonusPen: number = 0;
    if (target.category === UnitCategory.CAVALRY) {
      if (isBracedAntiCav) {
        antiCavMult = attackerStats.antiCavalryMultiplier;
        bonusPen = GameConstants.BRACED_ANTICAV_BONUS_PEN; // +30% 动能破甲
      } else if (attackerStats.antiCavalryMultiplier > 1.0 && attackerStats.antiCavalryMultiplier < 2.0) {
        antiCavMult = attackerStats.antiCavalryMultiplier;
      } else if (attacker.unitType === UnitTypeId.PIKEMAN || attacker.unitType === UnitTypeId.YANLONG_HALBERD_GRENADIER) {
        antiCavMult = 1.50;
      }
    }

    let terrainMult: number = 1.0;
    if (this.terrainSampleA.elevation > this.terrainSampleB.elevation) {
      terrainMult *= 1.12; // 居高近战 +12%
    }
    if (attacker.factionId === FactionId.TIEYING && this.terrainSampleA.elevation >= 1) {
      terrainMult *= 1.15;
    }
    if (
      attacker.factionId === FactionId.SHUANGYUAN &&
      (this.terrainSampleA.terrain === TerrainType.SNOWFIELD ||
        this.config.weather === WeatherType.BLIZZARD)
    ) {
      terrainMult *= 1.10;
    }
    if (attacker.factionId === FactionId.XUEYUE && this.config.weather === WeatherType.NIGHT) {
      terrainMult *= 1.15;
    }

    const attackerRation: BattlefieldRationStage =
      attacker.side === BattleSide.PLAYER ? this.playerRationStage : this.enemyRationStage;
    const rationMult: number = attackerRation === BattlefieldRationStage.STARVING ? 0.75 : 1.0;

    // 渡河“半渡而击”（30% ~ 80% 成员涉水时受击 +20% 易伤 + 一次性 -12 士气震慑）
    const halfFordMult: number = this.checkAndTriggerHalfFordVulnerability(targetSq);

    this.dmgParams.reset();
    this.dmgParams.baseAttack = attackerStats.attack;
    this.dmgParams.targetArmor = effTargetArmor;
    this.dmgParams.attackerArmorPen = attackerStats.armorPenetration;
    this.dmgParams.bonusArmorPen = bonusPen;
    this.dmgParams.shieldRangedBlock = 0;
    this.dmgParams.isRanged = false;
    this.dmgParams.incomingAngleDeg = incomingDeg;
    this.dmgParams.isCircleDefense = isCircle;
    this.dmgParams.isBridgePass = isBridge;
    this.dmgParams.isTargetRouting = targetSq.isRouting;
    this.dmgParams.chargeMult = chargeMult;
    this.dmgParams.antiCavMult = antiCavMult;
    this.dmgParams.terrainMult = terrainMult;
    this.dmgParams.moraleMult = computeMoraleAttackMultiplier(attackerSq.morale);
    this.dmgParams.rationMult = rationMult;
    this.dmgParams.halfFordMult = halfFordMult;

    const finalDmg: number = computeFinalHitDamage(this.dmgParams);
    target.hp -= finalDmg;

    // 冲锋撞击击退（霜原巨熊免疫普通击退，方阵抗击退 +50%）
    if (isChargeStrike && target.unitType !== UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
      const phalanxResist: number =
        targetSq.formation === FormationType.PHALANX_RECT && targetSq.bannerLostPenaltyTimer <= 0
          ? 0.50
          : 1.0;
      const pushDist: number = 18.0 * phalanxResist;
      const pushRad: number = Math.atan2(target.y - attacker.y, target.x - attacker.x);
      target.x += Math.cos(pushRad) * pushDist;
      target.y += Math.sin(pushRad) * pushDist;
      target.staggerTimer = Math.max(target.staggerTimer, 0.35 * phalanxResist);
    }

    // 侧翼（1.5x）与背击（2.0x）单次受击士气打击
    computeDirectionalModifiers(incomingDeg, isCircle, isBridge, this.dirModScratch);
    this.applyHitMoraleShockToSquad(
      targetSq,
      (finalDmg / Math.max(40.0, target.maxHp)) * 2.4 * this.dirModScratch.moraleShockMult
    );

    if (target.hp <= 0) {
      this.killSoldier(target, attacker);
    }
    return finalDmg;
  }

  private applyMeleeSectorCleave(
    attacker: SoldierPoolItem,
    attackerSq: SquadRuntimeItem,
    attackerStats: UnitStaticStats,
    primaryTarget: SoldierPoolItem,
    radius: number,
    halfArcDeg: number,
    dmgScale: number,
    knockbackPx: number,
    staggerSec: number,
    maxExtraTargets: number
  ): void {
    const candCount: number = this.spatialGrid.queryRadius(
      this.soldiers,
      attacker.x,
      attacker.y,
      radius,
      this.queryBufB
    );
    let extraHits: number = 0;
    for (let i: number = 0; i < candCount && extraHits < maxExtraTargets; i++) {
      const other: SoldierPoolItem = this.soldiers[this.queryBufB[i]];
      if (
        other.poolIndex === primaryTarget.poolIndex ||
        other.side === attacker.side ||
        !other.active ||
        other.hp <= 0
      ) {
        continue;
      }
      const deg: number = computeAttackIncomingAngleDeg(
        attacker.facingRad,
        attacker.x,
        attacker.y,
        other.x,
        other.y
      );
      if (deg <= halfArcDeg) {
        const oStats: UnitStaticStats = fastUnitStats(other.unitType);
        const oSq: SquadRuntimeItem = this.squads[other.squadId];
        sampleTerrainAtPoint(other.x, other.y, this.terrainZones, this.config.terrain, this.terrainSampleB);
        const oArmor: number = this.computeTargetModifiedArmor(
          other,
          oSq,
          oStats,
          this.terrainSampleB.terrain
        );
        this.dmgParams.reset();
        this.dmgParams.baseAttack = attackerStats.attack * dmgScale;
        this.dmgParams.targetArmor = oArmor;
        this.dmgParams.attackerArmorPen = attackerStats.armorPenetration;
        const splashDmg: number = computeFinalHitDamage(this.dmgParams);
        other.hp -= splashDmg;

        if (knockbackPx > 0 && other.unitType !== UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
          const pRad: number = Math.atan2(other.y - attacker.y, other.x - attacker.x);
          other.x += Math.cos(pRad) * knockbackPx;
          other.y += Math.sin(pRad) * knockbackPx;
          other.staggerTimer = Math.max(other.staggerTimer, staggerSec);
          other.actionState = UnitActionState.STAGGER_HIT;
        }
        if (other.hp <= 0) {
          this.killSoldier(other, attacker);
        }
        extraHits++;
      }
    }
  }

  private executeSoldierAttackOnStructure(
    attacker: SoldierPoolItem,
    stats: UnitStaticStats,
    st: FortStructureItem,
    warCryActive: boolean
  ): void {
    attacker.attackCooldown = stats.attackIntervalSec / (warCryActive ? 1.15 : 1.0);
    this.soldierIdleCombatSec[attacker.poolIndex] = 0;

    if (stats.attackRange > 60.0) {
      attacker.actionState = UnitActionState.RANGED_DRAW_FIRE;
      const cx: number = st.x + st.width * 0.5;
      const cy: number = st.y + st.height * 0.5;
      const kind: ProjectileKind =
        attacker.unitType === UnitTypeId.TREBUCHET
          ? ProjectileKind.TREBUCHET_BOULDER
          : attacker.unitType === UnitTypeId.BALLISTA
            ? ProjectileKind.BALLISTA_SPEAR
            : ProjectileKind.ARROW;
      this.spawnProjectile(
        attacker.side,
        kind,
        attacker.x,
        attacker.y,
        cx,
        cy,
        kind === ProjectileKind.TREBUCHET_BOULDER ? 140.0 : 20.0,
        0.75,
        stats.attack,
        stats.armorPenetration,
        kind === ProjectileKind.TREBUCHET_BOULDER ? 75.0 : 0,
        1,
        false,
        0
      );
      return;
    }

    attacker.actionState = UnitActionState.MELEE_STRIKE;
    let structMult: number = 0.65;
    if (attacker.unitType === UnitTypeId.GREAT_AXEMAN && st.kind === 'gate') {
      structMult = 1.85; // 巨斧劈木城门特效加成
    } else if (attacker.unitType === UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
      structMult = 1.65;
    }
    if (attacker.factionId === FactionId.YANLONG && stats.category === UnitCategory.SIEGE) {
      structMult *= 1.25;
    }

    st.hp -= Math.max(3.0, stats.attack * structMult);
    // 突袭敌方本阵大营触发劫掠随军粮车（当场夺取 150 应急粮翻盘！）
    if (st.kind === 'base_camp') {
      this.triggerSupplyCampRaid(attacker.side);
    }
    if (st.hp <= 0) {
      st.hp = 0;
      st.isBreached = true;
      this.spawnHitEffect(st.x + st.width * 0.5, st.y + st.height * 0.5, 'boulder_crater', 0);
    }
  }

  private executeSoldierAttackOnHero(
    attacker: SoldierPoolItem,
    attackerSq: SquadRuntimeItem,
    attackerStats: UnitStaticStats,
    targetHero: CommanderHeroItem,
    warCryActive: boolean
  ): void {
    this.soldierIdleCombatSec[attacker.poolIndex] = 0;
    let spdFactor: number = warCryActive ? 1.15 : 1.0;
    if (attacker.unitType === UnitTypeId.XUEYUE_WARDRUM_BERSERKER && attacker.maxHp > 0) {
      const missingRatio: number = Math.max(0, 1.0 - attacker.hp / attacker.maxHp);
      spdFactor += Math.floor(missingRatio * 10.0) * 0.06;
    }
    attacker.attackCooldown = attackerStats.attackIntervalSec / spdFactor;
    attacker.isStealthed = false;

    const attackerRation: BattlefieldRationStage =
      attacker.side === BattleSide.PLAYER ? this.playerRationStage : this.enemyRationStage;
    const rationMult: number = attackerRation === BattlefieldRationStage.STARVING ? 0.75 : 1.0;
    const moraleMult: number = computeMoraleAttackMultiplier(attackerSq.morale);

    if (attackerStats.attackRange > 60.0) {
      attacker.actionState = UnitActionState.RANGED_DRAW_FIRE;
      attacker.animPhase = 0;
      const speedPx: number = attacker.unitType === UnitTypeId.TIEYING_PAVISE_CROSSBOW ? 560.0 : 460.0;
      const kind: ProjectileKind =
        attacker.unitType === UnitTypeId.TIEYING_PAVISE_CROSSBOW
          ? ProjectileKind.CROSSBOW_BOLT
          : attacker.unitType === UnitTypeId.TREBUCHET
            ? ProjectileKind.TREBUCHET_BOULDER
            : attacker.unitType === UnitTypeId.BALLISTA
              ? ProjectileKind.BALLISTA_SPEAR
              : ProjectileKind.ARROW;
      const dx: number = targetHero.x - attacker.x;
      const dy: number = targetHero.y - attacker.y;
      const dist: number = Math.max(20.0, Math.sqrt(dx * dx + dy * dy));
      this.spawnProjectile(
        attacker.side,
        kind,
        attacker.x,
        attacker.y,
        targetHero.x,
        targetHero.y,
        kind === ProjectileKind.TREBUCHET_BOULDER ? 140.0 : 32.0,
        dist / speedPx,
        attackerStats.attack * moraleMult * rationMult,
        attackerStats.armorPenetration,
        kind === ProjectileKind.TREBUCHET_BOULDER ? 75.0 : 0,
        1,
        false,
        0
      );
      return;
    }

    attacker.actionState = UnitActionState.MELEE_STRIKE;
    attacker.animPhase = 0;
    let chargeMult: number = 1.0;
    if (
      attacker.chargeRunTime >= CHARGE_RUN_THRESHOLD_SEC &&
      attacker.chargeCooldown <= 0 &&
      attackerStats.chargeMultiplier > 1.0
    ) {
      chargeMult = attackerStats.chargeMultiplier;
      attacker.chargeRunTime = 0;
      attacker.chargeCooldown = BASE_CHARGE_COOLDOWN_SEC;
    }

    const rawAttack: number = attackerStats.attack * chargeMult * moraleMult * rationMult;
    this.heroEvents.reset();
    const fSquads: SquadRuntimeItem[] =
      targetHero.side === BattleSide.PLAYER ? this.playerSquads : this.enemySquads;
    const eSquads: SquadRuntimeItem[] =
      targetHero.side === BattleSide.PLAYER ? this.enemySquads : this.playerSquads;
    const fCamp: FortStructureItem | null =
      targetHero.side === BattleSide.PLAYER ? this.playerBaseCamp : this.enemyBaseCamp;
    const fInit: number =
      targetHero.side === BattleSide.PLAYER ? this.playerInitialTotal : this.enemyInitialTotal;
    const dealt: number = applyDamageToHero(
      targetHero,
      rawAttack,
      attackerStats.armorPenetration,
      attacker.x,
      attacker.y,
      false,
      attacker,
      fSquads,
      eSquads,
      fCamp,
      this.countNonRoutingSoldiers(targetHero.side),
      fInit,
      this.heroEvents
    );
    if (attacker.unitType === UnitTypeId.XUEYUE_WARDRUM_BERSERKER && dealt > 0) {
      attacker.hp = Math.min(attacker.maxHp, attacker.hp + dealt * 0.22);
    }
    this.consumeHeroEvents(targetHero.side, this.heroEvents);
  }

  private computeTargetModifiedArmor(
    target: SoldierPoolItem,
    targetSq: SquadRuntimeItem,
    targetStats: UnitStaticStats,
    terrain: TerrainType
  ): number {
    let armor: number = targetStats.armor;

    // 势力护甲加成（炎龙步兵+15%，玄甲骑兵+25%）
    if (
      target.factionId === FactionId.YANLONG &&
      (target.category === UnitCategory.INFANTRY || target.category === UnitCategory.POLEARM)
    ) {
      armor *= 1.15;
    } else if (target.factionId === FactionId.XUANJIA && target.category === UnitCategory.CAVALRY) {
      armor *= 1.25;
    }

    // 阵型护甲修正（钳形夹击 PINCERED / 铁桶合围 ENCIRCLED / 斩旗 12s 内失去方阵护甲！）
    const formationActive: boolean = !targetSq.isRouting && targetSq.bannerLostPenaltyTimer <= 0;
    if (formationActive) {
      if (
        targetSq.formation === FormationType.PHALANX_RECT &&
        targetSq.encirclement !== EncirclementState.PINCERED &&
        targetSq.encirclement !== EncirclementState.ENCIRCLED
      ) {
        const phalanxBonus: number = terrain === TerrainType.DENSE_FOREST ? 0.10 : 0.20;
        armor *= 1.0 + phalanxBonus;
      } else if (targetSq.formation === FormationType.WEDGE_CHARGE) {
        armor *= 0.90;
      }
    }

    // 河流浅滩涉水护甲有效率 -15%
    if (terrain === TerrainType.RIVER_FORD) {
      armor *= 0.85;
    }

    // 士气动摇 (<40) 护甲有效率 -15%
    armor *= computeMoraleArmorMultiplier(targetSq.morale);
    return armor;
  }

  private checkAndTriggerHalfFordVulnerability(targetSq: SquadRuntimeItem): number {
    if (targetSq.fordRatio >= 0.30 && targetSq.fordRatio <= 0.80) {
      if (!targetSq.halfFordShockApplied) {
        targetSq.halfFordShockApplied = true;
        const heroDown: boolean =
          targetSq.side === BattleSide.PLAYER
            ? this.playerHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP
            : this.enemyHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP;
        // 水陆首尾脱节遭遇半渡而击，直接承受全额 -12 士气震慑
        const newlyRouted: boolean = applySquadMoraleAndHysteresis(
          targetSq,
          -12.0,
          heroDown,
          false
        );
        if (newlyRouted) {
          this.onSquadBrokeIntoRout(targetSq);
        }
      }
      return GameConstants.HALF_FORD_VULNERABILITY_MULT; // 1.20x 易伤
    }
    return 1.0;
  }

  private applyHitMoraleShockToSquad(sq: SquadRuntimeItem, shockAmount: number): void {
    if (sq.squadId < this.squadUnderFireSec.length) {
      this.squadUnderFireSec[sq.squadId] = 4.0;
    }
    if (shockAmount <= 0 || sq.aliveCount <= 0) {
      return;
    }
    let adjusted: number = shockAmount;
    if (
      sq.formation === FormationType.PHALANX_RECT &&
      sq.bannerLostPenaltyTimer <= 0 &&
      sq.encirclement !== EncirclementState.PINCERED &&
      sq.encirclement !== EncirclementState.ENCIRCLED
    ) {
      adjusted *= 0.75; // 方阵士气流失减缓 25%
    }
    const heroDown: boolean =
      sq.side === BattleSide.PLAYER
        ? this.playerHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP
        : this.enemyHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP;

    const newlyRouted: boolean = applySquadMoraleAndHysteresis(sq, -adjusted, heroDown, false);
    if (newlyRouted) {
      this.onSquadBrokeIntoRout(sq);
    }
  }

  private killSoldier(victim: SoldierPoolItem, killer: SoldierPoolItem | null): void {
    victim.active = false;
    victim.hp = 0;
    victim.actionState = UnitActionState.FALLEN_CORPSE;

    const sq: SquadRuntimeItem = this.squads[victim.squadId];
    if (sq.aliveCount > 0) {
      sq.aliveCount--;
    }

    // 留存战场遗骸与折断旌旗（150 环形覆盖池）
    this.spawnCorpseDecal(victim.x, victim.y, victim.facingRad, victim.factionId, victim.isBannerBearer);

    // 执旗官阵亡：令所属军团立刻 -15 士气且 12s 丧失阵型加成！
    if (victim.isBannerBearer) {
      sq.bannerAlive = false;
      sq.bannerLostPenaltyTimer = 12.0;
      const heroDown: boolean =
        sq.side === BattleSide.PLAYER
          ? this.playerHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP
          : this.enemyHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP;
      const broke: boolean = applySquadMoraleAndHysteresis(sq, -15.0, heroDown, false);
      if (broke) {
        this.onSquadBrokeIntoRout(sq);
      }
    } else {
      // 普通伤亡对本队士气微冲击
      const lossShock: number = 22.0 / Math.max(6.0, sq.initialCount);
      this.applyHitMoraleShockToSquad(sq, lossShock);
    }

    // 血月祭司团特性：敌我伤亡充能【血月狂热】赋予全军移速 +20%
    if (this.config.playerFaction === FactionId.XUEYUE) {
      this.playerBloodFrenzySec = Math.min(12.0, this.playerBloodFrenzySec + 1.2);
    }
    if (this.config.enemyFaction === FactionId.XUEYUE) {
      this.enemyBloodFrenzySec = Math.min(12.0, this.enemyBloodFrenzySec + 1.2);
    }

    if (killer !== null && killer.factionId === FactionId.CANGLANG && sq.aliveCount === 0) {
      // 苍狼游牧以战养战微补给
      if (killer.side === BattleSide.PLAYER) {
        this.playerGrain += 10.0;
      } else {
        this.enemyGrain += 10.0;
      }
    }
    this.hudDirty = true;
  }

  // ==================== 箭塔自动射击与飞行投射物池步进 ====================

  private stepFortStructuresDefense(dtSec: number): void {
    for (let i: number = 0; i < this.structures.length; i++) {
      const st: FortStructureItem = this.structures[i];
      if (st.kind !== 'arrow_tower' || st.isBreached || st.hp <= 0) {
        continue;
      }
      if (st.attackTimer > 0) {
        st.attackTimer -= dtSec;
        continue;
      }
      const cx: number = st.x + st.width * 0.5;
      const cy: number = st.y + st.height * 0.5;
      const count: number = this.spatialGrid.queryRadius(
        this.soldiers,
        cx,
        cy,
        460.0,
        this.queryBufA
      );
      for (let k: number = 0; k < count; k++) {
        const s: SoldierPoolItem = this.soldiers[this.queryBufA[k]];
        if (s.side !== st.side && s.active && s.hp > 0) {
          st.attackTimer = 1.40;
          this.spawnProjectile(
            st.side,
            ProjectileKind.CROSSBOW_BOLT,
            cx,
            cy,
            s.x,
            s.y,
            18.0,
            0.60,
            32.0,
            0.40,
            0,
            1,
            false,
            0
          );
          break;
        }
      }
    }
  }

  private spawnProjectile(
    side: BattleSide,
    kind: ProjectileKind,
    startX: number,
    startY: number,
    destX: number,
    destY: number,
    arcHeight: number,
    durationSec: number,
    damage: number,
    armorPen: number,
    splashRadius: number,
    pierceRemaining: number,
    applyPoison: boolean,
    moraleShock: number
  ): void {
    for (let i: number = 0; i < this.projectiles.length; i++) {
      const p: ProjectilePoolItem = this.projectiles[i];
      if (!p.active) {
        const safeDur: number = Math.max(0.08, durationSec);
        p.active = true;
        p.side = side;
        p.kind = kind;
        p.startX = startX;
        p.startY = startY;
        p.x = startX;
        p.y = startY;
        p.vx = (destX - startX) / safeDur;
        p.vy = (destY - startY) / safeDur;
        p.arcHeight = arcHeight;
        p.flightProgress = 0;
        p.flightDuration = safeDur;
        p.damage = damage;
        p.armorPenetration = armorPen;
        p.splashRadius = splashRadius;
        p.pierceRemaining = pierceRemaining;
        p.applyPoison = applyPoison;
        p.moraleShock = moraleShock;
        this.projLastHitSoldier[i] = -1;
        return;
      }
    }
  }

  private stepAllProjectiles(dtSec: number): void {
    for (let i: number = 0; i < this.projectiles.length; i++) {
      const p: ProjectilePoolItem = this.projectiles[i];
      if (!p.active) {
        continue;
      }

      p.x += p.vx * dtSec;
      p.y += p.vy * dtSec;
      p.flightProgress += dtSec / Math.max(0.05, p.flightDuration);

      // 检查是否被开启【铁壁横戈】的敌方主帅格挡反弹！
      const opposingHero: CommanderHeroEntity =
        p.side === BattleSide.PLAYER ? this.enemyHero : this.playerHero;
      if (
        opposingHero.hp > 0 &&
        (opposingHero.vitalState === HeroVitalState.HEALTHY_ACTIVE ||
          opposingHero.vitalState === HeroVitalState.WOUNDED_WEAKENED)
      ) {
        const hdx: number = p.x - opposingHero.x;
        const hdy: number = p.y - opposingHero.y;
        if (hdx * hdx + hdy * hdy <= 22.0 * 22.0) {
          if (opposingHero.ironBulwarkTimer > 0 && p.splashRadius <= 0) {
            // 铁壁横戈反弹正面箭矢！
            p.side = opposingHero.side;
            p.vx = -p.vx;
            p.vy = -p.vy;
            p.flightProgress = 0.1;
            this.spawnHitEffect(opposingHero.x, opposingHero.y, 'shield_spark', opposingHero.facingRad);
            continue;
          } else if (p.splashRadius <= 0) {
            this.heroEvents.reset();
            const fSquads: SquadRuntimeItem[] =
              opposingHero.side === BattleSide.PLAYER ? this.playerSquads : this.enemySquads;
            const eSquads: SquadRuntimeItem[] =
              opposingHero.side === BattleSide.PLAYER ? this.enemySquads : this.playerSquads;
            const fCamp: FortStructureItem | null =
              opposingHero.side === BattleSide.PLAYER ? this.playerBaseCamp : this.enemyBaseCamp;
            const fInit: number =
              opposingHero.side === BattleSide.PLAYER
                ? this.playerInitialTotal
                : this.enemyInitialTotal;
            applyDamageToHero(
              opposingHero,
              p.damage,
              p.armorPenetration,
              p.x - p.vx * 0.1,
              p.y - p.vy * 0.1,
              true,
              null,
              fSquads,
              eSquads,
              fCamp,
              this.countNonRoutingSoldiers(opposingHero.side),
              fInit,
              this.heroEvents
            );
            this.consumeHeroEvents(opposingHero.side, this.heroEvents);
            p.active = false;
            continue;
          }
        }
      }

      // 平射贯穿型投射物实时沿途碰撞，以及曲射箭矢末段下降期（>=0.82）穿躯干碰撞检测
      const isFlatPiercing: boolean = p.splashRadius <= 0 && p.arcHeight <= 16.0;
      const isTerminalArrowDescent: boolean =
        p.splashRadius <= 0 && p.arcHeight > 16.0 && p.flightProgress >= 0.82;
      if ((isFlatPiercing || isTerminalArrowDescent) && p.flightProgress < 1.0) {
        const hitCount: number = this.spatialGrid.queryRadius(
          this.soldiers,
          p.x,
          p.y,
          18.0,
          this.queryBufA
        );
        for (let k: number = 0; k < hitCount; k++) {
          const sIdx: number = this.queryBufA[k];
          if (sIdx === this.projLastHitSoldier[i]) {
            continue;
          }
          const target: SoldierPoolItem = this.soldiers[sIdx];
          if (target.side === p.side || !target.active || target.hp <= 0) {
            continue;
          }
          this.applyProjectileHitToSoldier(p, target);
          this.projLastHitSoldier[i] = sIdx;
          p.pierceRemaining--;
          if (p.pierceRemaining <= 0) {
            p.active = false;
            break;
          }
        }
      }

      // 落地结算（抛射弓箭、火雷爆炸、投石车巨石砸地与拆城）
      if (p.active && p.flightProgress >= 1.0) {
        if (p.splashRadius > 0) {
          this.resolveSplashProjectileImpact(p);
        } else {
          const hitCount: number = this.spatialGrid.queryRadius(
            this.soldiers,
            p.x,
            p.y,
            24.0,
            this.queryBufA
          );
          let hitUnit: boolean = false;
          for (let k: number = 0; k < hitCount; k++) {
            const target: SoldierPoolItem = this.soldiers[this.queryBufA[k]];
            if (target.side !== p.side && target.active && target.hp > 0) {
              this.applyProjectileHitToSoldier(p, target);
              hitUnit = true;
              break;
            }
          }
          if (!hitUnit) {
            this.applyProjectileStructureDamage(p, 28.0);
          }
        }
        p.active = false;
      }
    }
  }

  private applyProjectileHitToSoldier(p: ProjectilePoolItem, target: SoldierPoolItem): void {
    const targetSq: SquadRuntimeItem = this.squads[target.squadId];
    const targetStats: UnitStaticStats = fastUnitStats(target.unitType);

    sampleTerrainAtPoint(
      target.x,
      target.y,
      this.terrainZones,
      this.config.terrain,
      this.terrainSampleB
    );

    // 迷雾密林树木遮挡：林外远程射击林内目标 30% 概率被枝叶偏转（DESIGN.md 7.2）
    if (this.terrainSampleB.terrain === TerrainType.DENSE_FOREST && p.splashRadius <= 0) {
      if (this.nextRandom01() < 0.30) {
        return;
      }
    }

    const threatOriginX: number = p.x - p.vx * 0.25;
    const threatOriginY: number = p.y - p.vy * 0.25;
    const incomingDeg: number = computeAttackIncomingAngleDeg(
      target.facingRad,
      target.x,
      target.y,
      threatOriginX,
      threatOriginY
    );

    const isCircle: boolean =
      targetSq.formation === FormationType.CIRCLE_DEFENSE &&
      targetSq.bannerLostPenaltyTimer <= 0 &&
      !targetSq.isRouting;
    const isPaviseReload: boolean =
      target.unitType === UnitTypeId.TIEYING_PAVISE_CROSSBOW && target.attackCooldown > 0.30;

    // 城墙工事掩体远程减伤 65%（及警钟入营民夫掩体减伤）
    let coverMult: number = 1.0;
    if (
      this.terrainSampleB.terrain === TerrainType.FORT_WALL ||
      (target.unitType === UnitTypeId.SAPPER &&
        target.side === BattleSide.PLAYER &&
        this.garrisonBellActive)
    ) {
      coverMult = 0.35;
    }

    // 雁行阵受范围爆炸伤 -35%（DESIGN.md 4.1）
    if (
      p.splashRadius > 0 &&
      targetSq.formation === FormationType.ECHELON_LINE &&
      targetSq.bannerLostPenaltyTimer <= 0
    ) {
      coverMult *= 0.65;
    }

    const effArmor: number = this.computeTargetModifiedArmor(
      target,
      targetSq,
      targetStats,
      this.terrainSampleB.terrain
    );
    const halfFordMult: number = this.checkAndTriggerHalfFordVulnerability(targetSq);

    let effectiveShieldBlock: number = targetStats.shieldRangedBlock;
    if (target.unitType === UnitTypeId.TIEYING_PAVISE_CROSSBOW && !isPaviseReload) {
      effectiveShieldBlock = 0; // 神弩手仅在换弹转身背盾期享 60% 大盾减免
    }

    this.dmgParams.reset();
    this.dmgParams.baseAttack = p.damage;
    this.dmgParams.targetArmor = effArmor;
    this.dmgParams.attackerArmorPen = p.armorPenetration;
    this.dmgParams.shieldRangedBlock = p.splashRadius > 0 ? effectiveShieldBlock * 0.35 : effectiveShieldBlock;
    this.dmgParams.isRanged = true;
    this.dmgParams.isExplosion = p.splashRadius > 0;
    this.dmgParams.incomingAngleDeg = incomingDeg;
    this.dmgParams.isCircleDefense = isCircle;
    this.dmgParams.isBridgePass = this.terrainSampleB.terrain === TerrainType.BRIDGE_PASS;
    this.dmgParams.isPaviseReloading = isPaviseReload;
    this.dmgParams.isTargetRouting = targetSq.isRouting;
    this.dmgParams.antiCavMult =
      p.kind === ProjectileKind.BALLISTA_SPEAR && target.category === UnitCategory.CAVALRY
        ? 1.40
        : 1.0;
    this.dmgParams.terrainMult = coverMult;
    this.dmgParams.halfFordMult = halfFordMult;

    const dmg: number = computeFinalHitDamage(this.dmgParams);
    target.hp -= dmg;
    target.isStealthed = false;
    this.soldierIdleCombatSec[target.poolIndex] = 0;

    if (p.applyPoison) {
      target.poisonTimer = Math.max(target.poisonTimer, 3.0);
    }

    if (effectiveShieldBlock >= 0.35 && (incomingDeg <= 60.0 || isCircle || isPaviseReload)) {
      this.spawnHitEffect(target.x, target.y, 'shield_spark', target.facingRad);
    }

    computeDirectionalModifiers(
      incomingDeg,
      isCircle,
      this.terrainSampleB.terrain === TerrainType.BRIDGE_PASS,
      this.dirModScratch
    );
    this.applyHitMoraleShockToSquad(
      targetSq,
      (dmg / Math.max(40.0, target.maxHp)) * 2.0 * this.dirModScratch.moraleShockMult
    );

    if (target.hp <= 0) {
      this.killSoldier(target, null);
    }
  }

  private resolveSplashProjectileImpact(p: ProjectilePoolItem): void {
    this.spawnHitEffect(p.x, p.y, 'boulder_crater', 0);
    const hitCount: number = this.spatialGrid.queryRadius(
      this.soldiers,
      p.x,
      p.y,
      p.splashRadius,
      this.queryBufA
    );
    let primaryShockSquadId: number = -1;

    for (let k: number = 0; k < hitCount; k++) {
      const target: SoldierPoolItem = this.soldiers[this.queryBufA[k]];
      if (target.side === p.side || !target.active || target.hp <= 0) {
        continue;
      }
      if (primaryShockSquadId === -1) {
        primaryShockSquadId = target.squadId;
      }
      this.applyProjectileHitToSoldier(p, target);
      if (
        p.kind === ProjectileKind.TREBUCHET_BOULDER &&
        target.active &&
        target.hp > 0
      ) {
        target.staggerTimer = Math.max(target.staggerTimer, 0.65);
        target.actionState = UnitActionState.STAGGER_HIT;
      }
    }

    // 结算火雷（-12 士气）或投石车巨石对命中军团的额外震慑士气打击
    if (p.moraleShock > 0 && primaryShockSquadId >= 0) {
      const shockedSq: SquadRuntimeItem = this.squads[primaryShockSquadId];
      const heroDown: boolean =
        shockedSq.side === BattleSide.PLAYER
          ? this.playerHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP
          : this.enemyHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP;
      const broke: boolean = applySquadMoraleAndHysteresis(
        shockedSq,
        -p.moraleShock,
        heroDown,
        false
      );
      if (broke) {
        this.onSquadBrokeIntoRout(shockedSq);
      }
    }

    this.applyProjectileStructureDamage(p, p.splashRadius);
  }

  private applyProjectileStructureDamage(p: ProjectilePoolItem, radius: number): void {
    const sideFaction: FactionId =
      p.side === BattleSide.PLAYER ? this.config.playerFaction : this.config.enemyFaction;

    for (let i: number = 0; i < this.structures.length; i++) {
      const st: FortStructureItem = this.structures[i];
      if (st.side === p.side || st.isBreached || st.hp <= 0) {
        continue;
      }
      const cx: number = Math.max(st.x, Math.min(st.x + st.width, p.x));
      const cy: number = Math.max(st.y, Math.min(st.y + st.height, p.y));
      const dx: number = cx - p.x;
      const dy: number = cy - p.y;
      if (dx * dx + dy * dy <= radius * radius) {
        // 配重投石车对建筑造成 350% 结构伤害；炎龙攻城器械再 +25%
        let structMult: number = p.kind === ProjectileKind.TREBUCHET_BOULDER ? 3.50 : 0.35;
        if (
          sideFaction === FactionId.YANLONG &&
          (p.kind === ProjectileKind.TREBUCHET_BOULDER || p.kind === ProjectileKind.BALLISTA_SPEAR)
        ) {
          structMult *= 1.25;
        }
        st.hp -= p.damage * structMult;
        if (st.hp <= 0) {
          st.hp = 0;
          st.isBreached = true;
        }
      }
    }
  }

  // ==================== 战争迷雾动态视野与环形特效池 ====================

  private updateFogOfWar(): void {
    this.updateSideVisibility(BattleSide.PLAYER, this.config.playerFaction);
    this.updateSideVisibility(BattleSide.ENEMY, this.config.enemyFaction);
  }

  private updateSideVisibility(observerSide: BattleSide, observerFaction: FactionId): void {
    let obsCount: number = 0;

    // 1. 收集己方士兵观察源
    for (let i: number = 0; i < this.soldiers.length; i++) {
      const s: SoldierPoolItem = this.soldiers[i];
      if (!s.active || s.hp <= 0 || s.side !== observerSide) {
        continue;
      }
      if (observerSide === BattleSide.PLAYER) {
        s.visibleToPlayer = true;
      } else {
        s.visibleToEnemy = true;
      }
      sampleTerrainAtPoint(s.x, s.y, this.terrainZones, this.config.terrain, this.terrainSampleA);
      const vRad: number = computeObserverVisionRadius(
        s.category,
        false,
        this.terrainSampleA.elevation,
        this.config.weather,
        observerFaction
      );
      if (obsCount < this.obsX.length) {
        this.obsX[obsCount] = s.x;
        this.obsY[obsCount] = s.y;
        this.obsRadius[obsCount] = vRad;
        obsCount++;
      }
    }

    // 2. 己方主帅视野源
    const hero: CommanderHeroEntity =
      observerSide === BattleSide.PLAYER ? this.playerHero : this.enemyHero;
    if (
      hero.hp > 0 &&
      (hero.vitalState === HeroVitalState.HEALTHY_ACTIVE ||
        hero.vitalState === HeroVitalState.WOUNDED_WEAKENED) &&
      obsCount < this.obsX.length
    ) {
      sampleTerrainAtPoint(hero.x, hero.y, this.terrainZones, this.config.terrain, this.terrainSampleA);
      this.obsX[obsCount] = hero.x;
      this.obsY[obsCount] = hero.y;
      this.obsRadius[obsCount] = computeObserverVisionRadius(
        UnitCategory.INFANTRY,
        true,
        this.terrainSampleA.elevation,
        this.config.weather,
        observerFaction
      );
      obsCount++;
    }

    // 3. 己方完好建筑视野源
    for (let i: number = 0; i < this.structures.length; i++) {
      const st: FortStructureItem = this.structures[i];
      if (st.side === observerSide && !st.isBreached && st.hp > 0 && obsCount < this.obsX.length) {
        this.obsX[obsCount] = st.x + st.width * 0.5;
        this.obsY[obsCount] = st.y + st.height * 0.5;
        this.obsRadius[obsCount] =
          this.config.weather === WeatherType.HEAVY_FOG ? 300.0 : 480.0;
        obsCount++;
      }
    }

    // 4. 逐名敌兵判定动态迷雾显形（密林未开火或潜行态需抵近 140px 识破，雾林势力透视）
    for (let i: number = 0; i < this.soldiers.length; i++) {
      const enemy: SoldierPoolItem = this.soldiers[i];
      if (!enemy.active || enemy.hp <= 0 || enemy.side === observerSide) {
        continue;
      }
      sampleTerrainAtPoint(
        enemy.x,
        enemy.y,
        this.terrainZones,
        this.config.terrain,
        this.terrainSampleB
      );
      const inForestUnfired: boolean =
        this.terrainSampleB.terrain === TerrainType.DENSE_FOREST &&
        this.soldierIdleCombatSec[i] >= 1.0;
      const concealed: boolean = enemy.isStealthed || inForestUnfired;

      let spotted: boolean = false;
      for (let o: number = 0; o < obsCount; o++) {
        const dx: number = enemy.x - this.obsX[o];
        const dy: number = enemy.y - this.obsY[o];
        const dSq: number = dx * dx + dy * dy;
        if (canObserverSpotTarget(dSq, this.obsRadius[o], observerFaction, concealed)) {
          spotted = true;
          break;
        }
      }

      if (observerSide === BattleSide.PLAYER) {
        enemy.visibleToPlayer = spotted;
      } else {
        enemy.visibleToEnemy = spotted;
      }
    }
  }

  private consumeHeroEvents(heroSide: BattleSide, ev: HeroStepEvents): void {
    if (ev.triggerHitStopMs > this.hitStopRemainingMs) {
      this.hitStopRemainingMs = ev.triggerHitStopMs;
      this.hudDirty = true;
    }
    if (ev.spawnArrow) {
      const speed: number = Math.sqrt(ev.arrowVx * ev.arrowVx + ev.arrowVy * ev.arrowVy);
      const dur: number = ev.arrowRange / Math.max(100.0, speed);
      this.spawnProjectile(
        heroSide,
        ProjectileKind.ARROW,
        ev.arrowStartX,
        ev.arrowStartY,
        ev.arrowStartX + ev.arrowVx * dur,
        ev.arrowStartY + ev.arrowVy * dur,
        6.0,
        dur,
        ev.arrowDamage,
        ev.arrowPen,
        0,
        2, // 百石硬弓重箭贯穿 2 人
        false,
        0
      );
    }
    for (let k: number = 0; k < ev.killedCount; k++) {
      const deadIdx: number = ev.killedSoldierIndices[k];
      if (deadIdx >= 0 && deadIdx < this.soldiers.length) {
        const victim: SoldierPoolItem = this.soldiers[deadIdx];
        const vSq: SquadRuntimeItem = this.squads[victim.squadId];
        if (vSq.aliveCount > 0) {
          vSq.aliveCount--;
        }
        this.spawnCorpseDecal(
          victim.x,
          victim.y,
          victim.facingRad,
          victim.factionId,
          victim.isBannerBearer
        );
        if (this.config.playerFaction === FactionId.XUEYUE) {
          this.playerBloodFrenzySec = Math.min(12.0, this.playerBloodFrenzySec + 1.2);
        }
        if (this.config.enemyFaction === FactionId.XUEYUE) {
          this.enemyBloodFrenzySec = Math.min(12.0, this.enemyBloodFrenzySec + 1.2);
        }
      }
    }
    if (ev.effectKind !== 'none') {
      this.spawnHitEffect(ev.effectX, ev.effectY, ev.effectKind, ev.effectAngle);
    }
    if (ev.playerForceReturnRts) {
      this.controlMode = BattleControlMode.RTS_COMMANDER;
      this.hudDirty = true;
    }
    if (ev.playerHeroMartyred) {
      this.outcome = BattleOutcomeReason.PLAYER_HERO_MARTYRED;
      this.hudDirty = true;
    }
    if (ev.enemyHeroDownedShock) {
      this.enemyCommandParalysisSec = Math.max(this.enemyCommandParalysisSec, 15.0);
      this.hudDirty = true;
    }
  }

  private spawnCorpseDecal(
    x: number,
    y: number,
    rotRad: number,
    factionId: FactionId,
    isBrokenBanner: boolean
  ): void {
    const c: CorpseDecalItem = this.corpses[this.corpseWriteCursor];
    c.active = true;
    c.x = x;
    c.y = y;
    c.rotationRad = rotRad;
    c.factionId = factionId;
    c.isBrokenBanner = isBrokenBanner;
    c.alpha = 0.90;
    this.corpseWriteCursor = (this.corpseWriteCursor + 1) % this.corpses.length;
  }

  private spawnHitEffect(
    x: number,
    y: number,
    kind: 'slash_arc' | 'shield_spark' | 'boulder_crater' | 'morale_burst' | 'blood_splash',
    angleRad: number
  ): void {
    const ef: HitEffectItem = this.hitEffects[this.effectWriteCursor];
    ef.active = true;
    ef.x = x;
    ef.y = y;
    ef.kind = kind;
    ef.maxTtl = kind === 'boulder_crater' ? 1.2 : 0.30;
    ef.ttl = ef.maxTtl;
    ef.angleRad = angleRad;
    this.effectWriteCursor = (this.effectWriteCursor + 1) % this.hitEffects.length;
  }

  private stepVisualEffects(dtSec: number): void {
    for (let i: number = 0; i < this.hitEffects.length; i++) {
      const ef: HitEffectItem = this.hitEffects[i];
      if (ef.active) {
        ef.ttl -= dtSec;
        if (ef.ttl <= 0) {
          ef.active = false;
        }
      }
    }
  }

  // ==================== 终局胜负检测与只读快照封装 ====================

  private evaluateBattleOutcome(dtSec: number): void {
    if (this.outcome !== BattleOutcomeReason.ONGOING) {
      return;
    }
    if (this.playerHero.vitalState === HeroVitalState.FALLEN_MARTYRED) {
      this.outcome = BattleOutcomeReason.PLAYER_HERO_MARTYRED;
      return;
    }
    if (this.playerBaseCamp !== null && (this.playerBaseCamp.isBreached || this.playerBaseCamp.hp <= 0)) {
      this.outcome = BattleOutcomeReason.PLAYER_BASE_DESTROYED;
      return;
    }
    if (this.enemyBaseCamp !== null && (this.enemyBaseCamp.isBreached || this.enemyBaseCamp.hp <= 0)) {
      this.outcome = BattleOutcomeReason.ENEMY_BASE_DESTROYED;
      return;
    }

    if (this.config.scenarioType === BattleScenarioType.SIEGE_DEFENSE) {
      const targetHoldSec: number =
        this.config.siegeHoldDurationSec > 0 ? this.config.siegeHoldDurationSec : 180.0;
      if (this.elapsedSec >= targetHoldSec) {
        this.outcome = BattleOutcomeReason.SIEGE_DEFENSE_HELD;
        return;
      }
    }

    this.recountArmyTotals();
    if (this.enemyInitialTotal > 0 && this.enemyAliveCount === 0) {
      this.outcome = BattleOutcomeReason.ENEMY_ARMY_ROUTED;
      return;
    }
    if (this.playerInitialTotal > 0 && this.playerAliveCount === 0) {
      this.outcome = BattleOutcomeReason.PLAYER_ARMY_ROUTED;
      return;
    }

    // 全军崩溃持续计时（预留 10s 允许主帅释放【三军战吼】挽狂澜于既倒）
    const pNonRout: number = this.countNonRoutingSoldiers(BattleSide.PLAYER);
    const eNonRout: number = this.countNonRoutingSoldiers(BattleSide.ENEMY);

    if (this.enemyInitialTotal > 0 && eNonRout === 0) {
      this.enemyAllRoutingSec += dtSec;
      if (this.enemyAllRoutingSec >= 10.0) {
        this.outcome = BattleOutcomeReason.ENEMY_ARMY_ROUTED;
        return;
      }
    } else {
      this.enemyAllRoutingSec = 0;
    }

    if (this.playerInitialTotal > 0 && pNonRout === 0) {
      this.playerAllRoutingSec += dtSec;
      if (this.playerAllRoutingSec >= 10.0) {
        this.outcome = BattleOutcomeReason.PLAYER_ARMY_ROUTED;
        return;
      }
    } else {
      this.playerAllRoutingSec = 0;
    }
  }

  private countNonRoutingSoldiers(side: BattleSide): number {
    let c: number = 0;
    for (let i: number = 0; i < this.soldiers.length; i++) {
      const s: SoldierPoolItem = this.soldiers[i];
      if (s.active && s.hp > 0 && s.side === side && !this.squads[s.squadId].isRouting) {
        c++;
      }
    }
    return c;
  }

  private recountArmyTotals(): void {
    let pAlive: number = 0;
    let eAlive: number = 0;
    let pPop: number = 0;
    let ePop: number = 0;

    for (let i: number = 0; i < this.soldiers.length; i++) {
      const s: SoldierPoolItem = this.soldiers[i];
      if (!s.active || s.hp <= 0) {
        continue;
      }
      const pop: number = fastUnitStats(s.unitType).popCap;
      if (s.side === BattleSide.PLAYER) {
        pAlive++;
        pPop += pop;
      } else {
        eAlive++;
        ePop += pop;
      }
    }
    this.playerAliveCount = pAlive;
    this.enemyAliveCount = eAlive;
    this.playerPopUsed = pPop;
    this.enemyPopUsed = ePop;

    let pMoraleSum: number = 0;
    let pSquadWeight: number = 0;
    for (let i: number = 0; i < this.playerSquads.length; i++) {
      const sq: SquadRuntimeItem = this.playerSquads[i];
      if (sq.aliveCount > 0) {
        pMoraleSum += sq.morale * sq.aliveCount;
        pSquadWeight += sq.aliveCount;
      }
    }
    this.playerAvgMorale = pSquadWeight > 0 ? pMoraleSum / pSquadWeight : 0;

    let eMoraleSum: number = 0;
    let eSquadWeight: number = 0;
    for (let i: number = 0; i < this.enemySquads.length; i++) {
      const sq: SquadRuntimeItem = this.enemySquads[i];
      if (sq.aliveCount > 0) {
        eMoraleSum += sq.morale * sq.aliveCount;
        eSquadWeight += sq.aliveCount;
      }
    }
    this.enemyAvgMorale = eSquadWeight > 0 ? eMoraleSum / eSquadWeight : 0;
  }

  private nextRandom01(): number {
    let x: number = this.prngState | 0;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.prngState = x | 0;
    return ((x >>> 0) % 10000) / 10000.0;
  }

  private createHudSnapshot(): BattleHudSnapshot {
    this.recountArmyTotals();
    const snap: BattleHudSnapshot = {
      elapsedSec: this.elapsedSec,
      isPaused: this.isPaused,
      controlMode: this.controlMode,
      switchCooldownSec: this.switchCooldownSec,
      garrisonBellActive: this.garrisonBellActive,
      playerGold: Math.floor(this.playerGold),
      playerWood: Math.floor(this.playerWood),
      playerGrain: Math.floor(this.playerGrain),
      playerRationStage: this.playerRationStage,
      enemyRationStage: this.enemyRationStage,
      playerAliveSoldiers: this.playerAliveCount,
      playerPopUsed: this.playerPopUsed,
      playerPopCap: GameConstants.DEFAULT_ARMY_POP_CAP,
      enemyAliveSoldiers: this.enemyAliveCount,
      playerAvgMorale: Math.round(this.playerAvgMorale * 10) / 10,
      enemyAvgMorale: Math.round(this.enemyAvgMorale * 10) / 10,
      heroHp: Math.round(this.playerHero.hp),
      heroMaxHp: this.playerHero.maxHp,
      heroVitalState: this.playerHero.vitalState,
      heroWeapon: this.playerHero.activeWeapon,
      heroArrows: this.playerHero.remainingArrows,
      chargeCd: Math.round(this.playerHero.chargeCooldown * 10) / 10,
      bulwarkCd: Math.round(this.playerHero.bulwarkCooldown * 10) / 10,
      warCryCd: Math.round(this.playerHero.warCryCooldown * 10) / 10,
      hitStopRemainingMs: Math.round(this.hitStopRemainingMs),
      outcome: this.outcome
    };
    return snap;
  }

  private createWorldView(): BattleWorldReadonlyView {
    const view: BattleWorldReadonlyView = {
      width: this.worldWidth,
      height: this.worldHeight,
      scenarioType: this.config.scenarioType,
      primaryTerrain: this.config.terrain,
      weather: this.config.weather,
      playerFaction: this.config.playerFaction,
      enemyFaction: this.config.enemyFaction,
      terrainZones: this.terrainZones,
      resourceNodes: this.resourceNodes,
      structures: this.structures,
      soldiers: this.soldiers,
      squads: this.squads,
      playerHero: this.playerHero as CommanderHeroRuntime,
      enemyHero: this.enemyHero as CommanderHeroRuntime,
      projectiles: this.projectiles,
      corpses: this.corpses,
      hitEffects: this.hitEffects,
      hud: this.cachedHud
    };
    return view;
  }
}

export {
  SpatialHashGrid,
  DamageFormulaParams,
  DirectionalCombatModifiers,
  computeEffectiveArmor,
  computeHyperbolicMitigation,
  computeRangedShieldMultiplier,
  computeDirectionalModifiers,
  computeAttackIncomingAngleDeg,
  isBracedAntiCavalryTriggered,
  computeFinalHitDamage,
  classifyEncirclementFromMask,
  hasPinceredOctantPair,
  evaluateRationStage,
  applySquadMoraleAndHysteresis,
  computeObserverVisionRadius,
  canObserverSpotTarget
};
