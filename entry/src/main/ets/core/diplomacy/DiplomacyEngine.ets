/**
 * 八方合纵连横、信誉体系、量化媾和估值与双重同盟豁免引擎（DiplomacyEngine.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖）
 *
 * 核心职责（严格对齐 DESIGN.md 第 6、8.1~8.3、10.3~10.4 节）：
 * 1. 维护 8 大势力双边关系矩阵 [-100, +100] 与全局外交信誉 [0, 100]；
 * 2. 支持宣战、停火媾和、互不侵犯（R>=15, C>=40）、丝路通商（R>=25，商盟+35%）、
 *    军事同盟（R>=55, C>=50，共享视野与粮道借道）、朝贡附庸、递减防刷送礼、密使挑拨离间；
 * 3. 实现零随机数的量化媾和接受度公式 `evaluatePeaceOffer`（三档结果与反报价资产上限保护）；
 * 4. 实现背盟重罚与【双重同盟防御优先保护受侵略方 / 居中调停 3 回合停火】零扣信誉豁免铁律；
 * 5. 实现单势力占城 >= 13 座时的【反霸权合纵警觉】（相邻非同盟势力自动 +25 共同威胁好感）。
 */
import { GameConstants } from '../../common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../../config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../../config/FactionConfig';
import { getUnitConfigById } from '../../config/UnitConfig';
import {
  AiPersonality,
  CampaignNodeConfig,
  CampaignNodeType,
  FactionStaticConfig,
  UnitStaticStats
} from '../../model/GameTypes';
import {
  BetrayalAssessment,
  BilateralDiplomacyState,
  CampaignNodeRuntime,
  DiplomaticStatus,
  FactionCampaignRuntime,
  FactionId,
  PeaceEvaluationResult,
  PeaceOfferTerms,
  PeaceOutcomeKind,
  RosterEntry,
  SupplyLineGrade
} from '../CoreContracts';

/** 宣战评估与执行上下文（支持显式传入协防盟友或交战侵略方） */
export interface WarDeclarationContext {
  /** 若为协防被侵略的同盟国而参战，可显式指定被保护盟友（亦支持引擎自动识别） */
  readonly defendingVictimAlly?: FactionId;
}

/** 正式宣战执行结果 */
export interface WarDeclarationResult {
  readonly success: boolean;
  readonly assessment: BetrayalAssessment;
  readonly message: string;
}

/** 媾和评分各项明细拆解（供 UI 谈判滑块实时预览与单测精确断言） */
export interface PeaceScoreBreakdown {
  readonly warExhaustion: number;
  readonly battlefieldAdvantage: number;
  readonly offerValue: number;
  readonly thirdPartyThreat: number;
  readonly lowCredibilityPenalty: number;
  readonly netScore: number;
}

/** 媾和谈判执行结果 */
export interface PeaceExecutionResult {
  readonly evaluation: PeaceEvaluationResult;
  readonly breakdown: PeaceScoreBreakdown;
  readonly applied: boolean;
  readonly triggeredImmediateWar: boolean;
  readonly enemyMoraleBoostNextBattle: number;
}

/** 通用外交行动执行结果 */
export interface DiplomaticActionResult {
  readonly success: boolean;
  readonly relationDelta: number;
  readonly credibilityDelta: number;
  readonly message: string;
}

/** 停战期分期纳粮契约记录 */
export interface ActiveGrainTributeContract {
  readonly payer: FactionId;
  readonly receiver: FactionId;
  readonly grainPerTurn: number;
  remainingTurns: number;
}

/** 外交回合推进汇总报告 */
export interface DiplomacyTurnReport {
  readonly tradeGoldByFaction: Map<FactionId, number>;
  readonly expiredTreatyCredibilityBonuses: FactionId[];
  readonly activeHegemonFactions: FactionId[];
  readonly logs: string[];
}

/**
 * 战役外交与信誉计算核心引擎
 */
export class DiplomacyEngine {
  /** 互不侵犯条约门槛与持续回合 */
  public static readonly NON_AGGRESSION_MIN_REL: number = 15;
  public static readonly NON_AGGRESSION_MIN_CRED: number = 40;
  public static readonly NON_AGGRESSION_TURNS: number = 8;

  /** 丝路通商协定门槛与基础收益 */
  public static readonly TRADE_PACT_MIN_REL: number = 25;
  public static readonly BASE_TRADE_GOLD_PER_TURN: number = 60;
  public static readonly SHAMO_TRADE_BONUS_MULT: number = 1.35;
  public static readonly SHAMO_CARAVAN_TECH_BONUS_GOLD: number = 45;

  /** 低信誉禁盟线与赔款溢价比例（C < 40 求和赔款要求溢价 +80%） */
  public static readonly LOW_CREDIBILITY_BAN_THRESHOLD: number = 40;
  public static readonly LOW_CREDIBILITY_INDEMNITY_PREMIUM: number = 0.80;

  /** 反霸权合纵警觉城池数阈值（40 城之 35% = 14，DESIGN.md 8.3 明确标注 >= 13 座） */
  public static readonly HEGEMONY_ALERT_CITY_THRESHOLD: number = 13;
  public static readonly HEGEMONY_COMMON_THREAT_REL_BONUS: number = 25;

  /** 密使挑拨离间最低金币消耗与关系打击值 */
  public static readonly SOW_DISCORD_MIN_GOLD: number = 180;
  public static readonly SOW_DISCORD_REL_PENALTY: number = -20;

  private readonly staticNodeMap: Map<string, CampaignNodeConfig>;
  private readonly staticNodes: readonly CampaignNodeConfig[];

  /** 记录每场进行中战争的主动挑起方（canonicalPairKey -> aggressorFaction），用于双重同盟防御豁免判定 */
  private readonly warAggressorMap: Map<string, FactionId>;
  /** 记录每场战争已持续回合数（canonicalPairKey -> turns），用于计算厌战度 W_exhaust */
  private readonly warDurationMap: Map<string, number>;
  /** 记录朝贡附庸关系的宗主国映射（canonicalPairKey -> overlordFaction） */
  private readonly vassalOverlordMap: Map<string, FactionId>;
  /** 记录停战期每回合纳粮履约表 */
  private readonly grainTributeContracts: ActiveGrainTributeContract[];
  /** 记录本回合因谈判破裂被锁定派使的有向对（`proposer->target`） */
  private readonly envoyLockedThisTurn: Set<string>;
  /** 记录本回合送礼次数（`sender->receiver` -> count），实现单回合递减防刷 */
  private readonly giftCountThisTurn: Map<string, number>;
  /** 记录已激活反霸权 +25 共同威胁修正的双边键集合（防止跨回合重复无限叠加） */
  private readonly activeHegemonyBoostedPairs: Set<string>;
  /** 记录因屈辱求和被拒而赋予敌方下场战斗的士气加成（factionId -> moraleBonus） */
  private readonly pendingRejectedPeaceMoraleBonus: Map<FactionId, number>;

  public constructor(staticNodes: readonly CampaignNodeConfig[] = CAMPAIGN_MAP_NODES) {
    this.staticNodes = staticNodes;
    this.staticNodeMap = new Map<string, CampaignNodeConfig>();
    for (let i: number = 0; i < staticNodes.length; i++) {
      this.staticNodeMap.set(staticNodes[i].id, staticNodes[i]);
    }
    this.warAggressorMap = new Map<string, FactionId>();
    this.warDurationMap = new Map<string, number>();
    this.vassalOverlordMap = new Map<string, FactionId>();
    this.grainTributeContracts = [];
    this.envoyLockedThisTurn = new Set<string>();
    this.giftCountThisTurn = new Map<string, number>();
    this.activeHegemonyBoostedPairs = new Set<string>();
    this.pendingRejectedPeaceMoraleBonus = new Map<FactionId, number>();
  }

  /**
   * 重置引擎内部瞬态追踪表（用于加载新存档或重开战役）
   */
  public resetRuntimeTrackers(): void {
    this.warAggressorMap.clear();
    this.warDurationMap.clear();
    this.vassalOverlordMap.clear();
    this.grainTributeContracts.length = 0;
    this.envoyLockedThisTurn.clear();
    this.giftCountThisTurn.clear();
    this.activeHegemonyBoostedPairs.clear();
    this.pendingRejectedPeaceMoraleBonus.clear();
  }

  /**
   * 从读档恢复的外交与版图快照重建内部追踪器（确保读档后附庸宗主、战争回合与反霸权幂等性不丢失）
   */
  public syncTrackersFromLoadedState(
    diplomacy: readonly BilateralDiplomacyState[],
    nodes: readonly CampaignNodeRuntime[]
  ): void {
    this.resetRuntimeTrackers();

    // 统计各势力城池数以识别现存霸权国及附庸宗主归属
    const cityCounts: Map<FactionId, number> = new Map<FactionId, number>();
    for (let i: number = 0; i < nodes.length; i++) {
      const owner: FactionId = nodes[i].owner;
      const prev: number | undefined = cityCounts.get(owner);
      cityCounts.set(owner, (prev !== undefined ? prev : 0) + 1);
    }

    const hegemons: Set<FactionId> = new Set<FactionId>();
    cityCounts.forEach((cnt: number, fid: FactionId) => {
      if (cnt >= DiplomacyEngine.HEGEMONY_ALERT_CITY_THRESHOLD) {
        hegemons.add(fid);
      }
    });

    for (let i: number = 0; i < diplomacy.length; i++) {
      const rel: BilateralDiplomacyState = diplomacy[i];
      const pairKey: string = DiplomacyEngine.makePairKey(rel.factionA, rel.factionB);

      if (rel.status === DiplomaticStatus.WAR) {
        this.warDurationMap.set(pairKey, 1);
      } else if (rel.status === DiplomaticStatus.VASSAL) {
        const countA: number = cityCounts.get(rel.factionA) !== undefined ? (cityCounts.get(rel.factionA) as number) : 0;
        const countB: number = cityCounts.get(rel.factionB) !== undefined ? (cityCounts.get(rel.factionB) as number) : 0;
        const overlord: FactionId = countA >= countB ? rel.factionA : rel.factionB;
        this.vassalOverlordMap.set(pairKey, overlord);
      }

      if (
        hegemons.size > 0 &&
        !hegemons.has(rel.factionA) &&
        !hegemons.has(rel.factionB) &&
        rel.status !== DiplomaticStatus.ALLIANCE &&
        rel.status !== DiplomaticStatus.WAR &&
        this.doFactionsShareBorder(rel.factionA, rel.factionB, nodes)
      ) {
        this.activeHegemonyBoostedPairs.add(pairKey);
      }
    }
  }

