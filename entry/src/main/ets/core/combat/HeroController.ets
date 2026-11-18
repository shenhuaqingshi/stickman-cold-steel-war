/**
 * 主帅英雄操控、三兵刃切换、精准弹反、24 支箭袋限制与两段式落马状态机（HeroController.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖，零每帧 GC）
 */
import { GameConstants } from '../../common/GameConstants';
import { getFactionConfigById } from '../../config/FactionConfig';
import { getUnitConfigById } from '../../config/UnitConfig';
import { FactionStaticConfig, UnitStaticStats } from '../../model/GameTypes';
import {
  BattleSide,
  CommanderHeroRuntime,
  FactionId,
  FortStructureEntity,
  HeroControlInput,
  HeroSkillId,
  HeroVitalState,
  HeroWeaponType,
  ProjectileKind,
  SoldierRuntimeEntity,
  SquadRuntimeState,
  UnitActionState,
  UnitCategory,
  UnitTypeId
} from '../CoreContracts';
import {
  applySquadMoraleAndHysteresis,
  computeAttackIncomingAngleDeg,
  computeEffectiveArmor,
  computeHyperbolicMitigation
} from './DamageAndMorale';
import { SpatialHashGrid } from './SpatialHashGrid';

export const HERO_BASE_MAX_HP: number = 1100;
export const HERO_BASE_ARMOR: number = 55;
export const HERO_BASE_MOVE_SPEED: number = 92;
export const HERO_MAX_QUIVER_ARROWS: number = 24;
export const HERO_ARROW_AUTO_RECOVER_SEC: number = 2.5;
export const HERO_CAMP_RECOVERY_SEC: number = 45.0;
export const HERO_MODE_SWITCH_CD_SEC: number = 1.5;

const heroQueryScratch: Int32Array = new Int32Array(GameConstants.MAX_UNIT_POOL_SIZE);

/** 主帅运行时具象类（固定隐藏类布局，零未标注字面量） */
export class CommanderHeroEntity implements CommanderHeroRuntime {
  public readonly side: BattleSide;
  public readonly factionId: FactionId;
  public readonly name: string;
  public x: number;
  public y: number;
  public vx: number = 0;
  public vy: number = 0;
  public facingRad: number;
  public hp: number = HERO_BASE_MAX_HP;
  public maxHp: number = HERO_BASE_MAX_HP;
  public armor: number = HERO_BASE_ARMOR;
  public moveSpeed: number = HERO_BASE_MOVE_SPEED;
  public vitalState: HeroVitalState = HeroVitalState.HEALTHY_ACTIVE;
  public recoveryTimer: number = 0;
  public activeWeapon: HeroWeaponType = HeroWeaponType.COMMAND_SABER;
  public remainingArrows: number = HERO_MAX_QUIVER_ARROWS;
  public arrowRecoverTimer: number = 0;
  public attackCooldown: number = 0;
  public isBlocking: boolean = false;
  public parryWindowTimer: number = 0;
  public ironBulwarkTimer: number = 0;
  public warCryBuffTimer: number = 0;
  public chargeCooldown: number = 0;
  public bulwarkCooldown: number = 0;
  public warCryCooldown: number = 0;
  public actionState: UnitActionState = UnitActionState.IDLE_READY;
  public animPhase: number = 0;
  public kills: number = 0;

  /** 内部脱战计时（用于百石硬弓脱战自动回箭判定） */
  public outOfCombatTimer: number = 5.0;
  /** 上一帧举盾按键状态（用于检测 0.25s 精准弹反起手沿） */
  public prevBlockHeld: boolean = false;

  constructor(
    side: BattleSide,
    factionId: FactionId,
    x: number,
    y: number,
    facingRad: number
  ) {
    this.side = side;
    this.factionId = factionId;
    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(factionId);
    const factionTitle: string = fCfg !== undefined ? fCfg.name : '诸侯';
    this.name = side === BattleSide.PLAYER ? `${factionTitle}统帅` : `${factionTitle}敌帅`;
    this.x = x;
    this.y = y;
    this.facingRad = facingRad;
  }
}

/** 主帅单步行为输出事件缓冲（供 BattleSimulator 消费投射物/顿帧/胜负事件，零闭包分配） */
export class HeroStepEvents {
  public triggerHitStopMs: number = 0;
  public spawnArrow: boolean = false;
  public arrowStartX: number = 0;
  public arrowStartY: number = 0;
  public arrowVx: number = 0;
  public arrowVy: number = 0;
  public arrowDamage: number = 0;
  public arrowPen: number = 0;
  public arrowRange: number = 460;
  public playerForceReturnRts: boolean = false;
  public playerHeroMartyred: boolean = false;
  public enemyHeroDownedShock: boolean = false;
  public effectX: number = 0;
  public effectY: number = 0;
  public effectAngle: number = 0;
  public effectKind: 'none' | 'slash_arc' | 'shield_spark' | 'morale_burst' = 'none';
  public readonly killedSoldierIndices: Int32Array = new Int32Array(16);
  public killedCount: number = 0;

  public reset(): void {
    this.triggerHitStopMs = 0;
    this.spawnArrow = false;
    this.playerForceReturnRts = false;
    this.playerHeroMartyred = false;
    this.enemyHeroDownedShock = false;
    this.effectKind = 'none';
    this.killedCount = 0;
  }
}

