/**
 * 全局游戏会话与跨页面状态协调中心（GameSessionCoordinator.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 依赖，可在 Node 单测直接驱动全流程验证）
 *
 * 核心职责：
 * 1. 打通【主菜单 -> 战前整军（遭遇战/守城/自定义） -> 真实冷兵器大战 -> 战后结算】完整闭环；
 * 2. 打通【主菜单/读档 -> 40城78路战略大地图 -> 外交谈判/背盟确认/内政科技/行军伏击 -> 真实战场 -> 战俘处置回写 -> AI 回合演化 -> 自动/手动存档】完整闭环；
 * 3. 统一托管 SaveManager（6 槽离线存档）与 SettingsStore（平板帧率、LOD、M-Pencil 手写笔、左右手摇杆配置）。
 */
import { GameConstants } from '../../common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../../config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../../config/FactionConfig';
import { getUnitConfigById, UNIT_STATIC_CONFIGS } from '../../config/UnitConfig';
import {
  CampaignNodeConfig,
  CampaignNodeType,
  FactionStaticConfig,
  PeaceOfferTerms,
  SaveSlotSummary,
  UnitStaticStats
} from '../../model/GameTypes';
import {
  ArmyCorpsRole,
  BattleHudSnapshot,
  BattleInitConfig,
  BattleOutcomeReason,
  BattleScenarioType,
  BattleSettlementSummary,
  BattleSide,
  BetrayalAssessment,
  CampaignNodeRuntime,
  CampaignSaveState,
  DiplomaticStatus,
  FactionCampaignRuntime,
  FactionId,
  HeroSkillId,
  RosterEntry,
  TerrainType,
  UnitTypeId,
  WeatherType
} from '../CoreContracts';
import { AiBattleDecisionBatch, BattleTacticalAI } from '../ai/BattleTacticalAI';
import {
  CampaignStrategicAI,
  StrategicActionType,
  StrategicTurnAction
} from '../ai/CampaignStrategicAI';
import {
  CampaignEngine,
  CampaignOperationResult,
  CampaignTurnAdvanceReport,
  MarchActionOptions,
  MarchActionResult,
  PrisonerDisposition,
  SettlementApplyReport
} from '../campaign/CampaignEngine';
import { BattleSimulator } from '../combat/BattleSimulator';
import {
  DiplomaticActionResult,
  PeaceExecutionResult,
  PeaceScoreBreakdown,
  WarDeclarationContext,
  WarDeclarationResult
} from '../diplomacy/DiplomacyEngine';
import {
  InMemoryPersistenceBackend,
  PersistenceBackendAdapter,
  SaveLoadResult,
  SaveManager,
  SaveWriteResult
} from '../../storage/SaveManager';
import { SettingsStore } from '../../storage/SettingsStore';

/** 战前整军可变草稿状态（支撑遭遇战、守城挑战、自定义沙盒） */
export interface SetupDraftState {
  modeKey: string;
  modeTitle: string;
  scenarioType: BattleScenarioType;
  playerFaction: FactionId;
  enemyFaction: FactionId;
  terrain: TerrainType;
  weather: WeatherType;
  initialGrain: number;
  siegeHoldDurationSec: number;
  playerRoster: RosterEntry[];
}

/** 媾和实时预览复合结果 */
export interface PeaceOfferPreviewBundle {
  readonly breakdown: PeaceScoreBreakdown;
  readonly netScore: number;
  readonly outcomeKind: string;
  readonly explanation: string;
  readonly counterTerms: PeaceOfferTerms | null;
}

/** 统帅累计战绩统计面板数据 */
export interface HallOfFameStats {
  readonly activeCampaignTurn: number;
  readonly activeCampaignFaction: FactionId;
  readonly activeControlledCities: number;
  readonly activeControlledCapitals: number;
  readonly totalBattlesFought: number;
  readonly totalBattlesWon: number;
  readonly totalEnemiesKilled: number;
  readonly standaloneBattlesFought: number;
  readonly standaloneBattlesWon: number;
  readonly standaloneHeroKills: number;
}

export class GameSessionCoordinator {
  private static singletonInstance: GameSessionCoordinator | null = null;

  public static getInstance(): GameSessionCoordinator {
    if (GameSessionCoordinator.singletonInstance === null) {
      GameSessionCoordinator.singletonInstance = new GameSessionCoordinator();
    }
    return GameSessionCoordinator.singletonInstance;
  }

  private persistenceBackend: PersistenceBackendAdapter;
  private readonly saveManager: SaveManager;
  private readonly settingsStore: SettingsStore;
  private readonly campaignEngine: CampaignEngine;
  private readonly campaignAi: CampaignStrategicAI;

  private selectedMenuFaction: FactionId = FactionId.YANLONG;
  private hasInitializedCampaign: boolean = false;
  private setupDraft: SetupDraftState;

  private activeBattleSim: BattleSimulator | null = null;
  private activeBattleAi: BattleTacticalAI | null = null;
  private activeBattleFromCampaign: boolean = false;
  private lastAiDoctrine: string = 'PINNING_PINCER_ENCIRCLE';
  private lastAiSiegePhase: string = 'NONE';

  private pendingSettlement: BattleSettlementSummary | null = null;
  private pendingSettlementFromCampaign: boolean = false;
  private pendingSettlementApplied: boolean = false;
  private lastCampaignSettlementReport: SettlementApplyReport | null = null;

  private standaloneBattlesFought: number = 0;
  private standaloneBattlesWon: number = 0;
  private standaloneHeroKills: number = 0;

  public constructor(backend?: PersistenceBackendAdapter) {
    this.persistenceBackend = backend !== undefined ? backend : new InMemoryPersistenceBackend();
    this.saveManager = new SaveManager(this.persistenceBackend);
    this.settingsStore = new SettingsStore(this.persistenceBackend);
    this.campaignEngine = new CampaignEngine(FactionId.YANLONG);
    this.campaignAi = new CampaignStrategicAI();
    this.setupDraft = this.buildDefaultSetupDraft('skirmish', '遭遇战', FactionId.YANLONG);
  }

