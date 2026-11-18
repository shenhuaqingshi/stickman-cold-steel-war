/**
 * 战役战略大地图 BFS 粮道补给线与围点打援拓扑引擎（SupplyLineEngine.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖）
 *
 * 核心职责：
 * 1. 基于 40 节点无向连通图，仅允许穿过【本方控制节点】或【正式军事同盟国（ALLIANCE）节点】，
 *    向本方任一 `isSupplyDepot === true` 仓城执行最短跳数 BFS，输出含完整高亮路径 `pathNodeIds` 的评估结果；
 * 2. 兑现四档补给倍率与苍狼汗国远征惩罚减免 35% 法则（DESIGN.md 6 & 7.3）；
 * 3. 计算围城断粮第 1 回合应急干粮预警、第 2 回合起每回合 8% 逃亡减员与初始士气 65 封顶（DESIGN.md 10.1）；
 * 4. 识别围点打援咽喉设伏节点（DESIGN.md 4.4）。
 */
import { GameConstants } from '../../common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../../config/CampaignMapConfig';
import { CampaignNodeConfig } from '../../model/GameTypes';
import {
  BilateralDiplomacyState,
  CampaignNodeRuntime,
  DiplomaticStatus,
  FactionId,
  SupplyEvaluationResult,
  SupplyLineGrade,
  TerrainType
} from '../CoreContracts';

/** 断粮孤立回合影响计算结果 */
export interface SeveredIsolationImpact {
  readonly isolatedTurns: number;
  readonly isEmergencyWarningOnly: boolean;
  readonly desertionAttritionRate: number;
  readonly marchSpeedMultiplier: number;
  readonly battleMoraleCap: number;
}

/** 大地图拓扑完整性核验摘要 */
export interface MapTopologyAudit {
  readonly nodeCount: number;
  readonly undirectedRoadCount: number;
  readonly isSymmetric: boolean;
  readonly isFullyConnected: boolean;
}

/**
 * 战役补给线与战略交通拓扑计算引擎
 */
export class SupplyLineEngine {
  /** 苍狼汗国远征补给跳数惩罚减免比例（DESIGN.md 第 6 节：远征补给惩罚 -35%） */
  public static readonly CANGLANG_EXPEDITION_RELIEF_RATIO: number = 0.35;

  /** d === 3（长途远征）基础维持耗粮附加比例 +25% */
  public static readonly EXTENDED_UPKEEP_PENALTY: number = 0.25;
  /** d === 3（长途远征）基础开战携粮削减比例 -15% */
  public static readonly EXTENDED_INIT_GRAIN_PENALTY: number = 0.15;

  /** d >= 4（孤军悬远）基础维持耗粮附加比例 +50% */
  public static readonly OVEREXTENDED_UPKEEP_PENALTY: number = 0.50;
  /** d >= 4（孤军悬远）基础开战携粮削减比例 -25% */
  public static readonly OVEREXTENDED_INIT_GRAIN_PENALTY: number = 0.25;

  /** d === Infinity（粮道断绝）应急状态下耗粮倍率与携粮折算 */
  public static readonly SEVERED_UPKEEP_MULTIPLIER: number = 1.75;
  public static readonly SEVERED_INIT_GRAIN_MULTIPLIER: number = 0.55;

  /** 断粮第 2 回合起每回合非战斗逃亡减员率 8% */
  public static readonly SEVERED_ATTRITION_RATE_TURN2: number = 0.08;
  /** 断粮第 2 回合起大地图行军力倍率（-25%） */
  public static readonly SEVERED_MARCH_MULTIPLIER_TURN2: number = 0.75;
  /** 断粮第 2 回合起进入战斗初始士气上限封顶值 */
  public static readonly SEVERED_BATTLE_MORALE_CAP: number = 65;

  private readonly staticNodeMap: Map<string, CampaignNodeConfig>;
  private readonly staticNodeList: readonly CampaignNodeConfig[];

  public constructor(staticNodes: readonly CampaignNodeConfig[] = CAMPAIGN_MAP_NODES) {
    this.staticNodeList = staticNodes;
    this.staticNodeMap = new Map<string, CampaignNodeConfig>();
    for (let i: number = 0; i < staticNodes.length; i++) {
      const cfg: CampaignNodeConfig = staticNodes[i];
      this.staticNodeMap.set(cfg.id, cfg);
    }
  }