/** 获取主帅当前有效伤害倍率（重创虚弱态 -25%） */
export function getHeroDamageMultiplier(hero: CommanderHeroEntity): number {
  return hero.vitalState === HeroVitalState.WOUNDED_WEAKENED ? 0.75 : 1.0;
}

/**
 * 处理主帅承受伤害（含佩刀正面格挡 80%、0.25s 精准弹反眩晕 1.5s、铁壁横戈减伤与两段式落马）
 * @returns 实际扣除的 HP
 */
export function applyDamageToHero(
  hero: CommanderHeroEntity,
  rawAttack: number,
  armorPen: number,
  sourceX: number,
  sourceY: number,
  isRanged: boolean,
  attackerSoldier: SoldierRuntimeEntity | null,
  friendlySquads: readonly SquadRuntimeState[],
  enemySquads: readonly SquadRuntimeState[],
  ownBaseCamp: FortStructureEntity | null,
  nonRoutingFriendlyAlive: number,
  initialFriendlyTotal: number,
  outEvents: HeroStepEvents
): number {
  if (
    hero.vitalState === HeroVitalState.RECOVERING_IN_CAMP ||
    hero.vitalState === HeroVitalState.FALLEN_MARTYRED ||
    hero.hp <= 0
  ) {
    return 0;
  }

  hero.outOfCombatTimer = 0;
  const angleDeg: number = computeAttackIncomingAngleDeg(
    hero.facingRad,
    hero.x,
    hero.y,
    sourceX,
    sourceY
  );

  // 1. 铁壁横戈期间正面免伤/极高减伤
  if (hero.ironBulwarkTimer > 0 && angleDeg <= 120.0) {
    if (isRanged) {
      outEvents.effectKind = 'shield_spark';
      outEvents.effectX = hero.x;
      outEvents.effectY = hero.y;
      outEvents.effectAngle = hero.facingRad;
      return 0;
    }
    rawAttack *= 0.15;
  }

  // 2. 佩刀精准弹反窗口（起盾前 0.25s 内正面近战攻击 0 伤，震退敌兵并眩晕 1.5s）
  if (
    !isRanged &&
    hero.activeWeapon === HeroWeaponType.COMMAND_SABER &&
    hero.isBlocking &&
    hero.parryWindowTimer > 0 &&
    angleDeg <= 95.0
  ) {
    if (attackerSoldier !== null && attackerSoldier.active && attackerSoldier.hp > 0) {
      const pushRad: number = Math.atan2(
        attackerSoldier.y - hero.y,
        attackerSoldier.x - hero.x
      );
      if (attackerSoldier.unitType !== UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
        attackerSoldier.x += Math.cos(pushRad) * 30.0;
        attackerSoldier.y += Math.sin(pushRad) * 30.0;
      }
      attackerSoldier.vx = 0;
      attackerSoldier.vy = 0;
      attackerSoldier.chargeRunTime = 0;
      attackerSoldier.staggerTimer = Math.max(attackerSoldier.staggerTimer, 1.5);
      attackerSoldier.actionState = UnitActionState.STAGGER_HIT;
    }
    outEvents.effectKind = 'shield_spark';
    outEvents.effectX = hero.x;
    outEvents.effectY = hero.y;
    outEvents.effectAngle = hero.facingRad;
    outEvents.triggerHitStopMs = GameConstants.HERO_HIT_STOP_MS;
    return 0;
  }

  // 3. 常规举盾主动格挡（正面 <= 90° 减免 80% 伤害）
  if (hero.isBlocking && angleDeg <= 90.0) {
    rawAttack *= 0.20;
  } else if (angleDeg > 135.0) {
    rawAttack *= GameConstants.REAR_DAMAGE_MULTIPLIER;
  } else if (angleDeg > 60.0) {
    rawAttack *= GameConstants.FLANK_DAMAGE_MULTIPLIER;
  }

  const effArmor: number = computeEffectiveArmor(hero.armor, armorPen, 0);
  const mitigation: number = computeHyperbolicMitigation(effArmor);
  const finalDmg: number = Math.max(2.0, rawAttack * (1.0 - mitigation));

  hero.hp -= finalDmg;
  if (hero.hp <= 0) {
    handleHeroZeroHpTransition(
      hero,
      friendlySquads,
      enemySquads,
      ownBaseCamp,
      nonRoutingFriendlyAlive,
      initialFriendlyTotal,
      outEvents
    );
  }
  return finalDmg;
}

/**
 * 主帅 HP 归零时的两段式“落马重伤 — 亲卫抢救 / 二次绝命”状态流转（DESIGN.md 10.2）
 */
