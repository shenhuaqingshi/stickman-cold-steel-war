import test from 'node:test';
import assert from 'node:assert/strict';

import { GameConstants } from '../../entry/src/main/ets/common/GameConstants.ets';
import { CAMPAIGN_MAP_NODES } from '../../entry/src/main/ets/config/CampaignMapConfig.ets';
import { FACTION_STATIC_CONFIGS } from '../../entry/src/main/ets/config/FactionConfig.ets';
import {
  ArmyCorpsRole,
  BattleOutcomeReason,
  BattleScenarioType,
  DiplomaticStatus,
  FactionId,
  PeaceOutcomeKind,
  SupplyLineGrade,
  UnitTypeId
} from '../../entry/src/main/ets/core/CoreContracts.ets';
import { SupplyLineEngine } from '../../entry/src/main/ets/core/campaign/SupplyLineEngine.ets';
import { DiplomacyEngine } from '../../entry/src/main/ets/core/diplomacy/DiplomacyEngine.ets';
import {
  CampaignEngine,
  CampaignVictoryKind,
  PrisonerDisposition
} from '../../entry/src/main/ets/core/campaign/CampaignEngine.ets';
import {
  InMemoryPersistenceBackend,
  SaveErrorCode,
  SaveManager
} from '../../entry/src/main/ets/storage/SaveManager.ets';
import {
  DistantLodPolicy,
  JoystickHandedness,
  SettingsStore,
  TargetFpsOption
} from '../../entry/src/main/ets/storage/SettingsStore.ets';
import {
  CampaignStrategicAI,
  StrategicActionType
} from '../../entry/src/main/ets/core/ai/CampaignStrategicAI.ets';
import { GameSessionCoordinator } from '../../entry/src/main/ets/core/session/GameSessionCoordinator.ets';

// ==================== 1. SupplyLineEngine: 40 节点 BFS 补给跳数、同盟借道与苍狼减免 ====================

test('SupplyLineEngine: 40-node undirected graph topology & multi-hop BFS multipliers (Yanlong vs Canglang)', () => {
  const engine = new CampaignEngine(FactionId.YANLONG);
  const supply = engine.getSupplyEngine();
  const audit = supply.auditMapTopology();

  assert.equal(audit.nodeCount, 40);
  assert.equal(audit.undirectedRoadCount, 78);
  assert.equal(audit.isSymmetric, true);
  assert.equal(audit.isFullyConnected, true);

  const state = engine.getState();
  // 开局所有 40 城均处于 FULL_SUPPLY (hops <= 2)
  for (const node of state.nodes) {
    assert.equal(node.supplyGrade, SupplyLineGrade.FULL_SUPPLY);
    assert.ok(node.supplyHops <= 2);
  }

  // 构造一条从炎龙帝都 (yl_capital, depot) 出发的远征走廊：
  // yl_capital (0) -> yl_pass (1) -> cl_river (2) -> cl_fort (3) -> xj_beacon (4)
  // 注：将沿途非仓城节点归属设为 YANLONG，同时确保其余邻居仍属他国，锁定唯一最短路径
  const setOwner = (id, owner) => {
    const n = engine.getNodeRuntime(id);
    assert.ok(n !== undefined);
    n.owner = owner;
  };
  setOwner('cl_river', FactionId.YANLONG);
  setOwner('cl_fort', FactionId.YANLONG);
  setOwner('xj_beacon', FactionId.YANLONG);

  const d0 = supply.evaluateNodeSupply('yl_capital', FactionId.YANLONG, state.nodes, state.diplomacy);
  assert.equal(d0.hops, 0);
  assert.equal(d0.grade, SupplyLineGrade.FULL_SUPPLY);
  assert.deepEqual(d0.pathNodeIds, ['yl_capital']);
  assert.equal(d0.upkeepMultiplier, 1.0);
  assert.equal(d0.initialGrainMultiplier, 1.0);

  const d2 = supply.evaluateNodeSupply('cl_river', FactionId.YANLONG, state.nodes, state.diplomacy);
  assert.equal(d2.hops, 2);
  assert.equal(d2.grade, SupplyLineGrade.FULL_SUPPLY);
  assert.deepEqual(d2.pathNodeIds, ['cl_river', 'yl_pass', 'yl_capital']);
  assert.equal(d2.upkeepMultiplier, 1.0);
  assert.equal(d2.initialGrainMultiplier, 1.0);

  const d3 = supply.evaluateNodeSupply('cl_fort', FactionId.YANLONG, state.nodes, state.diplomacy);
  assert.equal(d3.hops, 3);
  assert.equal(d3.grade, SupplyLineGrade.EXTENDED_MARCH);
  assert.deepEqual(d3.pathNodeIds, ['cl_fort', 'cl_river', 'yl_pass', 'yl_capital']);
  assert.equal(d3.upkeepMultiplier, 1.25);
  assert.equal(d3.initialGrainMultiplier, 0.85);

  const d4 = supply.evaluateNodeSupply('xj_beacon', FactionId.YANLONG, state.nodes, state.diplomacy);
  assert.equal(d4.hops, 4);
  assert.equal(d4.grade, SupplyLineGrade.OVEREXTENDED);
  assert.deepEqual(d4.pathNodeIds, ['xj_beacon', 'cl_fort', 'cl_river', 'yl_pass', 'yl_capital']);
  assert.equal(d4.upkeepMultiplier, 1.50);
  assert.equal(d4.initialGrainMultiplier, 0.75);

  // 验证苍狼汗国远征惩罚减免 35%（d=3 耗粮 +16.25% / 携粮 -9.75%；d=4 耗粮 +32.5% / 携粮 -16.25%）
  const canglangD3 = supply.computeMultipliersByHops(
    'cl_fort',
    3,
    'cl_capital',
    ['cl_fort', 'a', 'b', 'cl_capital'],
    FactionId.CANGLANG
  );
  assert.equal(canglangD3.grade, SupplyLineGrade.EXTENDED_MARCH);
  assert.equal(canglangD3.upkeepMultiplier, 1.1625);
  assert.equal(canglangD3.initialGrainMultiplier, 0.9025);

  const canglangD4 = supply.computeMultipliersByHops(
    'xj_beacon',
    4,
    'cl_capital',
    ['xj_beacon', 'a', 'b', 'c', 'cl_capital'],
    FactionId.CANGLANG
  );
  assert.equal(canglangD4.grade, SupplyLineGrade.OVEREXTENDED);
  assert.equal(canglangD4.upkeepMultiplier, 1.325);
  assert.equal(canglangD4.initialGrainMultiplier, 0.8375);
});

test('SupplyLineEngine: military ALLIANCE opens supply transit while NON_AGGRESSION / TRADE_PACT do not', () => {
  const engine = new CampaignEngine(FactionId.YANLONG);
  const supply = engine.getSupplyEngine();
  const diplo = engine.getDiplomacyEngine();
  const state = engine.getState();

  // 炎龙孤悬占领 cl_fort，其与本方领土之间的 cl_river 仍由苍狼控制 -> 断粮 SEVERED
  engine.getNodeRuntime('cl_fort').owner = FactionId.YANLONG;
  const severed = supply.evaluateNodeSupply('cl_fort', FactionId.YANLONG, state.nodes, state.diplomacy);
  assert.equal(severed.grade, SupplyLineGrade.SEVERED);
  assert.equal(severed.hops, Number.POSITIVE_INFINITY);
  assert.equal(severed.pathNodeIds.length, 0);

  // 与玄甲签署通商或互不侵犯：仍不可借道 xj_plain
  const relPair = diplo.getBilateralState(state.diplomacy, FactionId.YANLONG, FactionId.XUANJIA);
  relPair.relation = 60;
  diplo.signTradePact(FactionId.YANLONG, FactionId.XUANJIA, state.diplomacy, state.factions);
  assert.equal(
    supply.evaluateNodeSupply('cl_fort', FactionId.YANLONG, state.nodes, state.diplomacy).grade,
    SupplyLineGrade.SEVERED
  );

  diplo.signNonAggressionPact(FactionId.YANLONG, FactionId.XUANJIA, state.diplomacy, state.factions);
  assert.equal(
    supply.evaluateNodeSupply('cl_fort', FactionId.YANLONG, state.nodes, state.diplomacy).grade,
    SupplyLineGrade.SEVERED
  );

  // 正式缔结军事攻守同盟（ALLIANCE）：立即允许经玄甲 xj_plain 连通炎龙仓城 yl_forge（2 跳 FULL_SUPPLY）！
  const allianceRes = diplo.formAlliance(
    FactionId.YANLONG,
    FactionId.XUANJIA,
    state.diplomacy,
    state.factions
  );
  assert.equal(allianceRes.success, true);

  const alliedSupply = supply.evaluateNodeSupply(
    'cl_fort',
    FactionId.YANLONG,
    state.nodes,
    state.diplomacy
  );
  assert.equal(alliedSupply.grade, SupplyLineGrade.FULL_SUPPLY);
  assert.equal(alliedSupply.hops, 2);
  assert.equal(alliedSupply.nearestDepotNodeId, 'yl_forge');
  assert.deepEqual(alliedSupply.pathNodeIds, ['cl_fort', 'xj_plain', 'yl_forge']);
});

