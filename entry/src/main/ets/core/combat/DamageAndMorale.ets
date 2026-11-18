/**
 * 伤害数学模型、八象限包抄合围、士气迟滞防抖、断粮三级惩罚与迷雾视野引擎（DamageAndMorale.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖，零每帧 GC）
 */
import { GameConstants } from '../../common/GameConstants';
import {
  BattlefieldRationStage,
  BattleSide,
  CommanderHeroRuntime,
  EncirclementState,
  FactionId,
  FormationType,
  HeroVitalState,
  SoldierRuntimeEntity,
  SquadRuntimeState,
  TerrainType,
  UnitActionState,
  UnitCategory,
  UnitTypeId,
  WeatherType
} from '../CoreContracts';
import { SpatialHashGrid } from './SpatialHashGrid';

const RAD_TO_DEG: number = 180.0 / Math.PI;
const TWO_PI: number = Math.PI * 2.0;
const OCTANT_SLICE_RAD: number = Math.PI / 4.0;
const HALF_OCTANT_RAD: number = Math.PI / 8.0;

/** 方向性受击修正复用容器（零分配复用） */
export class DirectionalCombatModifiers {
  public incomingAngleDeg: number = 0;
  public damageMult: number = 1.0;
  public moraleShockMult: number = 1.0;
  public disableShieldAndBrace: boolean = false;
}

/** 单次伤害结算完整输入参数结构 */
export class DamageFormulaParams {
  public baseAttack: number = 10;
  public targetArmor: number = 0;
  public attackerArmorPen: number = 0;
  public bonusArmorPen: number = 0;
  public shieldRangedBlock: number = 0;
  public isRanged: boolean = false;
  public isExplosion: boolean = false;
  public incomingAngleDeg: number = 0;
  public isCircleDefense: boolean = false;
  public isBridgePass: boolean = false;
  public isPaviseReloading: boolean = false;
  public isTargetRouting: boolean = false;
  public chargeMult: number = 1.0;
  public antiCavMult: number = 1.0;
  public terrainMult: number = 1.0;
  public moraleMult: number = 1.0;
  public rationMult: number = 1.0;
  public halfFordMult: number = 1.0;
  public critMult: number = 1.0;

  public reset(): void {
    this.baseAttack = 10;
    this.targetArmor = 0;
    this.attackerArmorPen = 0;
    this.bonusArmorPen = 0;
    this.shieldRangedBlock = 0;
    this.isRanged = false;
    this.isExplosion = false;
    this.incomingAngleDeg = 0;
    this.isCircleDefense = false;
    this.isBridgePass = false;
    this.isPaviseReloading = false;
    this.isTargetRouting = false;
    this.chargeMult = 1.0;
    this.antiCavMult = 1.0;
    this.terrainMult = 1.0;
    this.moraleMult = 1.0;
    this.rationMult = 1.0;
    this.halfFordMult = 1.0;
    this.critMult = 1.0;
  }
}

/** 将弧度归一化到 [-PI, +PI] */
export function normalizeAngleSigned(rad: number): number {
  let a: number = rad % TWO_PI;
  if (a > Math.PI) {
    a -= TWO_PI;
  } else if (a < -Math.PI) {
    a += TWO_PI;
  }
  return a;
}

/**
 * 计算受击方正面朝向与威胁来袭方向之间的夹角（度，[0, 180]）
 * 0° 表示威胁来自正前方，90° 表示正侧面，180° 表示正背后
 */
export function computeAttackIncomingAngleDeg(
  defenderFacingRad: number,
  defenderX: number,
  defenderY: number,
  threatSourceX: number,
  threatSourceY: number
): number {
  const dx: number = threatSourceX - defenderX;
  const dy: number = threatSourceY - defenderY;
  const distSq: number = dx * dx + dy * dy;
  if (distSq < 1e-8) {
    return 0;
  }
  const dist: number = Math.sqrt(distSq);
  const fx: number = Math.cos(defenderFacingRad);
  const fy: number = Math.sin(defenderFacingRad);
  let cosTheta: number = (fx * dx + fy * dy) / dist;
  if (cosTheta > 1.0) {
    cosTheta = 1.0;
  } else if (cosTheta < -1.0) {
    cosTheta = -1.0;
  }
  return Math.acos(cosTheta) * RAD_TO_DEG;
}

