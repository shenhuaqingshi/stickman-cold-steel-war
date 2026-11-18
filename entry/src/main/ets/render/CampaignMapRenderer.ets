/**
 * 鸿蒙平板 3600×2400 战略大地图渲染器（CampaignMapRenderer.ets）
 * - 渲染 8 大地理板块底色地貌（永冻霜原、苍狼草原、铁脊高原、铁鹰山脉、中原赤炎平原、金沙绿洲、迷雾幽林、血月盆地）
 * - 渲染全图对称双向道路网：按 CampaignNodeRuntime.supplyGrade 动态着色（满补给翠绿实线、远征琥珀虚线、断粮猩红闪烁告警线）
 * - 选中城关时自动高亮其通往最近补给仓城（isSupplyDepot）的 BFS 粮道干线与运粮车队动画
 * - 渲染 40 座城关（区分王都五角城廓、雄关城楼、粮仓谷仓、矿山商埠、渡口前哨），含势力旗帜、城名、驻军徽章、被围困双剑交火特效与伏兵暗记
 * - 支持双指捏合缩放（0.45~1.80）、拖拽漫游、点选拾取 pickNodeAtScreenPos 与右上角可点击秒跳的战略全局小地图
 * - 零 @kit.ArkUI 依赖，零 any / unknown
 */
import { GameConstants } from '../common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS } from '../config/FactionConfig';
import {
  BilateralDiplomacyState,
  CampaignNodeRuntime,
  CampaignSaveState,
  DiplomaticStatus,
  FactionCampaignRuntime,
  FactionId,
  SupplyEvaluationResult,
  SupplyLineGrade
} from '../core/CoreContracts';
import { CampaignNodeConfig, CampaignNodeType } from '../model/GameTypes';
import {
  getFactionBucketIndex,
  ICanvas2DContext,
  MinimapLayout,
  Point2D,
  ViewportRect
} from './StickmanBattleRenderer';

export { ICanvas2DContext, MinimapLayout, Point2D };

/** 预计算的战略大地图无向道路边 */
export interface CampaignRoadEdge {
  readonly indexA: number;
  readonly indexB: number;
  readonly nodeIdA: string;
  readonly nodeIdB: string;
  readonly x1: number;
  readonly y1: number;
  readonly x2: number;
  readonly y2: number;
}

/** 地理大区板块元数据 */
interface RegionBiomeZone {
  readonly regionIndex: number;
  readonly title: string;
  readonly centerX: number;
  readonly centerY: number;
  readonly radiusX: number;
  readonly radiusY: number;
  readonly fillColor: string;
  readonly detailColor: string;
}

/** 战略大地图渲染可选交互参数 */
export interface CampaignMapRenderOptions {
  readonly selectedNodeId?: string | null;
  readonly hoveredNodeId?: string | null;
  readonly selectedSupplyEval?: SupplyEvaluationResult | null;
}

/** 战略大地图单帧渲染统计 */
export interface CampaignRenderStats {
  totalNodes: number;
  visibleNodes: number;
  totalRoads: number;
  highlightedSupplyEdges: number;
}

const PI: number = Math.PI;
const TWO_PI: number = Math.PI * 2;

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
  '#FFD54F',
  '#E1F5FE',
  '#B0BEC5',
  '#FFF8E1',
  '#E0F7FA',
  '#C8E6C9',
  '#E1BEE7',
  '#F8BBD0'
];

const REGION_BIOMES: readonly RegionBiomeZone[] = [
  {
    regionIndex: 1,
    title: '极北永冻霜原',
    centerX: 860,
    centerY: 360,
    radiusX: 620,
    radiusY: 330,
    fillColor: '#223340',
    detailColor: 'rgba(179, 229, 252, 0.22)'
  },
  {
    regionIndex: 2,
    title: '瀚海苍狼草原',
    centerX: 1960,
    centerY: 470,
    radiusX: 640,
    radiusY: 340,
    fillColor: '#253526',
    detailColor: 'rgba(165, 214, 167, 0.20)'
  },
  {
    regionIndex: 3,
    title: '铁脊古战场高原',
    centerX: 2980,
    centerY: 720,
    radiusX: 540,
    radiusY: 520,
    fillColor: '#312938',
    detailColor: 'rgba(206, 147, 216, 0.18)'
  },
  {
    regionIndex: 4,
    title: '西境铁鹰山脉',
    centerX: 720,
    centerY: 1140,
    radiusX: 520,
    radiusY: 430,
    fillColor: '#262D3B',
    detailColor: 'rgba(176, 190, 197, 0.24)'
  },
  {
    regionIndex: 5,
    title: '中原赤炎平原',
    centerX: 1860,
    centerY: 1150,
    radiusX: 620,
    radiusY: 410,
    fillColor: '#3B3023',
    detailColor: 'rgba(255, 213, 79, 0.18)'
  },
  {
    regionIndex: 6,
    title: '金沙绿洲走廊',
    centerX: 890,
    centerY: 1900,
    radiusX: 580,
    radiusY: 400,
    fillColor: '#4B3A21',
    detailColor: 'rgba(255, 224, 130, 0.22)'
  },
  {
    regionIndex: 7,
    title: '南疆迷雾幽林',
    centerX: 1990,
    centerY: 1950,
    radiusX: 560,
    radiusY: 380,
    fillColor: '#1A3122',
    detailColor: 'rgba(129, 199, 132, 0.22)'
  },
  {
    regionIndex: 8,
    title: '幽暗血月盆地',
    centerX: 2940,
    centerY: 1690,
    radiusX: 560,
    radiusY: 440,
    fillColor: '#331D28',
    detailColor: 'rgba(244, 143, 177, 0.20)'
  }
];

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

function supplySeverityRank(grade: SupplyLineGrade): number {
  switch (grade) {
    case SupplyLineGrade.FULL_SUPPLY:
      return 0;
    case SupplyLineGrade.EXTENDED_MARCH:
      return 1;
    case SupplyLineGrade.OVEREXTENDED:
      return 2;
    case SupplyLineGrade.SEVERED:
      return 3;
    default:
      return 0;
  }
}

/**
 * 鸿蒙平板 40 城关战略大地图 Canvas 2D 渲染器
 */
export class CampaignMapRenderer {
  private viewportW: number = 1280;
  private viewportH: number = 800;
  private readonly worldW: number = GameConstants.CAMPAIGN_MAP_WIDTH;
  private readonly worldH: number = GameConstants.CAMPAIGN_MAP_HEIGHT;

  private camX: number = GameConstants.CAMPAIGN_MAP_WIDTH * 0.5;
  private camY: number = GameConstants.CAMPAIGN_MAP_HEIGHT * 0.5;
  private zoom: number = 0.65;
  private animClockSec: number = 0;
  private selectedNodeId: string | null = null;
  private stylusPickRadiusPx: number = GameConstants.STYLUS_PICK_RADIUS_PX;

  private readonly nodeIndexById: Map<string, number> = new Map<string, number>();
  private readonly roads: CampaignRoadEdge[] = [];
  private readonly runtimeByNodeIndex: (CampaignNodeRuntime | null)[] = [];
  private readonly bfsVisited: Int32Array = new Int32Array(CAMPAIGN_MAP_NODES.length);
  private readonly bfsParent: Int32Array = new Int32Array(CAMPAIGN_MAP_NODES.length);
  private readonly bfsQueue: Int32Array = new Int32Array(CAMPAIGN_MAP_NODES.length);
  private readonly internalBfsPath: string[] = [];

