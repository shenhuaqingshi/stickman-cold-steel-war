/**
 * L1 战略大地图 7 大 AI 势力独立演化效用决策器（CampaignStrategicAI.ets）
 *
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范：
 * - 零 any / unknown，零未标注对象字面量，零 @kit.ArkUI 依赖
 * - 输入 CampaignSaveState 与指定 FactionId，输出结构化回合战略指令列表 StrategicTurnAction[]
 * - 完整兑现：
 *   1) AI 之间真实攻伐结盟（绝不围着玩家转，基于 40 城拓扑、防务、粮仓价值与 8 种性格效用评估）
 *   2) 两线作战规避（除血月祭司团外，同时与 >=2 强敌交战时主动向次要战线求和止损）
 *   3) 反霸权合纵警觉（任一势力占城 >=13 座即 35% 时，相邻非同盟 AI 自动提升合作权重促成反扩张同盟）
 *   4) 保护自身粮道 & 截断敌方咽喉（BFS 补给线连通推演，优先夺回断粮仓城通道并偷袭敌军孤立补给咽喉）
 */
import { GameConstants } from '../../common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../../config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../../config/FactionConfig';
import { getUnitConfigById } from '../../config/UnitConfig';
import {
  AiPersonality,
  ArmyCorpsRole,
  BilateralDiplomacyState,
  CampaignNodeConfig,
  CampaignNodeType,
  DiplomaticStatus,
  FactionId,
  FactionStaticConfig,
  FactionTechItem,
  PeaceOfferTerms,
  TerrainType,
  UnitCategory,
  UnitStaticStats,
  UnitTypeId
} from '../../model/GameTypes';
import {
  CampaignNodeRuntime,
  CampaignSaveState,
  FactionCampaignRuntime,
  RosterEntry,
  SupplyEvaluationResult,
  SupplyLineGrade
} from '../CoreContracts';

/** 触发全图反霸权【合纵警觉】的占城阈值（40 座城关的 35% 即 >= 13 座，对应 DESIGN.md 8.3） */
export const HEGEMONY_CITY_THRESHOLD: number = 13;

/** 反霸权合纵警觉共同威胁双边好感加成（对应 DESIGN.md 8.3） */
export const ANTI_HEGEMONY_RELATION_BONUS: number = 25;

/** 战略回合指令类型枚举（严格对应八种核心战略动作） */
export enum StrategicActionType {
  RECRUIT = 'recruit',
  UNLOCK_TECH = 'unlockTech',
  MARCH_ATTACK = 'marchAttack',
  SET_AMBUSH_TRAP = 'setAmbushTrap',
  PROPOSE_ALLIANCE = 'proposeAlliance',
  PROPOSE_TRADE = 'proposeTrade',
  PROPOSE_PEACE = 'proposePeace',
  DECLARE_WAR = 'declareWar'
}

/** 结构化大地图单步战略指令 */
export interface StrategicTurnAction {
  readonly type: StrategicActionType;
  readonly kind: StrategicActionType;
  readonly factionId: FactionId;
  readonly targetFactionId: FactionId | null;
  readonly fromNodeId: string;
  readonly targetNodeId: string;
  readonly unitType: UnitTypeId | null;
  readonly count: number;
  readonly corpsRole: ArmyCorpsRole | null;
  readonly techId: string;
  readonly peaceTerms: PeaceOfferTerms | null;
  readonly utilityScore: number;
  readonly reason: string;
}

/** 候选进攻目标节点效用评分明细 */
export interface AttackTargetCandidate {
  readonly fromNodeId: string;
  readonly targetNodeId: string;
  readonly defenderFaction: FactionId;
  readonly utilityScore: number;
  readonly reconnectsOwnSupply: boolean;
  readonly seversEnemyNodesCount: number;
  readonly isEnemySupplyThroat: boolean;
  readonly requiresDeclareWar: boolean;
  readonly reason: string;
}

/** 势力战略态势诊断快照（供调试与单测审阅） */
export interface FactionStrategicAssessment {
  readonly factionId: FactionId;
  readonly personality: AiPersonality;
  readonly controlledCityCount: number;
  readonly militaryPower: number;
  readonly strongWarEnemies: FactionId[];
  readonly hegemonFaction: FactionId | null;
  readonly hegemonCityCount: number;
  readonly severedOwnNodeIds: string[];
  readonly topAttackCandidate: AttackTargetCandidate | null;
}

/** 内部可变预算账本（防止单回合内政与赔款透支库存） */
interface TurnResourceBudget {
  gold: number;
  wood: number;
  grain: number;
}

function clampNum(val: number, minVal: number, maxVal: number): number {
  if (val < minVal) {
    return minVal;
  }
  if (val > maxVal) {
    return maxVal;
  }
  return val;
}

/** 预构建 O(1) 大地图静态节点索引，消除多源 BFS 与全图接壤推演中的重复数组扫描 */
const STATIC_NODE_LOOKUP: Map<string, CampaignNodeConfig> = buildStaticNodeLookup();

function buildStaticNodeLookup(): Map<string, CampaignNodeConfig> {
  const table: Map<string, CampaignNodeConfig> = new Map<string, CampaignNodeConfig>();
  for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
    const node: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
    table.set(node.id, node);
  }
  return table;
}

function getStaticNodeById(nodeId: string): CampaignNodeConfig | undefined {
  return STATIC_NODE_LOOKUP.get(nodeId);
}

function getRuntimeNodeById(nodes: readonly CampaignNodeRuntime[], nodeId: string): CampaignNodeRuntime | undefined {
  for (let i: number = 0; i < nodes.length; i++) {
    if (nodes[i].nodeId === nodeId) {
      return nodes[i];
    }
  }
  return undefined;
}

function getRuntimeFactionById(
  factions: readonly FactionCampaignRuntime[],
  factionId: FactionId
): FactionCampaignRuntime | undefined {
  for (let i: number = 0; i < factions.length; i++) {
    if (factions[i].factionId === factionId) {
      return factions[i];
    }
  }
  return undefined;
}

function findDiplomacyRecord(
  diplomacy: readonly BilateralDiplomacyState[],
  a: FactionId,
  b: FactionId
): BilateralDiplomacyState | undefined {
  for (let i: number = 0; i < diplomacy.length; i++) {
    const d: BilateralDiplomacyState = diplomacy[i];
    if ((d.factionA === a && d.factionB === b) || (d.factionA === b && d.factionB === a)) {
      return d;
    }
  }
  return undefined;
}

function getDiplomaticStatus(
  diplomacy: readonly BilateralDiplomacyState[],
  a: FactionId,
  b: FactionId
): DiplomaticStatus {
  if (a === b) {
    return DiplomaticStatus.ALLIANCE;
  }
  const rec: BilateralDiplomacyState | undefined = findDiplomacyRecord(diplomacy, a, b);
  return rec !== undefined ? rec.status : DiplomaticStatus.NEUTRAL;
}

function getBilateralRelation(
  diplomacy: readonly BilateralDiplomacyState[],
  a: FactionId,
  b: FactionId
): number {
  if (a === b) {
    return 100;
  }
  const rec: BilateralDiplomacyState | undefined = findDiplomacyRecord(diplomacy, a, b);
  if (rec !== undefined) {
    return rec.relation;
  }
  if (a === FactionId.XUEYUE || b === FactionId.XUEYUE) {
    return -15;
  }
  return 0;
}

function getVendettaLockTurns(
  diplomacy: readonly BilateralDiplomacyState[],
  a: FactionId,
  b: FactionId
): number {
  const rec: BilateralDiplomacyState | undefined = findDiplomacyRecord(diplomacy, a, b);
  return rec !== undefined ? rec.vendettaLockTurns : 0;
}

/**
 * 估算单支编制兵种战力分
 */
function estimateUnitPower(unitType: UnitTypeId): number {
  const st: UnitStaticStats | undefined = getUnitConfigById(unitType);
  if (st === undefined) {
    return 16;
  }
  if (st.category === UnitCategory.SUPPORT) {
    return 3;
  }
  const dps: number = (st.attack / Math.max(0.5, st.attackIntervalSec)) * (1.0 + st.armorPenetration * 0.55);
  return st.hp * 0.07 + dps * 1.1 + st.armor * 0.22 + st.popCap * 4.0;
}

/**
 * 估算指定势力总军事实力（野战主力军团 + 辖区驻防折算）
 */
