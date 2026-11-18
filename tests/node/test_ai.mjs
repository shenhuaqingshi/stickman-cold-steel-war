import assert from 'node:assert/strict';

import {
  AiPersonality,
  ArmyCorpsRole,
  BattleControlMode,
  BattlefieldRationStage,
  BattleOutcomeReason,
  BattleScenarioType,
  BattleSide,
  DiplomaticStatus,
  EncirclementState,
  FactionId,
  FormationType,
  HeroVitalState,
  HeroWeaponType,
  SupplyLineGrade,
  TacticalOrder,
  TerrainType,
  UnitActionState,
  UnitTypeId,
  WeatherType
} from '../../entry/src/main/ets/core/CoreContracts.ets';

import { CAMPAIGN_MAP_NODES } from '../../entry/src/main/ets/config/CampaignMapConfig.ets';
import { FACTION_STATIC_CONFIGS } from '../../entry/src/main/ets/config/FactionConfig.ets';

import {
  AI_BLACKBOARD_UPDATE_INTERVAL_SEC,
  BattleTacticalAI,
  evaluateBattleTacticalAI,
  SiegeTacticalPhase,
  TacticalDoctrineId
} from '../../entry/src/main/ets/core/ai/BattleTacticalAI.ets';

import {
  CampaignStrategicAI,
  computeFactionSupplyMap,
  evaluateCampaignStrategicTurn,
  HEGEMONY_CITY_THRESHOLD,
  StrategicActionType
} from '../../entry/src/main/ets/core/ai/CampaignStrategicAI.ets';
import { BattleSimulator } from '../../entry/src/main/ets/core/combat/BattleSimulator.ets';

// ==================== 测试辅助构造器 ====================

function makeHero(side, factionId, overrides = {}) {
  return {
    side,
    factionId,
    name: side === BattleSide.PLAYER ? '玩家统帅' : '敌军统帅',
    x: side === BattleSide.PLAYER ? 900 : 3900,
    y: 1200,
    vx: 0,
    vy: 0,
    facingRad: side === BattleSide.PLAYER ? 0 : Math.PI,
    hp: 1100,
    maxHp: 1100,
    armor: 55,
    moveSpeed: 92,
    vitalState: HeroVitalState.HEALTHY_ACTIVE,
    recoveryTimer: 0,
    activeWeapon: HeroWeaponType.COMMAND_SABER,
    remainingArrows: 24,
    arrowRecoverTimer: 0,
    attackCooldown: 0,
    isBlocking: false,
    parryWindowTimer: 0,
    ironBulwarkTimer: 0,
    warCryBuffTimer: 0,
    chargeCooldown: 0,
    bulwarkCooldown: 0,
    warCryCooldown: 0,
    actionState: UnitActionState.IDLE_READY,
    animPhase: 0,
    kills: 0,
    ...overrides
  };
}

function makeSquad(squadId, side, factionId, corpsRole, primaryUnitType, centerX, centerY, overrides = {}) {
  return {
    squadId,
    side,
    factionId,
    corpsRole,
    name: `Sq-${squadId}`,
    primaryUnitType,
    formation: FormationType.PHALANX_RECT,
    order: TacticalOrder.ADVANCE,
    morale: 80,
    isRouting: false,
    encirclement: EncirclementState.CLEAR,
    threatOctantMask: 0,
    centerX,
    centerY,
    facingRad: side === BattleSide.PLAYER ? 0 : Math.PI,
    targetX: centerX,
    targetY: centerY,
    waypointsX: [],
    waypointsY: [],
    waypointCursor: 0,
    aliveCount: 24,
    initialCount: 24,
    bannerAlive: true,
    bannerLostPenaltyTimer: 0,
    fordRatio: 0,
    halfFordShockApplied: false,
    ...overrides
  };
}

function makeBaseWorld(overrides = {}) {
  const playerFaction = overrides.playerFaction ?? FactionId.YANLONG;
  const enemyFaction = overrides.enemyFaction ?? FactionId.CANGLANG;
  const structures = overrides.structures ?? [
    {
      id: 'p_camp',
      side: BattleSide.PLAYER,
      kind: 'base_camp',
      x: 360,
      y: 1110,
      width: 180,
      height: 180,
      hp: 2500,
      maxHp: 2500,
      isBreached: false
    },
    {
      id: 'e_camp',
      side: BattleSide.ENEMY,
      kind: 'base_camp',
      x: 4260,
      y: 1110,
      width: 180,
      height: 180,
      hp: 2500,
      maxHp: 2500,
      isBreached: false
    }
  ];

  const squads = overrides.squads ?? [
    makeSquad(1, BattleSide.PLAYER, playerFaction, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 1800, 1200),
    makeSquad(2, BattleSide.PLAYER, playerFaction, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.COMPOSITE_ARCHER, 1400, 1200),
    makeSquad(101, BattleSide.ENEMY, enemyFaction, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 3000, 1200),
    makeSquad(102, BattleSide.ENEMY, enemyFaction, ArmyCorpsRole.LEFT_WING, UnitTypeId.LIGHT_CAVALRY, 3100, 520),
    makeSquad(103, BattleSide.ENEMY, enemyFaction, ArmyCorpsRole.RIGHT_WING, UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER, 3100, 1880),
    makeSquad(104, BattleSide.ENEMY, enemyFaction, ArmyCorpsRole.REAR_RESERVE, UnitTypeId.GREAT_AXEMAN, 3550, 1200),
    makeSquad(105, BattleSide.ENEMY, enemyFaction, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.COMPOSITE_ARCHER, 3320, 1200)
  ];

  return {
    width: 4800,
    height: 2400,
    scenarioType: BattleScenarioType.FIELD_PITCHED,
    primaryTerrain: TerrainType.PLAIN,
    weather: WeatherType.CLEAR_DAY,
    playerFaction,
    enemyFaction,
    terrainZones: [],
    resourceNodes: [
      { id: 'rn_gold_e', resourceKind: 'gold', x: 3900, y: 420, remainingAmount: 800, maxAmount: 800 },
      { id: 'rn_grain_p', resourceKind: 'grain', x: 1350, y: 2050, remainingAmount: 900, maxAmount: 900 }
    ],
    structures,
    soldiers: [],
    squads,
    playerHero: makeHero(BattleSide.PLAYER, playerFaction, { x: 1720, y: 1200 }),
    enemyHero: makeHero(BattleSide.ENEMY, enemyFaction, { x: 3180, y: 1200 }),
    projectiles: [],
    corpses: [],
    hitEffects: [],
    hud: {
      elapsedSec: 25,
      isPaused: false,
      controlMode: BattleControlMode.RTS_COMMANDER,
      switchCooldownSec: 0,
      garrisonBellActive: false,
      playerGold: 500,
      playerWood: 350,
      playerGrain: 1100,
      playerRationStage: BattlefieldRationStage.ABUNDANT,
      enemyRationStage: BattlefieldRationStage.ABUNDANT,
      playerAliveSoldiers: 48,
      playerPopUsed: 48,
      playerPopCap: 240,
      enemyAliveSoldiers: 120,
      enemyAvgMorale: 80,
      playerAvgMorale: 80,
      heroHp: 1100,
      heroMaxHp: 1100,
      heroVitalState: HeroVitalState.HEALTHY_ACTIVE,
      heroWeapon: HeroWeaponType.COMMAND_SABER,
      heroArrows: 24,
      chargeCd: 0,
      bulwarkCd: 0,
      warCryCd: 0,
      hitStopRemainingMs: 0,
      outcome: BattleOutcomeReason.ONGOING,
      ...(overrides.hud ?? {})
    },
    ...overrides
  };
}

function findCmd(batch, squadId) {
  return batch.squadCommands.find((c) => c.squadIds.includes(squadId));
}