export function handleHeroZeroHpTransition(
  hero: CommanderHeroEntity,
  friendlySquads: readonly SquadRuntimeState[],
  enemySquads: readonly SquadRuntimeState[],
  ownBaseCamp: FortStructureEntity | null,
  nonRoutingFriendlyAlive: number,
  initialFriendlyTotal: number,
  outEvents: HeroStepEvents
): void {
  const baseBroken: boolean =
    ownBaseCamp === null || ownBaseCamp.isBreached || ownBaseCamp.hp <= 0;
  const armyCollapsed: boolean =
    initialFriendlyTotal > 0 && nonRoutingFriendlyAlive < initialFriendlyTotal * 0.10;

  if (hero.vitalState === HeroVitalState.HEALTHY_ACTIVE && !baseBroken && !armyCollapsed) {
    // 首次落马重伤：回营包扎 45s，全军士气立刻 -35 且上限锁死 65
    hero.vitalState = HeroVitalState.RECOVERING_IN_CAMP;
    hero.recoveryTimer = HERO_CAMP_RECOVERY_SEC;
    hero.hp = 0;
    hero.vx = 0;
    hero.vy = 0;
    hero.isBlocking = false;
    hero.ironBulwarkTimer = 0;
    hero.actionState = UnitActionState.STAGGER_HIT;
    if (ownBaseCamp !== null) {
      hero.x = ownBaseCamp.x + ownBaseCamp.width * 0.5;
      hero.y = ownBaseCamp.y + ownBaseCamp.height * 0.5;
    }

    for (let i: number = 0; i < friendlySquads.length; i++) {
      const sq: SquadRuntimeState = friendlySquads[i];
      if (sq.aliveCount > 0) {
        applySquadMoraleAndHysteresis(
          sq,
          -GameConstants.HERO_FIRST_DOWN_MORALE_SHOCK,
          true,
          false
        );
      }
    }

    if (hero.side === BattleSide.PLAYER) {
      outEvents.playerForceReturnRts = true;
    } else {
      // 玩家击倒敌帅：敌军 -35 士气并瘫痪指挥 15s，我军士气沸腾 +20
      outEvents.enemyHeroDownedShock = true;
      for (let i: number = 0; i < enemySquads.length; i++) {
        const pSq: SquadRuntimeState = enemySquads[i];
        if (pSq.aliveCount > 0) {
          applySquadMoraleAndHysteresis(pSq, 20.0, false, false);
        }
      }
    }
    return;
  }

  // 二次落马或本阵已破 / 残军不足 10%：直接殉国
  hero.vitalState = HeroVitalState.FALLEN_MARTYRED;
  hero.hp = 0;
  hero.vx = 0;
  hero.vy = 0;
  hero.isBlocking = false;
  hero.actionState = UnitActionState.FALLEN_CORPSE;

  if (hero.side === BattleSide.PLAYER) {
    for (let i: number = 0; i < friendlySquads.length; i++) {
      const sq: SquadRuntimeState = friendlySquads[i];
      sq.morale = 0;
      sq.isRouting = true;
    }
    outEvents.playerForceReturnRts = true;
    outEvents.playerHeroMartyred = true;
  } else {
    outEvents.enemyHeroDownedShock = true;
    for (let i: number = 0; i < friendlySquads.length; i++) {
      const sq: SquadRuntimeState = friendlySquads[i];
      if (sq.aliveCount > 0) {
        applySquadMoraleAndHysteresis(sq, -45.0, true, false);
      }
    }
    for (let i: number = 0; i < enemySquads.length; i++) {
      const pSq: SquadRuntimeState = enemySquads[i];
      if (pSq.aliveCount > 0) {
        applySquadMoraleAndHysteresis(pSq, 20.0, false, false);
      }
    }
  }
}

/**
 * 对主帅命中的敌兵结算伤害、击退、反骑挑落与斩杀执旗官士气打击
 */
function strikeSoldierFromHero(
  hero: CommanderHeroEntity,
  target: SoldierRuntimeEntity,
  enemySquads: readonly SquadRuntimeState[],
  baseDamage: number,
  armorPen: number,
  antiCavMult: number,
  knockbackPx: number,
  staggerSec: number,
  outEvents: HeroStepEvents
): boolean {
  const stats: UnitStaticStats | undefined = getUnitConfigById(target.unitType);
  const targetBaseArmor: number = stats !== undefined ? stats.armor : 15;
  const cavMult: number = target.category === UnitCategory.CAVALRY ? antiCavMult : 1.0;
  const effArmor: number = computeEffectiveArmor(targetBaseArmor, armorPen, 0);
  const mit: number = computeHyperbolicMitigation(effArmor);
  const dmg: number = Math.max(
    2.0,
    baseDamage * getHeroDamageMultiplier(hero) * cavMult * (1.0 - mit)
  );

  target.hp -= dmg;
  target.isStealthed = false;

  if (knockbackPx > 0 && target.unitType !== UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
    const pushAngle: number = Math.atan2(target.y - hero.y, target.x - hero.x);
    target.x += Math.cos(pushAngle) * knockbackPx;
    target.y += Math.sin(pushAngle) * knockbackPx;
  }
  if (staggerSec > 0) {
    if (
      target.unitType !== UnitTypeId.SHUANGYUAN_GIANT_BREAKER ||
      staggerSec >= 0.55
    ) {
      target.staggerTimer = Math.max(target.staggerTimer, staggerSec);
      target.actionState = UnitActionState.STAGGER_HIT;
    }
    if (target.category === UnitCategory.CAVALRY) {
      target.vx = 0;
      target.vy = 0;
      target.chargeRunTime = 0;
      target.chargeCooldown = Math.max(target.chargeCooldown, 8.0);
    }
  }

  if (target.hp <= 0) {
    target.hp = 0;
    target.active = false;
    target.actionState = UnitActionState.FALLEN_CORPSE;
    hero.kills++;
    if (outEvents.killedCount < outEvents.killedSoldierIndices.length) {
      outEvents.killedSoldierIndices[outEvents.killedCount] = target.poolIndex;
      outEvents.killedCount++;
    }
    // 若斩杀军团执旗官：令该敌军团立即 -15 士气且 12s 丧失阵型加成
    if (target.isBannerBearer) {
      for (let q: number = 0; q < enemySquads.length; q++) {
        const sq: SquadRuntimeState = enemySquads[q];
        if (sq.squadId === target.squadId) {
          sq.bannerAlive = false;
          sq.bannerLostPenaltyTimer = 12.0;
          applySquadMoraleAndHysteresis(sq, -15.0, false, false);
          break;
        }
      }
    }
    return true;
  }
  return false;
}