  /** 绑定 HarmonyOS 应用沙箱离线文件持久化后端 */
  public bindPersistenceBackend(backend: PersistenceBackendAdapter): void {
    this.persistenceBackend = backend;
    this.saveManager.setBackend(backend);
    this.settingsStore.setBackend(backend);
    // 若槽位 0 已有合法自动存档且当前尚未手动开启战役，自动静默恢复供主菜单“继续战役”使用
    if (!this.hasInitializedCampaign) {
      const autoLoaded: SaveLoadResult = this.saveManager.loadFromSlot(SaveManager.AUTO_SAVE_SLOT, true);
      if (autoLoaded.success && autoLoaded.state !== null) {
        this.campaignEngine.loadFromSaveState(autoLoaded.state);
        this.selectedMenuFaction = autoLoaded.state.playerFaction;
        this.hasInitializedCampaign = true;
      }
    }
  }

  public getSaveManager(): SaveManager {
    return this.saveManager;
  }

  public getSettingsStore(): SettingsStore {
    return this.settingsStore;
  }

  public getCampaignEngine(): CampaignEngine {
    return this.campaignEngine;
  }

  public getSelectedMenuFaction(): FactionId {
    return this.selectedMenuFaction;
  }

  public setSelectedMenuFaction(factionId: FactionId): void {
    this.selectedMenuFaction = factionId;
  }

  public hasActiveCampaign(): boolean {
    return this.hasInitializedCampaign;
  }

  // ==================== 1. 战前整军（遭遇战 / 守城挑战 / 自定义沙盒） ====================

  public prepareSetupForMode(modeKey: string, modeTitle: string, playerFaction: FactionId): SetupDraftState {
    this.selectedMenuFaction = playerFaction;
    this.setupDraft = this.buildDefaultSetupDraft(modeKey, modeTitle, playerFaction);
    return this.setupDraft;
  }

  public getSetupDraft(): SetupDraftState {
    return this.setupDraft;
  }

  public canUnitBeRecruitedByFaction(factionId: FactionId, unitType: UnitTypeId): boolean {
    const stats: UnitStaticStats | undefined = getUnitConfigById(unitType);
    if (stats === undefined) {
      return false;
    }
    if (stats.exclusiveFaction !== null && stats.exclusiveFaction !== factionId) {
      return false;
    }
    if (factionId === FactionId.CANGLANG && unitType === UnitTypeId.TREBUCHET) {
      return false;
    }
    return true;
  }

  public setSetupPlayerFaction(factionId: FactionId): void {
    this.setupDraft.playerFaction = factionId;
    if (this.setupDraft.enemyFaction === factionId) {
      this.setupDraft.enemyFaction = this.pickDefaultRivalFaction(factionId);
    }
    // 清理不兼容的前任势力专属兵种或苍狼投石车，并用新势力预设补齐为空时的军团
    const cleaned: RosterEntry[] = [];
    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(factionId);
    for (let i: number = 0; i < this.setupDraft.playerRoster.length; i++) {
      const item: RosterEntry = this.setupDraft.playerRoster[i];
      if (this.canUnitBeRecruitedByFaction(factionId, item.unitType)) {
        cleaned.push(item);
      } else if (fCfg !== undefined && getUnitConfigById(item.unitType)?.exclusiveFaction !== null) {
        const replaced: RosterEntry = {
          unitType: fCfg.exclusiveUnitId,
          count: item.count,
          corpsRole: item.corpsRole
        };
        cleaned.push(replaced);
      }
    }
    if (cleaned.length === 0) {
      this.setupDraft.playerRoster = this.buildPresetArmyRoster(factionId, 'balanced');
    } else {
      this.setupDraft.playerRoster = cleaned;
    }
  }

  public setSetupEnemyFaction(factionId: FactionId): void {
    this.setupDraft.enemyFaction = factionId;
  }

  public setSetupScenarioType(scenarioType: BattleScenarioType): void {
    this.setupDraft.scenarioType = scenarioType;
    if (
      scenarioType === BattleScenarioType.SIEGE_ASSAULT ||
      scenarioType === BattleScenarioType.SIEGE_DEFENSE
    ) {
      this.setupDraft.terrain = TerrainType.FORT_WALL;
    } else if (scenarioType === BattleScenarioType.NIGHT_RAID) {
      this.setupDraft.weather = WeatherType.NIGHT;
    }
  }

  public setSetupTerrain(terrain: TerrainType): void {
    this.setupDraft.terrain = terrain;
  }

  public setSetupWeather(weather: WeatherType): void {
    this.setupDraft.weather = weather;
  }

  public setSetupInitialGrain(grain: number): void {
    const safeGrain: number = Math.max(300, Math.min(3000, Math.round(grain)));
    this.setupDraft.initialGrain = safeGrain;
  }

  public setSetupSiegeDurationSec(durationSec: number): void {
    this.setupDraft.siegeHoldDurationSec = Math.max(90, Math.min(360, Math.round(durationSec)));
  }

  public computeRosterPopulation(roster: readonly RosterEntry[]): number {
    let used: number = 0;
    for (let i: number = 0; i < roster.length; i++) {
      const entry: RosterEntry = roster[i];
      const st: UnitStaticStats | undefined = getUnitConfigById(entry.unitType);
      const popPer: number = st !== undefined ? st.popCap : 1;
      used += entry.count * popPer;
    }
    return used;
  }

  public computeSetupPlayerPopUsed(): number {
    return this.computeRosterPopulation(this.setupDraft.playerRoster);
  }