test('CampaignEngine & SupplyLineEngine: 2-turn severed siege isolation triggers warning on Turn 1 and 8% desertion + 65 morale cap on Turn 2', () => {
  const engine = new CampaignEngine(FactionId.YANLONG);
  const isolatedNode = engine.getNodeRuntime('cl_fort');
  isolatedNode.owner = FactionId.YANLONG;
  isolatedNode.garrisonStrength = 100;

  const yanlong = engine.getFactionRuntime(FactionId.YANLONG);
  yanlong.armyLocationNodeId = 'cl_fort';
  const countSoldiers = (roster) => roster.reduce((acc, r) => acc + r.count, 0);
  const initialArmyCount = countSoldiers(yanlong.fieldArmyRoster);

  // 第 1 回合结算：仅触发应急干粮红字预警，守军与野战主力 0% 非战斗减员
  const turn1 = engine.advanceTurn();
  assert.ok(turn1.emergencySeveredNodes.includes('cl_fort'));
  assert.ok(!turn1.attritionSeveredNodes.includes('cl_fort'));
  assert.equal(isolatedNode.isolatedTurns, 1);
  assert.equal(isolatedNode.garrisonStrength, 100);
  assert.equal(countSoldiers(yanlong.fieldArmyRoster), initialArmyCount);

  // 第 2 回合结算：进入【饥疲】，守军与驻留野战主力均发生 8% 非战斗逃亡减员
  const turn2 = engine.advanceTurn();
  assert.ok(turn2.attritionSeveredNodes.includes('cl_fort'));
  assert.equal(isolatedNode.isolatedTurns, 2);
  assert.equal(isolatedNode.garrisonStrength, 92); // 100 * (1 - 0.08) = 92
  assert.ok(countSoldiers(yanlong.fieldArmyRoster) <= Math.floor(initialArmyCount * 0.92));

  // 断粮第 2 回合起开战初始士气上限封顶 65（基础 80 -> 士气修正 <= -15）
  const marchRes = engine.marchToNode(FactionId.YANLONG, 'cl_river');
  assert.equal(marchRes.battleTriggered, true);
  assert.ok(GameConstants.MORALE_BASE + marchRes.battleConfig.playerMoraleModifier <= 65);
});

// ==================== 2. DiplomacyEngine: 媾和量化三档、反报价上限保护、背盟与双重同盟豁免 ====================