/**
 * 释放主帅三大主动技能（破阵突击 / 铁壁横戈 / 三军战吼）
 */
export function executeHeroSkill(
  hero: CommanderHeroEntity,
  skill: HeroSkillId,
  soldiers: readonly SoldierRuntimeEntity[],
  friendlySquads: readonly SquadRuntimeState[],
  enemySquads: readonly SquadRuntimeState[],
  enemyHero: CommanderHeroEntity,
  enemyBaseCamp: FortStructureEntity | null,
  enemyNonRoutingAlive: number,
  enemyInitialTotal: number,
  grid: SpatialHashGrid,
  worldWidth: number,
  worldHeight: number,
  outEvents: HeroStepEvents
): boolean {
  if (
    hero.vitalState !== HeroVitalState.HEALTHY_ACTIVE &&
    hero.vitalState !== HeroVitalState.WOUNDED_WEAKENED
  ) {
    return false;
  }

  if (skill === HeroSkillId.BREAKTHROUGH_CHARGE) {
    if (hero.chargeCooldown > 0) {
      return false;
    }
    hero.chargeCooldown = 10.0;
    hero.outOfCombatTimer = 0;
    hero.actionState = UnitActionState.CHARGE_SPRINT;
    hero.animPhase = 0;

    const startX: number = hero.x;
    const startY: number = hero.y;
    const dirX: number = Math.cos(hero.facingRad);
    const dirY: number = Math.sin(hero.facingRad);
    const endX: number = Math.max(36.0, Math.min(worldWidth - 36.0, startX + dirX * 160.0));
    const endY: number = Math.max(36.0, Math.min(worldHeight - 36.0, startY + dirY * 160.0));
    hero.x = endX;
    hero.y = endY;

    const midX: number = (startX + endX) * 0.5;
    const midY: number = (startY + endY) * 0.5;
    const candCount: number = grid.queryRadius(soldiers, midX, midY, 120.0, heroQueryScratch);
    const spearBonus: number = hero.activeWeapon === HeroWeaponType.BREAKER_SPEAR ? 1.40 : 1.0;
    const baseStrike: number = 75.0 * spearBonus;
    let hitAny: boolean = false;

    for (let i: number = 0; i < candCount; i++) {
      const s: SoldierRuntimeEntity = soldiers[heroQueryScratch[i]];
      if (s.side === hero.side || !s.active || s.hp <= 0) {
        continue;
      }
      // 计算点到冲锋线段 [start, end] 的投影距离
      const apx: number = s.x - startX;
      const apy: number = s.y - startY;
      const segLenX: number = endX - startX;
      const segLenY: number = endY - startY;
      const segLenSq: number = segLenX * segLenX + segLenY * segLenY;
      let t: number = segLenSq > 1.0 ? (apx * segLenX + apy * segLenY) / segLenSq : 0;
      if (t < 0) {
        t = 0;
      } else if (t > 1.0) {
        t = 1.0;
      }
      const closestX: number = startX + segLenX * t;
      const closestY: number = startY + segLenY * t;
      const distSq: number =
        (s.x - closestX) * (s.x - closestX) + (s.y - closestY) * (s.y - closestY);
      if (distSq <= 34.0 * 34.0) {
        strikeSoldierFromHero(hero, s, enemySquads, baseStrike, 0.50, 1.35, 34.0, 0.75, outEvents);
        hitAny = true;
      }
    }

    // 检查是否撞中敌方主帅
    if (
      enemyHero.hp > 0 &&
      (enemyHero.vitalState === HeroVitalState.HEALTHY_ACTIVE ||
        enemyHero.vitalState === HeroVitalState.WOUNDED_WEAKENED)
    ) {
      const ehDx: number = enemyHero.x - hero.x;
      const ehDy: number = enemyHero.y - hero.y;
      if (ehDx * ehDx + ehDy * ehDy <= 52.0 * 52.0) {
        applyDamageToHero(
          enemyHero,
          baseStrike * getHeroDamageMultiplier(hero),
          0.50,
          startX,
          startY,
          false,
          null,
          enemySquads,
          friendlySquads,
          enemyBaseCamp,
          enemyNonRoutingAlive,
          enemyInitialTotal,
          outEvents
        );
        hitAny = true;
      }
    }

    if (hitAny) {
      outEvents.triggerHitStopMs = GameConstants.HERO_HIT_STOP_MS;
    }
    outEvents.effectKind = 'slash_arc';
    outEvents.effectX = hero.x;
    outEvents.effectY = hero.y;
    outEvents.effectAngle = hero.facingRad;
    return true;
  }

  if (skill === HeroSkillId.IRON_BULWARK) {
    if (hero.bulwarkCooldown > 0) {
      return false;
    }
    hero.bulwarkCooldown = 8.0;
    hero.ironBulwarkTimer = 2.0;
    hero.isBlocking = true;
    hero.actionState = UnitActionState.SHIELD_BLOCK;
    outEvents.effectKind = 'shield_spark';
    outEvents.effectX = hero.x;
    outEvents.effectY = hero.y;
    outEvents.effectAngle = hero.facingRad;
    return true;
  }

  if (skill === HeroSkillId.GRAND_WAR_CRY) {
    if (hero.warCryCooldown > 0) {
      return false;
    }
    hero.warCryCooldown = 22.0;
    hero.warCryBuffTimer = 8.0;
    const heroDownCap: boolean = hero.vitalState === HeroVitalState.RECOVERING_IN_CAMP;

    // 320px 内所有友军立即 +18 士气并直接唤醒溃逃分队重整反扑
    for (let i: number = 0; i < friendlySquads.length; i++) {
      const sq: SquadRuntimeState = friendlySquads[i];
      if (sq.aliveCount <= 0) {
        continue;
      }
      const dx: number = sq.centerX - hero.x;
      const dy: number = sq.centerY - hero.y;
      if (dx * dx + dy * dy <= 320.0 * 320.0) {
        applySquadMoraleAndHysteresis(sq, 18.0, heroDownCap, true);
      }
    }

    // 180px 内所有敌军震慑 -10 士气
    const enemyHeroDown: boolean =
      enemyHero.vitalState === HeroVitalState.RECOVERING_IN_CAMP;
    for (let i: number = 0; i < enemySquads.length; i++) {
      const esq: SquadRuntimeState = enemySquads[i];
      if (esq.aliveCount <= 0) {
        continue;
      }
      const dx: number = esq.centerX - hero.x;
      const dy: number = esq.centerY - hero.y;
      if (dx * dx + dy * dy <= 180.0 * 180.0) {
        applySquadMoraleAndHysteresis(esq, -10.0, enemyHeroDown, false);
      }
    }

    outEvents.effectKind = 'morale_burst';
    outEvents.effectX = hero.x;
    outEvents.effectY = hero.y;
    outEvents.effectAngle = 0;
    return true;
  }

  return false;
}

