/**
 * 鸿蒙平板高分屏大战场火柴人骨骼合批渲染器（StickmanBattleRenderer.ets）
 * - 支持 4800×2400 标准野战与 5600×2600 攻城大战场
 * - 视口外扩 96px 裁剪 + 多级 LOD（zoom < 0.60 远景精简 / zoom >= 0.60 完整 8 关节骨骼）
 * - 按势力色与冷兵器材质分组 Path Batching，同屏 300~600 火柴人单帧 stroke 调用压控在 ~25 次以内
 * - 零 @kit.ArkUI 依赖，零 any / unknown，零每帧临时对象分配
 */
import { GameConstants } from '../common/GameConstants';
import { FACTION_STATIC_CONFIGS } from '../config/FactionConfig';
import {
  BattleControlMode,
  BattlefieldResourceNode,
  BattleScenarioType,
  BattleSide,
  BattleWorldReadonlyView,
  CombatHitEffect,
  CommanderHeroRuntime,
  EncirclementState,
  FactionId,
  FallenCorpseDecal,
  FortStructureEntity,
  HeroVitalState,
  HeroWeaponType,
  ProjectileKind,
  ProjectileRuntimeEntity,
  SoldierRuntimeEntity,
  SquadRuntimeState,
  TerrainType,
  TerrainZoneRect,
  UnitActionState,
  UnitTypeId,
  WeatherType
} from '../core/CoreContracts';

export type CanvasLineCapMode = 'butt' | 'round' | 'square';
export type CanvasLineJoinMode = 'round' | 'bevel' | 'miter';
export type CanvasTextAlignMode = 'left' | 'right' | 'center' | 'start' | 'end';
export type CanvasTextBaselineMode = 'alphabetic' | 'top' | 'hanging' | 'middle' | 'ideographic' | 'bottom';

/** 兼容 HarmonyOS CanvasGradient 的结构接口 */
export interface ICanvasGradientLike {
  addColorStop(offset: number, color: string): void;
}

/** 兼容 HarmonyOS CanvasPattern 的结构接口 */
export interface ICanvasPatternLike {
  setTransform(): void;
}

export type CanvasStyleValue = string | number | ICanvasGradientLike | ICanvasPatternLike;

/**
 * 结构化 2D 画布上下文契约：
 * HarmonyOS ArkUI 的 CanvasRenderingContext2D 天然满足该接口，同时支持 Node 24 计数型 Mock 单测
 */
export interface ICanvas2DContext {
  fillStyle: CanvasStyleValue;
  strokeStyle: CanvasStyleValue;
  lineWidth: number;
  lineCap: CanvasLineCapMode;
  lineJoin: CanvasLineJoinMode;
  globalAlpha: number;
  font: string;
  textAlign: CanvasTextAlignMode;
  textBaseline: CanvasTextBaselineMode;

  save(): void;
  restore(): void;
  clearRect(x: number, y: number, w: number, h: number): void;
  fillRect(x: number, y: number, w: number, h: number): void;
  strokeRect(x: number, y: number, w: number, h: number): void;
  beginPath(): void;
  closePath(): void;
  moveTo(x: number, y: number): void;
  lineTo(x: number, y: number): void;
  arc(x: number, y: number, radius: number, startAngle: number, endAngle: number, counterclockwise?: boolean): void;
  ellipse(
    x: number,
    y: number,
    radiusX: number,
    radiusY: number,
    rotation: number,
    startAngle: number,
    endAngle: number,
    counterclockwise?: boolean
  ): void;
  quadraticCurveTo(cpx: number, cpy: number, x: number, y: number): void;
  fill(): void;
  stroke(): void;
  translate(x: number, y: number): void;
  scale(x: number, y: number): void;
  rotate(angle: number): void;
  fillText(text: string, x: number, y: number, maxWidth?: number): void;
  setLineDash(segments: number[]): void;
}

/** 二维坐标结构 */
export interface Point2D {
  x: number;
  y: number;
}

/** 矩形区域结构 */
export interface ViewportRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** 右上角缩略小地图布局矩形 */
export interface MinimapLayout {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** 战场交互层叠加参数（框选绿框、选中编队、M-Pencil 手绘路线预览、战争迷雾开关） */
export interface BattleSelectionOverlay {
  readonly selectedSquadIds?: readonly number[];
  readonly marqueeActive?: boolean;
  readonly marqueeStartX?: number;
  readonly marqueeStartY?: number;
  readonly marqueeEndX?: number;
  readonly marqueeEndY?: number;
  readonly stylusTrailScreenX?: readonly number[];
  readonly stylusTrailScreenY?: readonly number[];
  readonly fogOfWarEnabled?: boolean;
}

/** 单帧渲染性能与裁剪遥测指标 */
export interface BattleRenderStats {
  totalActiveSoldiers: number;
  visibleSoldiers: number;
  culledSoldiers: number;
  isFarLod: boolean;
  renderedCorpses: number;
  renderedProjectiles: number;
}

const PI: number = Math.PI;
const TWO_PI: number = Math.PI * 2;
const HALF_PI: number = Math.PI * 0.5;
const FAR_LOD_ZOOM_THRESHOLD: number = 0.60;
const FACTION_COUNT: number = 8;

const FACTION_PRIMARY_COLORS: readonly string[] = [
  '#C62828', // YANLONG
  '#0277BD', // CANGLANG
  '#283593', // TIEYING
  '#F9A825', // SHAMO
  '#29B6F6', // SHUANGYUAN
  '#2E7D32', // WULIN
  '#7B1FA2', // XUANJIA
  '#AD1457'  // XUEYUE
];

const FACTION_ACCENT_COLORS: readonly string[] = [
  '#FFD54F', // YANLONG
  '#E1F5FE', // CANGLANG
  '#B0BEC5', // TIEYING
  '#FFF8E1', // SHAMO
  '#E0F7FA', // SHUANGYUAN
  '#C8E6C9', // WULIN
  '#E1BEE7', // XUANJIA
  '#F8BBD0'  // XUEYUE
];

/**
 * 将势力枚举映射为固定 0..7 桶索引（零字符串哈希分配）
 */
export function getFactionBucketIndex(factionId: FactionId): number {
  switch (factionId) {
    case FactionId.YANLONG:
      return 0;
    case FactionId.CANGLANG:
      return 1;
    case FactionId.TIEYING:
      return 2;
    case FactionId.SHAMO:
      return 3;
    case FactionId.SHUANGYUAN:
      return 4;
    case FactionId.WULIN:
      return 5;
    case FactionId.XUANJIA:
      return 6;
    case FactionId.XUEYUE:
      return 7;
    default:
      return 0;
  }
}

function clampNum(val: number, minVal: number, maxVal: number): number {
  if (!Number.isFinite(val)) {
    return minVal;
  }
  if (val < minVal) {
    return minVal;
  }
  if (val > maxVal) {
    return maxVal;
  }
  return val;
}

function safeNum(val: number, fallback: number): number {
  return Number.isFinite(val) ? val : fallback;
}

/**
 * 鸿蒙平板大战场 Canvas 2D 骨骼合批渲染器
 */
export class StickmanBattleRenderer {
  private viewportW: number = 1280;
  private viewportH: number = 800;
  private worldW: number = GameConstants.BATTLEFIELD_WIDTH;
  private worldH: number = GameConstants.BATTLEFIELD_HEIGHT;

  private camX: number = GameConstants.BATTLEFIELD_WIDTH * 0.5;
  private camY: number = GameConstants.BATTLEFIELD_HEIGHT * 0.5;
  private zoom: number = 0.75;

  private shakeOffsetX: number = 0;
  private shakeOffsetY: number = 0;
  private customShakeRemainingMs: number = 0;
  private customShakeMaxMs: number = 40;
  private customShakeIntensityPx: number = 5;
  private animClockSec: number = 0;
  private lodPolicyMode: string = 'auto_by_zoom';
  private stylusPickRadiusPx: number = GameConstants.STYLUS_PICK_RADIUS_PX;

  // 预分配复用数组与骨骼解算缓存（严禁每帧 new 产生 GC）
  private readonly dashEmpty: number[] = [];
  private readonly dashWaypoint: number[] = [10, 6];
  private readonly dashEncircle: number[] = [7, 4];

  private poolCapacity: number = GameConstants.MAX_UNIT_POOL_SIZE;
  private lastVisibleCount: number = 0;
  private visPoolIndices: Int32Array = new Int32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private factionBucketHead: Int32Array = new Int32Array(FACTION_COUNT);
  private visBucketNext: Int32Array = new Int32Array(GameConstants.MAX_UNIT_POOL_SIZE);

  // 每个可见槽位 k 的世界空间 8 关节解算坐标缓存
  private pHeadX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pHeadY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pHeadR: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pNeckX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pNeckY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pHipX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pHipY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pElLX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pElLY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pHaLX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pHaLY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pElRX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pElRY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pHaRX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pHaRY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pKnLX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pKnLY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pFtLX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pFtLY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pKnRX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pKnRY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pFtRX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pFtRY: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pDirX: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pAimCos: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pAimSin: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);
  private pScale: Float32Array = new Float32Array(GameConstants.MAX_UNIT_POOL_SIZE);

  private readonly scratchPoint: Point2D = { x: 0, y: 0 };
  private readonly minimapRect: MinimapLayout = { x: 0, y: 0, width: 200, height: 100 };
  private readonly culledViewport: ViewportRect = { x: 0, y: 0, width: 1280, height: 800 };
  private readonly renderStats: BattleRenderStats = {
    totalActiveSoldiers: 0,
    visibleSoldiers: 0,
    culledSoldiers: 0,
    isFarLod: false,
    renderedCorpses: 0,
    renderedProjectiles: 0
  };

  constructor(viewportW: number = 1280, viewportH: number = 800) {
    this.setViewportSize(viewportW, viewportH);
    this.clampCamera();
    this.recomputeMinimapLayout();
    // 校验静态配置引用确保模块常驻链接
    if (FACTION_STATIC_CONFIGS.length === 0) {
      this.zoom = 0.75;
    }
  }

  /** 设置平板 Canvas 视口像素宽高 */
  public setViewportSize(viewportW: number, viewportH: number): void {
    this.viewportW = Math.max(120, safeNum(viewportW, 1280));
    this.viewportH = Math.max(120, safeNum(viewportH, 800));
    this.clampCamera();
    this.recomputeMinimapLayout();
  }

  /** 同步战场逻辑宽高（支持 4800×2400 野战与 5600×2600 攻城战无缝切换） */
  public setWorldSize(worldW: number, worldH: number): void {
    const nextW: number = Math.max(800, safeNum(worldW, GameConstants.BATTLEFIELD_WIDTH));
    const nextH: number = Math.max(600, safeNum(worldH, GameConstants.BATTLEFIELD_HEIGHT));
    if (nextW !== this.worldW || nextH !== this.worldH) {
      this.worldW = nextW;
      this.worldH = nextH;
      this.clampCamera();
      this.recomputeMinimapLayout();
    }
  }

  /** 直接设置摄像机世界中心与缩放倍率（严格限制在 0.45 ~ 1.65） */
  public setCamera(worldX: number, worldY: number, zoom?: number): void {
    if (zoom !== undefined) {
      this.zoom = clampNum(zoom, GameConstants.BATTLE_ZOOM_MIN, GameConstants.BATTLE_ZOOM_MAX);
    }
    this.camX = safeNum(worldX, this.camX);
    this.camY = safeNum(worldY, this.camY);
    this.clampCamera();
  }

  public getCameraX(): number {
    return this.camX;
  }

  public getCameraY(): number {
    return this.camY;
  }

  public getZoom(): number {
    return this.zoom;
  }

  public getViewportWidth(): number {
    return this.viewportW;
  }

  public getViewportHeight(): number {
    return this.viewportH;
  }

  /** 同步设置面板远景骨骼 LOD 档位（'auto_by_zoom' | 'high_detail' | 'perf_saver'） */
  public setLodPolicyMode(mode: string): void {
    this.lodPolicyMode = mode;
  }

  /** 同步设置面板 M-Pencil 手写笔有效拾取半径（px） */
  public setStylusPickRadiusPx(radiusPx: number): void {
    this.stylusPickRadiusPx = clampNum(radiusPx, 8, 64);
  }

  /** 获取最近一帧渲染统计快照 */
  public getLastRenderStats(): BattleRenderStats {
    return this.renderStats;
  }

  /** 屏幕拖拽平移视口 */
  public panByScreenDelta(dxScreen: number, dyScreen: number): void {
    const invZoom: number = 1.0 / this.zoom;
    this.camX -= safeNum(dxScreen, 0) * invZoom;
    this.camY -= safeNum(dyScreen, 0) * invZoom;
    this.clampCamera();
  }

  /** 双指捏合围绕屏幕锚点无级缩放（锚点下世界坐标保持不动） */
  public zoomAtScreenPoint(nextZoom: number, anchorScreenX: number, anchorScreenY: number): void {
    const sx: number = safeNum(anchorScreenX, this.viewportW * 0.5);
    const sy: number = safeNum(anchorScreenY, this.viewportH * 0.5);
    const beforeWorldX: number = (sx - this.viewportW * 0.5 - this.shakeOffsetX) / this.zoom + this.camX;
    const beforeWorldY: number = (sy - this.viewportH * 0.5 - this.shakeOffsetY) / this.zoom + this.camY;

    this.zoom = clampNum(nextZoom, GameConstants.BATTLE_ZOOM_MIN, GameConstants.BATTLE_ZOOM_MAX);
    this.camX = beforeWorldX - (sx - this.viewportW * 0.5 - this.shakeOffsetX) / this.zoom;
    this.camY = beforeWorldY - (sy - this.viewportH * 0.5 - this.shakeOffsetY) / this.zoom;
    this.clampCamera();
  }

  /** 主动触发重劈顿帧/破阵微震屏（默认 40ms Hit-Stop 震幅） */
  public triggerHitStopShake(
    durationMs: number = GameConstants.HERO_HIT_STOP_MS,
    intensityPx: number = 5.5
  ): void {
    this.customShakeMaxMs = Math.max(1, safeNum(durationMs, GameConstants.HERO_HIT_STOP_MS));
    this.customShakeRemainingMs = this.customShakeMaxMs;
    this.customShakeIntensityPx = clampNum(intensityPx, 0, 24);
  }

  /**
   * 每帧更新摄像机：
   * - 英雄上阵模式下平滑插值跟随主帅并附加微前瞻偏移；
   * - 处理 40ms Hit-Stop 重击顿帧微震屏衰减
   */
  public updateCamera(world: BattleWorldReadonlyView, dtSec: number): void {
    const safeDt: number = clampNum(dtSec, 0, 0.25);
    this.animClockSec += safeDt;
    this.setWorldSize(world.width, world.height);

    if (
      world.hud.controlMode === BattleControlMode.HERO_ACTION &&
      world.playerHero.vitalState !== HeroVitalState.FALLEN_MARTYRED
    ) {
      const lookAheadX: number = Math.cos(safeNum(world.playerHero.facingRad, 0)) * 42;
      const lookAheadY: number = Math.sin(safeNum(world.playerHero.facingRad, 0)) * 24;
      const targetX: number = safeNum(world.playerHero.x, this.camX) + lookAheadX;
      const targetY: number = safeNum(world.playerHero.y, this.camY) + lookAheadY;
      const alpha: number = 1.0 - Math.exp(-9.0 * Math.max(0.008, safeDt));
      this.camX += (targetX - this.camX) * alpha;
      this.camY += (targetY - this.camY) * alpha;
      this.clampCamera();
    }

    const hudHitStopMs: number = safeNum(world.hud.hitStopRemainingMs, 0);
    if (this.customShakeRemainingMs > 0) {
      this.customShakeRemainingMs = Math.max(0, this.customShakeRemainingMs - safeDt * 1000.0);
    }

    const effectiveRemainMs: number = Math.max(hudHitStopMs, this.customShakeRemainingMs);
    if (effectiveRemainMs > 0) {
      const maxRefMs: number = hudHitStopMs > 0 ? GameConstants.HERO_HIT_STOP_MS : this.customShakeMaxMs;
      const ratio: number = clampNum(effectiveRemainMs / Math.max(1, maxRefMs), 0, 1);
      const amp: number = this.customShakeIntensityPx * ratio;
      const phase: number = effectiveRemainMs * 0.85 + this.animClockSec * 90.0;
      this.shakeOffsetX = Math.sin(phase * 2.3) * amp;
      this.shakeOffsetY = Math.cos(phase * 3.1) * amp * 0.75;
    } else {
      this.shakeOffsetX = 0;
      this.shakeOffsetY = 0;
    }
  }

  /** 屏幕像素坐标 -> 战场世界逻辑坐标（精确包含当前缩放与震屏偏移） */
  public screenToWorld(sx: number, sy: number, out?: Point2D): Point2D {
    const wx: number = (safeNum(sx, 0) - this.viewportW * 0.5 - this.shakeOffsetX) / this.zoom + this.camX;
    const wy: number = (safeNum(sy, 0) - this.viewportH * 0.5 - this.shakeOffsetY) / this.zoom + this.camY;
    if (out !== undefined) {
      out.x = wx;
      out.y = wy;
      return out;
    }
    const pt: Point2D = { x: wx, y: wy };
    return pt;
  }

  /** 战场世界逻辑坐标 -> 屏幕像素坐标（与 screenToWorld 严格互逆） */
  public worldToScreen(wx: number, wy: number, out?: Point2D): Point2D {
    const sx: number = (safeNum(wx, 0) - this.camX) * this.zoom + this.viewportW * 0.5 + this.shakeOffsetX;
    const sy: number = (safeNum(wy, 0) - this.camY) * this.zoom + this.viewportH * 0.5 + this.shakeOffsetY;
    if (out !== undefined) {
      out.x = sx;
      out.y = sy;
      return out;
    }
    const pt: Point2D = { x: sx, y: sy };
    return pt;
  }