  public computeSetupPlayerTotalSoldiers(): number {
    let sum: number = 0;
    for (let i: number = 0; i < this.setupDraft.playerRoster.length; i++) {
      sum += this.setupDraft.playerRoster[i].count;
    }
    return sum;
  }

  public getSetupUnitCountInCorps(unitType: UnitTypeId, corpsRole: ArmyCorpsRole): number {
    for (let i: number = 0; i < this.setupDraft.playerRoster.length; i++) {
      const entry: RosterEntry = this.setupDraft.playerRoster[i];
      if (entry.unitType === unitType && entry.corpsRole === corpsRole) {
        return entry.count;
      }
    }
    return 0;
  }

  public adjustSetupUnitCount(
    unitType: UnitTypeId,
    corpsRole: ArmyCorpsRole,
    delta: number
  ): boolean {
    if (delta === 0) {
      return true;
    }
    if (!this.canUnitBeRecruitedByFaction(this.setupDraft.playerFaction, unitType)) {
      return false;
    }
    const st: UnitStaticStats | undefined = getUnitConfigById(unitType);
    if (st === undefined) {
      return false;
    }

    const currentPop: number = this.computeSetupPlayerPopUsed();
    let existingIdx: number = -1;
    for (let i: number = 0; i < this.setupDraft.playerRoster.length; i++) {
      const item: RosterEntry = this.setupDraft.playerRoster[i];
      if (item.unitType === unitType && item.corpsRole === corpsRole) {
        existingIdx = i;
        break;
      }
    }

    const oldCount: number = existingIdx >= 0 ? this.setupDraft.playerRoster[existingIdx].count : 0;
    let nextCount: number = Math.max(0, oldCount + delta);
    if (nextCount > oldCount) {
      const availPop: number = Math.max(0, GameConstants.DEFAULT_ARMY_POP_CAP - currentPop);
      const maxAddUnits: number = Math.floor(availPop / Math.max(1, st.popCap));
      if (maxAddUnits <= 0) {
        return false;
      }
      nextCount = Math.min(nextCount, oldCount + maxAddUnits);
    }

    const updatedList: RosterEntry[] = [];
    for (let i: number = 0; i < this.setupDraft.playerRoster.length; i++) {
      if (i === existingIdx) {
        if (nextCount > 0) {
          const updatedEntry: RosterEntry = {
            unitType: unitType,
            count: nextCount,
            corpsRole: corpsRole
          };
          updatedList.push(updatedEntry);
        }
      } else {
        updatedList.push(this.setupDraft.playerRoster[i]);
      }
    }

    if (existingIdx < 0 && nextCount > 0) {
      const appended: RosterEntry = {
        unitType: unitType,
        count: nextCount,
        corpsRole: corpsRole
      };
      updatedList.push(appended);
    }
    this.setupDraft.playerRoster = updatedList;
    return true;
  }

  public applySetupPreset(presetKind: 'balanced' | 'cavalry_blitz' | 'fortress_artillery' | 'clear'): void {
    if (presetKind === 'clear') {
      this.setupDraft.playerRoster = [];
      return;
    }
    this.setupDraft.playerRoster = this.buildPresetArmyRoster(this.setupDraft.playerFaction, presetKind);
  }

  /** 由战前整军面板启动真实战场模拟 */
  public launchBattleFromSetup(): BattleInitConfig {
    if (this.setupDraft.playerRoster.length === 0) {
      this.setupDraft.playerRoster = this.buildPresetArmyRoster(this.setupDraft.playerFaction, 'balanced');
    }
    const enemyPresetKind: 'balanced' | 'cavalry_blitz' | 'fortress_artillery' =
      this.setupDraft.scenarioType === BattleScenarioType.SIEGE_DEFENSE
        ? 'fortress_artillery'
        : 'balanced';
    const enemyRoster: RosterEntry[] = this.buildPresetArmyRoster(
      this.setupDraft.enemyFaction,
      enemyPresetKind
    );

    const cfg: BattleInitConfig = {
      scenarioType: this.setupDraft.scenarioType,
      playerFaction: this.setupDraft.playerFaction,
      enemyFaction: this.setupDraft.enemyFaction,
      terrain: this.setupDraft.terrain,
      weather: this.setupDraft.weather,
      playerInitialGrain: this.setupDraft.initialGrain,
      enemyInitialGrain: GameConstants.BATTLE_INIT_GRAIN,
      playerMoraleModifier: 0,
      enemyMoraleModifier: 0,
      playerArmyRoster: CampaignEngine.cloneRosterList(this.setupDraft.playerRoster),
      enemyArmyRoster: enemyRoster,
      campaignNodeId: '',
      siegeHoldDurationSec: this.setupDraft.siegeHoldDurationSec
    };

    this.startBattleWithConfig(cfg, false);
    return cfg;
  }

  // ==================== 2. 真实冷兵器战斗会话（BattleSimulator + BattleTacticalAI） ====================

  public startBattleWithConfig(config: BattleInitConfig, isFromCampaign: boolean): BattleSimulator {
    const sim: BattleSimulator = new BattleSimulator(config);
    const ai: BattleTacticalAI = new BattleTacticalAI();
    const initBatch: AiBattleDecisionBatch = ai.evaluateNow(sim.getWorldView());
    this.applyAiDecisionBatch(sim, initBatch);

    this.activeBattleSim = sim;
    this.activeBattleAi = ai;
    this.activeBattleFromCampaign = isFromCampaign;
    this.pendingSettlement = null;
    this.pendingSettlementFromCampaign = isFromCampaign;
    this.pendingSettlementApplied = false;
    this.lastCampaignSettlementReport = null;
    return sim;
  }

  public getActiveBattleSimulator(): BattleSimulator | null {
    return this.activeBattleSim;
  }

  public getActiveBattleAi(): BattleTacticalAI | null {
    return this.activeBattleAi;
  }

  public isActiveBattleFromCampaign(): boolean {
    return this.activeBattleFromCampaign;
  }

