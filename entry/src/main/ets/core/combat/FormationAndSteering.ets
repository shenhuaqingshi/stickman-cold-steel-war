/**
 * 四大冷兵器编队阵型、九种实时战术寻路与弹簧槽位局部避障引擎（FormationAndSteering.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖，零每帧 GC）
 */
import { GameConstants } from '../../common/GameConstants';
import {
  BattlefieldRationStage,
  BattleSide,
  FactionId,
  FormationType,
  FortStructureEntity,
  SoldierRuntimeEntity,
  SquadRuntimeState,
  TacticalOrder,
  TerrainType,
  TerrainZoneRect,
  UnitActionState,
  UnitCategory,
  UnitTypeId,
  WeatherType
} from '../CoreContracts';
import { normalizeAngleSigned } from './DamageAndMorale';
import { SpatialHashGrid } from './SpatialHashGrid';

const slotScratchBuffer: Int32Array = new Int32Array(GameConstants.MAX_UNIT_POOL_SIZE);

/** 地形查询结果复用容器 */
export class TerrainSampleResult {
  public terrain: TerrainType = TerrainType.PLAIN;
  public elevation: number = 0;
}

/**
 * 查询世界坐标 (x, y) 所在地形与海拔层级（高优先级特定区覆盖默认基础地形）
 */
export function sampleTerrainAtPoint(
  x: number,
  y: number,
  zones: readonly TerrainZoneRect[],
  fallbackTerrain: TerrainType,
  outSample: TerrainSampleResult
): void {
  // 河流渡口、桥梁关隘与城墙战场的非特指河岸/陆地基底为开阔平原，确保水陆边界分明（支撑半渡而击）
  const baseGround: TerrainType =
    fallbackTerrain === TerrainType.RIVER_FORD ||
    fallbackTerrain === TerrainType.BRIDGE_PASS ||
    fallbackTerrain === TerrainType.FORT_WALL
      ? TerrainType.PLAIN
      : fallbackTerrain;

  outSample.terrain = baseGround;
  outSample.elevation = baseGround === TerrainType.HIGH_GROUND ? 1 : 0;

  const zLen: number = zones.length;
  // 桥梁与城墙优先级高于河流浅滩，逆序匹配
  for (let i: number = zLen - 1; i >= 0; i--) {
    const z: TerrainZoneRect = zones[i];
    if (x >= z.x && x <= z.x + z.width && y >= z.y && y <= z.y + z.height) {
      outSample.terrain = z.terrain;
      outSample.elevation = z.elevation;
      return;
    }
  }
}

/**
 * 为指定分队的所有存活成员预计算阵型局部槽位偏移 (slotOffsetX, slotOffsetY)
 * 局部坐标系定义：+X 沿分队正面朝向向前，+Y 沿分队右侧横向展开
 */