  /**
   * 获取静态城关节点配置
   */
  public getStaticNodeConfig(nodeId: string): CampaignNodeConfig | undefined {
    return this.staticNodeMap.get(nodeId);
  }

  /**
   * 判断两个势力是否处于可借道补给的正式军事同盟关系（仅 ALLIANCE 开放粮道借道权）
   */
  public areFactionsAlliedForSupply(
    factionA: FactionId,
    factionB: FactionId,
    diplomacy: readonly BilateralDiplomacyState[]
  ): boolean {
    if (factionA === factionB) {
      return true;
    }
    for (let i: number = 0; i < diplomacy.length; i++) {
      const rel: BilateralDiplomacyState = diplomacy[i];
      const matchPair: boolean =
        (rel.factionA === factionA && rel.factionB === factionB) ||
        (rel.factionA === factionB && rel.factionB === factionA);
      if (matchPair) {
        return rel.status === DiplomaticStatus.ALLIANCE;
      }
    }
    return false;
  }

  /**
   * 判断指定节点是否允许指定势力的粮道车队通行（本方控制节点 或 正式军事同盟国控制节点）
   */
  public isNodePassableForSupply(
    nodeRuntime: CampaignNodeRuntime,
    factionId: FactionId,
    diplomacy: readonly BilateralDiplomacyState[]
  ): boolean {
    if (nodeRuntime.owner === factionId) {
      return true;
    }
    return this.areFactionsAlliedForSupply(factionId, nodeRuntime.owner, diplomacy);
  }

  /**
   * 判断指定节点是否可作为本方补给根源仓城（必须由本方实际控制且静态属性 isSupplyDepot === true）
   */
  public isOwnSupplyDepot(nodeRuntime: CampaignNodeRuntime, factionId: FactionId): boolean {
    if (nodeRuntime.owner !== factionId) {
      return false;
    }
    const cfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(nodeRuntime.nodeId);
    if (cfg === undefined) {
      return false;
    }
    return cfg.isSupplyDepot;
  }

  /**
   * 根据 BFS 最短连通跳数与势力特性（苍狼汗国减免 35% 远征惩罚）计算补给等级与粮草修正倍率
   */
  public computeMultipliersByHops(
    nodeId: string,
    hops: number,
    nearestDepotNodeId: string,
    pathNodeIds: readonly string[],
    factionId: FactionId
  ): SupplyEvaluationResult {
    if (!Number.isFinite(hops) || hops < 0) {
      const severedResult: SupplyEvaluationResult = {
        nodeId: nodeId,
        grade: SupplyLineGrade.SEVERED,
        hops: Number.POSITIVE_INFINITY,
        nearestDepotNodeId: '',
        pathNodeIds: [],
        upkeepMultiplier: SupplyLineEngine.SEVERED_UPKEEP_MULTIPLIER,
        initialGrainMultiplier: SupplyLineEngine.SEVERED_INIT_GRAIN_MULTIPLIER
      };
      return severedResult;
    }

    const penaltyScale: number =
      factionId === FactionId.CANGLANG
        ? 1.0 - SupplyLineEngine.CANGLANG_EXPEDITION_RELIEF_RATIO
        : 1.0;

    if (hops <= GameConstants.SUPPLY_FULL_HOPS) {
      const fullResult: SupplyEvaluationResult = {
        nodeId: nodeId,
        grade: SupplyLineGrade.FULL_SUPPLY,
        hops: hops,
        nearestDepotNodeId: nearestDepotNodeId,
        pathNodeIds: pathNodeIds,
        upkeepMultiplier: 1.0,
        initialGrainMultiplier: 1.0
      };
      return fullResult;
    }

    if (hops === 3) {
      const upkeepMult: number =
        SupplyLineEngine.roundTo4(1.0 + SupplyLineEngine.EXTENDED_UPKEEP_PENALTY * penaltyScale);
      const initGrainMult: number =
        SupplyLineEngine.roundTo4(1.0 - SupplyLineEngine.EXTENDED_INIT_GRAIN_PENALTY * penaltyScale);
      const extendedResult: SupplyEvaluationResult = {
        nodeId: nodeId,
        grade: SupplyLineGrade.EXTENDED_MARCH,
        hops: hops,
        nearestDepotNodeId: nearestDepotNodeId,
        pathNodeIds: pathNodeIds,
        upkeepMultiplier: upkeepMult,
        initialGrainMultiplier: initGrainMult
      };
      return extendedResult;
    }

    // hops >= 4：孤军悬远
    const overUpkeepMult: number =
      SupplyLineEngine.roundTo4(1.0 + SupplyLineEngine.OVEREXTENDED_UPKEEP_PENALTY * penaltyScale);
    const overInitGrainMult: number =
      SupplyLineEngine.roundTo4(1.0 - SupplyLineEngine.OVEREXTENDED_INIT_GRAIN_PENALTY * penaltyScale);
    const overextendedResult: SupplyEvaluationResult = {
      nodeId: nodeId,
      grade: SupplyLineGrade.OVEREXTENDED,
      hops: hops,
      nearestDepotNodeId: nearestDepotNodeId,
      pathNodeIds: pathNodeIds,
      upkeepMultiplier: overUpkeepMult,
      initialGrainMultiplier: overInitGrainMult
    };
    return overextendedResult;
  }

