/**
 * 均匀空间哈希网格（SpatialHashGrid.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖）
 * 采用定长 Int32Array 静态单向链表（cellHead + unitNext），每帧 O(N) 重建，零 GC 分配
 */
import { GameConstants } from '../../common/GameConstants';
import { SoldierRuntimeEntity, UnitActionState } from '../CoreContracts';

export class SpatialHashGrid {
  public readonly worldWidth: number;
  public readonly worldHeight: number;
  public readonly cellSize: number;
  public readonly invCellSize: number;
  public readonly cols: number;
  public readonly rows: number;
  public readonly totalCells: number;
  public readonly maxUnits: number;

  /** 每个网格桶的头节点池索引（-1 表示空桶） */
  public readonly cellHead: Int32Array;
  /** 每个士兵池槽位指向同格下一士兵的静态链表指针（-1 表示链尾） */
  public readonly unitNext: Int32Array;

  constructor(
    worldWidth: number = GameConstants.BATTLEFIELD_WIDTH,
    worldHeight: number = GameConstants.BATTLEFIELD_HEIGHT,
    cellSize: number = GameConstants.SPATIAL_GRID_CELL_SIZE,
    maxUnits: number = GameConstants.MAX_UNIT_POOL_SIZE
  ) {
    this.worldWidth = Math.max(cellSize, worldWidth);
    this.worldHeight = Math.max(cellSize, worldHeight);
    this.cellSize = Math.max(16, cellSize);
    this.invCellSize = 1.0 / this.cellSize;
    this.cols = Math.max(1, Math.ceil(this.worldWidth * this.invCellSize));
    this.rows = Math.max(1, Math.ceil(this.worldHeight * this.invCellSize));
    this.totalCells = this.cols * this.rows;
    this.maxUnits = Math.max(1, maxUnits);

    this.cellHead = new Int32Array(this.totalCells);
    this.unitNext = new Int32Array(this.maxUnits);
    this.cellHead.fill(-1);
    this.unitNext.fill(-1);
  }

  /** O(totalCells) 原生内存重置，零对象分配 */
  public clear(): void {
    this.cellHead.fill(-1);
  }

  /** 将世界 X 坐标映射为合法列索引 */
  public worldToCol(x: number): number {
    const c: number = Math.floor(x * this.invCellSize);
    if (c < 0) {
      return 0;
    }
    if (c >= this.cols) {
      return this.cols - 1;
    }
    return c;
  }

  /** 将世界 Y 坐标映射为合法行索引 */
  public worldToRow(y: number): number {
    const r: number = Math.floor(y * this.invCellSize);
    if (r < 0) {
      return 0;
    }
    if (r >= this.rows) {
      return this.rows - 1;
    }
    return r;
  }

  /** 插入单个活跃单位索引到对应网格桶头（O(1)） */
  public insert(poolIndex: number, x: number, y: number): void {
    if (poolIndex < 0 || poolIndex >= this.maxUnits) {
      return;
    }
    const col: number = this.worldToCol(x);
    const row: number = this.worldToRow(y);
    const cellIdx: number = row * this.cols + col;
    this.unitNext[poolIndex] = this.cellHead[cellIdx];
    this.cellHead[cellIdx] = poolIndex;
  }

  /** 从预分配士兵池一次性 O(N) 重建空间哈希索引 */
  public rebuildFromSoldiers(soldiers: readonly SoldierRuntimeEntity[]): void {
    this.cellHead.fill(-1);
    const len: number = Math.min(soldiers.length, this.maxUnits);
    for (let i: number = 0; i < len; i++) {
      const s: SoldierRuntimeEntity = soldiers[i];
      if (
        s.active &&
        s.hp > 0 &&
        s.actionState !== UnitActionState.DYING_FALL &&
        s.actionState !== UnitActionState.FALLEN_CORPSE
      ) {
        const col: number = this.worldToCol(s.x);
        const row: number = this.worldToRow(s.y);
        const cellIdx: number = row * this.cols + col;
        this.unitNext[i] = this.cellHead[cellIdx];
        this.cellHead[cellIdx] = i;
      }
    }
  }

  /**
   * 查询与给定轴对齐包围盒重叠的所有网格桶内单位候选索引，写入预分配 outBuffer
   * @returns 写入 outBuffer 的候选单位数量
   */
  public queryCellsAABB(
    minX: number,
    minY: number,
    maxX: number,
    maxY: number,
    outBuffer: Int32Array
  ): number {
    const minCol: number = this.worldToCol(minX);
    const maxCol: number = this.worldToCol(maxX);
    const minRow: number = this.worldToRow(minY);
    const maxRow: number = this.worldToRow(maxY);
    const maxOut: number = outBuffer.length;
    let count: number = 0;

    for (let row: number = minRow; row <= maxRow; row++) {
      const rowOffset: number = row * this.cols;
      for (let col: number = minCol; col <= maxCol; col++) {
        let idx: number = this.cellHead[rowOffset + col];
        while (idx !== -1) {
          if (count >= maxOut) {
            return count;
          }
          outBuffer[count] = idx;
          count++;
          idx = this.unitNext[idx];
        }
      }
    }
    return count;
  }

  /**
   * 精确圆形半径查询，将距离 (cx, cy) <= radius 的单位池索引写入预分配 outBuffer
   * @returns 命中的精确单位数量
   */
  public queryRadius(
    soldiers: readonly SoldierRuntimeEntity[],
    cx: number,
    cy: number,
    radius: number,
    outBuffer: Int32Array
  ): number {
    if (radius <= 0) {
      return 0;
    }
    const minCol: number = this.worldToCol(cx - radius);
    const maxCol: number = this.worldToCol(cx + radius);
    const minRow: number = this.worldToRow(cy - radius);
    const maxRow: number = this.worldToRow(cy + radius);
    const radiusSq: number = radius * radius;
    const maxOut: number = outBuffer.length;
    let count: number = 0;

    for (let row: number = minRow; row <= maxRow; row++) {
      const rowOffset: number = row * this.cols;
      for (let col: number = minCol; col <= maxCol; col++) {
        let idx: number = this.cellHead[rowOffset + col];
        while (idx !== -1) {
          const s: SoldierRuntimeEntity = soldiers[idx];
          const dx: number = s.x - cx;
          const dy: number = s.y - cy;
          if (dx * dx + dy * dy <= radiusSq) {
            if (count >= maxOut) {
              return count;
            }
            outBuffer[count] = idx;
            count++;
          }
          idx = this.unitNext[idx];
        }
      }
    }
    return count;
  }
}