export function assignSquadFormationSlots(
  squad: SquadRuntimeState,
  soldiers: readonly SoldierRuntimeEntity[]
): void {
  let count: number = 0;
  let bannerMemberPos: number = -1;
  const sLen: number = soldiers.length;

  for (let i: number = 0; i < sLen; i++) {
    const s: SoldierRuntimeEntity = soldiers[i];
    if (
      s.active &&
      s.hp > 0 &&
      s.squadId === squad.squadId &&
      s.actionState !== UnitActionState.DYING_FALL &&
      s.actionState !== UnitActionState.FALLEN_CORPSE
    ) {
      if (s.isBannerBearer && bannerMemberPos === -1) {
        bannerMemberPos = count;
      }
      slotScratchBuffer[count] = i;
      count++;
    }
  }

  if (count === 0) {
    return;
  }

  // 确保执旗官位于 0 号核心领队槽位（前排正中/楔尖）
  if (bannerMemberPos > 0) {
    const tmp: number = slotScratchBuffer[0];
    slotScratchBuffer[0] = slotScratchBuffer[bannerMemberPos];
    slotScratchBuffer[bannerMemberPos] = tmp;
  }

  if (squad.formation === FormationType.CIRCLE_DEFENSE) {
    if (count === 1) {
      soldiers[slotScratchBuffer[0]].slotOffsetX = 0;
      soldiers[slotScratchBuffer[0]].slotOffsetY = 0;
      return;
    }
    if (count <= 12) {
      const radius: number = Math.max(22.0, count * 3.4);
      for (let k: number = 0; k < count; k++) {
        const theta: number = (k / count) * Math.PI * 2.0;
        const unit: SoldierRuntimeEntity = soldiers[slotScratchBuffer[k]];
        unit.slotOffsetX = Math.cos(theta) * radius;
        unit.slotOffsetY = Math.sin(theta) * radius;
      }
    } else {
      const innerCount: number = Math.max(4, Math.floor(count * 0.38));
      const outerCount: number = count - innerCount;
      const innerR: number = Math.max(20.0, innerCount * 3.2);
      const outerR: number = Math.max(innerR + 18.0, outerCount * 3.1);
      for (let k: number = 0; k < innerCount; k++) {
        const theta: number = (k / innerCount) * Math.PI * 2.0;
        const unit: SoldierRuntimeEntity = soldiers[slotScratchBuffer[k]];
        unit.slotOffsetX = Math.cos(theta) * innerR;
        unit.slotOffsetY = Math.sin(theta) * innerR;
      }
      for (let k: number = 0; k < outerCount; k++) {
        const theta: number = (k / outerCount) * Math.PI * 2.0;
        const unit: SoldierRuntimeEntity = soldiers[slotScratchBuffer[innerCount + k]];
        unit.slotOffsetX = Math.cos(theta) * outerR;
        unit.slotOffsetY = Math.sin(theta) * outerR;
      }
    }
    return;
  }

  if (squad.formation === FormationType.WEDGE_CHARGE) {
    // 楔形三角箭头：第 r 排容纳 (2*r + 1) 人
    let cursor: number = 0;
    let row: number = 0;
    const totalRowsEst: number = Math.max(1, Math.ceil(Math.sqrt(count)));
    const centerShiftX: number = (totalRowsEst - 1) * 8.0;
    while (cursor < count) {
      const rowCap: number = row * 2 + 1;
      const inThisRow: number = Math.min(rowCap, count - cursor);
      const localX: number = centerShiftX - row * 17.0;
      for (let c: number = 0; c < inThisRow; c++) {
        const localY: number = (c - (inThisRow - 1) * 0.5) * 18.0;
        const unit: SoldierRuntimeEntity = soldiers[slotScratchBuffer[cursor]];
        unit.slotOffsetX = localX;
        unit.slotOffsetY = localY;
        cursor++;
      }
      row++;
    }
    return;
  }

  if (squad.formation === FormationType.ECHELON_LINE) {
    // 宽幅双排微弧雁行阵（无遮挡全齐射）
    const rows: number = count <= 6 ? 1 : 2;
    const cols: number = Math.max(1, Math.ceil(count / rows));
    for (let k: number = 0; k < count; k++) {
      const r: number = Math.floor(k / cols);
      const c: number = k % cols;
      const normLateral: number = cols > 1 ? (c - (cols - 1) * 0.5) / (cols * 0.5) : 0;
      const localY: number = (c - (cols - 1) * 0.5) * 22.0 + (r % 2 === 1 ? 6.0 : 0.0);
      const arcCurveX: number = -Math.abs(normLateral) * 8.0;
      const localX: number = ((rows - 1) * 0.5 - r) * 19.0 + arcCurveX;
      const unit: SoldierRuntimeEntity = soldiers[slotScratchBuffer[k]];
      unit.slotOffsetX = localX;
      unit.slotOffsetY = localY;
    }
    return;
  }

  // 默认 PHALANX_RECT：密集矩形方阵（深 4~6 排）
  const targetRows: number = count <= 4 ? 1 : Math.min(6, Math.max(2, Math.round(Math.sqrt(count * 0.65))));
  const cols: number = Math.max(1, Math.ceil(count / targetRows));
  const actualRows: number = Math.ceil(count / cols);
  for (let k: number = 0; k < count; k++) {
    const r: number = Math.floor(k / cols);
    const c: number = k % cols;
    const localX: number = ((actualRows - 1) * 0.5 - r) * 16.0;
    const localY: number = (c - (cols - 1) * 0.5) * 17.0;
    const unit: SoldierRuntimeEntity = soldiers[slotScratchBuffer[k]];
    unit.slotOffsetX = localX;
    unit.slotOffsetY = localY;
  }
}