  public getLastAiDoctrine(): string {
    return this.lastAiDoctrine;
  }

  public getLastAiSiegePhase(): string {
    return this.lastAiSiegePhase;
  }

  /**
   * 推进一帧真实战斗物理与三层战术 AI（严禁任何假动画，100% 走 BattleSimulator + BattleTacticalAI）
   */
  public stepActiveBattle(dtSec: number): BattleHudSnapshot | null {
    if (this.activeBattleSim === null || this.activeBattleAi === null) {
      return null;
    }
    const sim: BattleSimulator = this.activeBattleSim;
    const hudBefore: BattleHudSnapshot = sim.getHudSnapshot();
    if (!hudBefore.isPaused && hudBefore.outcome === BattleOutcomeReason.ONGOING && dtSec > 0) {
      const batch: AiBattleDecisionBatch | null = this.activeBattleAi.step(sim.getWorldView(), dtSec);
      if (batch !== null) {
        this.applyAiDecisionBatch(sim, batch);
      }
      sim.stepTick(dtSec);
    }
    return sim.getHudSnapshot();
  }

  private applyAiDecisionBatch(sim: BattleSimulator, batch: AiBattleDecisionBatch): void {
    this.lastAiDoctrine = batch.activeDoctrine;
    this.lastAiSiegePhase = batch.siegePhase;
    for (let i: number = 0; i < batch.squadCommands.length; i++) {
      sim.issueSquadCommand(batch.squadCommands[i]);
    }
    for (let r: number = 0; r < batch.recruitRequests.length; r++) {
      sim.recruitUnit(
        BattleSide.ENEMY,
        batch.recruitRequests[r].unitType,
        batch.recruitRequests[r].corpsRole
      );
    }
    if (batch.enemyHeroTriggerWarCry) {
      sim.triggerEnemyHeroSkill(HeroSkillId.GRAND_WAR_CRY);
    }
  }

  /**
   * 结束当前战斗并生成结算摘要（支持自然终局、停火议和或主动撤军）
   */
  public finalizeActiveBattle(manualExitAction?: 'retreat' | 'truce'): BattleSettlementSummary | null {
    if (this.activeBattleSim === null) {
      return this.pendingSettlement;
    }
    if (this.pendingSettlement !== null) {
      return this.pendingSettlement;
    }

    const sim: BattleSimulator = this.activeBattleSim;
    if (manualExitAction === 'truce' && sim.getHudSnapshot().outcome === BattleOutcomeReason.ONGOING) {
      sim.negotiateFieldTruce();
    }

    let summary: BattleSettlementSummary = sim.buildSettlementSummary();
    if (manualExitAction === 'retreat' && summary.outcomeReason === BattleOutcomeReason.ONGOING) {
      const retreatLosses: number = Math.max(2, Math.round(summary.playerInitialTotal * 0.08));
      const adjustedSummary: BattleSettlementSummary = {
        scenarioType: summary.scenarioType,
        campaignNodeId: summary.campaignNodeId,
        playerFaction: summary.playerFaction,
        enemyFaction: summary.enemyFaction,
        isVictory: false,
        outcomeReason: BattleOutcomeReason.PLAYER_ARMY_ROUTED,
        durationSec: summary.durationSec,
        playerInitialTotal: summary.playerInitialTotal,
        playerKilled: Math.max(summary.playerKilled, retreatLosses),
        playerWoundedRecovered: summary.playerWoundedRecovered,
        enemyInitialTotal: summary.enemyInitialTotal,
        enemyKilled: summary.enemyKilled,
        capturedPrisoners: 0,
        lootedGold: 0,
        lootedWood: 0,
        lootedGrain: 0,
        heroKills: summary.heroKills,
        commanderExpGained: Math.min(15, summary.commanderExpGained)
      };
      summary = adjustedSummary;
    }

    this.pendingSettlement = summary;
    this.pendingSettlementFromCampaign = this.activeBattleFromCampaign;
    this.pendingSettlementApplied = false;

    if (!this.activeBattleFromCampaign) {
      this.standaloneBattlesFought++;
      if (summary.isVictory) {
        this.standaloneBattlesWon++;
      }
      this.standaloneHeroKills += summary.heroKills;
    }

    return summary;
  }

  // ==================== 3. 战后结算与战役态势回写 ====================

  public getPendingSettlementSummary(): BattleSettlementSummary | null {
    return this.pendingSettlement;
  }

  public isPendingSettlementFromCampaign(): boolean {
    return this.pendingSettlementFromCampaign;
  }

  public isPendingSettlementApplied(): boolean {
    return this.pendingSettlementApplied;
  }

  public getLastCampaignSettlementReport(): SettlementApplyReport | null {
    return this.lastCampaignSettlementReport;
  }

  public commitPendingCampaignSettlement(
    disposition: PrisonerDisposition
  ): SettlementApplyReport | null {
    if (!this.pendingSettlementFromCampaign || this.pendingSettlement === null) {
      return null;
    }
    if (this.pendingSettlementApplied && this.lastCampaignSettlementReport !== null) {
      return this.lastCampaignSettlementReport;
    }
    const report: SettlementApplyReport = this.campaignEngine.applyBattleSettlement(
      this.pendingSettlement,
      disposition
    );
    this.pendingSettlementApplied = true;
    this.lastCampaignSettlementReport = report;
    this.saveManager.saveAuto(this.campaignEngine.getState());
    return report;
  }

  // ==================== 4. 40 城 78 路战役大地图、外交博弈与 AI 回合演化 ====================

  public ensureCampaignForFaction(factionId: FactionId, forceRestart: boolean = false): CampaignSaveState {
    this.selectedMenuFaction = factionId;
    if (!this.hasInitializedCampaign || forceRestart) {
      const fresh: CampaignSaveState = this.campaignEngine.startNewCampaign(factionId);
      this.hasInitializedCampaign = true;
      this.saveManager.saveAuto(fresh);
      return fresh;
    }
    return this.campaignEngine.getState();
  }

