/**
 * 40 城关战略战役状态机引擎（CampaignEngine.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖）
 *
 * 核心职责（严格对齐 DESIGN.md 第 1、2、6、7.3、8、10 节）：
 * 1. 按 `CAMPAIGN_MAP_NODES` 初始化 8 大势力各 5 座城关、初始三维资源、多军团主力编制与双边外交矩阵；
 * 2. 支持征募兵种（含专属兵种校验、苍狼禁投石车、商盟纯金雇佣军、人口上限 240）、解锁三阶专属科技；
 * 3. 支持行军至相邻节点，自动识别野战/攻城/守城/伏击/护粮/夜袭 6 类关卡并生成 `BattleInitConfig`；
 * 4. 支持预设【围点打援】伏击圈，打援大捷令被围孤城守军士气直接锐减 -25；
 * 5. 完整结算战后回写 `applyBattleSettlement`（伤兵恢复、俘虏收编/换赎金、城池易手、主帅升级、二次阵亡 2 回合休养）；
 * 6. 推进大地图回合结算（税赋产粮、丝路通商、围城断粮 2 回合起 8% 减员、守约到期 +3 信誉、AI 钩子、八王都统一或同盟霸权胜利判定）。
 */
import { GameConstants } from '../../common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../../config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../../config/FactionConfig';
import { getUnitConfigById } from '../../config/UnitConfig';
import {
  CampaignNodeConfig,
  CampaignNodeType,
  FactionStaticConfig,
  FactionTechItem,
  ResourceCost,
  UnitCategory,
  UnitStaticStats
} from '../../model/GameTypes';
import {
  ArmyCorpsRole,
  BattleInitConfig,
  BattleOutcomeReason,
  BattleScenarioType,
  BattleSettlementSummary,
  BetrayalAssessment,
  BilateralDiplomacyState,
  CampaignNodeRuntime,
  CampaignSaveState,
  DiplomaticStatus,
  FactionCampaignRuntime,
  FactionId,
  PeaceOfferTerms,
  RosterEntry,
  SupplyEvaluationResult,
  SupplyLineGrade,
  TerrainType,
  UnitTypeId,
  WeatherType
} from '../CoreContracts';
import {
  DiplomacyEngine,
  DiplomacyTurnReport,
  PeaceExecutionResult,
  WarDeclarationContext,
  WarDeclarationResult
} from '../diplomacy/DiplomacyEngine';
import { SeveredIsolationImpact, SupplyLineEngine } from './SupplyLineEngine';

/** 战俘处置策略枚举 */
export enum PrisonerDisposition {
  RANSOM = 'ransom',   // 遣返换取赎金
  RECRUIT = 'recruit'  // 整编收编入伍（超出人口上限部分自动折算赎金）
}

/** 战役全局胜负终局状态枚举 */
export enum CampaignVictoryKind {
  ONGOING = 'ongoing',
  UNIFIED_ALL_CAPITALS = 'unified_all_capitals', // 独占全图全部 8 座王都
  ALLIANCE_HEGEMONY = 'alliance_hegemony',       // 与正式军事同盟共掌全部 8 座王都及 >=75% 版图
  PLAYER_ELIMINATED = 'player_eliminated',       // 玩家失去全部城关覆灭
  RIVAL_UNIFIED = 'rival_unified'                // 敌对强权抢先统一全图 8 座王都
}

/** 战役胜利判定结果 */
export interface CampaignVictoryResult {
  readonly kind: CampaignVictoryKind;
  readonly winnerFaction: FactionId | null;
  readonly playerControlledCapitals: number;
  readonly alliedControlledCapitals: number;
  readonly totalCapitals: number;
  readonly summaryText: string;
}

/** 征募或科技研发通用操作结果 */
export interface CampaignOperationResult {
  readonly success: boolean;
  readonly message: string;
  readonly costGold: number;
  readonly costWood: number;
  readonly costGrain: number;
}

/** 行军指令可选参数 */
export interface MarchActionOptions {
  /** 当目标处于同盟/互不侵犯/停战期时，是否已通过玩家二次弹窗确认强行背盟进攻 */
  readonly confirmBetrayal?: boolean;
  /** 当目标处于中立/通商态时，是否允许行军自动正式宣战（默认 true） */
  readonly autoDeclareWar?: boolean;
  /** 主动选择发动黑夜劫营夜袭 */
  readonly preferNightRaid?: boolean;
  /** 主动选择发动奇袭劫粮护粮战 */
  readonly preferConvoyRaid?: boolean;
  /** 协防受侵略共同盟友 ID（触发双重同盟防御豁免） */
  readonly defendingVictimAlly?: FactionId;
}

/** 行军结果（和平移防 或 触发战斗配置 或 阻断提示背盟确认） */
export interface MarchActionResult {
  readonly success: boolean;
  readonly battleTriggered: boolean;
  readonly requiresBetrayalConfirmation: boolean;
  readonly betrayalAssessment: BetrayalAssessment | null;
  readonly battleConfig: BattleInitConfig | null;
  readonly supplyEvaluation: SupplyEvaluationResult | null;
  readonly message: string;
}

/** 战后回写结算反馈报告 */
export interface SettlementApplyReport {
  readonly netPlayerLosses: number;
  readonly prisonersRecruited: number;
  readonly ransomGoldGained: number;
  readonly nodeCaptured: boolean;
  readonly reliefAmbushMoraleShockAppliedTo: string[];
  readonly commanderLeveledUp: boolean;
  readonly newCommanderLevel: number;
  readonly commanderInjuredTurns: number;
  readonly victoryCheck: CampaignVictoryResult;
}

/** 回合推进汇总报告 */
export interface CampaignTurnAdvanceReport {
  readonly newTurnNumber: number;
  readonly emergencySeveredNodes: string[];
  readonly attritionSeveredNodes: string[];
  readonly diplomacyReport: DiplomacyTurnReport;
  readonly aiActionsExecuted: number;
  readonly victoryCheck: CampaignVictoryResult;
}

/** L1 战略 AI 单势力回合行动回调钩子签名 */
export type CampaignAiTurnHook = (engine: CampaignEngine, aiFaction: FactionId) => void;

/**
 * 战略大地图 40 城关核心状态机
 */
export class CampaignEngine {
  public static readonly CURRENT_SCHEMA_VERSION: number = 1;
  public static readonly MAX_RECENT_LOGS: number = 40;
  public static readonly RANSOM_GOLD_PER_PRISONER: number = 18;
  public static readonly RELIEF_AMBUSH_GARRISON_MORALE_PENALTY: number = -25;

  private readonly supplyEngine: SupplyLineEngine;
  private readonly diplomacyEngine: DiplomacyEngine;
  private readonly staticNodeMap: Map<string, CampaignNodeConfig>;
  private readonly capitalNodeIds: string[];

  /** 预设的【围点打援】伏击映射：设伏节点 ID -> 被围困目标敌城节点 ID */
  private readonly reliefAmbushTargetByNode: Map<string, string>;
  /** 因援军被伏击歼灭而承受孤城绝望 Debuff 的城池映射：敌城节点 ID -> 士气惩罚值（-25） */
  private readonly isolatedCityMoraleDebuffMap: Map<string, number>;

  private state: CampaignSaveState;