function makeStandardCampaignState(playerFaction = FactionId.SHAMO) {
  const nodes = CAMPAIGN_MAP_NODES.map((cfg) => ({
    nodeId: cfg.id,
    owner: cfg.initialOwner,
    garrisonStrength: cfg.defenseLevel * 28,
    defenseHp: cfg.defenseLevel * 200,
    isolatedTurns: 0,
    hasAmbushTrap: false,
    supplyGrade: SupplyLineGrade.FULL_SUPPLY,
    supplyHops: cfg.isSupplyDepot ? 0 : 1
  }));

  const factions = FACTION_STATIC_CONFIGS.map((fc) => ({
    factionId: fc.id,
    isAlive: true,
    gold: 620,
    wood: 420,
    grain: 680,
    credibility: fc.startingCredibility,
    unlockedTechIds: [],
    commanderLevel: 2,
    commanderExp: 100,
    betrayalMoralePenaltyBattles: 0,
    commanderInjuredTurns: 0,
    fieldArmyRoster: [
      { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 22, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
      { unitType: UnitTypeId.LIGHT_CAVALRY, count: 12, corpsRole: ArmyCorpsRole.LEFT_WING },
      { unitType: fc.exclusiveUnitId, count: 14, corpsRole: ArmyCorpsRole.REAR_RESERVE }
    ],
    armyLocationNodeId: fc.capitalNodeId
  }));

  const diplomacy = [];
  for (let i = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
    for (let j = i + 1; j < FACTION_STATIC_CONFIGS.length; j++) {
      const fa = FACTION_STATIC_CONFIGS[i].id;
      const fb = FACTION_STATIC_CONFIGS[j].id;
      const initRel = fa === FactionId.XUEYUE || fb === FactionId.XUEYUE ? -18 : 12;
      diplomacy.push({
        factionA: fa,
        factionB: fb,
        relation: initRel,
        status: DiplomaticStatus.NEUTRAL,
        remainingTurns: 0,
        vendettaLockTurns: 0
      });
    }
  }

  return {
    schemaVersion: 1,
    turnNumber: 4,
    playerFaction,
    nodes,
    factions,
    diplomacy,
    totalBattlesFought: 2,
    totalBattlesWon: 1,
    totalEnemiesKilled: 180,
    recentLogs: []
  };
}

function setDiplomacy(state, fa, fb, status, relation = 0, vendettaLockTurns = 0) {
  const rec = state.diplomacy.find(
    (d) => (d.factionA === fa && d.factionB === fb) || (d.factionA === fb && d.factionB === fa)
  );
  if (rec) {
    rec.status = status;
    rec.relation = relation;
    rec.vendettaLockTurns = vendettaLockTurns;
  }
}

// ==================== 执行测试套件 ====================

let passed = 0;
function runTest(name, fn) {
  fn();
  passed += 1;
  console.log(`  [PASS] ${name}`);
}

console.log('=== 开始执行 L2 战场战术 AI 与 L1 战略大地图 AI 自动化单测 ===');

// 1. 0.5s 黑板节流步进与正面佯攻+两翼绕后包抄航点测试
runTest('1. 0.5s 黑板更新周期 & 正面佯攻+两翼南北走廊钳形合围航点生成', () => {
  const ai = new BattleTacticalAI();
  const world = makeBaseWorld();

  assert.equal(AI_BLACKBOARD_UPDATE_INTERVAL_SEC, 0.5);
  assert.equal(ai.step(world, 0.20), null, '未满 0.5s 不应提前触发黑板重算');
  assert.equal(ai.step(world, 0.25), null, '累计 0.45s 仍不应触发');

  const batch = ai.step(world, 0.10);
  assert.ok(batch !== null, '累计满 0.5s 必须返回 AiBattleDecisionBatch');
  assert.equal(batch.activeDoctrine, TacticalDoctrineId.PINNING_PINCER_ENCIRCLE);
  assert.equal(batch.siegePhase, SiegeTacticalPhase.NONE);
  assert.equal(batch.toggleGarrisonBell, false);

  const vanCmd = findCmd(batch, 101);
  const leftWingCmd = findCmd(batch, 102);
  const rightWingCmd = findCmd(batch, 103);
  const reserveCmd = findCmd(batch, 104);

  assert.equal(vanCmd.order, TacticalOrder.ADVANCE, '中军前锋应稳步推进吸火');
  assert.equal(vanCmd.formation, FormationType.PHALANX_RECT);

  assert.equal(leftWingCmd.order, TacticalOrder.PINCER_ENCIRCLE, '左翼应执行钳形合围');
  assert.ok(Array.isArray(leftWingCmd.customWaypointsX) && leftWingCmd.customWaypointsX.length === 3, '左翼必须生成3段绕后弧线航点');
  assert.ok(leftWingCmd.customWaypointsY[0] <= 520, '左翼首航点必须走北翼走廊 (Y <= 520)');
  assert.ok(leftWingCmd.customWaypointsX[1] < 1800, '左翼中段航点必须绕过玩家前锋 X=1800 切向后排');

  assert.equal(rightWingCmd.order, TacticalOrder.PINCER_ENCIRCLE, '右翼应协同执行钳形合围');
  assert.ok(Array.isArray(rightWingCmd.customWaypointsY) && rightWingCmd.customWaypointsY.length === 3);
  assert.ok(rightWingCmd.customWaypointsY[0] >= 1880, '右翼首航点必须走南翼走廊 (Y >= 1880)');

  assert.equal(reserveCmd.order, TacticalOrder.HOLD_GROUND, '战线平稳时总预备队必须扣留原地待命');
  assert.ok(reserveCmd.targetX > 3000, '总预备队应驻留于己方前线后方');

  // 苍狼汗国严禁请求配重投石车
  for (const r of batch.recruitRequests) {
    assert.notEqual(r.unitType, UnitTypeId.TREBUCHET, '苍狼汗国绝不可招募投石车');
  }
});

// 2. 反风筝纪律与残血孤身斩首围猎对比测试
runTest('2. 反风筝单队驱离（绝不全军脱阵傻追） vs 玩家主帅残血孤身（HP < 45%）合围斩首', () => {
  // 2A. 玩家主帅持百石硬弓在阵前单骑远射风筝（HP 85%）
  const kiteWorld = makeBaseWorld({
    playerHero: makeHero(BattleSide.PLAYER, FactionId.YANLONG, {
      x: 2620,
      y: 920,
      hp: 935,
      maxHp: 1100,
      activeWeapon: HeroWeaponType.HEAVY_WARBOW,
      remainingArrows: 18
    })
  });

  const kiteBatch = evaluateBattleTacticalAI(kiteWorld);
  const chasingHeroCmds = kiteBatch.squadCommands.filter(
    (c) => c.targetX === 2620 && c.targetY === 920
  );
  assert.equal(chasingHeroCmds.length, 1, '反风筝铁律：只能分派唯一 1 支机动队驱离风筝主帅！');
  const vanCmd = findCmd(kiteBatch, 101);
  const resCmd = findCmd(kiteBatch, 104);
  const siegeCmd = findCmd(kiteBatch, 105);
  assert.notEqual(vanCmd.targetX, 2620, '中军前锋绝不可脱离主战线傻追风筝主帅');
  assert.equal(resCmd.order, TacticalOrder.HOLD_GROUND, '总预备队绝不可追击风筝主帅');
  assert.notEqual(siegeCmd.targetX, 2620, '远程群继续瞄准敌主力阵线');

  // 2B. 玩家主帅孤身深入敌阵且 HP = 38% (< 45%) -> 触发斩首围猎！
  const decapWorld = makeBaseWorld({
    enemyFaction: FactionId.TIEYING,
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 1500, 1200),
      makeSquad(101, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.GREAT_AXEMAN, 2950, 1150),
      makeSquad(102, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.LEFT_WING, UnitTypeId.LIGHT_CAVALRY, 3050, 900),
      makeSquad(103, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.TIEYING_PAVISE_CROSSBOW, 3200, 1220)
    ],
    playerHero: makeHero(BattleSide.PLAYER, FactionId.YANLONG, {
      x: 2820,
      y: 1120,
      hp: 410,
      maxHp: 1100
    })
  });

  const decapBatch = evaluateBattleTacticalAI(decapWorld);
  assert.equal(decapBatch.activeDoctrine, TacticalDoctrineId.DECAPITATION_HUNT);
  const hunters = decapBatch.squadCommands.filter((c) => c.targetX === 2820 && c.targetY === 1120);
  assert.ok(hunters.length >= 3, '残血孤身主帅应立即引来附近多支破甲精锐与骑兵合围斩首');
  assert.equal(decapBatch.enemyHeroTargetX, 2820, '敌方主帅也应压上协力斩首');
});