  public startNewCampaign(factionId: FactionId): CampaignSaveState {
    return this.ensureCampaignForFaction(factionId, true);
  }

  public recruitCampaignArmy(
    unitType: UnitTypeId,
    count: number,
    corpsRole: ArmyCorpsRole,
    useMercenaryGoldContract: boolean = false
  ): CampaignOperationResult {
    const playerFac: FactionId = this.campaignEngine.getState().playerFaction;
    return this.campaignEngine.recruitUnits(
      playerFac,
      unitType,
      count,
      corpsRole,
      useMercenaryGoldContract
    );
  }

  public unlockPlayerTech(techId: string): CampaignOperationResult {
    const playerFac: FactionId = this.campaignEngine.getState().playerFaction;
    return this.campaignEngine.unlockTech(playerFac, techId);
  }

  public setupPlayerReliefAmbush(
    ambushNodeId: string,
    besiegedEnemyNodeId?: string
  ): CampaignOperationResult {
    const playerFac: FactionId = this.campaignEngine.getState().playerFaction;
    return this.campaignEngine.setupReliefAmbush(playerFac, ambushNodeId, besiegedEnemyNodeId);
  }

  public marchPlayerArmyToNode(
    targetNodeId: string,
    options?: MarchActionOptions
  ): MarchActionResult {
    const playerFac: FactionId = this.campaignEngine.getState().playerFaction;
    const res: MarchActionResult = this.campaignEngine.marchToNode(playerFac, targetNodeId, options);
    if (res.battleTriggered && res.battleConfig !== null) {
      this.startBattleWithConfig(res.battleConfig, true);
    }
    return res;
  }

  public launchCampaignReliefAmbushBattle(ambushNodeId: string): boolean {
    const playerFac: FactionId = this.campaignEngine.getState().playerFaction;
    const cfg: BattleInitConfig | null = this.campaignEngine.createReliefAmbushBattleConfig(
      playerFac,
      ambushNodeId
    );
    if (cfg === null) {
      return false;
    }
    this.startBattleWithConfig(cfg, true);
    return true;
  }

  public launchCampaignSiegeDefenseBattle(
    defendingNodeId: string,
    attackerFaction: FactionId
  ): boolean {
    const cfg: BattleInitConfig | null = this.campaignEngine.createSiegeDefenseBattleConfig(
      defendingNodeId,
      attackerFaction
    );
    if (cfg === null) {
      return false;
    }
    this.startBattleWithConfig(cfg, true);
    return true;
  }

  /** 外交动作封装（自动同步刷新全图 BFS 粮道并写入编年日志） */
  public assessPlayerWarDeclaration(
    targetFaction: FactionId,
    defendingVictimAlly?: FactionId
  ): BetrayalAssessment {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const ctx: WarDeclarationContext | undefined =
      defendingVictimAlly !== undefined ? { defendingVictimAlly: defendingVictimAlly } : undefined;
    return this.campaignEngine
      .getDiplomacyEngine()
      .assessWarDeclaration(st.playerFaction, targetFaction, st.diplomacy, st.factions, ctx);
  }

  public declarePlayerWar(
    targetFaction: FactionId,
    defendingVictimAlly?: FactionId
  ): WarDeclarationResult {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const ctx: WarDeclarationContext | undefined =
      defendingVictimAlly !== undefined ? { defendingVictimAlly: defendingVictimAlly } : undefined;
    const res: WarDeclarationResult = this.campaignEngine
      .getDiplomacyEngine()
      .declareWar(st.playerFaction, targetFaction, st.diplomacy, st.factions, ctx);
    this.campaignEngine.getSupplyEngine().refreshAllNodesSupply(st.nodes, st.diplomacy);
    this.appendCampaignLog(res.message);
    return res;
  }

  public mediateDoubleAlliance(allyB: FactionId, allyC: FactionId): DiplomaticActionResult {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const res: DiplomaticActionResult = this.campaignEngine
      .getDiplomacyEngine()
      .mediateDoubleAllianceConflict(st.playerFaction, allyB, allyC, st.diplomacy);
    this.campaignEngine.getSupplyEngine().refreshAllNodesSupply(st.nodes, st.diplomacy);
    if (res.success) {
      this.appendCampaignLog(res.message);
    }
    return res;
  }

  public previewPeaceOffer(terms: PeaceOfferTerms): PeaceOfferPreviewBundle {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const diplo = this.campaignEngine.getDiplomacyEngine();
    const breakdown: PeaceScoreBreakdown = diplo.computePeaceScoreBreakdown(
      terms,
      st.diplomacy,
      st.factions,
      st.nodes
    );
    const evalRes = diplo.evaluatePeaceOffer(terms, st.diplomacy, st.factions, st.nodes);
    const bundle: PeaceOfferPreviewBundle = {
      breakdown: breakdown,
      netScore: evalRes.netScore,
      outcomeKind: evalRes.kind,
      explanation: evalRes.explanation,
      counterTerms: evalRes.counterTerms
    };
    return bundle;
  }

  public submitPeaceOffer(terms: PeaceOfferTerms): PeaceExecutionResult {
    return this.campaignEngine.negotiatePeace(terms);
  }

  public signPlayerNonAggression(targetFaction: FactionId): DiplomaticActionResult {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const res: DiplomaticActionResult = this.campaignEngine
      .getDiplomacyEngine()
      .signNonAggressionPact(st.playerFaction, targetFaction, st.diplomacy, st.factions);
    if (res.success) {
      this.appendCampaignLog(res.message);
    }
    return res;
  }

  public signPlayerTradePact(targetFaction: FactionId): DiplomaticActionResult {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const res: DiplomaticActionResult = this.campaignEngine
      .getDiplomacyEngine()
      .signTradePact(st.playerFaction, targetFaction, st.diplomacy, st.factions);
    if (res.success) {
      this.appendCampaignLog(res.message);
    }
    return res;
  }