  private readonly dashEmpty: number[] = [];
  private readonly dashExtended: number[] = [12, 7];
  private readonly dashSevered: number[] = [8, 6];
  private readonly dashWarFront: number[] = [5, 8];

  private readonly scratchPoint: Point2D = { x: 0, y: 0 };
  private readonly minimapRect: MinimapLayout = { x: 0, y: 0, width: 210, height: 140 };
  private readonly culledViewport: ViewportRect = { x: 0, y: 0, width: 1280, height: 800 };
  private readonly renderStats: CampaignRenderStats = {
    totalNodes: CAMPAIGN_MAP_NODES.length,
    visibleNodes: 0,
    totalRoads: 0,
    highlightedSupplyEdges: 0
  };

  constructor(viewportW: number = 1280, viewportH: number = 800) {
    this.buildStaticTopologyCache();
    this.setViewportSize(viewportW, viewportH);
    this.clampCamera();
    this.recomputeMinimapLayout();
    if (FACTION_STATIC_CONFIGS.length === 0) {
      this.zoom = 0.65;
    }
  }

  /** 设置平板大地图视口像素尺寸 */
  public setViewportSize(viewportW: number, viewportH: number): void {
    this.viewportW = Math.max(120, safeNum(viewportW, 1280));
    this.viewportH = Math.max(120, safeNum(viewportH, 800));
    this.clampCamera();
    this.recomputeMinimapLayout();
  }

