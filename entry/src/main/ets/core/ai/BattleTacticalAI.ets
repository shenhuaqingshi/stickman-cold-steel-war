/**
 * L2 战场多军团黑板战术指挥官 AI + 攻守城三段式状态机（BattleTacticalAI.ets）
 *
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范：
 * - 零 any / unknown，零未标注对象字面量，零 @kit.ArkUI 依赖
 * - 基于 BattleWorldReadonlyView 纯数据视图，每 0.5s 刷新态势黑板并输出结构化决策批次 AiBattleDecisionBatch
 * - 完整实装 DESIGN.md 9.2 七大高阶冷兵器战术与 8 种 AiPersonality 非对称指挥差异
 */
import { GameConstants } from '../../common/GameConstants';
import { getFactionConfigById } from '../../config/FactionConfig';
import { getUnitConfigById, UNIT_STATIC_CONFIGS } from '../../config/UnitConfig';
import {
  AiPersonality,
  ArmyCorpsRole,
  BattleScenarioType,
  EncirclementState,
  FactionId,
  FactionStaticConfig,
  FormationType,
  HeroWeaponType,
  TacticalOrder,
  TerrainType,
  UnitCategory,
  UnitStaticStats,
  UnitTypeId,
  WeatherType
} from '../../model/GameTypes';
import {
  BattlefieldRationStage,
  BattlefieldResourceNode,
  BattleSide,
  BattleWorldReadonlyView,
  CommanderHeroRuntime,
  FortStructureEntity,
  HeroVitalState,
  SoldierRuntimeEntity,
  SquadCommandRequest,
  SquadRuntimeState,
  TerrainZoneRect
} from '../CoreContracts';

/** 战术黑板标准更新周期（秒，对应 DESIGN.md 9.2 每 0.5s 更新一次） */
export const AI_BLACKBOARD_UPDATE_INTERVAL_SEC: number = 0.5;

/** 战场 AI 顶层作战教条标识 */
export enum TacticalDoctrineId {
  PINNING_PINCER_ENCIRCLE = 'PINNING_PINCER_ENCIRCLE',
  FORD_AMBUSH_WAIT = 'FORD_AMBUSH_WAIT',
  HALF_FORD_STRIKE = 'HALF_FORD_STRIKE',
  HIGH_GROUND_HEDGEHOG = 'HIGH_GROUND_HEDGEHOG',
  FEIGNED_RETREAT_LURE = 'FEIGNED_RETREAT_LURE',
  FOREST_TRAP_ENCIRCLE = 'FOREST_TRAP_ENCIRCLE',
  ANTI_KITE_DETACH_ONE = 'ANTI_KITE_DETACH_ONE',
  DECAPITATION_HUNT = 'DECAPITATION_HUNT',
  SIEGE_THREE_STAGE_ASSAULT = 'SIEGE_THREE_STAGE_ASSAULT',
  SIEGE_THREE_STAGE_DEFENSE = 'SIEGE_THREE_STAGE_DEFENSE',
  COMMAND_PARALYSIS_HOLD = 'COMMAND_PARALYSIS_HOLD'
}

/** 攻守城三段式状态机阶段标识 */
export enum SiegeTacticalPhase {
  NONE = 'NONE',
  ASSAULT_PHASE_1_ARTILLERY = 'ASSAULT_PHASE_1_ARTILLERY',
  ASSAULT_PHASE_2_ESCALADE_BATTER = 'ASSAULT_PHASE_2_ESCALADE_BATTER',
  ASSAULT_PHASE_3_BREACH_COMMIT = 'ASSAULT_PHASE_3_BREACH_COMMIT',
  DEFENSE_PHASE_1_WALL_SNIPE = 'DEFENSE_PHASE_1_WALL_SNIPE',
  DEFENSE_PHASE_2_PLUG_GATE = 'DEFENSE_PHASE_2_PLUG_GATE',
  DEFENSE_PHASE_3_SALLY_BURN_SIEGE = 'DEFENSE_PHASE_3_SALLY_BURN_SIEGE'
}

/** AI 战场补兵招募请求项 */
export interface AiRecruitRequest {
  readonly unitType: UnitTypeId;
  readonly corpsRole: ArmyCorpsRole;
}

/** AI 每 0.5s 输出的战场完整决策批次结构 */
export interface AiBattleDecisionBatch {
  readonly squadCommands: SquadCommandRequest[];
  readonly recruitRequests: AiRecruitRequest[];
  readonly toggleGarrisonBell: boolean;
  readonly enemyHeroTargetX: number;
  readonly enemyHeroTargetY: number;
  readonly enemyHeroTriggerWarCry: boolean;
  readonly activeDoctrine: string;
  readonly siegePhase: string;
}

/** 二维战场坐标点 */
interface Point2D {
  x: number;
  y: number;
}

/** L2 多军团共享态势黑板快照 */
export interface TacticalBlackboard {
  personality: AiPersonality;
  elapsedSec: number;
  enemyHomeX: number;
  enemyHomeY: number;
  playerHomeX: number;
  playerHomeY: number;
  /** 从敌方本阵指向玩家本阵的水平推进方向（+1 或 -1） */
  forwardDirX: number;
  enemyFrontX: number;
  enemyFrontY: number;
  playerFrontX: number;
  playerFrontY: number;
  playerRearX: number;
  playerRearY: number;
  enemyCombatPower: number;
  playerCombatPower: number;
  playerCavalryRatio: number;
  playerRangedRatio: number;
  playerHeavyArmorRatio: number;
  hasRiverFord: boolean;
  riverCenterX: number;
  riverCenterY: number;
  halfFordTargetSquadId: number;
  hasHighGroundAnchor: boolean;
  highGroundX: number;
  highGroundY: number;
  hasForestTrapZone: boolean;
  forestTrapX: number;
  forestTrapY: number;
  exposedPlayerSapperFound: boolean;
  exposedSapperX: number;
  exposedSapperY: number;
  enemyCampUnderRaid: boolean;
  raiderThreatX: number;
  raiderThreatY: number;
  playerHeroKitingSolo: boolean;
  playerHeroDecapitable: boolean;
  playerBaitingHighGround: boolean;
  reserveEmergencySquadId: number;
  reserveBreakthroughSquadId: number;
  isCommandParalyzed: boolean;
  isAiSiegeAttacker: boolean;
  isAiSiegeDefender: boolean;
}

function clampCoord(val: number, minVal: number, maxVal: number): number {
  if (val < minVal) {
    return minVal;
  }
  if (val > maxVal) {
    return maxVal;
  }
  return val;
}

function distSq(ax: number, ay: number, bx: number, by: number): number {
  const dx: number = ax - bx;
  const dy: number = ay - by;
  return dx * dx + dy * dy;
}

function createEmptyBlackboard(): TacticalBlackboard {
  return {
    personality: AiPersonality.IMPERIAL_METHODICAL,
    elapsedSec: 0,
    enemyHomeX: 4300,
    enemyHomeY: 1200,
    playerHomeX: 500,
    playerHomeY: 1200,
    forwardDirX: -1,
    enemyFrontX: 3800,
    enemyFrontY: 1200,
    playerFrontX: 1000,
    playerFrontY: 1200,
    playerRearX: 700,
    playerRearY: 1200,
    enemyCombatPower: 0,
    playerCombatPower: 0,
    playerCavalryRatio: 0,
    playerRangedRatio: 0,
    playerHeavyArmorRatio: 0,
    hasRiverFord: false,
    riverCenterX: 2400,
    riverCenterY: 1200,
    halfFordTargetSquadId: -1,
    hasHighGroundAnchor: false,
    highGroundX: 3200,
    highGroundY: 1200,
    hasForestTrapZone: false,
    forestTrapX: 3100,
    forestTrapY: 600,
    exposedPlayerSapperFound: false,
    exposedSapperX: 0,
    exposedSapperY: 0,
    enemyCampUnderRaid: false,
    raiderThreatX: 0,
    raiderThreatY: 0,
    playerHeroKitingSolo: false,
    playerHeroDecapitable: false,
    playerBaitingHighGround: false,
    reserveEmergencySquadId: -1,
    reserveBreakthroughSquadId: -1,
    isCommandParalyzed: false,
    isAiSiegeAttacker: false,
    isAiSiegeDefender: false
  };
}

/** 预构建 O(1) 兵种静态配置哈希表，消除每 0.5s 黑板评估中的重复线性查找开销 */
const UNIT_STATS_LOOKUP: Map<UnitTypeId, UnitStaticStats> = buildUnitStatsLookup();

function buildUnitStatsLookup(): Map<UnitTypeId, UnitStaticStats> {
  const table: Map<UnitTypeId, UnitStaticStats> = new Map<UnitTypeId, UnitStaticStats>();
  for (let i: number = 0; i < UNIT_STATIC_CONFIGS.length; i++) {
    const item: UnitStaticStats = UNIT_STATIC_CONFIGS[i];
    table.set(item.id, item);
  }
  return table;
}

function fastUnitStats(unitId: UnitTypeId): UnitStaticStats | undefined {
  const cached: UnitStaticStats | undefined = UNIT_STATS_LOOKUP.get(unitId);
  return cached !== undefined ? cached : getUnitConfigById(unitId);
}

/**
 * 计算单支分队的估算战斗力权重
 */
function estimateSquadPower(squad: SquadRuntimeState): number {
  if (squad.aliveCount <= 0 || squad.isRouting) {
    return 0;
  }
  const stats: UnitStaticStats | undefined = fastUnitStats(squad.primaryUnitType);
  if (stats === undefined) {
    return squad.aliveCount * 15;
  }
  const unitScore: number =
    stats.hp * 0.08 +
    (stats.attack / Math.max(0.5, stats.attackIntervalSec)) * (1.0 + stats.armorPenetration * 0.6) +
    stats.armor * 0.25;
  const moraleFactor: number = clampCoord(squad.morale / 80.0, 0.35, 1.2);
  return squad.aliveCount * unitScore * moraleFactor;
}

/**
 * 判断分队是否具备机动突袭/驱离能力（骑兵 > 突击轻快兵 > 高速神射）
 */
function getSquadMobilityScore(squad: SquadRuntimeState): number {
  if (squad.aliveCount <= 0 || squad.isRouting) {
    return -1;
  }
  const stats: UnitStaticStats | undefined = fastUnitStats(squad.primaryUnitType);
  if (stats === undefined) {
    return 50;
  }
  if (stats.category === UnitCategory.SUPPORT || stats.category === UnitCategory.SIEGE) {
    return -1;
  }
  let bonus: number = stats.moveSpeed;
  if (stats.category === UnitCategory.CAVALRY) {
    bonus += 90;
  } else if (squad.corpsRole === ArmyCorpsRole.LEFT_WING || squad.corpsRole === ArmyCorpsRole.RIGHT_WING) {
    bonus += 35;
  }
  return bonus;
}

/**
 * 判断分队是否为高破甲或精锐斩首单位
 */
function isArmorPiercingOrEliteSquad(squad: SquadRuntimeState): boolean {
  if (squad.aliveCount <= 0 || squad.isRouting) {
    return false;
  }
  const stats: UnitStaticStats | undefined = fastUnitStats(squad.primaryUnitType);
  if (stats === undefined) {
    return false;
  }
  if (stats.category === UnitCategory.SUPPORT) {
    return false;
  }
  return (
    stats.armorPenetration >= 0.30 ||
    stats.category === UnitCategory.CAVALRY ||
    stats.category === UnitCategory.SHOCK
  );
}

/**
 * L2 战场多军团战术指挥官类（支持 0.5s 周期步进与即时黑板评估）
 */
export class BattleTacticalAI {
  private readonly blackboard: TacticalBlackboard = createEmptyBlackboard();
  private tickAccumulatorSec: number = 0;
  private garrisonBellActiveState: boolean = false;
  private feignedRetreatStartedAtSec: number = -1;
  private feignedRetreatCompleted: boolean = false;
  private prevEnemyHeroVital: HeroVitalState = HeroVitalState.HEALTHY_ACTIVE;
  private paralysisRemainingSec: number = 0;

  /**
   * 重置单局战场 AI 内部记忆状态
   */
  public reset(): void {
    this.tickAccumulatorSec = 0;
    this.garrisonBellActiveState = false;
    this.feignedRetreatStartedAtSec = -1;
    this.feignedRetreatCompleted = false;
    this.prevEnemyHeroVital = HeroVitalState.HEALTHY_ACTIVE;
    this.paralysisRemainingSec = 0;
  }

  /**
   * 读取当前态势黑板只读快照
   */
  public getBlackboard(): TacticalBlackboard {
    return this.blackboard;
  }