  public constructor(
    playerFaction: FactionId = FactionId.YANLONG,
    supplyEngine?: SupplyLineEngine,
    diplomacyEngine?: DiplomacyEngine
  ) {
    this.supplyEngine = supplyEngine !== undefined ? supplyEngine : new SupplyLineEngine(CAMPAIGN_MAP_NODES);
    this.diplomacyEngine =
      diplomacyEngine !== undefined ? diplomacyEngine : new DiplomacyEngine(CAMPAIGN_MAP_NODES);
    this.staticNodeMap = new Map<string, CampaignNodeConfig>();
    this.capitalNodeIds = [];
    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      const cfg: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
      this.staticNodeMap.set(cfg.id, cfg);
      if (cfg.nodeType === CampaignNodeType.CAPITAL_CITADEL) {
        this.capitalNodeIds.push(cfg.id);
      }
    }
    this.reliefAmbushTargetByNode = new Map<string, string>();
    this.isolatedCityMoraleDebuffMap = new Map<string, number>();
    this.state = this.buildInitialCampaignState(playerFaction);
  }

  /**
   * 获取底层 BFS 粮道引擎引用
   */
  public getSupplyEngine(): SupplyLineEngine {
    return this.supplyEngine;
  }

  /**
   * 获取底层外交谈判引擎引用
   */
  public getDiplomacyEngine(): DiplomacyEngine {
    return this.diplomacyEngine;
  }

  /**
   * 获取当前战役全局状态引用
   */
  public getState(): CampaignSaveState {
    return this.state;
  }

  /**
   * 重新开局并初始化指定玩家势力的完整 40 城战役
   */
  public startNewCampaign(playerFaction: FactionId): CampaignSaveState {
    this.diplomacyEngine.resetRuntimeTrackers();
    this.reliefAmbushTargetByNode.clear();
    this.isolatedCityMoraleDebuffMap.clear();
    this.state = this.buildInitialCampaignState(playerFaction);
    return this.state;
  }

  /**
   * 从已校验的存档快照恢复战役状态（同步还原外交追踪器与预设伏击圈映射）
   */
  public loadFromSaveState(saved: CampaignSaveState): void {
    this.reliefAmbushTargetByNode.clear();
    this.isolatedCityMoraleDebuffMap.clear();
    this.state = CampaignEngine.deepCloneSaveState(saved);
    this.diplomacyEngine.syncTrackersFromLoadedState(this.state.diplomacy, this.state.nodes);
    this.supplyEngine.refreshAllNodesSupply(this.state.nodes, this.state.diplomacy);

    for (let i: number = 0; i < this.state.nodes.length; i++) {
      const node: CampaignNodeRuntime = this.state.nodes[i];
      if (!node.hasAmbushTrap) {
        continue;
      }
      const cfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(node.nodeId);
      if (cfg === undefined) {
        continue;
      }
      for (let j: number = 0; j < cfg.neighbors.length; j++) {
        const nbr: CampaignNodeRuntime | undefined = this.getNodeRuntime(cfg.neighbors[j]);
        if (
          nbr !== undefined &&
          nbr.owner !== node.owner &&
          !this.diplomacyEngine.areAllied(this.state.diplomacy, node.owner, nbr.owner)
        ) {
          this.reliefAmbushTargetByNode.set(node.nodeId, nbr.nodeId);
          break;
        }
      }
    }
  }

  /**
   * 查询指定城关当前动态状态
   */
  public getNodeRuntime(nodeId: string): CampaignNodeRuntime | undefined {
    for (let i: number = 0; i < this.state.nodes.length; i++) {
      if (this.state.nodes[i].nodeId === nodeId) {
        return this.state.nodes[i];
      }
    }
    return undefined;
  }

  /**
   * 查询指定势力当前动态状态
   */
  public getFactionRuntime(factionId: FactionId): FactionCampaignRuntime | undefined {
    for (let i: number = 0; i < this.state.factions.length; i++) {
      if (this.state.factions[i].factionId === factionId) {
        return this.state.factions[i];
      }
    }
    return undefined;
  }

  /**
   * 查询某势力当前控制的城关总数
   */
  public countControlledNodes(factionId: FactionId): number {
    let count: number = 0;
    for (let i: number = 0; i < this.state.nodes.length; i++) {
      if (this.state.nodes[i].owner === factionId) {
        count++;
      }
    }
    return count;
  }

  /**
   * 查询指定城池因【围点打援】大捷而挂载的守军士气惩罚（未挂载为 0，打援获胜后为 -25）
   */
  public getBesiegedGarrisonMoraleModifier(nodeId: string): number {
    const val: number | undefined = this.isolatedCityMoraleDebuffMap.get(nodeId);
    return val !== undefined ? val : 0;
  }

  /**
   * 计算势力主力野战军团当前占用总人口
   */
  public computeArmyPopulationUsed(factionId: FactionId): number {
    const faction: FactionCampaignRuntime | undefined = this.getFactionRuntime(factionId);
    if (faction === undefined) {
      return 0;
    }
    let usedPop: number = 0;
    for (let i: number = 0; i < faction.fieldArmyRoster.length; i++) {
      const entry: RosterEntry = faction.fieldArmyRoster[i];
      const uCfg: UnitStaticStats | undefined = getUnitConfigById(entry.unitType);
      const popPerUnit: number = uCfg !== undefined ? uCfg.popCap : 1;
      usedPop += entry.count * popPerUnit;
    }
    return usedPop;
  }

  /**
   * 计算势力招募指定兵种的实际三维资源花费（含炎龙器械 -20%/骑兵 +15%、铁鹰突击金 +10%、商盟纯金币雇佣契约）
   */
  public computeRecruitmentCost(
    factionId: FactionId,
    unitType: UnitTypeId,
    count: number,
    useMercenaryGoldContract: boolean = false
  ): ResourceCost | null {
    const cleanCount: number = Math.floor(count);
    if (cleanCount <= 0) {
      return null;
    }
    const uCfg: UnitStaticStats | undefined = getUnitConfigById(unitType);
    const faction: FactionCampaignRuntime | undefined = this.getFactionRuntime(factionId);
    if (uCfg === undefined || faction === undefined) {
      return null;
    }

    let goldMult: number = 1.0;
    let woodMult: number = 1.0;
    let grainMult: number = 1.0;

    if (factionId === FactionId.YANLONG) {
      if (uCfg.category === UnitCategory.SIEGE) {
        goldMult = 0.80;
        woodMult = 0.80;
        grainMult = 0.80;
      } else if (uCfg.category === UnitCategory.CAVALRY) {
        goldMult = 1.15;
        woodMult = 1.15;
        grainMult = 1.15;
      }
    } else if (factionId === FactionId.TIEYING) {
      if (uCfg.category === UnitCategory.SHOCK) {
        goldMult = 1.10;
      }
    }

    if (factionId === FactionId.SHAMO && useMercenaryGoldContract) {
      // 沙漠商盟纯金币即时征召外邦雇佣军：《黄金契约》降低 20% 雇佣金
      const contractDiscount: number =
        faction.unlockedTechIds.indexOf('sm_tech_mercenary') >= 0 ? 0.80 : 1.0;
      const unitMercGold: number =
        (uCfg.cost.gold + uCfg.cost.wood * 0.85 + uCfg.cost.grain * 0.65) * contractDiscount;
      const mercCost: ResourceCost = {
        gold: Math.ceil(unitMercGold * cleanCount),
        wood: 0,
        grain: 0
      };
      return mercCost;
    }

    const normalCost: ResourceCost = {
      gold: Math.ceil(uCfg.cost.gold * goldMult * cleanCount),
      wood: Math.ceil(uCfg.cost.wood * woodMult * cleanCount),
      grain: Math.ceil(uCfg.cost.grain * grainMult * cleanCount)
    };
    return normalCost;
  }

  /**
   * 征募兵种编入主力军团（严格校验专属兵种权限、苍狼禁投石车、三维资源与 240 人口上限）
   */
  public recruitUnits(
    factionId: FactionId,
    unitType: UnitTypeId,
    count: number,
    corpsRole: ArmyCorpsRole = ArmyCorpsRole.VANGUARD_CENTER,
    useMercenaryGoldContract: boolean = false
  ): CampaignOperationResult {
    const cleanCount: number = Math.floor(count);
    if (cleanCount <= 0) {
      return CampaignEngine.failOp('征募数量必须为正整数。');
    }

    const faction: FactionCampaignRuntime | undefined = this.getFactionRuntime(factionId);
    const uCfg: UnitStaticStats | undefined = getUnitConfigById(unitType);
    if (faction === undefined || !faction.isAlive || uCfg === undefined) {
      return CampaignEngine.failOp('势力不存在或已覆灭，无法征募。');
    }

    // 苍狼汗国明确短板：禁造重型配重投石车（DESIGN.md 第 6 节）
    if (factionId === FactionId.CANGLANG && unitType === UnitTypeId.TREBUCHET) {
      return CampaignEngine.failOp('苍狼汗国游牧军制禁止建造配重投石车！');
    }

    // 专属王牌兵种权限核验（允许沙漠商盟在解锁《黄金契约》且与对应势力结有同盟时雇佣盟友精锐）
    if (uCfg.exclusiveFaction !== null && uCfg.exclusiveFaction !== factionId) {
      const canShamoHireAllyElite: boolean =
        factionId === FactionId.SHAMO &&
        useMercenaryGoldContract &&
        faction.unlockedTechIds.indexOf('sm_tech_mercenary') >= 0 &&
        this.diplomacyEngine.areAllied(this.state.diplomacy, factionId, uCfg.exclusiveFaction);
      if (!canShamoHireAllyElite) {
        return CampaignEngine.failOp(`【${uCfg.name}】为他国专属王牌禁军，本方无权招募。`);
      }
    }

    const currentPop: number = this.computeArmyPopulationUsed(factionId);
    const addedPop: number = cleanCount * uCfg.popCap;
    if (currentPop + addedPop > GameConstants.DEFAULT_ARMY_POP_CAP) {
      return CampaignEngine.failOp(
        `超出野战军团人口编制上限（当前 ${currentPop} + 新增 ${addedPop} > ${GameConstants.DEFAULT_ARMY_POP_CAP}）。`
      );
    }

    const totalCost: ResourceCost | null = this.computeRecruitmentCost(
      factionId,
      unitType,
      cleanCount,
      useMercenaryGoldContract
    );
    if (totalCost === null) {
      return CampaignEngine.failOp('征募费用计算异常。');
    }

    if (
      faction.gold < totalCost.gold ||
      faction.wood < totalCost.wood ||
      faction.grain < totalCost.grain
    ) {
      return CampaignEngine.failOp('国库金/木/粮储备不足，无法完成征募。');
    }

    faction.gold -= totalCost.gold;
    faction.wood -= totalCost.wood;
    faction.grain -= totalCost.grain;
    this.mergeIntoRoster(faction.fieldArmyRoster, unitType, cleanCount, corpsRole);

    const msg: string = `${factionId} 成功征募 ${cleanCount} 名【${uCfg.name}】编入 ${corpsRole}。`;
    this.appendLog(msg);
    const okRes: CampaignOperationResult = {
      success: true,
      message: msg,
      costGold: totalCost.gold,
      costWood: totalCost.wood,
      costGrain: totalCost.grain
    };
    return okRes;
  }

  /**
   * 研发解锁势力三阶专属科技
   */
  public unlockTech(factionId: FactionId, techId: string): CampaignOperationResult {
    const faction: FactionCampaignRuntime | undefined = this.getFactionRuntime(factionId);
    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(factionId);
    if (faction === undefined || !faction.isAlive || fCfg === undefined) {
      return CampaignEngine.failOp('势力状态无效。');
    }
    if (faction.unlockedTechIds.indexOf(techId) >= 0) {
      return CampaignEngine.failOp('该专属科技已研发解锁，无需重复投入。');
    }

    let targetTech: FactionTechItem | undefined = undefined;
    for (let i: number = 0; i < fCfg.uniqueTechs.length; i++) {
      if (fCfg.uniqueTechs[i].id === techId) {
        targetTech = fCfg.uniqueTechs[i];
        break;
      }
    }
    if (targetTech === undefined) {
      return CampaignEngine.failOp(`科技【${techId}】不属于势力 ${fCfg.name} 的专属科技树。`);
    }

    if (
      faction.gold < targetTech.cost.gold ||
      faction.wood < targetTech.cost.wood ||
      faction.grain < targetTech.cost.grain
    ) {
      return CampaignEngine.failOp(`研发《${targetTech.name}》所需金/木/粮不足。`);
    }

    faction.gold -= targetTech.cost.gold;
    faction.wood -= targetTech.cost.wood;
    faction.grain -= targetTech.cost.grain;
    faction.unlockedTechIds.push(techId);

    // 棱堡工事立即加固本方现辖关隘与城池城防耐久
    if (techId === 'ty_tech_bastion') {
      for (let i: number = 0; i < this.state.nodes.length; i++) {
        if (this.state.nodes[i].owner === factionId) {
          this.state.nodes[i].defenseHp = Math.round(this.state.nodes[i].defenseHp * 1.2);
        }
      }
    }

    const msg: string = `【科技突破】${fCfg.name} 成功研发专属军略《${targetTech.name}》！`;
    this.appendLog(msg);
    const okRes: CampaignOperationResult = {
      success: true,
      message: msg,
      costGold: targetTech.cost.gold,
      costWood: targetTech.cost.wood,
      costGrain: targetTech.cost.grain
    };
    return okRes;
  }

  /**
   * 发起战役层停火媾和谈判（若签约涉及边境割城则自动重算全图 40 城 BFS 补给线并同步存活状态）
   */
  public negotiatePeace(terms: PeaceOfferTerms): PeaceExecutionResult {
    const res: PeaceExecutionResult = this.diplomacyEngine.executePeaceNegotiation(
      terms,
      this.state.diplomacy,
      this.state.factions,
      this.state.nodes
    );
    if (res.applied) {
      this.refreshFactionAliveStates();
      this.supplyEngine.refreshAllNodesSupply(this.state.nodes, this.state.diplomacy);
      this.appendLog(`【停戈议和】${terms.proposer} 与 ${terms.target} 缔结 ${terms.truceTurns} 回合停战协定。`);
    } else if (res.triggeredImmediateWar) {
      this.appendLog(`【讹诈决裂】${terms.target} 怒斩来使，当即向 ${terms.proposer} 宣战！`);
    }
    return res;
  }

  /**
   * 预设【围点打援】咽喉伏击圈（DESIGN.md 4.4）：
   * 在本方控制的咽喉要道节点埋伏奇兵，指向相邻被围困或拟孤立的敌方城关；
   * 一旦在此节点成功伏击歼灭敌方援军，目标孤城守军士气直接锐减 -25！
   */
  public setupReliefAmbush(
    factionId: FactionId,
    ambushNodeId: string,
    besiegedEnemyNodeId?: string
  ): CampaignOperationResult {
    const faction: FactionCampaignRuntime | undefined = this.getFactionRuntime(factionId);
    const ambushNode: CampaignNodeRuntime | undefined = this.getNodeRuntime(ambushNodeId);
    const ambushCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(ambushNodeId);
    if (faction === undefined || !faction.isAlive || ambushNode === undefined || ambushCfg === undefined) {
      return CampaignEngine.failOp('设伏城关或势力不存在。');
    }

    const controlsAmbushNode: boolean =
      ambushNode.owner === factionId ||
      this.diplomacyEngine.areAllied(this.state.diplomacy, factionId, ambushNode.owner);
    if (!controlsAmbushNode) {
      return CampaignEngine.failOp('仅可在己方或盟友控制的交通咽喉节点预设打援伏兵。');
    }

    let resolvedBesiegedId: string = '';
    if (besiegedEnemyNodeId !== undefined && besiegedEnemyNodeId.length > 0) {
      if (ambushCfg.neighbors.indexOf(besiegedEnemyNodeId) < 0) {
        return CampaignEngine.failOp('被围目标城池必须与设伏咽喉节点相邻连通。');
      }
      const targetRuntime: CampaignNodeRuntime | undefined = this.getNodeRuntime(besiegedEnemyNodeId);
      if (targetRuntime === undefined || targetRuntime.owner === factionId) {
        return CampaignEngine.failOp('围点打援目标必须为敌对或非己方城池。');
      }
      resolvedBesiegedId = besiegedEnemyNodeId;
    } else {
      for (let i: number = 0; i < ambushCfg.neighbors.length; i++) {
        const nbrRuntime: CampaignNodeRuntime | undefined = this.getNodeRuntime(ambushCfg.neighbors[i]);
        if (
          nbrRuntime !== undefined &&
          nbrRuntime.owner !== factionId &&
          !this.diplomacyEngine.areAllied(this.state.diplomacy, factionId, nbrRuntime.owner)
        ) {
          resolvedBesiegedId = nbrRuntime.nodeId;
          break;
        }
      }
      if (resolvedBesiegedId.length === 0) {
        return CampaignEngine.failOp('该节点周围不存在可实施围点打援的相邻敌城。');
      }
    }

    ambushNode.hasAmbushTrap = true;
    this.reliefAmbushTargetByNode.set(ambushNodeId, resolvedBesiegedId);
    const msg: string = `【围点打援】${factionId} 于咽喉【${ambushCfg.name}】偃旗息鼓预设伏兵，锁死通往【${resolvedBesiegedId}】的援军通道！`;
    this.appendLog(msg);

    const okRes: CampaignOperationResult = {
      success: true,
      message: msg,
      costGold: 0,
      costWood: 0,
      costGrain: 0
    };
    return okRes;
  }

  /**
   * 生成【围点打援】截杀敌方驰援纵队的伏击战初始化配置（援军行军态士气 -10）
   */
  public createReliefAmbushBattleConfig(
    ambusherFaction: FactionId,
    ambushNodeId: string,
    reliefEnemyFaction?: FactionId
  ): BattleInitConfig | null {
    const ambushNode: CampaignNodeRuntime | undefined = this.getNodeRuntime(ambushNodeId);
    const ambushCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(ambushNodeId);
    const ambusherRuntime: FactionCampaignRuntime | undefined = this.getFactionRuntime(ambusherFaction);
    if (ambushNode === undefined || ambushCfg === undefined || ambusherRuntime === undefined) {
      return null;
    }

    let enemyId: FactionId | null = reliefEnemyFaction !== undefined ? reliefEnemyFaction : null;
    const besiegedId: string | undefined = this.reliefAmbushTargetByNode.get(ambushNodeId);
    if (enemyId === null && besiegedId !== undefined) {
      const besiegedNode: CampaignNodeRuntime | undefined = this.getNodeRuntime(besiegedId);
      if (besiegedNode !== undefined) {
        enemyId = besiegedNode.owner;
      }
    }
    if (enemyId === null) {
      return null;
    }

    return this.buildBattleInitConfig(
      BattleScenarioType.AMBUSH,
      ambusherFaction,
      enemyId,
      ambushNodeId,
      ambushNodeId,
      true
    );
  }

  /**
   * 生成敌军围攻本方城关时的【据城死守战（SIEGE_DEFENSE）】初始化配置
   */
  public createSiegeDefenseBattleConfig(
    defendingNodeId: string,
    attackerEnemyFaction: FactionId
  ): BattleInitConfig | null {
    const defNode: CampaignNodeRuntime | undefined = this.getNodeRuntime(defendingNodeId);
    if (defNode === undefined) {
      return null;
    }
    return this.buildBattleInitConfig(
      BattleScenarioType.SIEGE_DEFENSE,
      defNode.owner,
      attackerEnemyFaction,
      defendingNodeId,
      defendingNodeId,
      false
    );
  }

  /**
   * 统帅主力军团向相邻城关行军：
   * - 若进入己方或同盟节点：直接移防驻扎并刷新补给线；
   * - 若进入非友方节点：核验条约背盟二次确认 -> 自动识别 6 种战场剧本 -> 生成完整 `BattleInitConfig`。
   */
  public marchToNode(
    factionId: FactionId,
    targetNodeId: string,
    options?: MarchActionOptions
  ): MarchActionResult {
    const faction: FactionCampaignRuntime | undefined = this.getFactionRuntime(factionId);
    const targetNode: CampaignNodeRuntime | undefined = this.getNodeRuntime(targetNodeId);
    const targetCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(targetNodeId);
    if (faction === undefined || !faction.isAlive || targetNode === undefined || targetCfg === undefined) {
      return CampaignEngine.failMarch('行军势力或目标城关无效。');
    }

    const fromNodeId: string = faction.armyLocationNodeId;
    if (fromNodeId === targetNodeId) {
      const staySupply: SupplyEvaluationResult = this.supplyEngine.evaluateNodeSupply(
        targetNodeId,
        factionId,
        this.state.nodes,
        this.state.diplomacy,
        false
      );
      const sameNodeRes: MarchActionResult = {
        success: true,
        battleTriggered: false,
        requiresBetrayalConfirmation: false,
        betrayalAssessment: null,
        battleConfig: null,
        supplyEvaluation: staySupply,
        message: '主力军团已驻扎于该城关。'
      };
      return sameNodeRes;
    }

    const fromCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(fromNodeId);
    if (fromCfg === undefined || fromCfg.neighbors.indexOf(targetNodeId) < 0) {
      return CampaignEngine.failMarch(
        `目标【${targetCfg.name}】与当前驻地【${fromNodeId}】无直通道路相连，须逐城推进。`
      );
    }

    // 1. 友方控制或正式军事同盟借道：和平移防
    const isFriendlyOrAllied: boolean =
      targetNode.owner === factionId ||
      this.diplomacyEngine.areAllied(this.state.diplomacy, factionId, targetNode.owner);
    if (isFriendlyOrAllied) {
      faction.armyLocationNodeId = targetNodeId;
      const peacefulSupply: SupplyEvaluationResult = this.supplyEngine.evaluateNodeSupply(
        targetNodeId,
        factionId,
        this.state.nodes,
        this.state.diplomacy,
        false
      );
      const moveMsg: string = `${factionId} 主力军团顺利进驻【${targetCfg.name}】（补给跳数 ${peacefulSupply.hops}，状态 ${peacefulSupply.grade}）。`;
      this.appendLog(moveMsg);
      const peacefulRes: MarchActionResult = {
        success: true,
        battleTriggered: false,
        requiresBetrayalConfirmation: false,
        betrayalAssessment: null,
        battleConfig: null,
        supplyEvaluation: peacefulSupply,
        message: moveMsg
      };
      return peacefulRes;
    }

    // 2. 进军非同盟他国领地：检查外交宣战与背盟阻断确认（DESIGN.md 10.3）
    const defenderFaction: FactionId = targetNode.owner;
    const currentStatus: DiplomaticStatus = this.diplomacyEngine.getStatus(
      this.state.diplomacy,
      factionId,
      defenderFaction
    );

    let appliedAssessment: BetrayalAssessment | null = null;
    if (currentStatus !== DiplomaticStatus.WAR) {
      let warContext: WarDeclarationContext | undefined = undefined;
      if (options !== undefined && options.defendingVictimAlly !== undefined) {
        const explicitCtx: WarDeclarationContext = {
          defendingVictimAlly: options.defendingVictimAlly
        };
        warContext = explicitCtx;
      }
      const assessment: BetrayalAssessment = this.diplomacyEngine.assessWarDeclaration(
        factionId,
        defenderFaction,
        this.state.diplomacy,
        this.state.factions,
        warContext
      );
      appliedAssessment = assessment;

      const confirmBetrayal: boolean =
        options !== undefined && options.confirmBetrayal === true;
      const allowAutoWar: boolean =
        options === undefined || options.autoDeclareWar !== false;

      if (assessment.isBetrayalTriggered && !confirmBetrayal) {
        const blockRes: MarchActionResult = {
          success: false,
          battleTriggered: false,
          requiresBetrayalConfirmation: true,
          betrayalAssessment: assessment,
          battleConfig: null,
          supplyEvaluation: null,
          message: `【背盟强阻断警告】${assessment.explanation} 如确需撕毁条约强攻，请二次确认！`
        };
        return blockRes;
      }

      if (!allowAutoWar && !confirmBetrayal) {
        return CampaignEngine.failMarch('双方尚未处于交战状态，请先正式宣战后再行进兵。');
      }

      const warDecl: WarDeclarationResult = this.diplomacyEngine.declareWar(
        factionId,
        defenderFaction,
        this.state.diplomacy,
        this.state.factions,
        warContext
      );
      this.appendLog(`【战端开启】${warDecl.message}`);
    }

    // 3. 自动识别 6 大战役战斗类型并构造 BattleInitConfig
    const marchSupply: SupplyEvaluationResult = this.supplyEngine.evaluateMarchSupply(
      fromNodeId,
      targetNodeId,
      factionId,
      this.state.nodes,
      this.state.diplomacy
    );
    const scenario: BattleScenarioType = this.classifyBattleScenario(
      faction,
      targetNode,
      targetCfg,
      options
    );
    const battleCfg: BattleInitConfig = this.buildBattleInitConfig(
      scenario,
      factionId,
      defenderFaction,
      fromNodeId,
      targetNodeId,
      false
    );

    const battleMsg: string = `${factionId} 挥师进逼【${targetCfg.name}】，触发【${scenario}】会战（携粮 ${battleCfg.playerInitialGrain}）！`;
    this.appendLog(battleMsg);

    const combatRes: MarchActionResult = {
      success: true,
      battleTriggered: true,
      requiresBetrayalConfirmation: false,
      betrayalAssessment: appliedAssessment,
      battleConfig: battleCfg,
      supplyEvaluation: marchSupply,
      message: battleMsg
    };
    return combatRes;
  }

  /**
   * 处理战后结算回写大地图态势（严格对齐 DESIGN.md 第 1、4.4、10.2 节）：
   * 1. 伤兵恢复回编与净阵亡扣减；
   * 2. 俘虏收编入伍或折算赎金入库；
   * 3. 缴获金木粮入库、背盟士气惩罚场次递减；
   * 4. 主帅晋升与二次阵亡 2 回合【重伤休养】；
   * 5. 城池易手、围点打援大捷令孤城守军士气 -25、全图 BFS 粮道实时重算与灭国判定。
   */
  public applyBattleSettlement(
    summary: BattleSettlementSummary,
    prisonerDisposition: PrisonerDisposition = PrisonerDisposition.RANSOM
  ): SettlementApplyReport {
    this.state.totalBattlesFought += 1;
    this.state.totalEnemiesKilled += Math.max(0, Math.floor(summary.enemyKilled));
    if (summary.isVictory) {
      this.state.totalBattlesWon += 1;
    }

    const playerRuntime: FactionCampaignRuntime | undefined = this.getFactionRuntime(
      summary.playerFaction
    );
    const enemyRuntime: FactionCampaignRuntime | undefined = this.getFactionRuntime(
      summary.enemyFaction
    );
    const battleNode: CampaignNodeRuntime | undefined = this.getNodeRuntime(summary.campaignNodeId);
    const battleNodeCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(summary.campaignNodeId);

    let netLosses: number = 0;
    let recruitedPrisoners: number = 0;
    let ransomGold: number = 0;
    let capturedNode: boolean = false;
    const shockedIsolatedCities: string[] = [];
    let leveledUp: boolean = false;
    let finalLevel: number = playerRuntime !== undefined ? playerRuntime.commanderLevel : 1;
    let injuredTurns: number = playerRuntime !== undefined ? playerRuntime.commanderInjuredTurns : 0;

    if (playerRuntime !== undefined) {
      // 1. 阵亡与伤兵恢复结算：净减员 = max(0, playerKilled - playerWoundedRecovered)
      const currentTotal: number = this.countTotalSoldiers(playerRuntime.fieldArmyRoster);
      const rawKilled: number = Math.max(0, Math.floor(summary.playerKilled));
      const rawRecovered: number = Math.max(0, Math.floor(summary.playerWoundedRecovered));
      netLosses = CampaignEngine.clampInt(rawKilled - rawRecovered, 0, currentTotal);
      if (netLosses > 0) {
        this.applyCasualtiesToRoster(playerRuntime.fieldArmyRoster, netLosses);
      }

      // 2. 缴获资源入库
      playerRuntime.gold += Math.max(0, Math.floor(summary.lootedGold));
      playerRuntime.wood += Math.max(0, Math.floor(summary.lootedWood));
      playerRuntime.grain += Math.max(0, Math.floor(summary.lootedGrain));

      // 3. 战俘处置：换取赎金 或 整编收编为刀盾步兵（超出 240 人口上限部分自动换赎金）
      const prisoners: number = Math.max(0, Math.floor(summary.capturedPrisoners));
      if (prisoners > 0) {
        if (prisonerDisposition === PrisonerDisposition.RECRUIT && summary.isVictory) {
          const usedPop: number = this.computeArmyPopulationUsed(playerRuntime.factionId);
          const availablePop: number = Math.max(0, GameConstants.DEFAULT_ARMY_POP_CAP - usedPop);
          recruitedPrisoners = Math.min(prisoners, availablePop);
          const excessPrisoners: number = prisoners - recruitedPrisoners;
          if (recruitedPrisoners > 0) {
            this.mergeIntoRoster(
              playerRuntime.fieldArmyRoster,
              UnitTypeId.SHIELD_SWORDSMAN,
              recruitedPrisoners,
              ArmyCorpsRole.REAR_RESERVE
            );
          }
          ransomGold = excessPrisoners * CampaignEngine.RANSOM_GOLD_PER_PRISONER;
          playerRuntime.gold += ransomGold;
        } else {
          ransomGold = prisoners * CampaignEngine.RANSOM_GOLD_PER_PRISONER;
          playerRuntime.gold += ransomGold;
        }
      }

      // 4. 消耗背盟连续 2 场战斗士气动摇惩罚计数
      if (playerRuntime.betrayalMoralePenaltyBattles > 0) {
        playerRuntime.betrayalMoralePenaltyBattles -= 1;
      }

      // 5. 主帅经验晋升与二次阵亡【重伤休养 2 回合】（DESIGN.md 10.2）
      playerRuntime.commanderExp += Math.max(0, Math.floor(summary.commanderExpGained));
      while (
        playerRuntime.commanderLevel < 12 &&
        playerRuntime.commanderExp >= playerRuntime.commanderLevel * 100
      ) {
        playerRuntime.commanderExp -= playerRuntime.commanderLevel * 100;
        playerRuntime.commanderLevel += 1;
        leveledUp = true;
      }
      finalLevel = playerRuntime.commanderLevel;

      if (
        !summary.isVictory &&
        summary.outcomeReason === BattleOutcomeReason.PLAYER_HERO_MARTYRED
      ) {
        playerRuntime.commanderInjuredTurns = 2;
        this.appendLog(
          `【主帅重创】${playerRuntime.factionId} 统帅阵前力竭重伤，由亲卫拼死抢回王都休养 2 回合！`
        );
      }
      injuredTurns = playerRuntime.commanderInjuredTurns;
    }

    // 6. 削减敌方野战军团兵力
    if (enemyRuntime !== undefined) {
      const enemyTotal: number = this.countTotalSoldiers(enemyRuntime.fieldArmyRoster);
      const enemyLoss: number = CampaignEngine.clampInt(
        Math.floor(summary.enemyKilled * 0.65),
        0,
        Math.max(0, enemyTotal - 10)
      );
      if (enemyLoss > 0) {
        this.applyCasualtiesToRoster(enemyRuntime.fieldArmyRoster, enemyLoss);
      }
    }

    // 7. 胜败领土态势与【围点打援】士气打击回写
    if (battleNode !== undefined && battleNodeCfg !== undefined) {
      if (summary.isVictory) {
        // 若为【围点打援】伏击战大捷：引爆孤城守军士气 -25
        if (summary.scenarioType === BattleScenarioType.AMBUSH) {
          battleNode.hasAmbushTrap = false;
          const mappedTarget: string | undefined = this.reliefAmbushTargetByNode.get(
            battleNode.nodeId
          );
          if (mappedTarget !== undefined) {
            this.isolatedCityMoraleDebuffMap.set(
              mappedTarget,
              CampaignEngine.RELIEF_AMBUSH_GARRISON_MORALE_PENALTY
            );
            shockedIsolatedCities.push(mappedTarget);
            this.reliefAmbushTargetByNode.delete(battleNode.nodeId);
            this.appendLog(
              `【打援大捷】驰援纵队全军覆没！孤城【${mappedTarget}】外援断绝，守军士气骤降 -25！`
            );
          } else {
            // 若系临时遭遇伏击获胜，亦震慑相邻敌军被围城池
            for (let k: number = 0; k < battleNodeCfg.neighbors.length; k++) {
              const nbrNode: CampaignNodeRuntime | undefined = this.getNodeRuntime(
                battleNodeCfg.neighbors[k]
              );
              if (nbrNode !== undefined && nbrNode.owner === summary.enemyFaction) {
                this.isolatedCityMoraleDebuffMap.set(
                  nbrNode.nodeId,
                  CampaignEngine.RELIEF_AMBUSH_GARRISON_MORALE_PENALTY
                );
                shockedIsolatedCities.push(nbrNode.nodeId);
              }
            }
          }
        }

        // 若战场节点原属敌方：攻克易手！
        if (battleNode.owner !== summary.playerFaction) {
          const previousOwner: FactionId = battleNode.owner;
          battleNode.owner = summary.playerFaction;
          battleNode.isolatedTurns = 0;
          battleNode.hasAmbushTrap = false;
          battleNode.garrisonStrength = Math.max(65, battleNodeCfg.defenseLevel * 22);
          battleNode.defenseHp = this.computeMaxDefenseHp(battleNodeCfg, summary.playerFaction);
          this.isolatedCityMoraleDebuffMap.delete(battleNode.nodeId);
          capturedNode = true;

          if (playerRuntime !== undefined) {
            playerRuntime.armyLocationNodeId = battleNode.nodeId;
          }
          this.relocateDisplacedFactionArmy(previousOwner, battleNode.nodeId);
          this.appendLog(
            `【捷报攻克】${summary.playerFaction} 夺取重镇【${battleNodeCfg.name}】！`
          );
        }
      } else {
        // 战败处理：若为守城战失利则城池陷落；若为进攻失利则退回出发地或最近友城
        if (
          summary.scenarioType === BattleScenarioType.SIEGE_DEFENSE &&
          battleNode.owner === summary.playerFaction
        ) {
          battleNode.owner = summary.enemyFaction;
          battleNode.isolatedTurns = 0;
          battleNode.hasAmbushTrap = false;
          battleNode.garrisonStrength = 75;
          this.relocateDisplacedFactionArmy(summary.playerFaction, battleNode.nodeId);
          this.appendLog(`【城池失守】${battleNodeCfg.name} 陷落敌手！`);
        } else if (
          playerRuntime !== undefined &&
          battleNode.owner !== summary.playerFaction
        ) {
          this.relocateDisplacedFactionArmy(summary.playerFaction, battleNode.nodeId);
        }
      }
    }

    // 8. 刷新存活状态与全图 40 城 BFS 补给线
    this.refreshFactionAliveStates();
    this.supplyEngine.refreshAllNodesSupply(this.state.nodes, this.state.diplomacy);
    const victoryCheck: CampaignVictoryResult = this.checkVictoryCondition();

    const report: SettlementApplyReport = {
      netPlayerLosses: netLosses,
      prisonersRecruited: recruitedPrisoners,
      ransomGoldGained: ransomGold,
      nodeCaptured: capturedNode,
      reliefAmbushMoraleShockAppliedTo: shockedIsolatedCities,
      commanderLeveledUp: leveledUp,
      newCommanderLevel: finalLevel,
      commanderInjuredTurns: injuredTurns,
      victoryCheck: victoryCheck
    };
    return report;
  }

  /**
   * 推进大地图战略回合结算：
   * 1. 全图城关金币/木材/粮草产出入库（含沙漠商盟采金 +35%）与驻军粮耗扣减；
   * 2. 外交推进（通商贸易收入、停战纳粮、附庸岁币、条约自然期满 +3 信誉、>=13 城反霸权 +25 好感）；
   * 3. 全图 BFS 补给线重算与断粮孤城结算（第 1 回合应急干粮红字预警；第 2 回合起每回合 8% 逃亡减员）；
   * 4. 主帅重伤休养回合递减；
   * 5. 触发 L1 战略 AI 行动钩子；
   * 6. 核验八王都统一或同盟霸权胜利。
   */
  public advanceTurn(aiTurnHook?: CampaignAiTurnHook): CampaignTurnAdvanceReport {
    const emergencyNodes: string[] = [];
    const attritionNodes: string[] = [];

    // 1. 税收产粮与日常军粮维持消耗
    for (let i: number = 0; i < this.state.factions.length; i++) {
      const f: FactionCampaignRuntime = this.state.factions[i];
      if (!f.isAlive) {
        continue;
      }
      let goldIncome: number = 0;
      let woodIncome: number = 0;
      let grainIncome: number = 0;

      for (let j: number = 0; j < this.state.nodes.length; j++) {
        const node: CampaignNodeRuntime = this.state.nodes[j];
        if (node.owner !== f.factionId) {
          continue;
        }
        const cfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(node.nodeId);
        if (cfg === undefined) {
          continue;
        }
        let nodeGold: number = cfg.goldYield;
        if (
          f.factionId === FactionId.SHAMO &&
          (cfg.nodeType === CampaignNodeType.RESOURCE_HUB ||
            cfg.nodeType === CampaignNodeType.CAPITAL_CITADEL)
        ) {
          nodeGold = Math.round(nodeGold * 1.35);
        }
        goldIncome += nodeGold;
        woodIncome += cfg.woodYield;
        grainIncome += cfg.grainYield;
      }

      f.gold += goldIncome;
      f.wood += woodIncome;
      f.grain += grainIncome;

      // 主力军团驻地粮耗（受补给线跳数倍率与霜原熊族 +15% 食量修正）
      const armySupply: SupplyEvaluationResult = this.supplyEngine.evaluateNodeSupply(
        f.armyLocationNodeId,
        f.factionId,
        this.state.nodes,
        this.state.diplomacy,
        false
      );
      let appetiteMult: number = 1.0;
      if (
        f.factionId === FactionId.SHUANGYUAN &&
        f.unlockedTechIds.indexOf('sy_tech_winterhunt') < 0
      ) {
        appetiteMult = 1.15;
      }
      const baseArmyGrainUpkeep: number = Math.round(
        this.countTotalSoldiers(f.fieldArmyRoster) * 1.6 * armySupply.upkeepMultiplier * appetiteMult
      );
      f.grain = Math.max(0, f.grain - baseArmyGrainUpkeep);
    }

    // 2. 外交演进与通商/守约信誉结算
    const diploReport: DiplomacyTurnReport = this.diplomacyEngine.advanceDiplomacyTurn(
      this.state.diplomacy,
      this.state.factions,
      this.state.nodes
    );
    for (let i: number = 0; i < diploReport.logs.length; i++) {
      this.appendLog(diploReport.logs[i]);
    }

    // 3. 全图 40 城 BFS 补给重算与断粮孤立减员（严格对齐 DESIGN.md 10.1）
    this.supplyEngine.refreshAllNodesSupply(this.state.nodes, this.state.diplomacy);
    for (let i: number = 0; i < this.state.nodes.length; i++) {
      const node: CampaignNodeRuntime = this.state.nodes[i];
      const cfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(node.nodeId);
      const cityName: string = cfg !== undefined ? cfg.name : node.nodeId;

      if (node.supplyGrade === SupplyLineGrade.SEVERED) {
        node.isolatedTurns += 1;
        const impact: SeveredIsolationImpact = this.supplyEngine.evaluateSeveredIsolationImpact(
          node.isolatedTurns
        );
        if (impact.isEmergencyWarningOnly) {
          emergencyNodes.push(node.nodeId);
          this.appendLog(
            `【红色断粮预警】${cityName}（${node.owner}）归路被截断第 1 回合，开始消耗随军应急干粮！`
          );
        } else if (impact.desertionAttritionRate > 0) {
          attritionNodes.push(node.nodeId);
          // 守军每回合非战斗逃亡减员 8%
          const keptRatio: number = 1.0 - impact.desertionAttritionRate;
          if (node.garrisonStrength > 1) {
            const reducedGarrison: number = Math.max(
              1,
              Math.floor(node.garrisonStrength * keptRatio)
            );
            node.garrisonStrength = reducedGarrison;
          }
          // 若该势力野战主力正困于此断粮节点，同样遭受 8% 非战斗逃亡减员
          const ownerRuntime: FactionCampaignRuntime | undefined = this.getFactionRuntime(node.owner);
          if (ownerRuntime !== undefined && ownerRuntime.armyLocationNodeId === node.nodeId) {
            const armyTotal: number = this.countTotalSoldiers(ownerRuntime.fieldArmyRoster);
            const desertCount: number = Math.max(
              1,
              Math.ceil(armyTotal * impact.desertionAttritionRate)
            );
            if (armyTotal > 1) {
              this.applyCasualtiesToRoster(
                ownerRuntime.fieldArmyRoster,
                Math.min(desertCount, armyTotal - 1)
              );
            }
          }
          this.appendLog(
            `【饥疲逃亡】${cityName} 断粮第 ${node.isolatedTurns} 回合，爆发 8% 非战斗饥饿逃亡且开战士气封顶 65！`
          );
        }
      } else {
        node.isolatedTurns = 0;
        if (cfg !== undefined) {
          const maxGarrison: number = this.computeMaxGarrison(cfg);
          if (node.garrisonStrength < maxGarrison) {
            node.garrisonStrength = Math.min(maxGarrison, node.garrisonStrength + 8);
          }
          const maxDefHp: number = this.computeMaxDefenseHp(cfg, node.owner);
          if (node.defenseHp < maxDefHp) {
            node.defenseHp = Math.min(maxDefHp, node.defenseHp + 150);
          }
        }
      }
    }

    // 4. 主帅重伤休养倒计时递减
    for (let i: number = 0; i < this.state.factions.length; i++) {
      if (this.state.factions[i].commanderInjuredTurns > 0) {
        this.state.factions[i].commanderInjuredTurns -= 1;
      }
    }

    // 5. 触发 L1 战略 AI 行动钩子
    let aiCount: number = 0;
    if (aiTurnHook !== undefined) {
      for (let i: number = 0; i < this.state.factions.length; i++) {
        const aiFac: FactionCampaignRuntime = this.state.factions[i];
        if (!aiFac.isAlive || aiFac.factionId === this.state.playerFaction) {
          continue;
        }
        aiTurnHook(this, aiFac.factionId);
        aiCount++;
      }
      this.refreshFactionAliveStates();
      this.supplyEngine.refreshAllNodesSupply(this.state.nodes, this.state.diplomacy);
    }

    this.state.turnNumber += 1;
    const victoryCheck: CampaignVictoryResult = this.checkVictoryCondition();

    const turnReport: CampaignTurnAdvanceReport = {
      newTurnNumber: this.state.turnNumber,
      emergencySeveredNodes: emergencyNodes,
      attritionSeveredNodes: attritionNodes,
      diplomacyReport: diploReport,
      aiActionsExecuted: aiCount,
      victoryCheck: victoryCheck
    };
    return turnReport;
  }

  /**
   * 核验战役终局胜利条件：
   * 1. 玩家覆灭（控制城池 = 0）；
   * 2. 独占全图全部 8 座王都（UNIFIED_ALL_CAPITALS / RIVAL_UNIFIED）；
   * 3. 玩家与正式军事同盟国（及附庸）共掌全部 8 座王都且合计控制 >= 30 座城关（ALLIANCE_HEGEMONY）。
   */
  public checkVictoryCondition(): CampaignVictoryResult {
    const playerFaction: FactionId = this.state.playerFaction;
    const playerNodes: number = this.countControlledNodes(playerFaction);
    const totalCapitals: number = this.capitalNodeIds.length;

    if (playerNodes === 0) {
      const lostRes: CampaignVictoryResult = {
        kind: CampaignVictoryKind.PLAYER_ELIMINATED,
        winnerFaction: null,
        playerControlledCapitals: 0,
        alliedControlledCapitals: 0,
        totalCapitals: totalCapitals,
        summaryText: '本方全部城关失陷，大业中道崩殂。'
      };
      return lostRes;
    }

    // 统计各势力独占王都数量
    const capitalCountByFaction: Map<FactionId, number> = new Map<FactionId, number>();
    let playerCapitals: number = 0;
    let coalitionCapitals: number = 0;

    for (let i: number = 0; i < this.capitalNodeIds.length; i++) {
      const capRuntime: CampaignNodeRuntime | undefined = this.getNodeRuntime(this.capitalNodeIds[i]);
      if (capRuntime === undefined) {
        continue;
      }
      const prev: number | undefined = capitalCountByFaction.get(capRuntime.owner);
      const nextCount: number = (prev !== undefined ? prev : 0) + 1;
      capitalCountByFaction.set(capRuntime.owner, nextCount);

      if (capRuntime.owner === playerFaction) {
        playerCapitals += 1;
        coalitionCapitals += 1;
      } else {
        const status: DiplomaticStatus = this.diplomacyEngine.getStatus(
          this.state.diplomacy,
          playerFaction,
          capRuntime.owner
        );
        if (status === DiplomaticStatus.ALLIANCE || status === DiplomaticStatus.VASSAL) {
          coalitionCapitals += 1;
        }
      }
    }

    if (playerCapitals === totalCapitals) {
      const unifiedRes: CampaignVictoryResult = {
        kind: CampaignVictoryKind.UNIFIED_ALL_CAPITALS,
        winnerFaction: playerFaction,
        playerControlledCapitals: playerCapitals,
        alliedControlledCapitals: coalitionCapitals,
        totalCapitals: totalCapitals,
        summaryText: '八荒一统！本方铁骑踏平天下全部八座核心王都，成就冷兵器至高霸业！'
      };
      return unifiedRes;
    }

    // 检查是否有其他 AI 独占全部 8 座王都
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      const fid: FactionId = FACTION_STATIC_CONFIGS[i].id;
      if (fid === playerFaction) {
        continue;
      }
      const cCount: number | undefined = capitalCountByFaction.get(fid);
      if (cCount !== undefined && cCount === totalCapitals) {
        const rivalRes: CampaignVictoryResult = {
          kind: CampaignVictoryKind.RIVAL_UNIFIED,
          winnerFaction: fid,
          playerControlledCapitals: playerCapitals,
          alliedControlledCapitals: coalitionCapitals,
          totalCapitals: totalCapitals,
          summaryText: `强权 ${fid} 已囊括天下八座王都，大势已去。`
        };
        return rivalRes;
      }
    }

    // 检查同盟霸权胜利：玩家至少亲掌 2 座王都，且与同盟/附庸共掌全部 8 座王都及 >= 30 座城池
    if (playerCapitals >= 2 && coalitionCapitals === totalCapitals) {
      let coalitionTotalCities: number = 0;
      for (let i: number = 0; i < this.state.nodes.length; i++) {
        const owner: FactionId = this.state.nodes[i].owner;
        if (owner === playerFaction) {
          coalitionTotalCities += 1;
        } else {
          const st: DiplomaticStatus = this.diplomacyEngine.getStatus(
            this.state.diplomacy,
            playerFaction,
            owner
          );
          if (st === DiplomaticStatus.ALLIANCE || st === DiplomaticStatus.VASSAL) {
            coalitionTotalCities += 1;
          }
        }
      }
      if (coalitionTotalCities >= 30) {
        const hegemonyRes: CampaignVictoryResult = {
          kind: CampaignVictoryKind.ALLIANCE_HEGEMONY,
          winnerFaction: playerFaction,
          playerControlledCapitals: playerCapitals,
          alliedControlledCapitals: coalitionCapitals,
          totalCapitals: totalCapitals,
          summaryText: '合纵共主！本方与盟邦共掌八座王都与四海版图，达成【同盟霸权胜利】！'
        };
        return hegemonyRes;
      }
    }

    const ongoingRes: CampaignVictoryResult = {
      kind: CampaignVictoryKind.ONGOING,
      winnerFaction: null,
      playerControlledCapitals: playerCapitals,
      alliedControlledCapitals: coalitionCapitals,
      totalCapitals: totalCapitals,
      summaryText: `群雄逐鹿进行中（已掌控王都 ${playerCapitals}/${totalCapitals}，同盟共控 ${coalitionCapitals}/${totalCapitals}）。`
    };
    return ongoingRes;
  }

  private buildInitialCampaignState(playerFaction: FactionId): CampaignSaveState {
    const diplomacy: BilateralDiplomacyState[] = this.diplomacyEngine.createInitialDiplomacyMatrix();

    const nodes: CampaignNodeRuntime[] = [];
    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      const cfg: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
      const runtimeNode: CampaignNodeRuntime = {
        nodeId: cfg.id,
        owner: cfg.initialOwner,
        garrisonStrength: this.computeMaxGarrison(cfg),
        defenseHp: this.computeMaxDefenseHp(cfg, cfg.initialOwner),
        isolatedTurns: 0,
        hasAmbushTrap: false,
        supplyGrade: SupplyLineGrade.FULL_SUPPLY,
        supplyHops: 0
      };
      nodes.push(runtimeNode);
    }

    const factions: FactionCampaignRuntime[] = [];
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      const fCfg: FactionStaticConfig = FACTION_STATIC_CONFIGS[i];
      const initGold: number = fCfg.id === FactionId.SHAMO ? 1180 : 900;
      const initWood: number = fCfg.id === FactionId.WULIN ? 760 : 620;
      const initGrain: number =
        fCfg.id === FactionId.CANGLANG || fCfg.id === FactionId.YANLONG ? 1520 : 1400;

      const runtimeFaction: FactionCampaignRuntime = {
        factionId: fCfg.id,
        isAlive: true,
        gold: initGold,
        wood: initWood,
        grain: initGrain,
        credibility: fCfg.startingCredibility,
        unlockedTechIds: [],
        commanderLevel: 1,
        commanderExp: 0,
        betrayalMoralePenaltyBattles: 0,
        commanderInjuredTurns: 0,
        fieldArmyRoster: this.createDefaultFactionRoster(fCfg),
        armyLocationNodeId: fCfg.capitalNodeId
      };
      factions.push(runtimeFaction);
    }

    this.supplyEngine.refreshAllNodesSupply(nodes, diplomacy);

    const playerCfg: FactionStaticConfig | undefined = getFactionConfigById(playerFaction);
    const pName: string = playerCfg !== undefined ? playerCfg.name : playerFaction;

    const saveState: CampaignSaveState = {
      schemaVersion: CampaignEngine.CURRENT_SCHEMA_VERSION,
      turnNumber: 1,
      playerFaction: playerFaction,
      nodes: nodes,
      factions: factions,
      diplomacy: diplomacy,
      totalBattlesFought: 0,
      totalBattlesWon: 0,
      totalEnemiesKilled: 0,
      recentLogs: [`【纪元启幕】统帅执掌【${pName}】帅印，八荒四十城战火初燃！`]
    };
    return saveState;
  }

  /**
   * 为八大势力构建贴合各自战术风格的多军团开局主力编制（约 90 人，预留充裕征募空间）
   */
  private createDefaultFactionRoster(fCfg: FactionStaticConfig): RosterEntry[] {
    const siegeUnit: UnitTypeId =
      fCfg.id === FactionId.CANGLANG ? UnitTypeId.BALLISTA : UnitTypeId.TREBUCHET;
    const siegeCount: number = fCfg.id === FactionId.CANGLANG ? 3 : 2;
    const eliteCount: number =
      fCfg.id === FactionId.SHUANGYUAN || fCfg.id === FactionId.XUANJIA ? 8 : 14;

    const roster: RosterEntry[] = [
      {
        unitType: UnitTypeId.SHIELD_SWORDSMAN,
        count: 26,
        corpsRole: ArmyCorpsRole.VANGUARD_CENTER
      },
      {
        unitType: UnitTypeId.PIKEMAN,
        count: 18,
        corpsRole: ArmyCorpsRole.VANGUARD_CENTER
      },
      {
        unitType: UnitTypeId.COMPOSITE_ARCHER,
        count: 16,
        corpsRole: ArmyCorpsRole.LEFT_WING
      },
      {
        unitType: UnitTypeId.LIGHT_CAVALRY,
        count: 10,
        corpsRole: ArmyCorpsRole.RIGHT_WING
      },
      {
        unitType: fCfg.exclusiveUnitId,
        count: eliteCount,
        corpsRole: ArmyCorpsRole.REAR_RESERVE
      },
      {
        unitType: siegeUnit,
        count: siegeCount,
        corpsRole: ArmyCorpsRole.SIEGE_BATTERY
      },
      {
        unitType: UnitTypeId.SAPPER,
        count: 6,
        corpsRole: ArmyCorpsRole.SUPPLY_ESCORT
      }
    ];
    return roster;
  }

  private classifyBattleScenario(
    attacker: FactionCampaignRuntime,
    targetNode: CampaignNodeRuntime,
    targetCfg: CampaignNodeConfig,
    options?: MarchActionOptions
  ): BattleScenarioType {
    if (targetNode.hasAmbushTrap) {
      return BattleScenarioType.AMBUSH;
    }
    if (options !== undefined && options.preferNightRaid === true) {
      return BattleScenarioType.NIGHT_RAID;
    }
    if (
      attacker.factionId === FactionId.XUEYUE &&
      attacker.unlockedTechIds.indexOf('xy_tech_eternalnight') >= 0 &&
      targetCfg.nodeType !== CampaignNodeType.CAPITAL_CITADEL
    ) {
      return BattleScenarioType.NIGHT_RAID;
    }
    if (options !== undefined && options.preferConvoyRaid === true) {
      return BattleScenarioType.CONVOY_ESCORT;
    }
    const defenderRuntime: FactionCampaignRuntime | undefined = this.getFactionRuntime(
      targetNode.owner
    );
    const enemyMainArmyAway: boolean =
      defenderRuntime !== undefined && defenderRuntime.armyLocationNodeId !== targetNode.nodeId;
    if (
      targetCfg.nodeType === CampaignNodeType.GRANARY_TOWN &&
      targetCfg.defenseLevel <= 2 &&
      enemyMainArmyAway
    ) {
      return BattleScenarioType.CONVOY_ESCORT;
    }
    if (
      targetCfg.nodeType === CampaignNodeType.CAPITAL_CITADEL ||
      targetCfg.nodeType === CampaignNodeType.FORTRESS_PASS ||
      targetCfg.defenseLevel >= 4
    ) {
      return BattleScenarioType.SIEGE_ASSAULT;
    }
    return BattleScenarioType.FIELD_PITCHED;
  }

  private buildBattleInitConfig(
    scenario: BattleScenarioType,
    playerFaction: FactionId,
    enemyFaction: FactionId,
    fromNodeId: string,
    targetNodeId: string,
    isReliefInterception: boolean
  ): BattleInitConfig {
    const targetCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(targetNodeId);
    const targetRuntime: CampaignNodeRuntime | undefined = this.getNodeRuntime(targetNodeId);
    const fromRuntime: CampaignNodeRuntime | undefined = this.getNodeRuntime(fromNodeId);
    const playerRuntime: FactionCampaignRuntime | undefined = this.getFactionRuntime(playerFaction);
    const enemyRuntime: FactionCampaignRuntime | undefined = this.getFactionRuntime(enemyFaction);

    const terrain: TerrainType = targetCfg !== undefined ? targetCfg.terrain : TerrainType.PLAIN;
    const weather: WeatherType = this.pickBattleWeather(scenario, terrain);

    const playerSupply: SupplyEvaluationResult =
      scenario === BattleScenarioType.SIEGE_DEFENSE || isReliefInterception
        ? this.supplyEngine.evaluateNodeSupply(
            targetNodeId,
            playerFaction,
            this.state.nodes,
            this.state.diplomacy,
            false
          )
        : this.supplyEngine.evaluateMarchSupply(
            fromNodeId,
            targetNodeId,
            playerFaction,
            this.state.nodes,
            this.state.diplomacy
          );

    const enemySupply: SupplyEvaluationResult = this.supplyEngine.evaluateNodeSupply(
      targetNodeId,
      enemyFaction,
      this.state.nodes,
      this.state.diplomacy,
      true
    );

    const playerInitGrain: number = Math.max(
      180,
      Math.round(GameConstants.BATTLE_INIT_GRAIN * playerSupply.initialGrainMultiplier)
    );
    const enemyInitGrain: number = Math.max(
      180,
      Math.round(GameConstants.BATTLE_INIT_GRAIN * enemySupply.initialGrainMultiplier)
    );

    // 计算本方初始士气修正（背盟连续 2 战惩罚、2 回合断粮 65 封顶、主帅重伤休养、敌方求和破裂激励）
    let playerMoraleMod: number = this.diplomacyEngine.consumePendingPeaceBreakdownMoraleBonus(
      playerFaction
    );
    if (playerRuntime !== undefined) {
      if (playerRuntime.betrayalMoralePenaltyBattles > 0) {
        playerMoraleMod += this.diplomacyEngine.getBetrayalMoralePenaltyForFaction(playerFaction);
      }
      if (playerRuntime.commanderInjuredTurns > 0) {
        playerMoraleMod -= 12;
      }
    }
    const playerOriginNode: CampaignNodeRuntime | undefined =
      scenario === BattleScenarioType.SIEGE_DEFENSE ? targetRuntime : fromRuntime;
    if (playerOriginNode !== undefined && playerOriginNode.isolatedTurns >= 2) {
      const maxAllowedMod: number =
        SupplyLineEngine.SEVERED_BATTLE_MORALE_CAP - GameConstants.MORALE_BASE;
      if (playerMoraleMod > maxAllowedMod) {
        playerMoraleMod = maxAllowedMod;
      }
    }
    // 玩家主动踏入敌方设伏节点：承受行军遇伏 -10 士气
    if (
      scenario === BattleScenarioType.AMBUSH &&
      !isReliefInterception &&
      targetRuntime !== undefined &&
      targetRuntime.owner === enemyFaction
    ) {
      playerMoraleMod -= 10;
    }

    // 计算敌方初始士气修正（围点打援孤城 -25、驰援纵队遇伏 -10、夜袭首轮震慑 -15、2 回合断粮封顶 65）
    let enemyMoraleMod: number = this.diplomacyEngine.consumePendingPeaceBreakdownMoraleBonus(
      enemyFaction
    );
    if (enemyRuntime !== undefined && enemyRuntime.betrayalMoralePenaltyBattles > 0) {
      enemyMoraleMod += this.diplomacyEngine.getBetrayalMoralePenaltyForFaction(enemyFaction);
    }
    if (isReliefInterception) {
      enemyMoraleMod -= 10;
    }
    if (scenario === BattleScenarioType.NIGHT_RAID) {
      enemyMoraleMod -= 15;
    }
    const besiegedDebuff: number = this.getBesiegedGarrisonMoraleModifier(targetNodeId);
    if (besiegedDebuff < 0 && targetRuntime !== undefined && targetRuntime.owner === enemyFaction) {
      enemyMoraleMod += besiegedDebuff;
    }
    if (
      targetRuntime !== undefined &&
      targetRuntime.owner === enemyFaction &&
      targetRuntime.isolatedTurns >= 2
    ) {
      const capMod: number = SupplyLineEngine.SEVERED_BATTLE_MORALE_CAP - GameConstants.MORALE_BASE;
      if (enemyMoraleMod > capMod) {
        enemyMoraleMod = capMod;
      }
    }

    const pRoster: RosterEntry[] =
      playerRuntime !== undefined
        ? CampaignEngine.cloneRosterList(playerRuntime.fieldArmyRoster)
        : [];
    const eRoster: RosterEntry[] = this.buildEnemyBattleRoster(enemyRuntime, targetRuntime);

    let holdDuration: number = 0;
    if (scenario === BattleScenarioType.SIEGE_DEFENSE) {
      holdDuration = 180;
    } else if (scenario === BattleScenarioType.SIEGE_ASSAULT) {
      holdDuration = 300;
    }

    const cfg: BattleInitConfig = {
      scenarioType: scenario,
      playerFaction: playerFaction,
      enemyFaction: enemyFaction,
      terrain: terrain,
      weather: weather,
      playerInitialGrain: playerInitGrain,
      enemyInitialGrain: enemyInitGrain,
      playerMoraleModifier: playerMoraleMod,
      enemyMoraleModifier: enemyMoraleMod,
      playerArmyRoster: pRoster,
      enemyArmyRoster: eRoster,
      campaignNodeId: targetNodeId,
      siegeHoldDurationSec: holdDuration
    };
    return cfg;
  }

  private buildEnemyBattleRoster(
    enemyRuntime: FactionCampaignRuntime | undefined,
    targetNode: CampaignNodeRuntime | undefined
  ): RosterEntry[] {
    if (enemyRuntime !== undefined && enemyRuntime.fieldArmyRoster.length > 0) {
      if (targetNode === undefined || enemyRuntime.armyLocationNodeId === targetNode.nodeId) {
        return CampaignEngine.cloneRosterList(enemyRuntime.fieldArmyRoster);
      }
    }
    // 城防驻军编队生成
    const strength: number = targetNode !== undefined ? Math.max(30, targetNode.garrisonStrength) : 80;
    const shieldCount: number = Math.max(10, Math.round(strength * 0.38));
    const pikeCount: number = Math.max(8, Math.round(strength * 0.27));
    const archerCount: number = Math.max(8, Math.round(strength * 0.25));
    const cavCount: number = Math.max(4, Math.round(strength * 0.10));

    const garrisonRoster: RosterEntry[] = [
      {
        unitType: UnitTypeId.SHIELD_SWORDSMAN,
        count: shieldCount,
        corpsRole: ArmyCorpsRole.VANGUARD_CENTER
      },
      {
        unitType: UnitTypeId.PIKEMAN,
        count: pikeCount,
        corpsRole: ArmyCorpsRole.LEFT_WING
      },
      {
        unitType: UnitTypeId.COMPOSITE_ARCHER,
        count: archerCount,
        corpsRole: ArmyCorpsRole.SIEGE_BATTERY
      },
      {
        unitType: UnitTypeId.LIGHT_CAVALRY,
        count: cavCount,
        corpsRole: ArmyCorpsRole.RIGHT_WING
      }
    ];
    return garrisonRoster;
  }

  private pickBattleWeather(scenario: BattleScenarioType, terrain: TerrainType): WeatherType {
    if (scenario === BattleScenarioType.NIGHT_RAID) {
      return WeatherType.NIGHT;
    }
    if (scenario === BattleScenarioType.AMBUSH && terrain === TerrainType.DENSE_FOREST) {
      return WeatherType.HEAVY_FOG;
    }
    if (terrain === TerrainType.SNOWFIELD && this.state.turnNumber % 3 === 0) {
      return WeatherType.BLIZZARD;
    }
    if (terrain === TerrainType.RIVER_FORD && this.state.turnNumber % 4 === 0) {
      return WeatherType.RAIN_MUD;
    }
    return WeatherType.CLEAR_DAY;
  }

  private mergeIntoRoster(
    roster: RosterEntry[],
    unitType: UnitTypeId,
    addedCount: number,
    corpsRole: ArmyCorpsRole
  ): void {
    for (let i: number = 0; i < roster.length; i++) {
      const existing: RosterEntry = roster[i];
      if (existing.unitType === unitType && existing.corpsRole === corpsRole) {
        const updated: RosterEntry = {
          unitType: existing.unitType,
          count: existing.count + addedCount,
          corpsRole: existing.corpsRole
        };
        roster[i] = updated;
        return;
      }
    }
    const freshEntry: RosterEntry = {
      unitType: unitType,
      count: addedCount,
      corpsRole: corpsRole
    };
    roster.push(freshEntry);
  }

  private countTotalSoldiers(roster: readonly RosterEntry[]): number {
    let sum: number = 0;
    for (let i: number = 0; i < roster.length; i++) {
      sum += roster[i].count;
    }
    return sum;
  }

  /**
   * 将战损或断粮逃亡人数按编制占比均匀分摊扣减至各军团分队
   */
  private applyCasualtiesToRoster(roster: RosterEntry[], totalCasualties: number): void {
    let remainingToRemove: number = totalCasualties;
    const initialTotal: number = this.countTotalSoldiers(roster);
    if (initialTotal <= 0 || remainingToRemove <= 0) {
      return;
    }

    for (let i: number = 0; i < roster.length && remainingToRemove > 0; i++) {
      const entry: RosterEntry = roster[i];
      const share: number = Math.min(
        entry.count,
        Math.min(remainingToRemove, Math.floor((entry.count / initialTotal) * totalCasualties))
      );
      if (share > 0) {
        const nextEntry: RosterEntry = {
          unitType: entry.unitType,
          count: entry.count - share,
          corpsRole: entry.corpsRole
        };
        roster[i] = nextEntry;
        remainingToRemove -= share;
      }
    }

    // 处理向下取整余数
    for (let i: number = 0; i < roster.length && remainingToRemove > 0; i++) {
      const entry: RosterEntry = roster[i];
      if (entry.count > 0) {
        const take: number = Math.min(entry.count, remainingToRemove);
        const nextEntry: RosterEntry = {
          unitType: entry.unitType,
          count: entry.count - take,
          corpsRole: entry.corpsRole
        };
        roster[i] = nextEntry;
        remainingToRemove -= take;
      }
    }

    for (let i: number = roster.length - 1; i >= 0; i--) {
      if (roster[i].count <= 0) {
        roster.splice(i, 1);
      }
    }
  }

  private relocateDisplacedFactionArmy(factionId: FactionId, lostNodeId: string): void {
    const faction: FactionCampaignRuntime | undefined = this.getFactionRuntime(factionId);
    if (faction === undefined || faction.armyLocationNodeId !== lostNodeId) {
      return;
    }
    const lostCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(lostNodeId);
    if (lostCfg !== undefined) {
      for (let i: number = 0; i < lostCfg.neighbors.length; i++) {
        const nbr: CampaignNodeRuntime | undefined = this.getNodeRuntime(lostCfg.neighbors[i]);
        if (nbr !== undefined && nbr.owner === factionId) {
          faction.armyLocationNodeId = nbr.nodeId;
          return;
        }
      }
    }
    for (let i: number = 0; i < this.state.nodes.length; i++) {
      if (this.state.nodes[i].owner === factionId) {
        faction.armyLocationNodeId = this.state.nodes[i].nodeId;
        return;
      }
    }
  }

  /**
   * 同步更新各势力存活状态（因 FactionCampaignRuntime.isAlive 为 readonly，采用不可变替换）
   */
  private refreshFactionAliveStates(): void {
    for (let i: number = 0; i < this.state.factions.length; i++) {
      const f: FactionCampaignRuntime = this.state.factions[i];
      const stillAlive: boolean = this.countControlledNodes(f.factionId) > 0;
      if (f.isAlive !== stillAlive) {
        const updated: FactionCampaignRuntime = {
          factionId: f.factionId,
          isAlive: stillAlive,
          gold: f.gold,
          wood: f.wood,
          grain: f.grain,
          credibility: f.credibility,
          unlockedTechIds: f.unlockedTechIds,
          commanderLevel: f.commanderLevel,
          commanderExp: f.commanderExp,
          betrayalMoralePenaltyBattles: f.betrayalMoralePenaltyBattles,
          commanderInjuredTurns: f.commanderInjuredTurns,
          fieldArmyRoster: stillAlive ? f.fieldArmyRoster : [],
          armyLocationNodeId: f.armyLocationNodeId
        };
        this.state.factions[i] = updated;
        if (!stillAlive) {
          this.appendLog(`【诸侯覆灭】势力 ${f.factionId} 尽丧疆土，退出天下角逐！`);
        }
      }
    }
  }

  private computeMaxGarrison(cfg: CampaignNodeConfig): number {
    if (cfg.nodeType === CampaignNodeType.CAPITAL_CITADEL) {
      return 160;
    }
    if (cfg.nodeType === CampaignNodeType.FORTRESS_PASS) {
      return 125;
    }
    return 60 + cfg.defenseLevel * 12;
  }

  private computeMaxDefenseHp(cfg: CampaignNodeConfig, owner: FactionId): number {
    const baseHp: number = cfg.defenseLevel * 1000;
    return owner === FactionId.YANLONG ? Math.round(baseHp * 1.2) : baseHp;
  }

  private appendLog(entry: string): void {
    this.state.recentLogs.push(`[T${this.state.turnNumber}] ${entry}`);
    if (this.state.recentLogs.length > CampaignEngine.MAX_RECENT_LOGS) {
      this.state.recentLogs.shift();
    }
  }

  public static cloneRosterList(list: readonly RosterEntry[]): RosterEntry[] {
    const copy: RosterEntry[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const item: RosterEntry = {
        unitType: list[i].unitType,
        count: list[i].count,
        corpsRole: list[i].corpsRole
      };
      copy.push(item);
    }
    return copy;
  }

  public static deepCloneSaveState(src: CampaignSaveState): CampaignSaveState {
    const clonedNodes: CampaignNodeRuntime[] = [];
    for (let i: number = 0; i < src.nodes.length; i++) {
      const n: CampaignNodeRuntime = src.nodes[i];
      const cn: CampaignNodeRuntime = {
        nodeId: n.nodeId,
        owner: n.owner,
        garrisonStrength: n.garrisonStrength,
        defenseHp: n.defenseHp,
        isolatedTurns: n.isolatedTurns,
        hasAmbushTrap: n.hasAmbushTrap,
        supplyGrade: n.supplyGrade,
        supplyHops: n.supplyHops
      };
      clonedNodes.push(cn);
    }

    const clonedFactions: FactionCampaignRuntime[] = [];
    for (let i: number = 0; i < src.factions.length; i++) {
      const f: FactionCampaignRuntime = src.factions[i];
      const techs: string[] = [];
      for (let t: number = 0; t < f.unlockedTechIds.length; t++) {
        techs.push(f.unlockedTechIds[t]);
      }
      const cf: FactionCampaignRuntime = {
        factionId: f.factionId,
        isAlive: f.isAlive,
        gold: f.gold,
        wood: f.wood,
        grain: f.grain,
        credibility: f.credibility,
        unlockedTechIds: techs,
        commanderLevel: f.commanderLevel,
        commanderExp: f.commanderExp,
        betrayalMoralePenaltyBattles: f.betrayalMoralePenaltyBattles,
        commanderInjuredTurns: f.commanderInjuredTurns,
        fieldArmyRoster: CampaignEngine.cloneRosterList(f.fieldArmyRoster),
        armyLocationNodeId: f.armyLocationNodeId
      };
      clonedFactions.push(cf);
    }

    const clonedDiplomacy: BilateralDiplomacyState[] = [];
    for (let i: number = 0; i < src.diplomacy.length; i++) {
      const d: BilateralDiplomacyState = src.diplomacy[i];
      const cd: BilateralDiplomacyState = {
        factionA: d.factionA,
        factionB: d.factionB,
        relation: d.relation,
        status: d.status,
        remainingTurns: d.remainingTurns,
        vendettaLockTurns: d.vendettaLockTurns
      };
      clonedDiplomacy.push(cd);
    }

    const clonedLogs: string[] = [];
    for (let i: number = 0; i < src.recentLogs.length; i++) {
      clonedLogs.push(src.recentLogs[i]);
    }

    const cloned: CampaignSaveState = {
      schemaVersion: src.schemaVersion,
      turnNumber: src.turnNumber,
      playerFaction: src.playerFaction,
      nodes: clonedNodes,
      factions: clonedFactions,
      diplomacy: clonedDiplomacy,
      totalBattlesFought: src.totalBattlesFought,
      totalBattlesWon: src.totalBattlesWon,
      totalEnemiesKilled: src.totalEnemiesKilled,
      recentLogs: clonedLogs
    };
    return cloned;
  }

  private static failOp(msg: string): CampaignOperationResult {
    const res: CampaignOperationResult = {
      success: false,
      message: msg,
      costGold: 0,
      costWood: 0,
      costGrain: 0
    };
    return res;
  }

  private static failMarch(msg: string): MarchActionResult {
    const res: MarchActionResult = {
      success: false,
      battleTriggered: false,
      requiresBetrayalConfirmation: false,
      betrayalAssessment: null,
      battleConfig: null,
      supplyEvaluation: null,
      message: msg
    };
    return res;
  }

  private static clampInt(val: number, minVal: number, maxVal: number): number {
    if (val < minVal) {
      return minVal;
    }
    if (val > maxVal) {
      return maxVal;
    }
    return val;
  }
}