/** 阵型移动速度乘数修正（DESIGN.md 4.1） */
export function computeFormationMoveMultiplier(
  formation: FormationType,
  bannerLostActive: boolean
): number {
  if (formation === FormationType.CIRCLE_DEFENSE) {
    return 0.05; // 圆阵几乎原地结阵防御
  }
  if (bannerLostActive) {
    return 1.0;
  }
  if (formation === FormationType.PHALANX_RECT) {
    return 0.85; // -15%
  }
  if (formation === FormationType.WEDGE_CHARGE) {
    return 1.08; // +8%
  }
  return 1.0;
}

/** 综合地形、天气、势力、士气、断粮、中毒与骆驼惊马光环的单兵有效移速计算 */
export function computeEffectiveSoldierSpeed(
  baseMoveSpeed: number,
  baseArmor: number,
  category: UnitCategory,
  factionId: FactionId,
  formation: FormationType,
  bannerLostActive: boolean,
  morale: number,
  terrain: TerrainType,
  weather: WeatherType,
  rationStage: BattlefieldRationStage,
  isPoisoned: boolean,
  isSpookedByCamel: boolean,
  hasWarCryBuff: boolean,
  hasBloodFrenzy: boolean
): number {
  let mult: number = computeFormationMoveMultiplier(formation, bannerLostActive);

  // 地形修正（DESIGN.md 7.2）
  if (terrain === TerrainType.RIVER_FORD) {
    if (category === UnitCategory.CAVALRY) {
      mult *= factionId === FactionId.XUANJIA ? 0.45 : 0.55;
    } else {
      mult *= 0.60;
    }
  } else if (terrain === TerrainType.DENSE_FOREST) {
    if (factionId === FactionId.WULIN) {
      mult *= 1.20;
    } else if (category === UnitCategory.CAVALRY) {
      mult *= 0.65;
    } else {
      mult *= 0.75;
    }
  } else if (terrain === TerrainType.DESERT_DUNE) {
    if (factionId !== FactionId.SHAMO) {
      if (category === UnitCategory.CAVALRY) {
        mult *= 0.90;
      } else if (baseArmor >= 40) {
        mult *= 0.85;
      }
    }
  } else if (terrain === TerrainType.SNOWFIELD) {
    if (factionId !== FactionId.SHUANGYUAN) {
      mult *= 0.85;
    }
  }

  // 天气修正
  if (weather === WeatherType.RAIN_MUD) {
    if (category === UnitCategory.CAVALRY && (factionId === FactionId.XUANJIA || baseArmor >= 40)) {
      mult *= 0.65;
    } else {
      mult *= 0.90;
    }
  } else if (weather === WeatherType.BLIZZARD) {
    if (factionId !== FactionId.SHUANGYUAN) {
      mult *= 0.88;
    }
  }

  // 势力被动修正
  if (factionId === FactionId.CANGLANG && category === UnitCategory.CAVALRY) {
    mult *= 1.12;
  } else if (factionId === FactionId.YANLONG && baseArmor >= 45 && category !== UnitCategory.CAVALRY) {
    mult *= 0.95;
  }
  if (factionId === FactionId.XUEYUE && hasBloodFrenzy) {
    mult *= 1.20;
  }

  // 士气高昂加速
  if (morale >= 85.0) {
    mult *= 1.06;
  }

  // 断粮减速（玄甲重骑断粮额外暴跌 35%）
  if (
    rationStage === BattlefieldRationStage.HUNGRY ||
    rationStage === BattlefieldRationStage.STARVING
  ) {
    if (factionId === FactionId.XUANJIA && category === UnitCategory.CAVALRY) {
      mult *= 0.65;
    } else {
      mult *= 0.88;
    }
  }

  // 雾林神经毒减速 35%
  if (isPoisoned) {
    mult *= 0.65;
  }

  // 沙漠商盟黄金马穆鲁克 160px 惊马光环（敌方战马移速 -25%）
  if (isSpookedByCamel && category === UnitCategory.CAVALRY) {
    mult *= 0.75;
  }

  // 主帅【三军战吼】+15% 移速激励
  if (hasWarCryBuff) {
    mult *= 1.15;
  }

  return Math.max(4.0, baseMoveSpeed * mult);
}

/** 判定当前地形是否允许骑兵/突击兵发起冲锋助跑 */
export function canTerrainSupportCharge(terrain: TerrainType, category: UnitCategory): boolean {
  if (terrain === TerrainType.RIVER_FORD) {
    return false;
  }
  if (terrain === TerrainType.DENSE_FOREST && category === UnitCategory.CAVALRY) {
    return false;
  }
  return true;
}