  /**
   * 屏幕点击拾取作战军团：
   * - M-Pencil 手写笔采用精准 24px 热区（STYLUS_PICK_RADIUS_PX）
   * - 平板手指触控采用放大 44px 热区（FINGER_PICK_RADIUS_PX）
   */
  public pickSquadAtScreenPos(
    world: BattleWorldReadonlyView,
    sx: number,
    sy: number,
    isStylus: boolean = false,
    sideFilter?: BattleSide
  ): SquadRuntimeState | null {
    const pickRadiusPx: number = isStylus
      ? this.stylusPickRadiusPx
      : GameConstants.FINGER_PICK_RADIUS_PX;
    const maxDistSq: number = pickRadiusPx * pickRadiusPx;

    let bestSquad: SquadRuntimeState | null = null;
    let bestDistSq: number = maxDistSq;

    const squads: readonly SquadRuntimeState[] = world.squads;
    for (let i: number = 0; i < squads.length; i++) {
      const sq: SquadRuntimeState = squads[i];
      if (sq.aliveCount <= 0) {
        continue;
      }
      if (sideFilter !== undefined && sq.side !== sideFilter) {
        continue;
      }
      this.worldToScreen(sq.centerX, sq.centerY, this.scratchPoint);
      const dx: number = this.scratchPoint.x - sx;
      const dy: number = this.scratchPoint.y - sy;
      const distSq: number = dx * dx + dy * dy;
      if (distSq <= bestDistSq) {
        bestDistSq = distSq;
        bestSquad = sq;
      }
    }

    // 若未直接点中编队几何中心，再检测阵线边缘士兵（方便点选宽幅雁行阵两翼）
    if (bestSquad === null) {
      let bestSquadId: number = -1;
      const soldiers: readonly SoldierRuntimeEntity[] = world.soldiers;
      for (let i: number = 0; i < soldiers.length; i++) {
        const sol: SoldierRuntimeEntity = soldiers[i];
        if (!sol.active || sol.actionState === UnitActionState.FALLEN_CORPSE) {
          continue;
        }
        if (sideFilter !== undefined && sol.side !== sideFilter) {
          continue;
        }
        if (sol.side === BattleSide.ENEMY && !sol.visibleToPlayer) {
          continue;
        }
        this.worldToScreen(sol.x, sol.y, this.scratchPoint);
        const dx: number = this.scratchPoint.x - sx;
        const dy: number = this.scratchPoint.y - sy;
        const distSq: number = dx * dx + dy * dy;
        if (distSq <= bestDistSq) {
          bestDistSq = distSq;
          bestSquadId = sol.squadId;
        }
      }
      if (bestSquadId >= 0) {
        for (let j: number = 0; j < squads.length; j++) {
          if (squads[j].squadId === bestSquadId && squads[j].aliveCount > 0) {
            bestSquad = squads[j];
            break;
          }
        }
      }
    }

    return bestSquad;
  }

  /**
   * 屏幕框选矩形命中军团列表（返回命中的 squadId 数组，默认筛选玩家方军团）
   */
  public pickSquadsInScreenRect(
    world: BattleWorldReadonlyView,
    x1: number,
    y1: number,
    x2: number,
    y2: number,
    sideFilter: BattleSide = BattleSide.PLAYER
  ): number[] {
    const minX: number = Math.min(x1, x2);
    const maxX: number = Math.max(x1, x2);
    const minY: number = Math.min(y1, y2);
    const maxY: number = Math.max(y1, y2);
    const selectedIds: number[] = [];

    const squads: readonly SquadRuntimeState[] = world.squads;
    for (let i: number = 0; i < squads.length; i++) {
      const sq: SquadRuntimeState = squads[i];
      if (sq.aliveCount <= 0 || sq.side !== sideFilter) {
        continue;
      }
      this.worldToScreen(sq.centerX, sq.centerY, this.scratchPoint);
      if (
        this.scratchPoint.x >= minX &&
        this.scratchPoint.x <= maxX &&
        this.scratchPoint.y >= minY &&
        this.scratchPoint.y <= maxY
      ) {
        selectedIds.push(sq.squadId);
      }
    }

    // 补充检查士兵本体落入框选矩形但编队中心尚未进入框内的分队
    const soldiers: readonly SoldierRuntimeEntity[] = world.soldiers;
    for (let i: number = 0; i < soldiers.length; i++) {
      const sol: SoldierRuntimeEntity = soldiers[i];
      if (!sol.active || sol.side !== sideFilter || sol.actionState === UnitActionState.FALLEN_CORPSE) {
        continue;
      }
      if (sol.side === BattleSide.ENEMY && !sol.visibleToPlayer) {
        continue;
      }
      let alreadyAdded: boolean = false;
      for (let k: number = 0; k < selectedIds.length; k++) {
        if (selectedIds[k] === sol.squadId) {
          alreadyAdded = true;
          break;
        }
      }
      if (alreadyAdded) {
        continue;
      }
      this.worldToScreen(sol.x, sol.y, this.scratchPoint);
      if (
        this.scratchPoint.x >= minX &&
        this.scratchPoint.x <= maxX &&
        this.scratchPoint.y >= minY &&
        this.scratchPoint.y <= maxY
      ) {
        selectedIds.push(sol.squadId);
      }
    }

    return selectedIds;
  }

  /** 获取右上角战场缩略小地图的屏幕布局矩形 */
  public getMinimapLayout(): MinimapLayout {
    return this.minimapRect;
  }

  /** 判定屏幕坐标是否位于右上角小地图热区内 */
  public isPointInMinimap(sx: number, sy: number): boolean {
    return (
      sx >= this.minimapRect.x &&
      sx <= this.minimapRect.x + this.minimapRect.width &&
      sy >= this.minimapRect.y &&
      sy <= this.minimapRect.y + this.minimapRect.height
    );
  }

  /** 小地图屏幕坐标 -> 战场世界逻辑坐标（位于小地图外返回 null） */
  public minimapScreenToWorld(sx: number, sy: number, out?: Point2D): Point2D | null {
    if (!this.isPointInMinimap(sx, sy)) {
      return null;
    }
    const u: number = clampNum((sx - this.minimapRect.x) / Math.max(1, this.minimapRect.width), 0, 1);
    const v: number = clampNum((sy - this.minimapRect.y) / Math.max(1, this.minimapRect.height), 0, 1);
    const wx: number = u * this.worldW;
    const wy: number = v * this.worldH;
    if (out !== undefined) {
      out.x = wx;
      out.y = wy;
      return out;
    }
    const pt: Point2D = { x: wx, y: wy };
    return pt;
  }

  /** 战场世界逻辑坐标 -> 小地图屏幕像素坐标（与 minimapScreenToWorld 精确互逆） */
  public worldToMinimapScreen(wx: number, wy: number, out?: Point2D): Point2D {
    const u: number = clampNum(safeNum(wx, 0) / Math.max(1, this.worldW), 0, 1);
    const v: number = clampNum(safeNum(wy, 0) / Math.max(1, this.worldH), 0, 1);
    const sx: number = this.minimapRect.x + u * this.minimapRect.width;
    const sy: number = this.minimapRect.y + v * this.minimapRect.height;
    if (out !== undefined) {
      out.x = sx;
      out.y = sy;
      return out;
    }
    const pt: Point2D = { x: sx, y: sy };
    return pt;
  }

  /** 处理小地图点击快速跳转摄像机，命中返回 true */
  public handleMinimapTap(sx: number, sy: number): boolean {
    const hit: Point2D | null = this.minimapScreenToWorld(sx, sy, this.scratchPoint);
    if (hit === null) {
      return false;
    }
    this.setCamera(hit.x, hit.y);
    return true;
  }

  /**
   * 渲染完整单帧冷兵器大战场画面
   */
  public render(
    ctx: ICanvas2DContext,
    world: BattleWorldReadonlyView,
    overlay?: BattleSelectionOverlay
  ): BattleRenderStats {
    this.setWorldSize(world.width, world.height);
    const fogEnabled: boolean = overlay !== undefined && overlay.fogOfWarEnabled !== undefined
      ? overlay.fogOfWarEnabled
      : true;

    // 计算视口世界包络与 96px 安全裁剪外扩边界
    const halfViewW: number = (this.viewportW * 0.5 + Math.abs(this.shakeOffsetX)) / this.zoom;
    const halfViewH: number = (this.viewportH * 0.5 + Math.abs(this.shakeOffsetY)) / this.zoom;
    const margin: number = GameConstants.VIEWPORT_CULL_MARGIN;
    this.culledViewport.x = this.camX - halfViewW - margin;
    this.culledViewport.y = this.camY - halfViewH - margin;
    this.culledViewport.width = (halfViewW + margin) * 2.0;
    this.culledViewport.height = (halfViewH + margin) * 2.0;

    let isFarLod: boolean = this.zoom < FAR_LOD_ZOOM_THRESHOLD;
    if (this.lodPolicyMode === 'high_detail') {
      isFarLod = false;
    } else if (this.lodPolicyMode === 'perf_saver') {
      isFarLod = this.zoom < 0.90;
    }
    this.renderStats.isFarLod = isFarLod;

    ctx.clearRect(0, 0, this.viewportW, this.viewportH);
    ctx.save();
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.globalAlpha = 1.0;

    // 切入世界相机变换
    ctx.translate(this.viewportW * 0.5 + this.shakeOffsetX, this.viewportH * 0.5 + this.shakeOffsetY);
    ctx.scale(this.zoom, this.zoom);
    ctx.translate(-this.camX, -this.camY);

    // 1. 地形地貌、河流石桥、攻城城防与野外金木粮资源层
    this.renderTerrainAndFortLayer(ctx, world);

    // 2. 150 具古战场倒地遗骸与折断旌旗贴花池层
    this.renderStats.renderedCorpses = this.renderCorpseDecalLayer(ctx, world.corpses);

    // 3. 战术态势底纹层（选中光圈、M-Pencil 迂回航点虚线、八象限钳形/合围红色警示弧）
    this.renderTacticalGroundLayer(ctx, world.squads, overlay);

    // 4. 核心同色路径合批层：300~600 火柴人 8 关节骨骼 + 坐骑 + 攻城重器 + 16 兵种高辨识度武器
    this.renderBatchedSoldiersLayer(ctx, world, isFarLod, fogEnabled);

    // 5. 敌我双方主帅英雄层（金冠、披风、刀/枪/弓、铁壁横戈与三军战吼波纹）
    this.renderCommanderHeroesLayer(ctx, world, fogEnabled);

    // 6. 漫天抛物线箭矢（切线尾羽）、连弩钢矛、火雷、投石巨石与刀光火星特效层
    this.renderStats.renderedProjectiles = this.renderProjectilesAndEffectsLayer(
      ctx,
      world,
      isFarLod
    );

    // 7. 战场动态战争迷雾遮罩与天气昼夜氛围层
    if (fogEnabled) {
      this.renderFogOfWarLayer(ctx, world);
    }

    ctx.restore();

    // 8. 屏幕空间天气滤镜、RTS 框选绿框、手写笔实时轨迹与右上角战术缩略小地图
    this.renderScreenWeatherAndSelectionOverlay(ctx, world.weather, overlay);
    this.renderMinimapOverlay(ctx, world, fogEnabled);

    return this.renderStats;
  }

  // ==================== 内部辅助与分层合批实现 ====================

  private clampCamera(): void {
    this.zoom = clampNum(this.zoom, GameConstants.BATTLE_ZOOM_MIN, GameConstants.BATTLE_ZOOM_MAX);
    const halfW: number = (this.viewportW * 0.5) / this.zoom;
    const halfH: number = (this.viewportH * 0.5) / this.zoom;

    if (this.worldW <= halfW * 2.0) {
      this.camX = this.worldW * 0.5;
    } else {
      this.camX = clampNum(this.camX, halfW, this.worldW - halfW);
    }

    if (this.worldH <= halfH * 2.0) {
      this.camY = this.worldH * 0.5;
    } else {
      this.camY = clampNum(this.camY, halfH, this.worldH - halfH);
    }
  }

  private recomputeMinimapLayout(): void {
    const margin: number = 14;
    const mapW: number = clampNum(Math.floor(this.viewportW * 0.18), 156, 236);
    const aspect: number = this.worldH / Math.max(1, this.worldW);
    const mapH: number = Math.max(76, Math.round(mapW * aspect));
    this.minimapRect.width = mapW;
    this.minimapRect.height = mapH;
    this.minimapRect.x = Math.max(margin, this.viewportW - mapW - margin);
    this.minimapRect.y = margin;
  }

  private isRectVisible(x: number, y: number, w: number, h: number): boolean {
    return !(
      x + w < this.culledViewport.x ||
      x > this.culledViewport.x + this.culledViewport.width ||
      y + h < this.culledViewport.y ||
      y > this.culledViewport.y + this.culledViewport.height
    );
  }

  private isPointVisible(x: number, y: number): boolean {
    return (
      x >= this.culledViewport.x &&
      x <= this.culledViewport.x + this.culledViewport.width &&
      y >= this.culledViewport.y &&
      y <= this.culledViewport.y + this.culledViewport.height
    );
  }

  private ensureSoldierCapacity(required: number): void {
    if (required <= this.poolCapacity) {
      return;
    }
    const nextCap: number = Math.max(required, this.poolCapacity * 2);
    this.poolCapacity = nextCap;
    this.visPoolIndices = new Int32Array(nextCap);
    this.visBucketNext = new Int32Array(nextCap);
    this.pHeadX = new Float32Array(nextCap);
    this.pHeadY = new Float32Array(nextCap);
    this.pHeadR = new Float32Array(nextCap);
    this.pNeckX = new Float32Array(nextCap);
    this.pNeckY = new Float32Array(nextCap);
    this.pHipX = new Float32Array(nextCap);
    this.pHipY = new Float32Array(nextCap);
    this.pElLX = new Float32Array(nextCap);
    this.pElLY = new Float32Array(nextCap);
    this.pHaLX = new Float32Array(nextCap);
    this.pHaLY = new Float32Array(nextCap);
    this.pElRX = new Float32Array(nextCap);
    this.pElRY = new Float32Array(nextCap);
    this.pHaRX = new Float32Array(nextCap);
    this.pHaRY = new Float32Array(nextCap);
    this.pKnLX = new Float32Array(nextCap);
    this.pKnLY = new Float32Array(nextCap);
    this.pFtLX = new Float32Array(nextCap);
    this.pFtLY = new Float32Array(nextCap);
    this.pKnRX = new Float32Array(nextCap);
    this.pKnRY = new Float32Array(nextCap);
    this.pFtRX = new Float32Array(nextCap);
    this.pFtRY = new Float32Array(nextCap);
    this.pDirX = new Float32Array(nextCap);
    this.pAimCos = new Float32Array(nextCap);
    this.pAimSin = new Float32Array(nextCap);
    this.pScale = new Float32Array(nextCap);
  }

  private getTerrainFillColor(terrain: TerrainType): string {
    switch (terrain) {
      case TerrainType.PLAIN:
        return '#2B2A22';
      case TerrainType.HIGH_GROUND:
        return '#3A342A';
      case TerrainType.RIVER_FORD:
        return '#1A3B4B';
      case TerrainType.BRIDGE_PASS:
        return '#4E463F';
      case TerrainType.DENSE_FOREST:
        return '#1C3022';
      case TerrainType.DESERT_DUNE:
        return '#524127';
      case TerrainType.SNOWFIELD:
        return '#3B4752';
      case TerrainType.FORT_WALL:
        return '#423E3B';
      default:
        return '#2B2A22';
    }
  }