  /**
   * 按逻辑帧步进计时器，每满 0.5s 更新一次态势黑板并返回新决策批次；未到周期返回 null
   */
  public step(world: BattleWorldReadonlyView, dtSec: number): AiBattleDecisionBatch | null {
    if (dtSec > 0 && this.paralysisRemainingSec > 0) {
      this.paralysisRemainingSec = Math.max(0, this.paralysisRemainingSec - dtSec);
    }
    this.tickAccumulatorSec += Math.max(0, dtSec);
    if (this.tickAccumulatorSec + 1e-6 < AI_BLACKBOARD_UPDATE_INTERVAL_SEC) {
      return null;
    }
    while (this.tickAccumulatorSec >= AI_BLACKBOARD_UPDATE_INTERVAL_SEC) {
      this.tickAccumulatorSec -= AI_BLACKBOARD_UPDATE_INTERVAL_SEC;
    }
    return this.evaluateNow(world);
  }

  /**
   * 立即刷新战场态势黑板并生成完整战术决策批次
   */
  public evaluateNow(world: BattleWorldReadonlyView): AiBattleDecisionBatch {
    this.updateParalysisState(world);
    this.refreshBlackboard(world);

    const bb: TacticalBlackboard = this.blackboard;
    const toggleBell: boolean = this.computeGarrisonBellToggle(bb.enemyCampUnderRaid);
    const recruitRequests: AiRecruitRequest[] = this.planRecruitments(world, bb);

    // 收集双方有效分队
    const enemySquads: SquadRuntimeState[] = [];
    const playerSquads: SquadRuntimeState[] = [];
    for (let i: number = 0; i < world.squads.length; i++) {
      const sq: SquadRuntimeState = world.squads[i];
      if (sq.aliveCount <= 0) {
        continue;
      }
      if (sq.side === BattleSide.ENEMY) {
        enemySquads.push(sq);
      } else if (!sq.isRouting && this.isPlayerSquadDetected(world, sq)) {
        playerSquads.push(sq);
      }
    }

    // 边界规则（DESIGN.md 10.2.3）：敌帅刚被击倒 15s 内陷入指挥瘫痪（无法变阵与投入预备队）
    if (bb.isCommandParalyzed) {
      const paralyzedCommands: SquadCommandRequest[] = this.buildParalyzedHoldCommands(enemySquads);
      const heroPoint: Point2D = this.computeEnemyHeroPosition(world, bb, SiegeTacticalPhase.NONE);
      return {
        squadCommands: paralyzedCommands,
        recruitRequests: recruitRequests,
        toggleGarrisonBell: toggleBell,
        enemyHeroTargetX: heroPoint.x,
        enemyHeroTargetY: heroPoint.y,
        enemyHeroTriggerWarCry: false,
        activeDoctrine: TacticalDoctrineId.COMMAND_PARALYSIS_HOLD,
        siegePhase: SiegeTacticalPhase.NONE
      };
    }

    // 战术 7A：AI 攻城三段式状态机
    if (bb.isAiSiegeAttacker) {
      return this.executeSiegeAssaultFSM(world, bb, enemySquads, playerSquads, recruitRequests, toggleBell);
    }

    // 战术 7B：AI 守城三段式状态机
    if (bb.isAiSiegeDefender) {
      return this.executeSiegeDefenseFSM(world, bb, enemySquads, playerSquads, recruitRequests, toggleBell);
    }

    // 野战 / 护粮 / 夜袭 / 伏击 七大高阶冷兵器战术综合决策
    return this.executeFieldBattleCommander(world, bb, enemySquads, playerSquads, recruitRequests, toggleBell);
  }

  /**
   * 检测敌方主帅是否刚落马触发 15s 指挥瘫痪（兼容状态步进与单帧静态快照）
   */
  private updateParalysisState(world: BattleWorldReadonlyView): void {
    const hero: CommanderHeroRuntime = world.enemyHero;
    if (
      this.prevEnemyHeroVital === HeroVitalState.HEALTHY_ACTIVE &&
      (hero.vitalState === HeroVitalState.RECOVERING_IN_CAMP || hero.vitalState === HeroVitalState.FALLEN_MARTYRED)
    ) {
      this.paralysisRemainingSec = 15.0;
    }
    this.prevEnemyHeroVital = hero.vitalState;

    const snapshotJustDowned: boolean =
      hero.vitalState === HeroVitalState.RECOVERING_IN_CAMP && hero.recoveryTimer > 30.0;
    this.blackboard.isCommandParalyzed = this.paralysisRemainingSec > 0 || snapshotJustDowned;
  }