  /**
   * 评估指定节点对指定势力的最短合法补给线（BFS）
   * @param nodeId 待评估节点 ID
   * @param factionId 评估归属势力
   * @param nodes 全图动态节点列表
   * @param diplomacy 双边外交状态表
   * @param allowContestedOrigin 若为 true（如大军进逼敌方城下交战前），允许起点本身尚未占领，从相邻本方/盟友控制节点接续粮道
   */
  public evaluateNodeSupply(
    nodeId: string,
    factionId: FactionId,
    nodes: readonly CampaignNodeRuntime[],
    diplomacy: readonly BilateralDiplomacyState[],
    allowContestedOrigin: boolean = false
  ): SupplyEvaluationResult {
    const runtimeMap: Map<string, CampaignNodeRuntime> = this.buildRuntimeNodeMap(nodes);
    const alliedPairKeys: Set<string> = this.buildAlliedPairSet(diplomacy);
    return this.evaluateNodeSupplyFast(
      nodeId,
      factionId,
      runtimeMap,
      alliedPairKeys,
      allowContestedOrigin
    );
  }

  private evaluateNodeSupplyFast(
    nodeId: string,
    factionId: FactionId,
    runtimeMap: Map<string, CampaignNodeRuntime>,
    alliedPairKeys: Set<string>,
    allowContestedOrigin: boolean
  ): SupplyEvaluationResult {
    const startRuntime: CampaignNodeRuntime | undefined = runtimeMap.get(nodeId);
    const startStatic: CampaignNodeConfig | undefined = this.staticNodeMap.get(nodeId);

    if (startRuntime === undefined || startStatic === undefined) {
      return this.computeMultipliersByHops(nodeId, Number.POSITIVE_INFINITY, '', [], factionId);
    }

    const originPassable: boolean = this.isNodePassableFast(startRuntime, factionId, alliedPairKeys);
    if (!originPassable && !allowContestedOrigin) {
      return this.computeMultipliersByHops(nodeId, Number.POSITIVE_INFINITY, '', [], factionId);
    }

    // 起点本身即为本方仓城：0 跳直达满额补给
    if (originPassable && this.isOwnSupplyDepot(startRuntime, factionId)) {
      return this.computeMultipliersByHops(nodeId, 0, nodeId, [nodeId], factionId);
    }

    // 标准无权图最短路径 BFS（记录前驱节点以精确还原 pathNodeIds：从起点 -> 最近本方仓城）
    const visited: Set<string> = new Set<string>();
    const parentMap: Map<string, string> = new Map<string, string>();
    const distMap: Map<string, number> = new Map<string, number>();
    const queue: string[] = [nodeId];
    visited.add(nodeId);
    distMap.set(nodeId, 0);

    let head: number = 0;
    while (head < queue.length) {
      const currentId: string = queue[head];
      head++;

      const currentDist: number | undefined = distMap.get(currentId);
      const stepBase: number = currentDist !== undefined ? currentDist : 0;
      const currentStatic: CampaignNodeConfig | undefined = this.staticNodeMap.get(currentId);
      if (currentStatic === undefined) {
        continue;
      }

      const neighbors: readonly string[] = currentStatic.neighbors;
      for (let i: number = 0; i < neighbors.length; i++) {
        const nbrId: string = neighbors[i];
        if (visited.has(nbrId)) {
          continue;
        }
        const nbrRuntime: CampaignNodeRuntime | undefined = runtimeMap.get(nbrId);
        if (nbrRuntime === undefined) {
          continue;
        }
        if (!this.isNodePassableFast(nbrRuntime, factionId, alliedPairKeys)) {
          continue;
        }

        visited.add(nbrId);
        parentMap.set(nbrId, currentId);
        const nextDist: number = stepBase + 1;
        distMap.set(nbrId, nextDist);

        if (this.isOwnSupplyDepot(nbrRuntime, factionId)) {
          const pathIds: string[] = this.reconstructSupplyPath(nodeId, nbrId, parentMap);
          return this.computeMultipliersByHops(nodeId, nextDist, nbrId, pathIds, factionId);
        }

        queue.push(nbrId);
      }
    }

    return this.computeMultipliersByHops(nodeId, Number.POSITIVE_INFINITY, '', [], factionId);
  }