/**
 * 统计分队存活士兵质心 (centerX, centerY)、存活人数 aliveCount 与涉水比例 fordRatio
 */
const fordTerrainScratch: TerrainSampleResult = new TerrainSampleResult();

export function refreshSquadMetricsAndFordRatio(
  squad: SquadRuntimeState,
  soldiers: readonly SoldierRuntimeEntity[],
  terrainZones: readonly TerrainZoneRect[],
  fallbackTerrain: TerrainType
): void {
  let sumX: number = 0;
  let sumY: number = 0;
  let alive: number = 0;
  let inFord: number = 0;
  let bannerStillAlive: boolean = false;
  const sLen: number = soldiers.length;

  for (let i: number = 0; i < sLen; i++) {
    const s: SoldierRuntimeEntity = soldiers[i];
    if (
      s.active &&
      s.hp > 0 &&
      s.squadId === squad.squadId &&
      s.actionState !== UnitActionState.DYING_FALL &&
      s.actionState !== UnitActionState.FALLEN_CORPSE
    ) {
      sumX += s.x;
      sumY += s.y;
      alive++;
      if (s.isBannerBearer) {
        bannerStillAlive = true;
      }
      sampleTerrainAtPoint(s.x, s.y, terrainZones, fallbackTerrain, fordTerrainScratch);
      if (fordTerrainScratch.terrain === TerrainType.RIVER_FORD) {
        inFord++;
      }
    }
  }

  squad.aliveCount = alive;
  squad.bannerAlive = bannerStillAlive;
  if (alive > 0) {
    squad.centerX = sumX / alive;
    squad.centerY = sumY / alive;
    squad.fordRatio = inFord / alive;
    // 当全队已基本脱离河流后重置一次性半渡震慑标记，支持后续再次渡河判定
    if (squad.fordRatio < 0.10) {
      squad.halfFordShockApplied = false;
    }
  } else {
    squad.fordRatio = 0;
  }
}

/**
 * 推进分队虚拟引导锚点与战术朝向（支持 9 种战术指令与手写笔多航点队列）
 */