/** 计算有效护甲 A_eff = max(0, A_target * (1 - clamp(Pen + BonusPen, 0, 1))) */
export function computeEffectiveArmor(
  targetArmor: number,
  armorPenetration: number,
  bonusPenetration: number = 0
): number {
  if (targetArmor <= 0) {
    return 0;
  }
  let totalPen: number = armorPenetration + bonusPenetration;
  if (totalPen < 0) {
    totalPen = 0;
  } else if (totalPen > 1.0) {
    totalPen = 1.0;
  }
  return Math.max(0, targetArmor * (1.0 - totalPen));
}

/** 双曲护甲减伤率 Mitigation(A_eff) = A_eff / (A_eff + 50) */
export function computeHyperbolicMitigation(effectiveArmor: number): number {
  if (effectiveArmor <= 0) {
    return 0;
  }
  return effectiveArmor / (effectiveArmor + 50.0);
}

/**
 * 正面盾牌远程减伤乘数 M_shield = 1 - effectiveBlock
 * - <= 60° 全额格挡；60°~120° 减半；> 120° 背射归零
 * - 圆阵 CIRCLE_DEFENSE 360° 全向全额格挡
 * - 铁鹰重装神弩手换弹期背盾享全额 60% 远程减免
 * - 溃逃态弃盾狂奔失去格挡
 */
export function computeRangedShieldMultiplier(
  shieldRangedBlock: number,
  incomingAngleDeg: number,
  isCircleDefense: boolean,
  isPaviseReloading: boolean = false,
  isRouting: boolean = false
): number {
  if (isRouting || shieldRangedBlock <= 0) {
    return 1.0;
  }
  let clampedBlock: number = shieldRangedBlock;
  if (clampedBlock > 0.85) {
    clampedBlock = 0.85;
  }
  if (isPaviseReloading || isCircleDefense) {
    return 1.0 - clampedBlock;
  }
  if (incomingAngleDeg <= 60.0) {
    return 1.0 - clampedBlock;
  }
  if (incomingAngleDeg <= 120.0) {
    return 1.0 - clampedBlock * 0.5;
  }
  return 1.0;
}

/**
 * 侧翼（60°~135°）与背击（>135°）增伤及士气倍率判定
 * 圆阵 360° 免除侧背惩罚；桥梁窄关免除侧击加成
 */
export function computeDirectionalModifiers(
  incomingAngleDeg: number,
  isCircleDefense: boolean,
  isBridgePass: boolean,
  outMod: DirectionalCombatModifiers
): void {
  outMod.incomingAngleDeg = incomingAngleDeg;
  if (isCircleDefense) {
    outMod.damageMult = 1.0;
    outMod.moraleShockMult = 1.0;
    outMod.disableShieldAndBrace = false;
    return;
  }
  if (incomingAngleDeg > 135.0) {
    outMod.damageMult = GameConstants.REAR_DAMAGE_MULTIPLIER;
    outMod.moraleShockMult = 2.0;
    outMod.disableShieldAndBrace = true;
    return;
  }
  if (incomingAngleDeg > 60.0) {
    if (isBridgePass) {
      outMod.damageMult = 1.0;
      outMod.moraleShockMult = 1.0;
    } else {
      outMod.damageMult = GameConstants.FLANK_DAMAGE_MULTIPLIER;
      outMod.moraleShockMult = 1.5;
    }
    outMod.disableShieldAndBrace = false;
    return;
  }
  outMod.damageMult = 1.0;
  outMod.moraleShockMult = 1.0;
  outMod.disableShieldAndBrace = false;
}

/**
 * 判定长枪方阵兵 / 炎龙神机重卫是否触发【正面架枪迎骑】
 * 条件：非溃逃、非冲锋狂奔态，正面（<= 90° 或圆阵 360°）迎向冲锋态骑兵
 */