  public formPlayerAlliance(targetFaction: FactionId): DiplomaticActionResult {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const res: DiplomaticActionResult = this.campaignEngine
      .getDiplomacyEngine()
      .formAlliance(st.playerFaction, targetFaction, st.diplomacy, st.factions);
    this.campaignEngine.getSupplyEngine().refreshAllNodesSupply(st.nodes, st.diplomacy);
    if (res.success) {
      this.appendCampaignLog(res.message);
    }
    return res;
  }

  public establishCampaignVassalage(
    vassalFaction: FactionId,
    overlordFaction: FactionId
  ): DiplomaticActionResult {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const res: DiplomaticActionResult = this.campaignEngine
      .getDiplomacyEngine()
      .establishVassalage(vassalFaction, overlordFaction, st.diplomacy, st.factions, st.nodes);
    this.campaignEngine.getSupplyEngine().refreshAllNodesSupply(st.nodes, st.diplomacy);
    if (res.success) {
      this.appendCampaignLog(res.message);
    }
    return res;
  }

  public sendPlayerGift(
    targetFaction: FactionId,
    goldAmount: number,
    grainAmount: number
  ): DiplomaticActionResult {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const res: DiplomaticActionResult = this.campaignEngine
      .getDiplomacyEngine()
      .sendGift(st.playerFaction, targetFaction, goldAmount, grainAmount, st.diplomacy, st.factions);
    if (res.success) {
      this.appendCampaignLog(res.message);
    }
    return res;
  }

  public sowPlayerDiscord(
    targetA: FactionId,
    targetB: FactionId,
    goldCost: number
  ): DiplomaticActionResult {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const res: DiplomaticActionResult = this.campaignEngine
      .getDiplomacyEngine()
      .sowDiscord(st.playerFaction, targetA, targetB, goldCost, st.diplomacy, st.factions);
    this.campaignEngine.getSupplyEngine().refreshAllNodesSupply(st.nodes, st.diplomacy);
    if (res.success) {
      this.appendCampaignLog(res.message);
    }
    return res;
  }

  /**
   * 推进战略大地图下一回合：
   * - 驱动其余 7 大 AI 势力执行真实征募、科技研发、设伏、结盟、通商、媾和、宣战与边境攻城推演；
   * - 自动结算全图税赋、丝路通商、围城断粮减员与反霸权合纵警觉；
   * - 写入槽位 0 自动存档。
   */
  public advanceCampaignTurnWithAi(): CampaignTurnAdvanceReport {
    const report: CampaignTurnAdvanceReport = this.campaignEngine.advanceTurn(
      (eng: CampaignEngine, aiFaction: FactionId) => {
        this.executeSingleAiFactionStrategicTurn(eng, aiFaction);
      }
    );
    this.saveManager.saveAuto(this.campaignEngine.getState());
    return report;
  }

  private executeSingleAiFactionStrategicTurn(eng: CampaignEngine, aiFaction: FactionId): void {
    const st: CampaignSaveState = eng.getState();
    const diplo = eng.getDiplomacyEngine();
    const actions: StrategicTurnAction[] = this.campaignAi.evaluateFactionTurn(st, aiFaction);

    for (let i: number = 0; i < actions.length; i++) {
      const act: StrategicTurnAction = actions[i];
      if (act.type === StrategicActionType.RECRUIT && act.unitType !== null && act.corpsRole !== null) {
        eng.recruitUnits(
          aiFaction,
          act.unitType,
          act.count,
          act.corpsRole,
          aiFaction === FactionId.SHAMO
        );
      } else if (act.type === StrategicActionType.UNLOCK_TECH && act.techId.length > 0) {
        eng.unlockTech(aiFaction, act.techId);
      } else if (act.type === StrategicActionType.SET_AMBUSH_TRAP && act.targetNodeId.length > 0) {
        eng.setupReliefAmbush(aiFaction, act.targetNodeId);
      } else if (act.type === StrategicActionType.PROPOSE_TRADE && act.targetFactionId !== null) {
        diplo.signTradePact(aiFaction, act.targetFactionId, st.diplomacy, st.factions);
      } else if (act.type === StrategicActionType.PROPOSE_ALLIANCE && act.targetFactionId !== null) {
        diplo.formAlliance(aiFaction, act.targetFactionId, st.diplomacy, st.factions);
      } else if (act.type === StrategicActionType.PROPOSE_PEACE && act.peaceTerms !== null) {
        eng.negotiatePeace(act.peaceTerms);
      } else if (act.type === StrategicActionType.DECLARE_WAR && act.targetFactionId !== null) {
        diplo.declareWar(aiFaction, act.targetFactionId, st.diplomacy, st.factions);
      } else if (act.type === StrategicActionType.MARCH_ATTACK && act.targetNodeId.length > 0) {
        this.resolveAiBorderOffensive(eng, aiFaction, act.targetNodeId);
      }
    }
  }

