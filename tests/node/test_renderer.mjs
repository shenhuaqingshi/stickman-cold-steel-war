import assert from 'node:assert/strict';
import { GameConstants } from '../../entry/src/main/ets/common/GameConstants.ets';
import { CAMPAIGN_MAP_NODES } from '../../entry/src/main/ets/config/CampaignMapConfig.ets';
import { UNIT_STATIC_CONFIGS } from '../../entry/src/main/ets/config/UnitConfig.ets';
import {
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
  ProjectileKind,
  SupplyLineGrade,
  TacticalOrder,
  TerrainType,
  UnitActionState,
  UnitTypeId,
  WeatherType
} from '../../entry/src/main/ets/core/CoreContracts.ets';
import { StickmanBattleRenderer } from '../../entry/src/main/ets/render/StickmanBattleRenderer.ets';
import { CampaignMapRenderer } from '../../entry/src/main/ets/render/CampaignMapRenderer.ets';
import { BattleSimulator } from '../../entry/src/main/ets/core/combat/BattleSimulator.ets';
import { CampaignEngine } from '../../entry/src/main/ets/core/campaign/CampaignEngine.ets';

/**
 * 计数与坐标有限性严苛校验型 Mock ICanvas2DContext
 * - 统计全部绘制指令调用次数（重点检验 stroke 合批效率）
 * - 对所有传入坐标、半径、缩放值执行 Number.isFinite 检查，一旦出现 NaN / Infinity 立即抛错
 * - 校验 save / restore 栈严格平衡
 */
class CountingMockCanvas2DContext {
  constructor() {
    this.reset();
  }

  reset() {
    this._fillStyle = '#000000';
    this._strokeStyle = '#000000';
    this._lineWidth = 1;
    this._lineCap = 'butt';
    this._lineJoin = 'miter';
    this._globalAlpha = 1;
    this.font = '12px sans-serif';
    this.textAlign = 'left';
    this.textBaseline = 'alphabetic';

    this.saveDepth = 0;
    this.strokeCount = 0;
    this.fillCount = 0;
    this.beginPathCount = 0;
    this.closePathCount = 0;
    this.moveToCount = 0;
    this.lineToCount = 0;
    this.arcCount = 0;
    this.ellipseCount = 0;
    this.quadraticCurveToCount = 0;
    this.fillRectCount = 0;
    this.strokeRectCount = 0;
    this.clearRectCount = 0;
    this.fillTextCount = 0;
    this.setLineDashCount = 0;

    this.usedStrokeStyles = new Set();
    this.usedFillStyles = new Set();
    this.drawnTexts = [];
    this.nonEmptyDashCalls = 0;
    this.recordedFillRects = [];
  }

  _assertFinite(label, values) {
    for (let i = 0; i < values.length; i++) {
      const v = values[i];
      if (typeof v !== 'number' || !Number.isFinite(v)) {
        throw new Error(`[NaN/Infinity Guard] Invalid numeric arg in ${label}[${i}]: ${String(v)}`);
      }
    }
  }

  get fillStyle() {
    return this._fillStyle;
  }
  set fillStyle(v) {
    this._fillStyle = v;
    if (typeof v === 'string') {
      this.usedFillStyles.add(v);
    }
  }

  get strokeStyle() {
    return this._strokeStyle;
  }
  set strokeStyle(v) {
    this._strokeStyle = v;
    if (typeof v === 'string') {
      this.usedStrokeStyles.add(v);
    }
  }

  get lineWidth() {
    return this._lineWidth;
  }
  set lineWidth(v) {
    this._assertFinite('lineWidth', [v]);
    this._lineWidth = v;
  }

  get lineCap() {
    return this._lineCap;
  }
  set lineCap(v) {
    this._lineCap = v;
  }

  get lineJoin() {
    return this._lineJoin;
  }
  set lineJoin(v) {
    this._lineJoin = v;
  }

  get globalAlpha() {
    return this._globalAlpha;
  }
  set globalAlpha(v) {
    this._assertFinite('globalAlpha', [v]);
    this._globalAlpha = v;
  }

  save() {
    this.saveDepth++;
  }

  restore() {
    this.saveDepth--;
    if (this.saveDepth < 0) {
      throw new Error('Canvas restore() underflow: save/restore mismatch');
    }
  }

  clearRect(x, y, w, h) {
    this._assertFinite('clearRect', [x, y, w, h]);
    this.clearRectCount++;
  }

  fillRect(x, y, w, h) {
    this._assertFinite('fillRect', [x, y, w, h]);
    this.fillRectCount++;
    this.recordedFillRects.push({ x, y, w, h, style: this._fillStyle });
  }

  strokeRect(x, y, w, h) {
    this._assertFinite('strokeRect', [x, y, w, h]);
    this.strokeRectCount++;
  }

  beginPath() {
    this.beginPathCount++;
  }

  closePath() {
    this.closePathCount++;
  }

  moveTo(x, y) {
    this._assertFinite('moveTo', [x, y]);
    this.moveToCount++;
  }

  lineTo(x, y) {
    this._assertFinite('lineTo', [x, y]);
    this.lineToCount++;
  }

  arc(x, y, radius, startAngle, endAngle, counterclockwise = false) {
    this._assertFinite('arc', [x, y, radius, startAngle, endAngle]);
    assert.equal(typeof counterclockwise, 'boolean');
    if (radius < 0) {
      throw new Error(`Negative arc radius: ${radius}`);
    }
    this.arcCount++;
  }

  ellipse(x, y, radiusX, radiusY, rotation, startAngle, endAngle, counterclockwise = false) {
    this._assertFinite('ellipse', [x, y, radiusX, radiusY, rotation, startAngle, endAngle]);
    assert.equal(typeof counterclockwise, 'boolean');
    if (radiusX < 0 || radiusY < 0) {
      throw new Error(`Negative ellipse radius: ${radiusX}, ${radiusY}`);
    }
    this.ellipseCount++;
  }