export function isBracedAntiCavalryTriggered(
  defenderUnitType: UnitTypeId,
  defenderActionState: UnitActionState,
  defenderCurrentSpeed: number,
  defenderMaxSpeed: number,
  isDefenderRouting: boolean,
  incomingAngleDeg: number,
  isCircleDefense: boolean,
  isCavalryCharging: boolean
): boolean {
  if (!isCavalryCharging || isDefenderRouting) {
    return false;
  }
  if (
    defenderUnitType !== UnitTypeId.PIKEMAN &&
    defenderUnitType !== UnitTypeId.YANLONG_HALBERD_GRENADIER
  ) {
    return false;
  }
  if (
    defenderActionState === UnitActionState.CHARGE_SPRINT ||
    defenderActionState === UnitActionState.ROUT_PANIC ||
    defenderActionState === UnitActionState.DYING_FALL ||
    defenderActionState === UnitActionState.FALLEN_CORPSE
  ) {
    return false;
  }
  if (defenderMaxSpeed > 0 && defenderCurrentSpeed > defenderMaxSpeed * 0.55) {
    return false;
  }
  if (!isCircleDefense && incomingAngleDeg > 90.0) {
    return false;
  }
  return true;
}

/** 士气区间对攻击力的乘数修正（DESIGN.md 4.3） */
export function computeMoraleAttackMultiplier(morale: number): number {
  if (morale >= 85.0) {
    return 1.12;
  }
  if (morale >= GameConstants.MORALE_WAVERING_THRESHOLD) {
    return 1.0;
  }
  if (morale >= GameConstants.MORALE_ROUT_THRESHOLD) {
    return 0.80;
  }
  return 0.50;
}

/** 士气区间对护甲有效率的乘数修正（动摇 < 40 时护甲有效率 -15%） */
export function computeMoraleArmorMultiplier(morale: number): number {
  if (morale < GameConstants.MORALE_WAVERING_THRESHOLD) {
    return 0.85;
  }
  return 1.0;
}

/**
 * 完整单次伤害结算函数（最低保底伤害 2）
 */
const sharedDirMod: DirectionalCombatModifiers = new DirectionalCombatModifiers();

export function computeFinalHitDamage(params: DamageFormulaParams): number {
  computeDirectionalModifiers(
    params.incomingAngleDeg,
    params.isCircleDefense,
    params.isBridgePass,
    sharedDirMod
  );

  const effectiveBonusPen: number = sharedDirMod.disableShieldAndBrace ? 0 : params.bonusArmorPen;
  const effectiveAntiCav: number = sharedDirMod.disableShieldAndBrace ? 1.0 : params.antiCavMult;
  const effArmor: number = computeEffectiveArmor(
    params.targetArmor,
    params.attackerArmorPen,
    effectiveBonusPen
  );
  const mitigation: number = computeHyperbolicMitigation(effArmor);

  let shieldMult: number = 1.0;
  if (params.isRanged) {
    if (sharedDirMod.disableShieldAndBrace && !params.isPaviseReloading) {
      shieldMult = 1.0;
    } else {
      shieldMult = computeRangedShieldMultiplier(
        params.shieldRangedBlock,
        params.incomingAngleDeg,
        params.isCircleDefense,
        params.isPaviseReloading,
        params.isTargetRouting
      );
    }
  }

  const rawDamage: number =
    params.baseAttack *
    params.chargeMult *
    effectiveAntiCav *
    params.terrainMult *
    params.moraleMult *
    params.rationMult *
    params.halfFordMult *
    params.critMult *
    sharedDirMod.damageMult *
    shieldMult *
    (1.0 - mitigation);

  return Math.max(2.0, rawDamage);
}

/**
 * 将相对于分队朝向的带符号弧度 [-PI, +PI] 映射到 8 象限索引 0..7
 * 0: 正前 [-22.5°, +22.5°)
 * 1: 右前 [+22.5°, +67.5°)
 * 2: 正右 [+67.5°, +112.5°)
 * 3: 右后 [+112.5°, +157.5°)
 * 4: 正后 [+157.5°, 180°] U [-180°, -157.5°)
 * 5: 左后 [-157.5°, -112.5°)
 * 6: 正左 [-112.5°, -67.5°)
 * 7: 左前 [-67.5°, -22.5°)
 */
export function relativeAngleToOctant(relRad: number): number {
  let shifted: number = normalizeAngleSigned(relRad) + HALF_OCTANT_RAD;
  if (shifted < 0) {
    shifted += TWO_PI;
  }
  const idx: number = Math.floor(shifted / OCTANT_SLICE_RAD) & 7;
  return idx;
}

/** 统计 8 位掩码中置位扇区数 */
export function countOctantBits(mask: number): number {
  let v: number = mask & 0xff;
  let c: number = 0;
  while (v !== 0) {
    v &= v - 1;
    c++;
  }
  return c;
}