export function updateSquadOrderGuidance(
  squad: SquadRuntimeState,
  dtSec: number,
  ownBaseX: number,
  ownBaseY: number,
  enemyFocusX: number,
  enemyFocusY: number,
  worldWidth: number,
  worldHeight: number,
  outGuidePos: Float64Array
): void {
  if (squad.aliveCount <= 0) {
    outGuidePos[0] = squad.centerX;
    outGuidePos[1] = squad.centerY;
    return;
  }

  // 溃逃中脱离指挥，全力朝本阵后方狂奔
  if (squad.isRouting) {
    const fleeX: number = squad.side === BattleSide.PLAYER ? 20.0 : worldWidth - 20.0;
    const fleeY: number = ownBaseY;
    squad.facingRad = Math.atan2(fleeY - squad.centerY, fleeX - squad.centerX);
    outGuidePos[0] = fleeX;
    outGuidePos[1] = fleeY;
    return;
  }

  // 原地坚守或圆阵：死守当前阵地，朝向最近敌军威胁
  if (
    squad.order === TacticalOrder.HOLD_GROUND ||
    squad.formation === FormationType.CIRCLE_DEFENSE
  ) {
    const dxE: number = enemyFocusX - squad.centerX;
    const dyE: number = enemyFocusY - squad.centerY;
    if (dxE * dxE + dyE * dyE > 16.0) {
      squad.facingRad = Math.atan2(dyE, dxE);
    }
    outGuidePos[0] = squad.targetX;
    outGuidePos[1] = squad.targetY;
    return;
  }

  // 潜伏设伏：若尚未接敌（> 180px），静默保持在设伏目标点
  if (squad.order === TacticalOrder.AMBUSH_HIDE) {
    const distEnemySq: number =
      (enemyFocusX - squad.centerX) * (enemyFocusX - squad.centerX) +
      (enemyFocusY - squad.centerY) * (enemyFocusY - squad.centerY);
    if (distEnemySq > 180.0 * 180.0) {
      squad.facingRad = Math.atan2(enemyFocusY - squad.centerY, enemyFocusX - squad.centerX);
      outGuidePos[0] = squad.targetX;
      outGuidePos[1] = squad.targetY;
      return;
    }
    // 敌军踏入 180px 伏击袋，自动转为冲锋暴起突袭！
    squad.order = TacticalOrder.ALL_OUT_CHARGE;
    squad.targetX = enemyFocusX;
    squad.targetY = enemyFocusY;
  }

  // 交替撤退：向己方本阵缓慢后撤，但正面始终朝向敌方以举盾格挡避免背击
  if (squad.order === TacticalOrder.RETREAT) {
    squad.facingRad = Math.atan2(enemyFocusY - squad.centerY, enemyFocusX - squad.centerX);
    outGuidePos[0] = ownBaseX;
    outGuidePos[1] = ownBaseY;
    return;
  }

  // 诈败诱敌：接敌 210px 内时快速向本阵方向诱退 320px，正面维持戒备不掉士气，诱入深处后反扑
  if (squad.order === TacticalOrder.FEIGNED_RETREAT) {
    const dxE: number = enemyFocusX - squad.centerX;
    const dyE: number = enemyFocusY - squad.centerY;
    const distE: number = Math.sqrt(dxE * dxE + dyE * dyE);
    const distBase: number = Math.abs(squad.centerX - ownBaseX);
    if (distBase < 520.0 && distE < 240.0) {
      // 已诱敌深入己方腹地，瞬间反身全军冲锋掩杀！
      squad.order = TacticalOrder.ALL_OUT_CHARGE;
      squad.targetX = enemyFocusX;
      squad.targetY = enemyFocusY;
    } else {
      const pullX: number =
        squad.side === BattleSide.PLAYER
          ? Math.max(380.0, squad.centerX - 320.0)
          : Math.min(worldWidth - 380.0, squad.centerX + 320.0);
      squad.facingRad = Math.atan2(dyE, dxE);
      outGuidePos[0] = pullX;
      outGuidePos[1] = squad.centerY;
      return;
    }
  }

  // 手写笔自定义多航点或迂回包抄航点推进
  let destX: number = squad.targetX;
  let destY: number = squad.targetY;
  if (
    squad.waypointsX.length > 0 &&
    squad.waypointCursor < squad.waypointsX.length &&
    squad.waypointCursor < squad.waypointsY.length
  ) {
    destX = squad.waypointsX[squad.waypointCursor];
    destY = squad.waypointsY[squad.waypointCursor];
    const wpDx: number = destX - squad.centerX;
    const wpDy: number = destY - squad.centerY;
    if (wpDx * wpDx + wpDy * wpDy <= 75.0 * 75.0) {
      squad.waypointCursor++;
      if (squad.waypointCursor < squad.waypointsX.length) {
        destX = squad.waypointsX[squad.waypointCursor];
        destY = squad.waypointsY[squad.waypointCursor];
      } else {
        destX = squad.targetX;
        destY = squad.targetY;
      }
    }
  } else if (
    squad.order === TacticalOrder.FLANK ||
    squad.order === TacticalOrder.PINCER_ENCIRCLE
  ) {
    // 自动计算侧翼 220px 大弧线偏移包抄点
    const dxT: number = destX - squad.centerX;
    const dyT: number = destY - squad.centerY;
    const distT: number = Math.sqrt(dxT * dxT + dyT * dyT);
    if (distT > 260.0) {
      const perpSign: number = squad.centerY <= worldHeight * 0.5 ? -1.0 : 1.0;
      const midX: number = (squad.centerX + destX) * 0.5;
      const midY: number = Math.max(
        140.0,
        Math.min(worldHeight - 140.0, destY + perpSign * 220.0)
      );
      destX = midX;
      destY = midY;
    }
  }

  const moveDx: number = destX - squad.centerX;
  const moveDy: number = destY - squad.centerY;
  if (moveDx * moveDx + moveDy * moveDy > 25.0) {
    const desiredFacing: number = Math.atan2(moveDy, moveDx);
    const diff: number = normalizeAngleSigned(desiredFacing - squad.facingRad);
    const maxTurn: number = 3.2 * dtSec;
    if (Math.abs(diff) <= maxTurn) {
      squad.facingRad = desiredFacing;
    } else {
      squad.facingRad = normalizeAngleSigned(
        squad.facingRad + (diff > 0 ? maxTurn : -maxTurn)
      );
    }
  }

  outGuidePos[0] = Math.max(48.0, Math.min(worldWidth - 48.0, destX));
  outGuidePos[1] = Math.max(48.0, Math.min(worldHeight - 48.0, destY));
}

