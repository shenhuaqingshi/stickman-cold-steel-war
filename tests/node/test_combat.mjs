import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';

import { GameConstants } from '../../entry/src/main/ets/common/GameConstants.ets';
import {
  ArmyCorpsRole,
  BattleControlMode,
  BattlefieldRationStage,
  BattleOutcomeReason,
  BattleScenarioType,
  BattleSide,
  EncirclementState,
  FactionId,
  FormationType,
  HeroSkillId,
  HeroVitalState,
  HeroWeaponType,
  TacticalOrder,
  TerrainType,
  UnitActionState,
  UnitCategory,
  UnitTypeId,
  WeatherType
} from '../../entry/src/main/ets/core/CoreContracts.ets';
import {
  applySquadMoraleAndHysteresis,
  BattleSimulator,
  canObserverSpotTarget,
  classifyEncirclementFromMask,
  computeAttackIncomingAngleDeg,
  computeDirectionalModifiers,
  computeEffectiveArmor,
  computeFinalHitDamage,
  computeHyperbolicMitigation,
  computeObserverVisionRadius,
  computeRangedShieldMultiplier,
  DamageFormulaParams,
  DirectionalCombatModifiers,
  evaluateRationStage,
  hasPinceredOctantPair,
  isBracedAntiCavalryTriggered,
  SpatialHashGrid
} from '../../entry/src/main/ets/core/combat/BattleSimulator.ets';
import { GameSessionCoordinator } from '../../entry/src/main/ets/core/session/GameSessionCoordinator.ets';

let passedTests = 0;

function runTest(name, fn) {
  fn();
  passedTests++;
  console.log(`  [PASS] ${passedTests}. ${name}`);
}

function approxEqual(actual, expected, eps = 1e-4, msg = '') {
  assert.ok(
    Math.abs(actual - expected) <= eps,
    `${msg} expected ~${expected}, got ${actual} (diff=${Math.abs(actual - expected)})`
  );
}

function makeBaseConfig(overrides = {}) {
  return {
    scenarioType: BattleScenarioType.FIELD_PITCHED,
    playerFaction: FactionId.YANLONG,
    enemyFaction: FactionId.CANGLANG,
    terrain: TerrainType.PLAIN,
    weather: WeatherType.CLEAR_DAY,
    playerInitialGrain: GameConstants.BATTLE_INIT_GRAIN,
    enemyInitialGrain: GameConstants.BATTLE_INIT_GRAIN,
    playerMoraleModifier: 0,
    enemyMoraleModifier: 0,
    playerArmyRoster: [],
    enemyArmyRoster: [],
    campaignNodeId: 'yl_capital',
    siegeHoldDurationSec: 180,
    ...overrides
  };
}

console.log('=== 鸿蒙平板冷兵器大战 · 第 2 步战斗物理与主帅核心引擎单测 ===');

// ---------------------------------------------------------------------------
// 1. 对象池预分配容量与均匀空间哈希网格单测
// ---------------------------------------------------------------------------
runTest('预分配对象池容量与 SpatialHashGrid (120px, Int32Array 静态链表) 精确查询', () => {
  const sim = new BattleSimulator(makeBaseConfig());
  const world = sim.getWorldView();

  assert.equal(world.width, 4800);
  assert.equal(world.height, 2400);
  assert.equal(world.soldiers.length, 600);
  assert.equal(world.projectiles.length, 400);
  assert.equal(world.corpses.length, 150);
  assert.equal(world.hitEffects.length, 120);
  assert.ok(world.hud.playerAliveSoldiers >= 100, '默认开局玩家满编百人大军');
  assert.ok(world.hud.enemyAliveSoldiers >= 100, '默认开局敌军满编百人大军');

  const grid = sim.getSpatialGrid();
  assert.equal(grid.cellSize, 120);
  assert.equal(grid.cols, 40);
  assert.equal(grid.rows, 20);
  assert.equal(grid.totalCells, 800);
  assert.ok(grid.cellHead instanceof Int32Array);
  assert.ok(grid.unitNext instanceof Int32Array);

  const outBuf = new Int32Array(600);
  const cx = 1180;
  const cy = 1200;
  const r = 240;
  const gridHits = grid.queryRadius(world.soldiers, cx, cy, r, outBuf);

  let bruteHits = 0;
  for (let i = 0; i < world.soldiers.length; i++) {
    const s = world.soldiers[i];
    if (s.active && s.hp > 0) {
      const dx = s.x - cx;
      const dy = s.y - cy;
      if (dx * dx + dy * dy <= r * r) {
        bruteHits++;
      }
    }
  }
  assert.equal(gridHits, bruteHits, '空间哈希网格查询结果必须与暴力几何距离完全一致');
  assert.ok(gridHits > 0);
});

// ---------------------------------------------------------------------------
// 2. 双曲护甲减伤模型与保底伤害 2
// ---------------------------------------------------------------------------
runTest('双曲护甲减伤 A_eff/(A_eff+50)、重斧破甲与最低伤害 2 保底', () => {
  approxEqual(computeHyperbolicMitigation(0), 0.0);
  approxEqual(computeHyperbolicMitigation(50), 0.5);
  approxEqual(computeHyperbolicMitigation(150), 0.75);

  // 巨斧兵 65% 破甲打 100 护甲：A_eff = 35 -> mit = 35/85
  const effArmor = computeEffectiveArmor(100, 0.65, 0);
  approxEqual(effArmor, 35.0);

  const p = new DamageFormulaParams();
  p.baseAttack = 1;
  p.targetArmor = 500;
  p.attackerArmorPen = 0;
  approxEqual(computeFinalHitDamage(p), 2.0, 1e-6, '超高护甲刮痧保底必须为 2');

  p.reset();
  p.baseAttack = 40;
  p.targetArmor = 50;
  p.attackerArmorPen = 0;
  approxEqual(computeFinalHitDamage(p), 20.0, 1e-6, '50 点有效护甲减伤 50%');
});

// ---------------------------------------------------------------------------
// 3. 正面盾牌远程格挡、圆阵 360° 防御与侧背增伤模型
// ---------------------------------------------------------------------------
runTest('正面盾牌远程格挡（<=60°全额、60~120°减半、>120°归零）及圆阵 360° 免侧背惩罚', () => {
  // 刀盾步兵 55% 盾格挡
  approxEqual(computeRangedShieldMultiplier(0.55, 30, false, false, false), 0.45);
  approxEqual(computeRangedShieldMultiplier(0.55, 90, false, false, false), 1 - 0.275);
  approxEqual(computeRangedShieldMultiplier(0.55, 150, false, false, false), 1.0);
  approxEqual(computeRangedShieldMultiplier(0.55, 175, true, false, false), 0.45, 1e-6, '圆阵背向享全额盾防');
  approxEqual(computeRangedShieldMultiplier(0.60, 180, false, true, false), 0.40, 1e-6, '铁鹰神弩换弹转身背盾享60%减伤');
  approxEqual(computeRangedShieldMultiplier(0.55, 10, false, false, true), 1.0, 1e-6, '溃逃丢盾归零');

  const dir = new DirectionalCombatModifiers();
  computeDirectionalModifiers(45, false, false, dir);
  approxEqual(dir.damageMult, 1.0);
  approxEqual(dir.moraleShockMult, 1.0);
  assert.equal(dir.disableShieldAndBrace, false);

  computeDirectionalModifiers(100, false, false, dir);
  approxEqual(dir.damageMult, 1.25);
  approxEqual(dir.moraleShockMult, 1.5);
  assert.equal(dir.disableShieldAndBrace, false);

  computeDirectionalModifiers(160, false, false, dir);
  approxEqual(dir.damageMult, 1.45);
  approxEqual(dir.moraleShockMult, 2.0);
  assert.equal(dir.disableShieldAndBrace, true);

  computeDirectionalModifiers(170, true, false, dir);
  approxEqual(dir.damageMult, 1.0);
  approxEqual(dir.moraleShockMult, 1.0);
  assert.equal(dir.disableShieldAndBrace, false);
});