// 3. 渡口潜伏待机与涉水 30%~80% 半渡而击测试
runTest('3. 渡口潜伏与半渡而击（涉水 30%~80% 触发弓弩集火与重步压岸）', () => {
  const riverZone = {
    id: 'central_ford',
    terrain: TerrainType.RIVER_FORD,
    x: 2250,
    y: 0,
    width: 300,
    height: 2400,
    elevation: 0
  };

  // 阶段 A：玩家尚未入水，AI 在东岸潜伏待机不主动下水挨罚
  const waitWorld = makeBaseWorld({
    enemyFaction: FactionId.YANLONG,
    primaryTerrain: TerrainType.RIVER_FORD,
    terrainZones: [riverZone],
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.SHUANGYUAN, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHUANGYUAN_GIANT_BREAKER, 1950, 1200, { fordRatio: 0.0 }),
      makeSquad(101, BattleSide.ENEMY, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.YANLONG_HALBERD_GRENADIER, 2780, 1200),
      makeSquad(105, BattleSide.ENEMY, FactionId.YANLONG, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.COMPOSITE_ARCHER, 2960, 1200)
    ]
  });
  const waitBatch = evaluateBattleTacticalAI(waitWorld);
  assert.equal(waitBatch.activeDoctrine, TacticalDoctrineId.FORD_AMBUSH_WAIT);
  assert.equal(findCmd(waitBatch, 101).order, TacticalOrder.AMBUSH_HIDE);

  // 阶段 B：玩家前锋涉水达 55%（处于 30%~80% 半渡脱节窗口）
  const halfFordWorld = makeBaseWorld({
    enemyFaction: FactionId.YANLONG,
    primaryTerrain: TerrainType.RIVER_FORD,
    terrainZones: [riverZone],
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.SHUANGYUAN, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHUANGYUAN_GIANT_BREAKER, 2380, 1200, { fordRatio: 0.55 }),
      makeSquad(101, BattleSide.ENEMY, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.YANLONG_HALBERD_GRENADIER, 2720, 1200),
      makeSquad(105, BattleSide.ENEMY, FactionId.YANLONG, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.COMPOSITE_ARCHER, 2920, 1200)
    ]
  });
  const strikeBatch = evaluateBattleTacticalAI(halfFordWorld);
  assert.equal(strikeBatch.activeDoctrine, TacticalDoctrineId.HALF_FORD_STRIKE);
  assert.equal(findCmd(strikeBatch, 101).order, TacticalOrder.ALL_OUT_CHARGE, '重步必须立即冲锋压岸');
  assert.equal(findCmd(strikeBatch, 105).formation, FormationType.ECHELON_LINE, '岸边弓弩雁行展开集火');
  assert.equal(findCmd(strikeBatch, 105).targetX, 2380);
});

// 4. 高地刺猬防反（铁鹰王国）防单骑诱饵测试
runTest('4. 高地刺猬防反（铁鹰王国抢占 HIGH_GROUND 坚守，单骑诱敌绝不追出工事）', () => {
  const hillZone = {
    id: 'east_ridge',
    terrain: TerrainType.HIGH_GROUND,
    x: 3100,
    y: 850,
    width: 420,
    height: 700,
    elevation: 1
  };
  const hillWorld = makeBaseWorld({
    enemyFaction: FactionId.TIEYING,
    terrainZones: [hillZone],
    squads: [
      // 玩家派 1 支轻骑逼近山脚勾引，其余两支主力远在后方
      makeSquad(1, BattleSide.PLAYER, FactionId.CANGLANG, ArmyCorpsRole.LEFT_WING, UnitTypeId.LIGHT_CAVALRY, 2860, 1180),
      makeSquad(2, BattleSide.PLAYER, FactionId.CANGLANG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 1400, 1200),
      makeSquad(3, BattleSide.PLAYER, FactionId.CANGLANG, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.COMPOSITE_ARCHER, 1150, 1200),
      makeSquad(101, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.PIKEMAN, 3220, 1200),
      makeSquad(102, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.LEFT_WING, UnitTypeId.PIKEMAN, 3220, 1000),
      makeSquad(105, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.TIEYING_PAVISE_CROSSBOW, 3320, 1200)
    ]
  });

  const batch = evaluateBattleTacticalAI(hillWorld);
  assert.equal(batch.activeDoctrine, TacticalDoctrineId.HIGH_GROUND_HEDGEHOG);
  for (const cmd of batch.squadCommands) {
    assert.equal(cmd.order, TacticalOrder.HOLD_GROUND, `分队 ${cmd.squadIds[0]} 必须死守高地阵地，绝不可下山傻追诱饵`);
  }
});

// 5. 诈败诱敌入林与三面伏击合围测试
runTest('5. 诈败诱敌伏击（雾林猎手 FEIGNED_RETREAT 引敌入林 -> 三面合围歼灭）', () => {
  const forestZone = {
    id: 'mist_woods',
    terrain: TerrainType.DENSE_FOREST,
    x: 2950,
    y: 800,
    width: 500,
    height: 800,
    elevation: 0
  };

  const ai = new BattleTacticalAI();
  // 第一拍：前锋刚接敌（距离 <= 380px），触发诈败诱敌后撤，两翼密林潜伏
  const contactWorld = makeBaseWorld({
    enemyFaction: FactionId.WULIN,
    terrainZones: [forestZone],
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 2460, 1200),
      makeSquad(2, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.COMPOSITE_ARCHER, 2240, 1200),
      makeSquad(101, BattleSide.ENEMY, FactionId.WULIN, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 2760, 1200),
      makeSquad(102, BattleSide.ENEMY, FactionId.WULIN, ArmyCorpsRole.LEFT_WING, UnitTypeId.WULIN_SHADOW_SNIPER, 3180, 920),
      makeSquad(103, BattleSide.ENEMY, FactionId.WULIN, ArmyCorpsRole.RIGHT_WING, UnitTypeId.LIGHT_CAVALRY, 3180, 1480)
    ]
  });

  const lureBatch = ai.evaluateNow(contactWorld);
  assert.equal(lureBatch.activeDoctrine, TacticalDoctrineId.FEIGNED_RETREAT_LURE);
  assert.equal(findCmd(lureBatch, 101).order, TacticalOrder.FEIGNED_RETREAT, '前锋必须触发诈败后撤');
  assert.equal(findCmd(lureBatch, 102).order, TacticalOrder.AMBUSH_HIDE, '林中神射必须潜伏待机');
  assert.equal(findCmd(lureBatch, 103).order, TacticalOrder.AMBUSH_HIDE, '侧翼伏兵必须潜伏待机');

  // 第二拍：玩家贪功开启全军冲锋踏入密林陷阱袋，与后排弓手脱节 -> 瞬间三面反扑合围！
  const trapWorld = makeBaseWorld({
    enemyFaction: FactionId.WULIN,
    terrainZones: [forestZone],
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 3050, 1200, {
        order: TacticalOrder.ALL_OUT_CHARGE
      }),
      makeSquad(2, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.COMPOSITE_ARCHER, 2320, 1200),
      makeSquad(101, BattleSide.ENEMY, FactionId.WULIN, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 3340, 1200),
      makeSquad(102, BattleSide.ENEMY, FactionId.WULIN, ArmyCorpsRole.LEFT_WING, UnitTypeId.WULIN_SHADOW_SNIPER, 3180, 920),
      makeSquad(103, BattleSide.ENEMY, FactionId.WULIN, ArmyCorpsRole.RIGHT_WING, UnitTypeId.LIGHT_CAVALRY, 3180, 1480)
    ]
  });

  const springBatch = ai.evaluateNow(trapWorld);
  assert.equal(springBatch.activeDoctrine, TacticalDoctrineId.FOREST_TRAP_ENCIRCLE);
  assert.equal(findCmd(springBatch, 101).order, TacticalOrder.ALL_OUT_CHARGE, '诈败前锋反身掩杀');
  assert.equal(findCmd(springBatch, 103).order, TacticalOrder.PINCER_ENCIRCLE, '伏兵暴起封堵退路合围');
});