  /**
   * 战争迷雾与密林反伏击可见性检查（雾林猎手透视林雾；若单测未填充单兵池则回退分队级可见）
   */
  private isPlayerSquadDetected(world: BattleWorldReadonlyView, playerSquad: SquadRuntimeState): boolean {
    let hasAnyPlayerSoldierRecord: boolean = false;
    let squadHasSoldierRecord: boolean = false;
    for (let i: number = 0; i < world.soldiers.length; i++) {
      const s: SoldierRuntimeEntity = world.soldiers[i];
      if (!s.active || s.side !== BattleSide.PLAYER) {
        continue;
      }
      hasAnyPlayerSoldierRecord = true;
      if (s.squadId === playerSquad.squadId) {
        squadHasSoldierRecord = true;
        if (s.visibleToEnemy) {
          return true;
        }
        if (world.enemyFaction === FactionId.WULIN && s.isStealthed) {
          return true;
        }
      }
    }
    if (!hasAnyPlayerSoldierRecord || !squadHasSoldierRecord) {
      return true;
    }
    // 近距接战保底感知（140px 贴脸识破）
    for (let j: number = 0; j < world.squads.length; j++) {
      const esq: SquadRuntimeState = world.squads[j];
      if (esq.side === BattleSide.ENEMY && esq.aliveCount > 0) {
        if (distSq(esq.centerX, esq.centerY, playerSquad.centerX, playerSquad.centerY) <= 160 * 160) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 全量扫描战场并刷新 L2 态势黑板
   */
  private refreshBlackboard(world: BattleWorldReadonlyView): void {
    const bb: TacticalBlackboard = this.blackboard;
    const factionCfg: FactionStaticConfig | undefined = getFactionConfigById(world.enemyFaction);
    bb.personality = factionCfg !== undefined ? factionCfg.aiPersonality : AiPersonality.IMPERIAL_METHODICAL;
    bb.elapsedSec = world.hud.elapsedSec;

    // 1. 定位敌我本阵大营与进攻轴向
    let foundEnemyCamp: boolean = false;
    let foundPlayerCamp: boolean = false;
    let playerFortCount: number = 0;
    let enemyFortCount: number = 0;

    for (let i: number = 0; i < world.structures.length; i++) {
      const st: FortStructureEntity = world.structures[i];
      if (st.kind === 'base_camp') {
        const scx: number = st.x + st.width * 0.5;
        const scy: number = st.y + st.height * 0.5;
        if (st.side === BattleSide.ENEMY) {
          bb.enemyHomeX = scx;
          bb.enemyHomeY = scy;
          foundEnemyCamp = true;
        } else {
          bb.playerHomeX = scx;
          bb.playerHomeY = scy;
          foundPlayerCamp = true;
        }
      } else if (st.kind === 'gate' || st.kind === 'wall_segment') {
        if (st.side === BattleSide.PLAYER) {
          playerFortCount += 1;
        } else {
          enemyFortCount += 1;
        }
      }
    }

    if (!foundEnemyCamp) {
      bb.enemyHomeX = world.enemyHero.x > 0 ? world.enemyHero.x : world.width * 0.88;
      bb.enemyHomeY = world.height * 0.5;
    }
    if (!foundPlayerCamp) {
      bb.playerHomeX = world.playerHero.x > 0 ? world.playerHero.x : world.width * 0.12;
      bb.playerHomeY = world.height * 0.5;
    }
    bb.forwardDirX = bb.playerHomeX <= bb.enemyHomeX ? -1 : 1;

    // 攻守城身份自动识别（兼顾城防建筑实际归属与场景枚举）
    if (playerFortCount > 0 && enemyFortCount === 0) {
      bb.isAiSiegeAttacker = true;
      bb.isAiSiegeDefender = false;
    } else if (enemyFortCount > 0 && playerFortCount === 0) {
      bb.isAiSiegeAttacker = false;
      bb.isAiSiegeDefender = true;
    } else if (world.scenarioType === BattleScenarioType.SIEGE_DEFENSE) {
      bb.isAiSiegeAttacker = true;
      bb.isAiSiegeDefender = false;
    } else if (world.scenarioType === BattleScenarioType.SIEGE_ASSAULT) {
      bb.isAiSiegeAttacker = false;
      bb.isAiSiegeDefender = true;
    } else {
      bb.isAiSiegeAttacker = false;
      bb.isAiSiegeDefender = false;
    }

    // 2. 统计双方分队战力、兵种配比、前线与后排重心、半渡而击目标与预备队阈值
    bb.enemyCombatPower = 0;
    bb.playerCombatPower = 0;
    bb.halfFordTargetSquadId = -1;
    bb.reserveEmergencySquadId = -1;
    bb.reserveBreakthroughSquadId = -1;

    let enemyFrontBestProj: number = -1e9;
    let enemyFrontX: number = bb.enemyHomeX + bb.forwardDirX * 480;
    let enemyFrontY: number = world.height * 0.5;

    let playerFrontMostScore: number = -1e9;
    let playerFrontX: number = bb.playerHomeX - bb.forwardDirX * 450;
    let playerFrontY: number = world.height * 0.5;
    let playerRearMostScore: number = 1e9;
    let playerRearX: number = bb.playerHomeX;
    let playerRearY: number = world.height * 0.5;

    let totalPlayerCount: number = 0;
    let playerCavCount: number = 0;
    let playerRangedCount: number = 0;
    let playerHeavyArmorCount: number = 0;
    let lowestFriendlyMorale: number = 35.0;
    let lowestPlayerMorale: number = 40.0;

    for (let i: number = 0; i < world.squads.length; i++) {
      const sq: SquadRuntimeState = world.squads[i];
      if (sq.aliveCount <= 0) {
        continue;
      }
      if (sq.side === BattleSide.ENEMY) {
        bb.enemyCombatPower += estimateSquadPower(sq);
        if (
          !sq.isRouting &&
          sq.corpsRole !== ArmyCorpsRole.REAR_RESERVE &&
          sq.corpsRole !== ArmyCorpsRole.SUPPLY_ESCORT &&
          sq.corpsRole !== ArmyCorpsRole.SIEGE_BATTERY
        ) {
          const enemyProj: number = (sq.centerX - bb.enemyHomeX) * bb.forwardDirX +
            (sq.corpsRole === ArmyCorpsRole.VANGUARD_CENTER ? 80 : 0);
          if (enemyProj > enemyFrontBestProj) {
            enemyFrontBestProj = enemyProj;
            enemyFrontX = sq.centerX;
            enemyFrontY = sq.centerY;
          }
        }
        // 检测己方前线/侧翼濒溃缺口（士气 < 35）供总预备队堵漏
        if (
          sq.corpsRole !== ArmyCorpsRole.REAR_RESERVE &&
          sq.corpsRole !== ArmyCorpsRole.SUPPLY_ESCORT &&
          sq.morale < lowestFriendlyMorale
        ) {
          lowestFriendlyMorale = sq.morale;
          bb.reserveEmergencySquadId = sq.squadId;
        }
      } else {
        if (!this.isPlayerSquadDetected(world, sq)) {
          continue;
        }
        bb.playerCombatPower += estimateSquadPower(sq);
        const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
        if (stats !== undefined && stats.category !== UnitCategory.SUPPORT) {
          totalPlayerCount += sq.aliveCount;
          if (stats.category === UnitCategory.CAVALRY) {
            playerCavCount += sq.aliveCount;
          }
          if (stats.category === UnitCategory.RANGED || stats.category === UnitCategory.SIEGE) {
            playerRangedCount += sq.aliveCount;
          }
          if (stats.armor >= 40) {
            playerHeavyArmorCount += sq.aliveCount;
          }

          // 朝向敌方本阵推进越深，frontScore 越大
          const frontProjection: number = (sq.centerX - bb.playerHomeX) * (-bb.forwardDirX);
          if (!sq.isRouting && frontProjection > playerFrontMostScore) {
            playerFrontMostScore = frontProjection;
            playerFrontX = sq.centerX;
            playerFrontY = sq.centerY;
          }
          if (!sq.isRouting && (stats.category === UnitCategory.RANGED || stats.category === UnitCategory.SIEGE)) {
            if (frontProjection < playerRearMostScore) {
              playerRearMostScore = frontProjection;
              playerRearX = sq.centerX;
              playerRearY = sq.centerY;
            }
          }
        }

        // 检测玩家分队处于涉水 30%~80% 半渡脱节态
        if (!sq.isRouting && sq.fordRatio >= 0.30 && sq.fordRatio <= 0.80) {
          bb.halfFordTargetSquadId = sq.squadId;
        }

        // 检测玩家主力阵线动摇或遭合围缺口，供总预备队致命一击
        if (
          sq.corpsRole !== ArmyCorpsRole.SUPPLY_ESCORT &&
          sq.primaryUnitType !== UnitTypeId.SAPPER &&
          (sq.morale < lowestPlayerMorale ||
            sq.isRouting ||
            sq.encirclement === EncirclementState.PINCERED ||
            sq.encirclement === EncirclementState.ENCIRCLED)
        ) {
          if (sq.morale < lowestPlayerMorale || bb.reserveBreakthroughSquadId < 0) {
            lowestPlayerMorale = Math.min(lowestPlayerMorale, sq.morale);
            bb.reserveBreakthroughSquadId = sq.squadId;
          }
        }
      }
    }

    bb.enemyFrontX = enemyFrontX;
    bb.enemyFrontY = enemyFrontY;
    bb.playerFrontX = playerFrontX;
    bb.playerFrontY = playerFrontY;
    if (playerRearMostScore < 1e8) {
      bb.playerRearX = playerRearX;
      bb.playerRearY = playerRearY;
    } else {
      bb.playerRearX = clampCoord(playerFrontX - (-bb.forwardDirX) * 260, 100, world.width - 100);
      bb.playerRearY = playerFrontY;
    }

    const safeTotal: number = Math.max(1, totalPlayerCount);
    bb.playerCavalryRatio = playerCavCount / safeTotal;
    bb.playerRangedRatio = playerRangedCount / safeTotal;
    bb.playerHeavyArmorRatio = playerHeavyArmorCount / safeTotal;

    // 3. 扫描地形区（河流浅滩、高地/石桥刺猬锚点、密林伏击圈）
    this.scanTerrainFeatures(world, bb);

    // 4. 检测玩家落单野外工兵（奇袭断粮目标）与敌营被偷袭态势（本阵警钟）
    this.scanLogisticsAndCampSecurity(world, bb);

    // 5. 分析玩家主帅单骑风筝 vs 孤身残血可斩首 vs 高地单骑诱敌
    this.scanPlayerHeroThreat(world, bb);
  }

  /**
   * 扫描河流渡口、制高点/桥头锚点与密林伏击区
   */
  private scanTerrainFeatures(world: BattleWorldReadonlyView, bb: TacticalBlackboard): void {
    bb.hasRiverFord = world.primaryTerrain === TerrainType.RIVER_FORD || bb.halfFordTargetSquadId >= 0;
    bb.riverCenterX = world.width * 0.5;
    bb.riverCenterY = world.height * 0.5;

    bb.hasHighGroundAnchor = false;
    bb.hasForestTrapZone = false;

    let bestHighScore: number = -1e9;
    let bestForestScore: number = -1e9;

    for (let i: number = 0; i < world.terrainZones.length; i++) {
      const z: TerrainZoneRect = world.terrainZones[i];
      const cx: number = z.x + z.width * 0.5;
      const cy: number = z.y + z.height * 0.5;

      if (z.terrain === TerrainType.RIVER_FORD) {
        bb.hasRiverFord = true;
        bb.riverCenterX = cx;
        bb.riverCenterY = cy;
      }

      if (z.terrain === TerrainType.HIGH_GROUND || z.terrain === TerrainType.BRIDGE_PASS || z.elevation >= 1) {
        if (z.terrain !== TerrainType.FORT_WALL) {
          const distToEnemyHome: number = Math.abs(cx - bb.enemyHomeX);
          // 优选位于己方半场至中线之间的高地/桥头
          if (distToEnemyHome <= world.width * 0.62) {
            const score: number = z.elevation * 200 - Math.abs(distToEnemyHome - world.width * 0.30);
            if (score > bestHighScore) {
              bestHighScore = score;
              bb.hasHighGroundAnchor = true;
              bb.highGroundX = cx;
              bb.highGroundY = cy;
            }
          }
        }
      }

      if (z.terrain === TerrainType.DENSE_FOREST) {
        const distToEnemyHome: number = Math.abs(cx - bb.enemyHomeX);
        if (distToEnemyHome <= world.width * 0.68) {
          const score: number = -Math.abs(distToEnemyHome - world.width * 0.34);
          if (score > bestForestScore) {
            bestForestScore = score;
            bb.hasForestTrapZone = true;
            bb.forestTrapX = cx;
            bb.forestTrapY = cy;
          }
        }
      }
    }

    if (!bb.hasHighGroundAnchor && (world.primaryTerrain === TerrainType.HIGH_GROUND || world.primaryTerrain === TerrainType.BRIDGE_PASS)) {
      bb.hasHighGroundAnchor = true;
      bb.highGroundX = bb.enemyHomeX + bb.forwardDirX * (world.width * 0.28);
      bb.highGroundY = world.height * 0.5;
    }

    if (!bb.hasForestTrapZone && world.primaryTerrain === TerrainType.DENSE_FOREST) {
      bb.hasForestTrapZone = true;
      bb.forestTrapX = bb.enemyHomeX + bb.forwardDirX * (world.width * 0.30);
      bb.forestTrapY = world.height * 0.36;
    }
  }

  /**
   * 检测玩家无护卫野外工兵（奇袭断粮）与敌方大营遭玩家轻骑偷家（自动鸣钟）
   */
  private scanLogisticsAndCampSecurity(world: BattleWorldReadonlyView, bb: TacticalBlackboard): void {
    bb.exposedPlayerSapperFound = false;
    bb.enemyCampUnderRaid = false;

    // A. 检查玩家落单工兵分队
    for (let i: number = 0; i < world.squads.length; i++) {
      const sq: SquadRuntimeState = world.squads[i];
      if (sq.side !== BattleSide.PLAYER || sq.aliveCount <= 0 || sq.isRouting) {
        continue;
      }
      if (sq.primaryUnitType === UnitTypeId.SAPPER || sq.corpsRole === ArmyCorpsRole.SUPPLY_ESCORT) {
        if (!this.isPlayerSquadDetected(world, sq)) {
          continue;
        }
        // 判断附近 340px 是否有玩家主力作战编队贴身护卫，且不在玩家本阵 360px 围栏内
        const distFromPlayerCampSq: number = distSq(sq.centerX, sq.centerY, bb.playerHomeX, bb.playerHomeY);
        if (distFromPlayerCampSq > 360 * 360 && !this.hasNearbyPlayerCombatEscort(world, sq.centerX, sq.centerY, sq.squadId)) {
          bb.exposedPlayerSapperFound = true;
          bb.exposedSapperX = sq.centerX;
          bb.exposedSapperY = sq.centerY;
          break;
        }
      }
    }

    // 若未从分队检出，再扫描野外资源点旁孤立采集的玩家工兵实体
    if (!bb.exposedPlayerSapperFound) {
      for (let i: number = 0; i < world.soldiers.length; i++) {
        const s: SoldierRuntimeEntity = world.soldiers[i];
        if (!s.active || s.side !== BattleSide.PLAYER || s.unitType !== UnitTypeId.SAPPER || !s.visibleToEnemy) {
          continue;
        }
        if (distSq(s.x, s.y, bb.playerHomeX, bb.playerHomeY) > 360 * 360) {
          if (!this.hasNearbyPlayerCombatEscort(world, s.x, s.y, s.squadId)) {
            bb.exposedPlayerSapperFound = true;
            bb.exposedSapperX = s.x;
            bb.exposedSapperY = s.y;
            break;
          }
        }
      }
    }

    // B. 检测玩家轻骑/突袭队或主帅是否逼近敌军本阵大营偷家（含防抖迟滞半径）
    const raidTriggerRadius: number = this.garrisonBellActiveState ? 700 : 580;
    const raidTriggerRadiusSq: number = raidTriggerRadius * raidTriggerRadius;

    for (let i: number = 0; i < world.squads.length; i++) {
      const sq: SquadRuntimeState = world.squads[i];
      if (sq.side !== BattleSide.PLAYER || sq.aliveCount <= 0 || sq.isRouting) {
        continue;
      }
      if (distSq(sq.centerX, sq.centerY, bb.enemyHomeX, bb.enemyHomeY) <= raidTriggerRadiusSq) {
        bb.enemyCampUnderRaid = true;
        bb.raiderThreatX = sq.centerX;
        bb.raiderThreatY = sq.centerY;
        return;
      }
    }

    for (let i: number = 0; i < world.soldiers.length; i++) {
      const s: SoldierRuntimeEntity = world.soldiers[i];
      if (!s.active || s.side !== BattleSide.PLAYER) {
        continue;
      }
      if (distSq(s.x, s.y, bb.enemyHomeX, bb.enemyHomeY) <= raidTriggerRadiusSq) {
        bb.enemyCampUnderRaid = true;
        bb.raiderThreatX = s.x;
        bb.raiderThreatY = s.y;
        return;
      }
    }

    const ph: CommanderHeroRuntime = world.playerHero;
    if (
      (ph.vitalState === HeroVitalState.HEALTHY_ACTIVE || ph.vitalState === HeroVitalState.WOUNDED_WEAKENED) &&
      distSq(ph.x, ph.y, bb.enemyHomeX, bb.enemyHomeY) <= raidTriggerRadiusSq
    ) {
      bb.enemyCampUnderRaid = true;
      bb.raiderThreatX = ph.x;
      bb.raiderThreatY = ph.y;
    }
  }

  private hasNearbyPlayerCombatEscort(
    world: BattleWorldReadonlyView,
    x: number,
    y: number,
    ignoreSquadId: number
  ): boolean {
    for (let i: number = 0; i < world.squads.length; i++) {
      const sq: SquadRuntimeState = world.squads[i];
      if (
        sq.side === BattleSide.PLAYER &&
        sq.aliveCount > 0 &&
        !sq.isRouting &&
        sq.squadId !== ignoreSquadId &&
        sq.primaryUnitType !== UnitTypeId.SAPPER
      ) {
        if (distSq(sq.centerX, sq.centerY, x, y) <= 340 * 340) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 评估玩家主帅态势：单骑远射风筝 vs 孤身深入残血（HP < 45%）可合围斩首 vs 单骑勾引高地
   */
  private scanPlayerHeroThreat(world: BattleWorldReadonlyView, bb: TacticalBlackboard): void {
    bb.playerHeroKitingSolo = false;
    bb.playerHeroDecapitable = false;
    bb.playerBaitingHighGround = false;

    const ph: CommanderHeroRuntime = world.playerHero;
    const heroActive: boolean =
      ph.maxHp > 0 &&
      ph.hp > 0 &&
      (ph.vitalState === HeroVitalState.HEALTHY_ACTIVE || ph.vitalState === HeroVitalState.WOUNDED_WEAKENED);

    if (heroActive) {
      let minFriendDistSq: number = 1e12;
      for (let i: number = 0; i < world.squads.length; i++) {
        const sq: SquadRuntimeState = world.squads[i];
        if (sq.side === BattleSide.PLAYER && sq.aliveCount > 0 && !sq.isRouting) {
          const d2: number = distSq(ph.x, ph.y, sq.centerX, sq.centerY);
          if (d2 < minFriendDistSq) {
            minFriendDistSq = d2;
          }
        }
      }

      let minEnemyDistSq: number = 1e12;
      for (let i: number = 0; i < world.squads.length; i++) {
        const sq: SquadRuntimeState = world.squads[i];
        if (sq.side === BattleSide.ENEMY && sq.aliveCount > 0 && !sq.isRouting) {
          const d2: number = distSq(ph.x, ph.y, sq.centerX, sq.centerY);
          if (d2 < minEnemyDistSq) {
            minEnemyDistSq = d2;
          }
        }
      }

      const hpRatio: number = ph.hp / ph.maxHp;
      const deepIntoEnemyHalf: boolean = Math.abs(ph.x - bb.enemyHomeX) < world.width * 0.48;
      const isolatedFromPlayerArmy: boolean = minFriendDistSq >= 340 * 340;
      const soloAheadForKiting: boolean = minFriendDistSq >= 240 * 240 && minEnemyDistSq <= 680 * 680;

      // 1) 玩家主帅孤身深入且 HP < 45% -> 斩首围猎！
      if ((isolatedFromPlayerArmy || deepIntoEnemyHalf) && minFriendDistSq >= 280 * 280 && hpRatio < 0.45 && minEnemyDistSq <= 980 * 980) {
        bb.playerHeroDecapitable = true;
      } else if (
        soloAheadForKiting &&
        (ph.activeWeapon === HeroWeaponType.HEAVY_WARBOW || ph.remainingArrows > 0 || minEnemyDistSq <= 540 * 540)
      ) {
        // 2) 玩家主帅单骑在阵前远射/游走风筝 -> 仅派 1 支机动队驱离！
        bb.playerHeroKitingSolo = true;
      }
    }

    // 3) 检测高地前是否有单骑（主帅或单支轻骑）孤军勾引，而玩家主力仍在远处
    if (bb.hasHighGroundAnchor) {
      if (bb.playerHeroKitingSolo) {
        bb.playerBaitingHighGround = true;
      } else {
        let nearHighSquads: number = 0;
        let farMainSquads: number = 0;
        for (let i: number = 0; i < world.squads.length; i++) {
          const sq: SquadRuntimeState = world.squads[i];
          if (sq.side === BattleSide.PLAYER && sq.aliveCount > 0 && !sq.isRouting) {
            const d2: number = distSq(sq.centerX, sq.centerY, bb.highGroundX, bb.highGroundY);
            if (d2 <= 560 * 560) {
              nearHighSquads += 1;
            } else {
              farMainSquads += 1;
            }
          }
        }
        if (nearHighSquads === 1 && farMainSquads >= 2) {
          bb.playerBaitingHighGround = true;
        }
      }
    }
  }

  /**
   * 计算本阵警钟状态翻转信号：遭偷家时自动敲响保护工兵，危机解除后复工
   */
  private computeGarrisonBellToggle(underRaid: boolean): boolean {
    if (underRaid !== this.garrisonBellActiveState) {
      this.garrisonBellActiveState = underRaid;
      return true;
    }
    return false;
  }

  /**
   * 生成两翼绕后/奇袭三点弧线航点，确保绕开正面枪盾交战区 >= 220px
   */
  private buildCorridorFlankWaypoints(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    squad: SquadRuntimeState,
    useNorthCorridor: boolean,
    destX: number,
    destY: number
  ): Point2D[] {
    const corridorY: number = useNorthCorridor
      ? clampCoord(world.height * 0.14, 150, 520)
      : clampCoord(world.height * 0.86, world.height - 520, world.height - 150);

    const wp0X: number = clampCoord(squad.centerX + bb.forwardDirX * 280, 90, world.width - 90);
    const wp1X: number = clampCoord(bb.playerFrontX + bb.forwardDirX * 300, 90, world.width - 90);
    const wp2X: number = clampCoord(destX, 90, world.width - 90);
    const wp2Y: number = clampCoord(destY, 90, world.height - 90);

    const waypoints: Point2D[] = [
      { x: wp0X, y: corridorY },
      { x: wp1X, y: corridorY },
      { x: wp2X, y: wp2Y }
    ];
    return waypoints;
  }

  private toCommandWithWaypoints(
    squadId: number,
    formation: FormationType,
    order: TacticalOrder,
    waypoints: Point2D[]
  ): SquadCommandRequest {
    const xs: number[] = [];
    const ys: number[] = [];
    for (let i: number = 0; i < waypoints.length; i++) {
      xs.push(waypoints[i].x);
      ys.push(waypoints[i].y);
    }
    const lastIdx: number = waypoints.length - 1;
    return {
      squadIds: [squadId],
      formation: formation,
      order: order,
      targetX: waypoints[lastIdx].x,
      targetY: waypoints[lastIdx].y,
      customWaypointsX: xs,
      customWaypointsY: ys
    };
  }

  /**
   * 指挥瘫痪期保底指令（保持原阵型与当前位置防卫，绝不变阵或投入总预备队）
   */
  private buildParalyzedHoldCommands(enemySquads: SquadRuntimeState[]): SquadCommandRequest[] {
    const cmds: SquadCommandRequest[] = [];
    for (let i: number = 0; i < enemySquads.length; i++) {
      const sq: SquadRuntimeState = enemySquads[i];
      if (sq.isRouting) {
        continue;
      }
      cmds.push({
        squadIds: [sq.squadId],
        formation: sq.formation,
        order: TacticalOrder.HOLD_GROUND,
        targetX: sq.centerX,
        targetY: sq.centerY
      });
    }
    return cmds;
  }

  // ==================== 战术 7A：AI 攻城三段式状态机 ====================

  private executeSiegeAssaultFSM(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    enemySquads: SquadRuntimeState[],
    playerSquads: SquadRuntimeState[],
    recruitRequests: AiRecruitRequest[],
    toggleBell: boolean
  ): AiBattleDecisionBatch {
    let breachedStruct: FortStructureEntity | null = null;
    let mainGate: FortStructureEntity | null = null;
    let activeTower: FortStructureEntity | null = null;
    const wallSegments: FortStructureEntity[] = [];
    let minFortHpRatio: number = 1.0;

    for (let i: number = 0; i < world.structures.length; i++) {
      const st: FortStructureEntity = world.structures[i];
      if (st.side !== BattleSide.PLAYER) {
        continue;
      }
      if (st.kind === 'gate' || st.kind === 'wall_segment') {
        const ratio: number = st.maxHp > 0 ? st.hp / st.maxHp : 0;
        if (ratio < minFortHpRatio) {
          minFortHpRatio = ratio;
        }
        if (st.isBreached || st.hp <= 0) {
          if (breachedStruct === null || st.kind === 'gate') {
            breachedStruct = st;
          }
        }
        if (st.kind === 'gate' && mainGate === null) {
          mainGate = st;
        } else if (st.kind === 'wall_segment') {
          wallSegments.push(st);
        }
      } else if (st.kind === 'arrow_tower' && !st.isBreached && st.hp > 0) {
        if (activeTower === null || st.hp < activeTower.hp) {
          activeTower = st;
        }
      }
    }

    let hasArtillerySquad: boolean = false;
    for (let i: number = 0; i < enemySquads.length; i++) {
      const sq: SquadRuntimeState = enemySquads[i];
      if (
        !sq.isRouting &&
        (sq.primaryUnitType === UnitTypeId.TREBUCHET || sq.primaryUnitType === UnitTypeId.BALLISTA)
      ) {
        hasArtillerySquad = true;
        break;
      }
    }

    // 三阶段判定：
    // Phase 3：任意城门或城墙已轰塌破口 -> 投入重骑/巨熊总预备队突入瓮城
    // Phase 1：城墙未破、存在攻城重炮且箭塔尚存或墙门耐久 > 65% -> 炮火拆塔/墙准备期
    // Phase 2：箭塔已拔或墙体受损 <= 65% 或无重炮 -> 刀盾掩护多点登城 + 巨斧破门期
    let phase: SiegeTacticalPhase = SiegeTacticalPhase.ASSAULT_PHASE_2_ESCALADE_BATTER;
    if (breachedStruct !== null) {
      phase = SiegeTacticalPhase.ASSAULT_PHASE_3_BREACH_COMMIT;
    } else if (hasArtillerySquad && (activeTower !== null || minFortHpRatio > 0.65)) {
      phase = SiegeTacticalPhase.ASSAULT_PHASE_1_ARTILLERY;
    }

    const primaryFortX: number =
      breachedStruct !== null
        ? breachedStruct.x + breachedStruct.width * 0.5
        : mainGate !== null
          ? mainGate.x + mainGate.width * 0.5
          : wallSegments.length > 0
            ? wallSegments[0].x + wallSegments[0].width * 0.5
            : bb.playerHomeX - bb.forwardDirX * 320;
    const primaryFortY: number =
      breachedStruct !== null
        ? breachedStruct.y + breachedStruct.height * 0.5
        : mainGate !== null
          ? mainGate.y + mainGate.height * 0.5
          : wallSegments.length > 0
            ? wallSegments[0].y + wallSegments[0].height * 0.5
            : world.height * 0.5;

    const commands: SquadCommandRequest[] = [];
    let wallAssignIdx: number = 0;

    for (let i: number = 0; i < enemySquads.length; i++) {
      const sq: SquadRuntimeState = enemySquads[i];
      if (sq.isRouting) {
        continue;
      }
      const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
      const category: UnitCategory = stats !== undefined ? stats.category : UnitCategory.INFANTRY;

      if (phase === SiegeTacticalPhase.ASSAULT_PHASE_1_ARTILLERY) {
        const artilleryTargetX: number =
          activeTower !== null ? activeTower.x + activeTower.width * 0.5 : primaryFortX;
        const artilleryTargetY: number =
          activeTower !== null ? activeTower.y + activeTower.height * 0.5 : primaryFortY;
        const standOffX: number = clampCoord(artilleryTargetX - bb.forwardDirX * 620, 120, world.width - 120);
        const guardLineX: number = clampCoord(artilleryTargetX - bb.forwardDirX * 480, 120, world.width - 120);

        if (category === UnitCategory.SIEGE || sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY) {
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.ECHELON_LINE,
            order: TacticalOrder.ADVANCE,
            targetX: artilleryTargetX,
            targetY: artilleryTargetY
          });
        } else if (sq.corpsRole === ArmyCorpsRole.REAR_RESERVE) {
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.PHALANX_RECT,
            order: TacticalOrder.HOLD_GROUND,
            targetX: clampCoord(standOffX - bb.forwardDirX * 260, 120, world.width - 120),
            targetY: world.height * 0.5
          });
        } else {
          // 重步与两翼护住投石车/连弩车外围防城内轻骑突袭
          const laneOffsetY: number =
            sq.corpsRole === ArmyCorpsRole.LEFT_WING ? -220 : sq.corpsRole === ArmyCorpsRole.RIGHT_WING ? 220 : 0;
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.PHALANX_RECT,
            order: TacticalOrder.HOLD_GROUND,
            targetX: guardLineX,
            targetY: clampCoord(artilleryTargetY + laneOffsetY, 150, world.height - 150)
          });
        }
      } else if (phase === SiegeTacticalPhase.ASSAULT_PHASE_2_ESCALADE_BATTER) {
        if (sq.corpsRole === ArmyCorpsRole.REAR_RESERVE) {
          // 破门前扣留重骑/巨熊总预备队于安全待机位，严禁撞墙白送箭塔
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.PHALANX_RECT,
            order: TacticalOrder.HOLD_GROUND,
            targetX: clampCoord(primaryFortX - bb.forwardDirX * 560, 120, world.width - 120),
            targetY: primaryFortY
          });
        } else if (
          sq.primaryUnitType === UnitTypeId.GREAT_AXEMAN ||
          category === UnitCategory.SHOCK
        ) {
          // 巨斧破甲兵集火猛劈正门
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.WEDGE_CHARGE,
            order: TacticalOrder.ALL_OUT_CHARGE,
            targetX: primaryFortX,
            targetY: primaryFortY
          });
        } else if (category === UnitCategory.SIEGE || category === UnitCategory.RANGED) {
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.ECHELON_LINE,
            order: TacticalOrder.ADVANCE,
            targetX: primaryFortX,
            targetY: primaryFortY
          });
        } else if (category === UnitCategory.CAVALRY) {
          // 骑兵无法登墙，在外侧警戒护翼待破门
          const wingY: number = sq.corpsRole === ArmyCorpsRole.LEFT_WING ? 340 : world.height - 340;
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.WEDGE_CHARGE,
            order: TacticalOrder.HOLD_GROUND,
            targetX: clampCoord(primaryFortX - bb.forwardDirX * 420, 120, world.width - 120),
            targetY: wingY
          });
        } else {
          // 刀盾步兵举盾（PHALANX_RECT）掩护工兵分多点架设左右两翼云梯登城
          let climbX: number = primaryFortX;
          let climbY: number = primaryFortY + (wallAssignIdx % 2 === 0 ? -280 : 280);
          if (wallSegments.length > 0) {
            const seg: FortStructureEntity = wallSegments[wallAssignIdx % wallSegments.length];
            climbX = seg.x + seg.width * 0.5;
            climbY = seg.y + seg.height * 0.5;
          }
          wallAssignIdx += 1;
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.PHALANX_RECT,
            order: TacticalOrder.ADVANCE,
            targetX: climbX,
            targetY: clampCoord(climbY, 140, world.height - 140)
          });
        }
      } else {
        // Phase 3：城门/墙段告破！总预备队重骑/巨熊锥形阵全力突入瓮城直捣帅府
        const innerTargetX: number = clampCoord(bb.playerHomeX, 100, world.width - 100);
        const innerTargetY: number = clampCoord(bb.playerHomeY, 140, world.height - 140);

        if (category === UnitCategory.SIEGE || category === UnitCategory.RANGED) {
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.ECHELON_LINE,
            order: TacticalOrder.ADVANCE,
            targetX: primaryFortX,
            targetY: primaryFortY
          });
        } else if (sq.corpsRole === ArmyCorpsRole.SUPPLY_ESCORT && sq.primaryUnitType === UnitTypeId.SAPPER) {
          commands.push({
            squadIds: [sq.squadId],
            formation: FormationType.CIRCLE_DEFENSE,
            order: TacticalOrder.HOLD_GROUND,
            targetX: bb.enemyHomeX,
            targetY: bb.enemyHomeY
          });
        } else {
          const breachWaypoints: Point2D[] = [
            { x: primaryFortX, y: primaryFortY },
            { x: clampCoord(primaryFortX + bb.forwardDirX * 180, 90, world.width - 90), y: primaryFortY },
            { x: innerTargetX, y: innerTargetY }
          ];
          commands.push(
            this.toCommandWithWaypoints(
              sq.squadId,
              FormationType.WEDGE_CHARGE,
              TacticalOrder.ALL_OUT_CHARGE,
              breachWaypoints
            )
          );
        }
      }
    }

    const heroPos: Point2D = this.computeEnemyHeroPosition(world, bb, phase);
    const triggerWarCry: boolean = this.shouldEnemyHeroWarCry(world, enemySquads, playerSquads, phase);

    return {
      squadCommands: commands,
      recruitRequests: recruitRequests,
      toggleGarrisonBell: toggleBell,
      enemyHeroTargetX: heroPos.x,
      enemyHeroTargetY: heroPos.y,
      enemyHeroTriggerWarCry: triggerWarCry,
      activeDoctrine: TacticalDoctrineId.SIEGE_THREE_STAGE_ASSAULT,
      siegePhase: phase
    };
  }

  // ==================== 战术 7B：AI 守城三段式状态机 ====================

  private executeSiegeDefenseFSM(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    enemySquads: SquadRuntimeState[],
    playerSquads: SquadRuntimeState[],
    recruitRequests: AiRecruitRequest[],
    toggleBell: boolean
  ): AiBattleDecisionBatch {
    let threatenedGate: FortStructureEntity | null = null;
    let mainGate: FortStructureEntity | null = null;
    let minGateHpRatio: number = 1.0;

    for (let i: number = 0; i < world.structures.length; i++) {
      const st: FortStructureEntity = world.structures[i];
      if (st.side !== BattleSide.ENEMY) {
        continue;
      }
      if (st.kind === 'gate' || st.kind === 'wall_segment') {
        if (mainGate === null || st.kind === 'gate') {
          mainGate = st;
        }
        const ratio: number = st.maxHp > 0 ? st.hp / st.maxHp : 0;
        if (ratio < minGateHpRatio) {
          minGateHpRatio = ratio;
        }
        if (st.isBreached || ratio < 0.30) {
          if (threatenedGate === null || st.kind === 'gate') {
            threatenedGate = st;
          }
        }
      }
    }

    const fortLineX: number =
      threatenedGate !== null
        ? threatenedGate.x + threatenedGate.width * 0.5
        : mainGate !== null
          ? mainGate.x + mainGate.width * 0.5
          : bb.enemyHomeX + bb.forwardDirX * 360;
    const fortLineY: number =
      threatenedGate !== null
        ? threatenedGate.y + threatenedGate.height * 0.5
        : mainGate !== null
          ? mainGate.y + mainGate.height * 0.5
          : world.height * 0.5;

    // 检索城下推云梯工兵/无盾巨斧兵（Phase 1 高优集火目标）以及后方空虚的攻城投石车（Phase 3 侧门奇袭目标）
    let prioritySnipeTarget: SquadRuntimeState | null = null;
    let bestSnipeScore: number = -1e9;
    let exposedSiegeEngine: SquadRuntimeState | null = null;
    let allPlayerMeleePressedAtWall: boolean = false;
    let playerMeleeSquadCount: number = 0;
    let playerMeleeNearWallCount: number = 0;

    for (let i: number = 0; i < playerSquads.length; i++) {
      const psq: SquadRuntimeState = playerSquads[i];
      const stats: UnitStaticStats | undefined = getUnitConfigById(psq.primaryUnitType);
      const cat: UnitCategory = stats !== undefined ? stats.category : UnitCategory.INFANTRY;

      if (
        cat === UnitCategory.INFANTRY ||
        cat === UnitCategory.POLEARM ||
        cat === UnitCategory.SHOCK ||
        cat === UnitCategory.CAVALRY
      ) {
        playerMeleeSquadCount += 1;
        if (Math.abs(psq.centerX - fortLineX) <= 360) {
          playerMeleeNearWallCount += 1;
        }
      }

      // 城头集火评分：工兵（云梯手）与重型巨斧兵最高优
      let snipeScore: number = -Math.abs(psq.centerX - fortLineX) * 0.1;
      if (psq.primaryUnitType === UnitTypeId.SAPPER) {
        snipeScore += 180;
      } else if (psq.primaryUnitType === UnitTypeId.GREAT_AXEMAN || cat === UnitCategory.SHOCK) {
        snipeScore += 155;
      } else if (stats !== undefined && stats.shieldRangedBlock <= 0.1) {
        snipeScore += 80;
      }
      if (snipeScore > bestSnipeScore) {
        bestSnipeScore = snipeScore;
        prioritySnipeTarget = psq;
      }

      // 检索玩家后方攻城器械（投石车/连弩车）是否与前压步兵脱节空虚
      if (psq.primaryUnitType === UnitTypeId.TREBUCHET || psq.primaryUnitType === UnitTypeId.BALLISTA) {
        if (!this.hasNearbyPlayerCombatEscort(world, psq.centerX, psq.centerY, psq.squadId)) {
          exposedSiegeEngine = psq;
        }
      }
    }

    if (playerMeleeSquadCount > 0 && playerMeleeNearWallCount === playerMeleeSquadCount) {
      allPlayerMeleePressedAtWall = true;
    }

    // 挑选可从侧门出击的 1 支游骑兵/机动编队
    let sallyCavalrySquad: SquadRuntimeState | null = null;
    let bestSallyMobility: number = 65;
    for (let i: number = 0; i < enemySquads.length; i++) {
      const esq: SquadRuntimeState = enemySquads[i];
      if (esq.isRouting || esq.corpsRole === ArmyCorpsRole.VANGUARD_CENTER) {
        continue;
      }
      const mob: number = getSquadMobilityScore(esq);
      if (mob > bestSallyMobility) {
        bestSallyMobility = mob;
        sallyCavalrySquad = esq;
      }
    }

    // 检查门洞是否已有重步/长枪就位堵门
    const plugX: number = clampCoord(fortLineX - bb.forwardDirX * 55, 80, world.width - 80);
    const plugY: number = fortLineY;
    let gateAlreadyPlugged: boolean = false;
    if (threatenedGate !== null) {
      for (let i: number = 0; i < enemySquads.length; i++) {
        const esq: SquadRuntimeState = enemySquads[i];
        if (
          !esq.isRouting &&
          (esq.formation === FormationType.CIRCLE_DEFENSE || esq.formation === FormationType.PHALANX_RECT) &&
          distSq(esq.centerX, esq.centerY, plugX, plugY) <= 95 * 95
        ) {
          gateAlreadyPlugged = true;
          break;
        }
      }
    }

    const canTriggerSally: boolean =
      allPlayerMeleePressedAtWall && exposedSiegeEngine !== null && sallyCavalrySquad !== null;

    let phase: SiegeTacticalPhase = SiegeTacticalPhase.DEFENSE_PHASE_1_WALL_SNIPE;
    if (threatenedGate !== null && (!canTriggerSally || !gateAlreadyPlugged)) {
      phase = SiegeTacticalPhase.DEFENSE_PHASE_2_PLUG_GATE;
    } else if (canTriggerSally) {
      phase = SiegeTacticalPhase.DEFENSE_PHASE_3_SALLY_BURN_SIEGE;
    }

    const snipeX: number = prioritySnipeTarget !== null ? prioritySnipeTarget.centerX : bb.playerFrontX;
    const snipeY: number = prioritySnipeTarget !== null ? prioritySnipeTarget.centerY : bb.playerFrontY;
    const commands: SquadCommandRequest[] = [];

    for (let i: number = 0; i < enemySquads.length; i++) {
      const sq: SquadRuntimeState = enemySquads[i];
      if (sq.isRouting) {
        continue;
      }
      const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
      const category: UnitCategory = stats !== undefined ? stats.category : UnitCategory.INFANTRY;

      // 侧门轻骑绕后烧投石车（仅限选定的 1 支机动队；即使正门危急，只要另有步兵堵门，轻骑仍可出侧门拔除敌投石车根源）
      if (
        canTriggerSally &&
        sallyCavalrySquad !== null &&
        exposedSiegeEngine !== null &&
        sq.squadId === sallyCavalrySquad.squadId &&
        (phase === SiegeTacticalPhase.DEFENSE_PHASE_3_SALLY_BURN_SIEGE || enemySquads.length >= 2)
      ) {
        const useNorthGate: boolean = exposedSiegeEngine.centerY <= world.height * 0.5;
        const sideGateY: number = useNorthGate ? 200 : world.height - 200;
        const sallyWaypoints: Point2D[] = [
          { x: fortLineX, y: sideGateY },
          { x: clampCoord(exposedSiegeEngine.centerX, 90, world.width - 90), y: sideGateY },
          { x: exposedSiegeEngine.centerX, y: exposedSiegeEngine.centerY }
        ];
        commands.push(
          this.toCommandWithWaypoints(
            sq.squadId,
            FormationType.WEDGE_CHARGE,
            TacticalOrder.FLANK,
            sallyWaypoints
          )
        );
        continue;
      }

      if (category === UnitCategory.RANGED || category === UnitCategory.SIEGE || sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY) {
        // 城头远程集火工兵与无盾巨斧兵
        commands.push({
          squadIds: [sq.squadId],
          formation: FormationType.ECHELON_LINE,
          order: TacticalOrder.HOLD_GROUND,
          targetX: snipeX,
          targetY: snipeY
        });
      } else if (threatenedGate !== null) {
        // 城门 HP < 30% 或已破：调长枪与重步在门洞内结圆阵/方阵死堵缺口
        const plugFormation: FormationType =
          sq.primaryUnitType === UnitTypeId.PIKEMAN || sq.corpsRole === ArmyCorpsRole.VANGUARD_CENTER
            ? FormationType.CIRCLE_DEFENSE
            : FormationType.PHALANX_RECT;
        commands.push({
          squadIds: [sq.squadId],
          formation: plugFormation,
          order: TacticalOrder.HOLD_GROUND,
          targetX: plugX,
          targetY: plugY
        });
      } else {
        // 城门完好时城内预备待命护门
        commands.push({
          squadIds: [sq.squadId],
          formation: FormationType.PHALANX_RECT,
          order: TacticalOrder.HOLD_GROUND,
          targetX: plugX,
          targetY: plugY
        });
      }
    }

    const heroPos: Point2D = this.computeEnemyHeroPosition(world, bb, phase);
    const triggerWarCry: boolean = this.shouldEnemyHeroWarCry(world, enemySquads, playerSquads, phase);

    return {
      squadCommands: commands,
      recruitRequests: recruitRequests,
      toggleGarrisonBell: toggleBell,
      enemyHeroTargetX: heroPos.x,
      enemyHeroTargetY: heroPos.y,
      enemyHeroTriggerWarCry: triggerWarCry,
      activeDoctrine: TacticalDoctrineId.SIEGE_THREE_STAGE_DEFENSE,
      siegePhase: phase
    };
  }

  // ==================== 野战多军团七大高阶冷兵器战术指挥器 ====================

  private executeFieldBattleCommander(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    enemySquads: SquadRuntimeState[],
    playerSquads: SquadRuntimeState[],
    recruitRequests: AiRecruitRequest[],
    toggleBell: boolean
  ): AiBattleDecisionBatch {
    const commands: SquadCommandRequest[] = [];
    const assignedSquadIds: number[] = [];

    // 1. 最高优机会窗口：玩家主帅孤身深入且 HP < 45% -> 调集附近破甲精锐合围斩首！
    if (bb.playerHeroDecapitable) {
      let huntersAssigned: number = 0;
      for (let i: number = 0; i < enemySquads.length; i++) {
        const sq: SquadRuntimeState = enemySquads[i];
        if (sq.isRouting || sq.corpsRole === ArmyCorpsRole.SUPPLY_ESCORT) {
          continue;
        }
        const d2: number = distSq(sq.centerX, sq.centerY, world.playerHero.x, world.playerHero.y);
        if (isArmorPiercingOrEliteSquad(sq) && d2 <= 1050 * 1050) {
          const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
          const isRanged: boolean =
            stats !== undefined && (stats.category === UnitCategory.RANGED || stats.category === UnitCategory.SIEGE);
          commands.push({
            squadIds: [sq.squadId],
            formation: isRanged ? FormationType.ECHELON_LINE : FormationType.WEDGE_CHARGE,
            order: isRanged ? TacticalOrder.ADVANCE : TacticalOrder.PINCER_ENCIRCLE,
            targetX: world.playerHero.x,
            targetY: world.playerHero.y
          });
          assignedSquadIds.push(sq.squadId);
          huntersAssigned += 1;
        }
      }
      if (huntersAssigned === 0 && enemySquads.length > 0) {
        const fallbackSq: SquadRuntimeState = enemySquads[0];
        commands.push({
          squadIds: [fallbackSq.squadId],
          formation: FormationType.WEDGE_CHARGE,
          order: TacticalOrder.PINCER_ENCIRCLE,
          targetX: world.playerHero.x,
          targetY: world.playerHero.y
        });
        assignedSquadIds.push(fallbackSq.squadId);
      }
    }

    // 2. 反风筝硬性纪律：玩家主帅单骑远射骚扰时，严格仅分派 1 支真正高速机动队驱离（高地重步长枪绝不下山傻追！）
    let antiKiteActive: boolean = false;
    const holdingHighGroundFortress: boolean =
      bb.hasHighGroundAnchor &&
      (bb.personality === AiPersonality.FORTRESS_COUNTER || bb.enemyCombatPower < bb.playerCombatPower * 0.85) &&
      world.hud.enemyRationStage !== BattlefieldRationStage.STARVING;

    if (!bb.playerHeroDecapitable && bb.playerHeroKitingSolo) {
      let bestChaser: SquadRuntimeState | null = null;
      let bestChaserScore: number = -1;
      for (let i: number = 0; i < enemySquads.length; i++) {
        const sq: SquadRuntimeState = enemySquads[i];
        if (
          sq.isRouting ||
          sq.corpsRole === ArmyCorpsRole.VANGUARD_CENTER ||
          sq.corpsRole === ArmyCorpsRole.REAR_RESERVE ||
          sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY ||
          sq.corpsRole === ArmyCorpsRole.SUPPLY_ESCORT
        ) {
          continue;
        }
        const st: UnitStaticStats | undefined = fastUnitStats(sq.primaryUnitType);
        const isFastPursuer: boolean =
          st !== undefined && (st.category === UnitCategory.CAVALRY || st.moveSpeed >= 75);
        // 据守高地时严禁派慢速重步/长枪下山追高移速主帅；平地亦优先高速轻骑
        if (holdingHighGroundFortress && !isFastPursuer) {
          continue;
        }
        const mob: number = getSquadMobilityScore(sq) + (isFastPursuer ? 60 : 0);
        if (mob > bestChaserScore) {
          bestChaserScore = mob;
          bestChaser = sq;
        }
      }
      // 若两翼均不存在，仅当存在纯骑兵独立分队时才派出 1 支，中军步兵绝不离阵
      if (bestChaser === null) {
        for (let i: number = 0; i < enemySquads.length; i++) {
          const sq: SquadRuntimeState = enemySquads[i];
          const stats: UnitStaticStats | undefined = fastUnitStats(sq.primaryUnitType);
          if (
            !sq.isRouting &&
            sq.corpsRole !== ArmyCorpsRole.REAR_RESERVE &&
            stats !== undefined &&
            stats.category === UnitCategory.CAVALRY
          ) {
            bestChaser = sq;
            break;
          }
        }
      }

      if (bestChaser !== null) {
        commands.push({
          squadIds: [bestChaser.squadId],
          formation: FormationType.WEDGE_CHARGE,
          order: TacticalOrder.FLANK,
          targetX: world.playerHero.x,
          targetY: world.playerHero.y
        });
        assignedSquadIds.push(bestChaser.squadId);
        antiKiteActive = true;
      }
    }

    // 3. 奇袭断粮（RAID_SUPPLY）：发现玩家落单野外工兵，或本军陷入【饥溃 STARVING】绝境急需劫掠玩家大营 150 应急军粮翻盘
    const needDesperateGrainPlunder: boolean =
      world.hud.enemyRationStage === BattlefieldRationStage.STARVING;
    if (bb.exposedPlayerSapperFound || needDesperateGrainPlunder) {
      const plunderX: number = bb.exposedPlayerSapperFound ? bb.exposedSapperX : bb.playerHomeX;
      const plunderY: number = bb.exposedPlayerSapperFound ? bb.exposedSapperY : bb.playerHomeY;
      let raider: SquadRuntimeState | null = null;
      let bestRaiderScore: number = 70;
      for (let i: number = 0; i < enemySquads.length; i++) {
        const sq: SquadRuntimeState = enemySquads[i];
        if (
          sq.isRouting ||
          this.isAlreadyAssigned(assignedSquadIds, sq.squadId) ||
          sq.corpsRole === ArmyCorpsRole.VANGUARD_CENTER ||
          sq.corpsRole === ArmyCorpsRole.REAR_RESERVE ||
          sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY
        ) {
          continue;
        }
        const mob: number = getSquadMobilityScore(sq);
        if (mob > bestRaiderScore) {
          bestRaiderScore = mob;
          raider = sq;
        }
      }
      if (raider !== null) {
        const useNorth: boolean = plunderY <= world.height * 0.5;
        const raidWaypoints: Point2D[] = this.buildCorridorFlankWaypoints(
          world,
          bb,
          raider,
          useNorth,
          plunderX,
          plunderY
        );
        commands.push(
          this.toCommandWithWaypoints(
            raider.squadId,
            FormationType.WEDGE_CHARGE,
            TacticalOrder.RAID_SUPPLY,
            raidWaypoints
          )
        );
        assignedSquadIds.push(raider.squadId);
      }
    }

    // 4. 判定当前主力作战教条（Doctrine）
    const activeDoctrine: TacticalDoctrineId = this.selectFieldDoctrine(world, bb, enemySquads, playerSquads, antiKiteActive);

    // 5. 为剩余全部建制军团（中军前锋、左右两翼、远程群、总预备队、护粮队）分配协同指令
    let unassignedWingCount: number = 0;
    for (let i: number = 0; i < enemySquads.length; i++) {
      const sq: SquadRuntimeState = enemySquads[i];
      if (
        !sq.isRouting &&
        !this.isAlreadyAssigned(assignedSquadIds, sq.squadId) &&
        (sq.corpsRole === ArmyCorpsRole.LEFT_WING || sq.corpsRole === ArmyCorpsRole.RIGHT_WING)
      ) {
        unassignedWingCount += 1;
      }
    }

    for (let i: number = 0; i < enemySquads.length; i++) {
      const sq: SquadRuntimeState = enemySquads[i];
      if (sq.isRouting || this.isAlreadyAssigned(assignedSquadIds, sq.squadId)) {
        continue;
      }

      // 5.1 辎重护粮队与本阵协防
      if (sq.corpsRole === ArmyCorpsRole.SUPPLY_ESCORT || sq.primaryUnitType === UnitTypeId.SAPPER) {
        commands.push(this.buildSupplyEscortCommand(world, bb, sq));
        continue;
      }

      // 5.2 总预备队严格扣留与阈值投入纪律（REAR_RESERVE）
      if (sq.corpsRole === ArmyCorpsRole.REAR_RESERVE) {
        commands.push(this.buildRearReserveCommand(world, bb, sq, enemySquads, playerSquads));
        continue;
      }

      // 5.3 按选定高阶战术分配前锋、两翼与远程攻城群
      if (activeDoctrine === TacticalDoctrineId.HALF_FORD_STRIKE) {
        commands.push(this.buildHalfFordStrikeCommand(world, bb, sq, playerSquads));
      } else if (activeDoctrine === TacticalDoctrineId.FORD_AMBUSH_WAIT) {
        commands.push(this.buildFordAmbushWaitCommand(world, bb, sq));
      } else if (activeDoctrine === TacticalDoctrineId.HIGH_GROUND_HEDGEHOG) {
        commands.push(this.buildHighGroundHedgehogCommand(world, bb, sq));
      } else if (activeDoctrine === TacticalDoctrineId.FEIGNED_RETREAT_LURE) {
        commands.push(this.buildFeignedRetreatLureCommand(world, bb, sq));
      } else if (activeDoctrine === TacticalDoctrineId.FOREST_TRAP_ENCIRCLE) {
        commands.push(this.buildForestTrapEncircleCommand(world, bb, sq));
      } else {
        // 标准王牌战术：正面佯攻牵制 + 南北走廊两翼钳形合围（兼容各势力性格微调）
        commands.push(this.buildPinningPincerCommand(world, bb, sq, playerSquads, unassignedWingCount >= 2));
      }
    }

    const finalDoctrineLabel: string = bb.playerHeroDecapitable
      ? TacticalDoctrineId.DECAPITATION_HUNT
      : antiKiteActive && activeDoctrine === TacticalDoctrineId.PINNING_PINCER_ENCIRCLE
        ? TacticalDoctrineId.ANTI_KITE_DETACH_ONE
        : activeDoctrine;

    const heroPos: Point2D = this.computeEnemyHeroPosition(world, bb, SiegeTacticalPhase.NONE);
    const triggerWarCry: boolean = this.shouldEnemyHeroWarCry(world, enemySquads, playerSquads, SiegeTacticalPhase.NONE);

    return {
      squadCommands: commands,
      recruitRequests: recruitRequests,
      toggleGarrisonBell: toggleBell,
      enemyHeroTargetX: heroPos.x,
      enemyHeroTargetY: heroPos.y,
      enemyHeroTriggerWarCry: triggerWarCry,
      activeDoctrine: finalDoctrineLabel,
      siegePhase: SiegeTacticalPhase.NONE
    };
  }

  /**
   * 依据黑板态势与 8 种性格选择主力高阶战术教条
   */
  private selectFieldDoctrine(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    enemySquads: SquadRuntimeState[],
    playerSquads: SquadRuntimeState[],
    antiKiteActive: boolean
  ): TacticalDoctrineId {
    // 优先级 1：渡河半渡而击（玩家涉水 30%~80% 首尾脱节时立即压岸齐射）
    if (bb.halfFordTargetSquadId >= 0) {
      return TacticalDoctrineId.HALF_FORD_STRIKE;
    }

    const isStarvingDesperate: boolean =
      world.hud.enemyRationStage === BattlefieldRationStage.STARVING;

    // 优先级 2：高地刺猬防反（铁鹰王国或守势占优高地/石桥，绝不盲追单骑诱饵；断粮饥溃期除外以防活活饿死）
    const prefersFortressHedgehog: boolean =
      !isStarvingDesperate &&
      bb.hasHighGroundAnchor &&
      (bb.personality === AiPersonality.FORTRESS_COUNTER ||
        bb.playerBaitingHighGround ||
        (bb.enemyCombatPower < bb.playerCombatPower * 0.85 &&
          bb.personality !== AiPersonality.ZEALOT_SWARM &&
          bb.personality !== AiPersonality.HONOR_BERSERK_BEAR));
    if (prefersFortressHedgehog) {
      return TacticalDoctrineId.HIGH_GROUND_HEDGEHOG;
    }

    // 优先级 3：诈败诱敌伏击（雾林猎手 / 苍狼汗国 / 伏击关卡）
    const isTrapperPersonality: boolean =
      bb.personality === AiPersonality.GUERRILLA_TRAPPER ||
      bb.personality === AiPersonality.NOMAD_OPPORTUNIST ||
      world.scenarioType === BattleScenarioType.AMBUSH;

    if (isTrapperPersonality && bb.hasForestTrapZone && !this.feignedRetreatCompleted) {
      let playerOverextendedIntoTrap: boolean = false;
      for (let i: number = 0; i < playerSquads.length; i++) {
        const psq: SquadRuntimeState = playerSquads[i];
        const d2ToTrap: number = distSq(psq.centerX, psq.centerY, bb.forestTrapX, bb.forestTrapY);
        const deepInsideTrap: boolean = d2ToTrap <= 240 * 240;
        const chargingNearTrap: boolean =
          psq.order === TacticalOrder.ALL_OUT_CHARGE && d2ToTrap <= 360 * 360;
        const separatedFromRear: boolean = Math.abs(psq.centerX - bb.playerRearX) >= 360;
        if (deepInsideTrap || chargingNearTrap || (psq.order === TacticalOrder.ALL_OUT_CHARGE && separatedFromRear)) {
          playerOverextendedIntoTrap = true;
          break;
        }
      }

      if (playerOverextendedIntoTrap) {
        this.feignedRetreatCompleted = true;
        return TacticalDoctrineId.FOREST_TRAP_ENCIRCLE;
      }

      // 前锋短暂接敌后启动诈败诱敌后撤
      const frontDist: number = Math.hypot(bb.enemyFrontX - bb.playerFrontX, bb.enemyFrontY - bb.playerFrontY);
      if (frontDist <= 380 || (this.feignedRetreatStartedAtSec >= 0 && bb.elapsedSec - this.feignedRetreatStartedAtSec <= 7.0)) {
        if (this.feignedRetreatStartedAtSec < 0) {
          this.feignedRetreatStartedAtSec = bb.elapsedSec;
        }
        return TacticalDoctrineId.FEIGNED_RETREAT_LURE;
      }
    }

    // 优先级 4：中央河流渡口潜伏待机（玩家正在向河岸靠近但尚未涉水过半，AI 按兵不动守东岸；饥溃期不干耗）
    if (!isStarvingDesperate && bb.hasRiverFord && bb.personality !== AiPersonality.ZEALOT_SWARM) {
      const playerOnOwnSideOfRiver: boolean =
        (bb.playerFrontX - bb.riverCenterX) * (-bb.forwardDirX) < 120;
      const enemyOnOwnSideOfRiver: boolean =
        (bb.enemyFrontX - bb.riverCenterX) * bb.forwardDirX < 140;
      if (playerOnOwnSideOfRiver && enemyOnOwnSideOfRiver) {
        return TacticalDoctrineId.FORD_AMBUSH_WAIT;
      }
    }

    if (antiKiteActive && playerSquads.length === 0) {
      return TacticalDoctrineId.ANTI_KITE_DETACH_ONE;
    }

    // 默认高阶协同：中军稳推吸火 + 南北双走廊钳形合围
    return TacticalDoctrineId.PINNING_PINCER_ENCIRCLE;
  }

  private buildSupplyEscortCommand(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    sq: SquadRuntimeState
  ): SquadCommandRequest {
    if (bb.enemyCampUnderRaid) {
      if (sq.primaryUnitType === UnitTypeId.SAPPER) {
        return {
          squadIds: [sq.squadId],
          formation: FormationType.CIRCLE_DEFENSE,
          order: TacticalOrder.RETREAT,
          targetX: bb.enemyHomeX,
          targetY: bb.enemyHomeY
        };
      }
      return {
        squadIds: [sq.squadId],
        formation: FormationType.PHALANX_RECT,
        order: TacticalOrder.ALL_OUT_CHARGE,
        targetX: bb.raiderThreatX,
        targetY: bb.raiderThreatY
      };
    }

    // 安全时派往本方半场最近的可用资源点护卫采集
    let bestNode: BattlefieldResourceNode | null = null;
    let bestScore: number = -1e9;
    const needGrainUrgently: boolean =
      world.hud.enemyRationStage !== BattlefieldRationStage.ABUNDANT;

    for (let i: number = 0; i < world.resourceNodes.length; i++) {
      const rn: BattlefieldResourceNode = world.resourceNodes[i];
      if (rn.remainingAmount <= 0) {
        continue;
      }
      let score: number = -Math.hypot(rn.x - bb.enemyHomeX, rn.y - bb.enemyHomeY);
      if (needGrainUrgently && rn.resourceKind === 'grain') {
        score += 900;
      } else if (bb.personality === AiPersonality.MERCHANT_PRAGMATIC && rn.resourceKind === 'gold') {
        score += 500;
      }
      if (score > bestScore) {
        bestScore = score;
        bestNode = rn;
      }
    }

    const targetX: number = bestNode !== null ? bestNode.x : clampCoord(bb.enemyHomeX + bb.forwardDirX * 220, 90, world.width - 90);
    const targetY: number = bestNode !== null ? bestNode.y : bb.enemyHomeY;
    return {
      squadIds: [sq.squadId],
      formation: FormationType.PHALANX_RECT,
      order: TacticalOrder.HOLD_GROUND,
      targetX: targetX,
      targetY: targetY
    };
  }

  /**
   * 总预备队（REAR_RESERVE）严格阈值控制：
   * 1) 己方前线/两翼出现士气 < 35 危急缺口 -> 立即投入堵漏；
   * 2) 敌方主力出现动摇（士气 < 40 / 溃逃 / 被钳形合围） -> 立即投入锥形冲锋一锤定音；
   * 3) 其余常规交战阶段 -> 严格扣留于前线后方 420px 原地待命！
   */
  private buildRearReserveCommand(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    reserveSq: SquadRuntimeState,
    enemySquads: SquadRuntimeState[],
    playerSquads: SquadRuntimeState[]
  ): SquadCommandRequest {
    if (bb.reserveEmergencySquadId >= 0) {
      for (let i: number = 0; i < enemySquads.length; i++) {
        if (enemySquads[i].squadId === bb.reserveEmergencySquadId) {
          return {
            squadIds: [reserveSq.squadId],
            formation: FormationType.PHALANX_RECT,
            order: TacticalOrder.ALL_OUT_CHARGE,
            targetX: enemySquads[i].centerX,
            targetY: enemySquads[i].centerY
          };
        }
      }
    }

    if (bb.reserveBreakthroughSquadId >= 0) {
      for (let i: number = 0; i < playerSquads.length; i++) {
        if (playerSquads[i].squadId === bb.reserveBreakthroughSquadId) {
          return {
            squadIds: [reserveSq.squadId],
            formation: FormationType.WEDGE_CHARGE,
            order: TacticalOrder.ALL_OUT_CHARGE,
            targetX: playerSquads[i].centerX,
            targetY: playerSquads[i].centerY
          };
        }
      }
    }

    const holdX: number = clampCoord(bb.enemyFrontX - bb.forwardDirX * 420, 120, world.width - 120);
    const holdY: number = clampCoord(bb.enemyFrontY, 200, world.height - 200);
    return {
      squadIds: [reserveSq.squadId],
      formation: FormationType.PHALANX_RECT,
      order: TacticalOrder.HOLD_GROUND,
      targetX: holdX,
      targetY: holdY
    };
  }

  private buildHalfFordStrikeCommand(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    sq: SquadRuntimeState,
    playerSquads: SquadRuntimeState[]
  ): SquadCommandRequest {
    let fordX: number = bb.playerFrontX;
    let fordY: number = bb.playerFrontY;
    for (let i: number = 0; i < playerSquads.length; i++) {
      if (playerSquads[i].squadId === bb.halfFordTargetSquadId) {
        fordX = playerSquads[i].centerX;
        fordY = playerSquads[i].centerY;
        break;
      }
    }

    const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
    const cat: UnitCategory = stats !== undefined ? stats.category : UnitCategory.INFANTRY;

    if (cat === UnitCategory.RANGED || cat === UnitCategory.SIEGE || sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY) {
      // 岸边弓弩雁行展开集火涉水之敌，吃满 +20% 半渡易伤
      return {
        squadIds: [sq.squadId],
        formation: FormationType.ECHELON_LINE,
        order: TacticalOrder.ADVANCE,
        targetX: fordX,
        targetY: fordY
      };
    }

    if (sq.corpsRole === ArmyCorpsRole.LEFT_WING || sq.corpsRole === ArmyCorpsRole.RIGHT_WING) {
      const offsetY: number = sq.corpsRole === ArmyCorpsRole.LEFT_WING ? -190 : 190;
      return {
        squadIds: [sq.squadId],
        formation: FormationType.WEDGE_CHARGE,
        order: TacticalOrder.PINCER_ENCIRCLE,
        targetX: fordX,
        targetY: clampCoord(fordY + offsetY, 120, world.height - 120)
      };
    }

    // 中军重步冲锋压岸截击
    return {
      squadIds: [sq.squadId],
      formation: FormationType.PHALANX_RECT,
      order: TacticalOrder.ALL_OUT_CHARGE,
      targetX: fordX,
      targetY: fordY
    };
  }

  private buildFordAmbushWaitCommand(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    sq: SquadRuntimeState
  ): SquadCommandRequest {
    const bankX: number = clampCoord(bb.riverCenterX - bb.forwardDirX * 230, 120, world.width - 120);
    const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
    const cat: UnitCategory = stats !== undefined ? stats.category : UnitCategory.INFANTRY;

    if (cat === UnitCategory.RANGED || cat === UnitCategory.SIEGE || sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY) {
      return {
        squadIds: [sq.squadId],
        formation: FormationType.ECHELON_LINE,
        order: TacticalOrder.AMBUSH_HIDE,
        targetX: clampCoord(bankX - bb.forwardDirX * 140, 120, world.width - 120),
        targetY: bb.riverCenterY
      };
    }

    const laneY: number =
      sq.corpsRole === ArmyCorpsRole.LEFT_WING
        ? bb.riverCenterY - 240
        : sq.corpsRole === ArmyCorpsRole.RIGHT_WING
          ? bb.riverCenterY + 240
          : bb.riverCenterY;

    return {
      squadIds: [sq.squadId],
      formation: FormationType.PHALANX_RECT,
      order: TacticalOrder.AMBUSH_HIDE,
      targetX: bankX,
      targetY: clampCoord(laneY, 140, world.height - 140)
    };
  }

  private buildHighGroundHedgehogCommand(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    sq: SquadRuntimeState
  ): SquadCommandRequest {
    const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
    const cat: UnitCategory = stats !== undefined ? stats.category : UnitCategory.INFANTRY;

    if (cat === UnitCategory.RANGED || cat === UnitCategory.SIEGE || sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY) {
      return {
        squadIds: [sq.squadId],
        formation: FormationType.ECHELON_LINE,
        order: TacticalOrder.HOLD_GROUND,
        targetX: bb.highGroundX,
        targetY: bb.highGroundY
      };
    }

    const frontSlopeX: number = clampCoord(bb.highGroundX + bb.forwardDirX * 110, 100, world.width - 100);
    if (sq.corpsRole === ArmyCorpsRole.LEFT_WING) {
      return {
        squadIds: [sq.squadId],
        formation: FormationType.PHALANX_RECT,
        order: TacticalOrder.HOLD_GROUND,
        targetX: frontSlopeX,
        targetY: clampCoord(bb.highGroundY - 190, 120, world.height - 120)
      };
    }
    if (sq.corpsRole === ArmyCorpsRole.RIGHT_WING) {
      return {
        squadIds: [sq.squadId],
        formation: FormationType.PHALANX_RECT,
        order: TacticalOrder.HOLD_GROUND,
        targetX: frontSlopeX,
        targetY: clampCoord(bb.highGroundY + 190, 120, world.height - 120)
      };
    }

    return {
      squadIds: [sq.squadId],
      formation: FormationType.PHALANX_RECT,
      order: TacticalOrder.HOLD_GROUND,
      targetX: frontSlopeX,
      targetY: bb.highGroundY
    };
  }

  private buildFeignedRetreatLureCommand(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    sq: SquadRuntimeState
  ): SquadCommandRequest {
    if (sq.corpsRole === ArmyCorpsRole.VANGUARD_CENTER) {
      // 中军前锋佯装败退，将贪功追击的玩家引向密林陷阱袋口
      const lureDestX: number = clampCoord(bb.forestTrapX - bb.forwardDirX * 160, 120, world.width - 120);
      return {
        squadIds: [sq.squadId],
        formation: FormationType.ECHELON_LINE,
        order: TacticalOrder.FEIGNED_RETREAT,
        targetX: lureDestX,
        targetY: bb.forestTrapY
      };
    }

    const ambushOffsetY: number =
      sq.corpsRole === ArmyCorpsRole.LEFT_WING
        ? -240
        : sq.corpsRole === ArmyCorpsRole.RIGHT_WING
          ? 240
          : 0;
    return {
      squadIds: [sq.squadId],
      formation: sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY ? FormationType.ECHELON_LINE : FormationType.WEDGE_CHARGE,
      order: TacticalOrder.AMBUSH_HIDE,
      targetX: bb.forestTrapX,
      targetY: clampCoord(bb.forestTrapY + ambushOffsetY, 120, world.height - 120)
    };
  }

  private buildForestTrapEncircleCommand(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    sq: SquadRuntimeState
  ): SquadCommandRequest {
    const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
    const cat: UnitCategory = stats !== undefined ? stats.category : UnitCategory.INFANTRY;

    if (cat === UnitCategory.RANGED || cat === UnitCategory.SIEGE || sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY) {
      return {
        squadIds: [sq.squadId],
        formation: FormationType.ECHELON_LINE,
        order: TacticalOrder.ADVANCE,
        targetX: bb.playerFrontX,
        targetY: bb.playerFrontY
      };
    }

    if (sq.corpsRole === ArmyCorpsRole.LEFT_WING || sq.corpsRole === ArmyCorpsRole.RIGHT_WING) {
      const sealRearX: number = clampCoord(bb.playerFrontX + bb.forwardDirX * 220, 100, world.width - 100);
      return {
        squadIds: [sq.squadId],
        formation: FormationType.WEDGE_CHARGE,
        order: TacticalOrder.PINCER_ENCIRCLE,
        targetX: sealRearX,
        targetY: bb.playerFrontY
      };
    }

    return {
      squadIds: [sq.squadId],
      formation: FormationType.PHALANX_RECT,
      order: TacticalOrder.ALL_OUT_CHARGE,
      targetX: bb.playerFrontX,
      targetY: bb.playerFrontY
    };
  }

  /**
   * 正面佯攻稳推 + 左右两翼南北走廊大弧线钳形合围（融合 8 种势力性格差异）
   */
  private buildPinningPincerCommand(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    sq: SquadRuntimeState,
    playerSquads: SquadRuntimeState[],
    bothWingsAvailable: boolean
  ): SquadCommandRequest {
    const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
    const cat: UnitCategory = stats !== undefined ? stats.category : UnitCategory.INFANTRY;

    // 远程与攻城群：雁行阵居后火力压制玩家密集步兵或弓手群
    if (cat === UnitCategory.RANGED || cat === UnitCategory.SIEGE || sq.corpsRole === ArmyCorpsRole.SIEGE_BATTERY) {
      return {
        squadIds: [sq.squadId],
        formation: FormationType.ECHELON_LINE,
        order: TacticalOrder.ADVANCE,
        targetX: bb.playerFrontX,
        targetY: bb.playerFrontY
      };
    }

    // 玄甲重骑（IRON_SHOCK_ELITE）专盯玩家阵线接合部最薄弱分队实施凿穿
    let shockTargetX: number = bb.playerRearX;
    let shockTargetY: number = bb.playerRearY;
    if (bb.personality === AiPersonality.IRON_SHOCK_ELITE && playerSquads.length > 0) {
      let weakest: SquadRuntimeState = playerSquads[0];
      let minScore: number = 1e9;
      for (let i: number = 0; i < playerSquads.length; i++) {
        const psq: SquadRuntimeState = playerSquads[i];
        const score: number = psq.morale * 1.5 + psq.aliveCount * 0.8;
        if (score < minScore) {
          minScore = score;
          weakest = psq;
        }
      }
      shockTargetX = weakest.centerX;
      shockTargetY = weakest.centerY;
    }

    // 左翼（北走廊绕后）与右翼（南走廊绕后）：落点南北错开 75px 确保形成 >=120° 多扇区钳形夹击
    if (sq.corpsRole === ArmyCorpsRole.LEFT_WING || sq.corpsRole === ArmyCorpsRole.RIGHT_WING) {
      const useNorth: boolean = sq.corpsRole === ArmyCorpsRole.LEFT_WING;
      const wingOrder: TacticalOrder = bothWingsAvailable ? TacticalOrder.PINCER_ENCIRCLE : TacticalOrder.FLANK;
      const wingFormation: FormationType =
        sq.primaryUnitType === UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER
          ? FormationType.ECHELON_LINE
          : FormationType.WEDGE_CHARGE;
      const pincerOffsetY: number = bothWingsAvailable ? (useNorth ? -75 : 75) : 0;
      const waypoints: Point2D[] = this.buildCorridorFlankWaypoints(
        world,
        bb,
        sq,
        useNorth,
        shockTargetX,
        clampCoord(shockTargetY + pincerOffsetY, 120, world.height - 120)
      );
      return this.toCommandWithWaypoints(sq.squadId, wingFormation, wingOrder, waypoints);
    }

    // 中军前锋：若已被四面合围则结圆阵死撑待预备队救援；否则依性格稳推吸火或锥形硬凿
    if (sq.encirclement === EncirclementState.ENCIRCLED) {
      return {
        squadIds: [sq.squadId],
        formation: FormationType.CIRCLE_DEFENSE,
        order: TacticalOrder.HOLD_GROUND,
        targetX: sq.centerX,
        targetY: sq.centerY
      };
    }

    const isAggressiveShockPersonality: boolean =
      bb.personality === AiPersonality.HONOR_BERSERK_BEAR ||
      (bb.personality === AiPersonality.ZEALOT_SWARM &&
        (world.weather === WeatherType.NIGHT || Math.abs(sq.centerX - bb.playerFrontX) <= 320));

    return {
      squadIds: [sq.squadId],
      formation: isAggressiveShockPersonality ? FormationType.WEDGE_CHARGE : FormationType.PHALANX_RECT,
      order: isAggressiveShockPersonality ? TacticalOrder.ALL_OUT_CHARGE : TacticalOrder.ADVANCE,
      targetX: bb.playerFrontX,
      targetY: bb.playerFrontY
    };
  }

  /**
   * 敌方督战主帅走位决策：残血护命回撤、斩首围猎合击、常规督战覆盖 350px 帅旗士气光环
   */
  private computeEnemyHeroPosition(
    world: BattleWorldReadonlyView,
    bb: TacticalBlackboard,
    siegePhase: SiegeTacticalPhase
  ): Point2D {
    const eh: CommanderHeroRuntime = world.enemyHero;
    if (
      eh.vitalState === HeroVitalState.RECOVERING_IN_CAMP ||
      eh.vitalState === HeroVitalState.FALLEN_MARTYRED ||
      (eh.maxHp > 0 && eh.hp / eh.maxHp < 0.32) ||
      (eh.vitalState === HeroVitalState.WOUNDED_WEAKENED && eh.maxHp > 0 && eh.hp / eh.maxHp < 0.55)
    ) {
      return {
        x: clampCoord(bb.enemyHomeX, 80, world.width - 80),
        y: clampCoord(bb.enemyHomeY, 80, world.height - 80)
      };
    }

    if (bb.playerHeroDecapitable && eh.maxHp > 0 && eh.hp / eh.maxHp >= 0.55) {
      return {
        x: clampCoord(world.playerHero.x, 80, world.width - 80),
        y: clampCoord(world.playerHero.y, 80, world.height - 80)
      };
    }

    if (siegePhase === SiegeTacticalPhase.ASSAULT_PHASE_3_BREACH_COMMIT) {
      return {
        x: clampCoord(bb.playerHomeX - bb.forwardDirX * 180, 80, world.width - 80),
        y: clampCoord(bb.playerHomeY, 80, world.height - 80)
      };
    }

    const offsetBehindFront: number =
      bb.personality === AiPersonality.HONOR_BERSERK_BEAR || bb.personality === AiPersonality.ZEALOT_SWARM
        ? 45
        : 135;
    return {
      x: clampCoord(bb.enemyFrontX - bb.forwardDirX * offsetBehindFront, 80, world.width - 80),
      y: clampCoord(bb.enemyFrontY, 120, world.height - 120)
    };
  }

  /**
   * 敌方主帅【三军战吼】释放时机：唤醒 320px 内溃逃/动摇友军，或破口冲锋/贴脸震慑敌阵
   */
  private shouldEnemyHeroWarCry(
    world: BattleWorldReadonlyView,
    enemySquads: SquadRuntimeState[],
    playerSquads: SquadRuntimeState[],
    siegePhase: SiegeTacticalPhase
  ): boolean {
    const eh: CommanderHeroRuntime = world.enemyHero;
    if (
      eh.warCryCooldown > 0 ||
      eh.vitalState === HeroVitalState.RECOVERING_IN_CAMP ||
      eh.vitalState === HeroVitalState.FALLEN_MARTYRED
    ) {
      return false;
    }

    const moraleRallyThreshold: number =
      world.hud.enemyRationStage === BattlefieldRationStage.STARVING ? 60 : 48;
    for (let i: number = 0; i < enemySquads.length; i++) {
      const sq: SquadRuntimeState = enemySquads[i];
      if ((sq.isRouting || sq.morale < moraleRallyThreshold) && distSq(eh.x, eh.y, sq.centerX, sq.centerY) <= 320 * 320) {
        return true;
      }
    }

    for (let i: number = 0; i < playerSquads.length; i++) {
      const psq: SquadRuntimeState = playerSquads[i];
      if (distSq(eh.x, eh.y, psq.centerX, psq.centerY) <= 180 * 180) {
        return true;
      }
    }

    return siegePhase === SiegeTacticalPhase.ASSAULT_PHASE_3_BREACH_COMMIT;
  }

  /**
   * 战场动态针对性征募策略（克制配兵 + 断粮止募高耗粮骑兵 + 苍狼禁造投石车）
   */
  private planRecruitments(world: BattleWorldReadonlyView, bb: TacticalBlackboard): AiRecruitRequest[] {
    const requests: AiRecruitRequest[] = [];
    let enemyPopApprox: number = 0;
    let sapperCount: number = 0;

    for (let i: number = 0; i < world.squads.length; i++) {
      const sq: SquadRuntimeState = world.squads[i];
      if (sq.side !== BattleSide.ENEMY || sq.aliveCount <= 0) {
        continue;
      }
      const stats: UnitStaticStats | undefined = getUnitConfigById(sq.primaryUnitType);
      const popPerUnit: number = stats !== undefined ? stats.popCap : 1;
      enemyPopApprox += sq.aliveCount * popPerUnit;
      if (sq.primaryUnitType === UnitTypeId.SAPPER) {
        sapperCount += sq.aliveCount;
      }
    }

    if (enemyPopApprox >= GameConstants.DEFAULT_ARMY_POP_CAP - 4) {
      return requests;
    }

    // 余粮吃紧或工兵不足时优先补工兵采粮，停止爆大胃口重骑/巨熊
    if (sapperCount < 2) {
      requests.push({ unitType: UnitTypeId.SAPPER, corpsRole: ArmyCorpsRole.SUPPLY_ESCORT });
    }
    if (
      world.hud.enemyRationStage === BattlefieldRationStage.HUNGRY ||
      world.hud.enemyRationStage === BattlefieldRationStage.STARVING
    ) {
      return requests;
    }

    const factionCfg: FactionStaticConfig | undefined = getFactionConfigById(world.enemyFaction);
    const exclusiveUnit: UnitTypeId =
      factionCfg !== undefined ? factionCfg.exclusiveUnitId : UnitTypeId.SHIELD_SWORDSMAN;

    // 针对玩家当前主力构成进行克制补兵
    if (bb.playerCavalryRatio >= 0.30) {
      const antiCavUnit: UnitTypeId =
        world.enemyFaction === FactionId.SHAMO
          ? UnitTypeId.SHAMO_MAMELUKE_CAMEL
          : world.enemyFaction === FactionId.YANLONG
            ? UnitTypeId.YANLONG_HALBERD_GRENADIER
            : UnitTypeId.PIKEMAN;
      requests.push({ unitType: antiCavUnit, corpsRole: ArmyCorpsRole.VANGUARD_CENTER });
    } else if (bb.isAiSiegeAttacker && world.enemyFaction !== FactionId.CANGLANG) {
      requests.push({ unitType: UnitTypeId.TREBUCHET, corpsRole: ArmyCorpsRole.SIEGE_BATTERY });
    } else if (bb.playerHeavyArmorRatio >= 0.38) {
      const armorBreaker: UnitTypeId =
        world.enemyFaction === FactionId.TIEYING
          ? UnitTypeId.TIEYING_PAVISE_CROSSBOW
          : world.enemyFaction === FactionId.SHUANGYUAN
            ? UnitTypeId.SHUANGYUAN_GIANT_BREAKER
            : UnitTypeId.GREAT_AXEMAN;
      const role: ArmyCorpsRole =
        armorBreaker === UnitTypeId.TIEYING_PAVISE_CROSSBOW
          ? ArmyCorpsRole.SIEGE_BATTERY
          : ArmyCorpsRole.VANGUARD_CENTER;
      requests.push({ unitType: armorBreaker, corpsRole: role });
    } else if (bb.playerRangedRatio >= 0.35) {
      const flankCav: UnitTypeId =
        world.enemyFaction === FactionId.CANGLANG
          ? UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER
          : world.enemyFaction === FactionId.XUANJIA
            ? UnitTypeId.XUANJIA_CATAPHRACT
            : UnitTypeId.LIGHT_CAVALRY;
      requests.push({ unitType: flankCav, corpsRole: ArmyCorpsRole.LEFT_WING });
    } else {
      const exclusiveStats: UnitStaticStats | undefined = getUnitConfigById(exclusiveUnit);
      const targetRole: ArmyCorpsRole =
        exclusiveStats !== undefined && exclusiveStats.category === UnitCategory.CAVALRY
          ? ArmyCorpsRole.RIGHT_WING
          : exclusiveStats !== undefined && exclusiveStats.category === UnitCategory.RANGED
            ? ArmyCorpsRole.SIEGE_BATTERY
            : ArmyCorpsRole.VANGUARD_CENTER;
      requests.push({ unitType: exclusiveUnit, corpsRole: targetRole });
    }

    // 额外校验：严禁任何路径为苍狼汗国请求投石车，严禁跨势力招募专属兵种
    const sanitized: AiRecruitRequest[] = [];
    for (let i: number = 0; i < requests.length; i++) {
      const req: AiRecruitRequest = requests[i];
      if (world.enemyFaction === FactionId.CANGLANG && req.unitType === UnitTypeId.TREBUCHET) {
        sanitized.push({ unitType: UnitTypeId.BALLISTA, corpsRole: ArmyCorpsRole.SIEGE_BATTERY });
        continue;
      }
      const st: UnitStaticStats | undefined = getUnitConfigById(req.unitType);
      if (st !== undefined && st.exclusiveFaction !== null && st.exclusiveFaction !== world.enemyFaction) {
        sanitized.push({ unitType: UnitTypeId.SHIELD_SWORDSMAN, corpsRole: req.corpsRole });
        continue;
      }
      sanitized.push(req);
    }

    // 保留 UNIT_STATIC_CONFIGS 引用供静态全表校验
    if (UNIT_STATIC_CONFIGS.length === 0) {
      return [];
    }
    return sanitized;
  }

  private isAlreadyAssigned(assigned: number[], squadId: number): boolean {
    for (let i: number = 0; i < assigned.length; i++) {
      if (assigned[i] === squadId) {
        return true;
      }
    }
    return false;
  }
}

/**
 * 纯函数式单次战场 AI 评估入口（适用于无状态快照推演与独立单测断言）
 */
export function evaluateBattleTacticalAI(world: BattleWorldReadonlyView): AiBattleDecisionBatch {
  const ai: BattleTacticalAI = new BattleTacticalAI();
  return ai.evaluateNow(world);
}