/**
 * 执行主帅普通兵刃挥砍/长枪突刺/百石硬弓射击
 */
function performHeroPrimaryAttack(
  hero: CommanderHeroEntity,
  soldiers: readonly SoldierRuntimeEntity[],
  friendlySquads: readonly SquadRuntimeState[],
  enemySquads: readonly SquadRuntimeState[],
  enemyHero: CommanderHeroEntity,
  enemyBaseCamp: FortStructureEntity | null,
  enemyNonRoutingAlive: number,
  enemyInitialTotal: number,
  grid: SpatialHashGrid,
  outEvents: HeroStepEvents
): void {
  const speedBuff: number = hero.warCryBuffTimer > 0 ? 1.15 : 1.0;

  if (hero.activeWeapon === HeroWeaponType.HEAVY_WARBOW) {
    if (hero.remainingArrows <= 0) {
      return;
    }
    hero.remainingArrows--;
    hero.attackCooldown = 0.90 / speedBuff;
    hero.outOfCombatTimer = 0;
    hero.actionState = UnitActionState.RANGED_DRAW_FIRE;
    hero.animPhase = 0;

    const arrowSpeed: number = 620.0;
    outEvents.spawnArrow = true;
    outEvents.arrowStartX = hero.x + Math.cos(hero.facingRad) * 14.0;
    outEvents.arrowStartY = hero.y + Math.sin(hero.facingRad) * 14.0;
    outEvents.arrowVx = Math.cos(hero.facingRad) * arrowSpeed;
    outEvents.arrowVy = Math.sin(hero.facingRad) * arrowSpeed;
    outEvents.arrowDamage = 95.0 * getHeroDamageMultiplier(hero);
    outEvents.arrowPen = 0.50;
    outEvents.arrowRange = 460.0;
    return;
  }

  if (hero.activeWeapon === HeroWeaponType.BREAKER_SPEAR) {
    // 破阵大枪：前方 68px 直线穿刺 2 人，62 伤 55% 破甲，2.2x 反骑挑落
    hero.attackCooldown = 1.05 / speedBuff;
    hero.outOfCombatTimer = 0;
    hero.actionState = UnitActionState.MELEE_STRIKE;
    hero.animPhase = 0;

    const candCount: number = grid.queryRadius(soldiers, hero.x, hero.y, 72.0, heroQueryScratch);
    let hits: number = 0;
    let hitCavOrHeavy: boolean = false;
    const fx: number = Math.cos(hero.facingRad);
    const fy: number = Math.sin(hero.facingRad);

    for (let i: number = 0; i < candCount && hits < 2; i++) {
      const s: SoldierRuntimeEntity = soldiers[heroQueryScratch[i]];
      if (s.side === hero.side || !s.active || s.hp <= 0) {
        continue;
      }
      const dx: number = s.x - hero.x;
      const dy: number = s.y - hero.y;
      const forwardProj: number = dx * fx + dy * fy;
      const lateralProj: number = Math.abs(-dx * fy + dy * fx);
      if (forwardProj >= -4.0 && forwardProj <= 68.0 && lateralProj <= 20.0) {
        const isCav: boolean = s.category === UnitCategory.CAVALRY;
        strikeSoldierFromHero(
          hero,
          s,
          enemySquads,
          62.0,
          0.55,
          2.2,
          isCav ? 18.0 : 12.0,
          isCav ? 1.1 : 0.35,
          outEvents
        );
        hits++;
        hitCavOrHeavy = true;
      }
    }

    if (
      hits < 2 &&
      enemyHero.hp > 0 &&
      (enemyHero.vitalState === HeroVitalState.HEALTHY_ACTIVE ||
        enemyHero.vitalState === HeroVitalState.WOUNDED_WEAKENED)
    ) {
      const dxH: number = enemyHero.x - hero.x;
      const dyH: number = enemyHero.y - hero.y;
      const fProj: number = dxH * fx + dyH * fy;
      const lProj: number = Math.abs(-dxH * fy + dyH * fx);
      if (fProj >= -4.0 && fProj <= 68.0 && lProj <= 22.0) {
        applyDamageToHero(
          enemyHero,
          62.0 * getHeroDamageMultiplier(hero),
          0.55,
          hero.x,
          hero.y,
          false,
          null,
          enemySquads,
          friendlySquads,
          enemyBaseCamp,
          enemyNonRoutingAlive,
          enemyInitialTotal,
          outEvents
        );
        hitCavOrHeavy = true;
      }
    }

    if (hitCavOrHeavy) {
      outEvents.triggerHitStopMs = GameConstants.HERO_HIT_STOP_MS;
    }
    outEvents.effectKind = 'slash_arc';
    outEvents.effectX = hero.x + fx * 30.0;
    outEvents.effectY = hero.y + fy * 30.0;
    outEvents.effectAngle = hero.facingRad;
    return;
  }

  // 默认统帅佩刀：前方 120° 扇形斩最多 3 人，48 伤害，重击 40ms 顿帧
  hero.attackCooldown = 0.75 / speedBuff;
  hero.outOfCombatTimer = 0;
  hero.actionState = UnitActionState.MELEE_STRIKE;
  hero.animPhase = 0;

  const candCount: number = grid.queryRadius(soldiers, hero.x, hero.y, 46.0, heroQueryScratch);
  let hits: number = 0;
  for (let i: number = 0; i < candCount && hits < 3; i++) {
    const s: SoldierRuntimeEntity = soldiers[heroQueryScratch[i]];
    if (s.side === hero.side || !s.active || s.hp <= 0) {
      continue;
    }
    const angleDeg: number = computeAttackIncomingAngleDeg(
      hero.facingRad,
      hero.x,
      hero.y,
      s.x,
      s.y
    );
    if (angleDeg <= 60.0) {
      strikeSoldierFromHero(hero, s, enemySquads, 48.0, 0.25, 1.0, 14.0, 0.30, outEvents);
      hits++;
    }
  }

  if (
    hits < 3 &&
    enemyHero.hp > 0 &&
    (enemyHero.vitalState === HeroVitalState.HEALTHY_ACTIVE ||
      enemyHero.vitalState === HeroVitalState.WOUNDED_WEAKENED)
  ) {
    const ehDistSq: number =
      (enemyHero.x - hero.x) * (enemyHero.x - hero.x) +
      (enemyHero.y - hero.y) * (enemyHero.y - hero.y);
    if (ehDistSq <= 48.0 * 48.0) {
      const ehAngle: number = computeAttackIncomingAngleDeg(
        hero.facingRad,
        hero.x,
        hero.y,
        enemyHero.x,
        enemyHero.y
      );
      if (ehAngle <= 60.0) {
        applyDamageToHero(
          enemyHero,
          48.0 * getHeroDamageMultiplier(hero),
          0.25,
          hero.x,
          hero.y,
          false,
          null,
          enemySquads,
          friendlySquads,
          enemyBaseCamp,
          enemyNonRoutingAlive,
          enemyInitialTotal,
          outEvents
        );
        hits++;
      }
    }
  }

  if (hits > 0) {
    outEvents.triggerHitStopMs = GameConstants.HERO_HIT_STOP_MS;
  }
  outEvents.effectKind = 'slash_arc';
  outEvents.effectX = hero.x + Math.cos(hero.facingRad) * 20.0;
  outEvents.effectY = hero.y + Math.sin(hero.facingRad) * 20.0;
  outEvents.effectAngle = hero.facingRad;
}