  /**
   * 评估主力军团由 `fromNodeId` 行军进攻 `targetNodeId` 时的前线补给线
   * 保证通过实际进军出发点或相邻己方/盟友控制区测算开战携行粮草
   */
  public evaluateMarchSupply(
    fromNodeId: string,
    targetNodeId: string,
    factionId: FactionId,
    nodes: readonly CampaignNodeRuntime[],
    diplomacy: readonly BilateralDiplomacyState[]
  ): SupplyEvaluationResult {
    const targetDirect: SupplyEvaluationResult = this.evaluateNodeSupply(
      targetNodeId,
      factionId,
      nodes,
      diplomacy,
      true
    );
    if (targetDirect.grade !== SupplyLineGrade.SEVERED) {
      return targetDirect;
    }

    // 兜底：核验出发节点自身补给跳数 + 1
    const fromSupply: SupplyEvaluationResult = this.evaluateNodeSupply(
      fromNodeId,
      factionId,
      nodes,
      diplomacy,
      false
    );
    if (fromSupply.grade === SupplyLineGrade.SEVERED) {
      return this.computeMultipliersByHops(targetNodeId, Number.POSITIVE_INFINITY, '', [], factionId);
    }
    const combinedPath: string[] = [targetNodeId];
    for (let i: number = 0; i < fromSupply.pathNodeIds.length; i++) {
      combinedPath.push(fromSupply.pathNodeIds[i]);
    }
    return this.computeMultipliersByHops(
      targetNodeId,
      fromSupply.hops + 1,
      fromSupply.nearestDepotNodeId,
      combinedPath,
      factionId
    );
  }

  /**
   * 批量刷新全图所有节点各自所属势力的补给等级与跳数（单次预建 O(1) 节点索引与同盟哈希表，避免 40 次重复分配）
   */
  public refreshAllNodesSupply(
    nodes: CampaignNodeRuntime[],
    diplomacy: readonly BilateralDiplomacyState[]
  ): Map<string, SupplyEvaluationResult> {
    const runtimeMap: Map<string, CampaignNodeRuntime> = this.buildRuntimeNodeMap(nodes);
    const alliedPairKeys: Set<string> = this.buildAlliedPairSet(diplomacy);
    const resultMap: Map<string, SupplyEvaluationResult> = new Map<string, SupplyEvaluationResult>();

    for (let i: number = 0; i < nodes.length; i++) {
      const node: CampaignNodeRuntime = nodes[i];
      const evalRes: SupplyEvaluationResult = this.evaluateNodeSupplyFast(
        node.nodeId,
        node.owner,
        runtimeMap,
        alliedPairKeys,
        false
      );
      node.supplyGrade = evalRes.grade;
      node.supplyHops = evalRes.hops;
      resultMap.set(node.nodeId, evalRes);
    }
    return resultMap;
  }