  /**
   * 生成开局 8 大势力两两无序配对（共 28 组）的初始双边外交状态表
   * 对齐 DESIGN.md 第 6 节：血月祭司团与正统诸侯初始外交关系为 -15
   */
  public createInitialDiplomacyMatrix(): BilateralDiplomacyState[] {
    const matrix: BilateralDiplomacyState[] = [];
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      for (let j: number = i + 1; j < FACTION_STATIC_CONFIGS.length; j++) {
        const fA: FactionId = FACTION_STATIC_CONFIGS[i].id;
        const fB: FactionId = FACTION_STATIC_CONFIGS[j].id;
        let initRel: number = 0;

        if (fA === FactionId.XUEYUE || fB === FactionId.XUEYUE) {
          // 血月祭司邪道狂热，正统诸侯初始关系 -15
          initRel = -15;
        } else if (fA === FactionId.SHAMO || fB === FactionId.SHAMO) {
          // 沙漠商盟广结商缘，初始微幅友善 +6
          initRel = 6;
        } else if (
          (fA === FactionId.YANLONG && fB === FactionId.TIEYING) ||
          (fA === FactionId.TIEYING && fB === FactionId.YANLONG)
        ) {
          // 守序王国彼此默契 +8
          initRel = 8;
        }

        const entry: BilateralDiplomacyState = {
          factionA: fA,
          factionB: fB,
          relation: initRel,
          status: DiplomaticStatus.NEUTRAL,
          remainingTurns: 0,
          vendettaLockTurns: 0
        };
        matrix.push(entry);
      }
    }
    return matrix;
  }

  /**
   * 查询双边外交状态记录（对称无向查询）
   */
  public getBilateralState(
    diplomacy: readonly BilateralDiplomacyState[],
    factionA: FactionId,
    factionB: FactionId
  ): BilateralDiplomacyState | undefined {
    if (factionA === factionB) {
      return undefined;
    }
    for (let i: number = 0; i < diplomacy.length; i++) {
      const item: BilateralDiplomacyState = diplomacy[i];
      if (
        (item.factionA === factionA && item.factionB === factionB) ||
        (item.factionA === factionB && item.factionB === factionA)
      ) {
        return item;
      }
    }
    return undefined;
  }

  /**
   * 读取双边关系值 [-100, +100]
   */
  public getRelation(
    diplomacy: readonly BilateralDiplomacyState[],
    factionA: FactionId,
    factionB: FactionId
  ): number {
    if (factionA === factionB) {
      return GameConstants.DIPLOMACY_REL_MAX;
    }
    const state: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, factionA, factionB);
    return state !== undefined ? state.relation : 0;
  }

  /**
   * 读取双边当前条约状态
   */
  public getStatus(
    diplomacy: readonly BilateralDiplomacyState[],
    factionA: FactionId,
    factionB: FactionId
  ): DiplomaticStatus {
    if (factionA === factionB) {
      return DiplomaticStatus.ALLIANCE;
    }
    const state: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, factionA, factionB);
    return state !== undefined ? state.status : DiplomaticStatus.NEUTRAL;
  }

  /**
   * 判断双方是否缔结有正式军事同盟（开放粮道借道与战略视野共享）
   */
  public areAllied(
    diplomacy: readonly BilateralDiplomacyState[],
    factionA: FactionId,
    factionB: FactionId
  ): boolean {
    if (factionA === factionB) {
      return true;
    }
    return this.getStatus(diplomacy, factionA, factionB) === DiplomaticStatus.ALLIANCE;
  }

  /**
   * 判断双方是否共享战略视野（本方、正式军事同盟、朝贡附庸）
   */
  public sharesStrategicVision(
    diplomacy: readonly BilateralDiplomacyState[],
    factionA: FactionId,
    factionB: FactionId
  ): boolean {
    if (factionA === factionB) {
      return true;
    }
    const status: DiplomaticStatus = this.getStatus(diplomacy, factionA, factionB);
    return status === DiplomaticStatus.ALLIANCE || status === DiplomaticStatus.VASSAL;
  }

  /**
   * 显式登记某场交战的主动侵略方（供外部剧本或测试构造双重同盟冲突态使用）
   */
  public recordWarAggressor(aggressor: FactionId, victim: FactionId, durationTurns: number = 1): void {
    const key: string = DiplomacyEngine.makePairKey(aggressor, victim);
    this.warAggressorMap.set(key, aggressor);
    this.warDurationMap.set(key, Math.max(0, durationTurns));
  }

  /**
   * 获取指定势力因背盟触发的单场初始士气惩罚值（炎龙/铁鹰 -16，血月 -5，其余 -10）
   */
  public getBetrayalMoralePenaltyForFaction(factionId: FactionId): number {
    if (factionId === FactionId.YANLONG || factionId === FactionId.TIEYING) {
      return -16;
    }
    if (factionId === FactionId.XUEYUE) {
      return -5;
    }
    return -10;
  }

  /**
   * 消费并获取某势力因敌方屈辱求和破裂而赢得的下场战斗士气激励（+8）
   */
  public consumePendingPeaceBreakdownMoraleBonus(factionId: FactionId): number {
    const bonus: number | undefined = this.pendingRejectedPeaceMoraleBonus.get(factionId);
    if (bonus === undefined || bonus <= 0) {
      return 0;
    }
    this.pendingRejectedPeaceMoraleBonus.delete(factionId);
    return bonus;
  }

  /**
   * 查询本回合 `proposer` 对 `target` 是否因谈判破裂已被锁定派使
   */
  public isEnvoyLockedThisTurn(proposer: FactionId, target: FactionId): boolean {
    return this.envoyLockedThisTurn.has(`${proposer}->${target}`);
  }

  /**
   * 评估宣战或强行进攻是否触发【背盟重罚】或命中【双重同盟防御优先豁免铁律】（对齐 DESIGN.md 10.3）
   */
  public assessWarDeclaration(
    attacker: FactionId,
    defender: FactionId,
    diplomacy: readonly BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[],
    context?: WarDeclarationContext
  ): BetrayalAssessment {
    const relState: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, attacker, defender);
    if (relState === undefined || relState.status === DiplomaticStatus.WAR) {
      const alreadyWar: BetrayalAssessment = {
        isBetrayalTriggered: false,
        explanation: '双方已处于交战状态，无需重复宣战。',
        credibilityDelta: 0,
        globalRelationDelta: 0,
        vendettaTurns: 0,
        battleMoralePenalty: 0
      };
      return alreadyWar;
    }

    const isProtectedTreaty: boolean =
      relState.status === DiplomaticStatus.ALLIANCE ||
      relState.status === DiplomaticStatus.NON_AGGRESSION ||
      (relState.status === DiplomaticStatus.TRUCE && relState.remainingTurns > 0) ||
      relState.status === DiplomaticStatus.VASSAL;

    if (!isProtectedTreaty) {
      const cleanWar: BetrayalAssessment = {
        isBetrayalTriggered: false,
        explanation: '双方无同盟、互不侵犯或停战条约约束，属堂堂正正正式宣战，不扣减信誉。',
        credibilityDelta: 0,
        globalRelationDelta: 0,
        vendettaTurns: 0,
        battleMoralePenalty: 0
      };
      return cleanWar;
    }

    // 检查【双重同盟互攻防御优先豁免铁律】：
    // 若 A 同时与 B(defender)、C(victimAlly) 结有军事同盟，且 B 主动向 C 挑起侵略战争，则 A 协防被侵略方 C 豁免背盟！
    if (relState.status === DiplomaticStatus.ALLIANCE) {
      const invadedAlly: FactionId | null = this.findInvadedCommonAlly(
        attacker,
        defender,
        diplomacy,
        factions,
        context
      );
      if (invadedAlly !== null) {
        const exempted: BetrayalAssessment = {
          isBetrayalTriggered: false,
          explanation: `触发【双重同盟防御优先豁免】：挑衅方 ${defender} 主动侵略共同盟友 ${invadedAlly}，本方仗义协防受侵略盟友，零信誉扣除！`,
          credibilityDelta: 0,
          globalRelationDelta: 0,
          vendettaTurns: 0,
          battleMoralePenalty: 0
        };
        return exempted;
      }
    }

    const moralePenalty: number = this.getBetrayalMoralePenaltyForFaction(attacker);
    const betrayal: BetrayalAssessment = {
      isBetrayalTriggered: true,
      explanation: `撕毁现行【${relState.status}】条约偷袭盟友/停战国！信誉暴跌 -${GameConstants.BETRAYAL_CREDIBILITY_PENALTY}，受害国激活 10 回合血海世仇禁谈，天下诸侯好感 -${GameConstants.BETRAYAL_GLOBAL_RELATION_PENALTY}，连续 2 战初始士气 ${moralePenalty}。`,
      credibilityDelta: -GameConstants.BETRAYAL_CREDIBILITY_PENALTY,
      globalRelationDelta: -GameConstants.BETRAYAL_GLOBAL_RELATION_PENALTY,
      vendettaTurns: 10,
      battleMoralePenalty: moralePenalty
    };
    return betrayal;
  }

  /**
   * 执行宣战（自动结算背盟惩罚或双重同盟协防豁免）
   */
  public declareWar(
    attacker: FactionId,
    defender: FactionId,
    diplomacy: BilateralDiplomacyState[],
    factions: FactionCampaignRuntime[],
    context?: WarDeclarationContext
  ): WarDeclarationResult {
    if (attacker === defender) {
      const invalidAssessment: BetrayalAssessment = {
        isBetrayalTriggered: false,
        explanation: '不可向自身势力宣战。',
        credibilityDelta: 0,
        globalRelationDelta: 0,
        vendettaTurns: 0,
        battleMoralePenalty: 0
      };
      const failRes: WarDeclarationResult = {
        success: false,
        assessment: invalidAssessment,
        message: invalidAssessment.explanation
      };
      return failRes;
    }

    const relState: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, attacker, defender);
    const assessment: BetrayalAssessment = this.assessWarDeclaration(
      attacker,
      defender,
      diplomacy,
      factions,
      context
    );

    if (relState === undefined) {
      const missingRes: WarDeclarationResult = {
        success: false,
        assessment: assessment,
        message: '未找到双边外交记录。'
      };
      return missingRes;
    }

    if (relState.status === DiplomaticStatus.WAR) {
      const dupRes: WarDeclarationResult = {
        success: true,
        assessment: assessment,
        message: assessment.explanation
      };
      return dupRes;
    }

    // 终止双方任何未履行完毕的停战纳粮或附庸契约
    const pairKey: string = DiplomacyEngine.makePairKey(attacker, defender);
    this.vassalOverlordMap.delete(pairKey);
    this.removeGrainTributeBetween(attacker, defender);

    relState.status = DiplomaticStatus.WAR;
    relState.remainingTurns = 0;
    this.warAggressorMap.set(pairKey, attacker);
    this.warDurationMap.set(pairKey, 1);

    if (assessment.isBetrayalTriggered) {
      // 1. 受害国关系锁死 -100 + 10 回合血海世仇禁谈
      relState.relation = GameConstants.DIPLOMACY_REL_MIN;
      relState.vendettaLockTurns = assessment.vendettaTurns;

      // 2. 扣减背盟方信誉 -45 并挂载连续 2 场战斗初始士气惩罚
      const attackerRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, attacker);
      if (attackerRuntime !== undefined) {
        attackerRuntime.credibility = DiplomacyEngine.clamp(
          attackerRuntime.credibility + assessment.credibilityDelta,
          0,
          100
        );
        attackerRuntime.betrayalMoralePenaltyBattles = 2;
      }

      // 3. 天下共愤：全图其余所有存活势力对背盟方关系立即 -25
      for (let i: number = 0; i < factions.length; i++) {
        const other: FactionCampaignRuntime = factions[i];
        if (!other.isAlive || other.factionId === attacker || other.factionId === defender) {
          continue;
        }
        const thirdRel: BilateralDiplomacyState | undefined = this.getBilateralState(
          diplomacy,
          attacker,
          other.factionId
        );
        if (thirdRel !== undefined) {
          thirdRel.relation = DiplomacyEngine.clamp(
            thirdRel.relation + assessment.globalRelationDelta,
            GameConstants.DIPLOMACY_REL_MIN,
            GameConstants.DIPLOMACY_REL_MAX
          );
        }
      }
    } else {
      // 正常宣战或双重同盟协防豁免：双边关系降至 -80，零信誉损失
      relState.relation = Math.min(relState.relation, -80);
    }

    const okRes: WarDeclarationResult = {
      success: true,
      assessment: assessment,
      message: assessment.explanation
    };
    return okRes;
  }

  /**
   * 【双重同盟居中调停】：当 A 同时与 B、C 结有军事同盟，而 B 与 C 爆发战争时，
   * A 可居中斡旋促成 B、C 立即停火 3 回合，不视为对任何一方背盟，零信誉扣除（DESIGN.md 10.3）
   */
  public mediateDoubleAllianceConflict(
    mediator: FactionId,
    belligerentB: FactionId,
    belligerentC: FactionId,
    diplomacy: BilateralDiplomacyState[]
  ): DiplomaticActionResult {
    if (!this.areAllied(diplomacy, mediator, belligerentB) || !this.areAllied(diplomacy, mediator, belligerentC)) {
      const notAlliedRes: DiplomaticActionResult = {
        success: false,
        relationDelta: 0,
        credibilityDelta: 0,
        message: '居中调停失败：调停方必须同时与交战双方保持正式军事同盟。'
      };
      return notAlliedRes;
    }

    const warState: BilateralDiplomacyState | undefined = this.getBilateralState(
      diplomacy,
      belligerentB,
      belligerentC
    );
    if (warState === undefined || warState.status !== DiplomaticStatus.WAR) {
      const notAtWarRes: DiplomaticActionResult = {
        success: false,
        relationDelta: 0,
        credibilityDelta: 0,
        message: '目标两盟国当前并未处于交战状态。'
      };
      return notAtWarRes;
    }

    const pairKey: string = DiplomacyEngine.makePairKey(belligerentB, belligerentC);
    warState.status = DiplomaticStatus.TRUCE;
    warState.remainingTurns = 3;
    warState.relation = Math.max(warState.relation, -30);
    this.warAggressorMap.delete(pairKey);
    this.warDurationMap.delete(pairKey);

    const successRes: DiplomaticActionResult = {
      success: true,
      relationDelta: 0,
      credibilityDelta: 0,
      message: `${mediator} 成功居中调停盟友 ${belligerentB} 与 ${belligerentC} 罢兵停火 3 回合（零信誉扣除）。`
    };
    return successRes;
  }

  /**
   * 计算单座城关的外交割让估值（严格落在 25 ~ 60 区间，对齐 DESIGN.md 8.3）
   */
  public computeCityDiplomaticValue(nodeId: string): number {
    const cfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(nodeId);
    if (cfg === undefined) {
      return 30;
    }
    if (cfg.nodeType === CampaignNodeType.CAPITAL_CITADEL) {
      return 60;
    }
    let score: number = 16 + cfg.defenseLevel * 2.5 + (cfg.goldYield + cfg.woodYield + cfg.grainYield) / 22.0;
    if (cfg.isSupplyDepot) {
      score += 6;
    }
    if (cfg.nodeType === CampaignNodeType.FORTRESS_PASS) {
      score += 5;
    }
    return Math.round(DiplomacyEngine.clamp(score, 25, 60));
  }

  /**
   * 拆解计算媾和接受度五项核心指标：
   * AcceptScore = W_exhaust(0~45) - W_adv(-40~+40) + V_offer + T_third(0~30) - P_cred
   */
  public computePeaceScoreBreakdown(
    terms: PeaceOfferTerms,
    diplomacy: readonly BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[],
    nodes: readonly CampaignNodeRuntime[]
  ): PeaceScoreBreakdown {
    const proposerRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, terms.proposer);
    const targetRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, terms.target);
    const validTurns: number = Math.max(1, Math.floor(terms.truceTurns));

    // 1. 目标国厌战度 W_exhaust in [0, 45]
    const wExhaust: number = this.computeWarExhaustion(terms.proposer, terms.target, targetRuntime, nodes);

    // 2. 目标国相对求方的战场与综合国力优势 W_adv in [-40, +40]
    //    正值代表目标国占优（不愿轻易罢兵），负值代表求方占绝对优势（可迫签城下之盟）
    const wAdv: number = this.computeBattlefieldAdvantage(
      terms.target,
      terms.proposer,
      targetRuntime,
      proposerRuntime,
      nodes
    );

    // 3. 报价筹码折算分 V_offer = gold/25 + (grain*turns)/18 + sum(cityValue 25~60)
    //    若求方索取对方赔款（负数金粮）或索取对方城池，则 V_offer 为负值
    let cededCitySum: number = 0;
    const processedNodes: Set<string> = new Set<string>();
    for (let i: number = 0; i < terms.cededNodeIds.length; i++) {
      const cId: string = terms.cededNodeIds[i];
      if (processedNodes.has(cId)) {
        continue;
      }
      processedNodes.add(cId);
      const nodeRuntime: CampaignNodeRuntime | undefined = this.findNodeRuntime(nodes, cId);
      if (nodeRuntime === undefined) {
        continue;
      }
      const cityVal: number = this.computeCityDiplomaticValue(cId);
      if (nodeRuntime.owner === terms.proposer) {
        cededCitySum += cityVal;
      } else if (nodeRuntime.owner === terms.target) {
        cededCitySum -= cityVal;
      }
    }
    const safeGold: number = Number.isFinite(terms.goldIndemnity) ? terms.goldIndemnity : 0;
    const safeGrainPerTurn: number = Number.isFinite(terms.grainTributePerTurn)
      ? terms.grainTributePerTurn
      : 0;
    const vOffer: number = DiplomacyEngine.roundTo2(
      safeGold / 25.0 + (safeGrainPerTurn * validTurns) / 18.0 + cededCitySum
    );

    // 4. 目标国背后遭受的第三方战争与强敌环伺威胁 T_third in [0, 30]
    const tThird: number = this.computeThirdPartyThreat(
      terms.target,
      terms.proposer,
      diplomacy,
      factions,
      nodes
    );

    // 5. 求方低信誉怀疑折价 P_cred（当 C < 40 时求和赔款要求严格溢价 +80%）
    const proposerCred: number =
      proposerRuntime !== undefined ? proposerRuntime.credibility : GameConstants.CREDIBILITY_INIT;
    const baseWithoutCredAndOffer: number = wExhaust - wAdv + tThird;
    let pCred: number = 0;
    if (proposerCred < DiplomacyEngine.LOW_CREDIBILITY_BAN_THRESHOLD) {
      const rawCompensationNeeded: number = Math.max(0, -baseWithoutCredAndOffer);
      if (rawCompensationNeeded > 0) {
        pCred = DiplomacyEngine.roundTo2(
          rawCompensationNeeded * DiplomacyEngine.LOW_CREDIBILITY_INDEMNITY_PREMIUM
        );
      } else {
        pCred = DiplomacyEngine.roundTo2(
          10.0 + (DiplomacyEngine.LOW_CREDIBILITY_BAN_THRESHOLD - proposerCred) * 0.2
        );
      }
    } else if (proposerCred < 60) {
      pCred = DiplomacyEngine.roundTo2((60 - proposerCred) * 0.25);
    }

    const netScore: number = DiplomacyEngine.roundTo2(wExhaust - wAdv + vOffer + tThird - pCred);
    const breakdown: PeaceScoreBreakdown = {
      warExhaustion: wExhaust,
      battlefieldAdvantage: wAdv,
      offerValue: vOffer,
      thirdPartyThreat: tThird,
      lowCredibilityPenalty: pCred,
      netScore: netScore
    };
    return breakdown;
  }

  /**
   * 量化评估停火媾和报价（严格对齐 DESIGN.md 8.3 & 10.4）
   * - 世仇锁定期 vendettaLockTurns > 0 或本回合已斥退来使：直接返回 REJECTED_BREAKDOWN
   * - netScore >= 0：ACCEPTED
   * - -20 <= netScore < 0：COUNTER_OFFER（反报价金币/纳粮/割城严禁为负数，且严禁超出求方实际持有资产上限）
   * - netScore < -20：REJECTED_BREAKDOWN
   */
  public evaluatePeaceOffer(
    terms: PeaceOfferTerms,
    diplomacy: readonly BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[],
    nodes: readonly CampaignNodeRuntime[]
  ): PeaceEvaluationResult {
    const relState: BilateralDiplomacyState | undefined = this.getBilateralState(
      diplomacy,
      terms.proposer,
      terms.target
    );

    if (relState !== undefined && relState.vendettaLockTurns > 0) {
      const vendettaReject: PeaceEvaluationResult = {
        kind: PeaceOutcomeKind.REJECTED_BREAKDOWN,
        netScore: -999,
        explanation: `对方处于【血海世仇】禁谈锁定期（剩余 ${relState.vendettaLockTurns} 回合），断然斩杀来使拒绝议和！`,
        counterTerms: null
      };
      return vendettaReject;
    }

    if (this.isEnvoyLockedThisTurn(terms.proposer, terms.target)) {
      const lockedReject: PeaceEvaluationResult = {
        kind: PeaceOutcomeKind.REJECTED_BREAKDOWN,
        netScore: -100,
        explanation: '本回合来使已被对方斥退，城门紧闭，下回合方可再度遣使。',
        counterTerms: null
      };
      return lockedReject;
    }

    const breakdown: PeaceScoreBreakdown = this.computePeaceScoreBreakdown(
      terms,
      diplomacy,
      factions,
      nodes
    );

    if (breakdown.netScore >= 0) {
      const accepted: PeaceEvaluationResult = {
        kind: PeaceOutcomeKind.ACCEPTED,
        netScore: breakdown.netScore,
        explanation: `议和达成（净得分 ${breakdown.netScore} >= 0）：厌战 ${breakdown.warExhaustion}，态势优势 ${breakdown.battlefieldAdvantage}，筹码 ${breakdown.offerValue}，侧后威胁 ${breakdown.thirdPartyThreat}，信誉折价 ${breakdown.lowCredibilityPenalty}。`,
        counterTerms: null
      };
      return accepted;
    }

    if (breakdown.netScore >= -20) {
      const counter: PeaceOfferTerms = this.buildSafeCounterOffer(
        terms,
        breakdown,
        factions,
        nodes
      );
      const counterRes: PeaceEvaluationResult = {
        kind: PeaceOutcomeKind.COUNTER_OFFER,
        netScore: breakdown.netScore,
        explanation: `对方认为诚意稍欠（净得分 ${breakdown.netScore} 位于 [-20, 0)），提出可负担的加价反制方案。`,
        counterTerms: counter
      };
      return counterRes;
    }

    const rejected: PeaceEvaluationResult = {
      kind: PeaceOutcomeKind.REJECTED_BREAKDOWN,
      netScore: breakdown.netScore,
      explanation: `谈判彻底破裂（净得分 ${breakdown.netScore} < -20）：对方斥退来使，双边关系 -10 且本回合锁定再派使！`,
      counterTerms: null
    };
    return rejected;
  }

  /**
   * 执行停火媾和谈判流程（落地资源交割、领土割让、停战期锁定或破裂惩罚）
   */
  public executePeaceNegotiation(
    terms: PeaceOfferTerms,
    diplomacy: BilateralDiplomacyState[],
    factions: FactionCampaignRuntime[],
    nodes: CampaignNodeRuntime[]
  ): PeaceExecutionResult {
    const breakdown: PeaceScoreBreakdown = this.computePeaceScoreBreakdown(
      terms,
      diplomacy,
      factions,
      nodes
    );
    const evaluation: PeaceEvaluationResult = this.evaluatePeaceOffer(
      terms,
      diplomacy,
      factions,
      nodes
    );
    const relState: BilateralDiplomacyState | undefined = this.getBilateralState(
      diplomacy,
      terms.proposer,
      terms.target
    );

    if (evaluation.kind === PeaceOutcomeKind.ACCEPTED && relState !== undefined) {
      const proposerRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(
        factions,
        terms.proposer
      );
      const targetRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(
        factions,
        terms.target
      );
      const validTurns: number = DiplomacyEngine.normalizeTruceTurns(terms.truceTurns);

      if (proposerRuntime !== undefined && targetRuntime !== undefined) {
        // 核验一次性赔款资产是否充足
        if (terms.goldIndemnity > 0 && proposerRuntime.gold < terms.goldIndemnity) {
          const insufficientEval: PeaceEvaluationResult = {
            kind: PeaceOutcomeKind.COUNTER_OFFER,
            netScore: -1,
            explanation: '求方国库现银不足以支付承诺赔款，自动生成按实际资产封顶的替代方案。',
            counterTerms: this.buildSafeCounterOffer(terms, breakdown, factions, nodes)
          };
          const insufficientRes: PeaceExecutionResult = {
            evaluation: insufficientEval,
            breakdown: breakdown,
            applied: false,
            triggeredImmediateWar: false,
            enemyMoraleBoostNextBattle: 0
          };
          return insufficientRes;
        }
        if (terms.goldIndemnity < 0 && targetRuntime.gold < Math.abs(terms.goldIndemnity)) {
          const capGold: number = Math.max(0, Math.floor(targetRuntime.gold));
          targetRuntime.gold -= capGold;
          proposerRuntime.gold += capGold;
        } else if (terms.goldIndemnity > 0) {
          proposerRuntime.gold -= terms.goldIndemnity;
          targetRuntime.gold += terms.goldIndemnity;
        } else if (terms.goldIndemnity < 0) {
          const demandedGold: number = Math.abs(terms.goldIndemnity);
          targetRuntime.gold -= demandedGold;
          proposerRuntime.gold += demandedGold;
        }

        // 登记分期纳粮契约
        this.removeGrainTributeBetween(terms.proposer, terms.target);
        if (terms.grainTributePerTurn > 0) {
          const contract: ActiveGrainTributeContract = {
            payer: terms.proposer,
            receiver: terms.target,
            grainPerTurn: Math.floor(terms.grainTributePerTurn),
            remainingTurns: validTurns
          };
          this.grainTributeContracts.push(contract);
        } else if (terms.grainTributePerTurn < 0) {
          const reverseContract: ActiveGrainTributeContract = {
            payer: terms.target,
            receiver: terms.proposer,
            grainPerTurn: Math.floor(Math.abs(terms.grainTributePerTurn)),
            remainingTurns: validTurns
          };
          this.grainTributeContracts.push(reverseContract);
        }

        // 执行城池割让移交（确保任何一方至少保留王都/最后 1 城不被议和直接灭国）
        for (let i: number = 0; i < terms.cededNodeIds.length; i++) {
          const nodeRuntime: CampaignNodeRuntime | undefined = this.findNodeRuntime(
            nodes,
            terms.cededNodeIds[i]
          );
          if (nodeRuntime === undefined) {
            continue;
          }
          if (nodeRuntime.owner === terms.proposer && this.countOwnedNodes(nodes, terms.proposer) > 1) {
            nodeRuntime.owner = terms.target;
            nodeRuntime.isolatedTurns = 0;
            nodeRuntime.hasAmbushTrap = false;
          } else if (nodeRuntime.owner === terms.target && this.countOwnedNodes(nodes, terms.target) > 1) {
            nodeRuntime.owner = terms.proposer;
            nodeRuntime.isolatedTurns = 0;
            nodeRuntime.hasAmbushTrap = false;
          }
        }

        // 停火签约生效后，立即将处于对方领土内的野战军团撤回本方最近城池（对齐 DESIGN.md 10.4）
        this.evacuateArmyFromForeignTerritory(proposerRuntime, nodes, diplomacy);
        this.evacuateArmyFromForeignTerritory(targetRuntime, nodes, diplomacy);
      }

      const pairKey: string = DiplomacyEngine.makePairKey(terms.proposer, terms.target);
      this.warAggressorMap.delete(pairKey);
      this.warDurationMap.delete(pairKey);
      relState.status = DiplomaticStatus.TRUCE;
      relState.remainingTurns = validTurns;
      relState.relation = DiplomacyEngine.clamp(Math.max(relState.relation, -30) + 8, -100, 100);

      const okExec: PeaceExecutionResult = {
        evaluation: evaluation,
        breakdown: breakdown,
        applied: true,
        triggeredImmediateWar: false,
        enemyMoraleBoostNextBattle: 0
      };
      return okExec;
    }

    if (evaluation.kind === PeaceOutcomeKind.COUNTER_OFFER) {
      const counterExec: PeaceExecutionResult = {
        evaluation: evaluation,
        breakdown: breakdown,
        applied: false,
        triggeredImmediateWar: false,
        enemyMoraleBoostNextBattle: 0
      };
      return counterExec;
    }

    // REJECTED_BREAKDOWN：本回合锁定对该国再派使，关系 -10；战前讹诈破裂直接开战，战中求和被拒敌获 +8 士气
    const wasAlreadyLocked: boolean = this.isEnvoyLockedThisTurn(terms.proposer, terms.target);
    this.envoyLockedThisTurn.add(`${terms.proposer}->${terms.target}`);

    let triggeredWar: boolean = false;
    let moraleBoost: number = 0;

    if (relState !== undefined && !wasAlreadyLocked) {
      relState.relation = DiplomacyEngine.clamp(
        relState.relation - 10,
        GameConstants.DIPLOMACY_REL_MIN,
        GameConstants.DIPLOMACY_REL_MAX
      );
      if (relState.status === DiplomaticStatus.WAR) {
        moraleBoost = 8;
        this.pendingRejectedPeaceMoraleBonus.set(terms.target, moraleBoost);
      } else if (relState.status === DiplomaticStatus.NEUTRAL && breakdown.offerValue < 0) {
        // 战前边缘讹诈破裂（索取对方赔款、分期纳粮或边境城池被斥退）：对方当回合直接宣战压境
        this.declareWar(terms.target, terms.proposer, diplomacy, factions);
        triggeredWar = true;
      }
    }

    const breakdownExec: PeaceExecutionResult = {
      evaluation: evaluation,
      breakdown: breakdown,
      applied: false,
      triggeredImmediateWar: triggeredWar,
      enemyMoraleBoostNextBattle: moraleBoost
    };
    return breakdownExec;
  }

  /**
   * 缔结【互不侵犯条约】（需 R >= +15, C >= 40，持续 8 回合，消除接壤摩擦）
   */
  public signNonAggressionPact(
    proposer: FactionId,
    target: FactionId,
    diplomacy: BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[]
  ): DiplomaticActionResult {
    const relState: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, proposer, target);
    const propRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, proposer);
    if (relState === undefined || propRuntime === undefined) {
      return DiplomacyEngine.failAction('外交对象无效。');
    }
    if (relState.status === DiplomaticStatus.WAR || relState.vendettaLockTurns > 0) {
      return DiplomacyEngine.failAction('交战中或处于血海世仇期，无法签署互不侵犯条约。');
    }
    if (propRuntime.credibility < DiplomacyEngine.NON_AGGRESSION_MIN_CRED) {
      return DiplomacyEngine.failAction(
        `外交信誉不足（当前 ${propRuntime.credibility} < ${DiplomacyEngine.NON_AGGRESSION_MIN_CRED}），对方拒绝签约。`
      );
    }
    if (relState.relation < DiplomacyEngine.NON_AGGRESSION_MIN_REL) {
      return DiplomacyEngine.failAction(
        `双边关系不足（当前 ${relState.relation} < +${DiplomacyEngine.NON_AGGRESSION_MIN_REL}）。`
      );
    }
    if (relState.status === DiplomaticStatus.ALLIANCE) {
      return DiplomacyEngine.failAction('双方已缔结更高阶的军事攻守同盟。');
    }

    relState.status = DiplomaticStatus.NON_AGGRESSION;
    relState.remainingTurns = DiplomacyEngine.NON_AGGRESSION_TURNS;
    relState.relation = DiplomacyEngine.clamp(relState.relation + 5, -100, 100);

    const okRes: DiplomaticActionResult = {
      success: true,
      relationDelta: 5,
      credibilityDelta: 0,
      message: `${proposer} 与 ${target} 正式签署 8 回合【互不侵犯条约】。`
    };
    return okRes;
  }

  /**
   * 缔结【丝路通商协定】（需 R >= +25，沙漠商盟享 +35% 贸易收益及专属科技加成）
   */
  public signTradePact(
    proposer: FactionId,
    target: FactionId,
    diplomacy: BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[]
  ): DiplomaticActionResult {
    const relState: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, proposer, target);
    const propRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, proposer);
    if (relState === undefined || propRuntime === undefined) {
      return DiplomacyEngine.failAction('外交对象无效。');
    }
    if (relState.status === DiplomaticStatus.WAR || relState.vendettaLockTurns > 0) {
      return DiplomacyEngine.failAction('战火阻断商路，无法缔结丝路通商协定。');
    }
    if (relState.relation < DiplomacyEngine.TRADE_PACT_MIN_REL) {
      return DiplomacyEngine.failAction(
        `双边关系不足（当前 ${relState.relation} < +${DiplomacyEngine.TRADE_PACT_MIN_REL}）。`
      );
    }
    if (relState.status !== DiplomaticStatus.ALLIANCE) {
      relState.status = DiplomaticStatus.TRADE_PACT;
      relState.remainingTurns = 0;
    }
    relState.relation = DiplomacyEngine.clamp(relState.relation + 6, -100, 100);

    const okRes: DiplomaticActionResult = {
      success: true,
      relationDelta: 6,
      credibilityDelta: 0,
      message: `${proposer} 与 ${target} 开通【丝路通商协定】，每回合互享贸易税赋与好感提升。`
    };
    return okRes;
  }

  /**
   * 缔结【军事攻守同盟】（需 R >= +55, C >= 50，且任一方信誉不得低于 40 禁盟红线）
   */
  public formAlliance(
    proposer: FactionId,
    target: FactionId,
    diplomacy: BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[]
  ): DiplomaticActionResult {
    const relState: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, proposer, target);
    const propRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, proposer);
    const targetRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, target);
    if (relState === undefined || propRuntime === undefined || targetRuntime === undefined) {
      return DiplomacyEngine.failAction('外交对象无效。');
    }
    if (relState.status === DiplomaticStatus.WAR || relState.vendettaLockTurns > 0) {
      return DiplomacyEngine.failAction('交战或血海世仇状态下不可结盟。');
    }
    if (
      propRuntime.credibility < GameConstants.ALLIANCE_MIN_CREDIBILITY ||
      targetRuntime.credibility < DiplomacyEngine.LOW_CREDIBILITY_BAN_THRESHOLD
    ) {
      return DiplomacyEngine.failAction(
        `信誉未达盟约门槛（求方需 >= ${GameConstants.ALLIANCE_MIN_CREDIBILITY}，且双方均不可低于 ${DiplomacyEngine.LOW_CREDIBILITY_BAN_THRESHOLD} 禁盟线）。`
      );
    }
    if (relState.relation < GameConstants.ALLIANCE_MIN_RELATION) {
      return DiplomacyEngine.failAction(
        `双边关系不足（当前 ${relState.relation} < +${GameConstants.ALLIANCE_MIN_RELATION}）。`
      );
    }

    relState.status = DiplomaticStatus.ALLIANCE;
    relState.remainingTurns = 0;
    relState.relation = DiplomacyEngine.clamp(relState.relation + 10, -100, 100);

    const okRes: DiplomaticActionResult = {
      success: true,
      relationDelta: 10,
      credibilityDelta: 0,
      message: `${proposer} 与 ${target} 歃血缔结【军事攻守同盟】，开放战略视野共享与 BFS 粮道借道权！`
    };
    return okRes;
  }

  /**
   * 缔结【朝贡附庸】（残存 1 城的弱小势力纳贡求存，对齐 DESIGN.md 8.2）
   */
  public establishVassalage(
    vassal: FactionId,
    overlord: FactionId,
    diplomacy: BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[],
    nodes: readonly CampaignNodeRuntime[]
  ): DiplomaticActionResult {
    if (vassal === overlord) {
      return DiplomacyEngine.failAction('不可收自身为附庸。');
    }
    const relState: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, vassal, overlord);
    const overlordRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, overlord);
    if (relState === undefined || overlordRuntime === undefined) {
      return DiplomacyEngine.failAction('外交对象无效。');
    }
    if (relState.vendettaLockTurns > 0) {
      return DiplomacyEngine.failAction('血海世仇未消，拒绝接纳投诚。');
    }
    const vassalCityCount: number = this.countOwnedNodes(nodes, vassal);
    const overlordCityCount: number = this.countOwnedNodes(nodes, overlord);
    if (vassalCityCount !== 1 || overlordCityCount <= vassalCityCount) {
      return DiplomacyEngine.failAction('仅当弱小势力残存最后 1 座孤城且宗主国实力占优时方可纳贡称臣。');
    }

    const pairKey: string = DiplomacyEngine.makePairKey(vassal, overlord);
    this.warAggressorMap.delete(pairKey);
    this.warDurationMap.delete(pairKey);
    this.vassalOverlordMap.set(pairKey, overlord);

    relState.status = DiplomaticStatus.VASSAL;
    relState.remainingTurns = 12;
    relState.relation = DiplomacyEngine.clamp(Math.max(relState.relation, 15), -100, 100);

    const okRes: DiplomaticActionResult = {
      success: true,
      relationDelta: 15,
      credibilityDelta: 0,
      message: `${vassal} 向强国 ${overlord} 奉表称臣，结为【朝贡附庸】每回合进献岁币军粮以求存续。`
    };
    return okRes;
  }

  /**
   * 外交馈赠金粮（含单回合边际递减防无限刷好感机制，对齐 DESIGN.md 8.1）
   */
  public sendGift(
    sender: FactionId,
    receiver: FactionId,
    goldAmount: number,
    grainAmount: number,
    diplomacy: BilateralDiplomacyState[],
    factions: FactionCampaignRuntime[]
  ): DiplomaticActionResult {
    const cleanGold: number = Math.max(0, Math.floor(goldAmount));
    const cleanGrain: number = Math.max(0, Math.floor(grainAmount));
    if (sender === receiver || (cleanGold === 0 && cleanGrain === 0)) {
      return DiplomacyEngine.failAction('赠礼数额必须大于 0 且目标有效。');
    }

    const senderRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, sender);
    const receiverRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, receiver);
    const relState: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, sender, receiver);
    if (senderRuntime === undefined || receiverRuntime === undefined || relState === undefined) {
      return DiplomacyEngine.failAction('未找到赠礼双方势力状态。');
    }
    if (relState.vendettaLockTurns > 0) {
      return DiplomacyEngine.failAction('血海世仇期间对方拒收一切馈赠。');
    }
    if (senderRuntime.gold < cleanGold || senderRuntime.grain < cleanGrain) {
      return DiplomacyEngine.failAction('国库金粮不足，无法派发礼单。');
    }

    senderRuntime.gold -= cleanGold;
    senderRuntime.grain -= cleanGrain;
    receiverRuntime.gold += cleanGold;
    receiverRuntime.grain += cleanGrain;

    const giftKey: string = `${sender}->${receiver}`;
    const prevCount: number | undefined = this.giftCountThisTurn.get(giftKey);
    const sendIndex: number = prevCount !== undefined ? prevCount : 0;
    this.giftCountThisTurn.set(giftKey, sendIndex + 1);

    // 单回合递减系数：第1次 100%，第2次 50%，第3次 25%，第4次起 10%
    let diminishingScale: number = 0.10;
    if (sendIndex === 0) {
      diminishingScale = 1.0;
    } else if (sendIndex === 1) {
      diminishingScale = 0.50;
    } else if (sendIndex === 2) {
      diminishingScale = 0.25;
    }

    let rawGain: number = cleanGold / 20.0 + cleanGrain / 30.0;
    if (sender === FactionId.SHAMO && senderRuntime.unlockedTechIds.indexOf('sm_tech_caravan') >= 0) {
      rawGain *= 1.25;
    }

    const cappedBaseGain: number = Math.min(25, rawGain);
    const finalDelta: number = Math.max(1, Math.round(cappedBaseGain * diminishingScale));
    const oldRel: number = relState.relation;
    relState.relation = DiplomacyEngine.clamp(
      relState.relation + finalDelta,
      GameConstants.DIPLOMACY_REL_MIN,
      GameConstants.DIPLOMACY_REL_MAX
    );
    const actualDelta: number = relState.relation - oldRel;

    const okRes: DiplomaticActionResult = {
      success: true,
      relationDelta: actualDelta,
      credibilityDelta: 0,
      message: `${sender} 向 ${receiver} 馈赠金 ${cleanGold}、粮 ${cleanGrain}（本回合第 ${sendIndex + 1} 次，递减倍率 ${diminishingScale}），好感 +${actualDelta}。`
    };
    return okRes;
  }

  /**
   * 派遣密使挑拨离间两大目标势力（耗费重金使目标双边关系 -20，若跌破同盟维系线则瓦解敌方同盟）
   */
  public sowDiscord(
    instigator: FactionId,
    targetA: FactionId,
    targetB: FactionId,
    goldCost: number,
    diplomacy: BilateralDiplomacyState[],
    factions: FactionCampaignRuntime[]
  ): DiplomaticActionResult {
    if (targetA === targetB || instigator === targetA || instigator === targetB) {
      return DiplomacyEngine.failAction('挑拨离间必须指定两个不同的第三方势力。');
    }
    const spendGold: number = Math.max(DiplomacyEngine.SOW_DISCORD_MIN_GOLD, Math.floor(goldCost));
    const instigatorRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, instigator);
    const targetRel: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, targetA, targetB);
    if (instigatorRuntime === undefined || targetRel === undefined) {
      return DiplomacyEngine.failAction('外交目标状态不存在。');
    }
    if (instigatorRuntime.gold < spendGold) {
      return DiplomacyEngine.failAction(
        `密使经费不足（需至少 ${spendGold} 金币，当前持有 ${instigatorRuntime.gold}）。`
      );
    }

    instigatorRuntime.gold -= spendGold;
    const oldRel: number = targetRel.relation;
    targetRel.relation = DiplomacyEngine.clamp(
      targetRel.relation + DiplomacyEngine.SOW_DISCORD_REL_PENALTY,
      GameConstants.DIPLOMACY_REL_MIN,
      GameConstants.DIPLOMACY_REL_MAX
    );
    const delta: number = targetRel.relation - oldRel;

    let allianceBrokenNote: string = '';
    if (targetRel.status === DiplomaticStatus.ALLIANCE && targetRel.relation < 35) {
      targetRel.status = DiplomaticStatus.NON_AGGRESSION;
      targetRel.remainingTurns = 3;
      allianceBrokenNote = ' 双方猜忌深重，军事同盟当场瓦解降级！';
    }

    const okRes: DiplomaticActionResult = {
      success: true,
      relationDelta: delta,
      credibilityDelta: 0,
      message: `密使散播流言离间 ${targetA} 与 ${targetB}，使其双边关系 ${delta}！${allianceBrokenNote}`
    };
    return okRes;
  }

  /**
   * 记录盟友并肩抗敌好感加成（共同作战一场 +15，对齐 DESIGN.md 8.1）
   */
  public recordJointBattleBonus(
    factionA: FactionId,
    factionB: FactionId,
    diplomacy: BilateralDiplomacyState[]
  ): void {
    const rel: BilateralDiplomacyState | undefined = this.getBilateralState(diplomacy, factionA, factionB);
    if (rel !== undefined && rel.status !== DiplomaticStatus.WAR) {
      rel.relation = DiplomacyEngine.clamp(rel.relation + 15, -100, 100);
    }
  }

  /**
   * 计算指定势力本回合通过【丝路通商协定 / 军事同盟商路】获得的贸易金币收入
   * 沙漠商盟享 +35% 贸易收益加成及《丝路商队》每份商约额外 +45 金币
   */
  public calculateTurnTradeIncomeForFaction(
    factionId: FactionId,
    diplomacy: readonly BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[]
  ): number {
    const runtime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, factionId);
    if (runtime === undefined || !runtime.isAlive) {
      return 0;
    }

    let activePacts: number = 0;
    for (let i: number = 0; i < diplomacy.length; i++) {
      const rel: BilateralDiplomacyState = diplomacy[i];
      const involvesSelf: boolean = rel.factionA === factionId || rel.factionB === factionId;
      if (!involvesSelf) {
        continue;
      }
      const partnerId: FactionId = rel.factionA === factionId ? rel.factionB : rel.factionA;
      const partnerRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, partnerId);
      if (partnerRuntime === undefined || !partnerRuntime.isAlive) {
        continue;
      }
      if (rel.status === DiplomaticStatus.TRADE_PACT || rel.status === DiplomaticStatus.ALLIANCE) {
        activePacts++;
      }
    }

    if (activePacts === 0) {
      return 0;
    }

    let perPactGold: number = DiplomacyEngine.BASE_TRADE_GOLD_PER_TURN;
    if (factionId === FactionId.SHAMO) {
      perPactGold = Math.round(perPactGold * DiplomacyEngine.SHAMO_TRADE_BONUS_MULT);
      if (runtime.unlockedTechIds.indexOf('sm_tech_caravan') >= 0) {
        perPactGold += DiplomacyEngine.SHAMO_CARAVAN_TECH_BONUS_GOLD;
      }
    }
    return activePacts * perPactGold;
  }

  /**
   * 检测并落地【反霸权合纵警觉】（DESIGN.md 8.3）：
   * 任一势力占领城关 >= 13 座时，其余所有相邻且未结盟的存活非霸权势力之间自动获得 +25 共同威胁好感修正
   */
  public applyAntiHegemonyCheck(
    diplomacy: BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[],
    nodes: readonly CampaignNodeRuntime[]
  ): FactionId[] {
    const hegemons: FactionId[] = [];
    for (let i: number = 0; i < factions.length; i++) {
      const f: FactionCampaignRuntime = factions[i];
      if (!f.isAlive) {
        continue;
      }
      if (this.countOwnedNodes(nodes, f.factionId) >= DiplomacyEngine.HEGEMONY_ALERT_CITY_THRESHOLD) {
        hegemons.push(f.factionId);
      }
    }

    if (hegemons.length === 0) {
      this.activeHegemonyBoostedPairs.clear();
      return [];
    }

    for (let i: number = 0; i < diplomacy.length; i++) {
      const rel: BilateralDiplomacyState = diplomacy[i];
      if (hegemons.indexOf(rel.factionA) >= 0 || hegemons.indexOf(rel.factionB) >= 0) {
        continue;
      }
      const fARuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, rel.factionA);
      const fBRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, rel.factionB);
      if (fARuntime === undefined || fBRuntime === undefined || !fARuntime.isAlive || !fBRuntime.isAlive) {
        continue;
      }
      if (rel.status === DiplomaticStatus.ALLIANCE || rel.status === DiplomaticStatus.WAR) {
        continue;
      }
      if (!this.doFactionsShareBorder(rel.factionA, rel.factionB, nodes)) {
        continue;
      }

      const pairKey: string = DiplomacyEngine.makePairKey(rel.factionA, rel.factionB);
      if (!this.activeHegemonyBoostedPairs.has(pairKey)) {
        rel.relation = DiplomacyEngine.clamp(
          rel.relation + DiplomacyEngine.HEGEMONY_COMMON_THREAT_REL_BONUS,
          GameConstants.DIPLOMACY_REL_MIN,
          GameConstants.DIPLOMACY_REL_MAX
        );
        this.activeHegemonyBoostedPairs.add(pairKey);
      }
    }

    return hegemons;
  }

  /**
   * 推进一回合全图外交演化：
   * 1. 清空单回合派使锁与送礼递减计数；
   * 2. 结算通商贸易收入、停战分期纳粮、附庸岁币进献；
   * 3. 结算接壤摩擦（-2/回合）与商约亲善（+2/回合）；
   * 4. 递减世仇锁定期与有期条约回合数，停战/条约自然届满双方信誉 +3；
   * 5. 执行反霸权 >= 13 城合纵警觉检测。
   */
  public advanceDiplomacyTurn(
    diplomacy: BilateralDiplomacyState[],
    factions: FactionCampaignRuntime[],
    nodes: readonly CampaignNodeRuntime[]
  ): DiplomacyTurnReport {
    this.envoyLockedThisTurn.clear();
    this.giftCountThisTurn.clear();

    const logs: string[] = [];
    const tradeGoldMap: Map<FactionId, number> = new Map<FactionId, number>();
    const expiredCredFactions: FactionId[] = [];

    // 1. 发放通商协定金币收益
    for (let i: number = 0; i < factions.length; i++) {
      const f: FactionCampaignRuntime = factions[i];
      if (!f.isAlive) {
        tradeGoldMap.set(f.factionId, 0);
        continue;
      }
      const tradeGold: number = this.calculateTurnTradeIncomeForFaction(f.factionId, diplomacy, factions);
      f.gold += tradeGold;
      tradeGoldMap.set(f.factionId, tradeGold);
    }

    // 2. 履行停战分期纳粮契约
    for (let i: number = this.grainTributeContracts.length - 1; i >= 0; i--) {
      const contract: ActiveGrainTributeContract = this.grainTributeContracts[i];
      const payerRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, contract.payer);
      const recvRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, contract.receiver);
      if (payerRuntime !== undefined && recvRuntime !== undefined && payerRuntime.isAlive && recvRuntime.isAlive) {
        const actualGrain: number = Math.min(payerRuntime.grain, contract.grainPerTurn);
        payerRuntime.grain -= actualGrain;
        recvRuntime.grain += actualGrain;
      }
      contract.remainingTurns -= 1;
      if (contract.remainingTurns <= 0) {
        this.grainTributeContracts.splice(i, 1);
      }
    }

    // 3. 推进双边关系演化、附庸纳贡、战争持续回合与条约自然到期信誉 +3
    for (let i: number = 0; i < diplomacy.length; i++) {
      const rel: BilateralDiplomacyState = diplomacy[i];
      const fA: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, rel.factionA);
      const fB: FactionCampaignRuntime | undefined = this.findFactionRuntime(factions, rel.factionB);
      if (fA === undefined || fB === undefined || !fA.isAlive || !fB.isAlive) {
        continue;
      }

      const pairKey: string = DiplomacyEngine.makePairKey(rel.factionA, rel.factionB);

      if (rel.vendettaLockTurns > 0) {
        rel.vendettaLockTurns -= 1;
      }

      if (rel.status === DiplomaticStatus.WAR) {
        const prevDur: number | undefined = this.warDurationMap.get(pairKey);
        this.warDurationMap.set(pairKey, (prevDur !== undefined ? prevDur : 0) + 1);
      } else if (rel.status === DiplomaticStatus.TRADE_PACT || rel.status === DiplomaticStatus.ALLIANCE) {
        rel.relation = DiplomacyEngine.clamp(rel.relation + 2, -100, 100);
      } else if (rel.status === DiplomaticStatus.VASSAL) {
        const overlordId: FactionId | undefined = this.vassalOverlordMap.get(pairKey);
        if (overlordId !== undefined) {
          const vassalRuntime: FactionCampaignRuntime = overlordId === fA.factionId ? fB : fA;
          const overlordRuntime: FactionCampaignRuntime = overlordId === fA.factionId ? fA : fB;
          const tributeGold: number = Math.min(vassalRuntime.gold, 35);
          const tributeGrain: number = Math.min(vassalRuntime.grain, 45);
          vassalRuntime.gold -= tributeGold;
          vassalRuntime.grain -= tributeGrain;
          overlordRuntime.gold += tributeGold;
          overlordRuntime.grain += tributeGrain;
        }
      } else if (rel.status === DiplomaticStatus.NEUTRAL) {
        // 领土接壤摩擦：每回合 -2
        if (this.doFactionsShareBorder(rel.factionA, rel.factionB, nodes)) {
          rel.relation = DiplomacyEngine.clamp(rel.relation - 2, -100, 100);
        }
      }

      // 有期条约（停战协定 / 互不侵犯）倒计时及严守至届满 +3 信誉奖励
      if (
        (rel.status === DiplomaticStatus.TRUCE || rel.status === DiplomaticStatus.NON_AGGRESSION) &&
        rel.remainingTurns > 0
      ) {
        rel.remainingTurns -= 1;
        if (rel.remainingTurns === 0) {
          const expiredType: DiplomaticStatus = rel.status;
          rel.status = DiplomaticStatus.NEUTRAL;
          fA.credibility = DiplomacyEngine.clamp(fA.credibility + 3, 0, 100);
          fB.credibility = DiplomacyEngine.clamp(fB.credibility + 3, 0, 100);
          expiredCredFactions.push(fA.factionId);
          expiredCredFactions.push(fB.factionId);
          logs.push(
            `【守约重信】${fA.factionId} 与 ${fB.factionId} 严守【${expiredType}】至期满，双方外交信誉各 +3！`
          );
        }
      }
    }

    // 4. 反霸权合纵警觉检查
    const hegemons: FactionId[] = this.applyAntiHegemonyCheck(diplomacy, factions, nodes);
    if (hegemons.length > 0) {
      logs.push(
        `【合纵警觉】霸权势力（${hegemons.join(', ')}）占城达 13 座以上，接壤诸侯同仇敌忾好感 +25！`
      );
    }

    const report: DiplomacyTurnReport = {
      tradeGoldByFaction: tradeGoldMap,
      expiredTreatyCredibilityBonuses: expiredCredFactions,
      activeHegemonFactions: hegemons,
      logs: logs
    };
    return report;
  }

  /**
   * 判断两个势力在大地图上是否存在相邻接壤的城关
   */
  public doFactionsShareBorder(
    factionA: FactionId,
    factionB: FactionId,
    nodes: readonly CampaignNodeRuntime[]
  ): boolean {
    if (factionA === factionB) {
      return false;
    }
    const ownerByNode: Map<string, FactionId> = new Map<string, FactionId>();
    for (let i: number = 0; i < nodes.length; i++) {
      ownerByNode.set(nodes[i].nodeId, nodes[i].owner);
    }

    for (let i: number = 0; i < nodes.length; i++) {
      const node: CampaignNodeRuntime = nodes[i];
      if (node.owner !== factionA) {
        continue;
      }
      const cfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(node.nodeId);
      if (cfg === undefined) {
        continue;
      }
      for (let j: number = 0; j < cfg.neighbors.length; j++) {
        const nbrOwner: FactionId | undefined = ownerByNode.get(cfg.neighbors[j]);
        if (nbrOwner === factionB) {
          return true;
        }
      }
    }
    return false;
  }

  private findInvadedCommonAlly(
    attacker: FactionId,
    defender: FactionId,
    diplomacy: readonly BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[],
    context?: WarDeclarationContext
  ): FactionId | null {
    if (context !== undefined && context.defendingVictimAlly !== undefined) {
      const explicitAlly: FactionId = context.defendingVictimAlly;
      if (
        explicitAlly !== attacker &&
        explicitAlly !== defender &&
        this.areAllied(diplomacy, attacker, explicitAlly) &&
        this.getStatus(diplomacy, defender, explicitAlly) === DiplomaticStatus.WAR
      ) {
        const key: string = DiplomacyEngine.makePairKey(defender, explicitAlly);
        const recordedAggressor: FactionId | undefined = this.warAggressorMap.get(key);
        if (recordedAggressor === undefined || recordedAggressor === defender) {
          return explicitAlly;
        }
      }
    }

    for (let i: number = 0; i < factions.length; i++) {
      const candidate: FactionCampaignRuntime = factions[i];
      if (!candidate.isAlive || candidate.factionId === attacker || candidate.factionId === defender) {
        continue;
      }
      if (!this.areAllied(diplomacy, attacker, candidate.factionId)) {
        continue;
      }
      if (this.getStatus(diplomacy, defender, candidate.factionId) !== DiplomaticStatus.WAR) {
        continue;
      }
      const warKey: string = DiplomacyEngine.makePairKey(defender, candidate.factionId);
      const aggressor: FactionId | undefined = this.warAggressorMap.get(warKey);
      if (aggressor === defender) {
        return candidate.factionId;
      }
    }

    return null;
  }

  private computeWarExhaustion(
    proposer: FactionId,
    target: FactionId,
    targetRuntime: FactionCampaignRuntime | undefined,
    nodes: readonly CampaignNodeRuntime[]
  ): number {
    const pairKey: string = DiplomacyEngine.makePairKey(proposer, target);
    const warTurnsRaw: number | undefined = this.warDurationMap.get(pairKey);
    const warTurns: number = warTurnsRaw !== undefined ? warTurnsRaw : 1;

    let score: number = Math.min(22, warTurns * 3.5);
    const targetCities: number = this.countOwnedNodes(nodes, target);
    if (targetCities < 5) {
      score += (5 - targetCities) * 5.0;
    }

    if (targetRuntime !== undefined) {
      if (targetRuntime.grain < 350) {
        score += ((350 - targetRuntime.grain) / 350.0) * 10.0;
      }
      if (targetRuntime.gold < 180) {
        score += 4.0;
      }
      if (targetRuntime.commanderInjuredTurns > 0) {
        score += 6.0;
      }
    }

    const staticCfg: FactionStaticConfig | undefined = getFactionConfigById(target);
    if (staticCfg !== undefined) {
      if (staticCfg.aiPersonality === AiPersonality.IRON_SHOCK_ELITE) {
        score -= 6.0;
      } else if (staticCfg.aiPersonality === AiPersonality.ZEALOT_SWARM) {
        score -= 5.0;
      } else if (staticCfg.aiPersonality === AiPersonality.MERCHANT_PRAGMATIC) {
        score += 5.0;
      } else if (staticCfg.aiPersonality === AiPersonality.NOMAD_OPPORTUNIST) {
        score += 4.0;
      }
    }

    return DiplomacyEngine.roundTo2(DiplomacyEngine.clamp(score, 0, 45));
  }

  private computeBattlefieldAdvantage(
    target: FactionId,
    proposer: FactionId,
    targetRuntime: FactionCampaignRuntime | undefined,
    proposerRuntime: FactionCampaignRuntime | undefined,
    nodes: readonly CampaignNodeRuntime[]
  ): number {
    const targetPower: number = this.estimateStrategicPower(target, targetRuntime, nodes);
    const proposerPower: number = this.estimateStrategicPower(proposer, proposerRuntime, nodes);
    const sumPower: number = Math.max(1.0, targetPower + proposerPower);
    const rawAdv: number = ((targetPower - proposerPower) / sumPower) * 72.0;
    return DiplomacyEngine.roundTo2(DiplomacyEngine.clamp(rawAdv, -40, 40));
  }

  private estimateStrategicPower(
    factionId: FactionId,
    runtime: FactionCampaignRuntime | undefined,
    nodes: readonly CampaignNodeRuntime[]
  ): number {
    let power: number = 0;
    for (let i: number = 0; i < nodes.length; i++) {
      const n: CampaignNodeRuntime = nodes[i];
      if (n.owner === factionId) {
        power += 110 + n.garrisonStrength * 0.6;
        if (n.supplyGrade === SupplyLineGrade.SEVERED) {
          power -= 25;
        }
      }
    }
    if (runtime !== undefined) {
      for (let j: number = 0; j < runtime.fieldArmyRoster.length; j++) {
        const entry: RosterEntry = runtime.fieldArmyRoster[j];
        const uCfg: UnitStaticStats | undefined = getUnitConfigById(entry.unitType);
        const unitWeight: number = uCfg !== undefined ? uCfg.popCap * 4.5 + uCfg.cost.gold * 0.04 : 5.0;
        power += entry.count * unitWeight;
      }
      power += Math.min(250, runtime.gold * 0.12 + runtime.grain * 0.06);
      if (runtime.commanderInjuredTurns > 0) {
        power *= 0.88;
      }
    }
    return Math.max(10, power);
  }

  private computeThirdPartyThreat(
    target: FactionId,
    proposer: FactionId,
    diplomacy: readonly BilateralDiplomacyState[],
    factions: readonly FactionCampaignRuntime[],
    nodes: readonly CampaignNodeRuntime[]
  ): number {
    let threat: number = 0;
    for (let i: number = 0; i < factions.length; i++) {
      const other: FactionCampaignRuntime = factions[i];
      if (!other.isAlive || other.factionId === target || other.factionId === proposer) {
        continue;
      }
      const rel: BilateralDiplomacyState | undefined = this.getBilateralState(
        diplomacy,
        target,
        other.factionId
      );
      if (rel === undefined) {
        continue;
      }
      const otherCities: number = this.countOwnedNodes(nodes, other.factionId);
      if (rel.status === DiplomaticStatus.WAR) {
        threat += 12.0 + Math.min(10.0, otherCities * 1.4);
      } else if (
        rel.status === DiplomaticStatus.NEUTRAL &&
        rel.relation <= -25 &&
        this.doFactionsShareBorder(target, other.factionId, nodes)
      ) {
        threat += 6.0;
      }
    }
    return DiplomacyEngine.roundTo2(DiplomacyEngine.clamp(threat, 0, 30));
  }

  /**
   * 构造反报价单（严格兑现硬指标：金币/纳粮/割城严禁为负数，且严禁超出求方实际持有资产上限！）
   */
  private buildSafeCounterOffer(
    originalTerms: PeaceOfferTerms,
    breakdown: PeaceScoreBreakdown,
    factions: readonly FactionCampaignRuntime[],
    nodes: readonly CampaignNodeRuntime[]
  ): PeaceOfferTerms {
    const proposerRuntime: FactionCampaignRuntime | undefined = this.findFactionRuntime(
      factions,
      originalTerms.proposer
    );
    const validTurns: number = DiplomacyEngine.normalizeTruceTurns(originalTerms.truceTurns);

    const maxGoldHeld: number =
      proposerRuntime !== undefined ? Math.max(0, Math.floor(proposerRuntime.gold)) : 0;
    const maxTotalGrainHeld: number =
      proposerRuntime !== undefined ? Math.max(0, Math.floor(proposerRuntime.grain)) : 0;
    const maxGrainPerTurn: number = Math.max(0, Math.floor(maxTotalGrainHeld / validTurns));

    // 求方达成 AcceptScore >= 0 所需的总正向筹码分
    const baseWithoutOffer: number =
      breakdown.warExhaustion -
      breakdown.battlefieldAdvantage +
      breakdown.thirdPartyThreat -
      breakdown.lowCredibilityPenalty;
    const totalNeeded: number = Math.max(1.0, -baseWithoutOffer + 0.5);
    let remainingValueNeeded: number = totalNeeded;

    // 1. 优先在求方实际持有金币上限内索取赔款金币
    let counterGold: number = Math.min(maxGoldHeld, Math.max(0, Math.ceil(remainingValueNeeded * 25.0)));
    remainingValueNeeded = Math.max(0, remainingValueNeeded - counterGold / 25.0);

    // 2. 若金币不足抵偿差额，在求方实际持有余粮可负担的分期上限内索取每回合纳粮
    let counterGrainPerTurn: number = 0;
    if (remainingValueNeeded > 0 && maxGrainPerTurn > 0) {
      const desiredGrainPerTurn: number = Math.max(
        0,
        Math.ceil((remainingValueNeeded * 18.0) / validTurns)
      );
      counterGrainPerTurn = Math.min(maxGrainPerTurn, desiredGrainPerTurn);
      remainingValueNeeded = Math.max(
        0,
        remainingValueNeeded - (counterGrainPerTurn * validTurns) / 18.0
      );
    }

    // 3. 若金粮仍不足抵偿差额，改索求方实际控制的非王都边境城池（严格保证求方至少保留 1 座城池）
    const counterCededIds: string[] = [];
    let cededTotalValue: number = 0;
    if (remainingValueNeeded > 0) {
      const cedingCandidates: string[] = this.collectCedeableProposerNodes(
        originalTerms.proposer,
        originalTerms.target,
        nodes
      );
      for (let i: number = 0; i < cedingCandidates.length && remainingValueNeeded > 0; i++) {
        const candidateId: string = cedingCandidates[i];
        const cVal: number = this.computeCityDiplomaticValue(candidateId);
        counterCededIds.push(candidateId);
        cededTotalValue += cVal;
        remainingValueNeeded = Math.max(0, remainingValueNeeded - cVal);
      }

      // 若割让城池估值已抵消大部分筹码差额，回调冗余金粮要求使反报价精准合理且绝不超支
      if (cededTotalValue > 0) {
        const residualAfterCities: number = Math.max(0, totalNeeded - cededTotalValue);
        counterGold = Math.min(maxGoldHeld, Math.max(0, Math.ceil(residualAfterCities * 25.0)));
        const residualAfterGold: number = Math.max(0, residualAfterCities - counterGold / 25.0);
        if (residualAfterGold > 0 && maxGrainPerTurn > 0) {
          counterGrainPerTurn = Math.min(
            maxGrainPerTurn,
            Math.max(0, Math.ceil((residualAfterGold * 18.0) / validTurns))
          );
        } else {
          counterGrainPerTurn = 0;
        }
      }
    }

    const safeCounter: PeaceOfferTerms = {
      proposer: originalTerms.proposer,
      target: originalTerms.target,
      goldIndemnity: Math.max(0, counterGold),
      grainTributePerTurn: Math.max(0, counterGrainPerTurn),
      cededNodeIds: counterCededIds,
      truceTurns: validTurns
    };
    return safeCounter;
  }

  /**
   * 筛选求方名下可合法割让的城池列表（排除王都，且最多只取 totalOwned - 1 座，优先挑选与目标国接壤的边境城）
   */
  private collectCedeableProposerNodes(
    proposer: FactionId,
    target: FactionId,
    nodes: readonly CampaignNodeRuntime[]
  ): string[] {
    const proposerOwned: CampaignNodeRuntime[] = [];
    const targetNodeSet: Set<string> = new Set<string>();
    for (let i: number = 0; i < nodes.length; i++) {
      if (nodes[i].owner === proposer) {
        proposerOwned.push(nodes[i]);
      } else if (nodes[i].owner === target) {
        targetNodeSet.add(nodes[i].nodeId);
      }
    }
    if (proposerOwned.length <= 1) {
      return [];
    }

    const factionCfg: FactionStaticConfig | undefined = getFactionConfigById(proposer);
    const capitalId: string = factionCfg !== undefined ? factionCfg.capitalNodeId : '';

    const borderNonCapitals: string[] = [];
    const interiorNonCapitals: string[] = [];

    for (let i: number = 0; i < proposerOwned.length; i++) {
      const nId: string = proposerOwned[i].nodeId;
      const sCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(nId);
      if (nId === capitalId || (sCfg !== undefined && sCfg.nodeType === CampaignNodeType.CAPITAL_CITADEL)) {
        continue;
      }

      let bordersTarget: boolean = false;
      if (sCfg !== undefined) {
        for (let k: number = 0; k < sCfg.neighbors.length; k++) {
          if (targetNodeSet.has(sCfg.neighbors[k])) {
            bordersTarget = true;
            break;
          }
        }
      }
      if (bordersTarget) {
        borderNonCapitals.push(nId);
      } else {
        interiorNonCapitals.push(nId);
      }
    }

    const combined: string[] = [];
    const maxCedeCount: number = Math.max(0, proposerOwned.length - 1);
    for (let i: number = 0; i < borderNonCapitals.length && combined.length < maxCedeCount; i++) {
      combined.push(borderNonCapitals[i]);
    }
    for (let i: number = 0; i < interiorNonCapitals.length && combined.length < maxCedeCount; i++) {
      combined.push(interiorNonCapitals[i]);
    }
    return combined;
  }

  private removeGrainTributeBetween(factionA: FactionId, factionB: FactionId): void {
    for (let i: number = this.grainTributeContracts.length - 1; i >= 0; i--) {
      const c: ActiveGrainTributeContract = this.grainTributeContracts[i];
      const match: boolean =
        (c.payer === factionA && c.receiver === factionB) ||
        (c.payer === factionB && c.receiver === factionA);
      if (match) {
        this.grainTributeContracts.splice(i, 1);
      }
    }
  }

  private evacuateArmyFromForeignTerritory(
    faction: FactionCampaignRuntime,
    nodes: readonly CampaignNodeRuntime[],
    diplomacy: readonly BilateralDiplomacyState[]
  ): void {
    const locNode: CampaignNodeRuntime | undefined = this.findNodeRuntime(
      nodes,
      faction.armyLocationNodeId
    );
    if (locNode !== undefined) {
      if (
        locNode.owner === faction.factionId ||
        this.areAllied(diplomacy, faction.factionId, locNode.owner)
      ) {
        return;
      }
    }
    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(faction.factionId);
    if (fCfg !== undefined) {
      const capNode: CampaignNodeRuntime | undefined = this.findNodeRuntime(
        nodes,
        fCfg.capitalNodeId
      );
      if (capNode !== undefined && capNode.owner === faction.factionId) {
        faction.armyLocationNodeId = capNode.nodeId;
        return;
      }
    }
    for (let i: number = 0; i < nodes.length; i++) {
      if (nodes[i].owner === faction.factionId) {
        faction.armyLocationNodeId = nodes[i].nodeId;
        return;
      }
    }
  }

  private findFactionRuntime(
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

  private findNodeRuntime(
    nodes: readonly CampaignNodeRuntime[],
    nodeId: string
  ): CampaignNodeRuntime | undefined {
    for (let i: number = 0; i < nodes.length; i++) {
      if (nodes[i].nodeId === nodeId) {
        return nodes[i];
      }
    }
    return undefined;
  }

  private countOwnedNodes(nodes: readonly CampaignNodeRuntime[], factionId: FactionId): number {
    let count: number = 0;
    for (let i: number = 0; i < nodes.length; i++) {
      if (nodes[i].owner === factionId) {
        count++;
      }
    }
    return count;
  }

  private static normalizeTruceTurns(turns: number): number {
    if (!Number.isFinite(turns) || turns <= 0) {
      return 5;
    }
    return Math.max(1, Math.min(20, Math.floor(turns)));
  }

  private static makePairKey(a: FactionId, b: FactionId): string {
    return a < b ? `${a}|${b}` : `${b}|${a}`;
  }

  private static failAction(msg: string): DiplomaticActionResult {
    const res: DiplomaticActionResult = {
      success: false,
      relationDelta: 0,
      credibilityDelta: 0,
      message: msg
    };
    return res;
  }

  private static clamp(val: number, minVal: number, maxVal: number): number {
    if (val < minVal) {
      return minVal;
    }
    if (val > maxVal) {
      return maxVal;
    }
    return val;
  }

  private static roundTo2(val: number): number {
    return Math.round(val * 100) / 100;
  }
}