/** 计算两个象限索引之间的最小环形步距（0..4，每步 45°） */
export function octantCircularDist(a: number, b: number): number {
  const diff: number = Math.abs(a - b);
  return diff > 4 ? 8 - diff : diff;
}

/**
 * 判定掩码是否存在 >= 2 个互成 >= 120°（即环形步距 >= 3，对应 135°/180°）的非正面扇区（1..7）
 */
export function hasPinceredOctantPair(mask: number): boolean {
  const nonFrontMask: number = mask & 0xfe; // 排除 bit 0（正前扇区）
  if (countOctantBits(nonFrontMask) < 2) {
    return false;
  }
  for (let a: number = 1; a <= 7; a++) {
    if ((nonFrontMask & (1 << a)) === 0) {
      continue;
    }
    for (let b: number = a + 1; b <= 7; b++) {
      if ((nonFrontMask & (1 << b)) === 0) {
        continue;
      }
      if (octantCircularDist(a, b) >= 3) {
        return true;
      }
    }
  }
  return false;
}

/**
 * 纯函数判定给定八象限掩码与退路扇区对应的受围状态
 */
export function classifyEncirclementFromMask(
  threatOctantMask: number,
  retreatOctant: number
): EncirclementState {
  const occupiedCount: number = countOctantBits(threatOctantMask);
  if (occupiedCount === 0) {
    return EncirclementState.CLEAR;
  }
  const retreatBlocked: boolean = (threatOctantMask & (1 << (retreatOctant & 7))) !== 0;
  if (occupiedCount >= GameConstants.ENCIRCLEMENT_MIN_OCTANTS && retreatBlocked) {
    return EncirclementState.ENCIRCLED;
  }
  if (hasPinceredOctantPair(threatOctantMask)) {
    return EncirclementState.PINCERED;
  }
  // 侧后扇区（2,3,4,5,6）有敌军视为单侧/后方受袭 FLANKED
  if ((threatOctantMask & 0b01111100) !== 0) {
    return EncirclementState.FLANKED;
  }
  return EncirclementState.CLEAR;
}

/**
 * 对单个分队执行 160px 交战圈八象限扫描，更新 threatOctantMask 与 encirclement
 */
export function scanSquadOctantEncirclement(
  squad: SquadRuntimeState,
  soldiers: readonly SoldierRuntimeEntity[],
  enemyHero: CommanderHeroRuntime,
  grid: SpatialHashGrid,
  ownBaseCampX: number,
  ownBaseCampY: number,
  scratchIndices: Int32Array,
  scanRadius: number = 160.0
): EncirclementState {
  if (squad.aliveCount <= 0) {
    squad.threatOctantMask = 0;
    squad.encirclement = EncirclementState.CLEAR;
    return EncirclementState.CLEAR;
  }

  const hitCount: number = grid.queryRadius(
    soldiers,
    squad.centerX,
    squad.centerY,
    scanRadius,
    scratchIndices
  );

  let mask: number = 0;
  for (let i: number = 0; i < hitCount; i++) {
    const s: SoldierRuntimeEntity = soldiers[scratchIndices[i]];
    if (
      s.side !== squad.side &&
      s.active &&
      s.hp > 0 &&
      s.actionState !== UnitActionState.ROUT_PANIC &&
      s.actionState !== UnitActionState.DYING_FALL &&
      s.actionState !== UnitActionState.FALLEN_CORPSE
    ) {
      const rel: number = Math.atan2(s.y - squad.centerY, s.x - squad.centerX) - squad.facingRad;
      const oct: number = relativeAngleToOctant(rel);
      mask |= 1 << oct;
    }
  }

  // 检查敌方主帅是否在 160px 圈内压迫
  if (
    enemyHero.side !== squad.side &&
    enemyHero.hp > 0 &&
    (enemyHero.vitalState === HeroVitalState.HEALTHY_ACTIVE ||
      enemyHero.vitalState === HeroVitalState.WOUNDED_WEAKENED)
  ) {
    const hdx: number = enemyHero.x - squad.centerX;
    const hdy: number = enemyHero.y - squad.centerY;
    if (hdx * hdx + hdy * hdy <= scanRadius * scanRadius) {
      const relHero: number = Math.atan2(hdy, hdx) - squad.facingRad;
      mask |= 1 << relativeAngleToOctant(relHero);
    }
  }

  const retreatRel: number =
    Math.atan2(ownBaseCampY - squad.centerY, ownBaseCampX - squad.centerX) - squad.facingRad;
  const retreatOctant: number = relativeAngleToOctant(retreatRel);

  squad.threatOctantMask = mask;
  squad.encirclement = classifyEncirclementFromMask(mask, retreatOctant);
  return squad.encirclement;
}