/**
 * 局部单位排斥分离与城墙阻挡碰撞修正（O(1) 邻格遍历，零对象分配）
 */
export function applyUnitSeparationAndFortCollision(
  soldier: SoldierRuntimeEntity,
  soldiers: readonly SoldierRuntimeEntity[],
  structures: readonly FortStructureEntity[],
  grid: SpatialHashGrid,
  dtSec: number,
  worldWidth: number,
  worldHeight: number
): void {
  const selfRadius: number =
    soldier.unitType === UnitTypeId.SHUANGYUAN_GIANT_BREAKER ? 12.0 : 8.0;
  const checkSpan: number = selfRadius + 14.0;

  const minCol: number = grid.worldToCol(soldier.x - checkSpan);
  const maxCol: number = grid.worldToCol(soldier.x + checkSpan);
  const minRow: number = grid.worldToRow(soldier.y - checkSpan);
  const maxRow: number = grid.worldToRow(soldier.y + checkSpan);

  let pushX: number = 0;
  let pushY: number = 0;

  for (let r: number = minRow; r <= maxRow; r++) {
    const rowOff: number = r * grid.cols;
    for (let c: number = minCol; c <= maxCol; c++) {
      let otherIdx: number = grid.cellHead[rowOff + c];
      while (otherIdx !== -1) {
        if (otherIdx !== soldier.poolIndex) {
          const other: SoldierRuntimeEntity = soldiers[otherIdx];
          const otherRadius: number =
            other.unitType === UnitTypeId.SHUANGYUAN_GIANT_BREAKER ? 12.0 : 8.0;
          const minDist: number = selfRadius + otherRadius;
          const dx: number = soldier.x - other.x;
          const dy: number = soldier.y - other.y;
          const dSq: number = dx * dx + dy * dy;
          if (dSq < minDist * minDist) {
            if (dSq > 0.0001) {
              const d: number = Math.sqrt(dSq);
              const overlap: number = (minDist - d) / d;
              pushX += dx * overlap * 0.45;
              pushY += dy * overlap * 0.45;
            } else {
              const jitterSign: number = soldier.poolIndex > otherIdx ? 1.0 : -1.0;
              pushX += jitterSign * 2.0;
              pushY += jitterSign * 1.5;
            }
          }
        }
        otherIdx = grid.unitNext[otherIdx];
      }
    }
  }

  soldier.x += pushX * Math.min(1.0, dtSec * 15.0);
  soldier.y += pushY * Math.min(1.0, dtSec * 15.0);

  // 未破损城墙与城门物理阻挡（攻城战器械全毁时步兵可贴墙慢速攀越，骑兵严格禁登墙）
  const stLen: number = structures.length;
  for (let i: number = 0; i < stLen; i++) {
    const st: FortStructureEntity = structures[i];
    if (st.isBreached || st.hp <= 0) {
      continue;
    }
    if (st.kind !== 'wall_segment' && st.kind !== 'gate') {
      continue;
    }
    // 己方城门允许己方部队通行出击
    if (st.kind === 'gate' && st.side === soldier.side) {
      continue;
    }
    const halfW: number = st.width * 0.5 + selfRadius;
    const halfH: number = st.height * 0.5 + selfRadius;
    const centerX: number = st.x + st.width * 0.5;
    const centerY: number = st.y + st.height * 0.5;
    const dxS: number = soldier.x - centerX;
    const dyS: number = soldier.y - centerY;
    if (Math.abs(dxS) < halfW && Math.abs(dyS) < halfH) {
      const penX: number = halfW - Math.abs(dxS);
      const penY: number = halfH - Math.abs(dyS);
      if (penX < penY) {
        soldier.x += dxS >= 0 ? penX : -penX;
        soldier.vx = 0;
      } else {
        soldier.y += dyS >= 0 ? penY : -penY;
        soldier.vy = 0;
      }
    }
  }

  // 限制在合法世界边界内（溃逃兵在近边缘 24px 由主模拟器结算逃离退场）
  const margin: number = soldier.actionState === UnitActionState.ROUT_PANIC ? 12.0 : 28.0;
  if (soldier.x < margin) {
    soldier.x = margin;
  } else if (soldier.x > worldWidth - margin) {
    soldier.x = worldWidth - margin;
  }
  if (soldier.y < 28.0) {
    soldier.y = 28.0;
  } else if (soldier.y > worldHeight - 28.0) {
    soldier.y = worldHeight - 28.0;
  }
}