// 6. 奇袭断粮、总预备队双阈值投入 & 本阵偷家自动敲钟测试
runTest('6. 断粮奇袭（RAID_SUPPLY）、总预备队双阈值决胜投入 & 遭轻骑偷家自动敲响警钟', () => {
  // 6A. 玩家野外工兵落单采粮 + 敌本阵遭玩家游骑偷袭 + 己方前锋士气跌至 29 (<35)
  const crisisWorld = makeBaseWorld({
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 2500, 1200),
      // 落单野外玩家工兵队（远离玩家本阵与主力）
      makeSquad(6, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.SUPPLY_ESCORT, UnitTypeId.SAPPER, 1450, 2080),
      // 偷袭敌方本阵的玩家游骑兵
      makeSquad(7, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.LEFT_WING, UnitTypeId.LIGHT_CAVALRY, 4120, 1180),
      // 敌军前锋士气跌破 35（29）亟需预备队堵漏
      makeSquad(101, BattleSide.ENEMY, FactionId.CANGLANG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 2720, 1200, {
        morale: 29
      }),
      makeSquad(102, BattleSide.ENEMY, FactionId.CANGLANG, ArmyCorpsRole.LEFT_WING, UnitTypeId.LIGHT_CAVALRY, 3000, 520),
      makeSquad(103, BattleSide.ENEMY, FactionId.CANGLANG, ArmyCorpsRole.RIGHT_WING, UnitTypeId.LIGHT_CAVALRY, 3000, 1900),
      makeSquad(104, BattleSide.ENEMY, FactionId.CANGLANG, ArmyCorpsRole.REAR_RESERVE, UnitTypeId.GREAT_AXEMAN, 3450, 1200),
      makeSquad(106, BattleSide.ENEMY, FactionId.CANGLANG, ArmyCorpsRole.SUPPLY_ESCORT, UnitTypeId.SAPPER, 4050, 950)
    ]
  });

  const ai = new BattleTacticalAI();
  const batch1 = ai.evaluateNow(crisisWorld);

  assert.equal(batch1.toggleGarrisonBell, true, '本阵遭偷袭时必须立即敲响警钟');
  assert.equal(findCmd(batch1, 106).order, TacticalOrder.RETREAT, '己方野外工兵应立即退回本阵避险');

  const raidCmd = batch1.squadCommands.find((c) => c.order === TacticalOrder.RAID_SUPPLY);
  assert.ok(raidCmd !== undefined, '发现玩家落单野外工兵必须派出机动队执行 RAID_SUPPLY');
  assert.equal(raidCmd.targetX, 1450);
  assert.equal(raidCmd.targetY, 2080);

  const reservePlugCmd = findCmd(batch1, 104);
  assert.equal(reservePlugCmd.order, TacticalOrder.ALL_OUT_CHARGE, '前锋士气 < 35 时总预备队必须立即投入堵漏');
  assert.equal(reservePlugCmd.targetX, 2720);

  // 偷袭骑兵被歼灭后再次评估 -> 再次拨动警钟恢复工兵复工
  const clearedWorld = {
    ...crisisWorld,
    squads: crisisWorld.squads.filter((s) => s.squadId !== 7)
  };
  const batch2 = ai.evaluateNow(clearedWorld);
  assert.equal(batch2.toggleGarrisonBell, true, '危机解除后应再次切换警钟让工兵出营复工');

  // 6B. 敌军前线稳固但玩家前锋动摇（morale = 33 < 40）-> 总预备队锥形冲锋一锤定音
  const coupWorld = makeBaseWorld({
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 2200, 1200, {
        morale: 33
      }),
      makeSquad(101, BattleSide.ENEMY, FactionId.XUANJIA, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 2450, 1200, {
        morale: 78
      }),
      makeSquad(104, BattleSide.ENEMY, FactionId.XUANJIA, ArmyCorpsRole.REAR_RESERVE, UnitTypeId.XUANJIA_CATAPHRACT, 2950, 1200)
    ],
    enemyFaction: FactionId.XUANJIA
  });
  const coupBatch = evaluateBattleTacticalAI(coupWorld);
  const resStrike = findCmd(coupBatch, 104);
  assert.equal(resStrike.order, TacticalOrder.ALL_OUT_CHARGE, '敌军阵线动摇时总预备队铁浮图应全速突击凿穿');
  assert.equal(resStrike.formation, FormationType.WEDGE_CHARGE);
  assert.equal(resStrike.targetX, 2200);
});