  /** 设置摄像机世界中心与缩放倍率（严格限制在 0.45 ~ 1.80） */
  public setCamera(worldX: number, worldY: number, zoom?: number): void {
    if (zoom !== undefined) {
      this.zoom = clampNum(zoom, GameConstants.CAMPAIGN_ZOOM_MIN, GameConstants.CAMPAIGN_ZOOM_MAX);
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

  public getRoadEdges(): readonly CampaignRoadEdge[] {
    return this.roads;
  }

  public getLastRenderStats(): CampaignRenderStats {
    return this.renderStats;
  }

  public setSelectedNodeId(nodeId: string | null): void {
    this.selectedNodeId = nodeId;
  }

  public getSelectedNodeId(): string | null {
    return this.selectedNodeId;
  }

  /** 同步设置面板 M-Pencil 手写笔有效拾取半径（px） */
  public setStylusPickRadiusPx(radiusPx: number): void {
    this.stylusPickRadiusPx = clampNum(radiusPx, 8, 64);
  }

  /** 推进粮道闪烁与双剑交火动画时钟 */
  public tickAnimation(dtSec: number): void {
    this.animClockSec += clampNum(dtSec, 0, 0.25);
  }

  /** 拖拽漫游平移视口 */
  public panByScreenDelta(dxScreen: number, dyScreen: number): void {
    const invZoom: number = 1.0 / this.zoom;
    this.camX -= safeNum(dxScreen, 0) * invZoom;
    this.camY -= safeNum(dyScreen, 0) * invZoom;
    this.clampCamera();
  }

  /** 双指捏合围绕屏幕锚点无级缩放（0.45 ~ 1.80） */
  public zoomAtScreenPoint(nextZoom: number, anchorScreenX: number, anchorScreenY: number): void {
    const sx: number = safeNum(anchorScreenX, this.viewportW * 0.5);
    const sy: number = safeNum(anchorScreenY, this.viewportH * 0.5);
    const beforeWX: number = (sx - this.viewportW * 0.5) / this.zoom + this.camX;
    const beforeWY: number = (sy - this.viewportH * 0.5) / this.zoom + this.camY;

    this.zoom = clampNum(nextZoom, GameConstants.CAMPAIGN_ZOOM_MIN, GameConstants.CAMPAIGN_ZOOM_MAX);
    this.camX = beforeWX - (sx - this.viewportW * 0.5) / this.zoom;
    this.camY = beforeWY - (sy - this.viewportH * 0.5) / this.zoom;
    this.clampCamera();
  }

  /** 屏幕像素坐标 -> 大地图逻辑坐标 (0~3600, 0~2400) */
  public screenToWorld(sx: number, sy: number, out?: Point2D): Point2D {
    const wx: number = (safeNum(sx, 0) - this.viewportW * 0.5) / this.zoom + this.camX;
    const wy: number = (safeNum(sy, 0) - this.viewportH * 0.5) / this.zoom + this.camY;
    if (out !== undefined) {
      out.x = wx;
      out.y = wy;
      return out;
    }
    const pt: Point2D = { x: wx, y: wy };
    return pt;
  }

  /** 大地图逻辑坐标 -> 屏幕像素坐标（与 screenToWorld 严格互逆） */
  public worldToScreen(wx: number, wy: number, out?: Point2D): Point2D {
    const sx: number = (safeNum(wx, 0) - this.camX) * this.zoom + this.viewportW * 0.5;
    const sy: number = (safeNum(wy, 0) - this.camY) * this.zoom + this.viewportH * 0.5;
    if (out !== undefined) {
      out.x = sx;
      out.y = sy;
      return out;
    }
    const pt: Point2D = { x: sx, y: sy };
    return pt;
  }

  /**
   * 点击拾取 40 座城关节点（兼容手指 44px 大热区与 M-Pencil 手写笔精准拾取）
   */
  public pickNodeAtScreenPos(sx: number, sy: number, isStylus: boolean = false): CampaignNodeConfig | null {
    const minRadiusPx: number = isStylus
      ? this.stylusPickRadiusPx
      : GameConstants.FINGER_PICK_RADIUS_PX;

    let bestNode: CampaignNodeConfig | null = null;
    let bestDistSq: number = Number.POSITIVE_INFINITY;

    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      const node: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
      this.worldToScreen(node.x, node.y, this.scratchPoint);
      const nodeHitR: number = Math.max(
        minRadiusPx,
        (node.nodeType === CampaignNodeType.CAPITAL_CITADEL ? 34 : 26) * this.zoom
      );
      const dx: number = this.scratchPoint.x - sx;
      const dy: number = this.scratchPoint.y - sy;
      const distSq: number = dx * dx + dy * dy;
      if (distSq <= nodeHitR * nodeHitR && distSq < bestDistSq) {
        bestDistSq = distSq;
        bestNode = node;
      }
    }
    return bestNode;
  }

  /** 获取右上角战略全局小地图屏幕矩形 */
  public getMinimapLayout(): MinimapLayout {
    return this.minimapRect;
  }

  /** 判定屏幕点是否落在右上角战略小地图内 */
  public isPointInMinimap(sx: number, sy: number): boolean {
    return (
      sx >= this.minimapRect.x &&
      sx <= this.minimapRect.x + this.minimapRect.width &&
      sy >= this.minimapRect.y &&
      sy <= this.minimapRect.y + this.minimapRect.height
    );
  }

  /** 战略小地图屏幕坐标 -> 大地图世界坐标（位于小地图外返回 null） */
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

  /** 大地图世界坐标 -> 战略小地图屏幕坐标（与 minimapScreenToWorld 严格互逆） */
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

  /** 点击右上角战略小地图秒跳摄像机视口 */
  public handleMinimapTap(sx: number, sy: number): boolean {
    const hit: Point2D | null = this.minimapScreenToWorld(sx, sy, this.scratchPoint);
    if (hit === null) {
      return false;
    }
    this.setCamera(hit.x, hit.y);
    return true;
  }

  /**
   * 计算指定城关通往最近本方/军事同盟仓城（isSupplyDepot = true）的 BFS 最短粮道节点路径
   * 返回从仓城到目标城关的有序 nodeId 数组；若粮道断绝则返回空数组
   */
  public computeBfsSupplyPath(state: CampaignSaveState | null, targetNodeId: string): string[] {
    const length: number = this.solveBfsSupplyPathIntoBuffer(state, targetNodeId);
    const result: string[] = [];
    for (let i: number = 0; i < length; i++) {
      result.push(this.internalBfsPath[i]);
    }
    return result;
  }

  private solveBfsSupplyPathIntoBuffer(state: CampaignSaveState | null, targetNodeId: string): number {
    this.internalBfsPath.length = 0;
    const targetIdx: number | undefined = this.nodeIndexById.get(targetNodeId);
    if (targetIdx === undefined) {
      return 0;
    }
    this.syncRuntimeLookup(state);

    const targetOwner: FactionId = this.getNodeOwner(targetIdx);
    if (CAMPAIGN_MAP_NODES[targetIdx].isSupplyDepot) {
      this.internalBfsPath.push(targetNodeId);
      return 1;
    }

    const total: number = CAMPAIGN_MAP_NODES.length;
    for (let i: number = 0; i < total; i++) {
      this.bfsVisited[i] = 0;
      this.bfsParent[i] = -1;
    }

    let head: number = 0;
    let tail: number = 0;
    this.bfsQueue[tail] = targetIdx;
    tail++;
    this.bfsVisited[targetIdx] = 1;
    let foundDepotIdx: number = -1;

    while (head < tail) {
      const cur: number = this.bfsQueue[head];
      head++;
      const cfg: CampaignNodeConfig = CAMPAIGN_MAP_NODES[cur];
      if (cur !== targetIdx && cfg.isSupplyDepot) {
        foundDepotIdx = cur;
        break;
      }

      for (let n: number = 0; n < cfg.neighbors.length; n++) {
        const nbIdx: number | undefined = this.nodeIndexById.get(cfg.neighbors[n]);
        if (nbIdx === undefined || this.bfsVisited[nbIdx] !== 0) {
          continue;
        }
        const nbOwner: FactionId = this.getNodeOwner(nbIdx);
        if (nbOwner === targetOwner || this.areFactionsAllied(state, targetOwner, nbOwner)) {
          this.bfsVisited[nbIdx] = 1;
          this.bfsParent[nbIdx] = cur;
          this.bfsQueue[tail] = nbIdx;
          tail++;
        }
      }
    }

    if (foundDepotIdx < 0) {
      return 0;
    }

    let step: number = foundDepotIdx;
    while (step >= 0) {
      this.internalBfsPath.push(CAMPAIGN_MAP_NODES[step].id);
      if (step === targetIdx) {
        break;
      }
      step = this.bfsParent[step];
    }
    return this.internalBfsPath.length;
  }

  /**
   * 渲染完整单帧 3600×2400 战略大地图画面
   */
  public render(
    ctx: ICanvas2DContext,
    state: CampaignSaveState | null = null,
    options?: CampaignMapRenderOptions
  ): CampaignRenderStats {
    this.syncRuntimeLookup(state);
    const activeSelectedId: string | null = options !== undefined && options.selectedNodeId !== undefined
      ? options.selectedNodeId
      : this.selectedNodeId;
    const hoveredId: string | null = options !== undefined && options.hoveredNodeId !== undefined
      ? options.hoveredNodeId
      : null;

    const halfW: number = (this.viewportW * 0.5) / this.zoom;
    const halfH: number = (this.viewportH * 0.5) / this.zoom;
    const cullPad: number = 140;
    this.culledViewport.x = this.camX - halfW - cullPad;
    this.culledViewport.y = this.camY - halfH - cullPad;
    this.culledViewport.width = (halfW + cullPad) * 2.0;
    this.culledViewport.height = (halfH + cullPad) * 2.0;

    ctx.clearRect(0, 0, this.viewportW, this.viewportH);
    ctx.save();
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.globalAlpha = 1.0;

    ctx.translate(this.viewportW * 0.5, this.viewportH * 0.5);
    ctx.scale(this.zoom, this.zoom);
    ctx.translate(-this.camX, -this.camY);

    // 1. 八大地理板块底色地貌、山脉水系与势力版图光晕
    this.renderEightRegionsBiomeLayer(ctx);

    // 2. 全图道路网（动态补给着色）与选中城关 BFS 粮道高亮干线
    this.renderStats.highlightedSupplyEdges = this.renderRoadsAndSupplyLinesLayer(
      ctx,
      state,
      activeSelectedId,
      options !== undefined ? options.selectedSupplyEval : undefined
    );

    // 3. 40 座城关图标、旗帜、城名、驻军兵力徽章、被围困双剑交火特效与伏兵暗记
    this.renderStats.visibleNodes = this.renderFortressNodesLayer(
      ctx,
      state,
      activeSelectedId,
      hoveredId
    );

    ctx.restore();

    // 4. 右上角战略全局缩略小地图（含版图染色、交战闪烁与视口秒跳框）
    this.renderGlobalMinimapOverlay(ctx, activeSelectedId);

    return this.renderStats;
  }

  // ==================== 内部拓扑与分层绘制逻辑 ====================

  private buildStaticTopologyCache(): void {
    this.nodeIndexById.clear();
    this.roads.length = 0;
    this.runtimeByNodeIndex.length = 0;

    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      this.nodeIndexById.set(CAMPAIGN_MAP_NODES[i].id, i);
      this.runtimeByNodeIndex.push(null);
    }

    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      const nodeA: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
      for (let k: number = 0; k < nodeA.neighbors.length; k++) {
        const nbId: string = nodeA.neighbors[k];
        const j: number | undefined = this.nodeIndexById.get(nbId);
        if (j !== undefined && i < j) {
          const nodeB: CampaignNodeConfig = CAMPAIGN_MAP_NODES[j];
          const edge: CampaignRoadEdge = {
            indexA: i,
            indexB: j,
            nodeIdA: nodeA.id,
            nodeIdB: nodeB.id,
            x1: nodeA.x,
            y1: nodeA.y,
            x2: nodeB.x,
            y2: nodeB.y
          };
          this.roads.push(edge);
        }
      }
    }
    this.renderStats.totalRoads = this.roads.length;
  }

  private syncRuntimeLookup(state: CampaignSaveState | null): void {
    for (let i: number = 0; i < this.runtimeByNodeIndex.length; i++) {
      this.runtimeByNodeIndex[i] = null;
    }
    if (state === null) {
      return;
    }
    for (let i: number = 0; i < state.nodes.length; i++) {
      const rt: CampaignNodeRuntime = state.nodes[i];
      const idx: number | undefined = this.nodeIndexById.get(rt.nodeId);
      if (idx !== undefined) {
        this.runtimeByNodeIndex[idx] = rt;
      }
    }
  }

  private getNodeOwner(nodeIdx: number): FactionId {
    const rt: CampaignNodeRuntime | null = this.runtimeByNodeIndex[nodeIdx];
    return rt !== null ? rt.owner : CAMPAIGN_MAP_NODES[nodeIdx].initialOwner;
  }

  private getNodeSupplyGrade(nodeIdx: number): SupplyLineGrade {
    const rt: CampaignNodeRuntime | null = this.runtimeByNodeIndex[nodeIdx];
    return rt !== null ? rt.supplyGrade : SupplyLineGrade.FULL_SUPPLY;
  }

  private areFactionsAllied(state: CampaignSaveState | null, a: FactionId, b: FactionId): boolean {
    if (a === b) {
      return true;
    }
    if (state === null) {
      return false;
    }
    for (let i: number = 0; i < state.diplomacy.length; i++) {
      const rel: BilateralDiplomacyState = state.diplomacy[i];
      if (
        (rel.factionA === a && rel.factionB === b) ||
        (rel.factionA === b && rel.factionB === a)
      ) {
        return rel.status === DiplomaticStatus.ALLIANCE;
      }
    }
    return false;
  }

  private areFactionsAtWar(state: CampaignSaveState | null, a: FactionId, b: FactionId): boolean {
    if (a === b || state === null) {
      return false;
    }
    for (let i: number = 0; i < state.diplomacy.length; i++) {
      const rel: BilateralDiplomacyState = state.diplomacy[i];
      if (
        (rel.factionA === a && rel.factionB === b) ||
        (rel.factionA === b && rel.factionB === a)
      ) {
        return rel.status === DiplomaticStatus.WAR;
      }
    }
    return false;
  }

  private clampCamera(): void {
    this.zoom = clampNum(this.zoom, GameConstants.CAMPAIGN_ZOOM_MIN, GameConstants.CAMPAIGN_ZOOM_MAX);
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
    const mapW: number = clampNum(Math.floor(this.viewportW * 0.19), 162, 240);
    const mapH: number = Math.max(96, Math.round(mapW * (this.worldH / this.worldW)));
    this.minimapRect.width = mapW;
    this.minimapRect.height = mapH;
    this.minimapRect.x = Math.max(margin, this.viewportW - mapW - margin);
    this.minimapRect.y = margin;
  }

  private isPointInView(x: number, y: number): boolean {
    return (
      x >= this.culledViewport.x &&
      x <= this.culledViewport.x + this.culledViewport.width &&
      y >= this.culledViewport.y &&
      y <= this.culledViewport.y + this.culledViewport.height
    );
  }

  private isSegmentInView(x1: number, y1: number, x2: number, y2: number): boolean {
    const minX: number = Math.min(x1, x2);
    const maxX: number = Math.max(x1, x2);
    const minY: number = Math.min(y1, y2);
    const maxY: number = Math.max(y1, y2);
    return !(
      maxX < this.culledViewport.x ||
      minX > this.culledViewport.x + this.culledViewport.width ||
      maxY < this.culledViewport.y ||
      minY > this.culledViewport.y + this.culledViewport.height
    );
  }

  /**
   * 1. 绘制 8 大地理板块底色地貌、山脊沙丘森林肌理、大陆水道与势力控制圈染色
   */
  private renderEightRegionsBiomeLayer(ctx: ICanvas2DContext): void {
    // 羊皮沙盘深色底板
    ctx.fillStyle = '#1B1714';
    ctx.fillRect(0, 0, this.worldW, this.worldH);

    // 八大板块椭圆地貌底色块
    for (let i: number = 0; i < REGION_BIOMES.length; i++) {
      const rb: RegionBiomeZone = REGION_BIOMES[i];
      ctx.fillStyle = rb.fillColor;
      ctx.beginPath();
      ctx.ellipse(rb.centerX, rb.centerY, rb.radiusX, rb.radiusY, 0, 0, TWO_PI);
      ctx.fill();
    }

    // 40 城关归属势力疆域柔光底色（每势力 1 次合批 fill）
    ctx.save();
    ctx.globalAlpha = 0.14;
    for (let f: number = 0; f < 8; f++) {
      let hasCity: boolean = false;
      ctx.beginPath();
      for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
        const ownerIdx: number = getFactionBucketIndex(this.getNodeOwner(i));
        if (ownerIdx !== f) {
          continue;
        }
        const n: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
        if (!this.isPointInView(n.x, n.y)) {
          continue;
        }
        const rad: number = n.nodeType === CampaignNodeType.CAPITAL_CITADEL ? 155 : 115;
        ctx.moveTo(n.x + rad, n.y);
        ctx.arc(n.x, n.y, rad, 0, TWO_PI);
        hasCity = true;
      }
      if (hasCity) {
        ctx.fillStyle = FACTION_PRIMARY_COLORS[f];
        ctx.fill();
      }
    }
    ctx.restore();

    // 大陆贯通水系（洛水 / 饮马河 / 蓝河 / 暗河）单次合批 stroke
    ctx.beginPath();
    ctx.moveTo(980, 1020);
    ctx.quadraticCurveTo(1320, 990, 1520, 980);
    ctx.quadraticCurveTo(1820, 820, 2060, 610);
    ctx.moveTo(2220, 1340);
    ctx.quadraticCurveTo(2540, 1520, 2860, 1680);
    ctx.strokeStyle = 'rgba(41, 182, 246, 0.30)';
    ctx.lineWidth = 14;
    ctx.stroke();

    // 山脊纹理（铁鹰山脉、永冻霜原冰峰、铁脊高原裂谷）+ 沙丘弧线合批（单次 stroke）
    ctx.beginPath();
    for (let m: number = 0; m < 7; m++) {
      const mx: number = 520 + m * 68;
      const my: number = 960 + ((m * 53) % 280);
      ctx.moveTo(mx - 24, my + 18);
      ctx.lineTo(mx, my - 22);
      ctx.lineTo(mx + 24, my + 18);
    }
    for (let m: number = 0; m < 6; m++) {
      const mx: number = 2780 + m * 72;
      const my: number = 420 + ((m * 89) % 420);
      ctx.moveTo(mx - 22, my + 16);
      ctx.lineTo(mx, my - 18);
      ctx.lineTo(mx + 22, my + 16);
    }
    for (let d: number = 0; d < 5; d++) {
      const dx: number = 620 + d * 125;
      const dy: number = 1820 + (d % 2) * 95;
      ctx.moveTo(dx - 40, dy);
      ctx.quadraticCurveTo(dx, dy - 16, dx + 40, dy);
    }
    ctx.strokeStyle = 'rgba(236, 239, 241, 0.18)';
    ctx.lineWidth = 2.2;
    ctx.stroke();

    // 地理板块名称篆刻水印
    ctx.font = 'bold 24px sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = 'rgba(245, 230, 200, 0.22)';
    for (let i: number = 0; i < REGION_BIOMES.length; i++) {
      const rb: RegionBiomeZone = REGION_BIOMES[i];
      if (this.isPointInView(rb.centerX, rb.centerY - 90)) {
        ctx.fillText(rb.title, rb.centerX, rb.centerY - 90);
      }
    }
  }

  /**
   * 2. 绘制全图道路网（满补给翠绿实线 / 远征琥珀虚线 / 断粮猩红闪烁告警线 / 敌对边境线）及选中节点 BFS 粮道高亮
   */
  private renderRoadsAndSupplyLinesLayer(
    ctx: ICanvas2DContext,
    state: CampaignSaveState | null,
    selectedNodeId: string | null,
    explicitSupplyEval?: SupplyEvaluationResult | null
  ): number {
    // 2.1 底层古驿道石基合批（1 次 stroke）
    let hasVisibleRoad: boolean = false;
    ctx.beginPath();
    for (let i: number = 0; i < this.roads.length; i++) {
      const r: CampaignRoadEdge = this.roads[i];
      if (!this.isSegmentInView(r.x1, r.y1, r.x2, r.y2)) {
        continue;
      }
      ctx.moveTo(r.x1, r.y1);
      ctx.lineTo(r.x2, r.y2);
      hasVisibleRoad = true;
    }
    if (!hasVisibleRoad) {
      return 0;
    }
    ctx.strokeStyle = 'rgba(46, 39, 34, 0.90)';
    ctx.lineWidth = 6.2;
    ctx.stroke();

    // 2.2 按补给状态分四批绘制动态粮道色线（每类最多 1 次 stroke！）
    let hasFullSupply: boolean = false;
    let hasExtended: boolean = false;
    let hasOverextended: boolean = false;
    let hasSevered: boolean = false;
    let hasFrontier: boolean = false;

    // 批次 A：满补给翠绿实线（FULL_SUPPLY, d <= 2）
    ctx.beginPath();
    for (let i: number = 0; i < this.roads.length; i++) {
      const r: CampaignRoadEdge = this.roads[i];
      if (!this.isSegmentInView(r.x1, r.y1, r.x2, r.y2)) {
        continue;
      }
      const ownerA: FactionId = this.getNodeOwner(r.indexA);
      const ownerB: FactionId = this.getNodeOwner(r.indexB);
      if (!this.areFactionsAllied(state, ownerA, ownerB)) {
        hasFrontier = true;
        continue;
      }
      const rank: number = Math.max(
        supplySeverityRank(this.getNodeSupplyGrade(r.indexA)),
        supplySeverityRank(this.getNodeSupplyGrade(r.indexB))
      );
      if (rank === 0) {
        ctx.moveTo(r.x1, r.y1);
        ctx.lineTo(r.x2, r.y2);
        hasFullSupply = true;
      } else if (rank === 1) {
        hasExtended = true;
      } else if (rank === 2) {
        hasOverextended = true;
      } else {
        hasSevered = true;
      }
    }
    if (hasFullSupply) {
      ctx.strokeStyle = '#2ECC71';
      ctx.lineWidth = 3.0;
      ctx.stroke();
    }

    // 批次 B1：远征琥珀虚线（EXTENDED_MARCH, d == 3）
    if (hasExtended) {
      ctx.beginPath();
      for (let i: number = 0; i < this.roads.length; i++) {
        const r: CampaignRoadEdge = this.roads[i];
        if (!this.isSegmentInView(r.x1, r.y1, r.x2, r.y2)) {
          continue;
        }
        const ownerA: FactionId = this.getNodeOwner(r.indexA);
        const ownerB: FactionId = this.getNodeOwner(r.indexB);
        if (!this.areFactionsAllied(state, ownerA, ownerB)) {
          continue;
        }
        const rank: number = Math.max(
          supplySeverityRank(this.getNodeSupplyGrade(r.indexA)),
          supplySeverityRank(this.getNodeSupplyGrade(r.indexB))
        );
        if (rank === 1) {
          ctx.moveTo(r.x1, r.y1);
          ctx.lineTo(r.x2, r.y2);
        }
      }
      ctx.setLineDash(this.dashExtended);
      ctx.strokeStyle = '#FFB300';
      ctx.lineWidth = 3.2;
      ctx.stroke();
      ctx.setLineDash(this.dashEmpty);
    }

    // 批次 B2：孤军悬远深橙虚线（OVEREXTENDED, d >= 4）
    if (hasOverextended) {
      ctx.beginPath();
      for (let i: number = 0; i < this.roads.length; i++) {
        const r: CampaignRoadEdge = this.roads[i];
        if (!this.isSegmentInView(r.x1, r.y1, r.x2, r.y2)) {
          continue;
        }
        const ownerA: FactionId = this.getNodeOwner(r.indexA);
        const ownerB: FactionId = this.getNodeOwner(r.indexB);
        if (!this.areFactionsAllied(state, ownerA, ownerB)) {
          continue;
        }
        const rank: number = Math.max(
          supplySeverityRank(this.getNodeSupplyGrade(r.indexA)),
          supplySeverityRank(this.getNodeSupplyGrade(r.indexB))
        );
        if (rank === 2) {
          ctx.moveTo(r.x1, r.y1);
          ctx.lineTo(r.x2, r.y2);
        }
      }
      ctx.setLineDash(this.dashSevered);
      ctx.strokeStyle = '#FF7043';
      ctx.lineWidth = 3.4;
      ctx.stroke();
      ctx.setLineDash(this.dashEmpty);
    }

    // 批次 C：断粮猩红闪烁告警线（SEVERED）
    if (hasSevered) {
      const pulseAlpha: number = 0.48 + 0.52 * Math.abs(Math.sin(this.animClockSec * 5.2));
      ctx.save();
      ctx.globalAlpha = pulseAlpha;
      ctx.beginPath();
      for (let i: number = 0; i < this.roads.length; i++) {
        const r: CampaignRoadEdge = this.roads[i];
        if (!this.isSegmentInView(r.x1, r.y1, r.x2, r.y2)) {
          continue;
        }
        const ownerA: FactionId = this.getNodeOwner(r.indexA);
        const ownerB: FactionId = this.getNodeOwner(r.indexB);
        if (!this.areFactionsAllied(state, ownerA, ownerB)) {
          continue;
        }
        const rank: number = Math.max(
          supplySeverityRank(this.getNodeSupplyGrade(r.indexA)),
          supplySeverityRank(this.getNodeSupplyGrade(r.indexB))
        );
        if (rank >= 3) {
          ctx.moveTo(r.x1, r.y1);
          ctx.lineTo(r.x2, r.y2);
        }
      }
      ctx.setLineDash(this.dashSevered);
      ctx.strokeStyle = '#FF1744';
      ctx.lineWidth = 3.8;
      ctx.stroke();
      ctx.setLineDash(this.dashEmpty);
      ctx.restore();
    }

    // 批次 D：异国边境驿道（区分交战国暗红前线虚线与和平中立边境驿线）
    if (hasFrontier) {
      let hasWarBorder: boolean = false;
      ctx.beginPath();
      for (let i: number = 0; i < this.roads.length; i++) {
        const r: CampaignRoadEdge = this.roads[i];
        if (!this.isSegmentInView(r.x1, r.y1, r.x2, r.y2)) {
          continue;
        }
        const ownerA: FactionId = this.getNodeOwner(r.indexA);
        const ownerB: FactionId = this.getNodeOwner(r.indexB);
        if (!this.areFactionsAllied(state, ownerA, ownerB)) {
          if (this.areFactionsAtWar(state, ownerA, ownerB)) {
            hasWarBorder = true;
          } else {
            ctx.moveTo(r.x1, r.y1);
            ctx.lineTo(r.x2, r.y2);
          }
        }
      }
      ctx.setLineDash(this.dashWarFront);
      ctx.strokeStyle = 'rgba(176, 160, 146, 0.54)';
      ctx.lineWidth = 2.1;
      ctx.stroke();

      if (hasWarBorder) {
        ctx.beginPath();
        for (let i: number = 0; i < this.roads.length; i++) {
          const r: CampaignRoadEdge = this.roads[i];
          if (!this.isSegmentInView(r.x1, r.y1, r.x2, r.y2)) {
            continue;
          }
          const ownerA: FactionId = this.getNodeOwner(r.indexA);
          const ownerB: FactionId = this.getNodeOwner(r.indexB);
          if (!this.areFactionsAllied(state, ownerA, ownerB) && this.areFactionsAtWar(state, ownerA, ownerB)) {
            ctx.moveTo(r.x1, r.y1);
            ctx.lineTo(r.x2, r.y2);
          }
        }
        ctx.strokeStyle = 'rgba(255, 82, 82, 0.72)';
        ctx.lineWidth = 2.6;
        ctx.stroke();
      }
      ctx.setLineDash(this.dashEmpty);
    }

    // 2.3 选中城关通往仓城（isSupplyDepot）的 BFS 粮道高亮路径与流动粮车光点
    if (selectedNodeId === null) {
      return 0;
    }

    let bfsPath: readonly string[];
    if (
      explicitSupplyEval !== undefined &&
      explicitSupplyEval !== null &&
      explicitSupplyEval.nodeId === selectedNodeId &&
      explicitSupplyEval.pathNodeIds.length > 0
    ) {
      bfsPath = explicitSupplyEval.pathNodeIds;
    } else {
      this.solveBfsSupplyPathIntoBuffer(state, selectedNodeId);
      bfsPath = this.internalBfsPath;
    }

    if (bfsPath.length < 2) {
      return 0;
    }

    let highlightedEdges: number = 0;
    ctx.beginPath();
    for (let i: number = 0; i < bfsPath.length - 1; i++) {
      const idxA: number | undefined = this.nodeIndexById.get(bfsPath[i]);
      const idxB: number | undefined = this.nodeIndexById.get(bfsPath[i + 1]);
      if (idxA === undefined || idxB === undefined) {
        continue;
      }
      const nA: CampaignNodeConfig = CAMPAIGN_MAP_NODES[idxA];
      const nB: CampaignNodeConfig = CAMPAIGN_MAP_NODES[idxB];
      ctx.moveTo(nA.x, nA.y);
      ctx.lineTo(nB.x, nB.y);
      highlightedEdges++;
    }

    if (highlightedEdges > 0) {
      // 外发光金绿粮道干线
      ctx.strokeStyle = 'rgba(105, 240, 174, 0.42)';
      ctx.lineWidth = 10.0;
      ctx.stroke();

      ctx.strokeStyle = '#FFD54F';
      ctx.lineWidth = 3.8;
      ctx.stroke();

      // 沿粮道由仓城向选中前线流动的运粮节点圆珠
      const flowT: number = (this.animClockSec * 0.85) % 1.0;
      ctx.beginPath();
      for (let i: number = 0; i < bfsPath.length - 1; i++) {
        const idxA: number | undefined = this.nodeIndexById.get(bfsPath[i]);
        const idxB: number | undefined = this.nodeIndexById.get(bfsPath[i + 1]);
        if (idxA === undefined || idxB === undefined) {
          continue;
        }
        const nA: CampaignNodeConfig = CAMPAIGN_MAP_NODES[idxA];
        const nB: CampaignNodeConfig = CAMPAIGN_MAP_NODES[idxB];
        const cx: number = nA.x + (nB.x - nA.x) * flowT;
        const cy: number = nA.y + (nB.y - nA.y) * flowT;
        ctx.moveTo(cx + 5, cy);
        ctx.arc(cx, cy, 5, 0, TWO_PI);
      }
      ctx.fillStyle = '#FFF8E1';
      ctx.fill();
    }

    return highlightedEdges;
  }

  /**
   * 3. 渲染 40 座城关建筑图标、势力主色旗帜、城名、驻军徽章、围困双剑交火特效与伏兵暗记
   */
  private renderFortressNodesLayer(
    ctx: ICanvas2DContext,
    state: CampaignSaveState | null,
    selectedNodeId: string | null,
    hoveredNodeId: string | null
  ): number {
    let visibleCount: number = 0;
    let hasBesiegedNodes: boolean = false;
    let hasCapitalBorders: boolean = false;

    // 3.1 合批绘制全部被围困城关的脉动猩红告警圈（单次 stroke）
    const siegeRadiusPulse: number = 33 + Math.sin(this.animClockSec * 6.0) * 3.0;
    ctx.beginPath();
    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      const node: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
      if (!this.isPointInView(node.x, node.y)) {
        continue;
      }
      const rt: CampaignNodeRuntime | null = this.runtimeByNodeIndex[i];
      const owner: FactionId = rt !== null ? rt.owner : node.initialOwner;
      const isolatedTurns: number = rt !== null ? rt.isolatedTurns : 0;
      const supplyGrade: SupplyLineGrade = rt !== null ? rt.supplyGrade : SupplyLineGrade.FULL_SUPPLY;
      const isBesieged: boolean = isolatedTurns > 0 || supplyGrade === SupplyLineGrade.SEVERED ||
        this.isFrontlineContested(state, i, owner);
      if (isBesieged) {
        ctx.moveTo(node.x + siegeRadiusPulse, node.y);
        ctx.arc(node.x, node.y, siegeRadiusPulse, 0, TWO_PI);
        hasBesiegedNodes = true;
      }
    }
    if (hasBesiegedNodes) {
      ctx.strokeStyle = 'rgba(255, 23, 68, 0.78)';
      ctx.lineWidth = 2.6;
      ctx.stroke();
    }

    // 3.2 逐节点绘制选中光环与五类差异化城关图标主体
    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      const node: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
      if (!this.isPointInView(node.x, node.y)) {
        continue;
      }
      visibleCount++;
      if (node.nodeType === CampaignNodeType.CAPITAL_CITADEL) {
        hasCapitalBorders = true;
      }

      const rt: CampaignNodeRuntime | null = this.runtimeByNodeIndex[i];
      const owner: FactionId = rt !== null ? rt.owner : node.initialOwner;
      const factionIdx: number = getFactionBucketIndex(owner);
      const primaryCol: string = FACTION_PRIMARY_COLORS[factionIdx];
      const accentCol: string = FACTION_ACCENT_COLORS[factionIdx];
      const garrison: number = rt !== null ? rt.garrisonStrength : node.defenseLevel * 60;
      const supplyGrade: SupplyLineGrade = rt !== null ? rt.supplyGrade : SupplyLineGrade.FULL_SUPPLY;
      const hasAmbush: boolean = rt !== null ? rt.hasAmbushTrap : false;

      const isSelected: boolean = selectedNodeId !== null && node.id === selectedNodeId;
      const isHovered: boolean = hoveredNodeId !== null && node.id === hoveredNodeId;

      if (isSelected || isHovered) {
        ctx.strokeStyle = isSelected ? '#FFD54F' : '#81D4FA';
        ctx.lineWidth = isSelected ? 3.5 : 2.2;
        ctx.beginPath();
        ctx.arc(node.x, node.y, node.nodeType === CampaignNodeType.CAPITAL_CITADEL ? 36 : 28, 0, TWO_PI);
        ctx.stroke();
      }

      this.drawCityTypeIcon(ctx, node, primaryCol);

      // 城头势力主色旗面
      const poleX: number = node.x + (node.nodeType === CampaignNodeType.CAPITAL_CITADEL ? 18 : 13);
      const poleTopY: number = node.y - 34;
      ctx.fillStyle = primaryCol;
      ctx.beginPath();
      ctx.moveTo(poleX, poleTopY);
      ctx.lineTo(poleX + 16, poleTopY + 5);
      ctx.lineTo(poleX, poleTopY + 11);
      ctx.closePath();
      ctx.fill();

      if (this.hasFieldArmyAtNode(state, node.id)) {
        ctx.fillStyle = '#FFD54F';
        ctx.beginPath();
        ctx.arc(node.x - 20, node.y - 18, 6.5, 0, TWO_PI);
        ctx.fill();
      }

      // 伏兵暗记（hasAmbushTrap 咽喉伏击菱形紫翠暗印）
      if (hasAmbush) {
        const ax: number = node.x + 24;
        const ay: number = node.y + 2;
        ctx.fillStyle = '#00E676';
        ctx.beginPath();
        ctx.moveTo(ax, ay - 8);
        ctx.lineTo(ax + 7, ay);
        ctx.lineTo(ax, ay + 8);
        ctx.lineTo(ax - 7, ay);
        ctx.closePath();
        ctx.fill();
      }

      // 城池铭牌与驻军兵力徽章
      ctx.fillStyle = 'rgba(18, 15, 13, 0.84)';
      ctx.fillRect(node.x - 46, node.y + 20, 92, 34);

      ctx.font = node.nodeType === CampaignNodeType.CAPITAL_CITADEL ? 'bold 14px sans-serif' : '13px sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillStyle = node.isSupplyDepot ? '#FFD54F' : '#FFF8E1';
      ctx.fillText(node.name, node.x, node.y + 30);

      ctx.font = '11px sans-serif';
      ctx.fillStyle = supplyGrade === SupplyLineGrade.SEVERED ? '#FF5252' : accentCol;
      ctx.fillText(`驻军 ${garrison}`, node.x, node.y + 45);
    }

    // 3.3 合批绘制全部王都五角棱堡金色外廓（单次 stroke）
    if (hasCapitalBorders) {
      const outerR: number = 25;
      ctx.beginPath();
      for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
        const node: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
        if (node.nodeType !== CampaignNodeType.CAPITAL_CITADEL || !this.isPointInView(node.x, node.y)) {
          continue;
        }
        for (let p: number = 0; p < 5; p++) {
          const ang: number = -PI * 0.5 + (p * TWO_PI) / 5.0;
          const px: number = node.x + Math.cos(ang) * outerR;
          const py: number = node.y + Math.sin(ang) * outerR;
          if (p === 0) {
            ctx.moveTo(px, py);
          } else {
            ctx.lineTo(px, py);
          }
        }
        ctx.closePath();
      }
      ctx.strokeStyle = '#FFD54F';
      ctx.lineWidth = 2.4;
      ctx.stroke();
    }

    // 3.4 合批绘制全部可见城关旗杆（单次 stroke，取代 40 次逐城 stroke！）
    if (visibleCount > 0) {
      ctx.beginPath();
      for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
        const node: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
        if (!this.isPointInView(node.x, node.y)) {
          continue;
        }
        const poleX: number = node.x + (node.nodeType === CampaignNodeType.CAPITAL_CITADEL ? 18 : 13);
        ctx.moveTo(poleX, node.y - 10);
        ctx.lineTo(poleX, node.y - 34);
      }
      ctx.strokeStyle = '#ECEFF1';
      ctx.lineWidth = 1.8;
      ctx.stroke();
    }

    // 3.5 合批绘制全部被围困城关头顶交叉双剑交火特效（单次 stroke）
    if (hasBesiegedNodes) {
      const clash: number = Math.sin(this.animClockSec * 9.0) * 2.0;
      ctx.beginPath();
      for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
        const node: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
        if (!this.isPointInView(node.x, node.y)) {
          continue;
        }
        const rt: CampaignNodeRuntime | null = this.runtimeByNodeIndex[i];
        const owner: FactionId = rt !== null ? rt.owner : node.initialOwner;
        const isolatedTurns: number = rt !== null ? rt.isolatedTurns : 0;
        const supplyGrade: SupplyLineGrade = rt !== null ? rt.supplyGrade : SupplyLineGrade.FULL_SUPPLY;
        const isBesieged: boolean = isolatedTurns > 0 || supplyGrade === SupplyLineGrade.SEVERED ||
          this.isFrontlineContested(state, i, owner);
        if (isBesieged) {
          const sx: number = node.x;
          const sy: number = node.y - 38;
          ctx.moveTo(sx - 9 - clash, sy + 7);
          ctx.lineTo(sx + 9 - clash, sy - 9);
          ctx.moveTo(sx + 9 + clash, sy + 7);
          ctx.lineTo(sx - 9 + clash, sy - 9);
        }
      }
      ctx.strokeStyle = '#FF5252';
      ctx.lineWidth = 2.4;
      ctx.stroke();
    }

    return visibleCount;
  }

  private drawCityTypeIcon(
    ctx: ICanvas2DContext,
    node: CampaignNodeConfig,
    primaryCol: string
  ): void {
    const x: number = node.x;
    const y: number = node.y;

    if (node.nodeType === CampaignNodeType.CAPITAL_CITADEL) {
      // 王都巨城：五角星棱堡城廓（外框由 3.3 合批描边）+ 中心紫禁王殿 + 皇冠徽记
      const outerR: number = 25;
      ctx.fillStyle = '#37312E';
      ctx.beginPath();
      for (let p: number = 0; p < 5; p++) {
        const ang: number = -PI * 0.5 + (p * TWO_PI) / 5.0;
        const px: number = x + Math.cos(ang) * outerR;
        const py: number = y + Math.sin(ang) * outerR;
        if (p === 0) {
          ctx.moveTo(px, py);
        } else {
          ctx.lineTo(px, py);
        }
      }
      ctx.closePath();
      ctx.fill();

      ctx.fillStyle = primaryCol;
      ctx.fillRect(x - 10, y - 9, 20, 16);
      ctx.fillStyle = '#FFD54F';
      ctx.beginPath();
      ctx.moveTo(x - 8, y - 9);
      ctx.lineTo(x - 5, y - 16);
      ctx.lineTo(x, y - 11);
      ctx.lineTo(x + 5, y - 16);
      ctx.lineTo(x + 8, y - 9);
      ctx.closePath();
      ctx.fill();
    } else if (node.nodeType === CampaignNodeType.FORTRESS_PASS) {
      // 险要雄关：双侧高耸垛口敌楼 + 拱券关门
      ctx.fillStyle = '#4E4641';
      ctx.fillRect(x - 18, y - 14, 11, 26);
      ctx.fillRect(x + 7, y - 14, 11, 26);
      ctx.fillRect(x - 8, y - 6, 16, 18);
      ctx.fillStyle = primaryCol;
      ctx.fillRect(x - 16, y - 18, 7, 4);
      ctx.fillRect(x + 9, y - 18, 7, 4);
      ctx.fillStyle = '#1E1916';
      ctx.beginPath();
      ctx.arc(x, y + 12, 5.5, PI, TWO_PI);
      ctx.fill();
    } else if (node.nodeType === CampaignNodeType.GRANARY_TOWN) {
      // 粮仓重镇：圆顶丰穗谷仓 + 金色仓廪顶盖
      ctx.fillStyle = '#5D4037';
      ctx.fillRect(x - 14, y - 4, 28, 16);
      ctx.fillStyle = '#FBC02D';
      ctx.beginPath();
      ctx.moveTo(x - 17, y - 4);
      ctx.quadraticCurveTo(x, y - 22, x + 17, y - 4);
      ctx.closePath();
      ctx.fill();
      ctx.strokeStyle = primaryCol;
      ctx.lineWidth = 2.2;
      ctx.strokeRect(x - 14, y - 4, 28, 16);
    } else if (node.nodeType === CampaignNodeType.RESOURCE_HUB) {
      // 矿山/林场/商埠：重檐工坊山墙 + 金锭徽章
      ctx.fillStyle = '#455A64';
      ctx.beginPath();
      ctx.moveTo(x - 17, y + 12);
      ctx.lineTo(x - 12, y - 8);
      ctx.lineTo(x, y - 16);
      ctx.lineTo(x + 12, y - 8);
      ctx.lineTo(x + 17, y + 12);
      ctx.closePath();
      ctx.fill();
      ctx.fillStyle = '#FFB300';
      ctx.fillRect(x - 6, y - 2, 12, 8);
    } else {
      // 渡口/绿洲前哨：石拱桥墩 + 哨塔尖顶
      ctx.fillStyle = '#546E7A';
      ctx.fillRect(x - 16, y + 2, 32, 9);
      ctx.fillRect(x - 6, y - 13, 12, 16);
      ctx.fillStyle = primaryCol;
      ctx.beginPath();
      ctx.moveTo(x, y - 21);
      ctx.lineTo(x - 9, y - 13);
      ctx.lineTo(x + 9, y - 13);
      ctx.closePath();
      ctx.fill();
    }
  }

  private isFrontlineContested(state: CampaignSaveState | null, nodeIdx: number, owner: FactionId): boolean {
    if (state === null) {
      return false;
    }
    const cfg: CampaignNodeConfig = CAMPAIGN_MAP_NODES[nodeIdx];
    for (let i: number = 0; i < cfg.neighbors.length; i++) {
      const nbIdx: number | undefined = this.nodeIndexById.get(cfg.neighbors[i]);
      if (nbIdx === undefined) {
        continue;
      }
      const nbOwner: FactionId = this.getNodeOwner(nbIdx);
      if (nbOwner !== owner && this.areFactionsAtWar(state, owner, nbOwner)) {
        if (this.hasFieldArmyAtNode(state, cfg.neighbors[i]) || this.hasFieldArmyAtNode(state, cfg.id)) {
          return true;
        }
      }
    }
    return false;
  }

  private hasFieldArmyAtNode(state: CampaignSaveState | null, nodeId: string): boolean {
    if (state === null) {
      return false;
    }
    for (let i: number = 0; i < state.factions.length; i++) {
      const fc: FactionCampaignRuntime = state.factions[i];
      if (fc.isAlive && fc.armyLocationNodeId === nodeId) {
        return true;
      }
    }
    return false;
  }

  /**
   * 4. 右上角战略全局小地图（展示 8 区势力版图点、围城红闪与当前摄像机视口秒跳框）
   */
  private renderGlobalMinimapOverlay(ctx: ICanvas2DContext, selectedNodeId: string | null): void {
    const mm: MinimapLayout = this.minimapRect;
    const scaleX: number = mm.width / this.worldW;
    const scaleY: number = mm.height / this.worldH;

    ctx.fillStyle = 'rgba(18, 15, 13, 0.90)';
    ctx.fillRect(mm.x, mm.y, mm.width, mm.height);

    // 8 板块缩略底色
    for (let i: number = 0; i < REGION_BIOMES.length; i++) {
      const rb: RegionBiomeZone = REGION_BIOMES[i];
      ctx.fillStyle = rb.fillColor;
      ctx.beginPath();
      ctx.ellipse(
        mm.x + rb.centerX * scaleX,
        mm.y + rb.centerY * scaleY,
        rb.radiusX * scaleX,
        rb.radiusY * scaleY,
        0,
        0,
        TWO_PI
      );
      ctx.fill();
    }

    // 40 城关势力版图点、交战闪烁告警与选中高亮
    let hasMinimapSiege: boolean = false;
    ctx.beginPath();
    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      const node: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
      const owner: FactionId = this.getNodeOwner(i);
      const px: number = mm.x + node.x * scaleX;
      const py: number = mm.y + node.y * scaleY;
      const sz: number = node.nodeType === CampaignNodeType.CAPITAL_CITADEL ? 5.2 : 3.4;

      ctx.fillStyle = FACTION_PRIMARY_COLORS[getFactionBucketIndex(owner)];
      ctx.fillRect(px - sz * 0.5, py - sz * 0.5, sz, sz);

      const rt: CampaignNodeRuntime | null = this.runtimeByNodeIndex[i];
      if (rt !== null && (rt.isolatedTurns > 0 || rt.supplyGrade === SupplyLineGrade.SEVERED)) {
        ctx.moveTo(px + 4.8, py);
        ctx.arc(px, py, 4.8, 0, TWO_PI);
        hasMinimapSiege = true;
      }

      if (selectedNodeId !== null && node.id === selectedNodeId) {
        ctx.strokeStyle = '#FFD54F';
        ctx.lineWidth = 1.4;
        ctx.strokeRect(px - 4.5, py - 4.5, 9, 9);
      }
    }
    if (hasMinimapSiege) {
      ctx.strokeStyle = '#FF1744';
      ctx.lineWidth = 1.2;
      ctx.stroke();
    }

    ctx.strokeStyle = '#A1887F';
    ctx.lineWidth = 1.6;
    ctx.strokeRect(mm.x, mm.y, mm.width, mm.height);

    // 当前视口白色定位框
    const viewW: number = this.viewportW / this.zoom;
    const viewH: number = this.viewportH / this.zoom;
    const vx: number = clampNum((this.camX - viewW * 0.5) * scaleX, 0, mm.width);
    const vy: number = clampNum((this.camY - viewH * 0.5) * scaleY, 0, mm.height);
    const vw: number = clampNum(viewW * scaleX, 8, mm.width - vx);
    const vh: number = clampNum(viewH * scaleY, 8, mm.height - vy);

    ctx.strokeStyle = '#FFF8E1';
    ctx.lineWidth = 1.4;
    ctx.strokeRect(mm.x + vx, mm.y + vy, vw, vh);
  }
}