/**
 * 步进主帅状态机（冷却计时、本阵包扎复出、24 支箭袋本阵瞬补/脱战 2.5s 回收、铁壁横戈收招横扫与操控移动）
 */
export function stepCommanderHero(
  hero: CommanderHeroEntity,
  dtSec: number,
  isManualHeroControl: boolean,
  input: HeroControlInput,
  ownBaseCamp: FortStructureEntity | null,
  enemyBaseCamp: FortStructureEntity | null,
  soldiers: readonly SoldierRuntimeEntity[],
  friendlySquads: readonly SquadRuntimeState[],
  enemySquads: readonly SquadRuntimeState[],
  enemyHero: CommanderHeroEntity,
  enemyNonRoutingAlive: number,
  enemyInitialTotal: number,
  grid: SpatialHashGrid,
  worldWidth: number,
  worldHeight: number,
  outEvents: HeroStepEvents
): void {
  if (hero.vitalState === HeroVitalState.FALLEN_MARTYRED) {
    return;
  }

  // 1. 冷却递减
  if (hero.attackCooldown > 0) {
    hero.attackCooldown = Math.max(0, hero.attackCooldown - dtSec);
  }
  if (hero.parryWindowTimer > 0) {
    hero.parryWindowTimer = Math.max(0, hero.parryWindowTimer - dtSec);
  }
  if (hero.warCryBuffTimer > 0) {
    hero.warCryBuffTimer = Math.max(0, hero.warCryBuffTimer - dtSec);
  }
  if (hero.chargeCooldown > 0) {
    hero.chargeCooldown = Math.max(0, hero.chargeCooldown - dtSec);
  }
  if (hero.bulwarkCooldown > 0) {
    hero.bulwarkCooldown = Math.max(0, hero.bulwarkCooldown - dtSec);
  }
  if (hero.warCryCooldown > 0) {
    hero.warCryCooldown = Math.max(0, hero.warCryCooldown - dtSec);
  }

  // 2. 本阵重伤包扎 45s 复出检测
  if (hero.vitalState === HeroVitalState.RECOVERING_IN_CAMP) {
    const campLost: boolean =
      ownBaseCamp === null || ownBaseCamp.isBreached || ownBaseCamp.hp <= 0;
    if (campLost) {
      hero.vitalState = HeroVitalState.FALLEN_MARTYRED;
      hero.hp = 0;
      if (hero.side === BattleSide.PLAYER) {
        outEvents.playerHeroMartyred = true;
      }
      return;
    }
    hero.recoveryTimer -= dtSec;
    if (hero.recoveryTimer <= 0) {
      hero.recoveryTimer = 0;
      hero.vitalState = HeroVitalState.WOUNDED_WEAKENED;
      hero.hp = Math.round(hero.maxHp * 0.35);
      hero.armor = Math.round(HERO_BASE_ARMOR * 0.75);
      hero.moveSpeed = HERO_BASE_MOVE_SPEED * 0.75;
      hero.remainingArrows = HERO_MAX_QUIVER_ARROWS;
      hero.actionState = UnitActionState.IDLE_READY;
    }
    return;
  }

  // 3. 铁壁横戈结束瞬间触发 55px 旋身横扫
  if (hero.ironBulwarkTimer > 0) {
    hero.ironBulwarkTimer -= dtSec;
    if (hero.ironBulwarkTimer <= 0) {
      hero.ironBulwarkTimer = 0;
      hero.isBlocking = false;
      const sweepCount: number = grid.queryRadius(
        soldiers,
        hero.x,
        hero.y,
        55.0,
        heroQueryScratch
      );
      for (let i: number = 0; i < sweepCount; i++) {
        const s: SoldierRuntimeEntity = soldiers[heroQueryScratch[i]];
        if (s.side !== hero.side && s.active && s.hp > 0) {
          strikeSoldierFromHero(hero, s, enemySquads, 68.0, 0.40, 1.2, 24.0, 0.55, outEvents);
        }
      }
      outEvents.effectKind = 'slash_arc';
      outEvents.effectX = hero.x;
      outEvents.effectY = hero.y;
      outEvents.effectAngle = hero.facingRad;
    }
  }

  // 4. 24 支箭袋补给逻辑：靠近本阵大营 <= 200px 瞬间补满；脱战状态每 2.5s 自动回 1 支
  if (hero.remainingArrows < HERO_MAX_QUIVER_ARROWS) {
    let nearCamp: boolean = false;
    if (ownBaseCamp !== null && !ownBaseCamp.isBreached && ownBaseCamp.hp > 0) {
      const cx: number = ownBaseCamp.x + ownBaseCamp.width * 0.5;
      const cy: number = ownBaseCamp.y + ownBaseCamp.height * 0.5;
      const dCampSq: number = (hero.x - cx) * (hero.x - cx) + (hero.y - cy) * (hero.y - cy);
      if (dCampSq <= 200.0 * 200.0) {
        nearCamp = true;
      }
    }
    if (nearCamp) {
      hero.remainingArrows = HERO_MAX_QUIVER_ARROWS;
      hero.arrowRecoverTimer = 0;
    } else {
      hero.outOfCombatTimer += dtSec;
      const nearbyEnemies: number = grid.queryRadius(
        soldiers,
        hero.x,
        hero.y,
        140.0,
        heroQueryScratch
      );
      let engagedClose: boolean = false;
      for (let i: number = 0; i < nearbyEnemies; i++) {
        const s: SoldierRuntimeEntity = soldiers[heroQueryScratch[i]];
        if (s.side !== hero.side && s.active && s.hp > 0) {
          engagedClose = true;
          break;
        }
      }
      if (!engagedClose && hero.outOfCombatTimer >= 1.5) {
        hero.arrowRecoverTimer += dtSec;
        while (
          hero.arrowRecoverTimer >= HERO_ARROW_AUTO_RECOVER_SEC &&
          hero.remainingArrows < HERO_MAX_QUIVER_ARROWS
        ) {
          hero.arrowRecoverTimer -= HERO_ARROW_AUTO_RECOVER_SEC;
          hero.remainingArrows++;
        }
      } else {
        hero.arrowRecoverTimer = 0;
      }
    }
  } else {
    hero.outOfCombatTimer += dtSec;
    hero.arrowRecoverTimer = 0;
  }

  // 5. 移动与攻击操控（手动英雄模式 vs RTS 自动督战护卫）
  const speedMult: number = hero.warCryBuffTimer > 0 ? 1.15 : 1.0;
  const maxSpd: number = hero.moveSpeed * speedMult;

  if (isManualHeroControl) {
    // 检测起盾瞬间激活 0.25s 精准弹反窗口
    if (input.isBlockHeld && !hero.prevBlockHeld && hero.activeWeapon === HeroWeaponType.COMMAND_SABER) {
      hero.parryWindowTimer = 0.25;
    }
    hero.prevBlockHeld = input.isBlockHeld;
    hero.isBlocking = input.isBlockHeld || hero.ironBulwarkTimer > 0;

    if (Math.abs(input.aimX) > 0.01 || Math.abs(input.aimY) > 0.01) {
      hero.facingRad = Math.atan2(input.aimY, input.aimX);
    }

    const mvLenSq: number = input.moveX * input.moveX + input.moveY * input.moveY;
    if (mvLenSq > 0.0025) {
      const mvLen: number = Math.sqrt(mvLenSq);
      const normX: number = input.moveX / Math.max(1.0, mvLen);
      const normY: number = input.moveY / Math.max(1.0, mvLen);
      const blockSlow: number = hero.isBlocking ? 0.55 : 1.0;
      hero.vx = normX * maxSpd * blockSlow;
      hero.vy = normY * maxSpd * blockSlow;
      if (Math.abs(input.aimX) <= 0.01 && Math.abs(input.aimY) <= 0.01) {
        hero.facingRad = Math.atan2(hero.vy, hero.vx);
      }
      if (hero.attackCooldown <= 0.1 && !hero.isBlocking) {
        hero.actionState = UnitActionState.MARCH_RUN;
      }
    } else {
      hero.vx = 0;
      hero.vy = 0;
      if (hero.isBlocking) {
        hero.actionState = UnitActionState.SHIELD_BLOCK;
      } else if (hero.attackCooldown <= 0.05) {
        hero.actionState = UnitActionState.IDLE_READY;
      }
    }

    if (input.isAttackPressed && hero.attackCooldown <= 0 && !input.isBlockHeld) {
      performHeroPrimaryAttack(
        hero,
        soldiers,
        friendlySquads,
        enemySquads,
        enemyHero,
        enemyBaseCamp,
        enemyNonRoutingAlive,
        enemyInitialTotal,
        grid,
        outEvents
      );
    }
  } else {
    // 自动督战行为：伴随中军/预备队稳住帅旗光环，近身有敌自动挥砍自卫
    hero.prevBlockHeld = false;
    hero.isBlocking = hero.ironBulwarkTimer > 0;

    let anchorX: number = hero.x;
    let anchorY: number = hero.y;
    for (let i: number = 0; i < friendlySquads.length; i++) {
      const sq: SquadRuntimeState = friendlySquads[i];
      if (sq.aliveCount > 0 && !sq.isRouting) {
        const backOffset: number = hero.side === BattleSide.PLAYER ? -75.0 : 75.0;
        anchorX = sq.centerX + backOffset;
        anchorY = sq.centerY;
        break;
      }
    }

    // 扫描近身 75px 敌兵自卫反击
    const nearCount: number = grid.queryRadius(soldiers, hero.x, hero.y, 75.0, heroQueryScratch);
    let nearestEnemy: SoldierRuntimeEntity | null = null;
    let bestDistSq: number = 75.0 * 75.0 + 1.0;
    for (let i: number = 0; i < nearCount; i++) {
      const s: SoldierRuntimeEntity = soldiers[heroQueryScratch[i]];
      if (s.side !== hero.side && s.active && s.hp > 0) {
        const dSq: number = (s.x - hero.x) * (s.x - hero.x) + (s.y - hero.y) * (s.y - hero.y);
        if (dSq < bestDistSq) {
          bestDistSq = dSq;
          nearestEnemy = s;
        }
      }
    }

    if (nearestEnemy !== null) {
      hero.facingRad = Math.atan2(nearestEnemy.y - hero.y, nearestEnemy.x - hero.x);
      if (bestDistSq > 38.0 * 38.0) {
        hero.vx = Math.cos(hero.facingRad) * maxSpd * 0.80;
        hero.vy = Math.sin(hero.facingRad) * maxSpd * 0.80;
      } else {
        hero.vx = 0;
        hero.vy = 0;
        if (hero.attackCooldown <= 0) {
          if (hero.activeWeapon === HeroWeaponType.HEAVY_WARBOW) {
            hero.activeWeapon = HeroWeaponType.COMMAND_SABER;
          }
          performHeroPrimaryAttack(
            hero,
            soldiers,
            friendlySquads,
            enemySquads,
            enemyHero,
            enemyBaseCamp,
            enemyNonRoutingAlive,
            enemyInitialTotal,
            grid,
            outEvents
          );
        }
      }
    } else {
      const adx: number = anchorX - hero.x;
      const ady: number = anchorY - hero.y;
      const adSq: number = adx * adx + ady * ady;
      if (adSq > 45.0 * 45.0) {
        const ad: number = Math.sqrt(adSq);
        hero.vx = (adx / ad) * maxSpd * 0.75;
        hero.vy = (ady / ad) * maxSpd * 0.75;
        hero.facingRad = hero.side === BattleSide.PLAYER ? 0 : Math.PI;
        hero.actionState = UnitActionState.MARCH_RUN;
      } else {
        hero.vx = 0;
        hero.vy = 0;
        hero.facingRad = hero.side === BattleSide.PLAYER ? 0 : Math.PI;
        if (hero.attackCooldown <= 0.05) {
          hero.actionState = UnitActionState.IDLE_READY;
        }
      }
    }
  }

  hero.x = Math.max(36.0, Math.min(worldWidth - 36.0, hero.x + hero.vx * dtSec));
  hero.y = Math.max(36.0, Math.min(worldHeight - 36.0, hero.y + hero.vy * dtSec));
  hero.animPhase = (hero.animPhase + dtSec * 2.4) % 1.0;
}