function computeFactionMilitaryPower(state: CampaignSaveState, factionId: FactionId): number {
  const fac: FactionCampaignRuntime | undefined = getRuntimeFactionById(state.factions, factionId);
  if (fac === undefined || !fac.isAlive) {
    return 0;
  }
  let fieldPower: number = 0;
  for (let i: number = 0; i < fac.fieldArmyRoster.length; i++) {
    const entry: RosterEntry = fac.fieldArmyRoster[i];
    if (entry.count > 0) {
      fieldPower += entry.count * estimateUnitPower(entry.unitType);
    }
  }
  let garrisonSum: number = 0;
  for (let i: number = 0; i < state.nodes.length; i++) {
    if (state.nodes[i].owner === factionId) {
      garrisonSum += state.nodes[i].garrisonStrength;
    }
  }
  const injuryFactor: number = fac.commanderInjuredTurns > 0 ? 0.85 : 1.0;
  return (fieldPower + garrisonSum * 0.65) * injuryFactor;
}

function countFactionCities(nodes: readonly CampaignNodeRuntime[], factionId: FactionId): number {
  let count: number = 0;
  for (let i: number = 0; i < nodes.length; i++) {
    if (nodes[i].owner === factionId) {
      count += 1;
    }
  }
  return count;
}

/**
 * 判断两个势力在大地图上是否有领土直接接壤（距离 1 跳）
 */
function areFactionsAdjacent(nodes: readonly CampaignNodeRuntime[], factionA: FactionId, factionB: FactionId): boolean {
  if (factionA === factionB) {
    return false;
  }
  for (let i: number = 0; i < nodes.length; i++) {
    const rn: CampaignNodeRuntime = nodes[i];
    if (rn.owner !== factionA) {
      continue;
    }
    const sn: CampaignNodeConfig | undefined = getStaticNodeById(rn.nodeId);
    if (sn === undefined) {
      continue;
    }
    for (let j: number = 0; j < sn.neighbors.length; j++) {
      const nbRuntime: CampaignNodeRuntime | undefined = getRuntimeNodeById(nodes, sn.neighbors[j]);
      if (nbRuntime !== undefined && nbRuntime.owner === factionB) {
        return true;
      }
    }
  }
  return false;
}

/**
 * BFS 补给线连通评估（支持假设某节点易手后的反事实图割模拟，遵循 DESIGN.md 7.3 规则）
 */
function evaluateSupplyMapInternal(
  state: CampaignSaveState,
  factionId: FactionId,
  overrideNodeId: string,
  overrideNewOwner: FactionId | null
): Map<string, SupplyEvaluationResult> {
  const result: Map<string, SupplyEvaluationResult> = new Map<string, SupplyEvaluationResult>();

  // 收集允许通行的节点集合（本方控制节点 + 正式军事同盟国节点）与本方补给源仓城
  const passableSet: Set<string> = new Set<string>();
  const ownSet: Set<string> = new Set<string>();
  const depotSeeds: string[] = [];

  for (let i: number = 0; i < state.nodes.length; i++) {
    const rn: CampaignNodeRuntime = state.nodes[i];
    const effectiveOwner: FactionId =
      overrideNewOwner !== null && rn.nodeId === overrideNodeId ? overrideNewOwner : rn.owner;

    const isOwn: boolean = effectiveOwner === factionId;
    const isAllied: boolean =
      !isOwn && getDiplomaticStatus(state.diplomacy, factionId, effectiveOwner) === DiplomaticStatus.ALLIANCE;

    if (isOwn || isAllied) {
      passableSet.add(rn.nodeId);
    }
    if (isOwn) {
      ownSet.add(rn.nodeId);
      const sn: CampaignNodeConfig | undefined = getStaticNodeById(rn.nodeId);
      if (sn !== undefined && sn.isSupplyDepot) {
        depotSeeds.push(rn.nodeId);
      }
    }
  }

  // 多源 BFS：自全部本方仓城同时向外扩展最短跳数
  const distMap: Map<string, number> = new Map<string, number>();
  const rootDepotMap: Map<string, string> = new Map<string, string>();
  const parentMap: Map<string, string> = new Map<string, string>();
  const queue: string[] = [];

  for (let i: number = 0; i < depotSeeds.length; i++) {
    const seed: string = depotSeeds[i];
    distMap.set(seed, 0);
    rootDepotMap.set(seed, seed);
    parentMap.set(seed, '');
    queue.push(seed);
  }

  let head: number = 0;
  while (head < queue.length) {
    const curr: string = queue[head];
    head += 1;
    const currDist: number = distMap.get(curr) ?? 0;
    const currRoot: string = rootDepotMap.get(curr) ?? curr;
    const sn: CampaignNodeConfig | undefined = getStaticNodeById(curr);
    if (sn === undefined) {
      continue;
    }
    for (let j: number = 0; j < sn.neighbors.length; j++) {
      const nb: string = sn.neighbors[j];
      if (!passableSet.has(nb) || distMap.has(nb)) {
        continue;
      }
      distMap.set(nb, currDist + 1);
      rootDepotMap.set(nb, currRoot);
      parentMap.set(nb, curr);
      queue.push(nb);
    }
  }

  const isCanglang: boolean = factionId === FactionId.CANGLANG;
  const ownNodeIds: string[] = Array.from(ownSet);
  for (let i: number = 0; i < ownNodeIds.length; i++) {
    const nid: string = ownNodeIds[i];
    const d: number | undefined = distMap.get(nid);
    if (d === undefined) {
      result.set(nid, {
        nodeId: nid,
        grade: SupplyLineGrade.SEVERED,
        hops: 999,
        nearestDepotNodeId: '',
        pathNodeIds: [],
        upkeepMultiplier: 1.5,
        initialGrainMultiplier: 0.65
      });
      continue;
    }

    const revPath: string[] = [];
    let cursor: string = nid;
    while (cursor.length > 0) {
      revPath.push(cursor);
      cursor = parentMap.get(cursor) ?? '';
    }
    revPath.reverse();

    let grade: SupplyLineGrade = SupplyLineGrade.FULL_SUPPLY;
    let upkeepMult: number = 1.0;
    let initGrainMult: number = 1.0;
    if (d <= GameConstants.SUPPLY_FULL_HOPS) {
      grade = SupplyLineGrade.FULL_SUPPLY;
    } else if (d === 3) {
      grade = SupplyLineGrade.EXTENDED_MARCH;
      upkeepMult = isCanglang ? 1.0 + 0.25 * 0.65 : 1.25;
      initGrainMult = isCanglang ? 1.0 - 0.15 * 0.65 : 0.85;
    } else {
      grade = SupplyLineGrade.OVEREXTENDED;
      upkeepMult = isCanglang ? 1.0 + 0.50 * 0.65 : 1.50;
      initGrainMult = isCanglang ? 1.0 - 0.25 * 0.65 : 0.75;
    }

    result.set(nid, {
      nodeId: nid,
      grade: grade,
      hops: d,
      nearestDepotNodeId: rootDepotMap.get(nid) ?? '',
      pathNodeIds: revPath,
      upkeepMultiplier: upkeepMult,
      initialGrainMultiplier: initGrainMult
    });
  }

  return result;
}

/**
 * 公开的势力粮道连通评估纯函数（供外部或测试校验 BFS 粮道计算）
 */
export function computeFactionSupplyMap(
  state: CampaignSaveState,
  factionId: FactionId
): Map<string, SupplyEvaluationResult> {
  return evaluateSupplyMapInternal(state, factionId, '', null);
}

function createAction(
  type: StrategicActionType,
  factionId: FactionId,
  targetFactionId: FactionId | null,
  fromNodeId: string,
  targetNodeId: string,
  unitType: UnitTypeId | null,
  count: number,
  corpsRole: ArmyCorpsRole | null,
  techId: string,
  peaceTerms: PeaceOfferTerms | null,
  utilityScore: number,
  reason: string
): StrategicTurnAction {
  return {
    type: type,
    kind: type,
    factionId: factionId,
    targetFactionId: targetFactionId,
    fromNodeId: fromNodeId,
    targetNodeId: targetNodeId,
    unitType: unitType,
    count: count,
    corpsRole: corpsRole,
    techId: techId,
    peaceTerms: peaceTerms,
    utilityScore: Math.round(utilityScore * 100) / 100,
    reason: reason
  };
}

/**
 * L1 战略大地图 7 大 AI 势力独立演化决策引擎
 */
export class CampaignStrategicAI {
  /**
   * 诊断指定势力当前的全局战略态势（霸权国检测、两线交战、断粮孤城、最优进攻方向）
   */
  public assessFactionSituation(state: CampaignSaveState, factionId: FactionId): FactionStrategicAssessment {
    const staticFac: FactionStaticConfig | undefined = getFactionConfigById(factionId);
    const personality: AiPersonality =
      staticFac !== undefined ? staticFac.aiPersonality : AiPersonality.IMPERIAL_METHODICAL;

    const myCities: number = countFactionCities(state.nodes, factionId);
    const myPower: number = computeFactionMilitaryPower(state, factionId);

    // 1. 检测全图是否存在占城 >= 13 座（35%）的霸权势力
    let hegemonFaction: FactionId | null = null;
    let hegemonCityCount: number = 0;
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      const fid: FactionId = FACTION_STATIC_CONFIGS[i].id;
      const cnt: number = countFactionCities(state.nodes, fid);
      if (cnt >= HEGEMONY_CITY_THRESHOLD && cnt > hegemonCityCount) {
        hegemonCityCount = cnt;
        hegemonFaction = fid;
      }
    }