/**
 * 计算断粮三阶段状态（DESIGN.md 10.1）
 * - 余粮 > 0 且可维持 >= 15s: ABUNDANT
 * - 余粮 > 0 且可维持 < 15s: WARNING
 * - 余粮 <= 0 且持续 <= 30s: HUNGRY（-0.8/s 士气，-12% 移速，骑兵冲锋 CD +50%）
 * - 余粮 <= 0 且持续 > 30s: STARVING（-1.8/s 士气，-25% 攻击，商盟无金雇佣兵退场）
 */
export function evaluateRationStage(
  currentGrain: number,
  grainUpkeepPerSec: number,
  zeroGrainDurationSec: number
): BattlefieldRationStage {
  if (currentGrain > 0) {
    if (grainUpkeepPerSec > 0.0001) {
      const remainSec: number = currentGrain / grainUpkeepPerSec;
      if (remainSec < GameConstants.RATION_WARNING_SECONDS) {
        return BattlefieldRationStage.WARNING;
      }
    }
    return BattlefieldRationStage.ABUNDANT;
  }
  if (zeroGrainDurationSec > GameConstants.STARVATION_SEVERE_SECONDS) {
    return BattlefieldRationStage.STARVING;
  }
  return BattlefieldRationStage.HUNGRY;
}

/**
 * 更新分队士气上下限与迟滞环状态（DESIGN.md 4.3）
 * - < 20 触发溃逃（isRouting = true）
 * - 溃逃中必须回升至 >= 32（且脱离近身受敌，或被三军战吼直接唤醒）方可恢复控制
 * - 血月狂战祭团锁定士气 >= 50 不溃
 * - 铁桶合围 ENCIRCLED 士气上限锁死 45；主帅重伤包扎期间全军士气上限锁死 65
 * @returns 若本次调用新触发了由正常转为溃逃（false -> true），返回 true
 */
export function applySquadMoraleAndHysteresis(
  squad: SquadRuntimeState,
  moraleDelta: number,
  heroRecoveringCapActive: boolean,
  forcedWakeByWarCry: boolean = false
): boolean {
  const wasRouting: boolean = squad.isRouting;

  let maxCap: number = GameConstants.MORALE_MAX;
  if (heroRecoveringCapActive && maxCap > GameConstants.HERO_DOWN_MORALE_CAP) {
    maxCap = GameConstants.HERO_DOWN_MORALE_CAP;
  }
  if (squad.encirclement === EncirclementState.ENCIRCLED && maxCap > 45.0) {
    maxCap = 45.0;
  }

  let nextMorale: number = squad.morale + moraleDelta;
  // 血月狂战祭团战鼓锁士气 >= 50（除非铁桶合围被锁上限 < 50? 按兵种核心规则锁 >= 50 不溃）
  if (squad.primaryUnitType === UnitTypeId.XUEYUE_WARDRUM_BERSERKER) {
    if (maxCap < 50.0) {
      maxCap = 50.0;
    }
    if (nextMorale < 50.0) {
      nextMorale = 50.0;
    }
  }

  if (nextMorale > maxCap) {
    nextMorale = maxCap;
  }
  if (nextMorale < 0) {
    nextMorale = 0;
  }
  squad.morale = nextMorale;

  if (forcedWakeByWarCry) {
    if (squad.morale < GameConstants.MORALE_RALLY_THRESHOLD) {
      squad.morale = Math.min(maxCap, GameConstants.MORALE_RALLY_THRESHOLD);
    }
    squad.isRouting = false;
    return false;
  }

  if (squad.primaryUnitType === UnitTypeId.XUEYUE_WARDRUM_BERSERKER) {
    squad.isRouting = false;
    return false;
  }

  if (!squad.isRouting) {
    if (squad.morale < GameConstants.MORALE_ROUT_THRESHOLD) {
      squad.isRouting = true;
      return !wasRouting;
    }
  } else {
    const inContact: boolean = squad.threatOctantMask !== 0;
    if (squad.morale >= GameConstants.MORALE_RALLY_THRESHOLD && !inContact) {
      squad.isRouting = false;
    }
  }
  return false;
}