  quadraticCurveTo(cpx, cpy, x, y) {
    this._assertFinite('quadraticCurveTo', [cpx, cpy, x, y]);
    this.quadraticCurveToCount++;
  }

  fill() {
    this.fillCount++;
  }

  stroke() {
    this.strokeCount++;
  }

  translate(x, y) {
    this._assertFinite('translate', [x, y]);
  }

  scale(x, y) {
    this._assertFinite('scale', [x, y]);
  }

  rotate(angle) {
    this._assertFinite('rotate', [angle]);
  }

  fillText(text, x, y, maxWidth) {
    this._assertFinite('fillText', maxWidth !== undefined ? [x, y, maxWidth] : [x, y]);
    this.fillTextCount++;
    this.drawnTexts.push(String(text));
  }

  setLineDash(segments) {
    assert.ok(Array.isArray(segments));
    this._assertFinite('setLineDash', segments);
    this.setLineDashCount++;
    if (segments.length > 0) {
      this.nonEmptyDashCalls++;
    }
  }
}

const ALL_UNIT_TYPES = UNIT_STATIC_CONFIGS.map((u) => u.id);
const ALL_ACTIVE_ACTION_STATES = [
  UnitActionState.IDLE_READY,
  UnitActionState.MARCH_RUN,
  UnitActionState.CHARGE_SPRINT,
  UnitActionState.MELEE_WINDUP,
  UnitActionState.MELEE_STRIKE,
  UnitActionState.RANGED_DRAW_FIRE,
  UnitActionState.SHIELD_BLOCK,
  UnitActionState.STAGGER_HIT,
  UnitActionState.ROUT_PANIC,
  UnitActionState.DYING_FALL
];

/**
 * 构造包含 300 名同屏激战火柴人（覆盖全部 16 种兵种 + 全部动作状态 + 150 具遗骸 + 60 飞行箭矢巨石）的真实战场快照
 */
