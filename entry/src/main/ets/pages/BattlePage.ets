import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
import { getFactionConfigById } from '../config/FactionConfig';
import {
  ArmyCorpsRole,
  BattleControlMode,
  BattlefieldRationStage,
  BattleHudSnapshot,
  BattleOutcomeReason,
  BattleSide,
  BattleWorldReadonlyView,
  EncirclementState,
  FactionId,
  FormationType,
  HeroControlInput,
  HeroSkillId,
  HeroVitalState,
  HeroWeaponType,
  SquadCommandRequest,
  SquadRuntimeState,
  TacticalOrder,
  UnitTypeId
} from '../core/CoreContracts';
import { BattleSimulator } from '../core/combat/BattleSimulator';
import { GameSessionCoordinator } from '../core/session/GameSessionCoordinator';
import { FactionStaticConfig, RouteLaunchParams } from '../model/GameTypes';
import {
  BattleSelectionOverlay,
  Point2D,
  StickmanBattleRenderer
} from '../render/StickmanBattleRenderer';
import {
  GameSettingsData,
  JoystickHandedness,
  TargetFpsOption
} from '../storage/SettingsStore';
import { ArkCanvas2DAdapter } from '../ui/ArkCanvas2DAdapter';

const DOMAIN: number = 0x0001;
const TAG: string = 'BattlePage';

interface SquadUiRow {
  readonly squadId: number;
  readonly title: string;
  readonly statusBadge: string;
  readonly morale: number;
  readonly aliveCount: number;
  readonly initialCount: number;
  readonly isRouting: boolean;
}

interface FormationBtnItem {
  readonly formation: FormationType;
  readonly label: string;
}

interface OrderBtnItem {
  readonly order: TacticalOrder;
  readonly label: string;
}

/**
 * 鸿蒙平板真实冷兵器大战场页（全流程打通正式版）
 * 左栏（30%）：RTS 六军团列表/4阵型/9战术指令/本阵补兵 或 主帅亲自上阵三兵刃/格挡弹反/三技能操控台；
 * 右栏（70%）：4800×2400 / 5600×2600 实时骨骼交锋 Canvas 大视野（支持双指缩放、小地图秒跳、M-Pencil 画线包抄）。
 */