/**
 * 计算分队每秒持续环境/合围/断粮/主帅光环净士气变化率
 */
export function computeSquadContinuousMoraleRate(
  squad: SquadRuntimeState,
  rationStage: BattlefieldRationStage,
  sideGold: number,
  hasMercenaries: boolean,
  heroAuraActive: boolean,
  weather: WeatherType
): number {
  let rate: number = 0;

  // 1. 钳形夹击 / 铁桶合围士气雪崩
  if (squad.encirclement === EncirclementState.ENCIRCLED) {
    const circleActive: boolean =
      squad.formation === FormationType.CIRCLE_DEFENSE && squad.bannerLostPenaltyTimer <= 0;
    rate -= circleActive
      ? GameConstants.ENCIRCLEMENT_MORALE_DRAIN_PER_SEC * 0.5
      : GameConstants.ENCIRCLEMENT_MORALE_DRAIN_PER_SEC;
  } else if (squad.encirclement === EncirclementState.PINCERED) {
    rate -= GameConstants.PINCER_MORALE_DRAIN_PER_SEC;
  }

  // 2. 断粮饥饿 / 饥溃士气衰减
  if (rationStage === BattlefieldRationStage.HUNGRY) {
    rate -= 0.8;
  } else if (rationStage === BattlefieldRationStage.STARVING) {
    rate -= 1.8;
  }

  // 3. 沙漠商盟零金币时雇佣军士气滑坡
  if (squad.factionId === FactionId.SHAMO && hasMercenaries && sideGold <= 0) {
    rate -= 1.2;
  }

  // 4. 凛冽暴雪对非耐寒势力的微弱士气侵蚀
  if (weather === WeatherType.BLIZZARD && squad.factionId !== FactionId.SHUANGYUAN) {
    rate -= 0.25;
  }

  // 5. 脱战且粮草未断时的自然士气恢复与主帅帅旗光环
  const canRecover: boolean =
    rationStage === BattlefieldRationStage.ABUNDANT ||
    rationStage === BattlefieldRationStage.WARNING;

  if (canRecover && heroAuraActive && squad.encirclement !== EncirclementState.ENCIRCLED) {
    rate += 1.5;
  }
  if (canRecover && squad.threatOctantMask === 0) {
    rate += 1.2;
  }

  return rate;
}

/**
 * 计算观察者动态视野半径（DESIGN.md 7.1）
 * - 常规步兵 420px，骑兵 580px，主帅 520px
 * - 制高点/城头海拔 >= 1: +25%
 * - 浓雾 / 黑夜: -40%（血月祭司黑夜无损，雾林猎手林雾优势）
 */
export function computeObserverVisionRadius(
  category: UnitCategory,
  isHero: boolean,
  elevation: number,
  weather: WeatherType,
  observerFaction: FactionId
): number {
  let radius: number = GameConstants.VISION_RADIUS_INFANTRY;
  if (category === UnitCategory.CAVALRY) {
    radius = GameConstants.VISION_RADIUS_CAVALRY;
  } else if (isHero) {
    radius = 520.0;
  }

  if (elevation >= 1) {
    radius *= 1.25;
  }

  if (weather === WeatherType.HEAVY_FOG) {
    radius *= 0.60;
  } else if (weather === WeatherType.NIGHT) {
    if (observerFaction !== FactionId.XUEYUE) {
      radius *= 0.60;
    }
  }

  return radius;
}

/**
 * 判定单个观察者是否能识破目标敌军（含密林未开火 / 潜行 140px 隐蔽判定）
 */
export function canObserverSpotTarget(
  distSq: number,
  observerVisionRadius: number,
  observerFaction: FactionId,
  targetConcealedInForestOrStealth: boolean
): boolean {
  if (targetConcealedInForestOrStealth && observerFaction !== FactionId.WULIN) {
    const forestDetectRadius: number = Math.min(140.0, observerVisionRadius);
    return distSq <= forestDetectRadius * forestDetectRadius;
  }
  return distSq <= observerVisionRadius * observerVisionRadius;
}