function buildMockBattleWorld(soldierCount = 300) {
  const centerX = 2400;
  const centerY = 1200;

  const terrainZones = [
    { id: 'tz_north_hill', terrain: TerrainType.HIGH_GROUND, x: 1800, y: 200, width: 900, height: 380, elevation: 2 },
    { id: 'tz_north_forest', terrain: TerrainType.DENSE_FOREST, x: 2000, y: 600, width: 500, height: 220, elevation: 0 },
    { id: 'tz_river', terrain: TerrainType.RIVER_FORD, x: 2320, y: 820, width: 160, height: 760, elevation: 0 },
    { id: 'tz_bridge', terrain: TerrainType.BRIDGE_PASS, x: 2290, y: 1140, width: 220, height: 120, elevation: 0 },
    { id: 'tz_dune', terrain: TerrainType.DESERT_DUNE, x: 1850, y: 1620, width: 460, height: 280, elevation: 0 },
    { id: 'tz_snow', terrain: TerrainType.SNOWFIELD, x: 2520, y: 1620, width: 460, height: 280, elevation: 0 },
    { id: 'tz_fort', terrain: TerrainType.FORT_WALL, x: 2920, y: 980, width: 80, height: 440, elevation: 2 }
  ];

  const resourceNodes = [
    { id: 'res_gold', resourceKind: 'gold', x: 2060, y: 960, remainingAmount: 820, maxAmount: 1000 },
    { id: 'res_wood', resourceKind: 'wood', x: 2060, y: 1380, remainingAmount: 640, maxAmount: 900 },
    { id: 'res_grain', resourceKind: 'grain', x: 2680, y: 1380, remainingAmount: 510, maxAmount: 800 }
  ];

  const structures = [
    { id: 'p_camp', side: BattleSide.PLAYER, kind: 'base_camp', x: 1865, y: 1145, width: 110, height: 110, hp: 1800, maxHp: 2000, isBreached: false },
    { id: 'e_wall', side: BattleSide.ENEMY, kind: 'wall_segment', x: 2840, y: 970, width: 40, height: 180, hp: 900, maxHp: 1500, isBreached: false },
    { id: 'e_gate', side: BattleSide.ENEMY, kind: 'gate', x: 2838, y: 1152, width: 44, height: 96, hp: 420, maxHp: 1200, isBreached: false },
    { id: 'e_tower', side: BattleSide.ENEMY, kind: 'arrow_tower', x: 2836, y: 1296, width: 48, height: 48, hp: 700, maxHp: 900, isBreached: false },
    { id: 'p_stakes', side: BattleSide.PLAYER, kind: 'wooden_stakes', x: 2172, y: 1037, width: 96, height: 26, hp: 280, maxHp: 350, isBreached: false }
  ];

  const squads = [
    {
      squadId: 1,
      side: BattleSide.PLAYER,
      factionId: FactionId.YANLONG,
      corpsRole: ArmyCorpsRole.VANGUARD_CENTER,
      name: '1号·中军前锋',
      primaryUnitType: UnitTypeId.SHIELD_SWORDSMAN,
      formation: FormationType.PHALANX_RECT,
      order: TacticalOrder.ADVANCE,
      morale: 82,
      isRouting: false,
      encirclement: EncirclementState.PINCERED,
      threatOctantMask: 0b01000101,
      centerX: centerX - 160,
      centerY: centerY - 60,
      facingRad: 0,
      targetX: centerX + 100,
      targetY: centerY,
      waypointsX: [centerX - 60, centerX + 80, centerX + 210],
      waypointsY: [centerY - 120, centerY - 150, centerY - 40],
      waypointCursor: 0,
      aliveCount: 75,
      initialCount: 80,
      bannerAlive: true,
      bannerLostPenaltyTimer: 0,
      fordRatio: 0.45,
      halfFordShockApplied: false
    },
    {
      squadId: 2,
      side: BattleSide.PLAYER,
      factionId: FactionId.YANLONG,
      corpsRole: ArmyCorpsRole.LEFT_WING,
      name: '2号·左翼铁骑',
      primaryUnitType: UnitTypeId.LIGHT_CAVALRY,
      formation: FormationType.WEDGE_CHARGE,
      order: TacticalOrder.FLANK,
      morale: 31, // 动摇黄旗
      isRouting: false,
      encirclement: EncirclementState.CLEAR,
      threatOctantMask: 0,
      centerX: centerX - 210,
      centerY: centerY + 130,
      facingRad: -0.2,
      targetX: centerX + 160,
      targetY: centerY + 90,
      waypointsX: [],
      waypointsY: [],
      waypointCursor: 0,
      aliveCount: 75,
      initialCount: 75,
      bannerAlive: true,
      bannerLostPenaltyTimer: 0,
      fordRatio: 0,
      halfFordShockApplied: false
    },
    {
      squadId: 3,
      side: BattleSide.ENEMY,
      factionId: FactionId.CANGLANG,
      corpsRole: ArmyCorpsRole.VANGUARD_CENTER,
      name: '敌中军主力',
      primaryUnitType: UnitTypeId.PIKEMAN,
      formation: FormationType.PHALANX_RECT,
      order: TacticalOrder.HOLD_GROUND,
      morale: 16,
      isRouting: true, // 溃逃白旗
      encirclement: EncirclementState.ENCIRCLED,
      threatOctantMask: 0b11101101,
      centerX: centerX + 150,
      centerY: centerY,
      facingRad: Math.PI,
      targetX: centerX + 350,
      targetY: centerY,
      waypointsX: [],
      waypointsY: [],
      waypointCursor: 0,
      aliveCount: 150,
      initialCount: 160,
      bannerAlive: true,
      bannerLostPenaltyTimer: 0,
      fordRatio: 0,
      halfFordShockApplied: false
    }
  ];

  const soldiers = [];
  for (let i = 0; i < soldierCount; i++) {
    const isPlayer = i < soldierCount / 2;
    const unitCfg = UNIT_STATIC_CONFIGS[i % ALL_UNIT_TYPES.length];
    const row = Math.floor(i / 25);
    const col = i % 25;
    const sx = centerX - 360 + col * 29 + (isPlayer ? -18 : 18);
    const sy = centerY - 220 + row * 36;

    soldiers.push({
      active: true,
      poolIndex: i,
      side: isPlayer ? BattleSide.PLAYER : BattleSide.ENEMY,
      factionId: isPlayer ? FactionId.YANLONG : FactionId.CANGLANG,
      unitType: unitCfg.id,
      category: unitCfg.category,
      squadId: isPlayer ? (i % 2 === 0 ? 1 : 2) : 3,
      corpsRole: ArmyCorpsRole.VANGUARD_CENTER,
      isBannerBearer: i % 38 === 0,
      isMercenary: i % 40 === 0,
      x: sx,
      y: sy,
      vx: isPlayer ? 40 : -40,
      vy: 0,
      facingRad: isPlayer ? 0.08 : Math.PI - 0.08,
      hp: i % 3 === 0 ? Math.floor(unitCfg.hp * 0.65) : unitCfg.hp,
      maxHp: unitCfg.hp,
      actionState: ALL_ACTIVE_ACTION_STATES[i % ALL_ACTIVE_ACTION_STATES.length],
      animPhase: (i * 0.13) % 1.0,
      attackCooldown: i % 2 === 0 ? 0.8 : 0.2,
      chargeRunTime: 2.6,
      chargeCooldown: 0,
      staggerTimer: 0,
      poisonTimer: 0,
      isStealthed: unitCfg.id === UnitTypeId.WULIN_SHADOW_SNIPER && i % 2 === 0,
      visibleToPlayer: true,
      visibleToEnemy: true,
      grenadeUsed: false,
      slotOffsetX: 0,
      slotOffsetY: 0,
      targetEntityIndex: -1
    });
  }

  const corpses = [];
  for (let i = 0; i < GameConstants.MAX_FALLEN_CORPSE_DECAL; i++) {
    corpses.push({
      active: true,
      x: centerX - 340 + (i % 15) * 45,
      y: centerY - 210 + Math.floor(i / 15) * 42,
      rotationRad: (i * 0.47) % (Math.PI * 2),
      factionId: i % 2 === 0 ? FactionId.YANLONG : FactionId.CANGLANG,
      isBrokenBanner: i % 12 === 0,
      alpha: 0.85
    });
  }

  const projKinds = [
    ProjectileKind.ARROW,
    ProjectileKind.CROSSBOW_BOLT,
    ProjectileKind.BALLISTA_SPEAR,
    ProjectileKind.TREBUCHET_BOULDER,
    ProjectileKind.FIRE_BOMB
  ];
  const projectiles = [];
  for (let i = 0; i < 60; i++) {
    projectiles.push({
      active: true,
      poolIndex: i,
      side: i % 2 === 0 ? BattleSide.PLAYER : BattleSide.ENEMY,
      kind: projKinds[i % projKinds.length],
      startX: centerX - 240,
      startY: centerY,
      x: centerX - 250 + i * 8,
      y: centerY - 120 + (i % 10) * 24,
      vx: i % 2 === 0 ? 260 : -260,
      vy: 18,
      arcHeight: 75,
      flightProgress: (i + 1) / 62,
      flightDuration: 1.2,
      damage: 25,
      armorPenetration: 0.25,
      splashRadius: i % 5 === 3 ? 48 : 0,
      pierceRemaining: 1,
      applyPoison: i % 7 === 0,
      moraleShock: 0
    });
  }

  const hitEffects = [
    { active: true, x: centerX - 20, y: centerY - 15, kind: 'slash_arc', ttl: 0.18, maxTtl: 0.25, angleRad: 0.3 },
    { active: true, x: centerX + 12, y: centerY + 10, kind: 'shield_spark', ttl: 0.14, maxTtl: 0.22, angleRad: 1.1 },
    { active: true, x: centerX + 60, y: centerY - 30, kind: 'boulder_crater', ttl: 0.35, maxTtl: 0.50, angleRad: 0 }
  ];

  const playerHero = {
    side: BattleSide.PLAYER,
    factionId: FactionId.YANLONG,
    name: '炎龙统帅',
    x: centerX - 80,
    y: centerY,
    vx: 30,
    vy: 0,
    facingRad: 0.1,
    hp: 960,
    maxHp: 1100,
    armor: 55,
    moveSpeed: 92,
    vitalState: HeroVitalState.HEALTHY_ACTIVE,
    recoveryTimer: 0,
    activeWeapon: HeroWeaponType.BREAKER_SPEAR,
    remainingArrows: 20,
    arrowRecoverTimer: 0,
    attackCooldown: 0,
    isBlocking: true,
    parryWindowTimer: 0.1,
    ironBulwarkTimer: 1.2,
    warCryBuffTimer: 4.0,
    chargeCooldown: 0,
    bulwarkCooldown: 0,
    warCryCooldown: 0,
    actionState: UnitActionState.MELEE_STRIKE,
    animPhase: 0.45,
    kills: 12
  };

  const enemyHero = {
    ...playerHero,
    side: BattleSide.ENEMY,
    factionId: FactionId.CANGLANG,
    name: '苍狼大汗',
    x: centerX + 120,
    y: centerY + 20,
    facingRad: Math.PI,
    activeWeapon: HeroWeaponType.HEAVY_WARBOW,
    isBlocking: false,
    ironBulwarkTimer: 0,
    warCryBuffTimer: 0
  };

  const hud = {
    elapsedSec: 48.5,
    isPaused: false,
    controlMode: BattleControlMode.RTS_COMMANDER,
    switchCooldownSec: 0,
    garrisonBellActive: true,
    playerGold: 620,
    playerWood: 410,
    playerGrain: 980,
    playerRationStage: BattlefieldRationStage.ABUNDANT,
    enemyRationStage: BattlefieldRationStage.ABUNDANT,
    playerAliveSoldiers: 150,
    playerPopUsed: 180,
    playerPopCap: 240,
    enemyAliveSoldiers: 150,
    playerAvgMorale: 74,
    enemyAvgMorale: 42,
    heroHp: 960,
    heroMaxHp: 1100,
    heroVitalState: HeroVitalState.HEALTHY_ACTIVE,
    heroWeapon: HeroWeaponType.BREAKER_SPEAR,
    heroArrows: 20,
    chargeCd: 0,
    bulwarkCd: 0,
    warCryCd: 0,
    hitStopRemainingMs: 0,
    outcome: BattleOutcomeReason.ONGOING
  };

  return {
    width: GameConstants.BATTLEFIELD_WIDTH,
    height: GameConstants.BATTLEFIELD_HEIGHT,
    scenarioType: BattleScenarioType.SIEGE_ASSAULT,
    primaryTerrain: TerrainType.PLAIN,
    weather: WeatherType.RAIN_MUD,
    playerFaction: FactionId.YANLONG,
    enemyFaction: FactionId.CANGLANG,
    terrainZones,
    resourceNodes,
    structures,
    soldiers,
    squads,
    playerHero,
    enemyHero,
    projectiles,
    corpses,
    hitEffects,
    hud
  };
}