  /**
   * 1. 绘制 8 种地形、等高线阴影、河流浅滩波纹、石桥、密林树冠、攻城护城河/城墙垛口/裂纹城门/箭塔/大营及资源点
   */
  private renderTerrainAndFortLayer(ctx: ICanvas2DContext, world: BattleWorldReadonlyView): void {
    const viewX: number = Math.max(0, this.culledViewport.x);
    const viewY: number = Math.max(0, this.culledViewport.y);
    const viewW: number = Math.min(this.worldW - viewX, this.culledViewport.width);
    const viewH: number = Math.min(this.worldH - viewY, this.culledViewport.height);

    // 主战场底色（仅填充可视包络避免超大矩形开销）
    ctx.fillStyle = this.getTerrainFillColor(world.primaryTerrain);
    if (viewW > 0 && viewH > 0) {
      ctx.fillRect(viewX, viewY, viewW, viewH);
    }

    // 三路战线微弱分带底纹（北翼走廊 / 中路决战区 / 南翼侧道）
    ctx.fillStyle = 'rgba(255, 248, 225, 0.025)';
    const centerBandY: number = this.worldH * 0.28;
    const centerBandH: number = this.worldH * 0.44;
    if (this.isRectVisible(0, centerBandY, this.worldW, centerBandH)) {
      ctx.fillRect(viewX, centerBandY, Math.max(0, viewW), centerBandH);
    }

    const zones: readonly TerrainZoneRect[] = world.terrainZones;
    // 1.1 地形区块底色填充
    for (let i: number = 0; i < zones.length; i++) {
      const z: TerrainZoneRect = zones[i];
      if (!this.isRectVisible(z.x, z.y, z.width, z.height)) {
        continue;
      }
      if (z.elevation >= 1 && z.terrain === TerrainType.HIGH_GROUND) {
        // 山坡高地背光投影
        ctx.fillStyle = 'rgba(0, 0, 0, 0.28)';
        ctx.fillRect(z.x + 10, z.y + 12, z.width, z.height);
      }
      ctx.fillStyle = this.getTerrainFillColor(z.terrain);
      ctx.fillRect(z.x, z.y, z.width, z.height);
    }

    // 攻城战外围护城河水带（SIEGE_ASSAULT / SIEGE_DEFENSE）
    if (
      world.scenarioType === BattleScenarioType.SIEGE_ASSAULT ||
      world.scenarioType === BattleScenarioType.SIEGE_DEFENSE
    ) {
      const moatX: number = world.scenarioType === BattleScenarioType.SIEGE_ASSAULT
        ? this.worldW * 0.66
        : this.worldW * 0.30;
      if (this.isRectVisible(moatX - 36, 0, 72, this.worldH)) {
        ctx.fillStyle = '#153140';
        ctx.fillRect(moatX - 32, 0, 64, this.worldH);
        // 中心吊桥栈道
        ctx.fillStyle = '#5D4037';
        ctx.fillRect(moatX - 36, this.worldH * 0.44, 72, this.worldH * 0.12);
      }
    }

    // 1.2 合批山坡高地等高线 + 荒漠沙丘纹理 + 雪原冰纹（单次 stroke）
    let hasContourLines: boolean = false;
    ctx.beginPath();
    for (let i: number = 0; i < zones.length; i++) {
      const z: TerrainZoneRect = zones[i];
      if (!this.isRectVisible(z.x, z.y, z.width, z.height)) {
        continue;
      }
      if (z.terrain === TerrainType.HIGH_GROUND || z.elevation >= 1) {
        const rings: number = Math.min(3, Math.max(2, z.elevation + 1));
        for (let r: number = 0; r < rings; r++) {
          const inset: number = 14 + r * 22;
          if (z.width > inset * 2 && z.height > inset * 2) {
            ctx.moveTo(z.x + inset, z.y + inset);
            ctx.lineTo(z.x + z.width - inset, z.y + inset);
            ctx.lineTo(z.x + z.width - inset, z.y + z.height - inset);
            ctx.lineTo(z.x + inset, z.y + z.height - inset);
            ctx.closePath();
            hasContourLines = true;
          }
        }
      } else if (z.terrain === TerrainType.DESERT_DUNE || z.terrain === TerrainType.SNOWFIELD) {
        const stepY: number = 64;
        for (let ry: number = z.y + 32; ry < z.y + z.height - 16; ry += stepY) {
          ctx.moveTo(z.x + 20, ry);
          ctx.quadraticCurveTo(z.x + z.width * 0.5, ry - 14, z.x + z.width - 20, ry);
          hasContourLines = true;
        }
      }
    }
    if (hasContourLines) {
      ctx.strokeStyle = 'rgba(236, 224, 196, 0.20)';
      ctx.lineWidth = 1.6;
      ctx.stroke();
    }

    // 1.3 合批河流浅滩波纹与水花线（单次 stroke）
    let hasRiverWaves: boolean = false;
    const waveShift: number = Math.sin(this.animClockSec * 2.4) * 10.0;
    ctx.beginPath();
    for (let i: number = 0; i < zones.length; i++) {
      const z: TerrainZoneRect = zones[i];
      if (z.terrain !== TerrainType.RIVER_FORD || !this.isRectVisible(z.x, z.y, z.width, z.height)) {
        continue;
      }
      for (let wy: number = z.y + 28; wy < z.y + z.height - 16; wy += 48) {
        for (let wx: number = z.x + 16; wx < z.x + z.width - 28; wx += 56) {
          const ox: number = wx + waveShift;
          ctx.moveTo(ox, wy);
          ctx.quadraticCurveTo(ox + 12, wy - 5, ox + 24, wy);
          hasRiverWaves = true;
        }
      }
    }
    if (hasRiverWaves) {
      ctx.strokeStyle = 'rgba(129, 212, 250, 0.36)';
      ctx.lineWidth = 1.5;
      ctx.stroke();
    }

    // 1.4 合批石桥栏杆桥板与城墙砖缝（单次 stroke）
    let hasBridgeMasonry: boolean = false;
    ctx.beginPath();
    for (let i: number = 0; i < zones.length; i++) {
      const z: TerrainZoneRect = zones[i];
      if (!this.isRectVisible(z.x, z.y, z.width, z.height)) {
        continue;
      }
      if (z.terrain === TerrainType.BRIDGE_PASS) {
        ctx.moveTo(z.x, z.y + 3);
        ctx.lineTo(z.x + z.width, z.y + 3);
        ctx.moveTo(z.x, z.y + z.height - 3);
        ctx.lineTo(z.x + z.width, z.y + z.height - 3);
        for (let bx: number = z.x + 20; bx < z.x + z.width; bx += 24) {
          ctx.moveTo(bx, z.y + 4);
          ctx.lineTo(bx, z.y + z.height - 4);
        }
        hasBridgeMasonry = true;
      }
    }
    if (hasBridgeMasonry) {
      ctx.strokeStyle = '#8D8277';
      ctx.lineWidth = 2.0;
      ctx.stroke();
    }

    // 1.5 合批迷雾密林树冠簇（单次 fill，零 stroke）
    let hasForestCanopy: boolean = false;
    ctx.beginPath();
    for (let i: number = 0; i < zones.length; i++) {
      const z: TerrainZoneRect = zones[i];
      if (z.terrain !== TerrainType.DENSE_FOREST || !this.isRectVisible(z.x, z.y, z.width, z.height)) {
        continue;
      }
      for (let ty: number = z.y + 28; ty < z.y + z.height - 18; ty += 52) {
        for (let tx: number = z.x + 28; tx < z.x + z.width - 18; tx += 54) {
          const jitterX: number = ((tx * 17 + ty * 31) % 19) - 9;
          const jitterY: number = ((tx * 23 + ty * 13) % 17) - 8;
          const cx: number = tx + jitterX;
          const cy: number = ty + jitterY;
          if (this.isPointVisible(cx, cy)) {
            ctx.moveTo(cx + 18, cy);
            ctx.arc(cx, cy, 18, 0, TWO_PI);
            hasForestCanopy = true;
          }
        }
      }
    }
    if (hasForestCanopy) {
      ctx.fillStyle = 'rgba(38, 78, 46, 0.65)';
      ctx.fill();
    }

    // 1.6 野外资源采集点（金矿脉 / 林场原木 / 农庄粮垛）
    const resNodes: readonly BattlefieldResourceNode[] = world.resourceNodes;
    for (let i: number = 0; i < resNodes.length; i++) {
      const rn: BattlefieldResourceNode = resNodes[i];
      if (!this.isPointVisible(rn.x, rn.y)) {
        continue;
      }
      const remainRatio: number = clampNum(rn.remainingAmount / Math.max(1, rn.maxAmount), 0, 1);
      // 底座圆盘
      ctx.fillStyle = 'rgba(18, 16, 14, 0.55)';
      ctx.beginPath();
      ctx.arc(rn.x, rn.y, 24, 0, TWO_PI);
      ctx.fill();

      if (rn.resourceKind === 'gold') {
        ctx.fillStyle = remainRatio > 0.05 ? '#FFB300' : '#616161';
        ctx.beginPath();
        ctx.moveTo(rn.x - 16, rn.y + 10);
        ctx.lineTo(rn.x - 6, rn.y - 14);
        ctx.lineTo(rn.x + 6, rn.y - 6);
        ctx.lineTo(rn.x + 14, rn.y - 12);
        ctx.lineTo(rn.x + 18, rn.y + 10);
        ctx.closePath();
        ctx.fill();
      } else if (rn.resourceKind === 'wood') {
        ctx.fillStyle = remainRatio > 0.05 ? '#795548' : '#4E342E';
        ctx.fillRect(rn.x - 16, rn.y - 4, 32, 8);
        ctx.fillRect(rn.x - 12, rn.y - 12, 24, 7);
        ctx.fillStyle = '#2E7D32';
        ctx.beginPath();
        ctx.moveTo(rn.x, rn.y - 24);
        ctx.lineTo(rn.x - 12, rn.y - 8);
        ctx.lineTo(rn.x + 12, rn.y - 8);
        ctx.closePath();
        ctx.fill();
      } else {
        ctx.fillStyle = remainRatio > 0.05 ? '#FBC02D' : '#757575';
        ctx.beginPath();
        ctx.arc(rn.x - 7, rn.y + 4, 11, PI, TWO_PI);
        ctx.arc(rn.x + 7, rn.y + 4, 11, PI, TWO_PI);
        ctx.closePath();
        ctx.fill();
      }
      // 储量进度条
      ctx.fillStyle = 'rgba(0, 0, 0, 0.65)';
      ctx.fillRect(rn.x - 18, rn.y + 16, 36, 4);
      ctx.fillStyle = rn.resourceKind === 'gold' ? '#FFD54F' : (rn.resourceKind === 'wood' ? '#A1887F' : '#AED581');
      ctx.fillRect(rn.x - 18, rn.y + 16, 36 * remainRatio, 4);
    }

    // 1.7 城墙垛口、城门耐久裂纹、箭塔、拒马与本阵大营（统一采用与物理引擎一致的左上角 x,y 矩形坐标系，全部结构体裂纹与拒马合批为 1 次 stroke）
    const structures: readonly FortStructureEntity[] = world.structures;
    let hasFortStrokeDetails: boolean = false;
    for (let i: number = 0; i < structures.length; i++) {
      const st: FortStructureEntity = structures[i];
      if (!this.isRectVisible(st.x, st.y, st.width, st.height)) {
        continue;
      }
      const left: number = st.x;
      const top: number = st.y;
      const cx: number = st.x + st.width * 0.5;
      const cy: number = st.y + st.height * 0.5;
      const hpRatio: number = clampNum(st.hp / Math.max(1, st.maxHp), 0, 1);
      const factionIdx: number = getFactionBucketIndex(
        st.side === BattleSide.PLAYER ? world.playerFaction : world.enemyFaction
      );

      if (st.kind === 'wall_segment') {
        ctx.fillStyle = st.isBreached ? '#2B2624' : '#544E4A';
        ctx.fillRect(left, top, st.width, st.height);
        if (!st.isBreached) {
          // 城墙垛口齿列
          ctx.fillStyle = '#6D655F';
          const merlonStep: number = 18;
          if (st.height >= st.width) {
            for (let my: number = top + 4; my < top + st.height - 10; my += merlonStep) {
              ctx.fillRect(left - 3, my, 7, 10);
              ctx.fillRect(left + st.width - 4, my, 7, 10);
            }
          } else {
            for (let mx: number = left + 4; mx < left + st.width - 10; mx += merlonStep) {
              ctx.fillRect(mx, top - 3, 10, 7);
            }
          }
        }
      } else if (st.kind === 'gate') {
        ctx.fillStyle = st.isBreached ? '#1E1916' : '#4E342E';
        ctx.fillRect(left, top, st.width, st.height);
        if (!st.isBreached) {
          ctx.fillStyle = '#8D6E63';
          ctx.fillRect(left + 4, top + 4, st.width - 8, st.height - 8);
        }
      } else if (st.kind === 'arrow_tower') {
        ctx.fillStyle = st.isBreached ? '#2A2523' : '#455A64';
        ctx.fillRect(left, top, st.width, st.height);
        if (!st.isBreached) {
          ctx.fillStyle = FACTION_PRIMARY_COLORS[factionIdx];
          ctx.beginPath();
          ctx.moveTo(cx, top - 12);
          ctx.lineTo(left - 4, top + 6);
          ctx.lineTo(left + st.width + 4, top + 6);
          ctx.closePath();
          ctx.fill();
        }
      } else if (st.kind === 'base_camp') {
        // 本阵大营木栅与帅帐
        ctx.fillStyle = 'rgba(32, 26, 22, 0.85)';
        ctx.fillRect(left, top, st.width, st.height);
        ctx.fillStyle = FACTION_PRIMARY_COLORS[factionIdx];
        ctx.beginPath();
        ctx.moveTo(cx, top + 8);
        ctx.lineTo(left + 12, cy + 14);
        ctx.lineTo(left + st.width - 12, cy + 14);
        ctx.closePath();
        ctx.fill();
        if (st.side === BattleSide.PLAYER && world.hud.garrisonBellActive) {
          ctx.fillStyle = '#FFD54F';
          ctx.beginPath();
          ctx.arc(cx, top - 10, 7, 0, TWO_PI);
          ctx.fill();
        }
      }

      if (hpRatio < 0.99 && !st.isBreached) {
        ctx.fillStyle = 'rgba(0, 0, 0, 0.70)';
        ctx.fillRect(cx - 22, top - 9, 44, 5);
        ctx.fillStyle = hpRatio > 0.4 ? '#66BB6A' : '#EF5350';
        ctx.fillRect(cx - 22, top - 9, 44 * hpRatio, 5);
      }
    }

    // 合批绘制所有城门耐久裂纹与木质拒马尖刺（单次 stroke）
    ctx.beginPath();
    for (let i: number = 0; i < structures.length; i++) {
      const st: FortStructureEntity = structures[i];
      if (!this.isRectVisible(st.x, st.y, st.width, st.height)) {
        continue;
      }
      const cx: number = st.x + st.width * 0.5;
      const cy: number = st.y + st.height * 0.5;
      const hpRatio: number = clampNum(st.hp / Math.max(1, st.maxHp), 0, 1);
      if (st.kind === 'wooden_stakes' && !st.isBreached) {
        const count: number = Math.max(2, Math.floor(Math.max(st.width, st.height) / 18));
        for (let c: number = 0; c < count; c++) {
          const t: number = count > 1 ? (c / (count - 1)) - 0.5 : 0;
          const sx: number = st.width >= st.height ? cx + t * (st.width - 12) : cx;
          const sy: number = st.height > st.width ? cy + t * (st.height - 12) : cy;
          ctx.moveTo(sx - 7, sy + 7);
          ctx.lineTo(sx + 7, sy - 7);
          ctx.moveTo(sx - 7, sy - 7);
          ctx.lineTo(sx + 7, sy + 7);
          hasFortStrokeDetails = true;
        }
      } else if ((st.kind === 'gate' || st.kind === 'wall_segment') && hpRatio < 0.80 && !st.isBreached) {
        // 城门/城墙受损裂纹随损伤加深扩展
        ctx.moveTo(cx - 6, cy - 12);
        ctx.lineTo(cx + 2, cy - 2);
        ctx.lineTo(cx - 5, cy + 9);
        if (hpRatio < 0.45) {
          ctx.moveTo(cx + 2, cy - 2);
          ctx.lineTo(cx + 11, cy + 7);
          ctx.moveTo(cx - 10, cy + 2);
          ctx.lineTo(cx - 2, cy + 4);
        }
        hasFortStrokeDetails = true;
      }
    }
    if (hasFortStrokeDetails) {
      ctx.strokeStyle = '#BCAAA4';
      ctx.lineWidth = 2.0;
      ctx.stroke();
    }
  }

  /**
   * 2. 合批渲染 150 具战场倒地遗骸与折断旌旗（最多 2 次 stroke）
   */
  private renderCorpseDecalLayer(ctx: ICanvas2DContext, corpses: readonly FallenCorpseDecal[]): number {
    let rendered: number = 0;
    let hasBrokenBanners: boolean = false;

    // 2.1 地面暗色战迹椭圆合批 fill
    ctx.beginPath();
    for (let i: number = 0; i < corpses.length; i++) {
      const c: FallenCorpseDecal = corpses[i];
      if (!c.active || !this.isPointVisible(c.x, c.y)) {
        continue;
      }
      rendered++;
      ctx.moveTo(c.x + 10, c.y + 2);
      ctx.ellipse(c.x, c.y + 2, 10, 4.5, 0, 0, TWO_PI);
      if (c.isBrokenBanner) {
        hasBrokenBanners = true;
      }
    }
    if (rendered === 0) {
      return 0;
    }
    ctx.fillStyle = 'rgba(62, 18, 18, 0.34)';
    ctx.fill();

    // 2.2 全部倒地火柴人躯干四肢与断矛单次合批 stroke
    ctx.beginPath();
    for (let i: number = 0; i < corpses.length; i++) {
      const c: FallenCorpseDecal = corpses[i];
      if (!c.active || !this.isPointVisible(c.x, c.y)) {
        continue;
      }
      const cosR: number = Math.cos(safeNum(c.rotationRad, 0));
      const sinR: number = Math.sin(safeNum(c.rotationRad, 0));
      const headX: number = c.x + cosR * 9;
      const headY: number = c.y + sinR * 9;
      const hipX: number = c.x - cosR * 4;
      const hipY: number = c.y - sinR * 4;

      // 头圈 + 脊柱 + 散落四肢
      ctx.moveTo(headX + 2.6, headY);
      ctx.arc(headX, headY, 2.6, 0, TWO_PI);
      ctx.moveTo(c.x + cosR * 6, c.y + sinR * 6);
      ctx.lineTo(hipX, hipY);
      ctx.moveTo(c.x + cosR * 4, c.y + sinR * 4);
      ctx.lineTo(c.x + cosR * 1 - sinR * 7, c.y + sinR * 1 + cosR * 7);
      ctx.moveTo(hipX, hipY);
      ctx.lineTo(hipX - cosR * 8 + sinR * 4, hipY - sinR * 8 - cosR * 4);
      ctx.moveTo(hipX, hipY);
      ctx.lineTo(hipX - cosR * 7 - sinR * 4, hipY - sinR * 7 + cosR * 4);
      if (c.isBrokenBanner) {
        ctx.moveTo(c.x - 4, c.y + 4);
        ctx.lineTo(c.x + 8, c.y - 18);
      }
    }
    ctx.strokeStyle = 'rgba(138, 128, 120, 0.65)';
    ctx.lineWidth = 1.7;
    ctx.stroke();

    // 2.3 折断旌旗残破旗面合批 fill（旗杆已并入 2.2 合批 stroke，零额外 stroke）
    if (hasBrokenBanners) {
      ctx.beginPath();
      for (let i: number = 0; i < corpses.length; i++) {
        const c: FallenCorpseDecal = corpses[i];
        if (!c.active || !c.isBrokenBanner || !this.isPointVisible(c.x, c.y)) {
          continue;
        }
        ctx.moveTo(c.x + 8, c.y - 18);
        ctx.lineTo(c.x + 22, c.y - 13);
        ctx.lineTo(c.x + 16, c.y - 10);
        ctx.lineTo(c.x + 20, c.y - 7);
        ctx.lineTo(c.x + 5, c.y - 9);
        ctx.closePath();
      }
      ctx.fillStyle = 'rgba(198, 40, 40, 0.68)';
      ctx.fill();
    }

    return rendered;
  }