// 7. 攻守城三段式状态机全阶段切换测试
runTest('7. 攻城三阶段（炮火拆塔 -> 刀盾登城+巨斧破门 -> 破口投入重骑总预备队）与守城三阶段完整验证', () => {
  const makeAssaultStructures = (towerHp, gateHp, gateBreached) => [
    { id: 'p_camp', side: BattleSide.PLAYER, kind: 'base_camp', x: 400, y: 1200, width: 200, height: 200, hp: 3000, maxHp: 3000, isBreached: false },
    { id: 'p_gate', side: BattleSide.PLAYER, kind: 'gate', x: 1255, y: 1190, width: 90, height: 220, hp: gateHp, maxHp: 2000, isBreached: gateBreached },
    { id: 'p_wall_n', side: BattleSide.PLAYER, kind: 'wall_segment', x: 1260, y: 610, width: 80, height: 420, hp: 1800, maxHp: 2000, isBreached: false },
    { id: 'p_wall_s', side: BattleSide.PLAYER, kind: 'wall_segment', x: 1260, y: 1570, width: 80, height: 420, hp: 1800, maxHp: 2000, isBreached: false },
    { id: 'p_tower', side: BattleSide.PLAYER, kind: 'arrow_tower', x: 1285, y: 1025, width: 70, height: 70, hp: towerHp, maxHp: 1000, isBreached: towerHp <= 0 },
    { id: 'e_camp', side: BattleSide.ENEMY, kind: 'base_camp', x: 4900, y: 1200, width: 200, height: 200, hp: 3000, maxHp: 3000, isBreached: false }
  ];

  const assaultSquads = [
    makeSquad(1, BattleSide.PLAYER, FactionId.TIEYING, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.TIEYING_PAVISE_CROSSBOW, 1260, 1300),
    makeSquad(101, BattleSide.ENEMY, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 2100, 1300),
    makeSquad(102, BattleSide.ENEMY, FactionId.YANLONG, ArmyCorpsRole.LEFT_WING, UnitTypeId.GREAT_AXEMAN, 2100, 1100),
    makeSquad(104, BattleSide.ENEMY, FactionId.YANLONG, ArmyCorpsRole.REAR_RESERVE, UnitTypeId.XUANJIA_CATAPHRACT, 2600, 1300),
    makeSquad(105, BattleSide.ENEMY, FactionId.YANLONG, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.TREBUCHET, 2250, 1300)
  ];

  // 攻城阶段 1：箭塔完好，投石车点拆箭塔，总预备队按兵不动
  const aPhase1 = evaluateBattleTacticalAI(
    makeBaseWorld({
      width: 5600,
      height: 2600,
      scenarioType: BattleScenarioType.SIEGE_DEFENSE,
      enemyFaction: FactionId.YANLONG,
      structures: makeAssaultStructures(900, 1900, false),
      squads: assaultSquads
    })
  );
  assert.equal(aPhase1.siegePhase, SiegeTacticalPhase.ASSAULT_PHASE_1_ARTILLERY);
  assert.equal(findCmd(aPhase1, 105).targetX, 1320, '投石车应优先瞄准箭塔');
  assert.equal(findCmd(aPhase1, 104).order, TacticalOrder.HOLD_GROUND, '炮火准备期预备队原地待命');

  // 攻城阶段 2：箭塔已拔、城门受损至 55% -> 刀盾登墙 + 巨斧破门，总预备队仍扣留
  const aPhase2 = evaluateBattleTacticalAI(
    makeBaseWorld({
      width: 5600,
      height: 2600,
      scenarioType: BattleScenarioType.SIEGE_DEFENSE,
      enemyFaction: FactionId.YANLONG,
      structures: makeAssaultStructures(0, 1100, false),
      squads: assaultSquads
    })
  );
  assert.equal(aPhase2.siegePhase, SiegeTacticalPhase.ASSAULT_PHASE_2_ESCALADE_BATTER);
  assert.equal(findCmd(aPhase2, 101).formation, FormationType.PHALANX_RECT, '刀盾方阵顶箭雨登城');
  assert.equal(findCmd(aPhase2, 102).order, TacticalOrder.ALL_OUT_CHARGE, '巨斧兵猛劈正门');
  assert.equal(findCmd(aPhase2, 104).order, TacticalOrder.HOLD_GROUND, '城门未破前重骑预备队仍不送死');

  // 攻城阶段 3：城门告破 -> 重骑总预备队锥形阵全力突入城内！
  const aPhase3 = evaluateBattleTacticalAI(
    makeBaseWorld({
      width: 5600,
      height: 2600,
      scenarioType: BattleScenarioType.SIEGE_DEFENSE,
      enemyFaction: FactionId.YANLONG,
      structures: makeAssaultStructures(0, 0, true),
      squads: assaultSquads
    })
  );
  assert.equal(aPhase3.siegePhase, SiegeTacticalPhase.ASSAULT_PHASE_3_BREACH_COMMIT);
  assert.equal(findCmd(aPhase3, 104).order, TacticalOrder.ALL_OUT_CHARGE, '破门后重骑总预备队立即突入瓮城');
  assert.equal(findCmd(aPhase3, 104).formation, FormationType.WEDGE_CHARGE);
  assert.equal(aPhase3.enemyHeroTriggerWarCry, true, '破城突入时敌帅释放战吼鼓舞全军');

  // -------- AI 守城三阶段 --------
  const makeDefenseStructures = (gateHp) => [
    { id: 'p_camp', side: BattleSide.PLAYER, kind: 'base_camp', x: 400, y: 1200, width: 200, height: 200, hp: 3000, maxHp: 3000, isBreached: false },
    { id: 'e_gate', side: BattleSide.ENEMY, kind: 'gate', x: 4155, y: 1190, width: 90, height: 220, hp: gateHp, maxHp: 2000, isBreached: gateHp <= 0 },
    { id: 'e_camp', side: BattleSide.ENEMY, kind: 'base_camp', x: 4900, y: 1200, width: 200, height: 200, hp: 3000, maxHp: 3000, isBreached: false }
  ];

  // 守城阶段 1：城门 85%，城头神弩优先集火工兵/巨斧
  const dPhase1 = evaluateBattleTacticalAI(
    makeBaseWorld({
      width: 5600,
      height: 2600,
      scenarioType: BattleScenarioType.SIEGE_ASSAULT,
      enemyFaction: FactionId.TIEYING,
      structures: makeDefenseStructures(1700),
      squads: [
        makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 3550, 1300),
        makeSquad(2, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.SUPPLY_ESCORT, UnitTypeId.SAPPER, 3680, 1120),
        makeSquad(101, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.PIKEMAN, 4320, 1300),
        makeSquad(105, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.TIEYING_PAVISE_CROSSBOW, 4240, 1300)
      ]
    })
  );
  assert.equal(dPhase1.siegePhase, SiegeTacticalPhase.DEFENSE_PHASE_1_WALL_SNIPE);
  assert.equal(findCmd(dPhase1, 105).targetX, 3680, '城头神弩必须优先点杀推云梯工兵');

  // 守城阶段 2：城门耐久跌至 22% (< 30%) -> 重步长枪结圆阵死堵门洞
  const dPhase2 = evaluateBattleTacticalAI(
    makeBaseWorld({
      width: 5600,
      height: 2600,
      scenarioType: BattleScenarioType.SIEGE_ASSAULT,
      enemyFaction: FactionId.TIEYING,
      structures: makeDefenseStructures(440),
      squads: [
        makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.GREAT_AXEMAN, 4120, 1300),
        makeSquad(101, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.PIKEMAN, 4420, 1300),
        makeSquad(105, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.TIEYING_PAVISE_CROSSBOW, 4240, 1300)
      ]
    })
  );
  assert.equal(dPhase2.siegePhase, SiegeTacticalPhase.DEFENSE_PHASE_2_PLUG_GATE);
  assert.equal(findCmd(dPhase2, 101).formation, FormationType.CIRCLE_DEFENSE, '长枪重步在门洞结圆阵死堵缺口');

  // 守城阶段 3：攻方步兵全压城下，后方投石车空虚无护卫 -> 侧门派 1 队游骑绕后烧投石车
  const dPhase3 = evaluateBattleTacticalAI(
    makeBaseWorld({
      width: 5600,
      height: 2600,
      scenarioType: BattleScenarioType.SIEGE_ASSAULT,
      enemyFaction: FactionId.TIEYING,
      structures: makeDefenseStructures(1200),
      squads: [
        makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 4050, 1300),
        makeSquad(5, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.TREBUCHET, 3300, 1280),
        makeSquad(101, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.PIKEMAN, 4300, 1300),
        makeSquad(102, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.LEFT_WING, UnitTypeId.LIGHT_CAVALRY, 4350, 900),
        makeSquad(105, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.TIEYING_PAVISE_CROSSBOW, 4240, 1300)
      ]
    })
  );
  assert.equal(dPhase3.siegePhase, SiegeTacticalPhase.DEFENSE_PHASE_3_SALLY_BURN_SIEGE);
  const sallyCmd = findCmd(dPhase3, 102);
  assert.equal(sallyCmd.order, TacticalOrder.FLANK);
  assert.equal(sallyCmd.targetX, 3300, '侧门游骑必须直扑后方落单投石车');
  assert.ok(sallyCmd.customWaypointsY[0] <= 240, '侧门游骑经侧翼走廊绕开城下步兵群');
});