// ---------------------------------------------------------------------------
// 4. 长枪架枪迎骑 +30% 动能破甲与强制停马 & 背击失效测试
// ---------------------------------------------------------------------------
runTest('长枪/神机重卫正面架枪迎骑享 antiCavalryMultiplier + 30% 动能破甲并停马，背击失效', () => {
  assert.equal(
    isBracedAntiCavalryTriggered(
      UnitTypeId.PIKEMAN,
      UnitActionState.IDLE_READY,
      0,
      58,
      false,
      25,
      false,
      true
    ),
    true
  );
  assert.equal(
    isBracedAntiCavalryTriggered(
      UnitTypeId.PIKEMAN,
      UnitActionState.IDLE_READY,
      0,
      58,
      false,
      160,
      false,
      true
    ),
    false,
    '背向遭袭架枪必须失效'
  );

  // 验证长枪兵 (atk=20, pen=0.25, antiCav=3.2) 正面架枪迎击铁浮图 (armor=68)：
  // 总破甲 = 0.25 + 0.30 = 0.55 -> A_eff = 68 * 0.45 = 30.6 -> mit = 30.6 / 80.6
  const p = new DamageFormulaParams();
  p.baseAttack = 20;
  p.targetArmor = 68;
  p.attackerArmorPen = 0.25;
  p.bonusArmorPen = GameConstants.BRACED_ANTICAV_BONUS_PEN;
  p.antiCavMult = 3.2;
  p.incomingAngleDeg = 15;
  const frontBraceDmg = computeFinalHitDamage(p);
  const expectedEffArmor = 68 * 0.45;
  const expectedDmg = 20 * 3.2 * (1 - expectedEffArmor / (expectedEffArmor + 50));
  approxEqual(frontBraceDmg, expectedDmg, 1e-4);

  // 若遭遇背击 (>135°)，反骑倍率与动能破甲归零但承受 1.45x 背击
  p.incomingAngleDeg = 165;
  const rearBrokenDmg = computeFinalHitDamage(p);
  assert.ok(frontBraceDmg > rearBrokenDmg * 2.0, '正面架枪穿刺伤害远高于背击失效态');

  // 实战模拟测试：冲锋游骑兵正撞架枪长枪兵被强制停马清空冲锋动量
  const sim = new BattleSimulator(
    makeBaseConfig({
      playerArmyRoster: [{ unitType: UnitTypeId.PIKEMAN, count: 6, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.LIGHT_CAVALRY, count: 2, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  const w = sim.getWorldView();
  const pike = w.soldiers.find((s) => s.active && s.side === BattleSide.PLAYER);
  const cav = w.soldiers.find((s) => s.active && s.side === BattleSide.ENEMY);
  pike.x = 2000;
  pike.y = 1200;
  pike.facingRad = 0;
  pike.attackCooldown = 0;
  cav.x = 2036;
  cav.y = 1200;
  cav.vx = -115;
  cav.vy = 0;
  cav.facingRad = Math.PI;
  cav.chargeRunTime = 3.0;
  const cavHpBefore = cav.hp;

  sim.stepTick(0.033);
  assert.ok(cav.hp < cavHpBefore - 35, `骑兵撞枪阵应受重创: ${cavHpBefore} -> ${cav.hp}`);
  assert.equal(cav.chargeRunTime, 0, '冲锋动量必须被清空');
  assert.ok(cav.chargeCooldown >= 7.5, '骑兵进入 8s 冲锋重整冷却');
  assert.ok(cav.staggerTimer > 0, '骑兵被停马陷入硬直');
});

// ---------------------------------------------------------------------------
// 5. 八象限受敌扫描：钳形夹击 PINCERED 与五扇区铁桶合围 ENCIRCLED
// ---------------------------------------------------------------------------
runTest('八象限受敌扇区：钳形夹击 PINCERED（失方阵护甲、-2.2/s）与铁桶合围 ENCIRCLED（锁45上限、-4.8/s，圆阵减半）', () => {
  // 扇区 2 (+90°) 与扇区 6 (-90°) 同时受敌 -> 夹角 180° >= 120°，非正面扇区 -> PINCERED
  const pincerMask = (1 << 2) | (1 << 6);
  assert.equal(hasPinceredOctantPair(pincerMask), true);
  assert.equal(classifyEncirclementFromMask(pincerMask, 4), EncirclementState.PINCERED);

  // >= 5 个扇区受敌且退路扇区 4 被堵死 -> ENCIRCLED
  const encircleMask = (1 << 0) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 6);
  assert.equal(classifyEncirclementFromMask(encircleMask, 4), EncirclementState.ENCIRCLED);

  // 实战模拟器内验证 0.5s 八象限扫描、锁 45 士气上限及圆阵流失减半
  const sim = new BattleSimulator(
    makeBaseConfig({
      playerArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 4, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 6, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  const w = sim.getWorldView();
  const pSq = w.squads.find((sq) => sq.side === BattleSide.PLAYER);
  const pUnits = w.soldiers.filter((s) => s.active && s.side === BattleSide.PLAYER);
  const eUnits = w.soldiers.filter((s) => s.active && s.side === BattleSide.ENEMY);

  // 将玩家小队置于 (2000, 1200)，本阵在左侧 (x~450，退路在正后方 PI -> 扇区 4)
  for (const u of pUnits) {
    u.x = 2000;
    u.y = 1200;
    u.facingRad = 0;
  }
  // 将玩家主帅移远避免 350px 帅旗光环干扰精确士气衰减率测量
  w.playerHero.x = 450;
  w.playerHero.y = 400;

  // 在周围 100px (<160px) 布置 5 个扇区敌军（含正后退路扇区 4）
  const angles = [0, Math.PI * 0.5, Math.PI * 0.75, Math.PI, -Math.PI * 0.5];
  for (let i = 0; i < 5; i++) {
    eUnits[i].x = 2000 + Math.cos(angles[i]) * 105;
    eUnits[i].y = 1200 + Math.sin(angles[i]) * 105;
  }
  eUnits[5].x = 3800;
  eUnits[5].y = 1200;

  pSq.facingRad = 0;
  pSq.morale = 80;
  sim.issueSquadCommand({ squadIds: [pSq.squadId], order: TacticalOrder.HOLD_GROUND });
  sim.stepTick(0.05); // 首步后累计触发八象限扫描
  sim.stepTick(0.50);

  assert.equal(pSq.encirclement, EncirclementState.ENCIRCLED, '五扇区堵退路应判定为铁桶合围');
  assert.ok(pSq.morale <= 45.0, `铁桶合围士气上限必须锁死 45，当前: ${pSq.morale}`);

  // 对比方阵与圆阵在铁桶合围下的士气流失速度（圆阵减半）
  pSq.morale = 44.0;
  for (const e of eUnits) {
    e.attackCooldown = 10.0; // 暂停普攻仅测纯合围士气雪崩率
  }
  sim.stepTick(0.10);
  const lossNormal = 44.0 - pSq.morale;
  approxEqual(lossNormal, 4.8 * 0.10, 0.05, '常规阵型铁桶合围每秒掉 4.8 士气');

  sim.issueSquadCommand({ squadIds: [pSq.squadId], formation: FormationType.CIRCLE_DEFENSE });
  pSq.morale = 44.0;
  sim.stepTick(0.10);
  const lossCircle = 44.0 - pSq.morale;
  approxEqual(lossCircle, 2.4 * 0.10, 0.05, '圆阵铁桶合围士气流失减半为 2.4/s');
});

// ---------------------------------------------------------------------------
// 6. 渡河“半渡而击”（30%~80% 涉水享 1.20x 易伤 + 一次性 -12 士气震慑）
// ---------------------------------------------------------------------------
runTest('渡河半渡而击：30%~80% 成员处于 RIVER_FORD 时受击触发 1.20x 易伤与一次性 -12 士气震慑', () => {
  const sim = new BattleSimulator(
    makeBaseConfig({
      terrain: TerrainType.RIVER_FORD,
      playerArmyRoster: [{ unitType: UnitTypeId.COMPOSITE_ARCHER, count: 1, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.PIKEMAN, count: 4, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  const w = sim.getWorldView();
  const fordZone = w.terrainZones.find((z) => z.terrain === TerrainType.RIVER_FORD);
  assert.ok(fordZone !== undefined, '河谷战场包含 RIVER_FORD 地形区');

  const eSq = w.squads.find((sq) => sq.side === BattleSide.ENEMY);
  const enemies = w.soldiers.filter((s) => s.active && s.side === BattleSide.ENEMY);
  // 2 名敌兵在浅滩内，2 名在岸上 -> fordRatio = 0.50 (介于 30%~80%)
  enemies[0].x = fordZone.x + 50;
  enemies[0].y = fordZone.y + 120;
  enemies[1].x = fordZone.x + 60;
  enemies[1].y = fordZone.y + 140;
  enemies[2].x = fordZone.x + fordZone.width + 80;
  enemies[2].y = fordZone.y + 120;
  enemies[3].x = fordZone.x + fordZone.width + 95;
  enemies[3].y = fordZone.y + 140;

  const archer = w.soldiers.find((s) => s.active && s.side === BattleSide.PLAYER);
  archer.x = enemies[2].x - 160;
  archer.y = enemies[2].y;
  archer.attackCooldown = 0;
  eSq.morale = 80;

  sim.stepTick(0.05);
  approxEqual(eSq.fordRatio, 0.50, 0.01, '涉水比例应为 50%');

  // 推进箭矢命中岸上成员 enemies[2]
  for (let t = 0; t < 15; t++) {
    sim.stepTick(0.05);
  }
  assert.equal(eSq.halfFordShockApplied, true, '半渡而击一次性 -12 士气震慑必须触发');
  assert.ok(eSq.morale <= 70.0, `半渡而击受震慑后士气显著下跌: ${eSq.morale}`);
});

// ---------------------------------------------------------------------------
// 7. 士气迟滞防抖环与斩杀执旗官惩罚测试
// ---------------------------------------------------------------------------
runTest('士气迟滞环（<20 溃逃、回升至 28 仍溃、>=32 脱战重整）与斩杀执旗官 -15 士气及 12s 失阵型加成', () => {
  const sim = new BattleSimulator(
    makeBaseConfig({
      playerArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 5, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 2, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  const w = sim.getWorldView();
  const sq = w.squads.find((s) => s.side === BattleSide.PLAYER);

  sq.threatOctantMask = 0;
  sq.morale = 25;
  applySquadMoraleAndHysteresis(sq, -8, false, false); // 17 < 20 -> 溃逃
  assert.equal(sq.isRouting, true);

  // 溃逃期间下达战术指令必须被忽略
  const prevOrder = sq.order;
  sim.issueSquadCommand({ squadIds: [sq.squadId], order: TacticalOrder.HOLD_GROUND });
  assert.equal(sq.order, prevOrder, '溃逃部队脱离指挥控制');

  // 回升到 29 (< 32 迟滞阈值)：依然维持溃逃
  applySquadMoraleAndHysteresis(sq, 12, false, false); // 29
  assert.equal(sq.isRouting, true, '士气 29 未达 32 迟滞阈值，不得提前恢复控制');

  // 脱战状态回升至 33 (>= 32)：解除溃逃重整归建！
  applySquadMoraleAndHysteresis(sq, 4, false, false); // 33
  assert.equal(sq.isRouting, false, '脱战回升至 >= 32 解除溃逃');

  // 测试斩杀敌军执旗官
  const eSq = w.squads.find((s) => s.side === BattleSide.ENEMY);
  const bannerEnemy = w.soldiers.find((s) => s.active && s.side === BattleSide.ENEMY && s.isBannerBearer);
  assert.ok(bannerEnemy !== undefined, '敌军军团应配有执旗官');
  eSq.morale = 80;

  // 玩家主帅直接贴身一刀斩杀残血执旗官
  bannerEnemy.hp = 5;
  w.playerHero.x = bannerEnemy.x - 20;
  w.playerHero.y = bannerEnemy.y;
  w.playerHero.facingRad = 0;
  assert.equal(sim.toggleControlMode(), true);
  sim.updateHeroInput({ moveX: 0, moveY: 0, aimX: 1, aimY: 0, isAttackPressed: true, isBlockHeld: false });
  sim.stepTick(0.05);

  assert.equal(eSq.bannerAlive, false, '执旗官已阵亡');
  assert.ok(eSq.bannerLostPenaltyTimer >= 11.5, '丧失阵型加成计时器激活 12s');
  assert.ok(eSq.morale <= 65.1, `斩旗触发敌军团 -15 士气暴跌: ${eSq.morale}`);
  assert.ok(w.corpses.some((c) => c.active && c.isBrokenBanner), '遗骸池生成折断旌旗贴花');
});

// ---------------------------------------------------------------------------
// 8. 全部 8 大势力与专属王牌兵种独有机制全覆盖测试
// ---------------------------------------------------------------------------
runTest('8 大势力专属机制验证（炎龙火雷、苍狼边退边射、马穆鲁克惊马、巨熊免击退震飞、雾林破隐毒暴、铁浮图刷CD、狂战锁士气吸血）', () => {
  // 8.1 炎龙神机重卫首接敌投掷火雷 (-12 士气)
  {
    const sim = new BattleSimulator(
      makeBaseConfig({
        playerFaction: FactionId.YANLONG,
        playerArmyRoster: [{ unitType: UnitTypeId.YANLONG_HALBERD_GRENADIER, count: 1, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
        enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 3, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
      })
    );
    const w = sim.getWorldView();
    const gren = w.soldiers.find((s) => s.active && s.side === BattleSide.PLAYER);
    const eSq = w.squads.find((sq) => sq.side === BattleSide.ENEMY);
    const enemies = w.soldiers.filter((s) => s.active && s.side === BattleSide.ENEMY);
    gren.x = 2000;
    gren.y = 1200;
    gren.attackCooldown = 0;
    for (const e of enemies) {
      e.x = 2100;
      e.y = 1200;
    }
    eSq.morale = 80;
    sim.stepTick(0.05);
    assert.equal(gren.grenadeUsed, true, '神机重卫接敌投出震天火雷');
    for (let k = 0; k < 15; k++) {
      sim.stepTick(0.05);
    }
    assert.ok(eSq.morale < 68.5, `火雷爆炸削减敌军 12 点士气: ${eSq.morale}`);
  }

  // 8.2 苍狼怯薛边退边射 + 禁造配重投石车
  {
    const sim = new BattleSimulator(
      makeBaseConfig({
        playerFaction: FactionId.CANGLANG,
        playerArmyRoster: [{ unitType: UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER, count: 1, corpsRole: ArmyCorpsRole.LEFT_WING }],
        enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 1, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
      })
    );
    assert.equal(
      sim.recruitUnit(BattleSide.PLAYER, UnitTypeId.TREBUCHET, ArmyCorpsRole.SIEGE_BATTERY),
      false,
      '苍狼汗国严禁招募配重投石车'
    );
    const w = sim.getWorldView();
    const keshig = w.soldiers.find((s) => s.active && s.side === BattleSide.PLAYER);
    const enemy = w.soldiers.find((s) => s.active && s.side === BattleSide.ENEMY);
    keshig.x = 2000;
    keshig.y = 1200;
    keshig.attackCooldown = 0;
    enemy.x = 2100;
    enemy.y = 1200;
    sim.stepTick(0.05);
    assert.ok(keshig.x < 2000, '怯薛骑射近敌时自动后撤拉扯');
    assert.ok(w.projectiles.some((p) => p.active && p.side === BattleSide.PLAYER), '后撤同时转身射箭');
  }

  // 8.3 沙漠商盟马穆鲁克 160px 惊马光环（敌骑减速 25%）
  {
    const sim = new BattleSimulator(
      makeBaseConfig({
        playerFaction: FactionId.SHAMO,
        enemyFaction: FactionId.CANGLANG,
        playerArmyRoster: [{ unitType: UnitTypeId.SHAMO_MAMELUKE_CAMEL, count: 1, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
        enemyArmyRoster: [{ unitType: UnitTypeId.LIGHT_CAVALRY, count: 2, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
      })
    );
    const w = sim.getWorldView();
    const camel = w.soldiers.find((s) => s.active && s.side === BattleSide.PLAYER);
    const cavs = w.soldiers.filter((s) => s.active && s.side === BattleSide.ENEMY);
    camel.x = 1800;
    camel.y = 1200;
    // cavs[0] 在 120px 内受惊，cavs[1] 在 500px 外正常
    cavs[0].x = 1910;
    cavs[0].y = 1200;
    cavs[1].x = 2500;
    cavs[1].y = 1200;
    sim.stepTick(0.05);
    const spdSpooked = Math.hypot(cavs[0].vx, cavs[0].vy);
    const spdNormal = Math.hypot(cavs[1].vx, cavs[1].vy);
    assert.ok(spdSpooked < spdNormal * 0.82, `惊马光环内敌骑显著减速: ${spdSpooked} vs ${spdNormal}`);
  }

  // 8.4 霜原巨熊免疫普通击退 + 扇形震飞；雾林影袭潜行 180% 暴击毒减速
  {
    const sim = new BattleSimulator(
      makeBaseConfig({
        playerFaction: FactionId.SHUANGYUAN,
        enemyFaction: FactionId.WULIN,
        playerArmyRoster: [{ unitType: UnitTypeId.SHUANGYUAN_GIANT_BREAKER, count: 1, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
        enemyArmyRoster: [
          { unitType: UnitTypeId.WULIN_SHADOW_SNIPER, count: 1, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
          { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 2, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }
        ]
      })
    );
    const w = sim.getWorldView();
    const bear = w.soldiers.find((s) => s.active && s.unitType === UnitTypeId.SHUANGYUAN_GIANT_BREAKER);
    assert.equal(bear.maxHp, Math.round(620 * 1.15), '霜原熊族享 +15% 生命上限');

    const sniper = w.soldiers.find((s) => s.active && s.unitType === UnitTypeId.WULIN_SHADOW_SNIPER);
    assert.equal(sniper.isStealthed, true, '雾林影袭开局潜行');
    bear.x = 2000;
    bear.y = 1200;
    sniper.x = 2220;
    sniper.y = 1200;
    sniper.attackCooldown = 0;

    const eFoot = w.soldiers.filter((s) => s.active && s.unitType === UnitTypeId.SHIELD_SWORDSMAN);
    eFoot[0].x = 2026;
    eFoot[0].y = 1195;
    eFoot[1].x = 2028;
    eFoot[1].y = 1210;
    bear.attackCooldown = 0;

    sim.stepTick(0.05);
    assert.equal(sniper.isStealthed, false, '开火后破隐');
    const poisonProj = w.projectiles.find((p) => p.active && p.side === BattleSide.ENEMY);
    assert.ok(poisonProj !== undefined && poisonProj.applyPoison === true, '破隐首箭附带神经毒减速');
    assert.ok(eFoot[0].x > 2040 && eFoot[1].x > 2040, '巨熊重锤扇形同时震飞前排多名敌兵');

    for (let k = 0; k < 12; k++) {
      sim.stepTick(0.05);
    }
    assert.ok(bear.poisonTimer > 0, '目标中箭后挂上 3s 毒减速计时');
  }

  // 8.5 玄甲铁浮图击溃敌队重置 50% 冲锋冷却 + 血月狂战锁士气 >=50 与损血加速吸血
  {
    const sim = new BattleSimulator(
      makeBaseConfig({
        playerFaction: FactionId.XUANJIA,
        enemyFaction: FactionId.XUEYUE,
        playerArmyRoster: [{ unitType: UnitTypeId.XUANJIA_CATAPHRACT, count: 1, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
        enemyArmyRoster: [
          { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 1, corpsRole: ArmyCorpsRole.LEFT_WING },
          { unitType: UnitTypeId.XUEYUE_WARDRUM_BERSERKER, count: 2, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }
        ]
      })
    );
    const w = sim.getWorldView();
    const cata = w.soldiers.find((s) => s.active && s.unitType === UnitTypeId.XUANJIA_CATAPHRACT);
    const weakEnemy = w.soldiers.find((s) => s.active && s.unitType === UnitTypeId.SHIELD_SWORDSMAN);
    const weakSq = w.squads[weakEnemy.squadId];
    const berserker = w.soldiers.find((s) => s.active && s.unitType === UnitTypeId.XUEYUE_WARDRUM_BERSERKER);
    const berserkSq = w.squads[berserker.squadId];

    // 验证狂战士士气永远锁 >= 50 不溃
    applySquadMoraleAndHysteresis(berserkSq, -99, false, false);
    assert.equal(berserkSq.morale, 50, '血月狂战祭团士气锁定 >= 50');
    assert.equal(berserkSq.isRouting, false);

    // 验证狂战士残血加速与近战吸血
    berserker.hp = 60; // < 50% HP
    berserker.x = 1990;
    berserker.y = 1200;
    berserker.attackCooldown = 0;
    cata.x = 2012;
    cata.y = 1200;
    cata.chargeCooldown = 8.0;

    // 令旁侧普通敌兵士气跌破 20 触发溃逃，验证铁浮图重置 50% 冲锋 CD
    weakEnemy.x = 2020;
    weakEnemy.y = 1215;
    weakSq.centerX = 2020;
    weakSq.centerY = 1215;
    weakSq.morale = 20.5;
    weakEnemy.hp = 200;
    cata.attackCooldown = 0;

    sim.stepTick(0.05);
    assert.ok(berserker.hp > 60, `血月狂战士近战命中吸血恢复生命: 60 -> ${berserker.hp}`);
    assert.ok(berserker.attackCooldown < 0.80, `狂战士损血攻速加快，攻击间隔缩短至: ${berserker.attackCooldown}`);

    // 触发普通敌队溃逃
    weakSq.morale = 21;
    cata.chargeCooldown = 8.0;
    weakEnemy.x = 2015;
    weakEnemy.y = 1200;
    // 用火炮/重创令 weakSq 跌破 20
    w.playerHero.x = 2015;
    w.playerHero.y = 1200;
    assert.equal(sim.triggerHeroSkill(HeroSkillId.GRAND_WAR_CRY), true); // -10 敌军士气 -> 11 < 20 溃逃！
    // 同时测试击杀/士气崩溃时铁浮图冷却缩短（此处通过普攻打崩另一测试）
  }

  // 单独精确断言铁浮图击溃重置 50% 冲锋 CD
  {
    const sim2 = new BattleSimulator(
      makeBaseConfig({
        playerFaction: FactionId.XUANJIA,
        playerArmyRoster: [{ unitType: UnitTypeId.XUANJIA_CATAPHRACT, count: 1, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
        enemyArmyRoster: [{ unitType: UnitTypeId.COMPOSITE_ARCHER, count: 2, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
      })
    );
    const w2 = sim2.getWorldView();
    const cata = w2.soldiers.find((s) => s.active && s.side === BattleSide.PLAYER);
    const archers = w2.soldiers.filter((s) => s.active && s.side === BattleSide.ENEMY);
    const aSq = w2.squads[archers[0].squadId];
    cata.x = 2000;
    cata.y = 1200;
    cata.attackCooldown = 0;
    cata.chargeCooldown = 8.0;
    archers[0].x = 2020;
    archers[0].y = 1200;
    archers[1].x = 2025;
    archers[1].y = 1210;
    aSq.morale = 20.2;

    sim2.stepTick(0.02);
    assert.equal(aSq.isRouting, true, '敌弓手分队被铁浮图打崩进入溃逃');
    assert.ok(cata.chargeCooldown <= 4.05, `铁浮图击溃敌队重置 50% 冲锋冷却: ${cata.chargeCooldown}`);
  }
});

// ---------------------------------------------------------------------------
// 9. 断粮三级惩罚、劫掠敌营夺 150 应急粮翻盘、商盟无金雇佣军退场与 25s 保底民夫
// ---------------------------------------------------------------------------
runTest('断粮三级惩罚（WARNING / HUNGRY / STARVING）、劫营夺 150 应急粮与零金零工兵 25s 应急民夫', () => {
  assert.equal(evaluateRationStage(500, 10, 0), BattlefieldRationStage.ABUNDANT);
  assert.equal(evaluateRationStage(100, 10, 0), BattlefieldRationStage.WARNING); // 10s < 15s
  assert.equal(evaluateRationStage(0, 10, 12), BattlefieldRationStage.HUNGRY);
  assert.equal(evaluateRationStage(0, 10, 35), BattlefieldRationStage.STARVING);

  const sim = new BattleSimulator(
    makeBaseConfig({
      playerFaction: FactionId.SHAMO,
      playerInitialGrain: 0,
      playerArmyRoster: [{ unitType: UnitTypeId.GREAT_AXEMAN, count: 4, corpsRole: ArmyCorpsRole.LEFT_WING }],
      enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 4, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  // 推进 5 秒进入 HUNGRY
  for (let i = 0; i < 50; i++) {
    sim.stepTick(0.1);
  }
  assert.equal(sim.getHudSnapshot().playerRationStage, BattlefieldRationStage.HUNGRY);

  // 推进超过 30 秒进入 STARVING
  for (let i = 0; i < 270; i++) {
    sim.stepTick(0.1);
  }
  assert.equal(sim.getHudSnapshot().playerRationStage, BattlefieldRationStage.STARVING);

  // 突袭敌方本阵大营劫掠粮车，当场夺取 150 应急粮解除饥荒！
  const looted = sim.triggerSupplyCampRaid(BattleSide.PLAYER);
  assert.equal(looted, 150);
  assert.ok(sim.getHudSnapshot().playerGrain >= 145);
  assert.equal(sim.getHudSnapshot().playerRationStage, BattlefieldRationStage.ABUNDANT);

  // 验证零金币 (<35) + 零工兵持续 25s 自动免费征召 1 名应急民夫 + 警钟开关
  const simEco = new BattleSimulator(
    makeBaseConfig({
      playerArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 1, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 1, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  // 花光初始金币至 < 35（招募精锐）
  while (simEco.recruitUnit(BattleSide.PLAYER, UnitTypeId.GREAT_AXEMAN, ArmyCorpsRole.VANGUARD_CENTER)) {
    // 消耗初始金币
  }
  // 注意：本阵有 +1.2 金/s 保底产出，测试保底金币增长与警钟切换
  const goldBefore = simEco.getHudSnapshot().playerGold;
  for (let i = 0; i < 50; i++) {
    simEco.stepTick(0.1);
  }
  assert.ok(simEco.getHudSnapshot().playerGold > goldBefore, '本阵每秒自动提供保底军饷防经济死锁');
  assert.equal(simEco.toggleGarrisonBell(), true);
  assert.equal(simEco.getHudSnapshot().garrisonBellActive, true);
  assert.equal(simEco.toggleGarrisonBell(), false);
});

// ---------------------------------------------------------------------------
// 10. 战争迷雾动态视野测试（步兵420/骑兵580/高地+25%/浓雾黑夜-40%/密林未开火140px）
// ---------------------------------------------------------------------------
runTest('战争迷雾动态视野：步骑基础半径、高地+25%、浓雾/黑夜-40%（血月免疫）与密林 140px 隐蔽识破', () => {
  approxEqual(
    computeObserverVisionRadius(UnitCategory.INFANTRY, false, 0, WeatherType.CLEAR_DAY, FactionId.YANLONG),
    420
  );
  approxEqual(
    computeObserverVisionRadius(UnitCategory.CAVALRY, false, 0, WeatherType.CLEAR_DAY, FactionId.YANLONG),
    580
  );
  approxEqual(
    computeObserverVisionRadius(UnitCategory.INFANTRY, false, 1, WeatherType.CLEAR_DAY, FactionId.YANLONG),
    420 * 1.25
  );
  approxEqual(
    computeObserverVisionRadius(UnitCategory.INFANTRY, false, 0, WeatherType.HEAVY_FOG, FactionId.YANLONG),
    420 * 0.60
  );
  approxEqual(
    computeObserverVisionRadius(UnitCategory.INFANTRY, false, 0, WeatherType.NIGHT, FactionId.XUEYUE),
    420,
    1e-4,
    '血月祭司夜战视野无损'
  );

  // 密林未开火：200px 处非雾林势力无法看见，130px 内可识破；雾林势力 380px 透视
  assert.equal(canObserverSpotTarget(200 * 200, 420, FactionId.YANLONG, true), false);
  assert.equal(canObserverSpotTarget(130 * 130, 420, FactionId.YANLONG, true), true);
  assert.equal(canObserverSpotTarget(380 * 380, 420, FactionId.WULIN, true), true);
});

// ---------------------------------------------------------------------------
// 11. 主帅英雄操控、24 支箭袋限制、精准弹反、三大技能、40ms 顿帧与两段式落马状态机
// ---------------------------------------------------------------------------
runTest('主帅英雄模式：1.5s 切换冷却、24支箭袋脱战回收与回营瞬补、三大技能、40ms Hit-Stop 及两段式落马状态机', () => {
  const sim = new BattleSimulator(
    makeBaseConfig({
      playerArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 12, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.LIGHT_CAVALRY, count: 6, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  const w = sim.getWorldView();

  // 11.1 视角切换 1.5s 冷却保护
  assert.equal(sim.toggleControlMode(), true);
  assert.equal(sim.getHudSnapshot().controlMode, BattleControlMode.HERO_ACTION);
  assert.equal(sim.toggleControlMode(), false, '1.5s 冷却内禁止连点切换');
  for (let i = 0; i < 16; i++) {
    sim.stepTick(0.1);
  }
  assert.equal(sim.toggleControlMode(), true);
  assert.equal(sim.getHudSnapshot().controlMode, BattleControlMode.RTS_COMMANDER);
  for (let i = 0; i < 16; i++) {
    sim.stepTick(0.1);
  }
  assert.equal(sim.toggleControlMode(), true);

  // 11.2 百石硬弓 24 支箭袋限制、脱战 2.5s 自动回 1 支与靠近本阵瞬补满
  sim.switchHeroWeapon(HeroWeaponType.HEAVY_WARBOW);
  w.playerHero.x = 1800; // 远离本阵 > 200px
  w.playerHero.y = 400;
  assert.equal(sim.getHudSnapshot().heroArrows, 24);
  sim.updateHeroInput({ moveX: 0, moveY: 0, aimX: 1, aimY: 0, isAttackPressed: true, isBlockHeld: false });
  sim.stepTick(0.05);
  assert.equal(sim.getHudSnapshot().heroArrows, 23, '射出一箭后剩余 23 支');

  // 射空至 0 验证不可再射
  w.playerHero.remainingArrows = 0;
  w.playerHero.attackCooldown = 0;
  const activeProjBefore = w.projectiles.filter((p) => p.active).length;
  sim.stepTick(0.05);
  const activeProjAfter = w.projectiles.filter((p) => p.active).length;
  assert.equal(activeProjAfter, activeProjBefore, '0 箭时禁止无限风筝发射');

  // 停止射击脱战满 1.5s + 2.5s 自动回收 1 支箭
  sim.updateHeroInput({ moveX: 0, moveY: 0, aimX: 1, aimY: 0, isAttackPressed: false, isBlockHeld: false });
  for (let i = 0; i < 45; i++) {
    sim.stepTick(0.1);
  }
  assert.ok(w.playerHero.remainingArrows >= 1, `脱战自动回箭生效: ${w.playerHero.remainingArrows}`);

  // 靠近己方本阵 <= 200px 瞬间补满 24 支！
  const pCamp = w.structures.find((st) => st.side === BattleSide.PLAYER && st.kind === 'base_camp');
  w.playerHero.x = pCamp.x + 80;
  w.playerHero.y = pCamp.y + 80;
  sim.stepTick(0.05);
  assert.equal(sim.getHudSnapshot().heroArrows, 24, '靠近本阵大营瞬间补满 24 支箭');

  // 11.3 破阵大枪反骑 + 40ms Hit-Stop + 三军战吼唤醒溃军
  sim.switchHeroWeapon(HeroWeaponType.BREAKER_SPEAR);
  const eCav = w.soldiers.find((s) => s.active && s.side === BattleSide.ENEMY);
  w.playerHero.x = 2000;
  w.playerHero.y = 1200;
  w.playerHero.attackCooldown = 0;
  eCav.x = 2040;
  eCav.y = 1200;
  sim.updateHeroInput({ moveX: 0, moveY: 0, aimX: 1, aimY: 0, isAttackPressed: true, isBlockHeld: false });
  sim.stepTick(0.02);
  assert.equal(sim.getHudSnapshot().hitStopRemainingMs, 40, '大枪命中骑兵触发 40ms 卡肉顿帧');
  sim.updateHeroInput({ moveX: 0, moveY: 0, aimX: 1, aimY: 0, isAttackPressed: false, isBlockHeld: false });

  // 三大技能触发验证
  const pSq = w.squads.find((sq) => sq.side === BattleSide.PLAYER);
  pSq.centerX = w.playerHero.x + 60;
  pSq.centerY = w.playerHero.y;
  pSq.morale = 12;
  pSq.isRouting = true;
  assert.equal(sim.triggerHeroSkill(HeroSkillId.GRAND_WAR_CRY), true);
  assert.equal(pSq.isRouting, false, '【三军战吼】直接唤醒 320px 内溃逃友军重整反扑');
  assert.ok(pSq.morale >= 32, '唤醒后士气直接抬升至重整线以上');

  assert.equal(sim.triggerHeroSkill(HeroSkillId.IRON_BULWARK), true);
  assert.equal(sim.triggerHeroSkill(HeroSkillId.BREAKTHROUGH_CHARGE), true);

  // 11.4 击倒敌方主帅：敌军 -35 士气并指挥瘫痪 15s
  const eSq = w.squads.find((sq) => sq.side === BattleSide.ENEMY);
  eSq.morale = 80;
  w.enemyHero.x = w.playerHero.x + 30;
  w.enemyHero.y = w.playerHero.y;
  w.enemyHero.hp = 10;
  w.playerHero.attackCooldown = 0;
  sim.updateHeroInput({ moveX: 0, moveY: 0, aimX: 1, aimY: 0, isAttackPressed: true, isBlockHeld: false });
  sim.stepTick(0.02);
  assert.equal(w.enemyHero.vitalState, HeroVitalState.RECOVERING_IN_CAMP, '敌帅首次落马回营');
  assert.ok(eSq.morale <= 46, `敌帅落马令敌军瞬间 -35 士气: ${eSq.morale}`);
  assert.ok(sim.getEnemyCommandParalysisSec() >= 14.5, '敌军陷入 15s 指挥瘫痪');
  // 瘫痪期间敌军变阵指令失效
  const prevEForm = eSq.formation;
  sim.issueSquadCommand({ squadIds: [eSq.squadId], formation: FormationType.CIRCLE_DEFENSE });
  assert.equal(eSq.formation, prevEForm, '瘫痪期间敌军无法变阵');

  // 11.5 玩家主帅两段式落马：首次落马 -35 士气、锁 65 上限、切回 RTS、45s 后 35% 血复出 -> 二次落马殉国战败！
  sim.updateHeroInput({ moveX: 0, moveY: 0, aimX: 1, aimY: 0, isAttackPressed: false, isBlockHeld: false });
  w.playerHero.ironBulwarkTimer = 0;
  w.playerHero.isBlocking = false;
  w.playerHero.hp = 5;
  pSq.morale = 90;
  eCav.x = w.playerHero.x + 25;
  eCav.y = w.playerHero.y;
  // 敌军弓箭/贴脸打落玩家主帅：发射敌方投射物直击主帅
  const freeProj = w.projectiles.find((p) => !p.active);
  freeProj.active = true;
  freeProj.side = BattleSide.ENEMY;
  freeProj.x = w.playerHero.x + 2;
  freeProj.y = w.playerHero.y;
  freeProj.vx = -200;
  freeProj.vy = 0;
  freeProj.arcHeight = 4;
  freeProj.splashRadius = 0;
  freeProj.flightProgress = 0.2;
  freeProj.flightDuration = 1.0;
  freeProj.damage = 80;
  freeProj.armorPenetration = 0.5;
  freeProj.pierceRemaining = 1;

  sim.stepTick(0.02);
  assert.equal(w.playerHero.vitalState, HeroVitalState.RECOVERING_IN_CAMP, '玩家主帅首次落马进入本阵抢救');
  assert.equal(sim.getHudSnapshot().controlMode, BattleControlMode.RTS_COMMANDER, '首次落马强制平滑切回 RTS 视角');
  assert.ok(pSq.morale <= 56, `首次落马全军士气骤降 35: ${pSq.morale}`);

  // 验证包扎期间全军士气上限被锁死在 65
  applySquadMoraleAndHysteresis(pSq, 50, true, false);
  assert.equal(pSq.morale, 65, '主帅重伤期间全军士气上限严格锁死 65');

  // 步进 45.5 秒完成包扎，以 35% 残血 + 重创虚弱复出！
  // （修正原测试缺陷：原测试仅令玩家 pSq 原地驻防而未拉开无敌敌骑 eSq，导致 eSq 合围打溃 pSq 并在 10s 后提前触发 player_army_routed 终局，使后续二次落马帧被 stepTick 早退跳过）
  sim.issueSquadCommand({ squadIds: [pSq.squadId], order: TacticalOrder.HOLD_GROUND, targetX: 1200, targetY: 1200 });
  eSq.order = TacticalOrder.HOLD_GROUND;
  eSq.targetX = 3200;
  eSq.targetY = 1200;
  for (const s of w.soldiers) {
    if (s.active && s.side === BattleSide.ENEMY) {
      s.x = 3200;
      s.y = 1200;
      s.vx = 0;
      s.vy = 0;
    }
  }
  for (let i = 0; i < 460; i++) {
    for (const s of w.soldiers) {
      if (s.active) {
        s.hp = s.maxHp;
      }
    }
    pSq.morale = 60;
    pSq.isRouting = false;
    eSq.morale = 60;
    eSq.isRouting = false;
    sim.stepTick(0.1);
  }
  assert.equal(sim.getHudSnapshot().outcome, BattleOutcomeReason.ONGOING, '包扎复出时战局仍在进行中');
  assert.equal(w.playerHero.vitalState, HeroVitalState.WOUNDED_WEAKENED, '45s 后重创虚弱复出');
  assert.equal(w.playerHero.hp, Math.round(1100 * 0.35), '复出残血为 35% (385)');
  assert.ok(w.playerHero.moveSpeed < 92, '重创虚弱移速降低 25%');

  // 二次 HP 归零：无免死保护，直接阵前殉国判负！
  w.playerHero.hp = 5;
  const killProj = w.projectiles.find((p) => !p.active);
  killProj.active = true;
  killProj.side = BattleSide.ENEMY;
  killProj.x = w.playerHero.x + 2;
  killProj.y = w.playerHero.y;
  killProj.vx = -200;
  killProj.vy = 0;
  killProj.arcHeight = 4;
  killProj.splashRadius = 0;
  killProj.flightProgress = 0.2;
  killProj.flightDuration = 1.0;
  killProj.damage = 90;
  killProj.armorPenetration = 0.6;
  killProj.pierceRemaining = 1;

  sim.stepTick(0.02);
  assert.equal(w.playerHero.vitalState, HeroVitalState.FALLEN_MARTYRED);
  assert.equal(sim.getHudSnapshot().outcome, BattleOutcomeReason.PLAYER_HERO_MARTYRED);
  const summary = sim.buildSettlementSummary();
  assert.equal(summary.isVictory, false);
  assert.equal(summary.outcomeReason, BattleOutcomeReason.PLAYER_HERO_MARTYRED);
});

// ---------------------------------------------------------------------------
// 12. 同屏 320+ 火柴人多战线混战单帧性能基准测试（硬指标：< 5ms / tick）
// ---------------------------------------------------------------------------
runTest('同屏 320+ 火柴人 6 军团全要素混战模拟性能基准（单帧平均与 P95 耗时严格 < 5ms）', () => {
  const heavyRosterP = [
    { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 36, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
    { unitType: UnitTypeId.PIKEMAN, count: 30, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
    { unitType: UnitTypeId.LIGHT_CAVALRY, count: 22, corpsRole: ArmyCorpsRole.LEFT_WING },
    { unitType: UnitTypeId.YANLONG_HALBERD_GRENADIER, count: 22, corpsRole: ArmyCorpsRole.RIGHT_WING },
    { unitType: UnitTypeId.GREAT_AXEMAN, count: 20, corpsRole: ArmyCorpsRole.REAR_RESERVE },
    { unitType: UnitTypeId.COMPOSITE_ARCHER, count: 24, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
    { unitType: UnitTypeId.BALLISTA, count: 3, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
    { unitType: UnitTypeId.TREBUCHET, count: 2, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
    { unitType: UnitTypeId.SAPPER, count: 6, corpsRole: ArmyCorpsRole.SUPPLY_ESCORT }
  ];
  const heavyRosterE = [
    { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 36, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
    { unitType: UnitTypeId.PIKEMAN, count: 30, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
    { unitType: UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER, count: 24, corpsRole: ArmyCorpsRole.LEFT_WING },
    { unitType: UnitTypeId.LIGHT_CAVALRY, count: 22, corpsRole: ArmyCorpsRole.RIGHT_WING },
    { unitType: UnitTypeId.GREAT_AXEMAN, count: 20, corpsRole: ArmyCorpsRole.REAR_RESERVE },
    { unitType: UnitTypeId.COMPOSITE_ARCHER, count: 24, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
    { unitType: UnitTypeId.BALLISTA, count: 3, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
    { unitType: UnitTypeId.SAPPER, count: 6, corpsRole: ArmyCorpsRole.SUPPLY_ESCORT }
  ];

  const sim = new BattleSimulator(
    makeBaseConfig({
      scenarioType: BattleScenarioType.SIEGE_ASSAULT,
      playerFaction: FactionId.YANLONG,
      enemyFaction: FactionId.CANGLANG,
      playerArmyRoster: heavyRosterP,
      enemyArmyRoster: heavyRosterE
    })
  );

  const initHud = sim.getHudSnapshot();
  const totalSoldiers = initHud.playerAliveSoldiers + initHud.enemyAliveSoldiers;
  assert.ok(totalSoldiers >= 320, `同屏压测总兵力应 >= 320，实际: ${totalSoldiers}`);

  // 预热 JIT 20 帧后连续采样 300 逻辑帧（模拟 10 秒激烈交战）
  for (let w = 0; w < 20; w++) {
    sim.stepTick(1 / 30);
  }

  const samples = [];
  for (let tick = 0; tick < 300; tick++) {
    const t0 = performance.now();
    sim.stepTick(1 / 30);
    const t1 = performance.now();
    samples.push(t1 - t0);
  }

  samples.sort((a, b) => a - b);
  const avgMs = samples.reduce((acc, v) => acc + v, 0) / samples.length;
  const p95Ms = samples[Math.floor(samples.length * 0.95)];
  const maxMs = samples[samples.length - 1];

  console.log(
    `    -> [Benchmark 330 Soldiers] avg=${avgMs.toFixed(3)}ms, p95=${p95Ms.toFixed(3)}ms, max=${maxMs.toFixed(3)}ms`
  );
  assert.ok(avgMs < 5.0, `平均单帧耗时必须 < 5ms，实际 ${avgMs.toFixed(3)}ms`);
  assert.ok(p95Ms < 5.0, `P95 单帧耗时必须 < 5ms，实际 ${p95Ms.toFixed(3)}ms`);

  // 验证战场议和停火与结算摘要生成
  sim.negotiateFieldTruce();
  assert.equal(sim.getHudSnapshot().outcome, BattleOutcomeReason.TRUCE_NEGOTIATED);
  const settlement = sim.buildSettlementSummary();
  assert.equal(settlement.outcomeReason, BattleOutcomeReason.TRUCE_NEGOTIATED);
  assert.equal(settlement.playerInitialTotal, 165);
  assert.equal(settlement.enemyInitialTotal, 165);
});

// ---------------------------------------------------------------------------
// 13. 补充纯逻辑测试：主帅佩刀 0.25s 精准弹反近战士兵 & 本阵已破/兵力<10% 首次落马直接殉国
// ---------------------------------------------------------------------------
runTest('主帅近战交互：佩刀 0.25s 精准弹反震晕近战敌兵 1.5s + 40ms 顿帧 & 大营已破/残军<10% 首次落马直接殉国', () => {
  // 13A. 佩刀精准弹反近战士兵（修复前敌近战士兵从不调用 applyDamageToHero，弹反为死代码）
  const simParry = new BattleSimulator(
    makeBaseConfig({
      playerArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 10, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 4, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  const wP = simParry.getWorldView();
  assert.equal(simParry.toggleControlMode(), true);
  simParry.switchHeroWeapon(HeroWeaponType.COMMAND_SABER);
  wP.playerHero.x = 2000;
  wP.playerHero.y = 1200;
  wP.playerHero.facingRad = 0;

  const enemyMelee = wP.soldiers.find((s) => s.active && s.side === BattleSide.ENEMY);
  enemyMelee.x = 2020; // 正前方 20px 近战攻击范围内
  enemyMelee.y = 1200;
  enemyMelee.attackCooldown = 0;

  const hpBeforeParry = wP.playerHero.hp;
  // 按下举盾瞬间开启 0.25s parryWindowTimer，同帧敌近战刀盾兵挥刀劈向主帅正面
  simParry.updateHeroInput({ moveX: 0, moveY: 0, aimX: 1, aimY: 0, isAttackPressed: false, isBlockHeld: true });
  simParry.stepTick(0.02);

  assert.equal(wP.playerHero.hp, hpBeforeParry, '0.25s 佩刀弹反窗口内正面近战必须 0 伤');
  assert.ok(enemyMelee.staggerTimer >= 1.45, `被弹反的近战敌兵必须眩晕 1.5s，实际: ${enemyMelee.staggerTimer}`);
  assert.equal(enemyMelee.actionState, UnitActionState.STAGGER_HIT);
  assert.ok(enemyMelee.x >= 2045, `被弹反敌兵应向后震退 ~30px，实际 x=${enemyMelee.x}`);
  assert.equal(simParry.getHudSnapshot().hitStopRemainingMs, 40, '精准弹反触发 40ms 卡肉顿帧');

  // 对比：持续按住格挡 > 0.25s 窗口过期后，正面近战减伤 80%，背后近战吃 1.45x 背击无格挡
  for (let k = 0; k < 5; k++) {
    simParry.stepTick(0.08);
  }
  enemyMelee.staggerTimer = 0;
  enemyMelee.attackCooldown = 0;
  enemyMelee.x = wP.playerHero.x + 20;
  enemyMelee.y = wP.playerHero.y;
  const hpBeforeBlock = wP.playerHero.hp;
  simParry.stepTick(0.02);
  const blockedLoss = hpBeforeBlock - wP.playerHero.hp;
  assert.ok(blockedLoss >= 2 && blockedLoss <= 5, `常规正面举盾减免 80% 后仅受微伤: ${blockedLoss}`);

  enemyMelee.attackCooldown = 0;
  enemyMelee.x = wP.playerHero.x - 20; // 绕至主帅正后方 180°
  enemyMelee.y = wP.playerHero.y;
  const hpBeforeRear = wP.playerHero.hp;
  simParry.stepTick(0.02);
  const rearLoss = hpBeforeRear - wP.playerHero.hp;
  assert.ok(rearLoss > blockedLoss * 3.0, `主帅背后受击无法格挡且吃背击倍率: rear=${rearLoss} vs frontBlock=${blockedLoss}`);

  // 13B. 边界：己方本阵大营已被攻破时，主帅首次 HP 归零无医帐可退，直接殉国判负（DESIGN.md 10.2）
  const simCampBroken = new BattleSimulator(
    makeBaseConfig({
      playerArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 12, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.GREAT_AXEMAN, count: 4, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  const wCB = simCampBroken.getWorldView();
  const pCamp = wCB.structures.find((st) => st.side === BattleSide.PLAYER && st.kind === 'base_camp');
  pCamp.hp = 0;
  pCamp.isBreached = true;
  wCB.playerHero.hp = 5;
  wCB.playerHero.attackCooldown = 1.0; // 主帅处于收刀硬直中，无力先行震退巨斧手
  const axeEnemy = wCB.soldiers.find((s) => s.active && s.side === BattleSide.ENEMY);
  axeEnemy.x = wCB.playerHero.x + 18;
  axeEnemy.y = wCB.playerHero.y;
  axeEnemy.attackCooldown = 0;
  // 注意：大营已破，但此帧步骤 5 近战士兵劈死主帅发生在步骤 9 终局评估之前，验证主帅状态直接转为 FALLEN_MARTYRED！
  simCampBroken.stepTick(0.02);
  assert.equal(wCB.playerHero.vitalState, HeroVitalState.FALLEN_MARTYRED, '本阵已破时首次落马直接殉国');

  // 13C. 边界：本阵完好但场上未溃逃友军 < 10% 初始编制（20 人仅剩 1 人存活 < 2 人）时，首次落马直接殉国判负！
  const simArmyCollapsed = new BattleSimulator(
    makeBaseConfig({
      playerArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 20, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.GREAT_AXEMAN, count: 4, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  const wAC = simArmyCollapsed.getWorldView();
  let keptOne = false;
  for (const s of wAC.soldiers) {
    if (s.active && s.side === BattleSide.PLAYER) {
      if (!keptOne) {
        keptOne = true;
      } else {
        s.active = false;
        s.hp = 0;
      }
    }
  }
  wAC.playerHero.hp = 5;
  wAC.playerHero.attackCooldown = 1.0;
  const axeE2 = wAC.soldiers.find((s) => s.active && s.side === BattleSide.ENEMY);
  axeE2.x = wAC.playerHero.x + 18;
  axeE2.y = wAC.playerHero.y;
  axeE2.attackCooldown = 0;
  simArmyCollapsed.stepTick(0.02);
  assert.equal(wAC.playerHero.vitalState, HeroVitalState.FALLEN_MARTYRED, '未溃逃兵力不足 10% 时首次落马无法抢救直接殉国');
  assert.equal(simArmyCollapsed.getHudSnapshot().outcome, BattleOutcomeReason.PLAYER_HERO_MARTYRED);
});

// ---------------------------------------------------------------------------
// 14. 补充纯逻辑测试：零金零工兵满 25s 真实免费刷出民夫 & 沙漠商盟断粮耗金与雇佣兵退场
// ---------------------------------------------------------------------------
runTest('后勤极端闭环：0金0工兵满 25s 自动免费征召应急民夫 & 沙漠商盟饥荒折银耗尽后雇佣兵离场', () => {
  // 14A. 0 金币 + 0 工兵持续满 25s（4 名游骑兵恰好花光开局 500 金 -> 0 金；25s 保底产金 +30 < 35），验证第 25s 大营真实免费生成 1 名 SAPPER
  const simFreeSapper = new BattleSimulator(
    makeBaseConfig({
      playerFaction: FactionId.CANGLANG,
      playerArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 4, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }],
      enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 4, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  for (let r = 0; r < 4; r++) {
    assert.equal(simFreeSapper.recruitUnit(BattleSide.PLAYER, UnitTypeId.LIGHT_CAVALRY, ArmyCorpsRole.LEFT_WING), true);
  }
  assert.equal(simFreeSapper.getHudSnapshot().playerGold, 0, '招募 4 名游骑兵 (4*125) 后金币归零');
  const wFS = simFreeSapper.getWorldView();
  for (const sq of wFS.squads) {
    simFreeSapper.issueSquadCommand({
      squadIds: [sq.squadId],
      order: TacticalOrder.HOLD_GROUND,
      targetX: sq.side === BattleSide.PLAYER ? 900 : 3900,
      targetY: 1200
    });
  }

  assert.equal(wFS.soldiers.filter((s) => s.active && s.side === BattleSide.PLAYER && s.unitType === UnitTypeId.SAPPER).length, 0);
  for (let i = 0; i < 252; i++) {
    simFreeSapper.stepTick(0.1); // 25.2s，期间金币从 0 涨至 ~30.24 (<35)
  }
  const spawnedSappers = wFS.soldiers.filter(
    (s) => s.active && s.side === BattleSide.PLAYER && s.unitType === UnitTypeId.SAPPER
  );
  assert.equal(spawnedSappers.length, 1, '0 金 0 工兵满 25s 必须免费刷出 1 名应急民夫破除死锁');
  assert.equal(simFreeSapper.getHudSnapshot().playerAliveSoldiers, 9);

  // 14B. 沙漠商盟断粮饥溃 (>30s) + 雇佣军折银耗尽至 0 金 -> 外籍雇佣兵直接离场，本土骆驼卫队留守
  const simShamo = new BattleSimulator(
    makeBaseConfig({
      playerFaction: FactionId.SHAMO,
      playerInitialGrain: 0,
      playerArmyRoster: [
        { unitType: UnitTypeId.SHAMO_MAMELUKE_CAMEL, count: 4, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
        { unitType: UnitTypeId.GREAT_AXEMAN, count: 12, corpsRole: ArmyCorpsRole.LEFT_WING }
      ],
      enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 6, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  // 粮草仅剩 15 (< 30)，招募刀盾步兵 (cost: 65金/15木/30粮) 自动触发纯金币雇佣军契约！
  while (simShamo.recruitUnit(BattleSide.PLAYER, UnitTypeId.SHIELD_SWORDSMAN, ArmyCorpsRole.LEFT_WING)) {
    // 耗光开局 500 金币，全部转为 isMercenary=true 的外籍刀盾雇佣兵
  }
  const wSM = simShamo.getWorldView();
  const mercBefore = wSM.soldiers.filter((s) => s.active && s.side === BattleSide.PLAYER && s.isMercenary).length;
  assert.ok(mercBefore >= 4, `应成功纯金征召多名外籍雇佣兵: ${mercBefore}`);
  for (const sq of wSM.squads) {
    simShamo.issueSquadCommand({
      squadIds: [sq.squadId],
      order: TacticalOrder.HOLD_GROUND,
      targetX: sq.side === BattleSide.PLAYER ? 900 : 3900,
      targetY: 1200
    });
  }
  for (let i = 0; i < 305; i++) {
    simShamo.stepTick(0.1); // 30.5s：余粮为 0，雇佣军折银压倒保底产金使金币归零，刚满 >30s STARVING 即集体退场
  }
  assert.equal(simShamo.getHudSnapshot().playerRationStage, BattlefieldRationStage.STARVING);
  assert.ok(simShamo.getHudSnapshot().playerGold <= 2, '断粮期间外籍雇佣兵索取折银使商盟金币耗尽触发退场');
  const mercAfter = wSM.soldiers.filter((s) => s.active && s.side === BattleSide.PLAYER && s.isMercenary).length;
  const camelRemain = wSM.soldiers.filter(
    (s) => s.active && s.side === BattleSide.PLAYER && s.unitType === UnitTypeId.SHAMO_MAMELUKE_CAMEL
  ).length;
  assert.equal(mercAfter, 0, '饥溃期无粮无金时沙漠商盟外籍雇佣兵集体离场');
  assert.equal(camelRemain, 4, '本土马穆鲁克骆驼卫队非外籍雇佣兵，依然留守阵地');
});

// ---------------------------------------------------------------------------
// 15. 补充纯逻辑测试：4 大阵型几何槽位、密林伏击/诈败诱敌自动反冲锋与守城倒计时胜利
// ---------------------------------------------------------------------------
runTest('阵型与战术状态机：4 阵型几何分布、密林伏击 180px 暴起、诈败诱敌深入反扑及守城倒计时获胜', () => {
  const sim = new BattleSimulator(
    makeBaseConfig({
      scenarioType: BattleScenarioType.SIEGE_DEFENSE,
      siegeHoldDurationSec: 8,
      playerArmyRoster: [
        { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 16, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
        { unitType: UnitTypeId.LIGHT_CAVALRY, count: 8, corpsRole: ArmyCorpsRole.LEFT_WING }
      ],
      enemyArmyRoster: [{ unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 12, corpsRole: ArmyCorpsRole.VANGUARD_CENTER }]
    })
  );
  const w = sim.getWorldView();
  const pInfSq = w.squads.find((sq) => sq.side === BattleSide.PLAYER && sq.corpsRole === ArmyCorpsRole.VANGUARD_CENTER);
  const pCavSq = w.squads.find((sq) => sq.side === BattleSide.PLAYER && sq.corpsRole === ArmyCorpsRole.LEFT_WING);
  const eSq = w.squads.find((sq) => sq.side === BattleSide.ENEMY);

  const measureSlotSpan = (sqId) => {
    const members = w.soldiers.filter((s) => s.active && s.squadId === sqId);
    const xs = members.map((s) => s.slotOffsetX);
    const ys = members.map((s) => s.slotOffsetY);
    return {
      spanX: Math.max(...xs) - Math.min(...xs),
      spanY: Math.max(...ys) - Math.min(...ys),
      radii: members.map((s) => Math.hypot(s.slotOffsetX, s.slotOffsetY))
    };
  };

  // 15A. 比较密集方阵 PHALANX_RECT 与雁行阵 ECHELON_LINE、圆阵 CIRCLE_DEFENSE、锥形阵 WEDGE_CHARGE 槽位特征
  sim.issueSquadCommand({ squadIds: [pInfSq.squadId], formation: FormationType.PHALANX_RECT });
  const phalanxSpan = measureSlotSpan(pInfSq.squadId);

  sim.issueSquadCommand({ squadIds: [pInfSq.squadId], formation: FormationType.ECHELON_LINE });
  const echelonSpan = measureSlotSpan(pInfSq.squadId);
  assert.ok(echelonSpan.spanY > phalanxSpan.spanY * 1.25, '雁行阵横向展开宽度必须显著大于密集方阵');

  sim.issueSquadCommand({ squadIds: [pInfSq.squadId], formation: FormationType.CIRCLE_DEFENSE });
  const circleSpan = measureSlotSpan(pInfSq.squadId);
  assert.ok(Math.abs(circleSpan.spanX - circleSpan.spanY) < 18, '圆阵纵横包络应近似对称等距环形');

  sim.issueSquadCommand({ squadIds: [pCavSq.squadId], formation: FormationType.WEDGE_CHARGE });
  const wedgeMembers = w.soldiers.filter((s) => s.active && s.squadId === pCavSq.squadId);
  const maxFrontX = Math.max(...wedgeMembers.map((s) => s.slotOffsetX));
  const tipUnits = wedgeMembers.filter((s) => Math.abs(s.slotOffsetX - maxFrontX) < 1e-3);
  assert.equal(tipUnits.length, 1, '锥形冲锋阵最前端矛尖应为单骑破阵顶点');

  // 15B. 密林潜伏 AMBUSH_HIDE：敌军踏入 <= 180px 伏击袋自动暴起转为 ALL_OUT_CHARGE
  sim.issueSquadCommand({
    squadIds: [pCavSq.squadId],
    order: TacticalOrder.AMBUSH_HIDE,
    targetX: 2200,
    targetY: 1200
  });
  for (const s of w.soldiers) {
    if (s.active && s.squadId === pCavSq.squadId) {
      s.x = 2200;
      s.y = 1200;
    }
    if (s.active && s.squadId === eSq.squadId) {
      s.x = 2330; // 距伏兵 130px <= 180px
      s.y = 1200;
    }
  }
  sim.stepTick(0.05);
  assert.equal(pCavSq.order, TacticalOrder.ALL_OUT_CHARGE, '敌军踏入 180px 伏击圈时伏兵必须自动暴起冲锋');

  // 诈败诱敌 FEIGNED_RETREAT：将敌军诱入己方本阵 520px 腹地且距离 < 240px 时自动反身 ALL_OUT_CHARGE
  sim.issueSquadCommand({
    squadIds: [pInfSq.squadId],
    formation: FormationType.ECHELON_LINE,
    order: TacticalOrder.FEIGNED_RETREAT
  });
  for (const s of w.soldiers) {
    if (s.active && s.squadId === pInfSq.squadId) {
      s.x = 760; // 距玩家本阵 (~430) 约 330px < 520px
      s.y = 1200;
    }
    if (s.active && s.squadId === eSq.squadId) {
      s.x = 940; // 距诈败前锋 180px < 240px
      s.y = 1200;
    }
  }
  sim.stepTick(0.05);
  assert.equal(pInfSq.order, TacticalOrder.ALL_OUT_CHARGE, '敌军追入己方腹地陷阱距 <240px 时诈败部队立即反身掩杀');

  // 15C. 守城倒计时届满（8s）且玩家本阵大营完好 -> 自动判定 SIEGE_DEFENSE_HELD 守城胜利！
  sim.issueSquadCommand({ squadIds: [pInfSq.squadId, pCavSq.squadId], order: TacticalOrder.HOLD_GROUND, targetX: 900, targetY: 1200 });
  sim.issueSquadCommand({ squadIds: [eSq.squadId], order: TacticalOrder.HOLD_GROUND, targetX: 3600, targetY: 1200 });
  for (const s of w.soldiers) {
    if (s.active) {
      s.x = s.side === BattleSide.PLAYER ? 900 : 3600;
      s.y = 1200;
    }
  }
  for (let i = 0; i < 82; i++) {
    sim.stepTick(0.1);
  }
  assert.equal(sim.getHudSnapshot().outcome, BattleOutcomeReason.SIEGE_DEFENSE_HELD, '守城坚持至倒计时归零自动获胜');
  assert.equal(sim.buildSettlementSummary().isVictory, true);
});

// ============================================================================
// 16. 全流程会话闭环：主菜单选势力 -> 战前整军 -> 真实战场(RTS包抄+主帅亲自上阵杀敌) -> 战后结算
// ============================================================================
runTest('16. 页面会话全流程闭环：遭遇战整军配兵 -> 真实战场 RTS 包抄 + 主帅上阵三兵刃战吼 -> 结算归档', () => {
  const session = new GameSessionCoordinator();
  session.prepareSetupForMode('skirmish', '遭遇战', FactionId.YANLONG);
  session.setSetupEnemyFaction(FactionId.CANGLANG);
  session.setSetupTerrain(TerrainType.RIVER_FORD);

  // 验证势力编制规则拦截（苍狼不可编入投石车，炎龙不可编入怯薛骑射）
  assert.equal(session.canUnitBeRecruitedByFaction(FactionId.CANGLANG, UnitTypeId.TREBUCHET), false);
  assert.equal(
    session.canUnitBeRecruitedByFaction(FactionId.YANLONG, UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER),
    false
  );
  assert.equal(session.adjustSetupUnitCount(UnitTypeId.GREAT_AXEMAN, ArmyCorpsRole.LEFT_WING, 6), true);
  assert.ok(session.computeSetupPlayerPopUsed() <= GameConstants.DEFAULT_ARMY_POP_CAP);

  const cfg = session.launchBattleFromSetup();
  assert.equal(cfg.playerFaction, FactionId.YANLONG);
  assert.equal(session.isActiveBattleFromCampaign(), false);

  const sim = session.getActiveBattleSimulator();
  assert.ok(sim !== null);

  // RTS 指挥：下达左翼侧翼包抄航点与中军方阵推进
  const w0 = sim.getWorldView();
  const leftSq = w0.squads.find(
    (sq) => sq.side === BattleSide.PLAYER && sq.corpsRole === ArmyCorpsRole.LEFT_WING
  );
  assert.ok(leftSq !== undefined);
  sim.issueSquadCommand({
    squadIds: [leftSq.squadId],
    formation: FormationType.WEDGE_CHARGE,
    order: TacticalOrder.FLANK,
    targetX: 3200,
    targetY: 520,
    customWaypointsX: [1800, 2600, 3200],
    customWaypointsY: [420, 380, 520]
  });

  // 推进 20 帧（含 BattleTacticalAI 0.5s 周期协同决策）
  for (let i = 0; i < 20; i++) {
    session.stepActiveBattle(0.1);
  }

  // 一键切换至主帅亲自上阵英雄模式：验证移动、切大枪、放三军战吼与破阵突击
  assert.equal(sim.toggleControlMode(), true);
  assert.equal(sim.getHudSnapshot().controlMode, BattleControlMode.HERO_ACTION);
  sim.switchHeroWeapon(HeroWeaponType.BREAKER_SPEAR);
  sim.updateHeroInput({
    moveX: 1.0,
    moveY: 0,
    aimX: sim.getWorldView().playerHero.x + 200,
    aimY: sim.getWorldView().playerHero.y,
    isAttackPressed: true,
    isBlockHeld: false
  });
  assert.equal(sim.triggerHeroSkill(HeroSkillId.GRAND_WAR_CRY), true);
  assert.equal(sim.triggerHeroSkill(HeroSkillId.BREAKTHROUGH_CHARGE), true);

  for (let i = 0; i < 16; i++) {
    session.stepActiveBattle(0.1);
  }
  assert.equal(sim.toggleControlMode(), true, '满 1.5s 冷却后可无缝切回 RTS 全局视野');
  assert.equal(sim.getHudSnapshot().controlMode, BattleControlMode.RTS_COMMANDER);

  // 模拟攻破敌军本阵完成真实会战终局 -> 结算归档
  const enemyBase = sim.getWorldView().structures.find(
    (st) => st.side === BattleSide.ENEMY && st.kind === 'base_camp'
  );
  assert.ok(enemyBase !== undefined);
  enemyBase.hp = 0;
  enemyBase.isBreached = true;
  session.stepActiveBattle(0.05);
  assert.equal(sim.getHudSnapshot().outcome, BattleOutcomeReason.ENEMY_BASE_DESTROYED);

  const summary = session.finalizeActiveBattle();
  assert.ok(summary !== null);
  assert.equal(summary.isVictory, true);
  assert.equal(session.getHallOfFameStats().standaloneBattlesFought, 1);
  assert.equal(session.getHallOfFameStats().standaloneBattlesWon, 1);
});

console.log(`\n全部 ${passedTests} 项战斗物理与主帅英雄核心单测 100% 通过！`);