  /**
   * 计算围城/断粮孤立状态在当前孤立回合数下的战略惩罚（对齐 DESIGN.md 10.1）
   * - isolatedTurns <= 0：正常补给，无惩罚
   * - isolatedTurns === 1：第 1 回合消耗随军应急干粮，仅触发红色预警，0% 减员
   * - isolatedTurns >= 2：第 2 回合起进入【饥疲】，每回合非战斗逃亡减员 8%、行军力 -25%、开战初始士气封顶 65
   */
  public evaluateSeveredIsolationImpact(isolatedTurns: number): SeveredIsolationImpact {
    if (isolatedTurns <= 0) {
      const normalImpact: SeveredIsolationImpact = {
        isolatedTurns: 0,
        isEmergencyWarningOnly: false,
        desertionAttritionRate: 0.0,
        marchSpeedMultiplier: 1.0,
        battleMoraleCap: GameConstants.MORALE_MAX
      };
      return normalImpact;
    }
    if (isolatedTurns === 1) {
      const turn1Warning: SeveredIsolationImpact = {
        isolatedTurns: 1,
        isEmergencyWarningOnly: true,
        desertionAttritionRate: 0.0,
        marchSpeedMultiplier: 1.0,
        battleMoraleCap: GameConstants.MORALE_MAX
      };
      return turn1Warning;
    }
    const starvingImpact: SeveredIsolationImpact = {
      isolatedTurns: isolatedTurns,
      isEmergencyWarningOnly: false,
      desertionAttritionRate: SupplyLineEngine.SEVERED_ATTRITION_RATE_TURN2,
      marchSpeedMultiplier: SupplyLineEngine.SEVERED_MARCH_MULTIPLIER_TURN2,
      battleMoraleCap: SupplyLineEngine.SEVERED_BATTLE_MORALE_CAP
    };
    return starvingImpact;
  }

  /**
   * 检索围绕目标敌城可布设【围点打援】伏击圈的咽喉节点列表
   * 条件：与目标敌城相邻，且由本方/同盟控制（或具备密林/高地/关隘险要地形）
   */
  public findReliefAmbushCandidateNodes(
    besiegedEnemyNodeId: string,
    attackerFaction: FactionId,
    nodes: readonly CampaignNodeRuntime[],
    diplomacy: readonly BilateralDiplomacyState[]
  ): string[] {
    const besiegedCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(besiegedEnemyNodeId);
    if (besiegedCfg === undefined) {
      return [];
    }
    const runtimeMap: Map<string, CampaignNodeRuntime> = this.buildRuntimeNodeMap(nodes);
    const besiegedRuntime: CampaignNodeRuntime | undefined = runtimeMap.get(besiegedEnemyNodeId);
    if (besiegedRuntime === undefined || besiegedRuntime.owner === attackerFaction) {
      return [];
    }

    const candidates: string[] = [];
    for (let i: number = 0; i < besiegedCfg.neighbors.length; i++) {
      const nbrId: string = besiegedCfg.neighbors[i];
      const nbrRuntime: CampaignNodeRuntime | undefined = runtimeMap.get(nbrId);
      const nbrCfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(nbrId);
      if (nbrRuntime === undefined || nbrCfg === undefined) {
        continue;
      }
      if (this.isNodePassableForSupply(nbrRuntime, attackerFaction, diplomacy)) {
        // 优先排入密林、山坡高地、桥梁窄关等天然设伏节点
        const isIdealAmbushTerrain: boolean =
          nbrCfg.terrain === TerrainType.DENSE_FOREST ||
          nbrCfg.terrain === TerrainType.HIGH_GROUND ||
          nbrCfg.terrain === TerrainType.BRIDGE_PASS;
        if (isIdealAmbushTerrain) {
          candidates.unshift(nbrId);
        } else {
          candidates.push(nbrId);
        }
      }
    }
    return candidates;
  }