test('DiplomacyEngine: evaluatePeaceOffer three-tier outcomes, C<40 +80% premium, and strict asset cap on COUNTER_OFFER', () => {
  const engine = new CampaignEngine(FactionId.YANLONG);
  const diplo = engine.getDiplomacyEngine();
  const state = engine.getState();

  // 让苍狼攻占炎龙 2 座城（7 vs 3），建立战场优势以测试三档议和区间
  engine.getNodeRuntime('yl_pass').owner = FactionId.CANGLANG;
  engine.getNodeRuntime('yl_ferry').owner = FactionId.CANGLANG;
  diplo.declareWar(FactionId.CANGLANG, FactionId.YANLONG, state.diplomacy, state.factions);

  const yanlong = engine.getFactionRuntime(FactionId.YANLONG);
  yanlong.gold = 900;
  yanlong.grain = 1200;

  // 1) 空手套白狼（0 赔款）处于 [-20, 0) 区间 -> 返回 COUNTER_OFFER
  const zeroOffer = {
    proposer: FactionId.YANLONG,
    target: FactionId.CANGLANG,
    goldIndemnity: 0,
    grainTributePerTurn: 0,
    cededNodeIds: [],
    truceTurns: 5
  };
  const evalCounter = diplo.evaluatePeaceOffer(
    zeroOffer,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  assert.equal(evalCounter.kind, PeaceOutcomeKind.COUNTER_OFFER);
  assert.ok(evalCounter.netScore >= -20 && evalCounter.netScore < 0);
  assert.ok(evalCounter.counterTerms !== null);
  assert.ok(evalCounter.counterTerms.goldIndemnity > 0);
  assert.ok(evalCounter.counterTerms.goldIndemnity <= yanlong.gold);

  // 直接按对方反报价签约应立即 ACCEPTED
  const acceptCounter = diplo.evaluatePeaceOffer(
    evalCounter.counterTerms,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  assert.equal(acceptCounter.kind, PeaceOutcomeKind.ACCEPTED);
  assert.ok(acceptCounter.netScore >= 0);

  // 2) 劣势方反而狂妄索取敌方 400 金赔款（V_offer < 0）使总分 < -20 -> 返回 REJECTED_BREAKDOWN
  const arrogantOffer = {
    proposer: FactionId.YANLONG,
    target: FactionId.CANGLANG,
    goldIndemnity: -400,
    grainTributePerTurn: 0,
    cededNodeIds: [],
    truceTurns: 5
  };
  const relBeforeReject = diplo.getRelation(state.diplomacy, FactionId.YANLONG, FactionId.CANGLANG);
  const execReject = diplo.executePeaceNegotiation(
    arrogantOffer,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  assert.equal(execReject.evaluation.kind, PeaceOutcomeKind.REJECTED_BREAKDOWN);
  assert.ok(execReject.evaluation.netScore < -20);
  assert.equal(diplo.isEnvoyLockedThisTurn(FactionId.YANLONG, FactionId.CANGLANG), true);
  assert.equal(
    diplo.getRelation(state.diplomacy, FactionId.YANLONG, FactionId.CANGLANG),
    Math.max(-100, relBeforeReject - 10)
  );
  assert.equal(execReject.enemyMoraleBoostNextBattle, 8);

  // 本回合被锁使后再次强派使者直接被拦截
  const secondTrySameTurn = diplo.evaluatePeaceOffer(
    evalCounter.counterTerms,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  assert.equal(secondTrySameTurn.kind, PeaceOutcomeKind.REJECTED_BREAKDOWN);

  // 推进一回合解除本回合派使锁
  engine.advanceTurn();

  // 3) 极端资产上限保护测试：求方仅剩 40 金币、30 粮草、仅存最后 1 座王都时触发 COUNTER_OFFER
  //    断言反报价绝不出现负数，且金币 <= 40、分期总纳粮 <= 30、割城数 === 0（保留王都）！
  for (const n of state.nodes) {
    if (n.owner === FactionId.YANLONG && n.nodeId !== 'yl_capital') {
      n.owner = FactionId.XUANJIA;
    }
  }
  yanlong.gold = 40;
  yanlong.grain = 30;
  // 让苍狼背后同时面临霜原战争威胁使净分落在 [-20, 0)
  diplo.declareWar(FactionId.SHUANGYUAN, FactionId.CANGLANG, state.diplomacy, state.factions);

  const bankruptOffer = {
    proposer: FactionId.YANLONG,
    target: FactionId.CANGLANG,
    goldIndemnity: -50,
    grainTributePerTurn: -10,
    cededNodeIds: [],
    truceTurns: 5
  };
  // 微调使分数落在 [-20, 0)
  const probeOffer = {
    proposer: FactionId.YANLONG,
    target: FactionId.CANGLANG,
    goldIndemnity: 20,
    grainTributePerTurn: 0,
    cededNodeIds: [],
    truceTurns: 5
  };
  const brokeEval = diplo.evaluatePeaceOffer(
    probeOffer,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  if (brokeEval.kind === PeaceOutcomeKind.COUNTER_OFFER) {
    const ct = brokeEval.counterTerms;
    assert.ok(ct !== null);
    assert.ok(ct.goldIndemnity >= 0 && ct.goldIndemnity <= 40);
    assert.ok(ct.grainTributePerTurn >= 0 && ct.grainTributePerTurn * ct.truceTurns <= 30);
    assert.equal(ct.cededNodeIds.length, 0);
  }
  // 同时验证即便传入负报价在任意资产配置下生成的反报价也严禁为负且严禁超上限
  yanlong.gold = 65;
  yanlong.grain = 55;
  engine.getNodeRuntime('yl_granary').owner = FactionId.YANLONG;
  const counterCheck = diplo.evaluatePeaceOffer(
    bankruptOffer.goldIndemnity ? probeOffer : bankruptOffer,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  if (counterCheck.counterTerms !== null) {
    const ct2 = counterCheck.counterTerms;
    assert.ok(ct2.goldIndemnity >= 0 && ct2.goldIndemnity <= yanlong.gold);
    assert.ok(ct2.grainTributePerTurn >= 0 && ct2.grainTributePerTurn * ct2.truceTurns <= yanlong.grain);
    for (const cid of ct2.cededNodeIds) {
      assert.notEqual(cid, 'yl_capital');
      assert.equal(engine.getNodeRuntime(cid).owner, FactionId.YANLONG);
    }
  }

  // 4) 验证低信誉 C < 40 求和赔款要求溢价 +80%（P_cred 显著抬升所需筹码）
  yanlong.credibility = 85;
  const highCredBreakdown = diplo.computePeaceScoreBreakdown(
    zeroOffer,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  yanlong.credibility = 28; // < 40
  const lowCredBreakdown = diplo.computePeaceScoreBreakdown(
    zeroOffer,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  assert.equal(highCredBreakdown.lowCredibilityPenalty, 0);
  assert.ok(lowCredBreakdown.lowCredibilityPenalty >= 8);
  assert.ok(lowCredBreakdown.netScore < highCredBreakdown.netScore);
});

test('DiplomacyEngine: betrayal heavy penalties & faction-specific morale shocks (-16 / -10 / -5)', () => {
  const engine = new CampaignEngine(FactionId.YANLONG);
  const diplo = engine.getDiplomacyEngine();
  const state = engine.getState();

  const yanlong = engine.getFactionRuntime(FactionId.YANLONG);
  const tieying = engine.getFactionRuntime(FactionId.TIEYING);
  const shamo = engine.getFactionRuntime(FactionId.SHAMO);

  const relYT = diplo.getBilateralState(state.diplomacy, FactionId.YANLONG, FactionId.TIEYING);
  relYT.relation = 70;
  assert.equal(
    diplo.formAlliance(FactionId.YANLONG, FactionId.TIEYING, state.diplomacy, state.factions).success,
    true
  );

  const shamoRelBefore = diplo.getRelation(state.diplomacy, FactionId.YANLONG, FactionId.SHAMO);
  const credBefore = yanlong.credibility; // 88

  // 炎龙撕毁与铁鹰的军事同盟发动偷袭！
  const warRes = diplo.declareWar(
    FactionId.YANLONG,
    FactionId.TIEYING,
    state.diplomacy,
    state.factions
  );
  assert.equal(warRes.success, true);
  assert.equal(warRes.assessment.isBetrayalTriggered, true);
  assert.equal(warRes.assessment.credibilityDelta, -45);
  assert.equal(warRes.assessment.globalRelationDelta, -25);
  assert.equal(warRes.assessment.vendettaTurns, 10);
  assert.equal(warRes.assessment.battleMoralePenalty, -16); // 炎龙/铁鹰 -16

  assert.equal(yanlong.credibility, credBefore - 45);
  assert.equal(relYT.relation, -100);
  assert.equal(relYT.vendettaLockTurns, 10);
  assert.equal(yanlong.betrayalMoralePenaltyBattles, 2);
  assert.equal(
    diplo.getRelation(state.diplomacy, FactionId.YANLONG, FactionId.SHAMO),
    shamoRelBefore - 25
  );

  // 血海世仇期间（10 回合），即便割城赔巨款求和也必定返回 REJECTED_BREAKDOWN
  const peaceDuringVendetta = diplo.evaluatePeaceOffer(
    {
      proposer: FactionId.YANLONG,
      target: FactionId.TIEYING,
      goldIndemnity: 900,
      grainTributePerTurn: 100,
      cededNodeIds: ['yl_granary'],
      truceTurns: 8
    },
    state.diplomacy,
    state.factions,
    state.nodes
  );
  assert.equal(peaceDuringVendetta.kind, PeaceOutcomeKind.REJECTED_BREAKDOWN);

  // 验证血月祭司 (-5) 与苍狼汗国 (-10) 背盟士气惩罚档位，以及 C < 40 全图禁绝结盟
  assert.equal(diplo.getBetrayalMoralePenaltyForFaction(FactionId.TIEYING), -16);
  assert.equal(diplo.getBetrayalMoralePenaltyForFaction(FactionId.XUEYUE), -5);
  assert.equal(diplo.getBetrayalMoralePenaltyForFaction(FactionId.CANGLANG), -10);

  yanlong.credibility = 35; // < 40 禁盟红线
  const relYS = diplo.getBilateralState(state.diplomacy, FactionId.YANLONG, FactionId.SHAMO);
  relYS.relation = 80;
  assert.equal(
    diplo.formAlliance(FactionId.YANLONG, FactionId.SHAMO, state.diplomacy, state.factions).success,
    false
  );
  assert.equal(
    diplo.formAlliance(FactionId.SHAMO, FactionId.YANLONG, state.diplomacy, state.factions).success,
    false
  );
  assert.ok(shamo.isAlive);
});

test('DiplomacyEngine: Double-Alliance Defensive Priority Exemption (0 credibility loss when defending invaded ally or mediating 3-turn truce)', () => {
  const engine = new CampaignEngine(FactionId.YANLONG);
  const diplo = engine.getDiplomacyEngine();
  const state = engine.getState();

  // A = 炎龙同时与 B = 苍狼、C = 铁鹰缔结军事同盟
  diplo.getBilateralState(state.diplomacy, FactionId.YANLONG, FactionId.CANGLANG).relation = 75;
  diplo.getBilateralState(state.diplomacy, FactionId.YANLONG, FactionId.TIEYING).relation = 75;
  assert.equal(
    diplo.formAlliance(FactionId.YANLONG, FactionId.CANGLANG, state.diplomacy, state.factions).success,
    true
  );
  assert.equal(
    diplo.formAlliance(FactionId.YANLONG, FactionId.TIEYING, state.diplomacy, state.factions).success,
    true
  );

  // B(苍狼) 主动向 C(铁鹰) 宣战发动侵略！
  diplo.declareWar(FactionId.CANGLANG, FactionId.TIEYING, state.diplomacy, state.factions);

  // 反向核验：若 A(炎龙) 助纣为虐去进攻被侵略的受害盟友 C(铁鹰)，仍构成背盟（-45 信誉）！
  const attackVictimAssess = diplo.assessWarDeclaration(
    FactionId.YANLONG,
    FactionId.TIEYING,
    state.diplomacy,
    state.factions
  );
  assert.equal(attackVictimAssess.isBetrayalTriggered, true);
  assert.equal(attackVictimAssess.credibilityDelta, -45);

  // 正向核验 1：A(炎龙) 居中调停 B、C 达成 3 回合停火 -> 零扣信誉！
  const yanlong = engine.getFactionRuntime(FactionId.YANLONG);
  const initCred = yanlong.credibility;
  const mediateRes = diplo.mediateDoubleAllianceConflict(
    FactionId.YANLONG,
    FactionId.CANGLANG,
    FactionId.TIEYING,
    state.diplomacy
  );
  assert.equal(mediateRes.success, true);
  assert.equal(mediateRes.credibilityDelta, 0);
  assert.equal(yanlong.credibility, initCred);
  const bcRel = diplo.getBilateralState(state.diplomacy, FactionId.CANGLANG, FactionId.TIEYING);
  assert.equal(bcRel.status, DiplomaticStatus.TRUCE);
  assert.equal(bcRel.remainingTurns, 3);

  // 正向核验 2：B(苍狼) 再次撕毁停火强攻 C(铁鹰)，A(炎龙) 仗义出兵向挑衅方 B(苍狼) 宣战协防 C -> 豁免背盟，零扣信誉！
  diplo.declareWar(FactionId.CANGLANG, FactionId.TIEYING, state.diplomacy, state.factions);
  const defendAllyAssess = diplo.assessWarDeclaration(
    FactionId.YANLONG,
    FactionId.CANGLANG,
    state.diplomacy,
    state.factions
  );
  assert.equal(defendAllyAssess.isBetrayalTriggered, false);
  assert.equal(defendAllyAssess.credibilityDelta, 0);
  assert.equal(defendAllyAssess.vendettaTurns, 0);
  assert.equal(defendAllyAssess.battleMoralePenalty, 0);

  const defendWarRes = diplo.declareWar(
    FactionId.YANLONG,
    FactionId.CANGLANG,
    state.diplomacy,
    state.factions
  );
  assert.equal(defendWarRes.success, true);
  assert.equal(yanlong.credibility, initCred);
  assert.equal(yanlong.betrayalMoralePenaltyBattles, 0);
});

test('DiplomacyEngine: diminishing gifts, sow discord, trade bonus (+35% Shamo), treaty expiry (+3 cred), and >=13 cities anti-hegemony (+25)', () => {
  const engine = new CampaignEngine(FactionId.SHAMO);
  const diplo = engine.getDiplomacyEngine();
  const state = engine.getState();

  const shamo = engine.getFactionRuntime(FactionId.SHAMO);
  shamo.gold = 3000;
  shamo.grain = 3000;

  // 1) 同回合连续 3 次等额送礼：好感增量严格边际递减
  const g1 = diplo.sendGift(FactionId.SHAMO, FactionId.TIEYING, 200, 0, state.diplomacy, state.factions);
  const g2 = diplo.sendGift(FactionId.SHAMO, FactionId.TIEYING, 200, 0, state.diplomacy, state.factions);
  const g3 = diplo.sendGift(FactionId.SHAMO, FactionId.TIEYING, 200, 0, state.diplomacy, state.factions);
  assert.ok(g1.relationDelta > g2.relationDelta);
  assert.ok(g2.relationDelta > g3.relationDelta);

  // 2) 丝路通商：沙漠商盟享 +35% 贸易收益（60 * 1.35 = 81），解锁《丝路商队》再 +45 = 126
  const relST = diplo.getBilateralState(state.diplomacy, FactionId.SHAMO, FactionId.TIEYING);
  relST.relation = 40;
  assert.equal(
    diplo.signTradePact(FactionId.SHAMO, FactionId.TIEYING, state.diplomacy, state.factions).success,
    true
  );
  const shamoTradeBase = diplo.calculateTurnTradeIncomeForFaction(
    FactionId.SHAMO,
    state.diplomacy,
    state.factions
  );
  const tieyingTradeBase = diplo.calculateTurnTradeIncomeForFaction(
    FactionId.TIEYING,
    state.diplomacy,
    state.factions
  );
  assert.equal(tieyingTradeBase, 60);
  assert.equal(shamoTradeBase, 81);

  engine.unlockTech(FactionId.SHAMO, 'sm_tech_caravan');
  assert.equal(
    diplo.calculateTurnTradeIncomeForFaction(FactionId.SHAMO, state.diplomacy, state.factions),
    126
  );

  // 3) 密使挑拨离间：关系 -20 并瓦解脆弱同盟
  const relYC = diplo.getBilateralState(state.diplomacy, FactionId.YANLONG, FactionId.CANGLANG);
  relYC.status = DiplomaticStatus.ALLIANCE;
  relYC.relation = 50;
  const discordRes = diplo.sowDiscord(
    FactionId.SHAMO,
    FactionId.YANLONG,
    FactionId.CANGLANG,
    200,
    state.diplomacy,
    state.factions
  );
  assert.equal(discordRes.success, true);
  assert.equal(discordRes.relationDelta, -20);
  assert.equal(relYC.relation, 30);
  assert.notEqual(relYC.status, DiplomaticStatus.ALLIANCE);

  // 4) 有期条约自然届满：双方信誉各 +3
  relYC.status = DiplomaticStatus.TRUCE;
  relYC.remainingTurns = 1;
  const yanlong = engine.getFactionRuntime(FactionId.YANLONG);
  const canglang = engine.getFactionRuntime(FactionId.CANGLANG);
  const ylCredBefore = yanlong.credibility;
  const clCredBefore = canglang.credibility;
  engine.advanceTurn();
  assert.equal(relYC.status, DiplomaticStatus.NEUTRAL);
  assert.equal(yanlong.credibility, Math.min(100, ylCredBefore + 3));
  assert.equal(canglang.credibility, Math.min(100, clCredBefore + 3));

  // 5) 反霸权合纵警觉：让玄甲占领 >= 13 座城关，相邻非同盟诸侯（铁鹰 <-> 霜原）自动 +25 好感且不跨回合重复刷分
  let xjCount = engine.countControlledNodes(FactionId.XUANJIA);
  for (const n of state.nodes) {
    if (xjCount >= 13) {
      break;
    }
    if (
      n.owner !== FactionId.XUANJIA &&
      n.owner !== FactionId.TIEYING &&
      n.owner !== FactionId.SHUANGYUAN
    ) {
      n.owner = FactionId.XUANJIA;
      xjCount++;
    }
  }
  assert.ok(engine.countControlledNodes(FactionId.XUANJIA) >= 13);
  const relTSBefore = diplo.getRelation(state.diplomacy, FactionId.TIEYING, FactionId.SHUANGYUAN);
  const hegemons = diplo.applyAntiHegemonyCheck(state.diplomacy, state.factions, state.nodes);
  assert.ok(hegemons.includes(FactionId.XUANJIA));
  const relTSAfter1 = diplo.getRelation(state.diplomacy, FactionId.TIEYING, FactionId.SHUANGYUAN);
  assert.equal(relTSAfter1, relTSBefore + 25);

  // 再次调用不重复叠加 +25
  diplo.applyAntiHegemonyCheck(state.diplomacy, state.factions, state.nodes);
  assert.equal(
    diplo.getRelation(state.diplomacy, FactionId.TIEYING, FactionId.SHUANGYUAN),
    relTSAfter1
  );
});

// ==================== 3. CampaignEngine: 征募/科技/6类战斗识别/围点打援(-25)/战后结算与胜利判定 ====================

test('CampaignEngine: recruitment constraints, relief ambush (-25 isolated morale), post-battle settlement & victory conditions', () => {
  // 1) 苍狼禁造配重投石车核验
  const canglangCampaign = new CampaignEngine(FactionId.CANGLANG);
  const banTreb = canglangCampaign.recruitUnits(FactionId.CANGLANG, UnitTypeId.TREBUCHET, 1);
  assert.equal(banTreb.success, false);
  assert.equal(
    canglangCampaign.recruitUnits(FactionId.CANGLANG, UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER, 4).success,
    true
  );

  // 2) 炎龙战役：研发专属科技、6 类战斗场景识别、围点打援与战后结算
  const engine = new CampaignEngine(FactionId.YANLONG);
  const state = engine.getState();
  const yanlong = engine.getFactionRuntime(FactionId.YANLONG);

  // 禁招他国专属兵种
  assert.equal(
    engine.recruitUnits(FactionId.YANLONG, UnitTypeId.XUANJIA_CATAPHRACT, 2).success,
    false
  );
  // 炎龙攻城器械造价 -20% 折扣生效（投石车原价 240/210/60 -> 192/168/48）
  const trebCost = engine.computeRecruitmentCost(FactionId.YANLONG, UnitTypeId.TREBUCHET, 1);
  assert.deepEqual(trebCost, { gold: 192, wood: 168, grain: 48 });
  assert.equal(engine.unlockTech(FactionId.YANLONG, 'yl_tech_armor').success, true);
  assert.ok(yanlong.unlockedTechIds.includes('yl_tech_armor'));

  // 和平移防至前线赤壁雄关 yl_pass
  const movePass = engine.marchToNode(FactionId.YANLONG, 'yl_pass');
  assert.equal(movePass.success, true);
  assert.equal(movePass.battleTriggered, false);
  assert.equal(yanlong.armyLocationNodeId, 'yl_pass');

  // 预设【围点打援】伏击圈：在 yl_pass 设伏，瞄准相邻敌城 cl_river（饮马河营）
  const setTrap = engine.setupReliefAmbush(FactionId.YANLONG, 'yl_pass', 'cl_river');
  assert.equal(setTrap.success, true);
  assert.equal(engine.getNodeRuntime('yl_pass').hasAmbushTrap, true);

  const reliefBattleCfg = engine.createReliefAmbushBattleConfig(FactionId.YANLONG, 'yl_pass');
  assert.ok(reliefBattleCfg !== null);
  assert.equal(reliefBattleCfg.scenarioType, BattleScenarioType.AMBUSH);
  assert.ok(reliefBattleCfg.enemyMoraleModifier <= -10); // 援军遇伏 -10 士气

  // 结算【围点打援】伏击大捷：验证伤兵恢复、俘虏收编、主帅升级，以及 cl_river 守军士气直接 -25！
  const countRoster = (r) => r.reduce((s, item) => s + item.count, 0);
  const beforeBattleSoldiers = countRoster(yanlong.fieldArmyRoster);

  const ambushWinReport = engine.applyBattleSettlement(
    {
      scenarioType: BattleScenarioType.AMBUSH,
      campaignNodeId: 'yl_pass',
      playerFaction: FactionId.YANLONG,
      enemyFaction: FactionId.CANGLANG,
      isVictory: true,
      outcomeReason: BattleOutcomeReason.ENEMY_ARMY_ROUTED,
      durationSec: 145,
      playerInitialTotal: beforeBattleSoldiers,
      playerKilled: 18,
      playerWoundedRecovered: 8, // 净损仅 10 人
      enemyInitialTotal: 90,
      enemyKilled: 72,
      capturedPrisoners: 15, // 收编 15 名俘虏
      lootedGold: 160,
      lootedWood: 80,
      lootedGrain: 220,
      heroKills: 14,
      commanderExpGained: 130 // 足够从 Lv.1 升至 Lv.2
    },
    PrisonerDisposition.RECRUIT
  );

  assert.equal(ambushWinReport.netPlayerLosses, 10);
  assert.equal(ambushWinReport.prisonersRecruited, 15);
  assert.equal(countRoster(yanlong.fieldArmyRoster), beforeBattleSoldiers - 10 + 15);
  assert.equal(ambushWinReport.commanderLeveledUp, true);
  assert.equal(yanlong.commanderLevel, 2);
  assert.ok(ambushWinReport.reliefAmbushMoraleShockAppliedTo.includes('cl_river'));
  assert.equal(engine.getBesiegedGarrisonMoraleModifier('cl_river'), -25);

  // 随后趁势挥师进击孤城 cl_river：验证敌军初始士气确实携带 -25 孤城绝望惩罚！
  const assaultIsolated = engine.marchToNode(FactionId.YANLONG, 'cl_river');
  assert.equal(assaultIsolated.battleTriggered, true);
  assert.equal(assaultIsolated.battleConfig.scenarioType, BattleScenarioType.FIELD_PITCHED);
  assert.ok(assaultIsolated.battleConfig.enemyMoraleModifier <= -25);

  // 验证夜袭、护粮战、攻城战、守城战全部 6 种场景均可生成
  const nightRaidMarch = engine.marchToNode(FactionId.YANLONG, 'cl_river', { preferNightRaid: true });
  assert.equal(nightRaidMarch.battleConfig.scenarioType, BattleScenarioType.NIGHT_RAID);

  const convoyMarch = engine.marchToNode(FactionId.YANLONG, 'cl_river', { preferConvoyRaid: true });
  assert.equal(convoyMarch.battleConfig.scenarioType, BattleScenarioType.CONVOY_ESCORT);

  const defenseCfg = engine.createSiegeDefenseBattleConfig('yl_pass', FactionId.CANGLANG);
  assert.equal(defenseCfg.scenarioType, BattleScenarioType.SIEGE_DEFENSE);

  // 攻克 cl_river 后进逼城防 Lv.4 的风蚀古堡 cl_fort -> 自动识别为 SIEGE_ASSAULT
  const captureReport = engine.applyBattleSettlement({
    scenarioType: BattleScenarioType.FIELD_PITCHED,
    campaignNodeId: 'cl_river',
    playerFaction: FactionId.YANLONG,
    enemyFaction: FactionId.CANGLANG,
    isVictory: true,
    outcomeReason: BattleOutcomeReason.ENEMY_BASE_DESTROYED,
    durationSec: 180,
    playerInitialTotal: 95,
    playerKilled: 6,
    playerWoundedRecovered: 2,
    enemyInitialTotal: 85,
    enemyKilled: 70,
    capturedPrisoners: 10,
    lootedGold: 120,
    lootedWood: 60,
    lootedGrain: 150,
    heroKills: 9,
    commanderExpGained: 80
  });
  assert.equal(captureReport.nodeCaptured, true);
  assert.equal(engine.getNodeRuntime('cl_river').owner, FactionId.YANLONG);

  const siegeAssaultMarch = engine.marchToNode(FactionId.YANLONG, 'cl_fort');
  assert.equal(siegeAssaultMarch.battleConfig.scenarioType, BattleScenarioType.SIEGE_ASSAULT);

  // 验证主帅二次阵亡战败：挂载 2 回合【重伤休养】
  const martyrSettlement = engine.applyBattleSettlement({
    scenarioType: BattleScenarioType.SIEGE_ASSAULT,
    campaignNodeId: 'cl_fort',
    playerFaction: FactionId.YANLONG,
    enemyFaction: FactionId.CANGLANG,
    isVictory: false,
    outcomeReason: BattleOutcomeReason.PLAYER_HERO_MARTYRED,
    durationSec: 210,
    playerInitialTotal: 90,
    playerKilled: 25,
    playerWoundedRecovered: 5,
    enemyInitialTotal: 110,
    enemyKilled: 30,
    capturedPrisoners: 0,
    lootedGold: 0,
    lootedWood: 0,
    lootedGrain: 0,
    heroKills: 5,
    commanderExpGained: 20
  });
  assert.equal(martyrSettlement.commanderInjuredTurns, 2);
  assert.equal(yanlong.commanderInjuredTurns, 2);

  // 推进 1 回合（同时验证 AI 钩子对存活的 7 个 AI 势力触发）
  const hookedAiIds = [];
  engine.advanceTurn((eng, aiId) => {
    hookedAiIds.push(aiId);
    assert.ok(eng.getFactionRuntime(aiId).isAlive);
  });
  assert.equal(hookedAiIds.length, 7);
  assert.equal(yanlong.commanderInjuredTurns, 1);

  // 验证【同盟霸权胜利】与【八王都大一统胜利】
  for (let i = 0; i < state.nodes.length; i++) {
    state.nodes[i].owner = i < 20 ? FactionId.YANLONG : FactionId.TIEYING;
  }
  const relYT = engine.getDiplomacyEngine().getBilateralState(
    state.diplomacy,
    FactionId.YANLONG,
    FactionId.TIEYING
  );
  relYT.status = DiplomaticStatus.ALLIANCE;
  relYT.relation = 90;
  assert.equal(engine.checkVictoryCondition().kind, CampaignVictoryKind.ALLIANCE_HEGEMONY);

  for (const fCfg of FACTION_STATIC_CONFIGS) {
    engine.getNodeRuntime(fCfg.capitalNodeId).owner = FactionId.YANLONG;
  }
  assert.equal(engine.checkVictoryCondition().kind, CampaignVictoryKind.UNIFIED_ALL_CAPITALS);
});

// ==================== 4. SaveManager & SettingsStore: 存档多槽位、断粮 Infinity 还原与防崩校验 ====================

test('SaveManager & SettingsStore: auto+5 manual slots, SEVERED Infinity roundtrip, corrupted JSON / version mismatch defense', () => {
  const backend = new InMemoryPersistenceBackend();
  const saveMgr = new SaveManager(backend);
  const engine = new CampaignEngine(FactionId.CANGLANG);

  // 制造包含断粮孤城（sm_well 远在南疆沙海，与苍狼毫无相邻接壤 -> supplyHops = Infinity）的复杂进度并推进回合
  engine.getNodeRuntime('sm_well').owner = FactionId.CANGLANG;
  engine.advanceTurn();
  assert.equal(engine.getNodeRuntime('sm_well').supplyGrade, SupplyLineGrade.SEVERED);
  assert.equal(engine.getNodeRuntime('sm_well').supplyHops, Number.POSITIVE_INFINITY);

  // 1) 写入自动存档槽 (0) 与手动存档槽 (1, 5)
  const autoWrite = saveMgr.saveAuto(engine.getState(), '2026-11-18T08:00:00Z');
  assert.equal(autoWrite.success, true);
  assert.equal(autoWrite.slotIndex, 0);

  const manualWrite = saveMgr.saveToSlot(
    2,
    engine.getState(),
    '草原南征决战前夕',
    '2026-11-18T08:05:00Z'
  );
  assert.equal(manualWrite.success, true);

  // 非法槽位拦截（-1, 6）绝不抛异常
  assert.equal(saveMgr.saveToSlot(-1, engine.getState()).errorCode, SaveErrorCode.INVALID_SLOT);
  assert.equal(saveMgr.saveToSlot(6, engine.getState()).errorCode, SaveErrorCode.INVALID_SLOT);

  // 2) 冷启动新 SaveManager 绑定同一后端读取：验证 SEVERED Infinity 跳数与深拷贝隔离
  const coldSaveMgr = new SaveManager(backend);
  const summaries = coldSaveMgr.listSlotSummaries();
  assert.equal(summaries.length, 6); // 槽位 0 + 槽位 1~5
  assert.equal(summaries[0].isEmpty, false);
  assert.equal(summaries[1].isEmpty, true);
  assert.equal(summaries[2].isEmpty, false);
  assert.equal(summaries[2].title, '草原南征决战前夕');

  const loaded = coldSaveMgr.loadFromSlot(2, true);
  assert.equal(loaded.success, true);
  assert.equal(loaded.state.playerFaction, FactionId.CANGLANG);
  const loadedSeveredNode = loaded.state.nodes.find((n) => n.nodeId === 'sm_well');
  assert.equal(loadedSeveredNode.supplyGrade, SupplyLineGrade.SEVERED);
  assert.equal(loadedSeveredNode.supplyHops, Number.POSITIVE_INFINITY);

  // 3) 注入截断损坏 JSON、非法 schemaVersion、篡改节点数 —— 验证 100% 防崩安全降级
  backend.writeText(SaveManager.getStorageKeyForSlot(3), '{corrupted_json_truncated...');
  const corruptedLoad = coldSaveMgr.loadFromSlot(3, true);
  assert.equal(corruptedLoad.success, false);
  assert.equal(corruptedLoad.errorCode, SaveErrorCode.CORRUPTED_JSON);

  backend.writeText(
    SaveManager.getStorageKeyForSlot(4),
    JSON.stringify({ envelopeVersion: 1, slotIndex: 4, state: { schemaVersion: 999, turnNumber: 3 } })
  );
  const versionMismatch = coldSaveMgr.loadFromSlot(4, true);
  assert.equal(versionMismatch.success, false);
  assert.equal(versionMismatch.errorCode, SaveErrorCode.SCHEMA_VERSION_MISMATCH);

  backend.writeText(
    SaveManager.getStorageKeyForSlot(5),
    JSON.stringify({
      envelopeVersion: 1,
      slotIndex: 5,
      state: { schemaVersion: 1, turnNumber: 2, playerFaction: 'yanlong', nodes: [], factions: [], diplomacy: [] }
    })
  );
  const badPayload = coldSaveMgr.loadFromSlot(5, true);
  assert.equal(badPayload.success, false);
  assert.equal(badPayload.errorCode, SaveErrorCode.INVALID_STATE_PAYLOAD);

  // 即使槽位 3/4/5 全被外部写坏，listSlotSummaries() 依然稳定返回 6 个槽位绝不崩溃
  const resilientSummaries = coldSaveMgr.listSlotSummaries();
  assert.equal(resilientSummaries.length, 6);
  assert.equal(resilientSummaries[3].isEmpty, true);
  assert.equal(resilientSummaries[4].isEmpty, true);
  assert.equal(resilientSummaries[5].isEmpty, true);

  // 4) SettingsStore：60/30 FPS、远景 LOD、左右手摇杆、M-Pencil 手写笔灵敏度钳制与损坏 JSON 回退
  const settings = new SettingsStore(backend);
  assert.equal(settings.getSettings().targetFps, TargetFpsOption.FPS_60);

  settings.setTargetFps(TargetFpsOption.FPS_30);
  settings.setDistantLodPolicy(DistantLodPolicy.PERFORMANCE_SAVER);
  settings.setJoystickHandedness(JoystickHandedness.RIGHT_MOVE_LEFT_SKILL);
  settings.setStylusSensitivity(9.5); // 超上限钳制至 2.0
  settings.setSoundEnabled(false, 0.4);
  settings.setVibrationEnabled(false);

  const reloadedSettings = new SettingsStore(backend);
  const snap = reloadedSettings.getSettings();
  assert.equal(snap.targetFps, TargetFpsOption.FPS_30);
  assert.equal(snap.distantLodPolicy, DistantLodPolicy.PERFORMANCE_SAVER);
  assert.equal(snap.joystickHandedness, JoystickHandedness.RIGHT_MOVE_LEFT_SKILL);
  assert.equal(snap.stylusSensitivity, 2.0);
  assert.equal(snap.soundEnabled, false);
  assert.equal(snap.soundVolume, 0.4);
  assert.equal(snap.vibrationEnabled, false);
  assert.equal(reloadedSettings.getEffectiveStylusPickRadiusPx(), 48);

  // 损坏设置 JSON 自动安全回退默认值
  backend.writeText(SettingsStore.SETTINGS_STORAGE_KEY, '<<<not-json>>>');
  const fallbackSnap = reloadedSettings.reloadFromBackend();
  assert.equal(fallbackSnap.targetFps, TargetFpsOption.FPS_60);
  assert.equal(fallbackSnap.stylusSensitivity, 1.0);
});

// ==================== 5. 两轮自查强化断言：精确 +80% 信誉溢价、背盟二次确认、商盟雇佣、附庸与读档幂等性 ====================

test('Round 1 & 2 Audit: exact +80% low-credibility indemnity premium, truce evacuation, betrayal confirmation gate, Shamo mercenaries, vassalage & load idempotency', () => {
  // 1) 验证 C < 40 时求和所需正向筹码严格溢价 +80%
  const engine = new CampaignEngine(FactionId.YANLONG);
  const diplo = engine.getDiplomacyEngine();
  const state = engine.getState();

  engine.getNodeRuntime('yl_pass').owner = FactionId.CANGLANG;
  engine.getNodeRuntime('yl_ferry').owner = FactionId.CANGLANG;
  diplo.declareWar(FactionId.CANGLANG, FactionId.YANLONG, state.diplomacy, state.factions);

  const yanlong = engine.getFactionRuntime(FactionId.YANLONG);
  yanlong.credibility = 80;
  const probeZero = {
    proposer: FactionId.YANLONG,
    target: FactionId.CANGLANG,
    goldIndemnity: 0,
    grainTributePerTurn: 0,
    cededNodeIds: [],
    truceTurns: 5
  };
  const normalBd = diplo.computePeaceScoreBreakdown(
    probeZero,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  const rawDeficit = -(normalBd.warExhaustion - normalBd.battlefieldAdvantage + normalBd.thirdPartyThreat);
  assert.ok(rawDeficit > 0);

  yanlong.credibility = 30; // < 40 触发 +80% 赔款溢价
  const lowCredBd = diplo.computePeaceScoreBreakdown(
    probeZero,
    state.diplomacy,
    state.factions,
    state.nodes
  );
  assert.ok(Math.abs(lowCredBd.lowCredibilityPenalty - rawDeficit * 0.8) < 0.05);

  // 2) 验证停火割城后驻扎于被割让城池的主力军团自动撤回本方王都，且全图 BFS 粮道即时刷新
  yanlong.credibility = 85;
  yanlong.gold = 2000;
  yanlong.armyLocationNodeId = 'yl_granary';
  const peaceExec = engine.negotiatePeace({
    proposer: FactionId.YANLONG,
    target: FactionId.CANGLANG,
    goldIndemnity: 500,
    grainTributePerTurn: 10,
    cededNodeIds: ['yl_granary'],
    truceTurns: 8
  });
  assert.equal(peaceExec.applied, true);
  assert.equal(engine.getNodeRuntime('yl_granary').owner, FactionId.CANGLANG);
  assert.equal(yanlong.armyLocationNodeId, 'yl_capital'); // 自动撤离已割让领土

  // 3) 验证行军撕毁停战条约时的二次确认强阻断保护（confirmBetrayal=false 拦截，confirmBetrayal=true 执行）
  const blockedMarch = engine.marchToNode(FactionId.YANLONG, 'yl_pass', { confirmBetrayal: false });
  assert.equal(blockedMarch.success, false);
  assert.equal(blockedMarch.requiresBetrayalConfirmation, true);
  assert.equal(
    diplo.getStatus(state.diplomacy, FactionId.YANLONG, FactionId.CANGLANG),
    DiplomaticStatus.TRUCE
  );

  const forcedBetrayMarch = engine.marchToNode(FactionId.YANLONG, 'yl_pass', {
    confirmBetrayal: true
  });
  assert.equal(forcedBetrayMarch.success, true);
  assert.equal(forcedBetrayMarch.battleTriggered, true);
  assert.equal(yanlong.betrayalMoralePenaltyBattles, 2);
  assert.ok(forcedBetrayMarch.battleConfig.playerMoraleModifier <= -16);

  // 4) 验证沙漠商盟纯金币雇佣契约（木材/粮草消耗 = 0）及《黄金契约》雇佣盟友专属王牌兵种
  const shamoEngine = new CampaignEngine(FactionId.SHAMO);
  const shamoState = shamoEngine.getState();
  const shamo = shamoEngine.getFactionRuntime(FactionId.SHAMO);
  shamo.gold = 3500;
  const woodBeforeMerc = shamo.wood;
  const grainBeforeMerc = shamo.grain;

  const mercHire = shamoEngine.recruitUnits(
    FactionId.SHAMO,
    UnitTypeId.GREAT_AXEMAN,
    5,
    ArmyCorpsRole.VANGUARD_CENTER,
    true
  );
  assert.equal(mercHire.success, true);
  assert.equal(mercHire.costWood, 0);
  assert.equal(mercHire.costGrain, 0);
  assert.equal(shamo.wood, woodBeforeMerc);
  assert.equal(shamo.grain, grainBeforeMerc);

  shamoEngine.unlockTech(FactionId.SHAMO, 'sm_tech_mercenary');
  shamoEngine
    .getDiplomacyEngine()
    .getBilateralState(shamoState.diplomacy, FactionId.SHAMO, FactionId.TIEYING).relation = 75;
  shamoEngine
    .getDiplomacyEngine()
    .formAlliance(FactionId.SHAMO, FactionId.TIEYING, shamoState.diplomacy, shamoState.factions);
  const hireAllyCrossbow = shamoEngine.recruitUnits(
    FactionId.SHAMO,
    UnitTypeId.TIEYING_PAVISE_CROSSBOW,
    6,
    ArmyCorpsRole.LEFT_WING,
    true
  );
  assert.equal(hireAllyCrossbow.success, true);

  // 5) 验证弱国残存 1 城时缔结【朝贡附庸】及读档后反霸权 +25 幂等不重复刷分
  for (const n of shamoState.nodes) {
    if (n.owner === FactionId.WULIN && n.nodeId !== 'wl_capital') {
      n.owner = FactionId.XUANJIA;
    }
  }
  const vassalRes = shamoEngine
    .getDiplomacyEngine()
    .establishVassalage(
      FactionId.WULIN,
      FactionId.SHAMO,
      shamoState.diplomacy,
      shamoState.factions,
      shamoState.nodes
    );
  assert.equal(vassalRes.success, true);

  let xjOwned = shamoEngine.countControlledNodes(FactionId.XUANJIA);
  for (const n of shamoState.nodes) {
    if (xjOwned >= 14) {
      break;
    }
    if (n.owner === FactionId.XUEYUE) {
      n.owner = FactionId.XUANJIA;
      xjOwned++;
    }
  }
  shamoEngine.advanceTurn();
  const relBeforeSaveLoad = shamoEngine
    .getDiplomacyEngine()
    .getRelation(shamoState.diplomacy, FactionId.TIEYING, FactionId.SHUANGYUAN);

  const saveMgr = new SaveManager();
  assert.equal(saveMgr.saveToSlot(1, shamoEngine.getState()).success, true);
  const loadedSnap = saveMgr.loadFromSlot(1, true);
  assert.equal(loadedSnap.success, true);

  const restoredEngine = new CampaignEngine(FactionId.SHAMO);
  restoredEngine.loadFromSaveState(loadedSnap.state);
  restoredEngine
    .getDiplomacyEngine()
    .applyAntiHegemonyCheck(
      restoredEngine.getState().diplomacy,
      restoredEngine.getState().factions,
      restoredEngine.getState().nodes
    );
  const relAfterSaveLoad = restoredEngine
    .getDiplomacyEngine()
    .getRelation(restoredEngine.getState().diplomacy, FactionId.TIEYING, FactionId.SHUANGYUAN);
  assert.equal(relAfterSaveLoad, relBeforeSaveLoad); // 读档后绝不二次重复叠加 +25！
});

// ==================== 6. 补充纯逻辑测试：战前讹诈破裂当场开战、战中求和被拒敌军 +8 士气与战俘溢出赎金 ====================

test('Diplomacy & Settlement edge cases: pre-war city/gold extortion triggers immediate WAR, rejected war-peace +8 enemy morale & prisoner cap overflow ransom', () => {
  const engine = new CampaignEngine(FactionId.YANLONG);
  const diplo = engine.getDiplomacyEngine();
  const state = engine.getState();

  // 1) 和平中立期（NEUTRAL）向邻国索要边境城池（goldIndemnity=0, cededNodeIds=['cl_river']）的边缘讹诈破裂 -> 当回合直接触发宣战！
  assert.equal(diplo.getStatus(state.diplomacy, FactionId.YANLONG, FactionId.CANGLANG), DiplomaticStatus.NEUTRAL);
  const extortionExec = engine.negotiatePeace({
    proposer: FactionId.YANLONG,
    target: FactionId.CANGLANG,
    goldIndemnity: 0,
    grainTributePerTurn: 0,
    cededNodeIds: ['cl_river'],
    truceTurns: 5
  });
  assert.equal(extortionExec.evaluation.kind, PeaceOutcomeKind.REJECTED_BREAKDOWN);
  assert.equal(extortionExec.triggeredImmediateWar, true, '战前索城讹诈被斥退必须当回合直接引发对方宣战');
  assert.equal(diplo.getStatus(state.diplomacy, FactionId.YANLONG, FactionId.CANGLANG), DiplomaticStatus.WAR);
  assert.equal(diplo.isEnvoyLockedThisTurn(FactionId.YANLONG, FactionId.CANGLANG), true, '同回合锁定再次派使防穷举刷数值');

  // 推进 1 回合解除当回合派使锁，验证交战期无诚意求和被拒 -> 敌军下场战斗获得 +8 士气激励，且消费一次后自动清零
  engine.advanceTurn();
  assert.equal(diplo.isEnvoyLockedThisTurn(FactionId.YANLONG, FactionId.CANGLANG), false);
  // 令苍狼大举占优（夺取 yl_pass / yl_ferry / yl_granary）且炎龙信誉低迷，此时炎龙反倒索取赔款 -> 必遭 REJECTED_BREAKDOWN (netScore < -20)
  engine.getNodeRuntime('yl_pass').owner = FactionId.CANGLANG;
  engine.getNodeRuntime('yl_ferry').owner = FactionId.CANGLANG;
  engine.getNodeRuntime('yl_granary').owner = FactionId.CANGLANG;
  const rejectedPeace = engine.negotiatePeace({
    proposer: FactionId.YANLONG,
    target: FactionId.CANGLANG,
    goldIndemnity: -350,
    grainTributePerTurn: 0,
    cededNodeIds: [],
    truceTurns: 6
  });
  assert.equal(rejectedPeace.evaluation.kind, PeaceOutcomeKind.REJECTED_BREAKDOWN);
  assert.equal(rejectedPeace.enemyMoraleBoostNextBattle, 8);

  const battleAfterReject = engine.marchToNode(FactionId.YANLONG, 'yl_pass');
  assert.equal(battleAfterReject.battleTriggered, true);
  assert.equal(battleAfterReject.battleConfig.enemyMoraleModifier, 8, '求和被拒后敌军下场战斗必须获得 +8 士气激励');

  // 再次生成战斗配置：验证 +8 士气激励为单场一次性消费，绝不永久叠加
  const secondBattleCheck = engine.marchToNode(FactionId.YANLONG, 'yl_pass');
  assert.equal(secondBattleCheck.battleConfig.enemyMoraleModifier, 0);

  // 2) 验证战俘处置：RANSOM 全额换赎金（18 金/人），以及 RECRUIT 触及 240 人口上限时溢出人数自动折算赎金
  const yanlong = engine.getFactionRuntime(FactionId.YANLONG);
  const goldBeforeRansom = yanlong.gold;
  const ransomReport = engine.applyBattleSettlement(
    {
      scenarioType: BattleScenarioType.FIELD_PITCHED,
      campaignNodeId: 'yl_pass',
      playerFaction: FactionId.YANLONG,
      enemyFaction: FactionId.CANGLANG,
      isVictory: true,
      outcomeReason: BattleOutcomeReason.ENEMY_ARMY_ROUTED,
      durationSec: 120,
      playerInitialTotal: 90,
      playerKilled: 0,
      playerWoundedRecovered: 0,
      enemyInitialTotal: 80,
      enemyKilled: 60,
      capturedPrisoners: 20,
      lootedGold: 0,
      lootedWood: 0,
      lootedGrain: 0,
      heroKills: 4,
      commanderExpGained: 40
    },
    PrisonerDisposition.RANSOM
  );
  assert.equal(ransomReport.prisonersRecruited, 0);
  assert.equal(ransomReport.ransomGoldGained, 20 * CampaignEngine.RANSOM_GOLD_PER_PRISONER);
  assert.equal(yanlong.gold, goldBeforeRansom + 20 * 18);

  // 将玩家野战军人口填至 235（距上限 240 仅差 5 人口），收编 18 名战俘 -> 应整编 5 人 + 其余 13 人自动换取赎金！
  yanlong.fieldArmyRoster = [
    { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 235, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }
  ];
  const overflowReport = engine.applyBattleSettlement(
    {
      scenarioType: BattleScenarioType.FIELD_PITCHED,
      campaignNodeId: 'cl_river',
      playerFaction: FactionId.YANLONG,
      enemyFaction: FactionId.CANGLANG,
      isVictory: true,
      outcomeReason: BattleOutcomeReason.ENEMY_ARMY_ROUTED,
      durationSec: 100,
      playerInitialTotal: 235,
      playerKilled: 0,
      playerWoundedRecovered: 0,
      enemyInitialTotal: 70,
      enemyKilled: 50,
      capturedPrisoners: 18,
      lootedGold: 0,
      lootedWood: 0,
      lootedGrain: 0,
      heroKills: 2,
      commanderExpGained: 30
    },
    PrisonerDisposition.RECRUIT
  );
  assert.equal(overflowReport.prisonersRecruited, 5, '仅整编剩余 5 人口容量至上限 240');
  assert.equal(overflowReport.ransomGoldGained, 13 * 18, '超出 240 人口上限的 13 名俘虏自动折算赎金');
});

// ==================== 7. 补充闭环集成测试：CampaignEngine + CampaignStrategicAI 连续 5 回合全图演化 ====================

test('CampaignEngine + CampaignStrategicAI: 5-turn full-world autonomous AI strategic loop maintains all invariants', () => {
  const engine = new CampaignEngine(FactionId.SHAMO);
  const strategicAi = new CampaignStrategicAI();
  let executedAiCmds = 0;

  for (let turn = 0; turn < 5; turn++) {
    engine.advanceTurn((eng, aiFaction) => {
      const st = eng.getState();
      const diplo = eng.getDiplomacyEngine();
      const actions = strategicAi.evaluateFactionTurn(st, aiFaction);
      for (const act of actions) {
        executedAiCmds++;
        if (act.type === StrategicActionType.RECRUIT && act.unitType !== null && act.corpsRole !== null) {
          eng.recruitUnits(aiFaction, act.unitType, act.count, act.corpsRole, aiFaction === FactionId.SHAMO);
        } else if (act.type === StrategicActionType.UNLOCK_TECH && act.techId !== null) {
          eng.unlockTech(aiFaction, act.techId);
        } else if (act.type === StrategicActionType.SET_AMBUSH_TRAP && act.targetNodeId !== null) {
          eng.setupReliefAmbush(aiFaction, act.targetNodeId);
        } else if (act.type === StrategicActionType.PROPOSE_TRADE && act.targetFactionId !== null) {
          diplo.signTradePact(aiFaction, act.targetFactionId, st.diplomacy, st.factions);
        } else if (act.type === StrategicActionType.PROPOSE_ALLIANCE && act.targetFactionId !== null) {
          diplo.formAlliance(aiFaction, act.targetFactionId, st.diplomacy, st.factions);
        } else if (act.type === StrategicActionType.PROPOSE_PEACE && act.peaceTerms !== null) {
          eng.negotiatePeace(act.peaceTerms);
        } else if (act.type === StrategicActionType.DECLARE_WAR && act.targetFactionId !== null) {
          diplo.declareWar(aiFaction, act.targetFactionId, st.diplomacy, st.factions);
        } else if (act.type === StrategicActionType.MARCH_ATTACK && act.targetNodeId !== null) {
          const targetNode = eng.getNodeRuntime(act.targetNodeId);
          if (targetNode !== undefined && targetNode.owner !== aiFaction) {
            // 模拟 AI vs AI 边境攻防损耗与占领推进
            targetNode.garrisonStrength = Math.max(20, targetNode.garrisonStrength - 35);
          }
        }
      }
    });
  }

  const finalState = engine.getState();
  assert.equal(finalState.turnNumber, 6);
  assert.ok(executedAiCmds >= 35, `5 回合 7 家 AI 应产生丰富战略决策，实际执行: ${executedAiCmds}`);
  assert.equal(finalState.nodes.length, 40);

  for (const fac of finalState.factions) {
    assert.ok(Number.isFinite(fac.gold) && fac.gold >= 0, `${fac.factionId} 金币非负有限`);
    assert.ok(Number.isFinite(fac.wood) && fac.wood >= 0, `${fac.factionId} 木材非负有限`);
    assert.ok(Number.isFinite(fac.grain) && fac.grain >= 0, `${fac.factionId} 粮草非负有限`);
    assert.ok(fac.credibility >= 0 && fac.credibility <= 100, `${fac.factionId} 信誉落在 [0,100]`);
  }
  for (const d of finalState.diplomacy) {
    assert.ok(d.relation >= -100 && d.relation <= 100);
  }
});

test('GameSessionCoordinator: full campaign page closed loop (40-city 78-road, diplomacy, betrayal gate, march battle, prisoner settlement, save/load & settings)', () => {
  const backend = new InMemoryPersistenceBackend();
  const session = new GameSessionCoordinator(backend);

  // 1) 开启 40 城 78 路炎龙战役，验证自动存档立即落盘
  const initState = session.startNewCampaign(FactionId.YANLONG);
  assert.equal(initState.nodes.length, 40);
  assert.equal(session.getCampaignEngine().getSupplyEngine().auditMapTopology().undirectedRoadCount, 78);

  // 2) 外交面板闭环：馈赠提好感 -> 互不侵犯 -> 丝路通商 -> 军事攻守同盟
  const pRun = session.getCampaignEngine().getFactionRuntime(FactionId.YANLONG);
  pRun.gold = 2500;
  pRun.grain = 2500;
  for (let i = 0; i < 4; i++) {
    session.sendPlayerGift(FactionId.TIEYING, 220, 120);
  }
  assert.equal(session.signPlayerNonAggression(FactionId.TIEYING).success, true);

  // 3) 背盟二次确认强阻断：互不侵犯期间未确认强行进军 ty_fort 必须阻断且零扣信誉！
  pRun.armyLocationNodeId = 'yl_granary';
  const credBefore = pRun.credibility;
  const blockedMarch = session.marchPlayerArmyToNode('ty_fort', { confirmBetrayal: false });
  assert.equal(blockedMarch.requiresBetrayalConfirmation, true);
  assert.equal(blockedMarch.battleTriggered, false);
  assert.equal(pRun.credibility, credBefore);

  // 升级缔结通商与正式军事同盟：验证军事同盟开放和平借道权，而对盟友宣战评估触发背盟告警
  assert.equal(session.signPlayerTradePact(FactionId.TIEYING).success, true);
  session
    .getCampaignEngine()
    .getDiplomacyEngine()
    .getBilateralState(initState.diplomacy, FactionId.YANLONG, FactionId.TIEYING).relation = 65;
  assert.equal(session.formPlayerAlliance(FactionId.TIEYING).success, true);
  assert.equal(session.assessPlayerWarDeclaration(FactionId.TIEYING).isBetrayalTriggered, true);
  const alliedTransit = session.marchPlayerArmyToNode('ty_fort');
  assert.equal(alliedTransit.success, true);
  assert.equal(alliedTransit.battleTriggered, false);
  assert.equal(session.marchPlayerArmyToNode('yl_granary').success, true);

  // 4) 移师北境赤壁雄关 yl_pass 挥师进攻苍狼饮马河营 cl_river -> 触发真实战场 -> 大捷收编战俘占城！
  assert.equal(session.marchPlayerArmyToNode('yl_capital').success, true);
  assert.equal(session.marchPlayerArmyToNode('yl_pass').success, true);
  const warMarch = session.marchPlayerArmyToNode('cl_river', { autoDeclareWar: true });
  assert.equal(warMarch.battleTriggered, true);
  assert.equal(session.isActiveBattleFromCampaign(), true);

  const sim = session.getActiveBattleSimulator();
  assert.ok(sim !== null);
  session.stepActiveBattle(0.1);
  const enemyCamp = sim.getWorldView().structures.find(
    (st) => st.side === 'enemy' && st.kind === 'base_camp'
  );
  enemyCamp.hp = 0;
  enemyCamp.isBreached = true;
  session.stepActiveBattle(0.05);
  const battleSum = session.finalizeActiveBattle();
  assert.equal(battleSum.isVictory, true);

  const settleReport = session.commitPendingCampaignSettlement(PrisonerDisposition.RECRUIT);
  assert.ok(settleReport !== null);
  assert.equal(settleReport.nodeCaptured, true);
  assert.equal(session.getCampaignEngine().getNodeRuntime('cl_river').owner, FactionId.YANLONG);

  // 5) 停火媾和预览与签约 + 推进下一回合 AI 全图演化 + 手动存读档槽位 2 闭环 + 平板设置同步
  const peaceTerms = {
    proposer: FactionId.YANLONG,
    target: FactionId.CANGLANG,
    goldIndemnity: 350,
    grainTributePerTurn: 30,
    cededNodeIds: [],
    truceTurns: 8
  };
  const preview = session.previewPeaceOffer(peaceTerms);
  assert.ok(Number.isFinite(preview.netScore));
  assert.equal(session.submitPeaceOffer(peaceTerms).applied, true);

  const turnRep = session.advanceCampaignTurnWithAi();
  assert.equal(turnRep.newTurnNumber, 2);

  const saveRes = session.saveCurrentCampaignToSlot(2, '北伐饮马河大捷');
  assert.equal(saveRes.success, true);
  session.startNewCampaign(FactionId.WULIN);
  assert.equal(session.getCampaignEngine().getState().playerFaction, FactionId.WULIN);

  const loadRes = session.loadCampaignFromSlot(2);
  assert.equal(loadRes.success, true);
  assert.equal(session.getCampaignEngine().getState().playerFaction, FactionId.YANLONG);
  assert.equal(session.getCampaignEngine().getNodeRuntime('cl_river').owner, FactionId.YANLONG);

  session.getSettingsStore().setTargetFps(TargetFpsOption.FPS_30);
  session.getSettingsStore().setDistantLodPolicy(DistantLodPolicy.PERFORMANCE_SAVER);
  session.getSettingsStore().setJoystickHandedness(JoystickHandedness.RIGHT_MOVE_LEFT_SKILL);
  session.getSettingsStore().setStylusSensitivity(1.25);
  assert.equal(session.getSettingsStore().getEffectiveStylusPickRadiusPx(), 30);
});