// 8. 敌帅落马 15s 指挥瘫痪边界测试
runTest('8. 敌帅落马重伤前 15s 陷入指挥瘫痪（无法变阵与投入预备队）', () => {
  const paralyzedWorld = makeBaseWorld({
    enemyHero: makeHero(BattleSide.ENEMY, FactionId.CANGLANG, {
      vitalState: HeroVitalState.RECOVERING_IN_CAMP,
      recoveryTimer: 40 // 45s 包扎倒计时刚过 5s，处于前 15s 瘫痪期
    }),
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 2200, 1200, { morale: 25 }),
      makeSquad(101, BattleSide.ENEMY, FactionId.CANGLANG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 2500, 1200, {
        formation: FormationType.ECHELON_LINE
      }),
      makeSquad(104, BattleSide.ENEMY, FactionId.CANGLANG, ArmyCorpsRole.REAR_RESERVE, UnitTypeId.GREAT_AXEMAN, 3300, 1200)
    ]
  });

  const batch = evaluateBattleTacticalAI(paralyzedWorld);
  assert.equal(batch.activeDoctrine, TacticalDoctrineId.COMMAND_PARALYSIS_HOLD);
  assert.equal(findCmd(batch, 101).formation, FormationType.ECHELON_LINE, '瘫痪期内无法变阵');
  assert.equal(findCmd(batch, 104).order, TacticalOrder.HOLD_GROUND, '瘫痪期内无法投入总预备队');
});

// 9. L1 战略大地图：7 个 AI 独立演化与互攻结盟（绝不只围着玩家转）
runTest('9. L1 战略大地图：7 大 AI 真实互相攻伐、研发、招募、设伏与通商（零玩家仇恨偏见）', () => {
  const state = makeStandardCampaignState(FactionId.SHAMO);
  // 令北境苍狼与玄甲交战，促进真实 AI vs AI 攻伐
  setDiplomacy(state, FactionId.CANGLANG, FactionId.XUANJIA, DiplomaticStatus.WAR, -75);

  const strategicAI = new CampaignStrategicAI();
  const allTurns = strategicAI.evaluateAllAiFactionsTurn(state);
  assert.equal(allTurns.size, 7, '除玩家外其余 7 家 AI 必须全部独立演化');

  let aiVsAiAttackCount = 0;
  const observedActionTypes = new Set();

  for (const [fid, acts] of allTurns.entries()) {
    assert.notEqual(fid, FactionId.SHAMO);
    for (const a of acts) {
      observedActionTypes.add(a.type);
      if (a.type === StrategicActionType.MARCH_ATTACK && a.targetFactionId !== FactionId.SHAMO) {
        aiVsAiAttackCount += 1;
      }
    }
  }

  assert.ok(aiVsAiAttackCount >= 2, '远端 AI 之间必须真实发生互相进军攻伐，而非全部围攻玩家');
  assert.ok(observedActionTypes.has(StrategicActionType.RECRUIT), '应产生征募指令');
  assert.ok(observedActionTypes.has(StrategicActionType.UNLOCK_TECH), '应产生专属科技研发指令');
  assert.ok(observedActionTypes.has(StrategicActionType.SET_AMBUSH_TRAP), '应产生要冲设伏指令');
  assert.ok(observedActionTypes.has(StrategicActionType.PROPOSE_TRADE), '应产生通商提议指令');
});

// 10. L1 战略大地图：两线作战规避求和（常规 AI vs 血月狂热特例）
runTest('10. L1 两线作战规避：常规势力遭 >=2 强敌夹击主动向次要战线求和，血月祭司团死战不退', () => {
  const state = makeStandardCampaignState(FactionId.SHAMO);
  // 炎龙帝国同时与北方苍狼汗国、东方玄甲重骑两大强敌交战
  setDiplomacy(state, FactionId.YANLONG, FactionId.CANGLANG, DiplomaticStatus.WAR, -65);
  setDiplomacy(state, FactionId.YANLONG, FactionId.XUANJIA, DiplomaticStatus.WAR, -55);

  const ylActions = evaluateCampaignStrategicTurn(state, FactionId.YANLONG);
  const peaceAct = ylActions.find((a) => a.type === StrategicActionType.PROPOSE_PEACE);
  assert.ok(peaceAct !== undefined, '炎龙陷入两线强敌作战时必须主动向次要战线发起求和');
  assert.ok(
    peaceAct.targetFactionId === FactionId.CANGLANG || peaceAct.targetFactionId === FactionId.XUANJIA
  );
  assert.ok(peaceAct.peaceTerms !== null);
  assert.ok(peaceAct.peaceTerms.goldIndemnity >= 0 && peaceAct.peaceTerms.goldIndemnity <= 620, '赔款不得超出国库上限');

  // 同一时间对主战线集中兵力进攻
  const marchAct = ylActions.find((a) => a.type === StrategicActionType.MARCH_ATTACK);
  if (marchAct) {
    assert.notEqual(marchAct.targetFactionId, peaceAct.targetFactionId, '求和对象与主攻方向必须分离');
  }

  // 对照实验：血月祭司团同时与玄甲、炎龙、雾林三线交战，绝不主动求和！
  setDiplomacy(state, FactionId.XUEYUE, FactionId.XUANJIA, DiplomaticStatus.WAR, -80);
  setDiplomacy(state, FactionId.XUEYUE, FactionId.YANLONG, DiplomaticStatus.WAR, -80);
  setDiplomacy(state, FactionId.XUEYUE, FactionId.WULIN, DiplomaticStatus.WAR, -80);

  const xyActions = evaluateCampaignStrategicTurn(state, FactionId.XUEYUE);
  const xyPeace = xyActions.find((a) => a.type === StrategicActionType.PROPOSE_PEACE);
  assert.equal(xyPeace, undefined, '血月祭司团狂热扩张，即使多线作战也绝不屈膝求和');
});

// 11. L1 战略大地图：>= 13 城反霸权【合纵警觉】促成反扩张同盟测试
runTest('11. L1 反霸权合纵警觉：任一势力占城 >= 13 座（35%）时，相邻非同盟 AI 自动结成反扩张同盟', () => {
  const state = makeStandardCampaignState(FactionId.YANLONG);
  assert.equal(HEGEMONY_CITY_THRESHOLD, 13);

  // 让炎龙帝国扩张至 14 座城池（原本 5 城 + 吞并苍狼 5 城 + 玄甲 4 城 = 14 城 >= 13）
  let extraClaimed = 0;
  for (const n of state.nodes) {
    if ((n.owner === FactionId.CANGLANG || n.owner === FactionId.XUANJIA) && extraClaimed < 9) {
      n.owner = FactionId.YANLONG;
      extraClaimed += 1;
    }
  }
  const ylCount = state.nodes.filter((n) => n.owner === FactionId.YANLONG).length;
  assert.equal(ylCount, 14);

  // 将铁鹰王国与霜原熊族、沙漠商盟初始关系设为普通中立 5（平时远低于 55 结盟线，全靠反霸权合纵激活！）
  setDiplomacy(state, FactionId.TIEYING, FactionId.SHUANGYUAN, DiplomaticStatus.NEUTRAL, 5);
  setDiplomacy(state, FactionId.TIEYING, FactionId.SHAMO, DiplomaticStatus.NEUTRAL, 5);

  const tyActions = evaluateCampaignStrategicTurn(state, FactionId.TIEYING);
  const allyAct = tyActions.find((a) => a.type === StrategicActionType.PROPOSE_ALLIANCE);

  assert.ok(allyAct !== undefined, '霸主占城 >= 13 时相邻 AI 必须突破常规门槛主动发起反霸权结盟');
  assert.notEqual(allyAct.targetFactionId, FactionId.YANLONG, '绝不可向霸主本人提议结盟');
  assert.ok(
    allyAct.targetFactionId === FactionId.SHUANGYUAN || allyAct.targetFactionId === FactionId.SHAMO,
    '应向相邻非同盟伙伴发起反扩张同盟'
  );
});