function runAllTests() {
  console.log('=== [1/5] 测试大战场 300 火柴人全兵种交战 Path Batching 合批效率 ===');
  const mockCtx = new CountingMockCanvas2DContext();
  const battleRenderer = new StickmanBattleRenderer(1600, 1000);
  const world300 = buildMockBattleWorld(300);

  // 对准交战中心 (2400, 1200)，缩放 0.90 确保全部 300 名火柴人同屏可见且处于完整 8 关节骨骼 LOD！
  battleRenderer.setCamera(2400, 1200, 0.90);
  const stats300 = battleRenderer.render(mockCtx, world300, {
    selectedSquadIds: [1],
    marqueeActive: true,
    marqueeStartX: 220,
    marqueeStartY: 180,
    marqueeEndX: 520,
    marqueeEndY: 420,
    stylusTrailScreenX: [400, 480, 560, 650],
    stylusTrailScreenY: [320, 270, 260, 310],
    fogOfWarEnabled: true
  });

  assert.equal(mockCtx.saveDepth, 0, 'save/restore stack must return to 0');
  assert.equal(stats300.visibleSoldiers, 300, 'All 300 soldiers must be visible in viewport');
  assert.equal(stats300.isFarLod, false, 'zoom=0.90 must use full 8-joint LOD');
  assert.ok(
    mockCtx.strokeCount < 45,
    `Expected batched strokeCount < 45 for 300 fighting stickmen, got ${mockCtx.strokeCount}`
  );
  console.log(
    `  -> 300 同屏士兵（含150遗骸+60箭石+城防+小地图）单帧 stroke=${mockCtx.strokeCount} (<45 PASS), fill=${mockCtx.fillCount}, lineTo=${mockCtx.lineToCount}`
  );

  // 极限 600 人对象池满载测试
  mockCtx.reset();
  const world600 = buildMockBattleWorld(600);
  battleRenderer.setCamera(2400, 1200, 0.65);
  const stats600 = battleRenderer.render(mockCtx, world600);
  assert.equal(mockCtx.saveDepth, 0);
  assert.ok(stats600.visibleSoldiers >= 550);
  assert.ok(
    mockCtx.strokeCount < 45,
    `Expected batched strokeCount < 45 even for 600 soldiers, got ${mockCtx.strokeCount}`
  );
  console.log(
    `  -> 600 满池士兵极限同屏单帧 stroke=${mockCtx.strokeCount} (<45 PASS), visible=${stats600.visibleSoldiers}`
  );

  console.log('=== [2/5] 测试平板高分屏视口裁剪（Viewport Culling）与战争迷雾剔除 ===');
  mockCtx.reset();
  // 将视口移至左上角，中央 (2400,1200) 的全部 300 名火柴人与 150 具遗骸均位于视口 + 96px 之外
  battleRenderer.setViewportSize(1280, 800);
  battleRenderer.setCamera(100, 100, 1.25);
  const statsCorner = battleRenderer.render(mockCtx, world300);
  assert.equal(statsCorner.visibleSoldiers, 0, 'Off-screen soldiers must be 100% culled');
  assert.equal(statsCorner.culledSoldiers, 300, 'All 300 off-screen soldiers must be counted as culled');
  assert.equal(statsCorner.renderedCorpses, 0, 'Off-screen corpses must be 100% culled');
  assert.equal(statsCorner.renderedProjectiles, 0, 'Off-screen projectiles must be 100% culled');
  console.log(
    `  -> 角落视口裁剪: visibleSoldiers=${statsCorner.visibleSoldiers}, culled=${statsCorner.culledSoldiers}, stroke=${mockCtx.strokeCount} (PASS)`
  );

  // 验证战争迷雾不可见敌军剔除
  for (let i = 150; i < 300; i++) {
    world300.soldiers[i].visibleToPlayer = false;
  }
  battleRenderer.setCamera(2400, 1200, 0.90);
  mockCtx.reset();
  const statsFogOn = battleRenderer.render(mockCtx, world300, { fogOfWarEnabled: true });
  assert.equal(statsFogOn.visibleSoldiers, 150, 'Hidden enemy soldiers must be culled by Fog of War');
  const statsFogOff = battleRenderer.render(mockCtx, world300, { fogOfWarEnabled: false });
  assert.equal(statsFogOff.visibleSoldiers, 300, 'Disabling Fog of War reveals all 300 soldiers');
  for (let i = 150; i < 300; i++) {
    world300.soldiers[i].visibleToPlayer = true;
  }

  console.log('=== [3/5] 测试 zoom = 0.50 远景 LOD 与 zoom = 1.20 完整 8 关节 LOD 切换及零 NaN 断言 ===');
  battleRenderer.setViewportSize(1600, 1000);
  mockCtx.reset();
  battleRenderer.setCamera(2400, 1200, 0.50);
  const statsFar = battleRenderer.render(mockCtx, world300);
  const farLineToCount = mockCtx.lineToCount;
  assert.equal(statsFar.isFarLod, true, 'zoom=0.50 must activate Far LOD');
  assert.equal(statsFar.visibleSoldiers, 300);

  mockCtx.reset();
  battleRenderer.setCamera(2400, 1200, 1.20);
  const statsNear = battleRenderer.render(mockCtx, world300);
  const nearLineToCount = mockCtx.lineToCount;
  assert.equal(statsNear.isFarLod, false, 'zoom=1.20 must activate Full 8-joint LOD');
  assert.equal(statsNear.visibleSoldiers, 300);
  assert.ok(
    nearLineToCount > farLineToCount + 900,
    `Full 8-joint LOD lineTo (${nearLineToCount}) must exceed Far LOD (${farLineToCount}) due to articulated elbows/knees`
  );
  console.log(
    `  -> LOD 切换正常且零 NaN: zoom=0.50(FarLOD, lineTo=${farLineToCount}) vs zoom=1.20(FullLOD, lineTo=${nearLineToCount}) (PASS)`
  );

  // 极端脏值防御与 5600x2600 攻城全天候及主帅两段式重伤态零 NaN 断言
  world300.width = GameConstants.SIEGE_BATTLEFIELD_WIDTH;
  world300.height = GameConstants.SIEGE_BATTLEFIELD_HEIGHT;
  world300.soldiers[0].maxHp = 0;
  world300.soldiers[0].animPhase = Number.NaN;
  world300.soldiers[0].facingRad = Number.NaN;
  world300.projectiles[0].flightDuration = 0;
  world300.playerHero.vitalState = HeroVitalState.RECOVERING_IN_CAMP;
  world300.playerHero.recoveryTimer = 22;
  world300.enemyHero.vitalState = HeroVitalState.FALLEN_MARTYRED;
  for (const w of [WeatherType.CLEAR_DAY, WeatherType.HEAVY_FOG, WeatherType.RAIN_MUD, WeatherType.BLIZZARD, WeatherType.NIGHT]) {
    world300.weather = w;
    mockCtx.reset();
    battleRenderer.render(mockCtx, world300);
    assert.equal(mockCtx.saveDepth, 0);
  }
  // 恢复标准野战状态供后续坐标拾取测试
  world300.width = GameConstants.BATTLEFIELD_WIDTH;
  world300.height = GameConstants.BATTLEFIELD_HEIGHT;
  world300.soldiers[0].maxHp = 200;
  world300.soldiers[0].animPhase = 0.25;
  world300.soldiers[0].facingRad = 0;
  world300.projectiles[0].flightDuration = 1.2;
  world300.playerHero.vitalState = HeroVitalState.HEALTHY_ACTIVE;
  world300.enemyHero.vitalState = HeroVitalState.HEALTHY_ACTIVE;

  console.log('=== [4/5] 测试战场坐标互逆、40ms 顿帧震屏、主帅跟随、手写笔 24px / 手指 44px 拾取与小地图 ===');
  battleRenderer.setViewportSize(1440, 900);
  battleRenderer.setCamera(2150, 1180, 1.15);

  // 4.1 常规与震屏态下 screenToWorld <-> worldToScreen 精确互逆
  battleRenderer.triggerHitStopShake(40, 6.0);
  world300.hud.controlMode = BattleControlMode.HERO_ACTION;
  world300.hud.hitStopRemainingMs = 28;
  battleRenderer.updateCamera(world300, 0.016);

  const sampleWorldPts = [
    { x: 1820.5, y: 940.25 },
    { x: 2400.0, y: 1200.0 },
    { x: 2795.75, y: 1488.125 }
  ];
  for (const pt of sampleWorldPts) {
    const scr = battleRenderer.worldToScreen(pt.x, pt.y);
    const back = battleRenderer.screenToWorld(scr.x, scr.y);
    assert.ok(Math.abs(back.x - pt.x) < 1e-8, `world->screen->world X drift: ${back.x} vs ${pt.x}`);
    assert.ok(Math.abs(back.y - pt.y) < 1e-8, `world->screen->world Y drift: ${back.y} vs ${pt.y}`);
  }

  // 4.2 捏合缩放锚点不变性
  world300.hud.hitStopRemainingMs = 0;
  battleRenderer.triggerHitStopShake(1, 0);
  battleRenderer.updateCamera(world300, 0.05);
  battleRenderer.setCamera(2400, 1200, 0.80);
  const anchorSX = 520;
  const anchorSY = 340;
  const worldBeforePinch = battleRenderer.screenToWorld(anchorSX, anchorSY);
  battleRenderer.zoomAtScreenPoint(1.35, anchorSX, anchorSY);
  const worldAfterPinch = battleRenderer.screenToWorld(anchorSX, anchorSY);
  assert.ok(Math.abs(worldAfterPinch.x - worldBeforePinch.x) < 1e-6, 'Pinch zoom must preserve anchor world X');
  assert.ok(Math.abs(worldAfterPinch.y - worldBeforePinch.y) < 1e-6, 'Pinch zoom must preserve anchor world Y');

  // 4.3 手写笔 24px vs 手指 44px 差异化拾取测试
  const sq2 = world300.squads[1]; // center at (2190, 1330), no soldiers right at (2190, 1330 + offset)
  // 将士兵临时移开以纯粹测试编队中心 24px / 44px 拾取边界
  const savedY = world300.soldiers.map((s) => s.y);
  for (const s of world300.soldiers) {
    s.y = 400;
  }
  const sq2Scr = battleRenderer.worldToScreen(sq2.centerX, sq2.centerY);
  const stylusMiss = battleRenderer.pickSquadAtScreenPos(world300, sq2Scr.x + 34, sq2Scr.y, true, BattleSide.PLAYER);
  const stylusHit = battleRenderer.pickSquadAtScreenPos(world300, sq2Scr.x + 18, sq2Scr.y, true, BattleSide.PLAYER);
  const fingerHit = battleRenderer.pickSquadAtScreenPos(world300, sq2Scr.x + 34, sq2Scr.y, false, BattleSide.PLAYER);
  assert.equal(stylusMiss, null, 'M-Pencil 24px radius must reject 34px offset');
  assert.equal(stylusHit?.squadId, sq2.squadId, 'M-Pencil 24px radius must hit 18px offset');
  assert.equal(fingerHit?.squadId, sq2.squadId, 'Finger 44px radius must hit 34px offset');
  for (let i = 0; i < world300.soldiers.length; i++) {
    world300.soldiers[i].y = savedY[i];
  }

  // 4.4 框选矩形拾取测试
  const sq1Scr = battleRenderer.worldToScreen(world300.squads[0].centerX, world300.squads[0].centerY);
  const rectPicked = battleRenderer.pickSquadsInScreenRect(
    world300,
    sq1Scr.x - 30,
    sq1Scr.y - 30,
    sq1Scr.x + 30,
    sq1Scr.y + 30,
    BattleSide.PLAYER
  );
  assert.ok(rectPicked.includes(1), 'Marquee screen rect must pick squad #1');

  // 4.5 战场小地图正逆变换与点击秒跳测试
  const mmTargetW = { x: 3420, y: 1680 };
  const mmScr = battleRenderer.worldToMinimapScreen(mmTargetW.x, mmTargetW.y);
  assert.equal(battleRenderer.isPointInMinimap(mmScr.x, mmScr.y), true);
  const mmBack = battleRenderer.minimapScreenToWorld(mmScr.x, mmScr.y);
  assert.ok(mmBack !== null);
  assert.ok(Math.abs(mmBack.x - mmTargetW.x) < 1e-6, 'Battle minimap world<->screen X must invert accurately');
  assert.ok(Math.abs(mmBack.y - mmTargetW.y) < 1e-6, 'Battle minimap world<->screen Y must invert accurately');
  assert.equal(battleRenderer.handleMinimapTap(mmScr.x, mmScr.y), true);
  assert.ok(Math.abs(battleRenderer.getCameraX() - mmTargetW.x) < 1e-4);
  console.log('  -> 战场坐标互逆、震屏、M-Pencil/手指拾取、框选与小地图秒跳全部通过 (PASS)');

  console.log('=== [5/5] 测试 3600×2400 战略大地图 40 城关、动态粮道着色、BFS 粮道与全局小地图 ===');
  const campaignRenderer = new CampaignMapRenderer(1440, 900);
  const roadEdges = campaignRenderer.getRoadEdges();
  assert.equal(CAMPAIGN_MAP_NODES.length, 40, 'Must have 40 campaign nodes');
  assert.equal(roadEdges.length, 78, `Expected exactly 78 symmetric road edges, got ${roadEdges.length}`);

  // 构造含满补给、远征琥珀虚线、断粮猩红告警线、围困孤城与伏兵暗记的大地图状态
  const campaignState = {
    schemaVersion: 1,
    turnNumber: 12,
    playerFaction: FactionId.YANLONG,
    nodes: CAMPAIGN_MAP_NODES.map((n, idx) => {
      let owner = n.initialOwner;
      let grade = SupplyLineGrade.FULL_SUPPLY;
      let isolatedTurns = 0;
      let hasAmbushTrap = idx === 21;
      // 让炎龙远征夺取苍狼草原节点形成多层补给梯度
      if (n.id === 'cl_river') {
        owner = FactionId.YANLONG;
        grade = SupplyLineGrade.EXTENDED_MARCH;
      } else if (n.id === 'cl_fort') {
        owner = FactionId.YANLONG;
        grade = SupplyLineGrade.OVEREXTENDED;
      } else if (n.id === 'xj_beacon') {
        owner = FactionId.YANLONG;
        grade = SupplyLineGrade.SEVERED;
        isolatedTurns = 2;
      }
      return {
        nodeId: n.id,
        owner,
        garrisonStrength: 180 + idx * 5,
        defenseHp: 1000,
        isolatedTurns,
        hasAmbushTrap,
        supplyGrade: grade,
        supplyHops: grade === SupplyLineGrade.FULL_SUPPLY ? 1 : (grade === SupplyLineGrade.EXTENDED_MARCH ? 3 : 99)
      };
    }),
    factions: [
      {
        factionId: FactionId.YANLONG,
        isAlive: true,
        gold: 1200,
        wood: 800,
        grain: 1500,
        credibility: 88,
        unlockedTechIds: [],
        commanderLevel: 3,
        commanderExp: 240,
        betrayalMoralePenaltyBattles: 0,
        commanderInjuredTurns: 0,
        fieldArmyRoster: [],
        armyLocationNodeId: 'cl_fort'
      }
    ],
    diplomacy: [
      {
        factionA: FactionId.YANLONG,
        factionB: FactionId.CANGLANG,
        relation: -85,
        status: DiplomaticStatus.WAR,
        remainingTurns: 0,
        vendettaLockTurns: 0
      }
    ],
    totalBattlesFought: 6,
    totalBattlesWon: 5,
    totalEnemiesKilled: 1420,
    recentLogs: []
  };

  // 验证 BFS 粮道查找：cl_fort -> cl_river -> yl_pass -> yl_capital (isSupplyDepot=true)
  const bfsPath = campaignRenderer.computeBfsSupplyPath(campaignState, 'cl_fort');
  assert.ok(bfsPath.length >= 3, `Expected multi-hop BFS supply path for cl_fort, got ${JSON.stringify(bfsPath)}`);
  const depotNode = CAMPAIGN_MAP_NODES.find((n) => n.id === bfsPath[0]);
  assert.equal(depotNode?.isSupplyDepot, true, 'BFS supply path must originate at an isSupplyDepot node');
  assert.equal(bfsPath[bfsPath.length - 1], 'cl_fort', 'BFS supply path must end at selected node');

  // 被阻断孤城 xj_beacon（周围 cl_fort 若改回敌占）应返回空粮道；缔结 ALLIANCE 后则可借盟友粮道连通！
  campaignState.nodes.find((n) => n.nodeId === 'cl_fort').owner = FactionId.CANGLANG;
  const severedPath = campaignRenderer.computeBfsSupplyPath(campaignState, 'xj_beacon');
  assert.equal(severedPath.length, 0, 'Isolated node with no friendly/allied path to depot must return empty BFS path');
  campaignState.diplomacy[0].status = DiplomaticStatus.ALLIANCE;
  const alliedBorrowedPath = campaignRenderer.computeBfsSupplyPath(campaignState, 'xj_beacon');
  assert.ok(alliedBorrowedPath.length >= 2, 'Military ALLIANCE must open supply-line borrowing via allied nodes');
  campaignState.diplomacy[0].status = DiplomaticStatus.WAR;
  campaignState.nodes.find((n) => n.nodeId === 'cl_fort').owner = FactionId.YANLONG;

  // 全景缩放绘制全图 40 城关与全部粮道状态
  mockCtx.reset();
  campaignRenderer.tickAnimation(0.12);
  campaignRenderer.setCamera(1800, 1200, 0.45);
  const campStats = campaignRenderer.render(mockCtx, campaignState, {
    selectedNodeId: 'cl_fort',
    hoveredNodeId: 'yl_capital'
  });

  assert.equal(mockCtx.saveDepth, 0, 'Campaign render save/restore stack must balance');
  assert.equal(campStats.visibleNodes, 40, 'At zoom=0.45 on 1440x900 all 40 nodes must be visible');
  assert.ok(campStats.highlightedSupplyEdges >= 2, 'Selected node BFS supply route must highlight edges');
  assert.ok(mockCtx.strokeCount < 25, `Campaign 40-city batched strokeCount must be < 25, got ${mockCtx.strokeCount}`);
  assert.ok(mockCtx.usedStrokeStyles.has('#2ECC71'), 'Must draw FULL_SUPPLY emerald solid roads');
  assert.ok(mockCtx.usedStrokeStyles.has('#FFB300'), 'Must draw EXTENDED_MARCH amber dashed roads');
  assert.ok(mockCtx.usedStrokeStyles.has('#FF7043'), 'Must draw OVEREXTENDED deep-orange dashed roads');
  assert.ok(mockCtx.usedStrokeStyles.has('#FF1744'), 'Must draw SEVERED crimson warning roads');
  assert.ok(mockCtx.drawnTexts.includes('炎龙帝都'), 'Must render capital city name');

  // 大地图 screenToWorld <-> worldToScreen、城关拾取与全局小地图互逆测试
  campaignRenderer.setCamera(1860, 1180, 1.10);
  const ylCap = CAMPAIGN_MAP_NODES.find((n) => n.id === 'yl_capital');
  const ylScr = campaignRenderer.worldToScreen(ylCap.x, ylCap.y);
  const ylBack = campaignRenderer.screenToWorld(ylScr.x, ylScr.y);
  assert.ok(Math.abs(ylBack.x - ylCap.x) < 1e-8, 'Campaign world->screen->world X must be exact');
  assert.ok(Math.abs(ylBack.y - ylCap.y) < 1e-8, 'Campaign world->screen->world Y must be exact');

  const pickedCity = campaignRenderer.pickNodeAtScreenPos(ylScr.x + 12, ylScr.y - 8, true);
  assert.equal(pickedCity?.id, 'yl_capital', 'pickNodeAtScreenPos must pick 炎龙帝都');

  const campMmWorld = { x: 2680, y: 1560 };
  const campMmScr = campaignRenderer.worldToMinimapScreen(campMmWorld.x, campMmWorld.y);
  const campMmBack = campaignRenderer.minimapScreenToWorld(campMmScr.x, campMmScr.y);
  assert.ok(campMmBack !== null);
  assert.ok(Math.abs(campMmBack.x - campMmWorld.x) < 1e-6, 'Campaign minimap X round-trip must be exact');
  assert.ok(Math.abs(campMmBack.y - campMmWorld.y) < 1e-6, 'Campaign minimap Y round-trip must be exact');
  assert.equal(campaignRenderer.handleMinimapTap(campMmScr.x, campMmScr.y), true);
  assert.ok(Math.abs(campaignRenderer.getCameraX() - campMmWorld.x) < 1e-4);

  console.log(
    `  -> 大地图 40 城关 + ${roadEdges.length} 条道路 + 动态三级补给线 + BFS 粮道高亮 + 小地图秒跳全部通过 (PASS)`
  );

  // =========================================================================
  // [6/6] 真实核心引擎快照直连双渲染器闭环测试（验证城墙左上角无缝拼接与战役真实状态渲染）
  // =========================================================================
  console.log('=== [6/6] 测试 BattleSimulator & CampaignEngine 真实引擎快照直连双渲染器闭环 ===');
  const realSiegeSim = new BattleSimulator({
    scenarioType: BattleScenarioType.SIEGE_ASSAULT,
    playerFaction: FactionId.YANLONG,
    enemyFaction: FactionId.TIEYING,
    terrain: TerrainType.FORT_WALL,
    weather: WeatherType.RAIN_MUD,
    playerArmyRoster: [
      { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 24, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
      { unitType: UnitTypeId.GREAT_AXEMAN, count: 12, corpsRole: ArmyCorpsRole.LEFT_WING },
      { unitType: UnitTypeId.TREBUCHET, count: 2, corpsRole: ArmyCorpsRole.SIEGE_BATTERY }
    ],
    enemyArmyRoster: [
      { unitType: UnitTypeId.PIKEMAN, count: 20, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
      { unitType: UnitTypeId.TIEYING_PAVISE_CROSSBOW, count: 16, corpsRole: ArmyCorpsRole.SIEGE_BATTERY }
    ]
  });
  for (let i = 0; i < 30; i++) {
    realSiegeSim.stepTick(0.1);
  }
  const realBattleView = realSiegeSim.getWorldView();
  battleRenderer.setViewportSize(1440, 900);
  battleRenderer.setCamera(2600, 1300, 0.40);
  mockCtx.reset();
  const realBattleStats = battleRenderer.render(mockCtx, realBattleView, { fogOfWarEnabled: true });
  assert.equal(mockCtx.saveDepth, 0, 'Real BattleSimulator snapshot render must keep save/restore balanced');
  assert.ok(mockCtx.strokeCount < 45, `Real siege strokeCount must be < 45, got ${mockCtx.strokeCount}`);
  assert.ok(realBattleStats.visibleSoldiers > 0, 'Real siege snapshot should have visible stickman soldiers');

  // 验证北城墙 (y=240,h=930)、城门 (y=1170,h=260)、南城墙 (y=1430,h=930) 按左上角精确无缝拼接（无 465px 中心错位！）
  const nWall = realBattleView.structures.find((s) => s.id === 'fort_wall_north');
  const mGate = realBattleView.structures.find((s) => s.id === 'fort_main_gate');
  const sWall = realBattleView.structures.find((s) => s.id === 'fort_wall_south');
  assert.equal(nWall.y + nWall.height, mGate.y, '北城墙底边必须与城门顶边严丝合缝');
  assert.equal(mGate.y + mGate.height, sWall.y, '城门底边必须与南城墙顶边严丝合缝');

  const northWallDraw = mockCtx.recordedFillRects.find(
    (r) => r.x === nWall.x && r.y === nWall.y && r.w === nWall.width && r.h === nWall.height
  );
  const gateDraw = mockCtx.recordedFillRects.find(
    (r) => r.x === mGate.x && r.y === mGate.y && r.w === mGate.width && r.h === mGate.height
  );
  const southWallDraw = mockCtx.recordedFillRects.find(
    (r) => r.x === sWall.x && r.y === sWall.y && r.w === sWall.width && r.h === sWall.height
  );
  assert.ok(northWallDraw !== undefined, '北城墙必须精确绘制在引擎左上角坐标');
  assert.ok(gateDraw !== undefined, '中段城门必须无缝衔接绘制在引擎左上角坐标');
  assert.ok(southWallDraw !== undefined, '南城墙必须无缝衔接绘制在引擎左上角坐标');

  const realCampaign = new CampaignEngine(FactionId.XUANJIA);
  realCampaign.getNodeRuntime('cl_fort').owner = FactionId.XUANJIA;
  realCampaign.advanceTurn();
  mockCtx.reset();
  campaignRenderer.setCamera(1800, 1200, 0.45);
  const realCampStats = campaignRenderer.render(mockCtx, realCampaign.getState(), {
    selectedNodeId: 'cl_fort'
  });
  assert.equal(mockCtx.saveDepth, 0);
  assert.equal(realCampStats.visibleNodes, 40);
  assert.ok(mockCtx.strokeCount < 25);

  // 验证 SettingsStore LOD 策略与 M-Pencil 灵敏度半径与双渲染器实时联动
  battleRenderer.setCamera(2600, 1300, 0.75);
  battleRenderer.setLodPolicyMode('perf_saver');
  const perfStats = battleRenderer.render(mockCtx, realBattleView, { fogOfWarEnabled: true });
  assert.equal(perfStats.isFarLod, true, 'perf_saver policy at zoom=0.75 must engage streamlined Far LOD');
  battleRenderer.setLodPolicyMode('high_detail');
  battleRenderer.setCamera(2600, 1300, 0.50);
  const hdStats = battleRenderer.render(mockCtx, realBattleView, { fogOfWarEnabled: true });
  assert.equal(hdStats.isFarLod, false, 'high_detail policy at zoom=0.50 must preserve full 8-joint LOD');
  battleRenderer.setLodPolicyMode('auto_by_zoom');
  battleRenderer.setStylusPickRadiusPx(30);
  campaignRenderer.setStylusPickRadiusPx(30);
  console.log('  -> 真实引擎快照直连战场渲染器（城墙无缝拼接、设置LOD联动）与战略大地图渲染器全部通过 (PASS)');

  console.log('\nALL RENDERER AUTOMATED TESTS PASSED SUCCESSFULLY!');
}

runAllTests();