  /**
   * 3. 渲染选中编队绿环、M-Pencil 迂回航点虚线箭头、八象限钳形/合围红色警示弧
   */
  private renderTacticalGroundLayer(
    ctx: ICanvas2DContext,
    squads: readonly SquadRuntimeState[],
    overlay?: BattleSelectionOverlay
  ): void {
    const selectedIds: readonly number[] | undefined = overlay !== undefined ? overlay.selectedSquadIds : undefined;

    // 3.1 选中编队地面战术绿环
    if (selectedIds !== undefined && selectedIds.length > 0) {
      let hasSelectionRing: boolean = false;
      ctx.beginPath();
      for (let i: number = 0; i < squads.length; i++) {
        const sq: SquadRuntimeState = squads[i];
        if (sq.aliveCount <= 0) {
          continue;
        }
        let isSelected: boolean = false;
        for (let k: number = 0; k < selectedIds.length; k++) {
          if (selectedIds[k] === sq.squadId) {
            isSelected = true;
            break;
          }
        }
        if (isSelected && this.isPointVisible(sq.centerX, sq.centerY)) {
          ctx.moveTo(sq.centerX + 38, sq.centerY);
          ctx.ellipse(sq.centerX, sq.centerY, 38, 22, 0, 0, TWO_PI);
          hasSelectionRing = true;
        }
      }
      if (hasSelectionRing) {
        ctx.strokeStyle = '#69F0AE';
        ctx.lineWidth = 2.4;
        ctx.stroke();
      }
    }

    // 3.2 玩家军团 M-Pencil 手写迂回航点虚线路径（单次虚线 stroke + 单次箭头 fill）
    let hasWaypoints: boolean = false;
    ctx.beginPath();
    for (let i: number = 0; i < squads.length; i++) {
      const sq: SquadRuntimeState = squads[i];
      if (sq.aliveCount <= 0 || sq.side !== BattleSide.PLAYER) {
        continue;
      }
      const wpLen: number = Math.min(sq.waypointsX.length, sq.waypointsY.length);
      const startIdx: number = Math.max(0, sq.waypointCursor);
      if (startIdx < wpLen) {
        ctx.moveTo(sq.centerX, sq.centerY);
        for (let w: number = startIdx; w < wpLen; w++) {
          ctx.lineTo(safeNum(sq.waypointsX[w], sq.centerX), safeNum(sq.waypointsY[w], sq.centerY));
        }
        hasWaypoints = true;
      }
    }
    if (hasWaypoints) {
      ctx.setLineDash(this.dashWaypoint);
      ctx.strokeStyle = 'rgba(129, 212, 250, 0.85)';
      ctx.lineWidth = 2.4;
      ctx.stroke();
      ctx.setLineDash(this.dashEmpty);

      // 终点战术箭头
      ctx.beginPath();
      for (let i: number = 0; i < squads.length; i++) {
        const sq: SquadRuntimeState = squads[i];
        if (sq.aliveCount <= 0 || sq.side !== BattleSide.PLAYER) {
          continue;
        }
        const wpLen: number = Math.min(sq.waypointsX.length, sq.waypointsY.length);
        const startIdx: number = Math.max(0, sq.waypointCursor);
        if (startIdx < wpLen) {
          const endX: number = safeNum(sq.waypointsX[wpLen - 1], sq.centerX);
          const endY: number = safeNum(sq.waypointsY[wpLen - 1], sq.centerY);
          const prevX: number = wpLen - 2 >= startIdx ? safeNum(sq.waypointsX[wpLen - 2], sq.centerX) : sq.centerX;
          const prevY: number = wpLen - 2 >= startIdx ? safeNum(sq.waypointsY[wpLen - 2], sq.centerY) : sq.centerY;
          const ang: number = Math.atan2(endY - prevY, endX - prevX);
          const cosA: number = Math.cos(ang);
          const sinA: number = Math.sin(ang);
          ctx.moveTo(endX + cosA * 10, endY + sinA * 10);
          ctx.lineTo(endX - cosA * 8 - sinA * 6, endY - sinA * 8 + cosA * 6);
          ctx.lineTo(endX - cosA * 8 + sinA * 6, endY - sinA * 8 - cosA * 6);
          ctx.closePath();
        }
      }
      ctx.fillStyle = '#81D4FA';
      ctx.fill();
    }

    // 3.3 军团八象限受敌扇区警示弧（侧翼/钳形琥珀弧 + 铁桶合围猩红双弧）
    let hasFlankPincerArc: boolean = false;
    let hasEncircledArc: boolean = false;
    const octSpan: number = PI * 0.25;

    ctx.beginPath();
    for (let i: number = 0; i < squads.length; i++) {
      const sq: SquadRuntimeState = squads[i];
      if (sq.aliveCount <= 0 || !this.isPointVisible(sq.centerX, sq.centerY)) {
        continue;
      }
      // 渡河半渡而击水陆脱节态（30% ~ 80% 涉水）易伤警示内环
      if (sq.fordRatio >= 0.30 && sq.fordRatio <= 0.80) {
        ctx.moveTo(sq.centerX + 32, sq.centerY);
        ctx.ellipse(sq.centerX, sq.centerY, 32, 17, 0, 0, TWO_PI);
        hasFlankPincerArc = true;
      }
      if (
        sq.encirclement === EncirclementState.CLEAR ||
        sq.encirclement === EncirclementState.ENCIRCLED
      ) {
        continue;
      }
      const mask: number = sq.threatOctantMask & 0xff;
      for (let oct: number = 0; oct < 8; oct++) {
        if ((mask & (1 << oct)) !== 0) {
          const a0: number = oct * octSpan + 0.06;
          const a1: number = (oct + 1) * octSpan - 0.06;
          ctx.moveTo(sq.centerX + Math.cos(a0) * 46, sq.centerY + Math.sin(a0) * 46);
          ctx.arc(sq.centerX, sq.centerY, 46, a0, a1);
          hasFlankPincerArc = true;
        }
      }
    }
    if (hasFlankPincerArc) {
      ctx.strokeStyle = 'rgba(255, 167, 38, 0.85)';
      ctx.lineWidth = 3.0;
      ctx.stroke();
    }

    ctx.beginPath();
    for (let i: number = 0; i < squads.length; i++) {
      const sq: SquadRuntimeState = squads[i];
      if (
        sq.aliveCount <= 0 ||
        sq.encirclement !== EncirclementState.ENCIRCLED ||
        !this.isPointVisible(sq.centerX, sq.centerY)
      ) {
        continue;
      }
      const mask: number = sq.threatOctantMask !== 0 ? (sq.threatOctantMask & 0xff) : 0xff;
      for (let oct: number = 0; oct < 8; oct++) {
        if ((mask & (1 << oct)) !== 0) {
          const a0: number = oct * octSpan + 0.04;
          const a1: number = (oct + 1) * octSpan - 0.04;
          ctx.moveTo(sq.centerX + Math.cos(a0) * 50, sq.centerY + Math.sin(a0) * 50);
          ctx.arc(sq.centerX, sq.centerY, 50, a0, a1);
          hasEncircledArc = true;
        }
      }
    }
    if (hasEncircledArc) {
      ctx.setLineDash(this.dashEncircle);
      ctx.strokeStyle = '#FF1744';
      ctx.lineWidth = 3.6;
      ctx.stroke();
      ctx.setLineDash(this.dashEmpty);
    }
  }

  /**
   * 4. 核心火柴人 8 关节骨骼解算与同色路径合批渲染（Path Batching + LOD + 16 兵种剪影）
   */
  private renderBatchedSoldiersLayer(
    ctx: ICanvas2DContext,
    world: BattleWorldReadonlyView,
    isFarLod: boolean,
    fogEnabled: boolean
  ): void {
    const soldiers: readonly SoldierRuntimeEntity[] = world.soldiers;
    this.ensureSoldierCapacity(soldiers.length);

    for (let f: number = 0; f < FACTION_COUNT; f++) {
      this.factionBucketHead[f] = -1;
    }

    let totalActive: number = 0;
    let culledCount: number = 0;
    let visCount: number = 0;
    let hasHorses: boolean = false;
    let hasCamels: boolean = false;
    let hasTimberShafts: boolean = false;
    let hasColdSteel: boolean = false;
    let hasBows: boolean = false;
    let hasGiants: boolean = false;
    let hasStealthed: boolean = false;
    let hasRoutingFlags: boolean = false;
    let hasBanners: boolean = false;
    let hasInjuredHp: boolean = false;

    // 4.1 视口裁剪 + 8 关节骨骼姿态解算（屏外士兵 100% 跳过解算与绘制！）
    for (let i: number = 0; i < soldiers.length; i++) {
      const s: SoldierRuntimeEntity = soldiers[i];
      if (!s.active || s.actionState === UnitActionState.FALLEN_CORPSE) {
        continue;
      }
      totalActive++;

      if (fogEnabled && s.side === BattleSide.ENEMY && !s.visibleToPlayer) {
        culledCount++;
        continue;
      }

      const sx: number = safeNum(s.x, 0);
      const sy: number = safeNum(s.y, 0);
      if (!this.isPointVisible(sx, sy)) {
        culledCount++;
        continue;
      }

      const k: number = visCount;
      visCount++;
      this.visPoolIndices[k] = i;

      // 挂入势力同色静态单链表桶
      const bucketIdx: number = getFactionBucketIndex(s.factionId);
      this.visBucketNext[k] = this.factionBucketHead[bucketIdx];
      this.factionBucketHead[bucketIdx] = k;

      // 解算该士兵 8 关节世界坐标
      this.solveStickmanJoints(s, sx, sy, k, isFarLod);

      // 标记材质合批开关，避免空跑无用循环
      const ut: UnitTypeId = s.unitType;
      if (
        ut === UnitTypeId.LIGHT_CAVALRY ||
        ut === UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER ||
        ut === UnitTypeId.XUANJIA_CATAPHRACT
      ) {
        hasHorses = true;
      } else if (ut === UnitTypeId.SHAMO_MAMELUKE_CAMEL) {
        hasCamels = true;
      }

      if (
        ut === UnitTypeId.PIKEMAN ||
        ut === UnitTypeId.GREAT_AXEMAN ||
        ut === UnitTypeId.YANLONG_HALBERD_GRENADIER ||
        ut === UnitTypeId.SHUANGYUAN_GIANT_BREAKER ||
        ut === UnitTypeId.XUANJIA_CATAPHRACT ||
        ut === UnitTypeId.SAPPER ||
        ut === UnitTypeId.BALLISTA ||
        ut === UnitTypeId.TREBUCHET ||
        ut === UnitTypeId.XUEYUE_WARDRUM_BERSERKER ||
        s.isBannerBearer
      ) {
        hasTimberShafts = true;
      }

      if (
        ut === UnitTypeId.COMPOSITE_ARCHER ||
        ut === UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER ||
        ut === UnitTypeId.TIEYING_PAVISE_CROSSBOW ||
        ut === UnitTypeId.WULIN_SHADOW_SNIPER
      ) {
        hasBows = true;
      }

      hasColdSteel = true;
      if (ut === UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
        hasGiants = true;
      }
      if (s.isStealthed) {
        hasStealthed = true;
      }
      if (s.actionState === UnitActionState.ROUT_PANIC) {
        hasRoutingFlags = true;
      }
      if (s.isBannerBearer) {
        hasBanners = true;
      }
      if (s.hp < s.maxHp && s.hp > 0) {
        hasInjuredHp = true;
      }
    }

    this.renderStats.totalActiveSoldiers = totalActive;
    this.renderStats.culledSoldiers = culledCount;
    this.renderStats.visibleSoldiers = visCount;
    this.lastVisibleCount = visCount;

    if (visCount === 0) {
      this.renderSquadMoraleFlags(ctx, world.squads);
      return;
    }

    // 4.2 全体地面脚影椭圆合批（1 次 fill，0 次 stroke）
    ctx.beginPath();
    for (let k: number = 0; k < visCount; k++) {
      const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
      const rx: number = (s.unitType === UnitTypeId.BALLISTA || s.unitType === UnitTypeId.TREBUCHET)
        ? 18
        : (this.isMountedUnit(s.unitType) ? 14 : 7 * this.pScale[k]);
      const ry: number = rx * 0.36;
      ctx.moveTo(s.x + rx, s.y + 2);
      ctx.ellipse(s.x, s.y + 2, rx, ry, 0, 0, TWO_PI);
    }
    ctx.fillStyle = 'rgba(0, 0, 0, 0.32)';
    ctx.fill();

    // 4.3 战马四肢奔腾剪影合批（1 次 stroke）
    if (hasHorses) {
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        const ut: UnitTypeId = s.unitType;
        if (
          ut !== UnitTypeId.LIGHT_CAVALRY &&
          ut !== UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER &&
          ut !== UnitTypeId.XUANJIA_CATAPHRACT
        ) {
          continue;
        }
        const dir: number = this.pDirX[k];
        const phase: number = safeNum(s.animPhase, 0) * TWO_PI;
        const moving: boolean = s.actionState === UnitActionState.MARCH_RUN ||
          s.actionState === UnitActionState.CHARGE_SPRINT ||
          s.actionState === UnitActionState.ROUT_PANIC;
        const gallop: number = moving ? Math.sin(phase) * 7.5 : 0;
        const gallopOpp: number = moving ? Math.cos(phase) * 6.5 : 0;

        const chestX: number = s.x + dir * 9;
        const rumpX: number = s.x - dir * 9;
        const backY: number = s.y - 11;
        // 马背躯干 + 马颈马头 + 飘扬马尾
        ctx.moveTo(rumpX, backY);
        ctx.lineTo(chestX, backY);
        ctx.lineTo(chestX + dir * 6, backY - 9);
        ctx.lineTo(chestX + dir * 11, backY - 6);
        ctx.moveTo(rumpX, backY);
        ctx.lineTo(rumpX - dir * 6, backY + 5 - Math.abs(gallop) * 0.3);

        // 战马前后四蹄交替奔腾
        ctx.moveTo(chestX, backY);
        ctx.lineTo(chestX + dir * 3 + gallop, s.y);
        ctx.moveTo(chestX - dir * 2, backY);
        ctx.lineTo(chestX - gallopOpp, s.y);
        ctx.moveTo(rumpX + dir * 2, backY);
        ctx.lineTo(rumpX + gallopOpp, s.y);
        ctx.moveTo(rumpX, backY);
        ctx.lineTo(rumpX - dir * 3 - gallop, s.y);
      }
      ctx.strokeStyle = '#6D4C41';
      ctx.lineWidth = 2.4;
      ctx.stroke();
    }