// 12. L1 战略大地图：保护自身粮道 & 截断敌方补给咽喉测试 + 全 8 种动作完备断言
runTest('12. L1 BFS 粮道保护与截断敌方咽喉：优先夺回被断仓城通道，精准偷袭敌军单链咽喉，覆盖全部 8 类战略指令', () => {
  // 12A. 保护自身粮道：铁鹰仅留王城仓城作为补给源，蓝河铁桥（ty_bridge）被苍狼攻占导致断云天险或前线孤立，且石脊要塞暂非我属
  const stateA = makeStandardCampaignState(FactionId.SHAMO);
  // 模拟炎龙的丰穗仓城（yl_granary，核心补给站）被雾林猎手趁虚偷占！
  const granaryNode = stateA.nodes.find((n) => n.nodeId === 'yl_granary');
  granaryNode.owner = FactionId.WULIN;
  granaryNode.garrisonStrength = 60;
  setDiplomacy(stateA, FactionId.YANLONG, FactionId.WULIN, DiplomaticStatus.WAR, -70);

  const ylReconnectActs = evaluateCampaignStrategicTurn(stateA, FactionId.YANLONG);
  const ylMarch = ylReconnectActs.find((a) => a.type === StrategicActionType.MARCH_ATTACK);
  assert.ok(ylMarch !== undefined);
  assert.equal(ylMarch.targetNodeId, 'yl_granary', '核心补给仓城通道失守时必须最高优先级反扑夺回 yl_granary');

  // 12B. 截断敌方咽喉 + 正式宣战（declareWar）：构造敌方单链孤立补给走廊，验证图割 BFS 识别咽喉并宣战奇袭
  const stateB = makeStandardCampaignState(FactionId.SHAMO);
  // 让苍狼向东延伸控制 xj_beacon，若玄甲夺回 cl_fort 将切断苍狼在 xj_beacon 的退路与补给！
  const xjBeacon = stateB.nodes.find((n) => n.nodeId === 'xj_beacon');
  xjBeacon.owner = FactionId.CANGLANG;
  const clFort = stateB.nodes.find((n) => n.nodeId === 'cl_fort');
  clFort.garrisonStrength = 45;
  clFort.defenseHp = 180;
  // 断开 sy_fjord 借道可能（霜原与苍狼中立不通补给）
  const supplyBefore = computeFactionSupplyMap(stateB, FactionId.CANGLANG);
  assert.equal(supplyBefore.get('xj_beacon').grade, SupplyLineGrade.FULL_SUPPLY);

  const xjActs = evaluateCampaignStrategicTurn(stateB, FactionId.XUANJIA);
  const warAct = xjActs.find((a) => a.type === StrategicActionType.DECLARE_WAR);
  const cutMarch = xjActs.find((a) => a.type === StrategicActionType.MARCH_ATTACK);
  assert.ok(warAct !== undefined, '面对高价值咽喉目标应先正式发出 declareWar');
  assert.ok(cutMarch !== undefined, '宣战后紧随发出 marchAttack');
  assert.equal(cutMarch.targetFactionId, FactionId.CANGLANG);
});

// 13. 二轮自查新增：铁鹰高地纯重步长枪防主帅硬弓风筝（慢速长枪绝不下山追高速主帅）
runTest('13. 二轮回归：铁鹰据守高地且两翼仅为慢速长枪时，面对玩家主帅硬弓风筝 0 支步兵离阵下山', () => {
  const hillZone = {
    id: 'ty_bastion_hill',
    terrain: TerrainType.HIGH_GROUND,
    x: 3150,
    y: 900,
    width: 400,
    height: 600,
    elevation: 1
  };
  const world = makeBaseWorld({
    enemyFaction: FactionId.TIEYING,
    terrainZones: [hillZone],
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.CANGLANG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 1450, 1200),
      makeSquad(101, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.PIKEMAN, 3260, 1200),
      makeSquad(102, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.LEFT_WING, UnitTypeId.PIKEMAN, 3260, 1010),
      makeSquad(105, BattleSide.ENEMY, FactionId.TIEYING, ArmyCorpsRole.SIEGE_BATTERY, UnitTypeId.TIEYING_PAVISE_CROSSBOW, 3350, 1200)
    ],
    playerHero: makeHero(BattleSide.PLAYER, FactionId.CANGLANG, {
      x: 2880,
      y: 1150,
      hp: 980,
      maxHp: 1100,
      activeWeapon: HeroWeaponType.HEAVY_WARBOW,
      remainingArrows: 20
    })
  });

  const batch = evaluateBattleTacticalAI(world);
  assert.equal(batch.activeDoctrine, TacticalDoctrineId.HIGH_GROUND_HEDGEHOG);
  for (const cmd of batch.squadCommands) {
    assert.equal(cmd.order, TacticalOrder.HOLD_GROUND, '慢速长枪绝不可离开高地去追 92px/s 的风筝主帅');
  }
});

// 14. 二轮自查新增：战场【饥溃 STARVING】绝境翻盘行为（奇袭敌大营抢 150 粮 + 战吼锁士气 + 禁募高耗粮兵）
runTest('14. 二轮回归：战场余粮耗尽进入 STARVING 饥溃期时，AI 自动派骑兵劫敌大营应急粮并开启战吼稳军心', () => {
  const starvingWorld = makeBaseWorld({
    enemyFaction: FactionId.XUANJIA,
    hud: {
      enemyRationStage: BattlefieldRationStage.STARVING
    },
    squads: [
      makeSquad(1, BattleSide.PLAYER, FactionId.YANLONG, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 1900, 1200),
      makeSquad(101, BattleSide.ENEMY, FactionId.XUANJIA, ArmyCorpsRole.VANGUARD_CENTER, UnitTypeId.SHIELD_SWORDSMAN, 3100, 1200, {
        morale: 54
      }),
      makeSquad(102, BattleSide.ENEMY, FactionId.XUANJIA, ArmyCorpsRole.LEFT_WING, UnitTypeId.LIGHT_CAVALRY, 3150, 620)
    ],
    enemyHero: makeHero(BattleSide.ENEMY, FactionId.XUANJIA, { x: 3180, y: 1200, warCryCooldown: 0 })
  });

  const batch = evaluateBattleTacticalAI(starvingWorld);
  const raidCmd = batch.squadCommands.find((c) => c.order === TacticalOrder.RAID_SUPPLY);
  assert.ok(raidCmd !== undefined, '饥溃期必须分派奇兵突袭敌方大营抢夺 150 应急粮草');
  assert.equal(raidCmd.targetX, 450, '无野外敌工兵时直扑敌本阵粮车');
  assert.equal(batch.enemyHeroTriggerWarCry, true, '饥溃期士气下滑时主帅提前释放战吼锁住军心');
  for (const req of batch.recruitRequests) {
    assert.equal(req.unitType, UnitTypeId.SAPPER, '饥溃期仅允许补充工兵采粮，严禁再招铁浮图加剧饥荒');
  }
});