    // 2. 统计当前同时交战的强敌列表
    const strongWarEnemies: FactionId[] = [];
    for (let i: number = 0; i < state.factions.length; i++) {
      const other: FactionCampaignRuntime = state.factions[i];
      if (!other.isAlive || other.factionId === factionId) {
        continue;
      }
      if (getDiplomaticStatus(state.diplomacy, factionId, other.factionId) !== DiplomaticStatus.WAR) {
        continue;
      }
      const otherCities: number = countFactionCities(state.nodes, other.factionId);
      const otherPower: number = computeFactionMilitaryPower(state, other.factionId);
      if (otherCities >= 2 || otherPower >= Math.max(70, myPower * 0.45)) {
        strongWarEnemies.push(other.factionId);
      }
    }

    // 3. 检测本方粮道被断节点（综合实时 BFS 与节点自身 supplyGrade 标记）
    const supplyMap: Map<string, SupplyEvaluationResult> = computeFactionSupplyMap(state, factionId);
    const severedOwnNodeIds: string[] = [];
    for (let i: number = 0; i < state.nodes.length; i++) {
      const rn: CampaignNodeRuntime = state.nodes[i];
      if (rn.owner !== factionId) {
        continue;
      }
      const evalRes: SupplyEvaluationResult | undefined = supplyMap.get(rn.nodeId);
      if (
        rn.supplyGrade === SupplyLineGrade.SEVERED ||
        (evalRes !== undefined && evalRes.grade === SupplyLineGrade.SEVERED)
      ) {
        severedOwnNodeIds.push(rn.nodeId);
      }
    }

    // 4. 评估全部接壤潜在进攻目标
    const candidates: AttackTargetCandidate[] = this.scoreBorderAttackTargets(
      state,
      factionId,
      personality,
      myPower,
      hegemonFaction,
      strongWarEnemies,
      severedOwnNodeIds,
      null
    );