  private resolveAiBorderOffensive(
    eng: CampaignEngine,
    aiFaction: FactionId,
    targetNodeId: string
  ): void {
    const st: CampaignSaveState = eng.getState();
    const targetNode: CampaignNodeRuntime | undefined = eng.getNodeRuntime(targetNodeId);
    const attackerFac: FactionCampaignRuntime | undefined = eng.getFactionRuntime(aiFaction);
    if (targetNode === undefined || attackerFac === undefined || targetNode.owner === aiFaction) {
      return;
    }

    const defenderFaction: FactionId = targetNode.owner;
    const diploStatus: DiplomaticStatus = eng
      .getDiplomacyEngine()
      .getStatus(st.diplomacy, aiFaction, defenderFaction);
    if (diploStatus !== DiplomaticStatus.WAR) {
      return;
    }

    const attackerPop: number = eng.computeArmyPopulationUsed(aiFaction);
    const attackDamage: number = Math.max(28, Math.round(attackerPop * 0.42));

    if (defenderFaction === st.playerFaction) {
      // 对玩家边境城池施加真实围攻消耗并写入战报提示玩家回援或主动迎击
      targetNode.garrisonStrength = Math.max(25, targetNode.garrisonStrength - Math.round(attackDamage * 0.55));
      const targetCfg: CampaignNodeConfig | undefined = eng.getSupplyEngine().getStaticNodeConfig(targetNodeId);
      const aiCfg: FactionStaticConfig | undefined = getFactionConfigById(aiFaction);
      const cityName: string = targetCfg !== undefined ? targetCfg.name : targetNodeId;
      const aiName: string = aiCfg !== undefined ? aiCfg.name : aiFaction;
      this.appendCampaignLog(
        `【边关告急】${aiName}猛攻我方【${cityName}】，守军激战折损至 ${targetNode.garrisonStrength}！`
      );
      return;
    }

    // AI 之间真实攻城易手（确保大地图并非静态摆设，AI 诸侯会互相吞并扩张）
    if (targetNode.garrisonStrength <= attackDamage && eng.countControlledNodes(defenderFaction) > 1) {
      const oldOwnerCfg: FactionStaticConfig | undefined = getFactionConfigById(defenderFaction);
      const newOwnerCfg: FactionStaticConfig | undefined = getFactionConfigById(aiFaction);
      const targetCfg: CampaignNodeConfig | undefined = eng.getSupplyEngine().getStaticNodeConfig(targetNodeId);
      targetNode.owner = aiFaction;
      targetNode.garrisonStrength = 95;
      targetNode.isolatedTurns = 0;
      targetNode.hasAmbushTrap = false;
      attackerFac.armyLocationNodeId = targetNodeId;
      eng.getSupplyEngine().refreshAllNodesSupply(st.nodes, st.diplomacy);
      const aiName: string = newOwnerCfg !== undefined ? newOwnerCfg.name : aiFaction;
      const defName: string = oldOwnerCfg !== undefined ? oldOwnerCfg.name : defenderFaction;
      const cityName: string = targetCfg !== undefined ? targetCfg.name : targetNodeId;
      this.appendCampaignLog(`【天下军情】${aiName}攻破${defName}重镇【${cityName}】，版图易主！`);
    } else {
      targetNode.garrisonStrength = Math.max(20, targetNode.garrisonStrength - attackDamage);
    }
  }

  private appendCampaignLog(entry: string): void {
    const st: CampaignSaveState = this.campaignEngine.getState();
    st.recentLogs.unshift(`第${st.turnNumber}回合：${entry}`);
    if (st.recentLogs.length > CampaignEngine.MAX_RECENT_LOGS) {
      st.recentLogs.length = CampaignEngine.MAX_RECENT_LOGS;
    }
  }

  // ==================== 5. 离线存档与统帅荣誉统计 ====================

  public saveCurrentCampaignToSlot(slotIndex: number, customTitle?: string): SaveWriteResult {
    const state: CampaignSaveState = this.campaignEngine.getState();
    return this.saveManager.saveToSlot(slotIndex, state, customTitle);
  }

  public loadCampaignFromSlot(slotIndex: number): SaveLoadResult {
    const res: SaveLoadResult = this.saveManager.loadFromSlot(slotIndex, true);
    if (res.success && res.state !== null) {
      this.campaignEngine.loadFromSaveState(res.state);
      this.selectedMenuFaction = res.state.playerFaction;
      this.hasInitializedCampaign = true;
    }
    return res;
  }

  public listAllSaveSlots(): SaveSlotSummary[] {
    return this.saveManager.listSlotSummaries();
  }

  public deleteSaveSlot(slotIndex: number): boolean {
    return this.saveManager.deleteSlot(slotIndex);
  }

  public getHallOfFameStats(): HallOfFameStats {
    const st: CampaignSaveState = this.campaignEngine.getState();
    const playerFac: FactionId = st.playerFaction;
    let cities: number = 0;
    let capitals: number = 0;
    for (let i: number = 0; i < st.nodes.length; i++) {
      if (st.nodes[i].owner === playerFac) {
        cities++;
        const cfg: CampaignNodeConfig | undefined = this.campaignEngine
          .getSupplyEngine()
          .getStaticNodeConfig(st.nodes[i].nodeId);
        if (cfg !== undefined && cfg.nodeType === CampaignNodeType.CAPITAL_CITADEL) {
          capitals++;
        }
      }
    }
    const stats: HallOfFameStats = {
      activeCampaignTurn: st.turnNumber,
      activeCampaignFaction: playerFac,
      activeControlledCities: cities,
      activeControlledCapitals: capitals,
      totalBattlesFought: st.totalBattlesFought + this.standaloneBattlesFought,
      totalBattlesWon: st.totalBattlesWon + this.standaloneBattlesWon,
      totalEnemiesKilled: st.totalEnemiesKilled,
      standaloneBattlesFought: this.standaloneBattlesFought,
      standaloneBattlesWon: this.standaloneBattlesWon,
      standaloneHeroKills: this.standaloneHeroKills
    };
    return stats;
  }

  // ==================== 内部预设辅助构造 ====================