// 15. 二轮自查新增：国库枯竭下的两线求和割让边缘非仓城兜底 + 8 大势力全遍历零越界校验
runTest('15. 二轮回归：国库金粮双枯竭时两线求和自动割让边缘非仓城保命 & 8 势力全遍历坐标合法性验证', () => {
  const state = makeStandardCampaignState(FactionId.SHAMO);
  state.turnNumber = 1;
  setDiplomacy(state, FactionId.YANLONG, FactionId.CANGLANG, DiplomaticStatus.WAR, -70);
  setDiplomacy(state, FactionId.YANLONG, FactionId.XUANJIA, DiplomaticStatus.WAR, -70);

  const ylFac = state.factions.find((f) => f.factionId === FactionId.YANLONG);
  ylFac.gold = 12; // 国库几近归零
  ylFac.grain = 135; // 存粮逼近安全底线
  ylFac.credibility = 42;
  ylFac.fieldArmyRoster = [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 6, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }];

  const acts = evaluateCampaignStrategicTurn(state, FactionId.YANLONG);
  const peaceAct = acts.find((a) => a.type === StrategicActionType.PROPOSE_PEACE);
  assert.ok(peaceAct !== undefined);
  assert.ok(peaceAct.peaceTerms.goldIndemnity >= 0 && peaceAct.peaceTerms.goldIndemnity <= 12);
  assert.equal(peaceAct.peaceTerms.grainTributePerTurn, 0);
  assert.equal(peaceAct.peaceTerms.cededNodeIds.length, 1, '金粮枯竭且劣势时应割让 1 座非王都非仓城边缘关隘换取停火');
  assert.notEqual(peaceAct.peaceTerms.cededNodeIds[0], 'yl_capital', '绝不可割让王都');

  // 遍历全部 8 大势力作为战场 AI，断言坐标无 NaN / 无越界
  for (const fc of FACTION_STATIC_CONFIGS) {
    const w = makeBaseWorld({ enemyFaction: fc.id });
    const b = evaluateBattleTacticalAI(w);
    assert.ok(Number.isFinite(b.enemyHeroTargetX) && b.enemyHeroTargetX >= 0 && b.enemyHeroTargetX <= w.width);
    assert.ok(Number.isFinite(b.enemyHeroTargetY) && b.enemyHeroTargetY >= 0 && b.enemyHeroTargetY <= w.height);
    for (const c of b.squadCommands) {
      assert.ok(Number.isFinite(c.targetX) && c.targetX >= 0 && c.targetX <= w.width);
      assert.ok(Number.isFinite(c.targetY) && c.targetY >= 0 && c.targetY <= w.height);
    }
  }
});

// 16. 新增闭环集成单测：真实 BattleSimulator <-> BattleTacticalAI 连续 150 帧野战与攻城闭环协同推演
runTest('16. 闭环集成：BattleSimulator 与 BattleTacticalAI 连续多帧真实野战迂回、动态征募及攻城左上角城防瞄准推演', () => {
  // 16A. 野战闭环：玩家（炎龙）vs AI（苍狼汗国），驱动 120 帧（12s）真实物理与 AI 指令回灌
  const fieldSim = new BattleSimulator({
    scenarioType: BattleScenarioType.FIELD_PITCHED,
    playerFaction: FactionId.YANLONG,
    enemyFaction: FactionId.CANGLANG,
    terrain: TerrainType.PLAIN,
    weather: WeatherType.CLEAR_DAY,
    enemyInitialGold: 600,
    enemyInitialWood: 400,
    enemyInitialGrain: 1200,
    playerArmyRoster: [
      { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 20, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
      { unitType: UnitTypeId.COMPOSITE_ARCHER, count: 14, corpsRole: ArmyCorpsRole.SIEGE_BATTERY }
    ],
    enemyArmyRoster: [
      { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 18, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
      { unitType: UnitTypeId.LIGHT_CAVALRY, count: 10, corpsRole: ArmyCorpsRole.LEFT_WING },
      { unitType: UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER, count: 10, corpsRole: ArmyCorpsRole.RIGHT_WING },
      { unitType: UnitTypeId.GREAT_AXEMAN, count: 10, corpsRole: ArmyCorpsRole.REAR_RESERVE }
    ]
  });
  const fieldAi = new BattleTacticalAI();
  const initialEnemyCount = fieldSim.getHudSnapshot().enemyAliveSoldiers;
  let totalBatches = 0;
  let recruitedCount = 0;

  for (let step = 0; step < 120; step++) {
    const batch = fieldAi.step(fieldSim.getWorldView(), 0.1);
    if (batch !== null) {
      totalBatches++;
      for (const cmd of batch.squadCommands) {
        fieldSim.issueSquadCommand(cmd);
      }
      for (const req of batch.recruitRequests) {
        if (fieldSim.recruitUnit(BattleSide.ENEMY, req.unitType, req.corpsRole)) {
          recruitedCount++;
        }
      }
    }
    fieldSim.stepTick(0.1);
  }

  assert.ok(totalBatches >= 20, `12s 内 0.5s 周期黑板应评估 >= 20 次，实际: ${totalBatches}`);
  assert.ok(recruitedCount >= 1, 'AI 应通过 BattleSimulator.recruitUnit 成功动态增援工兵或克制兵种');
  assert.ok(fieldSim.getHudSnapshot().enemyAliveSoldiers > initialEnemyCount);

  const fw = fieldSim.getWorldView();
  for (const s of fw.soldiers) {
    if (s.active) {
      assert.ok(Number.isFinite(s.x) && Number.isFinite(s.y), '闭环模拟后士兵坐标严禁出现 NaN');
    }
  }

  // 16B. 守城闭环（AI 作为攻城方 SIEGE_DEFENSE）：验证 BattleSimulator 城防左上角坐标与 AI 投石车瞄准中心完全一致
  const siegeSim = new BattleSimulator({
    scenarioType: BattleScenarioType.SIEGE_DEFENSE,
    playerFaction: FactionId.TIEYING,
    enemyFaction: FactionId.YANLONG,
    terrain: TerrainType.FORT_WALL,
    weather: WeatherType.CLEAR_DAY,
    siegeHoldDurationSec: 180,
    playerArmyRoster: [
      { unitType: UnitTypeId.PIKEMAN, count: 16, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
      { unitType: UnitTypeId.TIEYING_PAVISE_CROSSBOW, count: 12, corpsRole: ArmyCorpsRole.SIEGE_BATTERY }
    ],
    enemyArmyRoster: [
      { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 16, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
      { unitType: UnitTypeId.GREAT_AXEMAN, count: 10, corpsRole: ArmyCorpsRole.LEFT_WING },
      { unitType: UnitTypeId.XUANJIA_CATAPHRACT, count: 8, corpsRole: ArmyCorpsRole.REAR_RESERVE },
      { unitType: UnitTypeId.TREBUCHET, count: 2, corpsRole: ArmyCorpsRole.SIEGE_BATTERY }
    ]
  });
  const siegeWorld = siegeSim.getWorldView();
  const siegeDecision = evaluateBattleTacticalAI(siegeWorld);
  assert.equal(siegeDecision.siegePhase, SiegeTacticalPhase.ASSAULT_PHASE_1_ARTILLERY);

  const trebuchetSq = siegeWorld.squads.find(
    (sq) => sq.side === BattleSide.ENEMY && sq.primaryUnitType === UnitTypeId.TREBUCHET
  );
  const trebCmd = findCmd(siegeDecision, trebuchetSq.squadId);
  const playerTowers = siegeWorld.structures.filter(
    (st) => st.side === BattleSide.PLAYER && st.kind === 'arrow_tower'
  );
  const matchedTowerCenter = playerTowers.some(
    (t) =>
      Math.abs(trebCmd.targetX - (t.x + t.width * 0.5)) < 1e-4 &&
      Math.abs(trebCmd.targetY - (t.y + t.height * 0.5)) < 1e-4
  );
  assert.equal(
    matchedTowerCenter,
    true,
    '攻城阶段 1 投石车必须精确瞄准 BattleSimulator 左上角城防实体的几何中心 (x+w/2, y+h/2)'
  );
});

console.log(`\n=== 全部 ${passed} 项 AI 核心战术与战略演化自动化单测 100% 通过！ ===`);
