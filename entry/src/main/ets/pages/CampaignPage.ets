import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../config/FactionConfig';
import {
  CampaignOperationResult,
  CampaignTurnAdvanceReport,
  CampaignVictoryKind,
  CampaignVictoryResult,
  MarchActionOptions,
  MarchActionResult
} from '../core/campaign/CampaignEngine';
import {
  ArmyCorpsRole,
  BetrayalAssessment,
  BilateralDiplomacyState,
  CampaignNodeRuntime,
  CampaignSaveState,
  DiplomaticStatus,
  FactionCampaignRuntime,
  FactionId,
  PeaceOfferTerms,
  PeaceOutcomeKind,
  SupplyEvaluationResult,
  SupplyLineGrade,
  UnitTypeId
} from '../core/CoreContracts';
import {
  DiplomaticActionResult,
  PeaceExecutionResult,
  WarDeclarationResult
} from '../core/diplomacy/DiplomacyEngine';
import {
  GameSessionCoordinator,
  PeaceOfferPreviewBundle
} from '../core/session/GameSessionCoordinator';
import {
  CampaignNodeConfig,
  FactionStaticConfig,
  FactionTechItem,
  PeaceOfferTerms as PeaceTermsModel,
  RouteLaunchParams
} from '../model/GameTypes';
import {
  CampaignMapRenderer,
  CampaignMapRenderOptions
} from '../render/CampaignMapRenderer';
import { SaveManager, SaveWriteResult } from '../storage/SaveManager';
import { ArkCanvas2DAdapter } from '../ui/ArkCanvas2DAdapter';

const DOMAIN: number = 0x0001;
const TAG: string = 'CampaignPage';

interface RivalFactionRow {
  readonly factionId: FactionId;
  readonly name: string;
  readonly color: string;
  readonly relation: number;
  readonly status: DiplomaticStatus;
  readonly remainingTurns: number;
  readonly vendettaTurns: number;
  readonly cityCount: number;
  readonly isAlive: boolean;
}

interface QuickRecruitBtn {
  readonly unitType: UnitTypeId;
  readonly count: number;
  readonly role: ArmyCorpsRole;
  readonly label: string;
}

/**
 * 3600×2400 战略大地图（40城78路无交叉平面拓扑）与八国外交纵横平板双栏正式页（CampaignPage.ets）
 * 左栏（36%）：【城关与行军】/【外交纵横（结盟·通商·互不侵犯·量化媾和·附庸·挑拨·背盟阻断）】/【整军与科技】；
 * 右栏（64%）：可双指缩放漫游、动态粮道着色、BFS 运粮高亮与小地图秒跳的战略大地图 Canvas 主视口。
 */