@Entry
@Component
struct BattlePage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;

  // 4Hz 节流同步的 ArkUI 轻量 HUD 状态
  @State controlMode: BattleControlMode = BattleControlMode.RTS_COMMANDER;
  @State isPaused: boolean = false;
  @State switchCooldownSec: number = 0;
  @State garrisonBellActive: boolean = false;
  @State playerGold: number = GameConstants.BATTLE_INIT_GOLD;
  @State playerWood: number = GameConstants.BATTLE_INIT_WOOD;
  @State playerGrain: number = GameConstants.BATTLE_INIT_GRAIN;
  @State rationStage: BattlefieldRationStage = BattlefieldRationStage.ABUNDANT;
  @State playerAlive: number = 0;
  @State playerPopUsed: number = 0;
  @State enemyAlive: number = 0;
  @State playerMorale: number = GameConstants.MORALE_BASE;
  @State enemyMorale: number = GameConstants.MORALE_BASE;
  @State heroHp: number = 1100;
  @State heroMaxHp: number = 1100;
  @State heroVitalState: HeroVitalState = HeroVitalState.HEALTHY_ACTIVE;
  @State heroWeapon: HeroWeaponType = HeroWeaponType.COMMAND_SABER;
  @State heroArrows: number = 24;
  @State heroKills: number = 0;
  @State chargeCd: number = 0;
  @State bulwarkCd: number = 0;
  @State warCryCd: number = 0;
  @State outcome: BattleOutcomeReason = BattleOutcomeReason.ONGOING;
  @State aiDoctrineText: string = '正面牵制+两翼包抄';
  @State battleTip: string = '点选左栏军团或画布士兵下令变阵包抄；点击右上角可随时切换【主帅亲自上阵】冲阵斩旗！';

  // RTS 交互状态
  @State pointerToolMode: string = 'pan_pick'; // 'pan_pick' | 'marquee' | 'target_order'
  @State fogOfWarEnabled: boolean = true;
  @State selectedSquadIds: number[] = [0];
  @State squadRows: SquadUiRow[] = [];

  // 英雄操控摇杆与偏好状态
  @State joystickRightHanded: boolean = false;
  @State isHeroBlockingUi: boolean = false;
  @State joyKnobOffsetX: number = 0;
  @State joyKnobOffsetY: number = 0;

  private readonly session: GameSessionCoordinator = GameSessionCoordinator.getInstance();
  private readonly canvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly canvasContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.canvasSettings);
  private canvasAdapter: ArkCanvas2DAdapter | null = null;
  private readonly battleRenderer: StickmanBattleRenderer = new StickmanBattleRenderer(1280, 800);

  private frameTimerId: number = -1;
  private lastTickMs: number = 0;
  private hudSyncAccumMs: number = 250;
  private pinchBaseZoom: number = 0.68;
  private vibrationEnabled: boolean = true;
  private stylusLineEnabled: boolean = true;

  // 画布手势与 M-Pencil 轨迹缓冲（预分配复用，避免帧内频繁创建数组）
  private isCanvasDragging: boolean = false;
  private touchDownX: number = 0;
  private touchDownY: number = 0;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  private marqueeActive: boolean = false;
  private marqueeEndX: number = 0;
  private marqueeEndY: number = 0;
  private isStylusDrawing: boolean = false;
  private readonly stylusTrailScreenX: number[] = [];
  private readonly stylusTrailScreenY: number[] = [];
  private readonly tempWorldPoint: Point2D = { x: 0, y: 0 };

  private readonly heroInputState: HeroControlInput = {
    moveX: 0,
    moveY: 0,
    aimX: 1200,
    aimY: 1200,
    isAttackPressed: false,
    isBlockHeld: false
  };

  private readonly formationButtons: readonly FormationBtnItem[] = [
    { formation: FormationType.PHALANX_RECT, label: '方阵(+甲抗骑)' },
    { formation: FormationType.ECHELON_LINE, label: '雁行(齐射防砸)' },
    { formation: FormationType.WEDGE_CHARGE, label: '锥形(冲锋凿穿)' },
    { formation: FormationType.CIRCLE_DEFENSE, label: '圆阵(免侧背伤)' }
  ];

  private readonly orderButtons: readonly OrderBtnItem[] = [
    { order: TacticalOrder.ADVANCE, label: '稳步推进' },
    { order: TacticalOrder.HOLD_GROUND, label: '原地坚守' },
    { order: TacticalOrder.ALL_OUT_CHARGE, label: '全军冲锋' },
    { order: TacticalOrder.RETREAT, label: '交替撤退' },
    { order: TacticalOrder.FLANK, label: '侧翼包抄' },
    { order: TacticalOrder.PINCER_ENCIRCLE, label: '钳形合围' },
    { order: TacticalOrder.FEIGNED_RETREAT, label: '诈败诱敌' },
    { order: TacticalOrder.AMBUSH_HIDE, label: '潜伏设伏' },
    { order: TacticalOrder.RAID_SUPPLY, label: '奇袭断粮' }
  ];

  aboutToAppear(): void {
    let sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null) {
      this.session.launchBattleFromSetup();
      sim = this.session.getActiveBattleSimulator();
    }

    const userSettings: GameSettingsData = this.session.getSettingsStore().getSettings();
    this.joystickRightHanded =
      userSettings.joystickHandedness === JoystickHandedness.RIGHT_MOVE_LEFT_SKILL;
    this.vibrationEnabled = userSettings.vibrationEnabled;
    this.stylusLineEnabled = userSettings.stylusTacticalLineEnabled;
    this.battleRenderer.setLodPolicyMode(userSettings.distantLodPolicy);
    this.battleRenderer.setStylusPickRadiusPx(
      this.session.getSettingsStore().getEffectiveStylusPickRadiusPx()
    );

    if (sim !== null) {
      const world: BattleWorldReadonlyView = sim.getWorldView();
      this.battleRenderer.setWorldSize(world.width, world.height);
      this.battleRenderer.setCamera(world.width * 0.36, world.height * 0.5, 0.68);
      this.selectFirstAlivePlayerSquad(world);
      this.syncHudToArkUi(world, true);
    }

    this.startRealTimeLoop(userSettings.targetFps);
  }

  aboutToDisappear(): void {
    this.stopRealTimeLoop();
  }

  private startRealTimeLoop(targetFps: TargetFpsOption): void {
    this.stopRealTimeLoop();
    const intervalMs: number = targetFps === TargetFpsOption.FPS_30 ? 33 : 16;
    this.lastTickMs = Date.now();
    this.frameTimerId = setInterval(() => {
      this.onFrameTick();
    }, intervalMs);
  }

  private stopRealTimeLoop(): void {
    if (this.frameTimerId !== -1) {
      clearInterval(this.frameTimerId);
      this.frameTimerId = -1;
    }
  }

  private selectFirstAlivePlayerSquad(world: BattleWorldReadonlyView): void {
    const nextIds: number[] = [];
    for (let i: number = 0; i < world.squads.length; i++) {
      const sq: SquadRuntimeState = world.squads[i];
      if (sq.side === BattleSide.PLAYER && sq.aliveCount > 0) {
        nextIds.push(sq.squadId);
        break;
      }
    }
    this.selectedSquadIds = nextIds;
  }

  private onFrameTick(): void {
    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null) {
      return;
    }
    const nowMs: number = Date.now();
    const rawDtSec: number = (nowMs - this.lastTickMs) * 0.001;
    this.lastTickMs = nowMs;
    const dtSec: number = Math.max(0.008, Math.min(0.05, rawDtSec));

    if (this.controlMode === BattleControlMode.HERO_ACTION) {
      const hero = sim.getWorldView().playerHero;
      if (Math.abs(this.heroInputState.moveX) > 0.05 || Math.abs(this.heroInputState.moveY) > 0.05) {
        this.heroInputState.aimX = hero.x + this.heroInputState.moveX * 220;
        this.heroInputState.aimY = hero.y + this.heroInputState.moveY * 220;
      }
      sim.updateHeroInput(this.heroInputState);
    }

    const hud: BattleHudSnapshot | null = this.session.stepActiveBattle(dtSec);
    const world: BattleWorldReadonlyView = sim.getWorldView();

    if (hud !== null && hud.hitStopRemainingMs > 0 && this.vibrationEnabled) {
      this.battleRenderer.triggerHitStopShake(hud.hitStopRemainingMs, 5.5);
    }
    this.battleRenderer.updateCamera(world, dtSec);

    if (this.canvasAdapter !== null) {
      const overlay: BattleSelectionOverlay = {
        selectedSquadIds: this.selectedSquadIds,
        marqueeActive: this.marqueeActive,
        marqueeStartX: this.touchDownX,
        marqueeStartY: this.touchDownY,
        marqueeEndX: this.marqueeEndX,
        marqueeEndY: this.marqueeEndY,
        stylusTrailScreenX: this.stylusTrailScreenX,
        stylusTrailScreenY: this.stylusTrailScreenY,
        fogOfWarEnabled: this.fogOfWarEnabled
      };
      this.battleRenderer.render(this.canvasAdapter, world, overlay);
    }

    this.hudSyncAccumMs += dtSec * 1000.0;
    if (
      this.hudSyncAccumMs >= 250.0 ||
      (hud !== null && hud.outcome !== this.outcome)
    ) {
      this.hudSyncAccumMs = 0;
      this.syncHudToArkUi(world, false);
    }
  }

  private syncHudToArkUi(world: BattleWorldReadonlyView, forceInit: boolean): void {
    const hud: BattleHudSnapshot = world.hud;
    this.controlMode = hud.controlMode;
    this.isPaused = hud.isPaused;
    this.switchCooldownSec = Math.ceil(hud.switchCooldownSec * 10) / 10;
    this.garrisonBellActive = hud.garrisonBellActive;
    this.playerGold = Math.floor(hud.playerGold);
    this.playerWood = Math.floor(hud.playerWood);
    this.playerGrain = Math.floor(hud.playerGrain);
    this.rationStage = hud.playerRationStage;
    this.playerAlive = hud.playerAliveSoldiers;
    this.playerPopUsed = hud.playerPopUsed;
    this.enemyAlive = hud.enemyAliveSoldiers;
    this.playerMorale = Math.round(hud.playerAvgMorale);
    this.enemyMorale = Math.round(hud.enemyAvgMorale);
    this.heroHp = Math.max(0, Math.round(hud.heroHp));
    this.heroMaxHp = Math.round(hud.heroMaxHp);
    this.heroVitalState = hud.heroVitalState;
    this.heroWeapon = hud.heroWeapon;
    this.heroArrows = hud.heroArrows;
    this.heroKills = world.playerHero.kills;
    this.chargeCd = Math.ceil(hud.chargeCd * 10) / 10;
    this.bulwarkCd = Math.ceil(hud.bulwarkCd * 10) / 10;
    this.warCryCd = Math.ceil(hud.warCryCd * 10) / 10;
    this.aiDoctrineText = this.formatDoctrineLabel(this.session.getLastAiDoctrine());

    if (hud.outcome !== BattleOutcomeReason.ONGOING && (this.outcome === BattleOutcomeReason.ONGOING || forceInit)) {
      this.outcome = hud.outcome;
      this.session.finalizeActiveBattle();
    } else {
      this.outcome = hud.outcome;
    }

    const rows: SquadUiRow[] = [];
    for (let i: number = 0; i < world.squads.length; i++) {
      const sq: SquadRuntimeState = world.squads[i];
      if (sq.side !== BattleSide.PLAYER) {
        continue;
      }
      const badge: string = this.buildSquadAlertBadge(sq);
      const row: SquadUiRow = {
        squadId: sq.squadId,
        title: sq.name,
        statusBadge: badge,
        morale: Math.round(sq.morale),
        aliveCount: sq.aliveCount,
        initialCount: sq.initialCount,
        isRouting: sq.isRouting
      };
      rows.push(row);
    }
    this.squadRows = rows;
  }

  private buildSquadAlertBadge(sq: SquadRuntimeState): string {
    if (sq.aliveCount <= 0) {
      return '全军覆没';
    }
    if (sq.isRouting) {
      return '溃逃中!';
    }
    if (sq.encirclement === EncirclementState.ENCIRCLED) {
      return '四面楚歌!';
    }
    if (sq.encirclement === EncirclementState.PINCERED) {
      return '钳形受夹!';
    }
    if (sq.encirclement === EncirclementState.FLANKED) {
      return '侧翼受袭';
    }
    return this.shortOrderLabel(sq.order);
  }

  private shortOrderLabel(order: TacticalOrder): string {
    switch (order) {
      case TacticalOrder.ADVANCE:
        return '推进';
      case TacticalOrder.HOLD_GROUND:
        return '坚守';
      case TacticalOrder.ALL_OUT_CHARGE:
        return '冲锋';
      case TacticalOrder.RETREAT:
        return '撤退';
      case TacticalOrder.FLANK:
        return '包抄';
      case TacticalOrder.PINCER_ENCIRCLE:
        return '钳击';
      case TacticalOrder.FEIGNED_RETREAT:
        return '诈败';
      case TacticalOrder.AMBUSH_HIDE:
        return '潜伏';
      case TacticalOrder.RAID_SUPPLY:
        return '断粮';
      default:
        return '戒备';
    }
  }

  private formatDoctrineLabel(doc: string): string {
    if (doc === 'PINNING_PINCER_ENCIRCLE') {
      return 'AI教条：正面牵制+两翼钳形合围';
    }
    if (doc === 'FORD_AMBUSH_WAIT' || doc === 'HALF_FORD_STRIKE') {
      return 'AI教条：渡口潜伏·半渡而击';
    }
    if (doc === 'HIGH_GROUND_HEDGEHOG') {
      return 'AI教条：高地刺猬防反';
    }
    if (doc === 'FEIGNED_RETREAT_LURE' || doc === 'FOREST_TRAP_ENCIRCLE') {
      return 'AI教条：诈败诱敌·密林伏击';
    }
    if (doc === 'DECAPITATION_HUNT') {
      return 'AI教条：合围斩首敌帅';
    }
    if (doc === 'SIEGE_THREE_STAGE_ASSAULT' || doc === 'SIEGE_THREE_STAGE_DEFENSE') {
      return `AI教条：攻守城三段式(${this.session.getLastAiSiegePhase()})`;
    }
    return `AI教条：${doc}`;
  }

  private rationStageText(): string {
    switch (this.rationStage) {
      case BattlefieldRationStage.ABUNDANT:
        return '军粮充沛';
      case BattlefieldRationStage.WARNING:
        return '余粮<15s告警!';
      case BattlefieldRationStage.HUNGRY:
        return '断粮饥饿(-速-士气)';
      case BattlefieldRationStage.STARVING:
        return '断粮饥溃(-25%攻)!';
      default:
        return '正常';
    }
  }

  private rationColor(): string {
    if (this.rationStage === BattlefieldRationStage.ABUNDANT) {
      return '#81C784';
    }
    if (this.rationStage === BattlefieldRationStage.WARNING) {
      return '#FFD54F';
    }
    return '#FF5252';
  }

  private heroVitalLabel(): string {
    switch (this.heroVitalState) {
      case HeroVitalState.HEALTHY_ACTIVE:
        return '战力完好(享首次抢救)';
      case HeroVitalState.RECOVERING_IN_CAMP:
        return '落马回营包扎中(全军锁65士气)';
      case HeroVitalState.WOUNDED_WEAKENED:
        return '重创虚弱(属性-25%·无免死)';
      case HeroVitalState.FALLEN_MARTYRED:
        return '阵前殉国!';
      default:
        return '';
    }
  }

  private handleCanvasTouch(event: TouchEvent): void {
    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null || event.touches.length === 0) {
      return;
    }
    const tx: number = event.touches[0].x;
    const ty: number = event.touches[0].y;
    const isStylus: boolean = event.sourceTool === SourceTool.Pen;
    const world: BattleWorldReadonlyView = sim.getWorldView();

    if (event.type === TouchType.Down) {
      if (this.battleRenderer.handleMinimapTap(tx, ty)) {
        this.isCanvasDragging = false;
        return;
      }

      this.touchDownX = tx;
      this.touchDownY = ty;
      this.lastTouchX = tx;
      this.lastTouchY = ty;
      this.isCanvasDragging = true;

      if (this.controlMode === BattleControlMode.HERO_ACTION) {
        this.battleRenderer.screenToWorld(tx, ty, this.tempWorldPoint);
        this.heroInputState.aimX = this.tempWorldPoint.x;
        this.heroInputState.aimY = this.tempWorldPoint.y;
        this.heroInputState.isAttackPressed = true;
        sim.updateHeroInput(this.heroInputState);
        return;
      }

      if (isStylus) {
        const hitSq: SquadRuntimeState | null = this.battleRenderer.pickSquadAtScreenPos(
          world,
          tx,
          ty,
          true,
          BattleSide.PLAYER
        );
        if (hitSq !== null) {
          this.selectedSquadIds = [hitSq.squadId];
        }
        if (this.stylusLineEnabled && this.selectedSquadIds.length > 0) {
          this.isStylusDrawing = true;
          this.stylusTrailScreenX.length = 0;
          this.stylusTrailScreenY.length = 0;
          this.stylusTrailScreenX.push(tx);
          this.stylusTrailScreenY.push(ty);
        }
        return;
      }

      if (this.pointerToolMode === 'marquee') {
        this.marqueeActive = true;
        this.marqueeEndX = tx;
        this.marqueeEndY = ty;
      }
      return;
    }

    if (event.type === TouchType.Move) {
      if (!this.isCanvasDragging) {
        return;
      }
      if (this.controlMode === BattleControlMode.HERO_ACTION) {
        this.battleRenderer.screenToWorld(tx, ty, this.tempWorldPoint);
        this.heroInputState.aimX = this.tempWorldPoint.x;
        this.heroInputState.aimY = this.tempWorldPoint.y;
        sim.updateHeroInput(this.heroInputState);
        return;
      }

      if (this.isStylusDrawing) {
        const lastIdx: number = this.stylusTrailScreenX.length - 1;
        if (lastIdx >= 0) {
          const dxS: number = tx - this.stylusTrailScreenX[lastIdx];
          const dyS: number = ty - this.stylusTrailScreenY[lastIdx];
          if (dxS * dxS + dyS * dyS >= 18 * 18 && this.stylusTrailScreenX.length < 18) {
            this.stylusTrailScreenX.push(tx);
            this.stylusTrailScreenY.push(ty);
          }
        }
        return;
      }

      if (this.marqueeActive) {
        this.marqueeEndX = tx;
        this.marqueeEndY = ty;
        return;
      }

      const dx: number = tx - this.lastTouchX;
      const dy: number = ty - this.lastTouchY;
      this.lastTouchX = tx;
      this.lastTouchY = ty;
      if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) {
        this.battleRenderer.panByScreenDelta(dx, dy);
      }
      return;
    }

    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.controlMode === BattleControlMode.HERO_ACTION) {
        this.heroInputState.isAttackPressed = false;
        sim.updateHeroInput(this.heroInputState);
        this.isCanvasDragging = false;
        return;
      }

      if (this.isStylusDrawing) {
        this.isStylusDrawing = false;
        if (this.stylusTrailScreenX.length >= 2 && this.selectedSquadIds.length > 0) {
          const wpX: number[] = [];
          const wpY: number[] = [];
          for (let i: number = 0; i < this.stylusTrailScreenX.length; i++) {
            this.battleRenderer.screenToWorld(
              this.stylusTrailScreenX[i],
              this.stylusTrailScreenY[i],
              this.tempWorldPoint
            );
            wpX.push(this.tempWorldPoint.x);
            wpY.push(this.tempWorldPoint.y);
          }
          const cmd: SquadCommandRequest = {
            squadIds: this.selectedSquadIds.slice(),
            order: TacticalOrder.FLANK,
            targetX: wpX[wpX.length - 1],
            targetY: wpY[wpY.length - 1],
            customWaypointsX: wpX,
            customWaypointsY: wpY
          };
          sim.issueSquadCommand(cmd);
          this.battleTip = `M-Pencil 战术笔迹已生成 ${wpX.length} 个迂回包抄航点！`;
        }
        this.stylusTrailScreenX.length = 0;
        this.stylusTrailScreenY.length = 0;
        this.isCanvasDragging = false;
        return;
      }

      if (this.marqueeActive) {
        this.marqueeActive = false;
        const pickedIds: number[] = this.battleRenderer.pickSquadsInScreenRect(
          world,
          this.touchDownX,
          this.touchDownY,
          tx,
          ty,
          BattleSide.PLAYER
        );
        if (pickedIds.length > 0) {
          this.selectedSquadIds = pickedIds;
          this.battleTip = `框选编队成功：已同时选中 ${pickedIds.length} 支军团，可统一下达钳形合围或阵型指令。`;
        }
        this.pointerToolMode = 'pan_pick';
        this.isCanvasDragging = false;
        return;
      }

      const moveDistSq: number =
        (tx - this.touchDownX) * (tx - this.touchDownX) +
        (ty - this.touchDownY) * (ty - this.touchDownY);
      if (moveDistSq < 14 * 14) {
        const tappedSquad: SquadRuntimeState | null = this.battleRenderer.pickSquadAtScreenPos(
          world,
          tx,
          ty,
          false,
          BattleSide.PLAYER
        );
        if (tappedSquad !== null && this.pointerToolMode !== 'target_order') {
          this.selectedSquadIds = [tappedSquad.squadId];
          this.battleTip = `已选中【${tappedSquad.name}】（存活${tappedSquad.aliveCount} · 士气${Math.round(tappedSquad.morale)}），点击左栏战术或开启【点地行军】指派目标。`;
        } else if (this.selectedSquadIds.length > 0) {
          this.battleRenderer.screenToWorld(tx, ty, this.tempWorldPoint);
          const moveCmd: SquadCommandRequest = {
            squadIds: this.selectedSquadIds.slice(),
            targetX: this.tempWorldPoint.x,
            targetY: this.tempWorldPoint.y
          };
          sim.issueSquadCommand(moveCmd);
          this.battleTip = `已命选中军团向坐标 (${Math.round(this.tempWorldPoint.x)}, ${Math.round(this.tempWorldPoint.y)}) 机动接敌！`;
          if (this.pointerToolMode === 'target_order') {
            this.pointerToolMode = 'pan_pick';
          }
        }
      }
      this.isCanvasDragging = false;
    }
  }

  private handleJoystickTouch(event: TouchEvent): void {
    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null) {
      return;
    }
    const centerR: number = 64.0;
    const maxKnobR: number = 42.0;

    if (event.type === TouchType.Up || event.type === TouchType.Cancel || event.touches.length === 0) {
      this.joyKnobOffsetX = 0;
      this.joyKnobOffsetY = 0;
      this.heroInputState.moveX = 0;
      this.heroInputState.moveY = 0;
      sim.updateHeroInput(this.heroInputState);
      return;
    }

    const rawDx: number = event.touches[0].x - centerR;
    const rawDy: number = event.touches[0].y - centerR;
    const len: number = Math.hypot(rawDx, rawDy);
    if (len < 4.0) {
      this.joyKnobOffsetX = 0;
      this.joyKnobOffsetY = 0;
      this.heroInputState.moveX = 0;
      this.heroInputState.moveY = 0;
    } else {
      const clampedR: number = Math.min(maxKnobR, len);
      const nx: number = rawDx / len;
      const ny: number = rawDy / len;
      this.joyKnobOffsetX = nx * clampedR;
      this.joyKnobOffsetY = ny * clampedR;
      this.heroInputState.moveX = nx;
      this.heroInputState.moveY = ny;
      const hero = sim.getWorldView().playerHero;
      this.heroInputState.aimX = hero.x + nx * 240.0;
      this.heroInputState.aimY = hero.y + ny * 240.0;
    }
    sim.updateHeroInput(this.heroInputState);
  }

  private applyFormationToSelected(formation: FormationType): void {
    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null || this.selectedSquadIds.length === 0) {
      return;
    }
    const cmd: SquadCommandRequest = {
      squadIds: this.selectedSquadIds.slice(),
      formation: formation
    };
    sim.issueSquadCommand(cmd);
  }

  private applyOrderToSelected(order: TacticalOrder): void {
    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null || this.selectedSquadIds.length === 0) {
      return;
    }
    const cmd: SquadCommandRequest = {
      squadIds: this.selectedSquadIds.slice(),
      order: order
    };
    sim.issueSquadCommand(cmd);
  }

  private selectAllPlayerSquads(): void {
    const ids: number[] = [];
    for (let i: number = 0; i < this.squadRows.length; i++) {
      if (this.squadRows[i].aliveCount > 0) {
        ids.push(this.squadRows[i].squadId);
      }
    }
    this.selectedSquadIds = ids;
  }

  private recruitAtCamp(unitType: UnitTypeId, role: ArmyCorpsRole): void {
    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null) {
      return;
    }
    const ok: boolean = sim.recruitUnit(BattleSide.PLAYER, unitType, role);
    if (ok) {
      this.syncHudToArkUi(sim.getWorldView(), false);
      this.battleTip = '本阵大营增援新兵已披甲出营投入战线！';
    } else {
      this.battleTip = '大营征募未成：请核查金木粮军资、240人口上限或本阵是否受损。';
    }
  }

  private recruitExclusiveAce(): void {
    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null) {
      return;
    }
    const pFac: FactionId = sim.getWorldView().playerFaction;
    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(pFac);
    if (fCfg !== undefined) {
      this.recruitAtCamp(fCfg.exclusiveUnitId, ArmyCorpsRole.REAR_RESERVE);
    }
  }

  private raidEnemyGrainCamp(): void {
    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null) {
      return;
    }
    const gained: number = sim.triggerSupplyCampRaid(BattleSide.PLAYER);
    if (gained > 0) {
      this.syncHudToArkUi(sim.getWorldView(), false);
      this.battleTip = `奇袭大捷！焚掠敌军粮营当场夺取 ${gained} 应急军粮！`;
    } else {
      this.battleTip = '劫营未达条件：需先派轻骑或主帅突入敌方本阵大营近旁（或冷却中）。';
    }
  }

  private switchRtsAndHeroMode(): void {
    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
    if (sim === null) {
      return;
    }
    const ok: boolean = sim.toggleControlMode();
    if (ok) {
      this.heroInputState.moveX = 0;
      this.heroInputState.moveY = 0;
      this.heroInputState.isAttackPressed = false;
      this.heroInputState.isBlockHeld = false;
      this.isHeroBlockingUi = false;
      sim.updateHeroInput(this.heroInputState);
      this.syncHudToArkUi(sim.getWorldView(), false);
    } else {
      this.battleTip = '视角切换受限：冷却 1.5s 保护中，或主帅重伤回营包扎期间暂由 RTS 统帅全局。';
    }
  }

  private exitToSettlement(manualAction?: 'retreat' | 'truce'): void {
    this.stopRealTimeLoop();
    this.session.finalizeActiveBattle(manualAction);
    const pFac: FactionId =
      this.session.getActiveBattleSimulator() !== null
        ? (this.session.getActiveBattleSimulator() as BattleSimulator).getWorldView().playerFaction
        : FactionId.YANLONG;
    const launchParams: RouteLaunchParams = {
      modeKey: 'battle_result',
      modeTitle: '战后军功结算',
      factionId: pFac
    };
    this.getUIContext().getRouter().replaceUrl({
      url: 'pages/BattleResultPage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Open BattleResultPage warning: %{public}s', JSON.stringify(err));
    });
  }

  private isSquadSelected(squadId: number): boolean {
    return this.selectedSquadIds.indexOf(squadId) >= 0;
  }

  @Builder
  private buildCommandSidePanel() {
    Column({ space: 8 }) {
      if (this.controlMode === BattleControlMode.RTS_COMMANDER) {
        // ==================== RTS 多军团指挥台 ====================
        Row({ space: 6 }) {
          Text('六军团建制战线')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD54F')
            .layoutWeight(1)

          Button('全选主力')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .padding({ left: 10, right: 10 })
            .fontSize(12)
            .backgroundColor('#37474F')
            .onClick(() => {
              this.selectAllPlayerSquads();
            })
        }
        .width('100%')

        Row({ space: 6 }) {
          Button(this.pointerToolMode === 'marquee' ? '框选中…' : '框选编队')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .layoutWeight(1)
            .fontSize(12)
            .backgroundColor(this.pointerToolMode === 'marquee' ? '#2E7D32' : '#263238')
            .onClick(() => {
              this.pointerToolMode = this.pointerToolMode === 'marquee' ? 'pan_pick' : 'marquee';
            })

          Button(this.pointerToolMode === 'target_order' ? '请点画布…' : '点地行军')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .layoutWeight(1)
            .fontSize(12)
            .backgroundColor(this.pointerToolMode === 'target_order' ? '#E65100' : '#263238')
            .onClick(() => {
              this.pointerToolMode =
                this.pointerToolMode === 'target_order' ? 'pan_pick' : 'target_order';
            })

          Button(this.fogOfWarEnabled ? '迷雾:开' : '迷雾:关')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .layoutWeight(1)
            .fontSize(12)
            .backgroundColor('#3E2723')
            .onClick(() => {
              this.fogOfWarEnabled = !this.fogOfWarEnabled;
            })
        }
        .width('100%')

        List({ space: 5 }) {
          ForEach(this.squadRows, (sq: SquadUiRow) => {
            ListItem() {
              Row({ space: 6 }) {
                Column({ space: 2 }) {
                  Text(`${sq.title} (${sq.aliveCount}/${sq.initialCount})`)
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(sq.aliveCount > 0 ? '#FFF8E1' : '#78909C')
                    .maxLines(1)
                  Text(`士气 ${sq.morale} · ${sq.statusBadge}`)
                    .fontSize(11)
                    .fontColor(sq.isRouting ? '#FF5252' : '#81C784')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(this.isSquadSelected(sq.squadId) ? '#4E342E' : '#241F1D')
              .borderRadius(8)
              .border({
                width: 1.5,
                color: this.isSquadSelected(sq.squadId) ? '#D4A843' : '#332C2A'
              })
              .onClick(() => {
                this.selectedSquadIds = [sq.squadId];
              })
            }
          }, (sq: SquadUiRow) => `${sq.squadId}_${sq.aliveCount}_${sq.morale}_${sq.statusBadge}`)
        }
        .layoutWeight(1)
        .width('100%')

        // 4 大经典阵型按钮
        Grid() {
          ForEach(this.formationButtons, (fb: FormationBtnItem) => {
            GridItem() {
              Button(fb.label)
                .width('100%')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(11)
                .backgroundColor('#2E2623')
                .fontColor('#FFE082')
                .onClick(() => {
                  this.applyFormationToSelected(fb.formation);
                })
            }
          }, (fb: FormationBtnItem) => fb.formation)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(5)
        .rowsGap(5)
        .height(102)
        .width('100%')

        // 9 种实时冷兵器战术指令矩阵
        Grid() {
          ForEach(this.orderButtons, (ob: OrderBtnItem) => {
            GridItem() {
              Button(ob.label)
                .width('100%')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(11)
                .backgroundColor('#263238')
                .fontColor('#ECEFF1')
                .onClick(() => {
                  this.applyOrderToSelected(ob.order);
                })
            }
          }, (ob: OrderBtnItem) => ob.order)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(5)
        .rowsGap(5)
        .height(154)
        .width('100%')

        // 本阵即时补兵与劫粮热区
        Row({ space: 4 }) {
          Button('+工兵')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .layoutWeight(1)
            .fontSize(11)
            .backgroundColor('#3E2723')
            .onClick(() => {
              this.recruitAtCamp(UnitTypeId.SAPPER, ArmyCorpsRole.SUPPLY_ESCORT);
            })
          Button('+刀盾')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .layoutWeight(1)
            .fontSize(11)
            .backgroundColor('#3E2723')
            .onClick(() => {
              this.recruitAtCamp(UnitTypeId.SHIELD_SWORDSMAN, ArmyCorpsRole.VANGUARD_CENTER);
            })
          Button('+长枪')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .layoutWeight(1)
            .fontSize(11)
            .backgroundColor('#3E2723')
            .onClick(() => {
              this.recruitAtCamp(UnitTypeId.PIKEMAN, ArmyCorpsRole.VANGUARD_CENTER);
            })
          Button('+王牌')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .layoutWeight(1)
            .fontSize(11)
            .backgroundColor('#8D3B24')
            .onClick(() => {
              this.recruitExclusiveAce();
            })
          Button('劫敌粮')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .layoutWeight(1)
            .fontSize(11)
            .backgroundColor('#1B5E20')
            .onClick(() => {
              this.raidEnemyGrainCamp();
            })
        }
        .width('100%')
      } else {
        // ==================== 主帅亲自上阵英雄操控台 ====================
        Scroll() {
          Column({ space: 8 }) {
            Text(`主帅亲自上阵 · 阵斩 ${this.heroKills} 敌`)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFD54F')

            Text(`HP ${this.heroHp}/${this.heroMaxHp} ｜ 箭袋 ${this.heroArrows}/24 ｜ ${this.heroVitalLabel()}`)
              .fontSize(12)
              .fontColor('#81C784')

            // 三把随身兵刃切换（>= 48vp）
            Row({ space: 6 }) {
              Button('佩刀(盾反)')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(12)
                .backgroundColor(
                  this.heroWeapon === HeroWeaponType.COMMAND_SABER ? '#B71C1C' : '#2E2623'
                )
                .onClick(() => {
                  const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
                  if (sim !== null) {
                    sim.switchHeroWeapon(HeroWeaponType.COMMAND_SABER);
                    this.heroWeapon = HeroWeaponType.COMMAND_SABER;
                  }
                })

              Button('破阵大枪')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(12)
                .backgroundColor(
                  this.heroWeapon === HeroWeaponType.BREAKER_SPEAR ? '#0D47A1' : '#2E2623'
                )
                .onClick(() => {
                  const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
                  if (sim !== null) {
                    sim.switchHeroWeapon(HeroWeaponType.BREAKER_SPEAR);
                    this.heroWeapon = HeroWeaponType.BREAKER_SPEAR;
                  }
                })

              Button(`硬弓(${this.heroArrows})`)
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(12)
                .backgroundColor(
                  this.heroWeapon === HeroWeaponType.HEAVY_WARBOW ? '#2E7D32' : '#2E2623'
                )
                .onClick(() => {
                  const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
                  if (sim !== null) {
                    sim.switchHeroWeapon(HeroWeaponType.HEAVY_WARBOW);
                    this.heroWeapon = HeroWeaponType.HEAVY_WARBOW;
                  }
                })
            }
            .width('100%')

            // 大尺寸虚拟摇杆触控圆盘 + 普攻/举盾精准弹反键
            Row({ space: 10 }) {
              Stack() {
                Circle({ width: 128, height: 128 })
                  .fill('#26201E')
                  .stroke('#6D4C41')
                  .strokeWidth(2)
                Circle({ width: 46, height: 46 })
                  .fill('#D4A843')
                  .translate({ x: this.joyKnobOffsetX, y: this.joyKnobOffsetY })
              }
              .width(128)
              .height(128)
              .onTouch((ev: TouchEvent) => {
                this.handleJoystickTouch(ev);
              })

              Column({ space: 8 }) {
                Button('挥砍 / 突刺 / 射击')
                  .width('100%')
                  .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .backgroundColor('#C62828')
                  .fontColor('#FFFFFF')
                  .onTouch((ev: TouchEvent) => {
                    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
                    if (sim === null) {
                      return;
                    }
                    this.heroInputState.isAttackPressed =
                      ev.type === TouchType.Down || ev.type === TouchType.Move;
                    sim.updateHeroInput(this.heroInputState);
                  })

                Button(this.isHeroBlockingUi ? '举盾格挡中(弹反!)' : '按住举盾 · 0.25s弹反')
                  .width('100%')
                  .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .backgroundColor(this.isHeroBlockingUi ? '#1565C0' : '#37474F')
                  .fontColor('#FFFFFF')
                  .onTouch((ev: TouchEvent) => {
                    const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
                    if (sim === null) {
                      return;
                    }
                    const held: boolean = ev.type === TouchType.Down || ev.type === TouchType.Move;
                    this.isHeroBlockingUi = held;
                    this.heroInputState.isBlockHeld = held;
                    sim.updateHeroInput(this.heroInputState);
                  })
              }
              .layoutWeight(1)
            }
            .width('100%')

            // 三大主动技能大热区按钮（>= 54vp）
            Button(
              this.chargeCd > 0
                ? `技能1【破阵突击】冷却 ${this.chargeCd}s`
                : '技能1【破阵突击】猛冲撞飞 (CD 10s)'
            )
              .width('100%')
              .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.chargeCd > 0 ? '#2C2624' : '#6A1B9A')
              .onClick(() => {
                const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
                if (sim !== null) {
                  sim.triggerHeroSkill(HeroSkillId.BREAKTHROUGH_CHARGE);
                }
              })

            Button(
              this.bulwarkCd > 0
                ? `技能2【铁壁横戈】冷却 ${this.bulwarkCd}s`
                : '技能2【铁壁横戈】弹反箭雨+旋斩 (CD 8s)'
            )
              .width('100%')
              .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.bulwarkCd > 0 ? '#2C2624' : '#00695C')
              .onClick(() => {
                const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
                if (sim !== null) {
                  sim.triggerHeroSkill(HeroSkillId.IRON_BULWARK);
                }
              })

            Button(
              this.warCryCd > 0
                ? `技能3【三军战吼】冷却 ${this.warCryCd}s`
                : '技能3【三军战吼】+18士气唤醒溃军! (CD 22s)'
            )
              .width('100%')
              .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.warCryCd > 0 ? '#2C2624' : '#E65100')
              .onClick(() => {
                const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
                if (sim !== null) {
                  sim.triggerHeroSkill(HeroSkillId.GRAND_WAR_CRY);
                }
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width(this.isWideScreen ? '30%' : '100%')
    .height(this.isWideScreen ? '100%' : '44%')
    .padding(10)
    .backgroundColor('#1A1514')
    .borderRadius(10)
  }

  @Builder
  private buildBattlefieldCanvasView() {
    Stack({ alignContent: Alignment.Center }) {
      Canvas(this.canvasContext)
        .width('100%')
        .height('100%')
        .backgroundColor('#1C1915')
        .borderRadius(10)
        .onReady(() => {
          this.canvasAdapter = new ArkCanvas2DAdapter(this.canvasContext);
          const cw: number = this.canvasContext.width;
          const ch: number = this.canvasContext.height;
          if (cw > 0 && ch > 0) {
            this.battleRenderer.setViewportSize(cw, ch);
          }
        })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const nw: number = Number(newArea.width);
          const nh: number = Number(newArea.height);
          if (nw > 0 && nh > 0) {
            this.battleRenderer.setViewportSize(nw, nh);
          }
        })
        .onTouch((event: TouchEvent) => {
          this.handleCanvasTouch(event);
        })
        .gesture(
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.pinchBaseZoom = this.battleRenderer.getZoom();
            })
            .onActionUpdate((ev: GestureEvent) => {
              this.battleRenderer.zoomAtScreenPoint(
                this.pinchBaseZoom * ev.scale,
                ev.pinchCenterX,
                ev.pinchCenterY
              );
            })
        )

      // 底部轻量战况提示浮条
      Column() {
        Blank()
        Text(`${this.aiDoctrineText} ｜ ${this.battleTip}`)
          .fontSize(11)
          .fontColor('#FFE082')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor('rgba(20, 17, 16, 0.78)')
          .borderRadius(6)
          .margin({ bottom: 8 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('96%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      // 终局胜负结算浮层横幅
      if (this.outcome !== BattleOutcomeReason.ONGOING) {
        Column({ space: 14 }) {
          Text(this.buildOutcomeHeadline())
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD54F')
          Text(`终局判定：${this.outcome}`)
            .fontSize(14)
            .fontColor('#ECEFF1')
          Button('进入战后军功与俘虏结算面板 ›')
            .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
            .padding({ left: 28, right: 28 })
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .backgroundColor('#B71C1C')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.exitToSettlement();
            })
        }
        .padding(26)
        .backgroundColor('rgba(24, 18, 16, 0.94)')
        .borderRadius(14)
        .border({ width: 2, color: '#D4A843' })
      }
    }
    .width(this.isWideScreen ? '70%' : '100%')
    .height(this.isWideScreen ? '100%' : '56%')
    .margin({
      left: this.isWideScreen && !(this.controlMode === BattleControlMode.HERO_ACTION && this.joystickRightHanded) ? 10 : 0,
      right: this.isWideScreen && this.controlMode === BattleControlMode.HERO_ACTION && this.joystickRightHanded ? 10 : 0,
      top: this.isWideScreen ? 0 : 8
    })
  }

  private buildOutcomeHeadline(): string {
    if (
      this.outcome === BattleOutcomeReason.ENEMY_BASE_DESTROYED ||
      this.outcome === BattleOutcomeReason.ENEMY_ARMY_ROUTED ||
      this.outcome === BattleOutcomeReason.SIEGE_DEFENSE_HELD
    ) {
      return '三军大捷 · 凯旋班师！';
    }
    if (this.outcome === BattleOutcomeReason.TRUCE_NEGOTIATED) {
      return '阵前鸣金 · 罢兵停火';
    }
    return '兵败受挫 · 鸣金收兵';
  }

  build() {
    Column({ space: 8 }) {
      // 顶部平板宽幅实时战略 HUD 栏（按钮全部 >= 48vp）
      Row({ space: 8 }) {
        Button('‹ 撤军')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 12, right: 12 })
          .fontSize(13)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.exitToSettlement('retreat');
          })

        Button('停火')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 12, right: 12 })
          .fontSize(13)
          .backgroundColor('#455A64')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.exitToSettlement('truce');
          })

        Column({ space: 2 }) {
          Text(`金 ${this.playerGold} · 木 ${this.playerWood} · 粮 ${this.playerGrain} [${this.rationStageText()}]`)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.rationColor())
          Text(`我军 ${this.playerAlive}人(士气${this.playerMorale}·人口${this.playerPopUsed}/240)  VS  敌军 ${this.enemyAlive}人(士气${this.enemyMorale})`)
            .fontSize(12)
            .fontColor('#ECEFF1')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.garrisonBellActive ? '警钟:鸣响协防' : '敲响本阵警钟')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 12, right: 12 })
          .fontSize(12)
          .backgroundColor(this.garrisonBellActive ? '#D84315' : '#2E2623')
          .onClick(() => {
            const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
            if (sim !== null) {
              this.garrisonBellActive = sim.toggleGarrisonBell();
            }
          })

        Button(this.isPaused ? '继续交锋' : '暂停部署')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 12, right: 12 })
          .fontSize(12)
          .backgroundColor('#37474F')
          .onClick(() => {
            const sim: BattleSimulator | null = this.session.getActiveBattleSimulator();
            if (sim !== null) {
              this.isPaused = !this.isPaused;
              sim.setPaused(this.isPaused);
            }
          })

        Button(
          this.controlMode === BattleControlMode.RTS_COMMANDER
            ? (this.switchCooldownSec > 0 ? `亲自上阵(${this.switchCooldownSec}s)` : '提刀亲自上阵!')
            : '切回统帅RTS'
        )
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 14, right: 14 })
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .backgroundColor(
            this.controlMode === BattleControlMode.RTS_COMMANDER ? '#B71C1C' : '#1565C0'
          )
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.switchRtsAndHeroMode();
          })
      }
      .width('100%')

      // 主体 MatePad 横屏左右双栏（默认左栏控制信息 + 右栏大战场主视口；若右手摇杆英雄模式则智能对调方便握持）
      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        if (this.isWideScreen && this.controlMode === BattleControlMode.HERO_ACTION && this.joystickRightHanded) {
          this.buildBattlefieldCanvasView()
          this.buildCommandSidePanel()
        } else {
          this.buildCommandSidePanel()
          this.buildBattlefieldCanvasView()
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#141110')
  }
}