    return {
      factionId: factionId,
      personality: personality,
      controlledCityCount: myCities,
      militaryPower: myPower,
      strongWarEnemies: strongWarEnemies,
      hegemonFaction: hegemonFaction,
      hegemonCityCount: hegemonCityCount,
      severedOwnNodeIds: severedOwnNodeIds,
      topAttackCandidate: candidates.length > 0 ? candidates[0] : null
    };
  }

  /**
   * 为指定 AI 势力生成当前回合的完整战略指令队列
   */
  public evaluateFactionTurn(state: CampaignSaveState, factionId: FactionId): StrategicTurnAction[] {
    const actions: StrategicTurnAction[] = [];
    const runtimeFac: FactionCampaignRuntime | undefined = getRuntimeFactionById(state.factions, factionId);
    if (runtimeFac === undefined || !runtimeFac.isAlive) {
      return actions;
    }

    const myCityCount: number = countFactionCities(state.nodes, factionId);
    if (myCityCount <= 0) {
      return actions;
    }

    const assessment: FactionStrategicAssessment = this.assessFactionSituation(state, factionId);
    const personality: AiPersonality = assessment.personality;
    const budget: TurnResourceBudget = {
      gold: runtimeFac.gold,
      wood: runtimeFac.wood,
      grain: runtimeFac.grain
    };

    // ==================== 第一步：两线作战规避与止损求和（血月祭司团除外） ====================
    let peaceTargetChosen: FactionId | null = null;
    if (personality !== AiPersonality.ZEALOT_SWARM && factionId !== FactionId.XUEYUE) {
      if (assessment.strongWarEnemies.length >= 2) {
        const secondaryEnemy: FactionId | null = this.selectSecondaryWarFrontForPeace(
          state,
          factionId,
          assessment.strongWarEnemies,
          assessment.hegemonFaction,
          assessment.severedOwnNodeIds
        );
        if (secondaryEnemy !== null) {
          const offer: PeaceOfferTerms = this.buildAffordablePeaceOffer(
            state,
            runtimeFac,
            secondaryEnemy,
            budget,
            assessment.strongWarEnemies.length
          );
          budget.gold = Math.max(0, budget.gold - offer.goldIndemnity);
          peaceTargetChosen = secondaryEnemy;
          actions.push(
            createAction(
              StrategicActionType.PROPOSE_PEACE,
              factionId,
              secondaryEnemy,
              runtimeFac.armyLocationNodeId,
              '',
              null,
              0,
              null,
              '',
              offer,
              92.0,
              `两线作战规避：同时与 ${assessment.strongWarEnemies.length} 大强敌交战，主动向次要战线 ${secondaryEnemy} 议和止损以集中兵力`
            )
          );
        }
      } else if (
        assessment.strongWarEnemies.length === 1 &&
        myCityCount <= 2 &&
        personality === AiPersonality.MERCHANT_PRAGMATIC &&
        budget.gold >= 220
      ) {
        // 沙漠商盟残局危急时亦擅长砸重金买和平喘息
        const loneEnemy: FactionId = assessment.strongWarEnemies[0];
        if (getVendettaLockTurns(state.diplomacy, factionId, loneEnemy) === 0) {
          const emergencyOffer: PeaceOfferTerms = this.buildAffordablePeaceOffer(
            state,
            runtimeFac,
            loneEnemy,
            budget,
            2
          );
          budget.gold = Math.max(0, budget.gold - emergencyOffer.goldIndemnity);
          peaceTargetChosen = loneEnemy;
          actions.push(
            createAction(
              StrategicActionType.PROPOSE_PEACE,
              factionId,
              loneEnemy,
              runtimeFac.armyLocationNodeId,
              '',
              null,
              0,
              null,
              '',
              emergencyOffer,
              84.0,
              `金元算计保命：城池仅余 ${myCityCount} 座，商盟斥资向强敌 ${loneEnemy} 购买停战喘息期`
            )
          );
        }
      }
    }

    // ==================== 第二步：反霸权【合纵警觉】（>= 13 城）与日常合纵通商外交 ====================
    this.planCoalitionAndDiplomacyActions(
      state,
      runtimeFac,
      assessment,
      budget,
      peaceTargetChosen,
      actions
    );

    // ==================== 第三步：势力专属科技研发（unlockTech） ====================
    this.planTechUnlockAction(runtimeFac, personality, budget, actions);

    // ==================== 第四步：针对性军团补员与配兵（recruit） ====================
    this.planStrategicRecruitmentActions(state, runtimeFac, assessment, budget, actions);

    // ==================== 第五步：咽喉/密林伏击与围点打援布防（setAmbushTrap） ====================
    this.planAmbushTrapAction(state, runtimeFac, assessment, budget, actions);

    // ==================== 第六步：保护自身粮道 / 截断敌方咽喉 / 宣战与进军（declareWar + marchAttack） ====================
    this.planOffensiveMarchAndWarActions(state, runtimeFac, assessment, budget, peaceTargetChosen, actions);

    return actions;
  }

  /**
   * 一次性演化全图除玩家外全部存活 AI 势力的回合决策（无玩家偏见独立演化）
   */
  public evaluateAllAiFactionsTurn(state: CampaignSaveState): Map<FactionId, StrategicTurnAction[]> {
    const batchMap: Map<FactionId, StrategicTurnAction[]> = new Map<FactionId, StrategicTurnAction[]>();
    for (let i: number = 0; i < state.factions.length; i++) {
      const fac: FactionCampaignRuntime = state.factions[i];
      if (!fac.isAlive || fac.factionId === state.playerFaction) {
        continue;
      }
      batchMap.set(fac.factionId, this.evaluateFactionTurn(state, fac.factionId));
    }
    return batchMap;
  }

  /**
   * 从多线交战敌人中甄选最适合议和脱身的次要战线：
   * 优先保留正在切断我方粮道或侵占我方王都核心区的主战线死敌，向周边次要强敌求和
   */
  private selectSecondaryWarFrontForPeace(
    state: CampaignSaveState,
    selfId: FactionId,
    warEnemies: FactionId[],
    hegemonFaction: FactionId | null,
    severedOwnNodeIds: string[]
  ): FactionId | null {
    const staticSelf: FactionStaticConfig | undefined = getFactionConfigById(selfId);
    const homeCapitalCfg: CampaignNodeConfig | undefined =
      staticSelf !== undefined ? getStaticNodeById(staticSelf.capitalNodeId) : undefined;
    const homeRegionIndex: number = homeCapitalCfg !== undefined ? homeCapitalCfg.regionIndex : -1;

    let bestPeaceTarget: FactionId | null = null;
    let bestPeaceScore: number = -1e9;

    for (let i: number = 0; i < warEnemies.length; i++) {
      const enemyId: FactionId = warEnemies[i];
      // 血海世仇锁定期内对方必拒一切谈判（DESIGN.md 10.3.2）
      if (getVendettaLockTurns(state.diplomacy, selfId, enemyId) > 0) {
        continue;
      }

      let score: number = 50.0;
      const rel: number = getBilateralRelation(state.diplomacy, selfId, enemyId);
      score += rel * 0.30;

      // 若对方占据我方初始核心区城池，则属于核心主战线，不轻易对其妥协，优先向另一侧求和
      let occupiesMyHomeRegion: boolean = false;
      let sharedBorderEdges: number = 0;
      for (let n: number = 0; n < state.nodes.length; n++) {
        const rn: CampaignNodeRuntime = state.nodes[n];
        const sn: CampaignNodeConfig | undefined = getStaticNodeById(rn.nodeId);
        if (sn === undefined) {
          continue;
        }
        if (rn.owner === enemyId && sn.regionIndex === homeRegionIndex) {
          occupiesMyHomeRegion = true;
        }
        if (rn.owner === selfId) {
          for (let k: number = 0; k < sn.neighbors.length; k++) {
            const nb: CampaignNodeRuntime | undefined = getRuntimeNodeById(state.nodes, sn.neighbors[k]);
            if (nb !== undefined && nb.owner === enemyId) {
              sharedBorderEdges += 1;
            }
          }
        }
      }

      if (occupiesMyHomeRegion) {
        score -= 45.0;
      }
      // 战线接触越窄（次要方向），越适合快速停火脱身
      score -= sharedBorderEdges * 4.5;

      // 若存在 >=13 城霸主，优先与非霸主停战以便共同抗击霸主！
      if (hegemonFaction !== null && enemyId !== hegemonFaction) {
        score += 40.0;
      }

      // 若某敌人正卡住我方断粮节点的唯一咽喉，保留对该敌人的进攻自由，优先向另一战线求和
      if (severedOwnNodeIds.length > 0 && this.doesEnemyBlockMySeveredNodes(state, selfId, enemyId, severedOwnNodeIds)) {
        score -= 55.0;
      }

      if (score > bestPeaceScore) {
        bestPeaceScore = score;
        bestPeaceTarget = enemyId;
      }
    }

    return bestPeaceTarget;
  }

  private doesEnemyBlockMySeveredNodes(
    state: CampaignSaveState,
    selfId: FactionId,
    enemyId: FactionId,
    severedOwnNodeIds: string[]
  ): boolean {
    for (let i: number = 0; i < severedOwnNodeIds.length; i++) {
      const sn: CampaignNodeConfig | undefined = getStaticNodeById(severedOwnNodeIds[i]);
      if (sn === undefined) {
        continue;
      }
      for (let j: number = 0; j < sn.neighbors.length; j++) {
        const nb: CampaignNodeRuntime | undefined = getRuntimeNodeById(state.nodes, sn.neighbors[j]);
        if (nb !== undefined && nb.owner === enemyId) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 依据 DESIGN.md 8.3 媾和接受度量化公式反向配算合法、可负担的停战报价单（严禁超资产上限或负数）
   */
  private buildAffordablePeaceOffer(
    state: CampaignSaveState,
    selfFac: FactionCampaignRuntime,
    targetEnemyId: FactionId,
    budget: TurnResourceBudget,
    activeWarCount: number
  ): PeaceOfferTerms {
    const selfPower: number = Math.max(1, computeFactionMilitaryPower(state, selfFac.factionId));
    const enemyPower: number = Math.max(1, computeFactionMilitaryPower(state, targetEnemyId));

    // 估算对方视角下的战场优势与低信誉折价，确保筹码足够令 AcceptScore >= 0
    const powerRatioEnemyOverSelf: number = clampNum((enemyPower - selfPower) / Math.max(selfPower, enemyPower), -1, 1);
    const estimatedEnemyAdv: number = powerRatioEnemyOverSelf * 28.0;
    const lowCredPenalty: number = selfFac.credibility < 60 ? (60 - selfFac.credibility) * 0.45 : 0;
    const estimatedWarExhaust: number = Math.min(35, 12 + state.turnNumber * 1.5);
    const thirdPartyThreatToEnemy: number = activeWarCount >= 2 ? 12 : 6;

    const neededOfferValue: number = Math.max(
      10,
      estimatedEnemyAdv + lowCredPenalty - estimatedWarExhaust - thirdPartyThreatToEnemy + 8
    );

    const truceTurns: number = 8;
    const maxAffordableGold: number = Math.max(0, Math.floor(budget.gold * 0.60));
    const desiredGold: number = Math.min(maxAffordableGold, Math.max(50, Math.ceil(neededOfferValue * 25)));
    const remainingValueGap: number = Math.max(0, neededOfferValue - desiredGold / 25.0);

    const maxSafeGrainPerTurn: number = Math.max(0, Math.floor(Math.max(0, budget.grain - 150) / truceTurns));
    const desiredGrainPerTurn: number = Math.min(
      maxSafeGrainPerTurn,
      Math.ceil((remainingValueGap * 18.0) / truceTurns)
    );

    const postGrainGap: number = Math.max(
      0,
      remainingValueGap - (desiredGrainPerTurn * truceTurns) / 18.0
    );

    // 若国库金粮双双枯竭仍不足以打动强敌停战（DESIGN.md 8.3 & 10.4），且本方尚存 >=3 城，可割让 1 座非王都且不会切断本土粮道的接壤边城断臂求生
    const cededNodes: string[] = [];
    if (postGrainGap > 8.0 && countFactionCities(state.nodes, selfFac.factionId) >= 3) {
      const staticSelf: FactionStaticConfig | undefined = getFactionConfigById(selfFac.factionId);
      const myCapitalId: string = staticSelf !== undefined ? staticSelf.capitalNodeId : '';
      let chosenBorderCession: string = '';
      let bestCessionCostScore: number = 1e9;

      for (let i: number = 0; i < state.nodes.length; i++) {
        const rn: CampaignNodeRuntime = state.nodes[i];
        if (rn.owner !== selfFac.factionId || rn.nodeId === myCapitalId) {
          continue;
        }
        const sn: CampaignNodeConfig | undefined = getStaticNodeById(rn.nodeId);
        if (sn === undefined || sn.nodeType === CampaignNodeType.CAPITAL_CITADEL) {
          continue;
        }
        let bordersTargetEnemy: boolean = false;
        for (let j: number = 0; j < sn.neighbors.length; j++) {
          const nb: CampaignNodeRuntime | undefined = getRuntimeNodeById(state.nodes, sn.neighbors[j]);
          if (nb !== undefined && nb.owner === targetEnemyId) {
            bordersTargetEnemy = true;
            break;
          }
        }
        if (!bordersTargetEnemy) {
          continue;
        }

        // 反事实校验：割让该边城后不得令本土剩余城池全部断粮
        const simAfterCede: Map<string, SupplyEvaluationResult> = evaluateSupplyMapInternal(
          state,
          selfFac.factionId,
          rn.nodeId,
          targetEnemyId
        );
        let createsSevered: boolean = false;
        const simVals: SupplyEvaluationResult[] = Array.from(simAfterCede.values());
        for (let k: number = 0; k < simVals.length; k++) {
          if (simVals[k].grade === SupplyLineGrade.SEVERED) {
            createsSevered = true;
            break;
          }
        }
        if (createsSevered) {
          continue;
        }

        const costScore: number =
          (sn.isSupplyDepot ? 500 : 0) + sn.goldYield + sn.grainYield + sn.woodYield;
        if (costScore < bestCessionCostScore) {
          bestCessionCostScore = costScore;
          chosenBorderCession = rn.nodeId;
        }
      }

      if (chosenBorderCession.length > 0) {
        cededNodes.push(chosenBorderCession);
      }
    }

    return {
      proposer: selfFac.factionId,
      target: targetEnemyId,
      goldIndemnity: desiredGold,
      grainTributePerTurn: desiredGrainPerTurn,
      cededNodeIds: cededNodes,
      truceTurns: truceTurns
    };
  }

  /**
   * 合纵抗霸（>=13 城）与基于性格的结盟/通商外交规划
   */
  private planCoalitionAndDiplomacyActions(
    state: CampaignSaveState,
    selfFac: FactionCampaignRuntime,
    assessment: FactionStrategicAssessment,
    budget: TurnResourceBudget,
    peaceTargetChosen: FactionId | null,
    actions: StrategicTurnAction[]
  ): void {
    const selfId: FactionId = selfFac.factionId;
    const hegemon: FactionId | null = assessment.hegemonFaction;
    const antiHegemonyTriggered: boolean = hegemon !== null && hegemon !== selfId;
    const selfBordersHegemon: boolean =
      antiHegemonyTriggered && hegemon !== null && areFactionsAdjacent(state.nodes, selfId, hegemon);

    let bestAllianceTarget: FactionId | null = null;
    let bestAllianceScore: number = -1e9;
    let bestAllianceReason: string = '';

    let bestTradeTarget: FactionId | null = null;
    let bestTradeScore: number = -1e9;
    let bestTradeReason: string = '';

    for (let i: number = 0; i < state.factions.length; i++) {
      const other: FactionCampaignRuntime = state.factions[i];
      if (!other.isAlive || other.factionId === selfId) {
        continue;
      }
      const otherId: FactionId = other.factionId;
      // 绝不向 >=13 城的扩张霸主献媚结盟
      if (hegemon !== null && otherId === hegemon) {
        continue;
      }
      if (getVendettaLockTurns(state.diplomacy, selfId, otherId) > 0) {
        continue;
      }

      const status: DiplomaticStatus = getDiplomaticStatus(state.diplomacy, selfId, otherId);
      const baseRelation: number = getBilateralRelation(state.diplomacy, selfId, otherId);
      const isNeighbor: boolean = areFactionsAdjacent(state.nodes, selfId, otherId);
      const otherBordersHegemon: boolean =
        antiHegemonyTriggered && hegemon !== null && areFactionsAdjacent(state.nodes, otherId, hegemon);

      // 合纵警觉修正：当存在 >=13 城霸主且双方相邻或同受霸主接壤威胁时，自动附加 +25 共同威胁好感与高额合作权重
      const sharesAntiHegemonyInterest: boolean =
        antiHegemonyTriggered && (isNeighbor || (selfBordersHegemon && otherBordersHegemon));
      const effectiveRelation: number =
        baseRelation + (sharesAntiHegemonyInterest ? ANTI_HEGEMONY_RELATION_BONUS : 0);

      // 若在反霸权警觉下与相邻非霸主处于交战，且尚未发议和使者，优先停战化敌为友！
      if (
        sharesAntiHegemonyInterest &&
        status === DiplomaticStatus.WAR &&
        peaceTargetChosen === null &&
        assessment.personality !== AiPersonality.ZEALOT_SWARM
      ) {
        const truceOffer: PeaceOfferTerms = this.buildAffordablePeaceOffer(state, selfFac, otherId, budget, 2);
        budget.gold = Math.max(0, budget.gold - truceOffer.goldIndemnity);
        actions.push(
          createAction(
            StrategicActionType.PROPOSE_PEACE,
            selfId,
            otherId,
            selfFac.armyLocationNodeId,
            '',
            null,
            0,
            null,
            '',
            truceOffer,
            88.0,
            `反霸权合纵止戈：霸主 ${hegemon} 已占 ${assessment.hegemonCityCount} 城（>=13），主动与邻国 ${otherId} 停火共御强权`
          )
        );
        continue;
      }

      if (status === DiplomaticStatus.WAR || status === DiplomaticStatus.ALLIANCE) {
        continue;
      }

      // 霜原熊族鄙视低信誉背盟小人（DESIGN.md 第 6 节）
      if (assessment.personality === AiPersonality.HONOR_BERSERK_BEAR && other.credibility < 50) {
        continue;
      }

      // 评估缔结【军事攻守同盟】效用
      const canProposeAllianceNormally: boolean =
        effectiveRelation >= GameConstants.ALLIANCE_MIN_RELATION &&
        selfFac.credibility >= GameConstants.ALLIANCE_MIN_CREDIBILITY &&
        other.credibility >= 45;
      const canProposeAntiHegemonyCoalition: boolean =
        sharesAntiHegemonyInterest &&
        selfFac.credibility >= 40 &&
        effectiveRelation >= 15;

      if (canProposeAllianceNormally || canProposeAntiHegemonyCoalition) {
        let allyScore: number = effectiveRelation * 0.8 + (isNeighbor ? 18 : 6);
        if (sharesAntiHegemonyInterest) {
          allyScore += 55.0;
        }
        if (assessment.personality === AiPersonality.FORTRESS_COUNTER) {
          allyScore += 20.0; // 铁鹰王国喜结防御同盟
        } else if (assessment.personality === AiPersonality.IMPERIAL_METHODICAL) {
          allyScore += 12.0;
        }
        // 若与该邻国结盟可借道缓解我方远征/断粮压力，额外加分
        if (assessment.severedOwnNodeIds.length > 0 && isNeighbor) {
          allyScore += 25.0;
        }

        if (allyScore > bestAllianceScore) {
          bestAllianceScore = allyScore;
          bestAllianceTarget = otherId;
          bestAllianceReason = sharesAntiHegemonyInterest
            ? `反霸权合纵警觉：${hegemon} 坐拥 ${assessment.hegemonCityCount} 城逾越 35% 红线，联合邻邦 ${otherId} 结成反扩张军事同盟`
            : `远交近攻战略协同：与高好感友邦 ${otherId}（有效关系 ${effectiveRelation}）缔结攻守同盟共享补给视野`;
        }
      }

      // 评估缔结【丝路通商协定】效用（商盟、守信正统诸侯及无边境摩擦的远邦更易率先互通有无，逐步升温至同盟）
      const highTrustMutualTrade: boolean =
        effectiveRelation >= 5 &&
        selfFac.credibility >= 75 &&
        other.credibility >= 75 &&
        (!isNeighbor ||
          assessment.personality === AiPersonality.FORTRESS_COUNTER ||
          assessment.personality === AiPersonality.IMPERIAL_METHODICAL);

      if (
        status !== DiplomaticStatus.TRADE_PACT &&
        (effectiveRelation >= 25 ||
          (assessment.personality === AiPersonality.MERCHANT_PRAGMATIC && effectiveRelation >= 0) ||
          highTrustMutualTrade)
      ) {
        let tradeScore: number = effectiveRelation * 0.6 + 26.0;
        if (assessment.personality === AiPersonality.MERCHANT_PRAGMATIC) {
          tradeScore += 38.0; // 沙漠商盟通商收益 +35%
        } else if (!isNeighbor) {
          tradeScore += 14.0; // 远交近攻：远邦无领土摩擦，通商稳赚不赔
        }
        if (sharesAntiHegemonyInterest) {
          tradeScore += 20.0;
        }
        if (tradeScore > bestTradeScore) {
          bestTradeScore = tradeScore;
          bestTradeTarget = otherId;
          bestTradeReason = `互利通商增收：与 ${otherId} 签署丝路通商协定提升每回合金币税赋并稳固双边关系`;
        }
      }
    }

    if (bestAllianceTarget !== null && bestAllianceScore >= 55.0) {
      actions.push(
        createAction(
          StrategicActionType.PROPOSE_ALLIANCE,
          selfId,
          bestAllianceTarget,
          selfFac.armyLocationNodeId,
          '',
          null,
          0,
          null,
          '',
          null,
          bestAllianceScore,
          bestAllianceReason
        )
      );
    }

    if (bestTradeTarget !== null && bestTradeTarget !== bestAllianceTarget && bestTradeScore >= 36.0) {
      actions.push(
        createAction(
          StrategicActionType.PROPOSE_TRADE,
          selfId,
          bestTradeTarget,
          selfFac.armyLocationNodeId,
          '',
          null,
          0,
          null,
          '',
          null,
          bestTradeScore,
          bestTradeReason
        )
      );
    }
  }

  /**
   * 评估并解锁本势力尚未研发的专属三阶科技（保留安全军粮与招兵底金）
   */
  private planTechUnlockAction(
    selfFac: FactionCampaignRuntime,
    personality: AiPersonality,
    budget: TurnResourceBudget,
    actions: StrategicTurnAction[]
  ): void {
    const cfg: FactionStaticConfig | undefined = getFactionConfigById(selfFac.factionId);
    if (cfg === undefined) {
      return;
    }

    for (let i: number = 0; i < cfg.uniqueTechs.length; i++) {
      const tech: FactionTechItem = cfg.uniqueTechs[i];
      let unlocked: boolean = false;
      for (let j: number = 0; j < selfFac.unlockedTechIds.length; j++) {
        if (selfFac.unlockedTechIds[j] === tech.id) {
          unlocked = true;
          break;
        }
      }
      if (unlocked) {
        continue;
      }

      // 确保研发后仍留有至少 120 金与 140 粮维持军队运转
      const goldReserve: number = personality === AiPersonality.MERCHANT_PRAGMATIC ? 180 : 110;
      if (
        budget.gold >= tech.cost.gold + goldReserve &&
        budget.wood >= tech.cost.wood &&
        budget.grain >= tech.cost.grain + 140
      ) {
        budget.gold -= tech.cost.gold;
        budget.wood -= tech.cost.wood;
        budget.grain -= tech.cost.grain;
        actions.push(
          createAction(
            StrategicActionType.UNLOCK_TECH,
            selfFac.factionId,
            null,
            selfFac.armyLocationNodeId,
            '',
            null,
            0,
            null,
            tech.id,
            null,
            72.0 - i * 4.0,
            `研发势力专属科技《${tech.name}》：${tech.effectSummary}`
          )
        );
      }
      break;
    }
  }

  /**
   * 战役野战主力补员与多军团建制均衡配兵（严格遵循专属兵种归属与苍狼禁投石车铁律）
   */
  private planStrategicRecruitmentActions(
    state: CampaignSaveState,
    selfFac: FactionCampaignRuntime,
    assessment: FactionStrategicAssessment,
    budget: TurnResourceBudget,
    actions: StrategicTurnAction[]
  ): void {
    const cfg: FactionStaticConfig | undefined = getFactionConfigById(selfFac.factionId);
    if (cfg === undefined) {
      return;
    }

    let currentPop: number = 0;
    let vanguardCount: number = 0;
    let wingCount: number = 0;
    let reserveCount: number = 0;
    let siegeCount: number = 0;

    for (let i: number = 0; i < selfFac.fieldArmyRoster.length; i++) {
      const entry: RosterEntry = selfFac.fieldArmyRoster[i];
      const st: UnitStaticStats | undefined = getUnitConfigById(entry.unitType);
      const pop: number = st !== undefined ? st.popCap : 1;
      currentPop += entry.count * pop;
      if (entry.corpsRole === ArmyCorpsRole.VANGUARD_CENTER) {
        vanguardCount += entry.count;
      } else if (entry.corpsRole === ArmyCorpsRole.LEFT_WING || entry.corpsRole === ArmyCorpsRole.RIGHT_WING) {
        wingCount += entry.count;
      } else if (entry.corpsRole === ArmyCorpsRole.REAR_RESERVE) {
        reserveCount += entry.count;
      } else if (entry.corpsRole === ArmyCorpsRole.SIEGE_BATTERY) {
        siegeCount += entry.count;
      }
    }

    if (currentPop >= GameConstants.DEFAULT_ARMY_POP_CAP - 6 || budget.grain <= 180) {
      return;
    }

    // 决定优先补强的建制槽位与兵种（按 DESIGN.md 9.2 的 40% 前锋 / 36% 两翼 / 24% 预备队健康配比）
    let chosenUnit: UnitTypeId = cfg.exclusiveUnitId;
    let chosenRole: ArmyCorpsRole = ArmyCorpsRole.REAR_RESERVE;

    if (vanguardCount < 28) {
      chosenRole = ArmyCorpsRole.VANGUARD_CENTER;
      if (
        selfFac.factionId === FactionId.YANLONG ||
        selfFac.factionId === FactionId.SHUANGYUAN ||
        selfFac.factionId === FactionId.XUEYUE
      ) {
        chosenUnit = cfg.exclusiveUnitId;
      } else if (selfFac.factionId === FactionId.TIEYING) {
        chosenUnit = UnitTypeId.PIKEMAN;
      } else {
        chosenUnit = UnitTypeId.SHIELD_SWORDSMAN;
      }
    } else if (wingCount < 20) {
      chosenRole = wingCount % 2 === 0 ? ArmyCorpsRole.LEFT_WING : ArmyCorpsRole.RIGHT_WING;
      if (
        selfFac.factionId === FactionId.CANGLANG ||
        selfFac.factionId === FactionId.SHAMO ||
        selfFac.factionId === FactionId.XUANJIA
      ) {
        chosenUnit = cfg.exclusiveUnitId;
      } else {
        chosenUnit = UnitTypeId.LIGHT_CAVALRY;
      }
    } else if (
      siegeCount < 6 &&
      selfFac.factionId !== FactionId.CANGLANG &&
      (assessment.personality === AiPersonality.IMPERIAL_METHODICAL ||
        assessment.personality === AiPersonality.FORTRESS_COUNTER)
    ) {
      chosenRole = ArmyCorpsRole.SIEGE_BATTERY;
      chosenUnit =
        selfFac.factionId === FactionId.YANLONG ? UnitTypeId.TREBUCHET : UnitTypeId.TIEYING_PAVISE_CROSSBOW;
    } else if (reserveCount < 16) {
      chosenRole = ArmyCorpsRole.REAR_RESERVE;
      chosenUnit = cfg.exclusiveUnitId;
    } else {
      chosenRole = ArmyCorpsRole.VANGUARD_CENTER;
      chosenUnit = cfg.exclusiveUnitId;
    }

    // 苍狼汗国绝对禁造投石车兜底校验
    if (selfFac.factionId === FactionId.CANGLANG && chosenUnit === UnitTypeId.TREBUCHET) {
      chosenUnit = UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER;
    }

    const unitStats: UnitStaticStats | undefined = getUnitConfigById(chosenUnit);
    if (unitStats === undefined) {
      return;
    }

    const safeGold: number = Math.max(0, budget.gold - (assessment.personality === AiPersonality.MERCHANT_PRAGMATIC ? 150 : 60));
    const safeWood: number = Math.max(0, budget.wood - 40);
    const safeGrain: number = Math.max(0, budget.grain - 180);

    const maxByGold: number = unitStats.cost.gold > 0 ? Math.floor(safeGold / unitStats.cost.gold) : 12;
    const maxByWood: number = unitStats.cost.wood > 0 ? Math.floor(safeWood / unitStats.cost.wood) : 12;
    const maxByGrain: number = unitStats.cost.grain > 0 ? Math.floor(safeGrain / unitStats.cost.grain) : 12;
    const recruitCount: number = Math.min(8, maxByGold, maxByWood, maxByGrain);

    if (recruitCount >= 2) {
      budget.gold -= recruitCount * unitStats.cost.gold;
      budget.wood -= recruitCount * unitStats.cost.wood;
      budget.grain -= recruitCount * unitStats.cost.grain;

      const spawnNode: string =
        selfFac.armyLocationNodeId.length > 0 ? selfFac.armyLocationNodeId : cfg.capitalNodeId;
      actions.push(
        createAction(
          StrategicActionType.RECRUIT,
          selfFac.factionId,
          null,
          spawnNode,
          spawnNode,
          chosenUnit,
          recruitCount,
          chosenRole,
          '',
          null,
          64.0,
          `扩编主力建制：于 ${spawnNode} 征募 ${recruitCount} 队【${unitStats.name}】充实 ${chosenRole}`
        )
      );
    }
  }

  /**
   * 在接壤前线雄关/密林/渡口或补给咽喉预设【打援伏兵 / 诡道陷阱】（setAmbushTrap）
   */
  private planAmbushTrapAction(
    state: CampaignSaveState,
    selfFac: FactionCampaignRuntime,
    assessment: FactionStrategicAssessment,
    budget: TurnResourceBudget,
    actions: StrategicTurnAction[]
  ): void {
    if (budget.wood < 50 || budget.gold < 40) {
      return;
    }

    let bestTrapNodeId: string = '';
    let bestTrapScore: number = -1e9;
    let bestTrapReason: string = '';

    for (let i: number = 0; i < state.nodes.length; i++) {
      const rn: CampaignNodeRuntime = state.nodes[i];
      if (rn.owner !== selfFac.factionId || rn.hasAmbushTrap) {
        continue;
      }
      const sn: CampaignNodeConfig | undefined = getStaticNodeById(rn.nodeId);
      if (sn === undefined) {
        continue;
      }

      let bordersHostileOrRival: boolean = false;
      let bordersWarEnemy: boolean = false;
      for (let j: number = 0; j < sn.neighbors.length; j++) {
        const nb: CampaignNodeRuntime | undefined = getRuntimeNodeById(state.nodes, sn.neighbors[j]);
        if (nb === undefined || nb.owner === selfFac.factionId) {
          continue;
        }
        const st: DiplomaticStatus = getDiplomaticStatus(state.diplomacy, selfFac.factionId, nb.owner);
        if (st === DiplomaticStatus.WAR) {
          bordersWarEnemy = true;
          bordersHostileOrRival = true;
        } else if (st === DiplomaticStatus.NEUTRAL) {
          bordersHostileOrRival = true;
        }
      }

      if (!bordersHostileOrRival) {
        continue;
      }

      let score: number = bordersWarEnemy ? 42.0 : 18.0;
      if (sn.terrain === TerrainType.DENSE_FOREST) {
        score += 24.0;
      } else if (sn.terrain === TerrainType.HIGH_GROUND || sn.terrain === TerrainType.BRIDGE_PASS) {
        score += 20.0;
      }
      if (sn.nodeType === CampaignNodeType.FORTRESS_PASS || sn.nodeType === CampaignNodeType.CROSSING_OUTPOST) {
        score += 18.0;
      }
      if (sn.isSupplyDepot) {
        score += 22.0; // 保护自身前线补给仓城咽喉
      }
      if (assessment.personality === AiPersonality.GUERRILLA_TRAPPER) {
        score += 32.0; // 雾林猎手酷爱密林设伏
      } else if (assessment.personality === AiPersonality.FORTRESS_COUNTER) {
        score += 22.0; // 铁鹰王国善守险关围点打援
      }

      if (score > bestTrapScore) {
        bestTrapScore = score;
        bestTrapNodeId = rn.nodeId;
        bestTrapReason = sn.isSupplyDepot
          ? `护卫粮道咽喉：在前线补给重镇【${sn.name}】布设打援伏兵防敌奇袭断粮`
          : `险要设伏打援：在边境要冲【${sn.name}】（${sn.terrain}）预设伏击袋截杀来犯/驰援敌军`;
      }
    }

    if (bestTrapNodeId.length > 0 && bestTrapScore >= 52.0) {
      budget.gold = Math.max(0, budget.gold - 40);
      budget.wood = Math.max(0, budget.wood - 50);
      actions.push(
        createAction(
          StrategicActionType.SET_AMBUSH_TRAP,
          selfFac.factionId,
          null,
          bestTrapNodeId,
          bestTrapNodeId,
          null,
          0,
          null,
          '',
          null,
          bestTrapScore,
          bestTrapReason
        )
      );
    }
  }

  /**
   * 评估全图所有接壤非同盟节点的进军攻伐价值（含打通己方断粮通道 + 截断敌方咽喉图割仿真）
   */
  private scoreBorderAttackTargets(
    state: CampaignSaveState,
    selfId: FactionId,
    personality: AiPersonality,
    selfPower: number,
    hegemonFaction: FactionId | null,
    strongWarEnemies: FactionId[],
    severedOwnNodeIds: string[],
    peaceTargetChosen: FactionId | null
  ): AttackTargetCandidate[] {
    const candidates: AttackTargetCandidate[] = [];
    const selfFac: FactionCampaignRuntime | undefined = getRuntimeFactionById(state.factions, selfId);
    const staticSelf: FactionStaticConfig | undefined = getFactionConfigById(selfId);
    if (selfFac === undefined || staticSelf === undefined) {
      return candidates;
    }

    const homeCapitalCfg: CampaignNodeConfig | undefined = getStaticNodeById(staticSelf.capitalNodeId);
    const homeRegionIndex: number = homeCapitalCfg !== undefined ? homeCapitalCfg.regionIndex : -1;

    // 预缓存各敌对邻国当前的补给断绝基线，用于图割差值计算
    const baselineEnemySeveredCount: Map<FactionId, number> = new Map<FactionId, number>();

    // 遍历所有由本方控制的边境出发点 -> 相邻异国目标节点
    const evaluatedTargetSet: Set<string> = new Set<string>();

    for (let i: number = 0; i < state.nodes.length; i++) {
      const myNode: CampaignNodeRuntime = state.nodes[i];
      if (myNode.owner !== selfId) {
        continue;
      }
      const myStatic: CampaignNodeConfig | undefined = getStaticNodeById(myNode.nodeId);
      if (myStatic === undefined) {
        continue;
      }

      for (let j: number = 0; j < myStatic.neighbors.length; j++) {
        const targetId: string = myStatic.neighbors[j];
        const pairKey: string = `${myNode.nodeId}->${targetId}`;
        if (evaluatedTargetSet.has(pairKey)) {
          continue;
        }
        evaluatedTargetSet.add(pairKey);

        const targetRuntime: CampaignNodeRuntime | undefined = getRuntimeNodeById(state.nodes, targetId);
        const targetStatic: CampaignNodeConfig | undefined = getStaticNodeById(targetId);
        if (targetRuntime === undefined || targetStatic === undefined || targetRuntime.owner === selfId) {
          continue;
        }

        const defenderId: FactionId = targetRuntime.owner;
        if (peaceTargetChosen !== null && defenderId === peaceTargetChosen) {
          continue;
        }

        const dipStatus: DiplomaticStatus = getDiplomaticStatus(state.diplomacy, selfId, defenderId);
        // 严守信誉底线：绝不背刺正式军事同盟、互不侵犯或停战期内目标（避免 -45 信誉崩盘与天下共愤）
        if (
          dipStatus === DiplomaticStatus.ALLIANCE ||
          dipStatus === DiplomaticStatus.NON_AGGRESSION ||
          dipStatus === DiplomaticStatus.TRUCE ||
          dipStatus === DiplomaticStatus.VASSAL
        ) {
          continue;
        }

        const requiresDeclareWar: boolean = dipStatus !== DiplomaticStatus.WAR;

        // 两线作战预防：除狂热扩张的血月祭司团外，若已与 >=1 强敌交战，绝不主动向新的中立国宣战开辟第二战线（除非为夺回断粮死穴！）
        let reconnectsOwnSupply: boolean = false;
        if (severedOwnNodeIds.length > 0) {
          const simOwnSupply: Map<string, SupplyEvaluationResult> = evaluateSupplyMapInternal(
            state,
            selfId,
            targetId,
            selfId
          );
          let remainingSevered: number = 0;
          for (let sIdx: number = 0; sIdx < severedOwnNodeIds.length; sIdx++) {
            const checkRes: SupplyEvaluationResult | undefined = simOwnSupply.get(severedOwnNodeIds[sIdx]);
            if (checkRes === undefined || checkRes.grade === SupplyLineGrade.SEVERED) {
              remainingSevered += 1;
            }
          }
          if (remainingSevered < severedOwnNodeIds.length) {
            reconnectsOwnSupply = true;
          }
        }
        // 若我方本区固有补给仓城被夺占，同样视作夺回自身粮道核心节点！
        if (targetStatic.regionIndex === homeRegionIndex && targetStatic.isSupplyDepot) {
          reconnectsOwnSupply = true;
        }

        if (
          requiresDeclareWar &&
          !reconnectsOwnSupply &&
          personality !== AiPersonality.ZEALOT_SWARM &&
          strongWarEnemies.length >= 1
        ) {
          continue;
        }

        // 反事实图割模拟：若攻占 targetId，敌方 defenderId 会新增多少座断粮孤城？
        if (!baselineEnemySeveredCount.has(defenderId)) {
          const baseMap: Map<string, SupplyEvaluationResult> = computeFactionSupplyMap(state, defenderId);
          let baseSev: number = 0;
          const baseVals: SupplyEvaluationResult[] = Array.from(baseMap.values());
          for (let bIdx: number = 0; bIdx < baseVals.length; bIdx++) {
            if (baseVals[bIdx].grade === SupplyLineGrade.SEVERED) {
              baseSev += 1;
            }
          }
          baselineEnemySeveredCount.set(defenderId, baseSev);
        }

        const postCaptureEnemySupply: Map<string, SupplyEvaluationResult> = evaluateSupplyMapInternal(
          state,
          defenderId,
          targetId,
          selfId
        );
        let postSev: number = 0;
        let postOverextended: number = 0;
        const postVals: SupplyEvaluationResult[] = Array.from(postCaptureEnemySupply.values());
        for (let pIdx: number = 0; pIdx < postVals.length; pIdx++) {
          if (postVals[pIdx].grade === SupplyLineGrade.SEVERED) {
            postSev += 1;
          } else if (postVals[pIdx].grade !== SupplyLineGrade.FULL_SUPPLY) {
            postOverextended += 1;
          }
        }
        const newlySeveredEnemyNodes: number = Math.max(
          0,
          postSev - (baselineEnemySeveredCount.get(defenderId) ?? 0)
        );

        const isEnemySupplyThroat: boolean =
          newlySeveredEnemyNodes > 0 ||
          (targetStatic.isSupplyDepot && targetRuntime.garrisonStrength <= 125) ||
          ((targetStatic.nodeType === CampaignNodeType.CROSSING_OUTPOST ||
            targetStatic.nodeType === CampaignNodeType.FORTRESS_PASS) &&
            (targetRuntime.isolatedTurns > 0 || targetRuntime.supplyGrade !== SupplyLineGrade.FULL_SUPPLY));

        // 综合效用函数计算
        const defenderPower: number = Math.max(40, computeFactionMilitaryPower(state, defenderId));
        const localResistance: number =
          targetRuntime.garrisonStrength * 0.42 +
          targetRuntime.defenseHp * 0.035 +
          targetStatic.defenseLevel * 7.5 +
          (targetRuntime.hasAmbushTrap ? 18.0 : 0);

        const economicScore: number =
          targetStatic.goldYield * 0.16 +
          targetStatic.woodYield * 0.11 +
          targetStatic.grainYield * (personality === AiPersonality.HONOR_BERSERK_BEAR ? 0.24 : 0.18);

        let utility: number = economicScore - localResistance * 0.45;
        utility += clampNum((selfPower / defenderPower) * 24.0, 4.0, 48.0);

        if (dipStatus === DiplomaticStatus.WAR) {
          utility += 34.0;
        } else if (dipStatus === DiplomaticStatus.TRADE_PACT) {
          utility -= personality === AiPersonality.MERCHANT_PRAGMATIC ? 65.0 : 38.0;
        }

        // 核心指标 4A：夺回被切断的自身粮道仓城通道（最高优先级！）
        if (reconnectsOwnSupply) {
          utility += 115.0;
        }

        // 核心指标 4B：截断敌军补给咽喉或奇袭孤立仓城
        if (newlySeveredEnemyNodes > 0) {
          utility += 48.0 * newlySeveredEnemyNodes + 10.0 * postOverextended;
        }
        if (isEnemySupplyThroat) {
          utility += 36.0;
        }
        if (targetStatic.isSupplyDepot) {
          utility += 24.0;
        }

        // 核心指标 3：反霸权遏制（霸主占城 >= 13 时，优先打击霸主薄弱边城）
        if (hegemonFaction !== null && defenderId === hegemonFaction) {
          utility += 32.0;
        }

        // 收复故土加成（炎龙、雾林尤重核心疆域）
        if (targetStatic.regionIndex === homeRegionIndex) {
          utility += personality === AiPersonality.IMPERIAL_METHODICAL || personality === AiPersonality.GUERRILLA_TRAPPER ? 52.0 : 30.0;
        }

        // 八大势力性格差异化战术偏好
        if (personality === AiPersonality.NOMAD_OPPORTUNIST) {
          // 苍狼汗国：见弱则扑、专劫高产粮仓，忌啃 5 级坚城王都
          if (targetRuntime.garrisonStrength <= 85) {
            utility += 28.0;
          }
          if (targetStatic.nodeType === CampaignNodeType.GRANARY_TOWN) {
            utility += 22.0;
          }
          if (targetStatic.defenseLevel >= 5) {
            utility -= 22.0;
          }
        } else if (personality === AiPersonality.FORTRESS_COUNTER) {
          // 铁鹰王国：稳健谨慎，非交战态不轻启战端，偏爱夺取制高关隘
          if (requiresDeclareWar && !reconnectsOwnSupply) {
            utility -= 24.0;
          }
          if (targetStatic.nodeType === CampaignNodeType.FORTRESS_PASS) {
            utility += 16.0;
          }
        } else if (personality === AiPersonality.MERCHANT_PRAGMATIC) {
          // 沙漠商盟：无利不起早，看重高金矿商埠，厌恶赔本硬仗
          utility += targetStatic.goldYield * 0.14;
          if (requiresDeclareWar && selfPower < defenderPower * 1.15) {
            utility -= 26.0;
          }
        } else if (personality === AiPersonality.HONOR_BERSERK_BEAR) {
          // 霜原熊族：痛击背盟失信之徒，无惧雪原硬仗
          const defFac: FactionCampaignRuntime | undefined = getRuntimeFactionById(state.factions, defenderId);
          if (defFac !== undefined && defFac.credibility < 50) {
            utility += 30.0;
          }
          if (targetStatic.terrain === TerrainType.SNOWFIELD) {
            utility += 16.0;
          }
        } else if (personality === AiPersonality.GUERRILLA_TRAPPER) {
          // 雾林猎手：密林作战强悍，不喜深入无遮挡荒漠平原远征
          if (targetStatic.terrain === TerrainType.DENSE_FOREST) {
            utility += 25.0;
          } else if (targetStatic.terrain === TerrainType.PLAIN && !reconnectsOwnSupply) {
            utility -= 14.0;
          }
        } else if (personality === AiPersonality.IRON_SHOCK_ELITE) {
          // 玄甲重骑：偏爱开阔平原铁骑驰骋
          if (targetStatic.terrain === TerrainType.PLAIN) {
            utility += 24.0;
          }
        } else if (personality === AiPersonality.ZEALOT_SWARM) {
          // 血月祭司团：狂热扩张好战加成
          utility += 26.0;
        }

        // 若主力军团刚好驻扎在该出发城池，省去调动损耗加分
        if (myNode.nodeId === selfFac.armyLocationNodeId) {
          utility += 12.0;
        }

        let reasonText: string = `战略进军【${targetStatic.name}】（守方 ${defenderId}）`;
        if (reconnectsOwnSupply) {
          reasonText = `死战打通粮道：紧急反扑夺回咽喉仓城通道【${targetStatic.name}】，解救本方断粮孤城`;
        } else if (newlySeveredEnemyNodes > 0 || isEnemySupplyThroat) {
          reasonText = `奇袭截断敌方咽喉：攻取补给枢纽【${targetStatic.name}】可一举切断 ${defenderId} 后方 ${Math.max(1, newlySeveredEnemyNodes)} 座城池粮道`;
        } else if (hegemonFaction !== null && defenderId === hegemonFaction) {
          reasonText = `反霸权联合作战：主动出击牵制霸主 ${defenderId} 边境要地【${targetStatic.name}】`;
        }

        candidates.push({
          fromNodeId: myNode.nodeId,
          targetNodeId: targetId,
          defenderFaction: defenderId,
          utilityScore: utility,
          reconnectsOwnSupply: reconnectsOwnSupply,
          seversEnemyNodesCount: newlySeveredEnemyNodes,
          isEnemySupplyThroat: isEnemySupplyThroat,
          requiresDeclareWar: requiresDeclareWar,
          reason: reasonText
        });
      }
    }

    // 按效用分降序排列，分数相同时按节点 ID 稳定排序保证确定性可复现
    candidates.sort((a: AttackTargetCandidate, b: AttackTargetCandidate): number => {
      if (Math.abs(b.utilityScore - a.utilityScore) > 1e-6) {
        return b.utilityScore - a.utilityScore;
      }
      return a.targetNodeId.localeCompare(b.targetNodeId);
    });

    return candidates;
  }

  /**
   * 依据最优目标评分发出宣战（declareWar）与行军进攻（marchAttack）指令
   */
  private planOffensiveMarchAndWarActions(
    state: CampaignSaveState,
    selfFac: FactionCampaignRuntime,
    assessment: FactionStrategicAssessment,
    budget: TurnResourceBudget,
    peaceTargetChosen: FactionId | null,
    actions: StrategicTurnAction[]
  ): void {
    // 主帅重伤休养或扣除当回合内政征募后余粮濒临见底时暂缓远征（抢通断粮死穴除外）
    const candidates: AttackTargetCandidate[] = this.scoreBorderAttackTargets(
      state,
      selfFac.factionId,
      assessment.personality,
      assessment.militaryPower,
      assessment.hegemonFaction,
      assessment.strongWarEnemies,
      assessment.severedOwnNodeIds,
      peaceTargetChosen
    );

    if (candidates.length === 0) {
      return;
    }

    const best: AttackTargetCandidate = candidates[0];
    if (!best.reconnectsOwnSupply && budget.grain < 120) {
      return;
    }

    const warThreshold: number =
      assessment.personality === AiPersonality.ZEALOT_SWARM
        ? 44.0
        : assessment.personality === AiPersonality.NOMAD_OPPORTUNIST
          ? 50.0
          : 56.0;
    const marchThreshold: number = best.reconnectsOwnSupply ? 30.0 : best.requiresDeclareWar ? warThreshold : 42.0;

    if (best.utilityScore < marchThreshold) {
      return;
    }

    if (best.requiresDeclareWar) {
      actions.push(
        createAction(
          StrategicActionType.DECLARE_WAR,
          selfFac.factionId,
          best.defenderFaction,
          best.fromNodeId,
          best.targetNodeId,
          null,
          0,
          null,
          '',
          null,
          best.utilityScore,
          `正式宣战：向无盟约约束的邻国 ${best.defenderFaction} 宣战以夺取战略目标【${best.targetNodeId}】`
        )
      );
    }

    actions.push(
      createAction(
        StrategicActionType.MARCH_ATTACK,
        selfFac.factionId,
        best.defenderFaction,
        best.fromNodeId,
        best.targetNodeId,
        null,
        0,
        null,
        '',
        null,
        best.utilityScore,
        best.reason
      )
    );
  }
}

/**
 * 纯函数式单势力战略回合决策入口
 */
export function evaluateCampaignStrategicTurn(
  state: CampaignSaveState,
  factionId: FactionId
): StrategicTurnAction[] {
  const ai: CampaignStrategicAI = new CampaignStrategicAI();
  return ai.evaluateFactionTurn(state, factionId);
}