    // 4.4 黄金马穆鲁克披甲骆驼高耸单峰剪影合批（1 次 stroke）
    if (hasCamels) {
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        if (s.unitType !== UnitTypeId.SHAMO_MAMELUKE_CAMEL) {
          continue;
        }
        const dir: number = this.pDirX[k];
        const stride: number = Math.sin(safeNum(s.animPhase, 0) * TWO_PI) * 6.5;
        const chestX: number = s.x + dir * 9;
        const rumpX: number = s.x - dir * 9;
        const backY: number = s.y - 13;
        // 驼峰曲线 + S 型长驼颈 + 四条修长驼腿
        ctx.moveTo(rumpX, backY);
        ctx.quadraticCurveTo(s.x, backY - 9, chestX, backY);
        ctx.quadraticCurveTo(chestX + dir * 6, backY + 3, chestX + dir * 9, backY - 11);
        ctx.lineTo(chestX + dir * 14, backY - 10);
        ctx.moveTo(chestX, backY);
        ctx.lineTo(chestX + stride, s.y);
        ctx.moveTo(chestX - dir * 2, backY);
        ctx.lineTo(chestX - stride * 0.7, s.y);
        ctx.moveTo(rumpX + dir * 2, backY);
        ctx.lineTo(rumpX - stride * 0.7, s.y);
        ctx.moveTo(rumpX, backY);
        ctx.lineTo(rumpX + stride, s.y);
      }
      ctx.strokeStyle = '#BCAAA4';
      ctx.lineWidth = 2.4;
      ctx.stroke();
    }

    // 4.5 木质枪杆 / 连弩车架 / 配重投石车长臂 / 大纛旗杆合批（1 次 stroke）
    if (hasTimberShafts) {
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        const ut: UnitTypeId = s.unitType;
        const dir: number = this.pDirX[k];
        const cosA: number = this.pAimCos[k];
        const sinA: number = this.pAimSin[k];
        const hx: number = this.pHaRX[k];
        const hy: number = this.pHaRY[k];

        if (ut === UnitTypeId.PIKEMAN) {
          // 48px 超长反骑枪丛
          const thrustBoost: number = s.actionState === UnitActionState.MELEE_STRIKE ? 8 : 0;
          const pikeLen: number = 44 + thrustBoost;
          ctx.moveTo(hx - cosA * 8, hy - sinA * 8);
          ctx.lineTo(hx + cosA * pikeLen, hy + sinA * pikeLen);
        } else if (ut === UnitTypeId.YANLONG_HALBERD_GRENADIER) {
          ctx.moveTo(hx - cosA * 6, hy - sinA * 6);
          ctx.lineTo(hx + cosA * 30, hy + sinA * 30);
        } else if (ut === UnitTypeId.XUANJIA_CATAPHRACT) {
          ctx.moveTo(hx - cosA * 6, hy - sinA * 6);
          ctx.lineTo(hx + cosA * 34, hy + sinA * 34);
        } else if (ut === UnitTypeId.GREAT_AXEMAN || ut === UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
          const haftLen: number = ut === UnitTypeId.SHUANGYUAN_GIANT_BREAKER ? 26 : 19;
          ctx.moveTo(hx - cosA * 4, hy - sinA * 4);
          ctx.lineTo(hx + cosA * haftLen, hy + sinA * haftLen);
        } else if (ut === UnitTypeId.SAPPER) {
          ctx.moveTo(hx, hy);
          ctx.lineTo(hx + cosA * 13, hy + sinA * 13);
        } else if (ut === UnitTypeId.BALLISTA) {
          // 破甲连弩车双轮木架与弩槽
          ctx.moveTo(s.x - 14, s.y - 6);
          ctx.lineTo(s.x + 14, s.y - 6);
          ctx.moveTo(s.x - 8, s.y);
          ctx.arc(s.x - 11, s.y - 3, 4, 0, TWO_PI);
          ctx.moveTo(s.x + 12, s.y);
          ctx.arc(s.x + 9, s.y - 3, 4, 0, TWO_PI);
          ctx.moveTo(s.x - dir * 8, s.y - 12);
          ctx.lineTo(s.x + dir * 22, s.y - 13);
        } else if (ut === UnitTypeId.TREBUCHET) {
          // 配重投石车 A 字高架与动态抛射长臂
          const swingAng: number = (s.actionState === UnitActionState.RANGED_DRAW_FIRE ||
            s.actionState === UnitActionState.MELEE_STRIKE)
            ? (-0.9 + safeNum(s.animPhase, 0) * 1.6) * dir
            : -0.55 * dir;
          const pivotX: number = s.x;
          const pivotY: number = s.y - 24;
          ctx.moveTo(s.x - 16, s.y);
          ctx.lineTo(s.x + 16, s.y);
          ctx.moveTo(s.x - 13, s.y);
          ctx.lineTo(pivotX, pivotY);
          ctx.lineTo(s.x + 13, s.y);
          const armCos: number = Math.cos(swingAng);
          const armSin: number = Math.sin(swingAng);
          ctx.moveTo(pivotX - armCos * 12, pivotY - armSin * 12);
          ctx.lineTo(pivotX + armCos * 30, pivotY + armSin * 30);
          // 配重箱竖杆
          ctx.moveTo(pivotX - armCos * 12, pivotY - armSin * 12);
          ctx.lineTo(pivotX - armCos * 12, pivotY - armSin * 12 + 9);
        } else if (ut === UnitTypeId.XUEYUE_WARDRUM_BERSERKER && s.poolIndex % 5 === 0) {
          // 血月祭团随军战鼓桶框与鼓槌
          const drumX: number = this.pHipX[k] + dir * 5.5;
          const drumY: number = this.pHipY[k] - 1.5;
          ctx.moveTo(drumX - 3.5, drumY - 4);
          ctx.lineTo(drumX + 3.5, drumY - 4);
          ctx.lineTo(drumX + 3.5, drumY + 4);
          ctx.lineTo(drumX - 3.5, drumY + 4);
          ctx.closePath();
        }

        // 军团执旗官高耸大纛旗杆（52px）
        if (s.isBannerBearer) {
          const bx: number = this.pHaLX[k];
          const by: number = this.pHaLY[k];
          ctx.moveTo(bx, s.y);
          ctx.lineTo(bx, by - 40);
        }
      }
      ctx.strokeStyle = '#8D6E63';
      ctx.lineWidth = 2.1;
      ctx.stroke();
    }

    // 4.6 按势力主色分组 Path Batching 绘制火柴人头部（fill）与 8 关节躯干四肢（每在场势力仅 1 次 stroke！）
    for (let f: number = 0; f < FACTION_COUNT; f++) {
      const headSlot: number = this.factionBucketHead[f];
      if (headSlot < 0) {
        continue;
      }

      // 4.6a 同势力全体火柴人实心头颅 + 铁浮图具装马甲 + 战旗旗面（1 次 fill）
      ctx.beginPath();
      let cur: number = headSlot;
      while (cur >= 0) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[cur]];
        if (!s.isStealthed) {
          const hx: number = this.pHeadX[cur];
          const hy: number = this.pHeadY[cur];
          const hr: number = this.pHeadR[cur];
          ctx.moveTo(hx + hr, hy);
          ctx.arc(hx, hy, hr, 0, TWO_PI);

          // 玄甲铁浮图披挂马甲片 / 沙漠马穆鲁克鎏金鞍毯 / 炎龙神机重卫震天火雷
          if (s.unitType === UnitTypeId.XUANJIA_CATAPHRACT) {
            ctx.moveTo(s.x - 12, s.y - 13);
            ctx.lineTo(s.x + 12, s.y - 13);
            ctx.lineTo(s.x + 14, s.y - 5);
            ctx.lineTo(s.x - 14, s.y - 5);
            ctx.closePath();
          } else if (s.unitType === UnitTypeId.SHAMO_MAMELUKE_CAMEL) {
            ctx.moveTo(s.x - 8, s.y - 16);
            ctx.lineTo(s.x + 8, s.y - 16);
            ctx.lineTo(s.x + 10, s.y - 9);
            ctx.lineTo(s.x - 10, s.y - 9);
            ctx.closePath();
          } else if (s.unitType === UnitTypeId.YANLONG_HALBERD_GRENADIER && !s.grenadeUsed) {
            const bx: number = this.pHipX[cur] - this.pDirX[cur] * 3.5;
            const by: number = this.pHipY[cur] + 1.0;
            ctx.moveTo(bx + 2.6, by);
            ctx.arc(bx, by, 2.6, 0, TWO_PI);
          }

          // 执旗官迎风猎猎燕尾大纛旗面
          if (s.isBannerBearer && hasBanners) {
            const poleX: number = this.pHaLX[cur];
            const topY: number = this.pHaLY[cur] - 40;
            const flutter: number = Math.sin(this.animClockSec * 6.0 + cur) * 3.0;
            const flagDir: number = -this.pDirX[cur];
            ctx.moveTo(poleX, topY);
            ctx.lineTo(poleX + flagDir * 22, topY + 4 + flutter);
            ctx.lineTo(poleX + flagDir * 16, topY + 10 + flutter * 0.5);
            ctx.lineTo(poleX + flagDir * 23, topY + 16 + flutter);
            ctx.lineTo(poleX, topY + 15);
            ctx.closePath();
          }
        }
        cur = this.visBucketNext[cur];
      }
      ctx.fillStyle = FACTION_PRIMARY_COLORS[f];
      ctx.fill();

      // 4.6b 同势力全体火柴人 8 关节躯干四肢线段合批（单次 stroke！）
      ctx.beginPath();
      cur = headSlot;
      let nonStealthDrawn: boolean = false;
      while (cur >= 0) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[cur]];
        if (!s.isStealthed) {
          nonStealthDrawn = true;
          this.appendStickmanSkeletonPath(ctx, cur, isFarLod);
        }
        cur = this.visBucketNext[cur];
      }
      if (nonStealthDrawn) {
        ctx.strokeStyle = FACTION_PRIMARY_COLORS[f];
        ctx.lineWidth = isFarLod ? 2.1 : 2.5;
        ctx.stroke();
      }
    }

    // 4.7 霜原巨熊破阵者 1.35x 魁梧肩甲重骨加粗批次（仅在场有巨人时 1 次 stroke）
    if (hasGiants) {
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        if (s.unitType !== UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
          continue;
        }
        // 加厚胸背骨骼与白熊皮肩甲横梁
        ctx.moveTo(this.pNeckX[k], this.pNeckY[k]);
        ctx.lineTo(this.pHipX[k], this.pHipY[k]);
        ctx.moveTo(this.pNeckX[k] - 6, this.pNeckY[k] + 2);
        ctx.lineTo(this.pNeckX[k] + 6, this.pNeckY[k] + 2);
      }
      ctx.strokeStyle = '#E0F7FA';
      ctx.lineWidth = 3.8;
      ctx.stroke();
    }

    // 4.8 雾林影袭神射潜行半透明批次（仅存在潜行单位时 1 次 stroke）
    if (hasStealthed) {
      ctx.save();
      ctx.globalAlpha = 0.42;
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        if (!s.isStealthed) {
          continue;
        }
        const hr: number = this.pHeadR[k];
        ctx.moveTo(this.pHeadX[k] + hr, this.pHeadY[k]);
        ctx.arc(this.pHeadX[k], this.pHeadY[k], hr, 0, TWO_PI);
        this.appendStickmanSkeletonPath(ctx, k, isFarLod);
      }
      ctx.strokeStyle = '#81C784';
      ctx.lineWidth = 2.2;
      ctx.stroke();
      ctx.restore();
    }

    // 4.9 复合弯弓 / 骑弓 / 钢弩臂 / 雾林长弓与满月弓弦合批（1 次 stroke）
    if (hasBows) {
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        const ut: UnitTypeId = s.unitType;
        if (
          ut !== UnitTypeId.COMPOSITE_ARCHER &&
          ut !== UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER &&
          ut !== UnitTypeId.TIEYING_PAVISE_CROSSBOW &&
          ut !== UnitTypeId.WULIN_SHADOW_SNIPER
        ) {
          continue;
        }
        const cosA: number = this.pAimCos[k];
        const sinA: number = this.pAimSin[k];
        const perpX: number = -sinA;
        const perpY: number = cosA;
        const bowX: number = this.pHaLX[k];
        const bowY: number = this.pHaLY[k];
        const halfSpan: number = ut === UnitTypeId.WULIN_SHADOW_SNIPER ? 10.5 : 8.5;

        const tip1X: number = bowX + perpX * halfSpan - cosA * 3;
        const tip1Y: number = bowY + perpY * halfSpan - sinA * 3;
        const tip2X: number = bowX - perpX * halfSpan - cosA * 3;
        const tip2Y: number = bowY - perpY * halfSpan - sinA * 3;

        // 反曲弯弓弧背
        ctx.moveTo(tip1X, tip1Y);
        ctx.quadraticCurveTo(bowX + cosA * 6, bowY + sinA * 6, tip2X, tip2Y);
        // 挽弓满月弓弦折线与在弦羽箭
        const isDrawing: boolean = s.actionState === UnitActionState.RANGED_DRAW_FIRE;
        const pullX: number = isDrawing ? this.pHaRX[k] : bowX - cosA * 3;
        const pullY: number = isDrawing ? this.pHaRY[k] : bowY - sinA * 3;
        ctx.moveTo(tip1X, tip1Y);
        ctx.lineTo(pullX, pullY);
        ctx.lineTo(tip2X, tip2Y);
        if (isDrawing && safeNum(s.animPhase, 0) < 0.80) {
          ctx.moveTo(pullX, pullY);
          ctx.lineTo(bowX + cosA * 8.5, bowY + sinA * 8.5);
        }
      }
      ctx.strokeStyle = '#FFE082';
      ctx.lineWidth = 1.6;
      ctx.stroke();
    }

    // 4.10 16 兵种冷兵器锋刃 + 圆盾/塔盾护甲高辨识度剪影合批（1 次盾面 fill + 1 次寒铁锋刃 stroke）
    if (hasColdSteel) {
      // 4.10a 盾牌盾面（圆盾 + 铁鹰大背盾/塔盾 + 投石车配重块）单次合批 fill
      let hasShieldFill: boolean = false;
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        if (s.actionState === UnitActionState.ROUT_PANIC) {
          continue; // 溃逃士兵丢弃盾牌狂奔
        }
        const ut: UnitTypeId = s.unitType;
        const dir: number = this.pDirX[k];
        const shX: number = this.pHaLX[k];
        const shY: number = this.pHaLY[k];

        if (
          ut === UnitTypeId.SHIELD_SWORDSMAN ||
          ut === UnitTypeId.LIGHT_CAVALRY ||
          ut === UnitTypeId.SHAMO_MAMELUKE_CAMEL
        ) {
          const r: number = ut === UnitTypeId.SHIELD_SWORDSMAN ? 6.8 : 5.2;
          ctx.moveTo(shX + r * 0.75, shY);
          ctx.ellipse(shX, shY, r * 0.75, r, 0, 0, TWO_PI);
          hasShieldFill = true;
        } else if (
          ut === UnitTypeId.TIEYING_PAVISE_CROSSBOW ||
          ut === UnitTypeId.YANLONG_HALBERD_GRENADIER ||
          ut === UnitTypeId.XUANJIA_CATAPHRACT
        ) {
          // 铁鹰神弩换弹转身背大盾 / 炎龙塔盾 / 玄甲护盾
          const reloadingBackShield: boolean = ut === UnitTypeId.TIEYING_PAVISE_CROSSBOW && s.attackCooldown > 0.55;
          const pavX: number = reloadingBackShield ? this.pNeckX[k] - dir * 5 : shX + dir * 2;
          const pavY: number = reloadingBackShield ? this.pNeckY[k] + 5 : shY;
          ctx.moveTo(pavX - 3.5, pavY - 8.5);
          ctx.lineTo(pavX + 3.5, pavY - 8.5);
          ctx.lineTo(pavX + 3.5, pavY + 8.5);
          ctx.lineTo(pavX - 3.5, pavY + 8.5);
          ctx.closePath();
          hasShieldFill = true;
        }
      }
      if (hasShieldFill) {
        ctx.fillStyle = '#455A64';
        ctx.fill();
      }

      // 4.10b 全体士兵寒铁刀剑、48px 枪尖、月牙戟、重斧、破阵巨锤、双狂战斧、弯刀、盾缘合批（1 次 stroke！）
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        const ut: UnitTypeId = s.unitType;
        const cosA: number = this.pAimCos[k];
        const sinA: number = this.pAimSin[k];
        const perpX: number = -sinA;
        const perpY: number = cosA;
        const hx: number = this.pHaRX[k];
        const hy: number = this.pHaRY[k];

        if (ut === UnitTypeId.SHIELD_SWORDSMAN || ut === UnitTypeId.LIGHT_CAVALRY) {
          ctx.moveTo(hx, hy);
          ctx.lineTo(hx + cosA * 15, hy + sinA * 15);
        } else if (ut === UnitTypeId.SHAMO_MAMELUKE_CAMEL || ut === UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER) {
          if (ut === UnitTypeId.SHAMO_MAMELUKE_CAMEL || s.actionState === UnitActionState.MELEE_STRIKE) {
            ctx.moveTo(hx, hy);
            ctx.quadraticCurveTo(hx + cosA * 9 + perpX * 4, hy + sinA * 9 + perpY * 4, hx + cosA * 16, hy + sinA * 16);
          }
        } else if (ut === UnitTypeId.PIKEMAN) {
          const thrustBoost: number = s.actionState === UnitActionState.MELEE_STRIKE ? 8 : 0;
          const tipBaseX: number = hx + cosA * (42 + thrustBoost);
          const tipBaseY: number = hy + sinA * (42 + thrustBoost);
          ctx.moveTo(tipBaseX, tipBaseY);
          ctx.lineTo(tipBaseX + cosA * 7, tipBaseY + sinA * 7);
        } else if (ut === UnitTypeId.YANLONG_HALBERD_GRENADIER) {
          const tipX: number = hx + cosA * 30;
          const tipY: number = hy + sinA * 30;
          ctx.moveTo(tipX - cosA * 5, tipY - sinA * 5);
          ctx.lineTo(tipX + cosA * 6, tipY + sinA * 6);
          // 月牙戟耳刃
          ctx.moveTo(tipX - cosA * 6 + perpX * 5, tipY - sinA * 6 + perpY * 5);
          ctx.lineTo(tipX - cosA * 2 + perpX * 6, tipY - sinA * 2 + perpY * 6);
        } else if (ut === UnitTypeId.XUANJIA_CATAPHRACT) {
          const tipX: number = hx + cosA * 34;
          const tipY: number = hy + sinA * 34;
          ctx.moveTo(tipX - cosA * 6, tipY - sinA * 6);
          ctx.lineTo(tipX + cosA * 7, tipY + sinA * 7);
        } else if (ut === UnitTypeId.GREAT_AXEMAN) {
          const headX: number = hx + cosA * 18;
          const headY: number = hy + sinA * 18;
          ctx.moveTo(headX - cosA * 4 + perpX * 7, headY - sinA * 4 + perpY * 7);
          ctx.quadraticCurveTo(headX + cosA * 4 + perpX * 9, headY + sinA * 4 + perpY * 9, headX + cosA * 5, headY + sinA * 5);
        } else if (ut === UnitTypeId.SHUANGYUAN_GIANT_BREAKER) {
          // 巨熊破阵重锤方头锤块
          const hmX: number = hx + cosA * 25;
          const hmY: number = hy + sinA * 25;
          ctx.moveTo(hmX - perpX * 7, hmY - perpY * 7);
          ctx.lineTo(hmX + perpX * 7, hmY + perpY * 7);
          ctx.moveTo(hmX - cosA * 3 - perpX * 6, hmY - sinA * 3 - perpY * 6);
          ctx.lineTo(hmX - cosA * 3 + perpX * 6, hmY - sinA * 3 + perpY * 6);
        } else if (ut === UnitTypeId.XUEYUE_WARDRUM_BERSERKER) {
          // 血月狂战士双手双斧
          ctx.moveTo(hx, hy);
          ctx.lineTo(hx + cosA * 11 + perpX * 4, hy + sinA * 11 + perpY * 4);
          const lx: number = this.pHaLX[k];
          const ly: number = this.pHaLY[k];
          ctx.moveTo(lx, ly);
          ctx.lineTo(lx + cosA * 11 - perpX * 4, ly + sinA * 11 - perpY * 4);
        } else if (ut === UnitTypeId.SAPPER) {
          const pkX: number = hx + cosA * 13;
          const pkY: number = hy + sinA * 13;
          ctx.moveTo(pkX - perpX * 5, pkY - perpY * 5);
          ctx.lineTo(pkX + perpX * 5, pkY + perpY * 5);
        } else if (ut === UnitTypeId.BALLISTA) {
          const dir: number = this.pDirX[k];
          ctx.moveTo(s.x + dir * 10, s.y - 20);
          ctx.lineTo(s.x + dir * 16, s.y - 13);
          ctx.lineTo(s.x + dir * 10, s.y - 6);
          ctx.moveTo(s.x + dir * 4, s.y - 13);
          ctx.lineTo(s.x + dir * 26, s.y - 13);
        }
      }
      ctx.strokeStyle = '#ECEFF1';
      ctx.lineWidth = 2.0;
      ctx.stroke();
    }

    // 4.11 溃逃士兵头顶恐慌小白旗合批（1 次 fill）
    if (hasRoutingFlags) {
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        if (s.actionState !== UnitActionState.ROUT_PANIC) {
          continue;
        }
        const fx: number = this.pHeadX[k];
        const fy: number = this.pHeadY[k] - 10;
        ctx.moveTo(fx, fy);
        ctx.lineTo(fx + 8, fy + 2.5);
        ctx.lineTo(fx, fy + 5.5);
        ctx.closePath();
      }
      ctx.fillStyle = '#FAFAFA';
      ctx.fill();
    }

    // 4.12 近景特写下受伤士兵轻量血条合批（仅 fill，0 次 stroke）
    if (hasInjuredHp && !isFarLod && this.zoom >= 0.72) {
      ctx.beginPath();
      for (let k: number = 0; k < visCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        if (s.hp >= s.maxHp || s.hp <= 0 || s.isStealthed) {
          continue;
        }
        const ratio: number = clampNum(s.hp / Math.max(1, s.maxHp), 0, 1);
        const bx: number = this.pHeadX[k] - 7;
        const by: number = this.pHeadY[k] - this.pHeadR[k] - 6;
        const w: number = 14 * ratio;
        ctx.moveTo(bx, by);
        ctx.lineTo(bx + w, by);
        ctx.lineTo(bx + w, by + 2.2);
        ctx.lineTo(bx, by + 2.2);
        ctx.closePath();
      }
      ctx.fillStyle = '#69F0AE';
      ctx.fill();
    }

    // 4.13 军团动摇黄旗 / 溃逃白旗集中标识
    this.renderSquadMoraleFlags(ctx, world.squads);
  }

  /**
   * 解算单名火柴人 11 态程序化 8 关节骨骼坐标（零堆分配，直接写入 Float32Array 槽位 k）
   */
  private solveStickmanJoints(
    s: SoldierRuntimeEntity,
    sx: number,
    sy: number,
    k: number,
    isFarLod: boolean
  ): void {
    const scale: number = s.unitType === UnitTypeId.SHUANGYUAN_GIANT_BREAKER ? 1.35 : 1.0;
    this.pScale[k] = scale;

    const facing: number = safeNum(s.facingRad, 0);
    const cosF: number = Math.cos(facing);
    const sinF: number = Math.sin(facing);
    const dirX: number = cosF >= 0 ? 1.0 : -1.0;
    this.pDirX[k] = dirX;
    this.pAimCos[k] = cosF;
    this.pAimSin[k] = sinF;

    const phase: number = clampNum(safeNum(s.animPhase, 0), 0, 1);
    const rad: number = phase * TWO_PI;
    const mountedLift: number = s.unitType === UnitTypeId.SHAMO_MAMELUKE_CAMEL
      ? 11.0
      : (this.isMountedUnit(s.unitType) ? 8.5 : 0.0);

    let leanX: number = 0;
    let bounceY: number = 0;
    let fallTilt: number = 0;
    const st: UnitActionState = s.actionState;

    if (st === UnitActionState.IDLE_READY) {
      bounceY = Math.sin(rad) * 0.9;
      leanX = dirX * 1.2;
    } else if (st === UnitActionState.MARCH_RUN) {
      bounceY = -Math.abs(Math.sin(rad)) * 2.2;
      leanX = dirX * 2.8;
    } else if (st === UnitActionState.CHARGE_SPRINT) {
      bounceY = -Math.abs(Math.sin(rad)) * 2.8;
      leanX = dirX * 5.8;
    } else if (st === UnitActionState.MELEE_WINDUP) {
      leanX = -dirX * (2.5 + phase * 1.8);
    } else if (st === UnitActionState.MELEE_STRIKE) {
      leanX = dirX * (4.5 + Math.sin(phase * PI) * 2.5);
    } else if (st === UnitActionState.SHIELD_BLOCK) {
      bounceY = 2.0;
      leanX = -dirX * 1.6;
    } else if (st === UnitActionState.STAGGER_HIT) {
      leanX = -dirX * 5.2;
      bounceY = -1.2;
    } else if (st === UnitActionState.ROUT_PANIC) {
      bounceY = -Math.abs(Math.sin(rad * 2.0)) * 3.0;
      leanX = dirX * 4.2;
    } else if (st === UnitActionState.DYING_FALL) {
      fallTilt = clampNum(phase, 0, 1);
    }

    const hipX: number = sx + fallTilt * (-dirX * 6.0 * scale);
    const hipY: number = sy - (10.5 * scale + mountedLift) * (1.0 - fallTilt * 0.78) + bounceY;
    const neckX: number = hipX + (leanX + fallTilt * dirX * 11.0) * scale;
    const neckY: number = hipY - (9.5 * scale) * (1.0 - fallTilt * 0.85);
    const headR: number = 3.6 * scale;
    const headX: number = neckX + dirX * (0.9 + fallTilt * 3.8) * scale;
    const headY: number = neckY - (headR + 0.8 * scale) * (1.0 - fallTilt * 0.72);

    this.pHipX[k] = hipX;
    this.pHipY[k] = hipY;
    this.pNeckX[k] = neckX;
    this.pNeckY[k] = neckY;
    this.pHeadX[k] = headX;
    this.pHeadY[k] = headY;
    this.pHeadR[k] = headR;

    // 远景精简 LOD（zoom < 0.60）：省去肘膝三角函数解算，仅计算主手与支撑脚端点
    if (isFarLod) {
      this.pFtLX[k] = sx - 3.5 * scale;
      this.pFtLY[k] = sy;
      this.pFtRX[k] = sx + 3.5 * scale;
      this.pFtRY[k] = sy;
      this.pHaLX[k] = neckX + dirX * 5.5 * scale;
      this.pHaLY[k] = neckY + 4.0 * scale;
      this.pHaRX[k] = neckX + cosF * 8.5 * scale;
      this.pHaRY[k] = neckY + sinF * 8.5 * scale + 2.0;
      return;
    }

    // 完整近中景 8 关节解算（双膝 + 双脚 + 双肘 + 双手）
    if (mountedLift > 0) {
      // 骑手跨鞍屈膝蹬镫姿态
      this.pKnLX[k] = hipX + dirX * 3.5;
      this.pKnLY[k] = hipY + 4.5;
      this.pFtLX[k] = hipX + dirX * 2.0;
      this.pFtLY[k] = hipY + 9.0;
      this.pKnRX[k] = hipX - dirX * 2.5;
      this.pKnRY[k] = hipY + 4.5;
      this.pFtRX[k] = hipX - dirX * 3.0;
      this.pFtRY[k] = hipY + 9.0;
    } else if (st === UnitActionState.MARCH_RUN || st === UnitActionState.CHARGE_SPRINT || st === UnitActionState.ROUT_PANIC) {
      const strideAmp: number = (st === UnitActionState.CHARGE_SPRINT ? 6.8 : 5.2) * scale;
      const sL: number = Math.sin(rad);
      const sR: number = -sL;
      this.pKnLX[k] = hipX + sL * strideAmp * 0.65 + dirX * 1.5;
      this.pKnLY[k] = (hipY + sy) * 0.5 - Math.max(0, sL) * 2.5;
      this.pFtLX[k] = sx + sL * strideAmp;
      this.pFtLY[k] = sy - Math.max(0, sL) * 2.2;

      this.pKnRX[k] = hipX + sR * strideAmp * 0.65 + dirX * 1.5;
      this.pKnRY[k] = (hipY + sy) * 0.5 - Math.max(0, sR) * 2.5;
      this.pFtRX[k] = sx + sR * strideAmp;
      this.pFtRY[k] = sy - Math.max(0, sR) * 2.2;
    } else if (st === UnitActionState.DYING_FALL) {
      // 致命倾倒跪地塌缩态
      this.pKnLX[k] = hipX - dirX * (2.5 + fallTilt * 4.5) * scale;
      this.pKnLY[k] = hipY + (sy - hipY) * (0.65 + fallTilt * 0.30);
      this.pFtLX[k] = sx - dirX * (4.0 + fallTilt * 6.0) * scale;
      this.pFtLY[k] = sy;

      this.pKnRX[k] = hipX + dirX * (2.2 - fallTilt * 4.0) * scale;
      this.pKnRY[k] = hipY + (sy - hipY) * (0.65 + fallTilt * 0.30);
      this.pFtRX[k] = sx + dirX * (3.5 - fallTilt * 6.5) * scale;
      this.pFtRY[k] = sy;
    } else if (st === UnitActionState.STAGGER_HIT) {
      // 受击硬直前脚离地后滑
      this.pKnLX[k] = hipX - dirX * 4.2 * scale;
      this.pKnLY[k] = (hipY + sy) * 0.55;
      this.pFtLX[k] = sx - dirX * 5.8 * scale;
      this.pFtLY[k] = sy;

      this.pKnRX[k] = hipX + dirX * 3.8 * scale;
      this.pKnRY[k] = hipY + 3.5 * scale;
      this.pFtRX[k] = sx + dirX * 6.2 * scale;
      this.pFtRY[k] = sy - 2.6 * scale;
    } else {
      // 戒备 / 挥砍弓步 / 格挡扎马步
      const lunge: number = st === UnitActionState.MELEE_STRIKE ? 3.2 * scale : 0;
      this.pKnLX[k] = hipX - dirX * 2.8 * scale;
      this.pKnLY[k] = (hipY + sy) * 0.5;
      this.pFtLX[k] = sx - dirX * 4.2 * scale;
      this.pFtLY[k] = sy;

      this.pKnRX[k] = hipX + dirX * (3.2 * scale + lunge * 0.5);
      this.pKnRY[k] = (hipY + sy) * 0.5;
      this.pFtRX[k] = sx + dirX * (4.4 * scale + lunge);
      this.pFtRY[k] = sy;
    }

    // 双臂与肘腕解算（覆盖 11 种动作状态）
    if (st === UnitActionState.ROUT_PANIC) {
      // 溃逃丢盾高举双手狂奔
      const wave: number = Math.sin(rad * 3.0) * 3.2 * scale;
      this.pElLX[k] = neckX - dirX * 4.5 * scale;
      this.pElLY[k] = neckY - 4.5 * scale;
      this.pHaLX[k] = neckX - dirX * 6.0 * scale + wave;
      this.pHaLY[k] = neckY - 10.5 * scale;

      this.pElRX[k] = neckX + dirX * 4.5 * scale;
      this.pElRY[k] = neckY - 4.5 * scale;
      this.pHaRX[k] = neckX + dirX * 6.0 * scale - wave;
      this.pHaRY[k] = neckY - 10.5 * scale;
    } else if (st === UnitActionState.RANGED_DRAW_FIRE) {
      // 挽弓搭箭满月态
      const drawRatio: number = phase < 0.78 ? (phase / 0.78) : 0.15;
      this.pElLX[k] = neckX + cosF * 5.2 * scale;
      this.pElLY[k] = neckY + sinF * 5.2 * scale + 1.2;
      this.pHaLX[k] = neckX + cosF * 10.5 * scale;
      this.pHaLY[k] = neckY + sinF * 10.5 * scale + 1.0;

      this.pElRX[k] = neckX - cosF * (4.5 + drawRatio * 3.5) * scale;
      this.pElRY[k] = neckY - 2.0 * scale;
      this.pHaRX[k] = neckX + cosF * (6.0 - drawRatio * 8.5) * scale;
      this.pHaRY[k] = neckY + sinF * (6.0 - drawRatio * 8.5) * scale + 1.0;
    } else if (st === UnitActionState.MELEE_WINDUP) {
      // 举刀/抡锤蓄力高举过顶
      this.pElLX[k] = neckX + dirX * 4.5 * scale;
      this.pElLY[k] = neckY + 3.5 * scale;
      this.pHaLX[k] = neckX + dirX * 7.2 * scale;
      this.pHaLY[k] = neckY + 2.5 * scale;

      this.pElRX[k] = neckX - dirX * 4.2 * scale;
      this.pElRY[k] = neckY - 4.8 * scale;
      this.pHaRX[k] = neckX - dirX * 2.0 * scale;
      this.pHaRY[k] = neckY - 10.2 * scale;
    } else if (st === UnitActionState.MELEE_STRIKE) {
      // 劈砍挥击 / 长枪猛刺前探
      this.pElLX[k] = neckX + dirX * 3.8 * scale;
      this.pElLY[k] = neckY + 4.0 * scale;
      this.pHaLX[k] = neckX + dirX * 6.2 * scale;
      this.pHaLY[k] = neckY + 3.5 * scale;

      this.pElRX[k] = neckX + cosF * 5.8 * scale;
      this.pElRY[k] = neckY + sinF * 5.8 * scale + 1.5;
      this.pHaRX[k] = neckX + cosF * 11.2 * scale;
      this.pHaRY[k] = neckY + sinF * 11.2 * scale + 2.0;
    } else if (st === UnitActionState.SHIELD_BLOCK) {
      // 顶盾招架态
      this.pElLX[k] = neckX + dirX * 5.2 * scale;
      this.pElLY[k] = neckY + 2.2 * scale;
      this.pHaLX[k] = neckX + dirX * 8.8 * scale;
      this.pHaLY[k] = neckY + 1.0 * scale;

      this.pElRX[k] = neckX - dirX * 2.8 * scale;
      this.pElRY[k] = neckY + 4.0 * scale;
      this.pHaRX[k] = neckX + dirX * 2.5 * scale;
      this.pHaRY[k] = neckY + 5.2 * scale;
    } else if (st === UnitActionState.STAGGER_HIT) {
      // 受击失衡双臂向两侧后张
      this.pElLX[k] = neckX + dirX * 4.8 * scale;
      this.pElLY[k] = neckY - 1.5 * scale;
      this.pHaLX[k] = neckX + dirX * 8.5 * scale;
      this.pHaLY[k] = neckY - 4.2 * scale;

      this.pElRX[k] = neckX - dirX * 5.2 * scale;
      this.pElRY[k] = neckY - 1.0 * scale;
      this.pHaRX[k] = neckX - dirX * 9.0 * scale;
      this.pHaRY[k] = neckY - 3.5 * scale;
    } else {
      // 呼吸戒备 / 奔跑摆臂 / 冲锋平端兵刃 / 倾倒
      const swing: number = (st === UnitActionState.MARCH_RUN || st === UnitActionState.CHARGE_SPRINT)
        ? Math.cos(rad) * 3.5 * scale
        : 0;
      this.pElLX[k] = neckX + dirX * 3.6 * scale - swing * 0.5;
      this.pElLY[k] = neckY + 4.2 * scale;
      this.pHaLX[k] = neckX + dirX * 6.8 * scale - swing;
      this.pHaLY[k] = neckY + 3.6 * scale;

      this.pElRX[k] = neckX - dirX * 2.2 * scale + swing * 0.5;
      this.pElRY[k] = neckY + 4.6 * scale;
      this.pHaRX[k] = neckX + cosF * 7.8 * scale + swing;
      this.pHaRY[k] = neckY + sinF * 7.8 * scale + 3.2 * scale;
    }
  }

  private appendStickmanSkeletonPath(ctx: ICanvas2DContext, k: number, isFarLod: boolean): void {
    // 躯干脊柱
    ctx.moveTo(this.pNeckX[k], this.pNeckY[k]);
    ctx.lineTo(this.pHipX[k], this.pHipY[k]);

    if (isFarLod) {
      // 远景精简 LOD：省去肘膝折点，直连支撑腿与持械主臂
      ctx.moveTo(this.pHipX[k], this.pHipY[k]);
      ctx.lineTo(this.pFtLX[k], this.pFtLY[k]);
      ctx.moveTo(this.pHipX[k], this.pHipY[k]);
      ctx.lineTo(this.pFtRX[k], this.pFtRY[k]);
      ctx.moveTo(this.pNeckX[k], this.pNeckY[k]);
      ctx.lineTo(this.pHaRX[k], this.pHaRY[k]);
    } else {
      // 完整 8 关节骨骼：肩->左肘->左手，肩->右肘->右手，胯->左膝->左脚，胯->右膝->右脚
      ctx.moveTo(this.pNeckX[k], this.pNeckY[k]);
      ctx.lineTo(this.pElLX[k], this.pElLY[k]);
      ctx.lineTo(this.pHaLX[k], this.pHaLY[k]);

      ctx.moveTo(this.pNeckX[k], this.pNeckY[k]);
      ctx.lineTo(this.pElRX[k], this.pElRY[k]);
      ctx.lineTo(this.pHaRX[k], this.pHaRY[k]);

      ctx.moveTo(this.pHipX[k], this.pHipY[k]);
      ctx.lineTo(this.pKnLX[k], this.pKnLY[k]);
      ctx.lineTo(this.pFtLX[k], this.pFtLY[k]);

      ctx.moveTo(this.pHipX[k], this.pHipY[k]);
      ctx.lineTo(this.pKnRX[k], this.pKnRY[k]);
      ctx.lineTo(this.pFtRX[k], this.pFtRY[k]);
    }
  }

  private isMountedUnit(ut: UnitTypeId): boolean {
    return (
      ut === UnitTypeId.LIGHT_CAVALRY ||
      ut === UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER ||
      ut === UnitTypeId.SHAMO_MAMELUKE_CAMEL ||
      ut === UnitTypeId.XUANJIA_CATAPHRACT
    );
  }

  /** 绘制各军团头顶动摇黄旗（morale < 40）与溃逃大白旗（isRouting） */
  private renderSquadMoraleFlags(ctx: ICanvas2DContext, squads: readonly SquadRuntimeState[]): void {
    let hasWavering: boolean = false;
    let hasRouting: boolean = false;

    ctx.beginPath();
    for (let i: number = 0; i < squads.length; i++) {
      const sq: SquadRuntimeState = squads[i];
      if (sq.aliveCount <= 0 || sq.isRouting || sq.morale >= GameConstants.MORALE_WAVERING_THRESHOLD) {
        continue;
      }
      if (this.isPointVisible(sq.centerX, sq.centerY)) {
        const fx: number = sq.centerX;
        const fy: number = sq.centerY - 42;
        ctx.moveTo(fx, fy);
        ctx.lineTo(fx + 14, fy + 5);
        ctx.lineTo(fx, fy + 10);
        ctx.closePath();
        hasWavering = true;
      }
    }
    if (hasWavering) {
      ctx.fillStyle = '#FFCA28';
      ctx.fill();
    }

    ctx.beginPath();
    for (let i: number = 0; i < squads.length; i++) {
      const sq: SquadRuntimeState = squads[i];
      if (sq.aliveCount <= 0 || !sq.isRouting) {
        continue;
      }
      if (this.isPointVisible(sq.centerX, sq.centerY)) {
        const fx: number = sq.centerX;
        const fy: number = sq.centerY - 44;
        ctx.moveTo(fx, fy);
        ctx.lineTo(fx + 16, fy + 6);
        ctx.lineTo(fx, fy + 12);
        ctx.closePath();
        hasRouting = true;
      }
    }
    if (hasRouting) {
      ctx.fillStyle = '#FFFFFF';
      ctx.fill();
    }
  }

  /**
   * 5. 渲染玩家主帅与敌方督战主帅（金冠、随风披风、统帅佩刀/破阵大枪/百石硬弓、铁壁横戈与三军战吼光环）
   */
  private renderCommanderHeroesLayer(
    ctx: ICanvas2DContext,
    world: BattleWorldReadonlyView,
    fogEnabled: boolean
  ): void {
    this.renderSingleHero(ctx, world.playerHero, true);
    const enemyHero: CommanderHeroRuntime = world.enemyHero;
    if (!fogEnabled || this.isEnemyHeroRevealed(world, enemyHero.x, enemyHero.y)) {
      this.renderSingleHero(ctx, enemyHero, false);
    }
  }

  private isEnemyHeroRevealed(world: BattleWorldReadonlyView, ex: number, ey: number): boolean {
    const rSq: number = GameConstants.VISION_RADIUS_CAVALRY * GameConstants.VISION_RADIUS_CAVALRY;
    const dxH: number = world.playerHero.x - ex;
    const dyH: number = world.playerHero.y - ey;
    if (dxH * dxH + dyH * dyH <= rSq) {
      return true;
    }
    const squads: readonly SquadRuntimeState[] = world.squads;
    for (let i: number = 0; i < squads.length; i++) {
      const sq: SquadRuntimeState = squads[i];
      if (sq.side === BattleSide.PLAYER && sq.aliveCount > 0) {
        const dx: number = sq.centerX - ex;
        const dy: number = sq.centerY - ey;
        if (dx * dx + dy * dy <= rSq) {
          return true;
        }
      }
    }
    return false;
  }

  private isEnemySquadRevealedOnMinimap(world: BattleWorldReadonlyView, sq: SquadRuntimeState): boolean {
    const soldiers: readonly SoldierRuntimeEntity[] = world.soldiers;
    let hasAssignedSoldier: boolean = false;
    for (let i: number = 0; i < soldiers.length; i++) {
      const s: SoldierRuntimeEntity = soldiers[i];
      if (!s.active || s.squadId !== sq.squadId || s.actionState === UnitActionState.FALLEN_CORPSE) {
        continue;
      }
      hasAssignedSoldier = true;
      if (s.visibleToPlayer) {
        return true;
      }
    }
    if (!hasAssignedSoldier) {
      return this.isEnemyHeroRevealed(world, sq.centerX, sq.centerY);
    }
    return false;
  }

  private renderSingleHero(ctx: ICanvas2DContext, hero: CommanderHeroRuntime, isPlayer: boolean): void {
    const hx: number = safeNum(hero.x, 0);
    const hy: number = safeNum(hero.y, 0);
    if (!this.isPointVisible(hx, hy)) {
      return;
    }
    const factionIdx: number = getFactionBucketIndex(hero.factionId);
    const primaryCol: string = FACTION_PRIMARY_COLORS[factionIdx];
    const accentCol: string = FACTION_ACCENT_COLORS[factionIdx];

    if (hero.vitalState === HeroVitalState.FALLEN_MARTYRED) {
      // 殉国帅旗折戟遗迹标记
      ctx.fillStyle = primaryCol;
      ctx.beginPath();
      ctx.moveTo(hx - 2, hy - 22);
      ctx.lineTo(hx + 14, hy - 16);
      ctx.lineTo(hx - 2, hy - 10);
      ctx.closePath();
      ctx.fill();
      return;
    }

    if (hero.vitalState === HeroVitalState.RECOVERING_IN_CAMP) {
      // 首次落马回本阵医帐包扎恢复态（45s 抢救进度）
      const healProgress: number = 1.0 - clampNum(safeNum(hero.recoveryTimer, 0) / 45.0, 0, 1);
      ctx.fillStyle = 'rgba(46, 125, 50, 0.35)';
      ctx.beginPath();
      ctx.arc(hx, hy - 8, 20, 0, TWO_PI);
      ctx.fill();
      ctx.fillStyle = '#69F0AE';
      ctx.fillRect(hx - 18, hy - 34, 36 * healProgress, 5);
      return;
    }

    const facing: number = safeNum(hero.facingRad, 0);
    const cosF: number = Math.cos(facing);
    const sinF: number = Math.sin(facing);
    const dirX: number = cosF >= 0 ? 1.0 : -1.0;

    // 帅旗统率地面光环
    ctx.fillStyle = isPlayer ? 'rgba(255, 213, 79, 0.16)' : 'rgba(239, 83, 80, 0.16)';
    ctx.beginPath();
    ctx.ellipse(hx, hy + 2, 18, 9, 0, 0, TWO_PI);
    ctx.fill();

    // 统帅随风猎猎大披风
    const capeWave: number = Math.sin(this.animClockSec * 7.5) * 4.5;
    ctx.fillStyle = primaryCol;
    ctx.beginPath();
    ctx.moveTo(hx, hy - 25);
    ctx.lineTo(hx - dirX * (16 + capeWave), hy - 4);
    ctx.lineTo(hx - dirX * (9 - capeWave * 0.5), hy - 2);
    ctx.closePath();
    ctx.fill();

    // 1.25x 魁梧主帅骨骼 + 随身三武器剪影（合为 1 次 stroke）
    const hipY: number = hy - 13;
    const neckY: number = hy - 26;
    const headY: number = hy - 32;
    const stride: number = (hero.actionState === UnitActionState.MARCH_RUN ||
      hero.actionState === UnitActionState.CHARGE_SPRINT)
      ? Math.sin(safeNum(hero.animPhase, 0) * TWO_PI) * 6.5
      : 0;

    ctx.beginPath();
    ctx.moveTo(hx + 5, headY);
    ctx.arc(hx, headY, 5, 0, TWO_PI);
    ctx.moveTo(hx, neckY);
    ctx.lineTo(hx, hipY);
    ctx.moveTo(hx, hipY);
    ctx.lineTo(hx - 5 + stride, hy);
    ctx.moveTo(hx, hipY);
    ctx.lineTo(hx + 5 - stride, hy);

    const handX: number = hx + cosF * 11;
    const handY: number = neckY + sinF * 11 + 3;
    ctx.moveTo(hx, neckY);
    ctx.lineTo(handX, handY);
    ctx.moveTo(hx, neckY);
    ctx.lineTo(hx + dirX * 7, neckY + 5);

    if (hero.activeWeapon === HeroWeaponType.COMMAND_SABER) {
      ctx.moveTo(handX, handY);
      ctx.lineTo(handX + cosF * 20, handY + sinF * 20);
    } else if (hero.activeWeapon === HeroWeaponType.BREAKER_SPEAR) {
      ctx.moveTo(handX - cosF * 8, handY - sinF * 8);
      ctx.lineTo(handX + cosF * 38, handY + sinF * 38);
    } else {
      const perpX: number = -sinF;
      const perpY: number = cosF;
      ctx.moveTo(handX + perpX * 11, handY + perpY * 11);
      ctx.quadraticCurveTo(handX + cosF * 8, handY + sinF * 8, handX - perpX * 11, handY - perpY * 11);
    }

    if (hero.isBlocking || hero.ironBulwarkTimer > 0) {
      ctx.moveTo(hx + Math.cos(facing - 0.9) * 18, neckY + Math.sin(facing - 0.9) * 18);
      ctx.arc(hx, neckY + 4, 18, facing - 0.9, facing + 0.9);
    }
    ctx.strokeStyle = accentCol;
    ctx.lineWidth = 3.0;
    ctx.stroke();

    // 主帅三叉金冠与血条铭牌
    ctx.fillStyle = '#FFD54F';
    ctx.beginPath();
    ctx.moveTo(hx - 5, headY - 4);
    ctx.lineTo(hx - 6, headY - 11);
    ctx.lineTo(hx - 2, headY - 7);
    ctx.lineTo(hx, headY - 13);
    ctx.lineTo(hx + 2, headY - 7);
    ctx.lineTo(hx + 6, headY - 11);
    ctx.lineTo(hx + 5, headY - 4);
    ctx.closePath();
    ctx.fill();

    const hpRatio: number = clampNum(hero.hp / Math.max(1, hero.maxHp), 0, 1);
    ctx.fillStyle = 'rgba(0, 0, 0, 0.72)';
    ctx.fillRect(hx - 20, headY - 22, 40, 5);
    ctx.fillStyle = isPlayer ? '#FFD54F' : '#FF5252';
    ctx.fillRect(hx - 20, headY - 22, 40 * hpRatio, 5);
  }

  /**
   * 6. 合批绘制漫天抛物线箭矢（切线方向 + 尾羽）、连弩长矛、投石巨石与受击刀弧火花特效
   */
  private renderProjectilesAndEffectsLayer(
    ctx: ICanvas2DContext,
    world: BattleWorldReadonlyView,
    isFarLod: boolean
  ): number {
    const projectiles: readonly ProjectileRuntimeEntity[] = world.projectiles;
    const hitEffects: readonly CombatHitEffect[] = world.hitEffects;
    const soldiers: readonly SoldierRuntimeEntity[] = world.soldiers;
    let visibleProjCount: number = 0;
    let hasShafts: boolean = false;
    let hasBoulders: boolean = false;
    let hasFireBombs: boolean = false;

    // 6.1 抛射物地面投影椭圆合批（1 次 fill）
    ctx.beginPath();
    for (let i: number = 0; i < projectiles.length; i++) {
      const p: ProjectileRuntimeEntity = projectiles[i];
      if (!p.active || !this.isPointVisible(p.x, p.y)) {
        continue;
      }
      visibleProjCount++;
      const r: number = p.kind === ProjectileKind.TREBUCHET_BOULDER ? 8.0 : 3.5;
      ctx.moveTo(p.x + r, p.y + 2);
      ctx.ellipse(p.x, p.y + 2, r, r * 0.45, 0, 0, TWO_PI);
      if (p.kind === ProjectileKind.TREBUCHET_BOULDER) {
        hasBoulders = true;
      } else if (p.kind === ProjectileKind.FIRE_BOMB) {
        hasFireBombs = true;
      } else {
        hasShafts = true;
      }
    }
    if (visibleProjCount > 0) {
      ctx.fillStyle = 'rgba(0, 0, 0, 0.28)';
      ctx.fill();
    }

    // 6.2 箭矢 / 弩矢 / 连弩重矛抛物线切线角箭身与尾羽合批（1 次箭杆 stroke + 1 次白翎尾羽 stroke）
    if (hasShafts) {
      ctx.beginPath();
      for (let i: number = 0; i < projectiles.length; i++) {
        const p: ProjectileRuntimeEntity = projectiles[i];
        if (
          !p.active ||
          p.kind === ProjectileKind.TREBUCHET_BOULDER ||
          p.kind === ProjectileKind.FIRE_BOMB ||
          !this.isPointVisible(p.x, p.y)
        ) {
          continue;
        }
        const t: number = clampNum(safeNum(p.flightProgress, 0.5), 0, 1);
        const arcH: number = safeNum(p.arcHeight, 0);
        const liftY: number = -4.0 * arcH * t * (1.0 - t);
        const dur: number = Math.max(0.05, safeNum(p.flightDuration, 1.0));
        const slopeX: number = safeNum(p.vx, 1) * dur;
        const slopeY: number = safeNum(p.vy, 0) * dur - 4.0 * arcH * (1.0 - 2.0 * t);
        const ang: number = Math.atan2(slopeY, slopeX);
        const cosA: number = Math.cos(ang);
        const sinA: number = Math.sin(ang);
        const len: number = p.kind === ProjectileKind.BALLISTA_SPEAR ? 22 : 13;
        const drawX: number = p.x;
        const drawY: number = p.y + liftY;

        ctx.moveTo(drawX - cosA * len * 0.6, drawY - sinA * len * 0.6);
        ctx.lineTo(drawX + cosA * len * 0.4, drawY + sinA * len * 0.4);
      }
      ctx.strokeStyle = '#D7CCC8';
      ctx.lineWidth = 1.7;
      ctx.stroke();

      // 箭矢尾羽 V 字翎毛与箭头合批
      ctx.beginPath();
      for (let i: number = 0; i < projectiles.length; i++) {
        const p: ProjectileRuntimeEntity = projectiles[i];
        if (
          !p.active ||
          p.kind === ProjectileKind.TREBUCHET_BOULDER ||
          p.kind === ProjectileKind.FIRE_BOMB ||
          !this.isPointVisible(p.x, p.y)
        ) {
          continue;
        }
        const t: number = clampNum(safeNum(p.flightProgress, 0.5), 0, 1);
        const arcH: number = safeNum(p.arcHeight, 0);
        const liftY: number = -4.0 * arcH * t * (1.0 - t);
        const dur: number = Math.max(0.05, safeNum(p.flightDuration, 1.0));
        const ang: number = Math.atan2(
          safeNum(p.vy, 0) * dur - 4.0 * arcH * (1.0 - 2.0 * t),
          safeNum(p.vx, 1) * dur
        );
        const cosA: number = Math.cos(ang);
        const sinA: number = Math.sin(ang);
        const perpX: number = -sinA;
        const perpY: number = cosA;
        const len: number = p.kind === ProjectileKind.BALLISTA_SPEAR ? 22 : 13;
        const tailX: number = p.x - cosA * len * 0.6;
        const tailY: number = p.y + liftY - sinA * len * 0.6;

        ctx.moveTo(tailX - cosA * 3 + perpX * 2.5, tailY - sinA * 3 + perpY * 2.5);
        ctx.lineTo(tailX + cosA * 2, tailY + sinA * 2);
        ctx.lineTo(tailX - cosA * 3 - perpX * 2.5, tailY - sinA * 3 - perpY * 2.5);
      }
      ctx.strokeStyle = '#FFFFFF';
      ctx.lineWidth = 1.3;
      ctx.stroke();
    }

    // 6.3 投石车巨石与震天火雷实体合批（纯 fill）
    if (hasBoulders) {
      ctx.beginPath();
      for (let i: number = 0; i < projectiles.length; i++) {
        const p: ProjectileRuntimeEntity = projectiles[i];
        if (!p.active || p.kind !== ProjectileKind.TREBUCHET_BOULDER || !this.isPointVisible(p.x, p.y)) {
          continue;
        }
        const t: number = clampNum(safeNum(p.flightProgress, 0.5), 0, 1);
        const drawY: number = p.y - 4.0 * safeNum(p.arcHeight, 0) * t * (1.0 - t);
        ctx.moveTo(p.x + 8.5, drawY);
        ctx.arc(p.x, drawY, 8.5, 0, TWO_PI);
      }
      ctx.fillStyle = '#90A4AE';
      ctx.fill();
    }

    if (hasFireBombs) {
      ctx.beginPath();
      for (let i: number = 0; i < projectiles.length; i++) {
        const p: ProjectileRuntimeEntity = projectiles[i];
        if (!p.active || p.kind !== ProjectileKind.FIRE_BOMB || !this.isPointVisible(p.x, p.y)) {
          continue;
        }
        const t: number = clampNum(safeNum(p.flightProgress, 0.5), 0, 1);
        const drawY: number = p.y - 4.0 * safeNum(p.arcHeight, 0) * t * (1.0 - t);
        ctx.moveTo(p.x + 5.5, drawY);
        ctx.arc(p.x, drawY, 5.5, 0, TWO_PI);
      }
      ctx.fillStyle = '#FF6D00';
      ctx.fill();
    }

    // 6.4 刀光残影、火柴人挥砍刀弧/冲锋疾风与举盾格挡火星/三军战吼波纹同色合批（最多 2 次 stroke）
    let hasSlashArcs: boolean = false;
    let hasSparks: boolean = false;
    let hasBloodSplash: boolean = false;

    ctx.beginPath();
    for (let i: number = 0; i < hitEffects.length; i++) {
      const fx: CombatHitEffect = hitEffects[i];
      if (!fx.active || fx.ttl <= 0 || !this.isPointVisible(fx.x, fx.y)) {
        continue;
      }
      if (fx.kind === 'blood_splash') {
        hasBloodSplash = true;
        continue;
      }
      if (fx.kind !== 'slash_arc') {
        continue;
      }
      const a: number = safeNum(fx.angleRad, 0);
      ctx.moveTo(fx.x + Math.cos(a - 0.75) * 16, fx.y + Math.sin(a - 0.75) * 16);
      ctx.arc(fx.x, fx.y, 16, a - 0.75, a + 0.75);
      hasSlashArcs = true;
    }

    // 合批近景火柴人 MELEE_STRIKE 动态挥砍刀弧与 CHARGE_SPRINT 冲锋破风线（0 额外 stroke）
    if (!isFarLod) {
      for (let k: number = 0; k < this.lastVisibleCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        if (s.actionState === UnitActionState.MELEE_STRIKE) {
          const facing: number = safeNum(s.facingRad, 0);
          const arcR: number = 14.0 * this.pScale[k];
          const cx: number = this.pNeckX[k];
          const cy: number = this.pNeckY[k] + 2.0;
          ctx.moveTo(cx + Math.cos(facing - 0.65) * arcR, cy + Math.sin(facing - 0.65) * arcR);
          ctx.arc(cx, cy, arcR, facing - 0.65, facing + 0.65);
          hasSlashArcs = true;
        } else if (s.actionState === UnitActionState.CHARGE_SPRINT) {
          const dir: number = this.pDirX[k];
          ctx.moveTo(s.x - dir * 10, this.pHipY[k] - 2);
          ctx.lineTo(s.x - dir * 21, this.pHipY[k] - 2);
          hasSlashArcs = true;
        }
      }
    }

    if (hasSlashArcs) {
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.82)';
      ctx.lineWidth = 2.2;
      ctx.stroke();
    }

    if (hasBloodSplash) {
      ctx.beginPath();
      for (let i: number = 0; i < hitEffects.length; i++) {
        const fx: CombatHitEffect = hitEffects[i];
        if (!fx.active || fx.ttl <= 0 || fx.kind !== 'blood_splash' || !this.isPointVisible(fx.x, fx.y)) {
          continue;
        }
        ctx.moveTo(fx.x + 4.5, fx.y);
        ctx.arc(fx.x, fx.y, 4.5, 0, TWO_PI);
      }
      ctx.fillStyle = 'rgba(211, 47, 47, 0.72)';
      ctx.fill();
    }

    ctx.beginPath();
    for (let i: number = 0; i < hitEffects.length; i++) {
      const fx: CombatHitEffect = hitEffects[i];
      if (!fx.active || fx.ttl <= 0 || !this.isPointVisible(fx.x, fx.y)) {
        continue;
      }
      if (fx.kind === 'shield_spark' || fx.kind === 'morale_burst' || fx.kind === 'boulder_crater') {
        const progress: number = 1.0 - clampNum(fx.ttl / Math.max(0.05, fx.maxTtl), 0, 1);
        const burstR: number = (fx.kind === 'boulder_crater' ? 26 : 12) * (0.4 + progress);
        for (let ray: number = 0; ray < 4; ray++) {
          const ra: number = safeNum(fx.angleRad, 0) + ray * HALF_PI;
          ctx.moveTo(fx.x + Math.cos(ra) * (burstR * 0.35), fx.y + Math.sin(ra) * (burstR * 0.35));
          ctx.lineTo(fx.x + Math.cos(ra) * burstR, fx.y + Math.sin(ra) * burstR);
        }
        hasSparks = true;
      }
    }

    // 合批 SHIELD_BLOCK 举盾格挡迸溅火星与主帅【三军战吼】金色波纹环（0 额外 stroke）
    if (!isFarLod) {
      for (let k: number = 0; k < this.lastVisibleCount; k++) {
        const s: SoldierRuntimeEntity = soldiers[this.visPoolIndices[k]];
        if (s.actionState === UnitActionState.SHIELD_BLOCK) {
          const spX: number = this.pHaLX[k] + this.pDirX[k] * 4.5;
          const spY: number = this.pHaLY[k];
          ctx.moveTo(spX - 3.5, spY - 3.5);
          ctx.lineTo(spX + 3.5, spY + 3.5);
          ctx.moveTo(spX - 3.5, spY + 3.5);
          ctx.lineTo(spX + 3.5, spY - 3.5);
          hasSparks = true;
        }
      }
    }

    if (
      world.playerHero.vitalState !== HeroVitalState.FALLEN_MARTYRED &&
      world.playerHero.warCryBuffTimer > 0 &&
      this.isPointVisible(world.playerHero.x, world.playerHero.y)
    ) {
      const r: number = 42 + Math.sin(this.animClockSec * 8.0) * 6;
      ctx.moveTo(world.playerHero.x + r, world.playerHero.y);
      ctx.arc(world.playerHero.x, world.playerHero.y, r, 0, TWO_PI);
      hasSparks = true;
    }
    if (
      world.enemyHero.vitalState !== HeroVitalState.FALLEN_MARTYRED &&
      world.enemyHero.warCryBuffTimer > 0 &&
      this.isPointVisible(world.enemyHero.x, world.enemyHero.y)
    ) {
      const r: number = 42 + Math.sin(this.animClockSec * 8.0) * 6;
      ctx.moveTo(world.enemyHero.x + r, world.enemyHero.y);
      ctx.arc(world.enemyHero.x, world.enemyHero.y, r, 0, TWO_PI);
      hasSparks = true;
    }

    if (hasSparks) {
      ctx.strokeStyle = '#FFD54F';
      ctx.lineWidth = 2.0;
      ctx.stroke();
    }

    return visibleProjCount;
  }

  /**
   * 7. 战场三路立体走廊双向战争迷雾半透明遮罩（兼容左右任意出生阵营、浓雾/黑夜视野缩减与血月夜战无损）
   */
  private renderFogOfWarLayer(ctx: ICanvas2DContext, world: BattleWorldReadonlyView): void {
    let weatherVisionMult: number = 1.0;
    if (world.weather === WeatherType.HEAVY_FOG) {
      weatherVisionMult = 0.60;
    } else if (world.weather === WeatherType.NIGHT && world.playerFaction !== FactionId.XUEYUE) {
      weatherVisionMult = 0.60;
    }

    const bandH: number = this.worldH / 3.0;
    const squads: readonly SquadRuntimeState[] = world.squads;
    ctx.fillStyle = 'rgba(10, 14, 18, 0.36)';

    for (let band: number = 0; band < 3; band++) {
      const bandTop: number = band * bandH;
      const bandBottom: number = band === 2 ? this.worldH : (band + 1) * bandH;
      if (!this.isRectVisible(0, bandTop, this.worldW, bandBottom - bandTop)) {
        continue;
      }

      let minClearX: number = this.worldW;
      let maxClearX: number = 0;
      let hasObserver: boolean = false;

      if (world.playerHero.vitalState !== HeroVitalState.FALLEN_MARTYRED) {
        const hr: number = GameConstants.VISION_RADIUS_INFANTRY * weatherVisionMult;
        if (world.playerHero.y + hr >= bandTop && world.playerHero.y - hr <= bandBottom) {
          minClearX = Math.min(minClearX, world.playerHero.x - hr);
          maxClearX = Math.max(maxClearX, world.playerHero.x + hr);
          hasObserver = true;
        }
      }

      for (let i: number = 0; i < squads.length; i++) {
        const sq: SquadRuntimeState = squads[i];
        if (sq.side !== BattleSide.PLAYER || sq.aliveCount <= 0) {
          continue;
        }
        const baseR: number = sq.primaryUnitType === UnitTypeId.LIGHT_CAVALRY ||
          sq.primaryUnitType === UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER
          ? GameConstants.VISION_RADIUS_CAVALRY
          : GameConstants.VISION_RADIUS_INFANTRY;
        const r: number = baseR * weatherVisionMult;
        if (sq.centerY + r >= bandTop && sq.centerY - r <= bandBottom) {
          if (sq.centerX - r < minClearX) {
            minClearX = sq.centerX - r;
          }
          if (sq.centerX + r > maxClearX) {
            maxClearX = sq.centerX + r;
          }
          hasObserver = true;
        }
      }

      if (!hasObserver) {
        ctx.fillRect(0, bandTop, this.worldW, bandBottom - bandTop);
      } else {
        const leftFogW: number = clampNum(minClearX, 0, this.worldW);
        if (leftFogW > 1 && this.isRectVisible(0, bandTop, leftFogW, bandBottom - bandTop)) {
          ctx.fillRect(0, bandTop, leftFogW, bandBottom - bandTop);
        }
        const rightFogX: number = clampNum(maxClearX, 0, this.worldW);
        if (rightFogX < this.worldW - 1 && this.isRectVisible(rightFogX, bandTop, this.worldW - rightFogX, bandBottom - bandTop)) {
          ctx.fillRect(rightFogX, bandTop, this.worldW - rightFogX, bandBottom - bandTop);
        }
      }
    }
  }

  /**
   * 8a. 屏幕空间天气氛围、RTS 框选绿框与 M-Pencil 实时手绘笔迹预览
   */
  private renderScreenWeatherAndSelectionOverlay(
    ctx: ICanvas2DContext,
    weather: WeatherType,
    overlay?: BattleSelectionOverlay
  ): void {
    if (weather === WeatherType.NIGHT) {
      ctx.fillStyle = 'rgba(8, 14, 30, 0.34)';
      ctx.fillRect(0, 0, this.viewportW, this.viewportH);
    } else if (weather === WeatherType.HEAVY_FOG) {
      ctx.fillStyle = 'rgba(207, 216, 220, 0.22)';
      ctx.fillRect(0, 0, this.viewportW, this.viewportH);
    } else if (weather === WeatherType.RAIN_MUD) {
      ctx.beginPath();
      const shift: number = (this.animClockSec * 280) % 80;
      for (let rx: number = 20; rx < this.viewportW; rx += 95) {
        for (let ry: number = -40 + shift; ry < this.viewportH; ry += 90) {
          ctx.moveTo(rx, ry);
          ctx.lineTo(rx - 9, ry + 22);
        }
      }
      ctx.strokeStyle = 'rgba(144, 202, 249, 0.28)';
      ctx.lineWidth = 1.2;
      ctx.stroke();
    } else if (weather === WeatherType.BLIZZARD) {
      ctx.beginPath();
      const snowShift: number = (this.animClockSec * 120) % 90;
      for (let sx: number = 30; sx < this.viewportW; sx += 100) {
        for (let sy: number = -20 + snowShift; sy < this.viewportH; sy += 95) {
          ctx.moveTo(sx + 2.2, sy);
          ctx.arc(sx, sy, 2.2, 0, TWO_PI);
        }
      }
      ctx.fillStyle = 'rgba(224, 247, 250, 0.45)';
      ctx.fill();
    }

    if (overlay === undefined) {
      return;
    }

    // RTS 绿色框选矩形
    if (
      overlay.marqueeActive === true &&
      overlay.marqueeStartX !== undefined &&
      overlay.marqueeStartY !== undefined &&
      overlay.marqueeEndX !== undefined &&
      overlay.marqueeEndY !== undefined
    ) {
      const mx: number = Math.min(overlay.marqueeStartX, overlay.marqueeEndX);
      const my: number = Math.min(overlay.marqueeStartY, overlay.marqueeEndY);
      const mw: number = Math.abs(overlay.marqueeEndX - overlay.marqueeStartX);
      const mh: number = Math.abs(overlay.marqueeEndY - overlay.marqueeStartY);
      ctx.fillStyle = 'rgba(105, 240, 174, 0.14)';
      ctx.fillRect(mx, my, mw, mh);
      ctx.strokeStyle = '#69F0AE';
      ctx.lineWidth = 1.8;
      ctx.strokeRect(mx, my, mw, mh);
    }

    // M-Pencil 实时手绘迂回曲线预览
    if (
      overlay.stylusTrailScreenX !== undefined &&
      overlay.stylusTrailScreenY !== undefined
    ) {
      const len: number = Math.min(overlay.stylusTrailScreenX.length, overlay.stylusTrailScreenY.length);
      if (len >= 2) {
        ctx.beginPath();
        ctx.moveTo(overlay.stylusTrailScreenX[0], overlay.stylusTrailScreenY[0]);
        for (let i: number = 1; i < len; i++) {
          ctx.lineTo(overlay.stylusTrailScreenX[i], overlay.stylusTrailScreenY[i]);
        }
        ctx.setLineDash(this.dashWaypoint);
        ctx.strokeStyle = '#FFD54F';
        ctx.lineWidth = 2.6;
        ctx.stroke();
        ctx.setLineDash(this.dashEmpty);
      }
    }
  }

  /**
   * 8b. 右上角可点击跳转的战场战术缩略小地图（含地形缩略、敌我军团色块、主帅位置与当前相机视口白框）
   */
  private renderMinimapOverlay(
    ctx: ICanvas2DContext,
    world: BattleWorldReadonlyView,
    fogEnabled: boolean
  ): void {
    const mm: MinimapLayout = this.minimapRect;
    const scaleX: number = mm.width / Math.max(1, this.worldW);
    const scaleY: number = mm.height / Math.max(1, this.worldH);

    ctx.fillStyle = 'rgba(20, 18, 16, 0.88)';
    ctx.fillRect(mm.x, mm.y, mm.width, mm.height);

    // 缩略地形色带
    const zones: readonly TerrainZoneRect[] = world.terrainZones;
    for (let i: number = 0; i < zones.length; i++) {
      const z: TerrainZoneRect = zones[i];
      ctx.fillStyle = this.getTerrainFillColor(z.terrain);
      ctx.fillRect(mm.x + z.x * scaleX, mm.y + z.y * scaleY, z.width * scaleX, z.height * scaleY);
    }

    // 友军与可见敌军分队态势点
    const playerCol: string = FACTION_PRIMARY_COLORS[getFactionBucketIndex(world.playerFaction)];
    const enemyCol: string = FACTION_PRIMARY_COLORS[getFactionBucketIndex(world.enemyFaction)];
    const squads: readonly SquadRuntimeState[] = world.squads;
    for (let i: number = 0; i < squads.length; i++) {
      const sq: SquadRuntimeState = squads[i];
      if (sq.aliveCount <= 0) {
        continue;
      }
      if (fogEnabled && sq.side === BattleSide.ENEMY && !this.isEnemySquadRevealedOnMinimap(world, sq)) {
        continue;
      }
      const px: number = mm.x + clampNum(sq.centerX, 0, this.worldW) * scaleX;
      const py: number = mm.y + clampNum(sq.centerY, 0, this.worldH) * scaleY;
      ctx.fillStyle = sq.side === BattleSide.PLAYER ? playerCol : enemyCol;
      ctx.fillRect(px - 2.5, py - 2.5, 5, 5);
    }

    // 玩家主帅金色星标
    if (world.playerHero.vitalState !== HeroVitalState.FALLEN_MARTYRED) {
      const hx: number = mm.x + clampNum(world.playerHero.x, 0, this.worldW) * scaleX;
      const hy: number = mm.y + clampNum(world.playerHero.y, 0, this.worldH) * scaleY;
      ctx.fillStyle = '#FFD54F';
      ctx.fillRect(hx - 3, hy - 3, 6, 6);
    }

    // 小地图外框 + 当前摄像机视口白色定位框
    ctx.strokeStyle = '#8D6E63';
    ctx.lineWidth = 1.5;
    ctx.strokeRect(mm.x, mm.y, mm.width, mm.height);

    const viewWorldW: number = this.viewportW / this.zoom;
    const viewWorldH: number = this.viewportH / this.zoom;
    const vx: number = clampNum((this.camX - viewWorldW * 0.5) * scaleX, 0, mm.width);
    const vy: number = clampNum((this.camY - viewWorldH * 0.5) * scaleY, 0, mm.height);
    const vw: number = clampNum(viewWorldW * scaleX, 6, mm.width - vx);
    const vh: number = clampNum(viewWorldH * scaleY, 6, mm.height - vy);

    ctx.strokeStyle = '#FFF8E1';
    ctx.lineWidth = 1.4;
    ctx.strokeRect(mm.x + vx, mm.y + vy, vw, vh);
  }
}