  /**
   * 核验战略大地图静态无向图拓扑完整性（节点总数、双向边对称性、单连通分量）
   */
  public auditMapTopology(): MapTopologyAudit {
    const count: number = this.staticNodeList.length;
    if (count === 0) {
      const emptyAudit: MapTopologyAudit = {
        nodeCount: 0,
        undirectedRoadCount: 0,
        isSymmetric: true,
        isFullyConnected: false
      };
      return emptyAudit;
    }

    let directedEdgeCount: number = 0;
    let symmetric: boolean = true;

    for (let i: number = 0; i < count; i++) {
      const nodeA: CampaignNodeConfig = this.staticNodeList[i];
      directedEdgeCount += nodeA.neighbors.length;
      for (let j: number = 0; j < nodeA.neighbors.length; j++) {
        const nbrId: string = nodeA.neighbors[j];
        const nodeB: CampaignNodeConfig | undefined = this.staticNodeMap.get(nbrId);
        if (nodeB === undefined || nodeB.neighbors.indexOf(nodeA.id) < 0) {
          symmetric = false;
        }
      }
    }

    const visited: Set<string> = new Set<string>();
    const queue: string[] = [this.staticNodeList[0].id];
    visited.add(this.staticNodeList[0].id);
    let head: number = 0;
    while (head < queue.length) {
      const currId: string = queue[head];
      head++;
      const cfg: CampaignNodeConfig | undefined = this.staticNodeMap.get(currId);
      if (cfg === undefined) {
        continue;
      }
      for (let k: number = 0; k < cfg.neighbors.length; k++) {
        const nextId: string = cfg.neighbors[k];
        if (!visited.has(nextId) && this.staticNodeMap.has(nextId)) {
          visited.add(nextId);
          queue.push(nextId);
        }
      }
    }

    const audit: MapTopologyAudit = {
      nodeCount: count,
      undirectedRoadCount: Math.floor(directedEdgeCount / 2),
      isSymmetric: symmetric,
      isFullyConnected: visited.size === count
    };
    return audit;
  }

  private buildRuntimeNodeMap(nodes: readonly CampaignNodeRuntime[]): Map<string, CampaignNodeRuntime> {
    const map: Map<string, CampaignNodeRuntime> = new Map<string, CampaignNodeRuntime>();
    for (let i: number = 0; i < nodes.length; i++) {
      map.set(nodes[i].nodeId, nodes[i]);
    }
    return map;
  }

  private buildAlliedPairSet(diplomacy: readonly BilateralDiplomacyState[]): Set<string> {
    const set: Set<string> = new Set<string>();
    for (let i: number = 0; i < diplomacy.length; i++) {
      const rel: BilateralDiplomacyState = diplomacy[i];
      if (rel.status === DiplomaticStatus.ALLIANCE) {
        const key: string =
          rel.factionA < rel.factionB
            ? `${rel.factionA}|${rel.factionB}`
            : `${rel.factionB}|${rel.factionA}`;
        set.add(key);
      }
    }
    return set;
  }

  private isNodePassableFast(
    nodeRuntime: CampaignNodeRuntime,
    factionId: FactionId,
    alliedPairKeys: Set<string>
  ): boolean {
    if (nodeRuntime.owner === factionId) {
      return true;
    }
    const key: string =
      factionId < nodeRuntime.owner
        ? `${factionId}|${nodeRuntime.owner}`
        : `${nodeRuntime.owner}|${factionId}`;
    return alliedPairKeys.has(key);
  }

  /**
   * 还原从评估起点 `originId` 通往最近本方仓城 `depotId` 的有序节点路径（供大地图高亮绘制）
   */
  private reconstructSupplyPath(
    originId: string,
    depotId: string,
    parentMap: Map<string, string>
  ): string[] {
    const reversed: string[] = [depotId];
    let cursor: string = depotId;
    let safetyCounter: number = 0;
    const maxSteps: number = this.staticNodeList.length + 2;

    while (cursor !== originId && safetyCounter < maxSteps) {
      const prev: string | undefined = parentMap.get(cursor);
      if (prev === undefined) {
        break;
      }
      reversed.push(prev);
      cursor = prev;
      safetyCounter++;
    }

    const path: string[] = [];
    for (let i: number = reversed.length - 1; i >= 0; i--) {
      path.push(reversed[i]);
    }
    return path;
  }

  private static roundTo4(val: number): number {
    return Math.round(val * 10000) / 10000;
  }
}