  private buildDefaultSetupDraft(
    modeKey: string,
    modeTitle: string,
    playerFaction: FactionId
  ): SetupDraftState {
    const enemyFaction: FactionId = this.pickDefaultRivalFaction(playerFaction);
    let scenario: BattleScenarioType = BattleScenarioType.FIELD_PITCHED;
    let terrain: TerrainType = TerrainType.PLAIN;
    let weather: WeatherType = WeatherType.CLEAR_DAY;
    let preset: 'balanced' | 'cavalry_blitz' | 'fortress_artillery' = 'balanced';

    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(playerFaction);
    if (fCfg !== undefined) {
      terrain = fCfg.homeTerrain;
    }

    if (modeKey === 'siege') {
      scenario = BattleScenarioType.SIEGE_DEFENSE;
      terrain = TerrainType.FORT_WALL;
      preset = 'fortress_artillery';
    } else if (modeKey === 'skirmish') {
      scenario = BattleScenarioType.FIELD_PITCHED;
      if (terrain === TerrainType.FORT_WALL) {
        terrain = TerrainType.RIVER_FORD;
      }
    }

    const draft: SetupDraftState = {
      modeKey: modeKey,
      modeTitle: modeTitle,
      scenarioType: scenario,
      playerFaction: playerFaction,
      enemyFaction: enemyFaction,
      terrain: terrain,
      weather: weather,
      initialGrain: GameConstants.BATTLE_INIT_GRAIN,
      siegeHoldDurationSec: 180,
      playerRoster: this.buildPresetArmyRoster(playerFaction, preset)
    };
    return draft;
  }

  private pickDefaultRivalFaction(playerFaction: FactionId): FactionId {
    if (playerFaction === FactionId.YANLONG) {
      return FactionId.CANGLANG;
    }
    if (playerFaction === FactionId.CANGLANG) {
      return FactionId.YANLONG;
    }
    if (playerFaction === FactionId.TIEYING) {
      return FactionId.SHUANGYUAN;
    }
    if (playerFaction === FactionId.SHAMO) {
      return FactionId.WULIN;
    }
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      if (FACTION_STATIC_CONFIGS[i].id !== playerFaction) {
        return FACTION_STATIC_CONFIGS[i].id;
      }
    }
    return FactionId.CANGLANG;
  }

  private buildPresetArmyRoster(
    factionId: FactionId,
    presetKind: 'balanced' | 'cavalry_blitz' | 'fortress_artillery'
  ): RosterEntry[] {
    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(factionId);
    const aceUnit: UnitTypeId =
      fCfg !== undefined ? fCfg.exclusiveUnitId : UnitTypeId.YANLONG_HALBERD_GRENADIER;
    const aceStats: UnitStaticStats | undefined = getUnitConfigById(aceUnit);
    const aceCount: number =
      aceStats !== undefined && aceStats.popCap >= 3
        ? 8
        : aceStats !== undefined && aceStats.popCap === 2
          ? 12
          : 18;

    if (presetKind === 'cavalry_blitz') {
      const blitz: RosterEntry[] = [
        { unitType: UnitTypeId.PIKEMAN, count: 18, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
        { unitType: UnitTypeId.LIGHT_CAVALRY, count: 14, corpsRole: ArmyCorpsRole.LEFT_WING },
        { unitType: UnitTypeId.LIGHT_CAVALRY, count: 14, corpsRole: ArmyCorpsRole.RIGHT_WING },
        { unitType: aceUnit, count: aceCount, corpsRole: ArmyCorpsRole.REAR_RESERVE },
        { unitType: UnitTypeId.COMPOSITE_ARCHER, count: 16, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
        { unitType: UnitTypeId.SAPPER, count: 6, corpsRole: ArmyCorpsRole.SUPPLY_ESCORT }
      ];
      return blitz;
    }

    if (presetKind === 'fortress_artillery') {
      const siegeUnit: UnitTypeId =
        factionId === FactionId.CANGLANG ? UnitTypeId.BALLISTA : UnitTypeId.TREBUCHET;
      const siegeCount: number = siegeUnit === UnitTypeId.TREBUCHET ? 3 : 4;
      const fort: RosterEntry[] = [
        { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 24, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
        { unitType: UnitTypeId.PIKEMAN, count: 16, corpsRole: ArmyCorpsRole.LEFT_WING },
        { unitType: UnitTypeId.GREAT_AXEMAN, count: 14, corpsRole: ArmyCorpsRole.RIGHT_WING },
        { unitType: aceUnit, count: aceCount, corpsRole: ArmyCorpsRole.REAR_RESERVE },
        { unitType: UnitTypeId.COMPOSITE_ARCHER, count: 18, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
        { unitType: siegeUnit, count: siegeCount, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
        { unitType: UnitTypeId.SAPPER, count: 8, corpsRole: ArmyCorpsRole.SUPPLY_ESCORT }
      ];
      return fort;
    }

    // 标准 6 军团百人协同编制（开局即具备前锋抗线、两翼骑兵包抄、专属王牌预备队、远程压制与工兵采粮）
    const balanced: RosterEntry[] = [
      { unitType: UnitTypeId.SHIELD_SWORDSMAN, count: 22, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
      { unitType: UnitTypeId.PIKEMAN, count: 16, corpsRole: ArmyCorpsRole.VANGUARD_CENTER },
      { unitType: UnitTypeId.LIGHT_CAVALRY, count: 10, corpsRole: ArmyCorpsRole.LEFT_WING },
      { unitType: UnitTypeId.LIGHT_CAVALRY, count: 10, corpsRole: ArmyCorpsRole.RIGHT_WING },
      { unitType: aceUnit, count: aceCount, corpsRole: ArmyCorpsRole.REAR_RESERVE },
      { unitType: UnitTypeId.COMPOSITE_ARCHER, count: 18, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
      { unitType: UnitTypeId.BALLISTA, count: 2, corpsRole: ArmyCorpsRole.SIEGE_BATTERY },
      { unitType: UnitTypeId.SAPPER, count: 6, corpsRole: ArmyCorpsRole.SUPPLY_ESCORT }
    ];
    // 校验 UNIT_STATIC_CONFIGS 与 CAMPAIGN_MAP_NODES 引用完整性
    if (UNIT_STATIC_CONFIGS.length === 0 || CAMPAIGN_MAP_NODES.length === 0) {
      return [];
    }
    return balanced;
  }
}