@Entry
@Component
struct CampaignPage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;

  // 顶部全局态势状态
  @State playerFaction: FactionId = FactionId.YANLONG;
  @State playerFactionName: string = '炎龙帝国';
  @State turnNumber: number = 1;
  @State gold: number = 0;
  @State wood: number = 0;
  @State grain: number = 0;
  @State credibility: number = 80;
  @State controlledCities: number = 5;
  @State armyPopUsed: number = 0;
  @State armyLocationNodeId: string = 'yl_capital';
  @State commanderLevel: number = 1;
  @State commanderInjuredTurns: number = 0;
  @State betrayalPenaltyBattles: number = 0;

  // 左栏页签与选中城关状态
  @State leftTab: string = 'city'; // 'city' | 'diplomacy' | 'army'
  @State selectedNodeId: string = 'yl_capital';
  @State selectedCityTitle: string = '炎龙帝都';
  @State selectedCityMeta: string = '';
  @State selectedCitySupplyText: string = '';
  @State selectedNeighborIds: string[] = [];
  @State statusFeedback: string = '点选右侧大地图任意城关检阅防务与 BFS 粮道，可向相邻城池挥师进军或在左栏纵横外交！';

  // 背盟二次确认强阻断弹卡状态（行军偷袭 或 外交强行宣战通用）
  @State pendingBetrayalPrompt: string = '';
  @State pendingBetrayalMode: string = ''; // '' | 'march' | 'declare_war'
  @State pendingBetrayalNodeId: string = '';
  @State pendingBetrayalTargetFaction: FactionId = FactionId.CANGLANG;
  @State pendingMarchNightRaid: boolean = false;
  @State pendingMarchConvoyRaid: boolean = false;

  // 外交纵横与量化媾和谈判台状态
  @State selectedTargetFaction: FactionId = FactionId.CANGLANG;
  @State rivalRows: RivalFactionRow[] = [];
  @State peaceGoldOffer: number = 100;
  @State peaceGrainPerTurn: number = 0;
  @State peaceTruceTurns: number = 8;
  @State peaceCityMode: string = 'none'; // 'none' | 'cede_own' | 'demand_enemy'
  @State peacePreviewText: string = '';
  @State counterOfferPending: PeaceTermsModel | null = null;
  @State counterOfferSummary: string = '';

  // 内政整军、商盟雇佣契约与胜利横幅
  @State useShamoGoldContract: boolean = false;
  @State unlockedTechIds: string[] = [];
  @State recentLogs: string[] = [];
  @State victoryBannerText: string = '';
  @State uiRefreshTick: number = 0;

  private readonly session: GameSessionCoordinator = GameSessionCoordinator.getInstance();
  private readonly canvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly canvasContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.canvasSettings);
  private canvasAdapter: ArkCanvas2DAdapter | null = null;
  private readonly mapRenderer: CampaignMapRenderer = new CampaignMapRenderer(1280, 800);

  private animTimerId: number = -1;
  private pinchStartZoom: number = 0.65;
  private isDraggingMap: boolean = false;
  private downScreenX: number = 0;
  private downScreenY: number = 0;
  private lastScreenX: number = 0;
  private lastScreenY: number = 0;
  private cachedSupplyEval: SupplyEvaluationResult | null = null;

  private readonly quickRecruits: readonly QuickRecruitBtn[] = [
    { unitType: UnitTypeId.SAPPER, count: 4, role: ArmyCorpsRole.SUPPLY_ESCORT, label: '+工兵×4' },
    { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 6, role: ArmyCorpsRole.VANGUARD_CENTER, label: '+刀盾×6' },
    { unitType: UnitTypeId.PIKEMAN, count: 6, role: ArmyCorpsRole.VANGUARD_CENTER, label: '+长枪×6' },
    { unitType: UnitTypeId.COMPOSITE_ARCHER, count: 6, role: ArmyCorpsRole.SIEGE_BATTERY, label: '+弓手×6' },
    { unitType: UnitTypeId.LIGHT_CAVALRY, count: 4, role: ArmyCorpsRole.LEFT_WING, label: '+游骑×4' },
    { unitType: UnitTypeId.GREAT_AXEMAN, count: 5, role: ArmyCorpsRole.RIGHT_WING, label: '+巨斧×5' }
  ];

  aboutToAppear(): void {
    const rawParams: Object | undefined = this.getUIContext().getRouter().getParams();
    if (rawParams !== undefined) {
      const typedParams: RouteLaunchParams = rawParams as RouteLaunchParams;
      if (typedParams.factionId && !this.session.hasActiveCampaign()) {
        this.session.ensureCampaignForFaction(typedParams.factionId, false);
      }
    } else if (!this.session.hasActiveCampaign()) {
      this.session.ensureCampaignForFaction(this.session.getSelectedMenuFaction(), false);
    }

    this.mapRenderer.setStylusPickRadiusPx(
      this.session.getSettingsStore().getEffectiveStylusPickRadiusPx()
    );

    const st: CampaignSaveState = this.session.getCampaignEngine().getState();
    const pFacCfg: FactionStaticConfig | undefined = getFactionConfigById(st.playerFaction);
    if (pFacCfg !== undefined) {
      this.selectedNodeId = pFacCfg.capitalNodeId;
      const capNode: CampaignNodeConfig | undefined = this.findStaticNode(pFacCfg.capitalNodeId);
      if (capNode !== undefined) {
        this.mapRenderer.setCamera(capNode.x, capNode.y, 0.72);
      }
    }
    this.pickDefaultTargetRival(st.playerFaction);
    this.refreshAllUiState();
    this.startMapAnimationLoop();
  }

  onPageShow(): void {
    this.mapRenderer.setStylusPickRadiusPx(
      this.session.getSettingsStore().getEffectiveStylusPickRadiusPx()
    );
    this.refreshAllUiState();
    this.startMapAnimationLoop();
  }

  aboutToDisappear(): void {
    this.stopMapAnimationLoop();
  }

  private startMapAnimationLoop(): void {
    this.stopMapAnimationLoop();
    this.animTimerId = setInterval(() => {
      this.mapRenderer.tickAnimation(0.08);
      this.redrawCampaignCanvas();
    }, 80);
  }

  private stopMapAnimationLoop(): void {
    if (this.animTimerId !== -1) {
      clearInterval(this.animTimerId);
      this.animTimerId = -1;
    }
  }

  private redrawCampaignCanvas(): void {
    if (this.canvasAdapter === null) {
      return;
    }
    const st: CampaignSaveState = this.session.getCampaignEngine().getState();
    const opts: CampaignMapRenderOptions = {
      selectedNodeId: this.selectedNodeId,
      selectedSupplyEval: this.cachedSupplyEval
    };
    this.mapRenderer.render(this.canvasAdapter, st, opts);
  }

  private pickDefaultTargetRival(playerFac: FactionId): void {
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      const fid: FactionId = FACTION_STATIC_CONFIGS[i].id;
      if (fid !== playerFac) {
        this.selectedTargetFaction = fid;
        return;
      }
    }
  }

  private findStaticNode(nodeId: string): CampaignNodeConfig | undefined {
    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      if (CAMPAIGN_MAP_NODES[i].id === nodeId) {
        return CAMPAIGN_MAP_NODES[i];
      }
    }
    return undefined;
  }

  private resolveFactionName(fid: FactionId): string {
    const cfg: FactionStaticConfig | undefined = getFactionConfigById(fid);
    return cfg !== undefined ? cfg.name : fid;
  }

  private refreshAllUiState(): void {
    const eng = this.session.getCampaignEngine();
    const st: CampaignSaveState = eng.getState();
    this.playerFaction = st.playerFaction;
    this.playerFactionName = this.resolveFactionName(st.playerFaction);
    this.turnNumber = st.turnNumber;
    this.controlledCities = eng.countControlledNodes(st.playerFaction);
    this.armyPopUsed = eng.computeArmyPopulationUsed(st.playerFaction);

    const pRuntime: FactionCampaignRuntime | undefined = eng.getFactionRuntime(st.playerFaction);
    if (pRuntime !== undefined) {
      this.gold = Math.floor(pRuntime.gold);
      this.wood = Math.floor(pRuntime.wood);
      this.grain = Math.floor(pRuntime.grain);
      this.credibility = Math.round(pRuntime.credibility);
      this.armyLocationNodeId = pRuntime.armyLocationNodeId;
      this.commanderLevel = pRuntime.commanderLevel;
      this.commanderInjuredTurns = pRuntime.commanderInjuredTurns;
      this.betrayalPenaltyBattles = pRuntime.betrayalMoralePenaltyBattles;
      this.unlockedTechIds = pRuntime.unlockedTechIds.slice();
    }

    this.recentLogs = st.recentLogs.slice(0, 12);

    const vic: CampaignVictoryResult = eng.checkVictoryCondition();
    this.victoryBannerText = vic.kind !== CampaignVictoryKind.ONGOING ? vic.summaryText : '';

    this.refreshSelectedCityDetails();
    this.refreshRivalDiplomacyRows();
    this.refreshPeacePreview();
    this.uiRefreshTick++;
    this.redrawCampaignCanvas();
  }

  private refreshSelectedCityDetails(): void {
    const eng = this.session.getCampaignEngine();
    const st: CampaignSaveState = eng.getState();
    const staticCfg: CampaignNodeConfig | undefined = this.findStaticNode(this.selectedNodeId);
    const runtimeNode: CampaignNodeRuntime | undefined = eng.getNodeRuntime(this.selectedNodeId);
    if (staticCfg === undefined || runtimeNode === undefined) {
      return;
    }

    this.mapRenderer.setSelectedNodeId(staticCfg.id);
    const ownerName: string = this.resolveFactionName(runtimeNode.owner);
    const armyHereTag: string =
      this.armyLocationNodeId === staticCfg.id ? ' · 【我方主力驻扎地】' : '';
    this.selectedCityTitle = `${staticCfg.name} [${staticCfg.regionName}] · 归属：${ownerName}${armyHereTag}`;

    const depotTag: string = staticCfg.isSupplyDepot ? '核心补给仓城' : '前线战略关城';
    const ambushTag: string = runtimeNode.hasAmbushTrap ? ' ｜ 已设【打援伏兵】' : '';
    const moraleDebuff: number = eng.getBesiegedGarrisonMoraleModifier(staticCfg.id);
    const debuffTag: string = moraleDebuff < 0 ? ` ｜ 孤城动摇(${moraleDebuff}士气)` : '';
    this.selectedCityMeta =
      `${depotTag} · 城防Lv.${staticCfg.defenseLevel}(耐久${runtimeNode.defenseHp}) · 守军${runtimeNode.garrisonStrength} ｜ 产金${staticCfg.goldYield}/木${staticCfg.woodYield}/粮${staticCfg.grainYield}${ambushTag}${debuffTag}`;

    const supplyEval: SupplyEvaluationResult = eng
      .getSupplyEngine()
      .evaluateNodeSupply(staticCfg.id, runtimeNode.owner, st.nodes, st.diplomacy);
    this.cachedSupplyEval = supplyEval;

    const hopsStr: string = Number.isFinite(supplyEval.hops) ? `${supplyEval.hops}跳` : '断绝(∞)';
    this.selectedCitySupplyText =
      `BFS粮道：${this.supplyGradeLabel(supplyEval.grade)}（距最近仓城 ${hopsStr} · 维持耗粮倍率 ${supplyEval.upkeepMultiplier}x · 被围回合 ${runtimeNode.isolatedTurns}）`;

    this.selectedNeighborIds = staticCfg.neighbors.slice();
  }

  private supplyGradeLabel(grade: SupplyLineGrade): string {
    switch (grade) {
      case SupplyLineGrade.FULL_SUPPLY:
        return '满额补给(100%)';
      case SupplyLineGrade.EXTENDED_MARCH:
        return '长途远征(耗粮+25%)';
      case SupplyLineGrade.OVEREXTENDED:
        return '孤军悬远(耗粮+50%)';
      case SupplyLineGrade.SEVERED:
        return '粮道断绝·合围孤军!';
      default:
        return '';
    }
  }

  private refreshRivalDiplomacyRows(): void {
    const eng = this.session.getCampaignEngine();
    const st: CampaignSaveState = eng.getState();
    const diplo = eng.getDiplomacyEngine();
    const list: RivalFactionRow[] = [];

    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      const fCfg: FactionStaticConfig = FACTION_STATIC_CONFIGS[i];
      if (fCfg.id === st.playerFaction) {
        continue;
      }
      const relRec: BilateralDiplomacyState | undefined = diplo.getBilateralState(
        st.diplomacy,
        st.playerFaction,
        fCfg.id
      );
      const facRun: FactionCampaignRuntime | undefined = eng.getFactionRuntime(fCfg.id);
      const row: RivalFactionRow = {
        factionId: fCfg.id,
        name: fCfg.name,
        color: fCfg.primaryColor,
        relation: relRec !== undefined ? Math.round(relRec.relation) : 0,
        status: relRec !== undefined ? relRec.status : DiplomaticStatus.NEUTRAL,
        remainingTurns: relRec !== undefined ? relRec.remainingTurns : 0,
        vendettaTurns: relRec !== undefined ? relRec.vendettaLockTurns : 0,
        cityCount: eng.countControlledNodes(fCfg.id),
        isAlive: facRun !== undefined ? facRun.isAlive : false
      };
      list.push(row);
    }
    this.rivalRows = list;
  }

  private buildCurrentPeaceTerms(): PeaceTermsModel {
    const eng = this.session.getCampaignEngine();
    const st: CampaignSaveState = eng.getState();
    const cededList: string[] = [];

    if (this.peaceCityMode === 'cede_own') {
      const ownBorder: string | null = this.pickCedeCandidateCity(st.playerFaction);
      if (ownBorder !== null) {
        cededList.push(ownBorder);
      }
    } else if (this.peaceCityMode === 'demand_enemy') {
      const enemyBorder: string | null = this.pickCedeCandidateCity(this.selectedTargetFaction);
      if (enemyBorder !== null) {
        cededList.push(enemyBorder);
      }
    }

    const terms: PeaceTermsModel = {
      proposer: st.playerFaction,
      target: this.selectedTargetFaction,
      goldIndemnity: this.peaceGoldOffer,
      grainTributePerTurn: this.peaceGrainPerTurn,
      cededNodeIds: cededList,
      truceTurns: this.peaceTruceTurns
    };
    return terms;
  }

  private pickCedeCandidateCity(ownerFac: FactionId): string | null {
    const eng = this.session.getCampaignEngine();
    const st: CampaignSaveState = eng.getState();
    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(ownerFac);
    const capId: string = fCfg !== undefined ? fCfg.capitalNodeId : '';
    for (let i: number = 0; i < st.nodes.length; i++) {
      const n: CampaignNodeRuntime = st.nodes[i];
      if (n.owner === ownerFac && n.nodeId !== capId) {
        return n.nodeId;
      }
    }
    return null;
  }

  private refreshPeacePreview(): void {
    const terms: PeaceTermsModel = this.buildCurrentPeaceTerms();
    const preview: PeaceOfferPreviewBundle = this.session.previewPeaceOffer(terms);
    let tag: string = '预计破裂斥退';
    if (preview.outcomeKind === PeaceOutcomeKind.ACCEPTED) {
      tag = '预计当场签约生效';
    } else if (preview.outcomeKind === PeaceOutcomeKind.COUNTER_OFFER) {
      tag = '预计对方加价反制';
    }
    this.peacePreviewText =
      `估值净分 ${preview.netScore}【${tag}】（厌战${preview.breakdown.warExhaustion} - 敌优${preview.breakdown.battlefieldAdvantage} + 筹码${preview.breakdown.offerValue} + 侧胁${preview.breakdown.thirdPartyThreat} - 信誉折价${preview.breakdown.lowCredibilityPenalty}）`;
  }

  // ==================== 大地图触控、手写笔与缩放交互 ====================

  private handleMapTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    const tx: number = event.touches[0].x;
    const ty: number = event.touches[0].y;
    const isStylus: boolean = event.sourceTool === SourceTool.Pen;

    if (event.type === TouchType.Down) {
      if (this.mapRenderer.handleMinimapTap(tx, ty)) {
        this.isDraggingMap = false;
        this.redrawCampaignCanvas();
        return;
      }
      this.downScreenX = tx;
      this.downScreenY = ty;
      this.lastScreenX = tx;
      this.lastScreenY = ty;
      this.isDraggingMap = true;
      return;
    }

    if (event.type === TouchType.Move && this.isDraggingMap) {
      const dx: number = tx - this.lastScreenX;
      const dy: number = ty - this.lastScreenY;
      this.lastScreenX = tx;
      this.lastScreenY = ty;
      if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) {
        this.mapRenderer.panByScreenDelta(dx, dy);
        this.redrawCampaignCanvas();
      }
      return;
    }

    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const moveSq: number =
        (tx - this.downScreenX) * (tx - this.downScreenX) +
        (ty - this.downScreenY) * (ty - this.downScreenY);
      if (moveSq < 14 * 14) {
        const picked: CampaignNodeConfig | null = this.mapRenderer.pickNodeAtScreenPos(
          tx,
          ty,
          isStylus
        );
        if (picked !== null) {
          this.selectedNodeId = picked.id;
          this.refreshSelectedCityDetails();
          this.redrawCampaignCanvas();
        }
      }
      this.isDraggingMap = false;
    }
  }

  // ==================== 行军、设伏、内政与外交业务操作 ====================

  private executeMarchAction(
    targetNodeId: string,
    preferNight: boolean,
    preferConvoy: boolean,
    confirmedBetrayal: boolean
  ): void {
    const opts: MarchActionOptions = {
      confirmBetrayal: confirmedBetrayal,
      autoDeclareWar: true,
      preferNightRaid: preferNight,
      preferConvoyRaid: preferConvoy
    };
    const res: MarchActionResult = this.session.marchPlayerArmyToNode(targetNodeId, opts);
    if (res.requiresBetrayalConfirmation && res.betrayalAssessment !== null) {
      this.pendingBetrayalMode = 'march';
      this.pendingBetrayalNodeId = targetNodeId;
      this.pendingMarchNightRaid = preferNight;
      this.pendingMarchConvoyRaid = preferConvoy;
      this.pendingBetrayalPrompt = res.betrayalAssessment.explanation;
      this.statusFeedback = '【背盟红线阻断】目标处于条约保护期，请先确认背盟严重后果！';
      return;
    }

    this.pendingBetrayalMode = '';
    this.pendingBetrayalPrompt = '';
    this.statusFeedback = res.message;
    this.refreshAllUiState();

    if (res.battleTriggered && res.battleConfig !== null) {
      this.openBattlePageForCampaign(res.battleConfig.campaignNodeId);
    }
  }

  private openBattlePageForCampaign(nodeId: string): void {
    this.stopMapAnimationLoop();
    const launchParams: RouteLaunchParams = {
      modeKey: 'campaign_battle',
      modeTitle: `战役会战 · ${nodeId}`,
      factionId: this.playerFaction
    };
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/BattlePage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Enter campaign BattlePage warning: %{public}s', JSON.stringify(err));
    });
  }

  private triggerDeclarationOfWar(confirmedBetrayal: boolean): void {
    const assess: BetrayalAssessment = this.session.assessPlayerWarDeclaration(
      this.selectedTargetFaction
    );
    if (assess.isBetrayalTriggered && !confirmedBetrayal) {
      this.pendingBetrayalMode = 'declare_war';
      this.pendingBetrayalTargetFaction = this.selectedTargetFaction;
      this.pendingBetrayalPrompt = assess.explanation;
      this.statusFeedback = '【背盟红线阻断】向盟友/停战国强行宣战将导致信誉崩盘，请二次确认！';
      return;
    }

    this.pendingBetrayalMode = '';
    this.pendingBetrayalPrompt = '';
    const res: WarDeclarationResult = this.session.declarePlayerWar(this.selectedTargetFaction);
    this.statusFeedback = res.message;
    this.refreshAllUiState();
  }

  private executePeaceSubmission(termsToSubmit: PeaceOfferTerms): void {
    const execRes: PeaceExecutionResult = this.session.submitPeaceOffer(termsToSubmit);
    this.statusFeedback = execRes.evaluation.explanation;
    if (
      execRes.evaluation.kind === PeaceOutcomeKind.COUNTER_OFFER &&
      execRes.evaluation.counterTerms !== null
    ) {
      const ct: PeaceOfferTerms = execRes.evaluation.counterTerms;
      this.counterOfferPending = ct;
      this.counterOfferSummary =
        `对方反报价：赔款 ${ct.goldIndemnity} 金 · 每回合纳粮 ${ct.grainTributePerTurn} · 割城 ${ct.cededNodeIds.length} 座 · 停战 ${ct.truceTurns} 回合`;
    } else {
      this.counterOfferPending = null;
      this.counterOfferSummary = '';
    }
    this.refreshAllUiState();
  }

  private tryEstablishVassalWithSelected(): void {
    const eng = this.session.getCampaignEngine();
    const targetCities: number = eng.countControlledNodes(this.selectedTargetFaction);
    const playerCities: number = eng.countControlledNodes(this.playerFaction);
    let res: DiplomaticActionResult;
    if (targetCities === 1 && playerCities > 1) {
      res = this.session.establishCampaignVassalage(this.selectedTargetFaction, this.playerFaction);
    } else if (playerCities === 1 && targetCities > 1) {
      res = this.session.establishCampaignVassalage(this.playerFaction, this.selectedTargetFaction);
    } else {
      this.statusFeedback = `朝贡附庸需弱小方仅存最后 1 座孤城（当前对方 ${targetCities} 城，我方 ${playerCities} 城）。`;
      return;
    }
    this.statusFeedback = res.message;
    this.refreshAllUiState();
  }

  private trySowDiscordAgainstSelected(): void {
    const eng = this.session.getCampaignEngine();
    const st: CampaignSaveState = eng.getState();
    const diplo = eng.getDiplomacyEngine();
    let bestPartner: FactionId | null = null;
    let bestRel: number = -999;

    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      const cand: FactionId = FACTION_STATIC_CONFIGS[i].id;
      if (cand === st.playerFaction || cand === this.selectedTargetFaction) {
        continue;
      }
      const r: number = diplo.getRelation(st.diplomacy, this.selectedTargetFaction, cand);
      if (r > bestRel) {
        bestRel = r;
        bestPartner = cand;
      }
    }
    if (bestPartner === null) {
      return;
    }
    const res: DiplomaticActionResult = this.session.sowPlayerDiscord(
      this.selectedTargetFaction,
      bestPartner,
      180
    );
    this.statusFeedback = res.message;
    this.refreshAllUiState();
  }

  private tryMediateAlliedWar(): void {
    const eng = this.session.getCampaignEngine();
    const st: CampaignSaveState = eng.getState();
    const diplo = eng.getDiplomacyEngine();
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      const third: FactionId = FACTION_STATIC_CONFIGS[i].id;
      if (third === st.playerFaction || third === this.selectedTargetFaction) {
        continue;
      }
      if (
        diplo.areAllied(st.diplomacy, st.playerFaction, this.selectedTargetFaction) &&
        diplo.areAllied(st.diplomacy, st.playerFaction, third) &&
        diplo.getStatus(st.diplomacy, this.selectedTargetFaction, third) === DiplomaticStatus.WAR
      ) {
        const res: DiplomaticActionResult = this.session.mediateDoubleAlliance(
          this.selectedTargetFaction,
          third
        );
        this.statusFeedback = res.message;
        this.refreshAllUiState();
        return;
      }
    }
    this.statusFeedback = '当前未检测到与我方共同结盟且彼此交战的两大盟国。';
  }

  private advanceNextTurn(): void {
    const report: CampaignTurnAdvanceReport = this.session.advanceCampaignTurnWithAi();
    const severedWarn: string =
      report.emergencySeveredNodes.length > 0
        ? ` ｜ 断粮预警城关 ${report.emergencySeveredNodes.length} 座！`
        : '';
    this.statusFeedback = `已推进至第 ${report.newTurnNumber} 回合（7国AI完成战略演化，自动存档已更新）${severedWarn}`;
    this.counterOfferPending = null;
    this.refreshAllUiState();
  }

  private quickSaveSlotOne(): void {
    const res: SaveWriteResult = this.session.saveCurrentCampaignToSlot(SaveManager.MIN_MANUAL_SLOT);
    this.statusFeedback = res.message;
  }

  private openSavePage(): void {
    this.stopMapAnimationLoop();
    const launchParams: RouteLaunchParams = {
      modeKey: 'save',
      modeTitle: '战役存档管理',
      factionId: this.playerFaction
    };
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/SavePage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Open SavePage warning: %{public}s', JSON.stringify(err));
    });
  }

  private goBackToMenu(): void {
    this.stopMapAnimationLoop();
    this.getUIContext().getRouter().back();
  }

  private diplomaticStatusLabel(status: DiplomaticStatus, turns: number): string {
    switch (status) {
      case DiplomaticStatus.WAR:
        return '交战中';
      case DiplomaticStatus.TRUCE:
        return `停火(${turns}回合)`;
      case DiplomaticStatus.NEUTRAL:
        return '中立';
      case DiplomaticStatus.NON_AGGRESSION:
        return `互不侵犯(${turns}回合)`;
      case DiplomaticStatus.TRADE_PACT:
        return '丝路通商';
      case DiplomaticStatus.ALLIANCE:
        return '军事同盟(借道)';
      case DiplomaticStatus.VASSAL:
        return `朝贡附庸(${turns}回合)`;
      default:
        return status;
    }
  }

  private currentPlayerTechList(): readonly FactionTechItem[] {
    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(this.playerFaction);
    return fCfg !== undefined ? fCfg.uniqueTechs : [];
  }

  private getNodeShortName(nodeId: string): string {
    const cfg: CampaignNodeConfig | undefined = this.findStaticNode(nodeId);
    return cfg !== undefined ? cfg.name : nodeId;
  }

  build() {
    Column({ space: 8 }) {
      // ==================== 顶部平板宽幅战略态势条（按钮全部 >= 48vp） ====================
      Row({ space: 8 }) {
        Button('‹ 主菜单')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 14, right: 14 })
          .fontSize(13)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.goBackToMenu();
          })

        Column({ space: 2 }) {
          Text(`${this.playerFactionName} · 第${this.turnNumber}回合 ｜ 城关 ${this.controlledCities}/40(78路) ｜ 统帅Lv.${this.commanderLevel}${this.commanderInjuredTurns > 0 ? `(养伤${this.commanderInjuredTurns}回)` : ''}`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#D4A843')
          Text(`金 ${this.gold} · 木 ${this.wood} · 粮 ${this.grain} ｜ 外交信誉 ${this.credibility} ｜ 野战军人口 ${this.armyPopUsed}/${GameConstants.DEFAULT_ARMY_POP_CAP}（驻扎：${this.getNodeShortName(this.armyLocationNodeId)}）`)
            .fontSize(12)
            .fontColor('#ECEFF1')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('速存#1')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 12, right: 12 })
          .fontSize(13)
          .backgroundColor('#2E7D32')
          .onClick(() => {
            this.quickSaveSlotOne();
          })

        Button('存/读档')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 12, right: 12 })
          .fontSize(13)
          .backgroundColor('#37474F')
          .onClick(() => {
            this.openSavePage();
          })

        Button('推进下一回合 ›')
          .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
          .padding({ left: 18, right: 18 })
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#B71C1C')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.advanceNextTurn();
          })
      }
      .width('100%')

      // ==================== 主体 MatePad 横屏左右双栏（左栏 36% 操控信息 + 右栏 64% 大地图主视口） ====================
      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        // 左栏（36%）：城关行军 / 外交纵横 / 整军科技
        Column({ space: 8 }) {
          Row({ space: 6 }) {
            Button('城关与行军')
              .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
              .layoutWeight(1)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.leftTab === 'city' ? '#6D4C41' : '#26201E')
              .fontColor('#FFF8E1')
              .onClick(() => {
                this.leftTab = 'city';
              })

            Button('外交纵横')
              .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
              .layoutWeight(1)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.leftTab === 'diplomacy' ? '#0D47A1' : '#26201E')
              .fontColor('#FFF8E1')
              .onClick(() => {
                this.leftTab = 'diplomacy';
                this.refreshRivalDiplomacyRows();
                this.refreshPeacePreview();
              })

            Button('整军与科技')
              .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
              .layoutWeight(1)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.leftTab === 'army' ? '#2E7D32' : '#26201E')
              .fontColor('#FFF8E1')
              .onClick(() => {
                this.leftTab = 'army';
              })
          }
          .width('100%')

          // 背盟二次确认强阻断弹卡（DESIGN.md 10.3）
          if (this.pendingBetrayalMode.length > 0) {
            Column({ space: 6 }) {
              Text('⚠ 背盟毁约二次确认警告！')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FF5252')
              Text(this.pendingBetrayalPrompt)
                .fontSize(12)
                .fontColor('#FFCDD2')
              Row({ space: 8 }) {
                Button('悬崖勒马·取消')
                  .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                  .layoutWeight(1)
                  .fontSize(12)
                  .backgroundColor('#37474F')
                  .onClick(() => {
                    this.pendingBetrayalMode = '';
                    this.pendingBetrayalPrompt = '';
                  })

                Button('执意背盟强攻!')
                  .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                  .layoutWeight(1)
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .backgroundColor('#D50000')
                  .fontColor('#FFFFFF')
                  .onClick(() => {
                    if (this.pendingBetrayalMode === 'march') {
                      this.executeMarchAction(
                        this.pendingBetrayalNodeId,
                        this.pendingMarchNightRaid,
                        this.pendingMarchConvoyRaid,
                        true
                      );
                    } else if (this.pendingBetrayalMode === 'declare_war') {
                      this.triggerDeclarationOfWar(true);
                    }
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(10)
            .backgroundColor('#3B1212')
            .borderRadius(8)
            .border({ width: 1.5, color: '#FF5252' })
          }

          Scroll() {
            Column({ space: 8 }) {
              if (this.leftTab === 'city') {
                Text(this.selectedCityTitle)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFD54F')

                Text(this.selectedCityMeta)
                  .fontSize(12)
                  .fontColor('#ECEFF1')
                  .lineHeight(18)

                Text(this.selectedCitySupplyText)
                  .fontSize(12)
                  .fontColor('#81C784')
                  .lineHeight(18)

                Row({ space: 8 }) {
                  Button('定位主力驻地')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#37474F')
                    .onClick(() => {
                      this.selectedNodeId = this.armyLocationNodeId;
                      const cfg: CampaignNodeConfig | undefined = this.findStaticNode(this.armyLocationNodeId);
                      if (cfg !== undefined) {
                        this.mapRenderer.setCamera(cfg.x, cfg.y);
                      }
                      this.refreshSelectedCityDetails();
                      this.redrawCampaignCanvas();
                    })

                  Button('挥师行军 / 攻打此城 ›')
                    .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                    .layoutWeight(2)
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .backgroundColor('#B71C1C')
                    .fontColor('#FFFFFF')
                    .onClick(() => {
                      this.executeMarchAction(this.selectedNodeId, false, false, false);
                    })
                }
                .width('100%')

                Row({ space: 6 }) {
                  Button('黑夜劫营夜袭')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#4A148C')
                    .onClick(() => {
                      this.executeMarchAction(this.selectedNodeId, true, false, false);
                    })

                  Button('奇袭断粮战')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#E65100')
                    .onClick(() => {
                      this.executeMarchAction(this.selectedNodeId, false, true, false);
                    })
                }
                .width('100%')

                Row({ space: 6 }) {
                  Button('设【围点打援】伏兵')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#1B5E20')
                    .onClick(() => {
                      const res: CampaignOperationResult = this.session.setupPlayerReliefAmbush(
                        this.selectedNodeId
                      );
                      this.statusFeedback = res.message;
                      this.refreshAllUiState();
                    })

                  Button('迎击驰援敌军(打援)')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#00695C')
                    .onClick(() => {
                      if (this.session.launchCampaignReliefAmbushBattle(this.selectedNodeId)) {
                        this.openBattlePageForCampaign(this.selectedNodeId);
                      } else {
                        this.statusFeedback = '需先在紧邻敌城的前线本方节点布设【围点打援】伏击圈！';
                      }
                    })
                }
                .width('100%')

                Text('直通道路相邻城关（点击快速切换检阅）：')
                  .fontSize(12)
                  .fontColor('#B0BEC5')

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.selectedNeighborIds, (nbrId: string) => {
                    Button(this.getNodeShortName(nbrId))
                      .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                      .margin({ right: 6, bottom: 6 })
                      .padding({ left: 12, right: 12 })
                      .fontSize(12)
                      .backgroundColor('#2C2522')
                      .fontColor('#FFE082')
                      .onClick(() => {
                        this.selectedNodeId = nbrId;
                        const cfg: CampaignNodeConfig | undefined = this.findStaticNode(nbrId);
                        if (cfg !== undefined) {
                          this.mapRenderer.setCamera(cfg.x, cfg.y);
                        }
                        this.refreshSelectedCityDetails();
                        this.redrawCampaignCanvas();
                      })
                  }, (nbrId: string) => nbrId)
                }
                .width('100%')
              } else if (this.leftTab === 'diplomacy') {
                Text('点选目标诸侯遣使（结盟共享粮道 / 量化议和 / 背盟重罚）：')
                  .fontSize(12)
                  .fontColor('#B0BEC5')

                ForEach(this.rivalRows, (rv: RivalFactionRow) => {
                  Row({ space: 8 }) {
                    Row()
                      .width(6)
                      .height(34)
                      .borderRadius(3)
                      .backgroundColor(rv.color)
                    Column({ space: 2 }) {
                      Text(`${rv.name}（${rv.cityCount}城） · ${this.diplomaticStatusLabel(rv.status, rv.remainingTurns)}`)
                        .fontSize(13)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#FFF8E1')
                      Text(`好感 ${rv.relation >= 0 ? '+' : ''}${rv.relation}${rv.vendettaTurns > 0 ? ` · 血海世仇锁${rv.vendettaTurns}回!` : ''}`)
                        .fontSize(11)
                        .fontColor(rv.relation >= 25 ? '#81C784' : (rv.relation < 0 ? '#FF8A80' : '#B0BEC5'))
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                  }
                  .width('100%')
                  .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })
                  .padding(8)
                  .backgroundColor(this.selectedTargetFaction === rv.factionId ? '#3E2E28' : '#232020')
                  .borderRadius(8)
                  .border({
                    width: 1.5,
                    color: this.selectedTargetFaction === rv.factionId ? '#D4A843' : '#332C2A'
                  })
                  .onClick(() => {
                    this.selectedTargetFaction = rv.factionId;
                    this.counterOfferPending = null;
                    this.refreshPeacePreview();
                  })
                }, (rv: RivalFactionRow) => `${rv.factionId}_${rv.status}_${rv.relation}_${rv.cityCount}`)

                // 外交条约与谋略大按钮网格（>= 48vp）
                Row({ space: 6 }) {
                  Button('正式宣战')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#B71C1C')
                    .onClick(() => {
                      this.triggerDeclarationOfWar(false);
                    })
                  Button('互不侵犯')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#37474F')
                    .onClick(() => {
                      const r: DiplomaticActionResult = this.session.signPlayerNonAggression(
                        this.selectedTargetFaction
                      );
                      this.statusFeedback = r.message;
                      this.refreshAllUiState();
                    })
                  Button('丝路通商')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#8D6E63')
                    .onClick(() => {
                      const r: DiplomaticActionResult = this.session.signPlayerTradePact(
                        this.selectedTargetFaction
                      );
                      this.statusFeedback = r.message;
                      this.refreshAllUiState();
                    })
                }
                .width('100%')

                Row({ space: 6 }) {
                  Button('军事同盟')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#1565C0')
                    .onClick(() => {
                      const r: DiplomaticActionResult = this.session.formPlayerAlliance(
                        this.selectedTargetFaction
                      );
                      this.statusFeedback = r.message;
                      this.refreshAllUiState();
                    })
                  Button('馈赠(120金)')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#2E7D32')
                    .onClick(() => {
                      const r: DiplomaticActionResult = this.session.sendPlayerGift(
                        this.selectedTargetFaction,
                        120,
                        60
                      );
                      this.statusFeedback = r.message;
                      this.refreshAllUiState();
                    })
                  Button('朝贡附庸')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#6A1B9A')
                    .onClick(() => {
                      this.tryEstablishVassalWithSelected();
                    })
                }
                .width('100%')

                Row({ space: 6 }) {
                  Button('密使挑拨敌盟(-20)')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#4E342E')
                    .onClick(() => {
                      this.trySowDiscordAgainstSelected();
                    })
                  Button('双盟居中调停(停火3回)')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#00695C')
                    .onClick(() => {
                      this.tryMediateAlliedWar();
                    })
                }
                .width('100%')

                // 停火媾和量化筹码谈判台
                Column({ space: 6 }) {
                  Text(`停火媾和筹码台（对【${this.resolveFactionName(this.selectedTargetFaction)}】，正数献礼/负数索取）`)
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#FFD54F')

                  Row({ space: 6 }) {
                    Button('金-100')
                      .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                      .fontSize(11)
                      .backgroundColor('#2E2623')
                      .onClick(() => {
                        this.peaceGoldOffer = Math.max(-400, this.peaceGoldOffer - 100);
                        this.refreshPeacePreview();
                      })
                    Text(`赔款:${this.peaceGoldOffer}金`)
                      .fontSize(12)
                      .fontColor('#FFE082')
                      .layoutWeight(1)
                      .textAlign(TextAlign.Center)
                    Button('金+100')
                      .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                      .fontSize(11)
                      .backgroundColor('#2E2623')
                      .onClick(() => {
                        this.peaceGoldOffer = Math.min(900, this.peaceGoldOffer + 100);
                        this.refreshPeacePreview();
                      })
                  }
                  .width('100%')

                  Row({ space: 6 }) {
                    Button('粮-30/回')
                      .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                      .fontSize(11)
                      .backgroundColor('#2E2623')
                      .onClick(() => {
                        this.peaceGrainPerTurn = Math.max(-90, this.peaceGrainPerTurn - 30);
                        this.refreshPeacePreview();
                      })
                    Text(`岁粮:${this.peaceGrainPerTurn}/回`)
                      .fontSize(12)
                      .fontColor('#FFE082')
                      .layoutWeight(1)
                      .textAlign(TextAlign.Center)
                    Button('粮+30/回')
                      .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                      .fontSize(11)
                      .backgroundColor('#2E2623')
                      .onClick(() => {
                        this.peaceGrainPerTurn = Math.min(180, this.peaceGrainPerTurn + 30);
                        this.refreshPeacePreview();
                      })
                  }
                  .width('100%')

                  Row({ space: 6 }) {
                    Button(`停战:${this.peaceTruceTurns}回 ↻`)
                      .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                      .layoutWeight(1)
                      .fontSize(12)
                      .backgroundColor('#263238')
                      .onClick(() => {
                        this.peaceTruceTurns =
                          this.peaceTruceTurns === 5 ? 8 : (this.peaceTruceTurns === 8 ? 12 : 5);
                        this.refreshPeacePreview();
                      })

                    Button(
                      this.peaceCityMode === 'none'
                        ? '领土:不割城 ↻'
                        : (this.peaceCityMode === 'cede_own' ? '领土:割1边城 ↻' : '领土:索敌1城 ↻')
                    )
                      .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                      .layoutWeight(1)
                      .fontSize(12)
                      .backgroundColor('#263238')
                      .onClick(() => {
                        this.peaceCityMode =
                          this.peaceCityMode === 'none'
                            ? 'cede_own'
                            : (this.peaceCityMode === 'cede_own' ? 'demand_enemy' : 'none');
                        this.refreshPeacePreview();
                      })
                  }
                  .width('100%')

                  Text(this.peacePreviewText)
                    .fontSize(11)
                    .fontColor('#81D4FA')
                    .lineHeight(16)

                  Button('遣使提交停火媾和方案 ›')
                    .width('100%')
                    .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .backgroundColor('#0277BD')
                    .fontColor('#FFFFFF')
                    .onClick(() => {
                      this.executePeaceSubmission(this.buildCurrentPeaceTerms());
                    })

                  if (this.counterOfferPending !== null) {
                    Text(this.counterOfferSummary)
                      .fontSize(11)
                      .fontColor('#FFD54F')
                    Button('接受对方反报价立即签约!')
                      .width('100%')
                      .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                      .fontSize(13)
                      .fontWeight(FontWeight.Bold)
                      .backgroundColor('#2E7D32')
                      .fontColor('#FFFFFF')
                      .onClick(() => {
                        if (this.counterOfferPending !== null) {
                          this.executePeaceSubmission(this.counterOfferPending);
                        }
                      })
                  }
                }
                .width('100%')
                .padding(10)
                .backgroundColor('#221E1D')
                .borderRadius(8)
              } else {
                // 整军募兵、专属三阶科技与战略编年日志
                Text(`野战主力募兵（人口 ${this.armyPopUsed}/240${this.betrayalPenaltyBattles > 0 ? ` · 背盟动摇余${this.betrayalPenaltyBattles}战` : ''}）`)
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFD54F')

                if (this.playerFaction === FactionId.SHAMO) {
                  Button(
                    this.useShamoGoldContract
                      ? '沙漠商盟：纯金币雇佣契约 [已开启]'
                      : '沙漠商盟：常规金木粮征募 [点此切纯金雇佣]'
                  )
                    .width('100%')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .fontSize(12)
                    .backgroundColor('#F9A825')
                    .fontColor('#141110')
                    .onClick(() => {
                      this.useShamoGoldContract = !this.useShamoGoldContract;
                    })
                }

                Grid() {
                  ForEach(this.quickRecruits, (qr: QuickRecruitBtn) => {
                    GridItem() {
                      Button(qr.label)
                        .width('100%')
                        .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                        .fontSize(12)
                        .backgroundColor('#2E2623')
                        .fontColor('#FFF8E1')
                        .onClick(() => {
                          const res: CampaignOperationResult = this.session.recruitCampaignArmy(
                            qr.unitType,
                            qr.count,
                            qr.role,
                            this.useShamoGoldContract
                          );
                          this.statusFeedback = res.message;
                          this.refreshAllUiState();
                        })
                    }
                  }, (qr: QuickRecruitBtn) => qr.label)
                }
                .columnsTemplate('1fr 1fr 1fr')
                .columnsGap(6)
                .rowsGap(6)
                .height(104)
                .width('100%')

                Row({ space: 6 }) {
                  Button('+本国专属王牌×4')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .backgroundColor('#8D3B24')
                    .onClick(() => {
                      const fCfg: FactionStaticConfig | undefined = getFactionConfigById(this.playerFaction);
                      if (fCfg !== undefined) {
                        const res: CampaignOperationResult = this.session.recruitCampaignArmy(
                          fCfg.exclusiveUnitId,
                          4,
                          ArmyCorpsRole.REAR_RESERVE,
                          false
                        );
                        this.statusFeedback = res.message;
                        this.refreshAllUiState();
                      }
                    })

                  Button('+攻城重器×1')
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .layoutWeight(1)
                    .fontSize(12)
                    .backgroundColor('#4E342E')
                    .onClick(() => {
                      const siegeId: UnitTypeId =
                        this.playerFaction === FactionId.CANGLANG
                          ? UnitTypeId.BALLISTA
                          : UnitTypeId.TREBUCHET;
                      const res: CampaignOperationResult = this.session.recruitCampaignArmy(
                        siegeId,
                        1,
                        ArmyCorpsRole.SIEGE_BATTERY,
                        this.useShamoGoldContract
                      );
                      this.statusFeedback = res.message;
                      this.refreshAllUiState();
                    })
                }
                .width('100%')

                Text('本国三阶专属科技研发：')
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#81C784')

                ForEach(this.currentPlayerTechList(), (tech: FactionTechItem) => {
                  Row({ space: 8 }) {
                    Column({ space: 2 }) {
                      Text(`《${tech.name}》（金${tech.cost.gold}/木${tech.cost.wood}/粮${tech.cost.grain}）`)
                        .fontSize(13)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#FFF8E1')
                      Text(tech.effectSummary)
                        .fontSize(11)
                        .fontColor('#B0BEC5')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)

                    Button(this.unlockedTechIds.indexOf(tech.id) >= 0 ? '已掌握' : '研发')
                      .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                      .fontSize(12)
                      .backgroundColor(
                        this.unlockedTechIds.indexOf(tech.id) >= 0 ? '#2E7D32' : '#0277BD'
                      )
                      .onClick(() => {
                        const res: CampaignOperationResult = this.session.unlockPlayerTech(tech.id);
                        this.statusFeedback = res.message;
                        this.refreshAllUiState();
                      })
                  }
                  .width('100%')
                  .padding(8)
                  .backgroundColor('#232020')
                  .borderRadius(8)
                }, (tech: FactionTechItem) => `${tech.id}_${this.uiRefreshTick}`)

                Text('近期天下军情编年录：')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFD54F')

                ForEach(this.recentLogs, (logLine: string, idx: number) => {
                  Text(`• ${logLine}`)
                    .fontSize(11)
                    .fontColor('#CFD8DC')
                    .width('100%')
                }, (logLine: string, idx: number) => `${idx}_${logLine}`)
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .layoutWeight(1)
          .width('100%')

          Text(this.statusFeedback)
            .fontSize(11)
            .fontColor('#FFE082')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding(8)
            .backgroundColor('#261F1B')
            .borderRadius(6)
        }
        .width(this.isWideScreen ? '36%' : '100%')
        .height(this.isWideScreen ? '100%' : '48%')
        .padding(10)
        .backgroundColor('#1A1514')
        .borderRadius(10)

        // ==================== 右栏（64%）：3600×2400 战略大地图 40城78路 Canvas 主视口 ====================
        Stack({ alignContent: Alignment.Center }) {
          Canvas(this.canvasContext)
            .width('100%')
            .height('100%')
            .backgroundColor('#182026')
            .borderRadius(10)
            .onReady(() => {
              this.canvasAdapter = new ArkCanvas2DAdapter(this.canvasContext);
              const cw: number = this.canvasContext.width;
              const ch: number = this.canvasContext.height;
              if (cw > 0 && ch > 0) {
                this.mapRenderer.setViewportSize(cw, ch);
              }
              this.redrawCampaignCanvas();
            })
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              const nw: number = Number(newArea.width);
              const nh: number = Number(newArea.height);
              if (nw > 0 && nh > 0) {
                this.mapRenderer.setViewportSize(nw, nh);
                this.redrawCampaignCanvas();
              }
            })
            .onTouch((event: TouchEvent) => {
              this.handleMapTouch(event);
            })
            .gesture(
              PinchGesture({ fingers: 2 })
                .onActionStart(() => {
                  this.pinchStartZoom = this.mapRenderer.getZoom();
                })
                .onActionUpdate((ev: GestureEvent) => {
                  this.mapRenderer.zoomAtScreenPoint(
                    this.pinchStartZoom * ev.scale,
                    ev.pinchCenterX,
                    ev.pinchCenterY
                  );
                  this.redrawCampaignCanvas();
                })
            )

          if (this.victoryBannerText.length > 0) {
            Column({ space: 12 }) {
              Text('★ 九州一统 · 战役终局达成 ★')
                .fontSize(24)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFD54F')
              Text(this.victoryBannerText)
                .fontSize(14)
                .fontColor('#FFF8E1')
                .textAlign(TextAlign.Center)
              Button('开启新一轮天下争霸 ›')
                .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                .padding({ left: 24, right: 24 })
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#B71C1C')
                .onClick(() => {
                  this.session.startNewCampaign(this.playerFaction);
                  this.refreshAllUiState();
                })
            }
            .padding(24)
            .backgroundColor('rgba(24, 18, 16, 0.94)')
            .borderRadius(14)
            .border({ width: 2, color: '#D4A843' })
          }
        }
        .width(this.isWideScreen ? '64%' : '100%')
        .height(this.isWideScreen ? '100%' : '52%')
        .margin({ left: this.isWideScreen ? 10 : 0, top: this.isWideScreen ? 0 : 8 })
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
