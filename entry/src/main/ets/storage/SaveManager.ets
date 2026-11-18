/**
 * 战役离线本地多槽位存档管理器（SaveManager.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 硬依赖）
 *
 * 核心设计：
 * 1. 纯内存高速缓存 + 可注入持久化后端适配器（Stage UI 层可注入应用沙箱文件或 Preferences 适配器，Node 测试零依赖运行）；
 * 2. 支持 1 个自动存档槽（槽位 0）+ 5 个手动存档槽（槽位 1~5），共 6 个标准槽位；
 * 3. 提供 `listSlotSummaries(): SaveSlotSummary[]`、损坏 JSON 异常捕获、Schema 版本号校验、全字段合法性深层防崩校验；
 * 4. 自动处理 `SupplyLineGrade.SEVERED` 下 `Infinity` 跳数的安全 JSON 序列化与反序列化还原。
 */
import { CAMPAIGN_MAP_NODES } from '../config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../config/FactionConfig';
import { UNIT_STATIC_CONFIGS } from '../config/UnitConfig';
import { FactionStaticConfig } from '../model/GameTypes';
import {
  ArmyCorpsRole,
  BilateralDiplomacyState,
  CampaignNodeRuntime,
  CampaignSaveState,
  DiplomaticStatus,
  FactionCampaignRuntime,
  FactionId,
  RosterEntry,
  SaveSlotSummary,
  SupplyLineGrade,
  UnitTypeId
} from '../core/CoreContracts';
import { CampaignEngine } from '../core/campaign/CampaignEngine';

/** 可注入的键值文本持久化后端契约（解耦沙箱 fs / Preferences 与纯逻辑单测） */
export interface PersistenceBackendAdapter {
  readText(key: string): string | null;
  writeText(key: string, content: string): void;
  deleteKey(key: string): void;
}

/** 默认纯内存持久化后端实现 */
export class InMemoryPersistenceBackend implements PersistenceBackendAdapter {
  private readonly store: Map<string, string>;

  public constructor() {
    this.store = new Map<string, string>();
  }

  public readText(key: string): string | null {
    const val: string | undefined = this.store.get(key);
    return val !== undefined ? val : null;
  }

  public writeText(key: string, content: string): void {
    this.store.set(key, content);
  }

  public deleteKey(key: string): void {
    this.store.delete(key);
  }

  public clearAll(): void {
    this.store.clear();
  }
}

/** 存档读写错误类型枚举 */
export enum SaveErrorCode {
  NONE = 'none',
  INVALID_SLOT = 'invalid_slot',
  EMPTY_SLOT = 'empty_slot',
  CORRUPTED_JSON = 'corrupted_json',
  SCHEMA_VERSION_MISMATCH = 'schema_version_mismatch',
  INVALID_STATE_PAYLOAD = 'invalid_state_payload',
  BACKEND_IO_ERROR = 'backend_io_error'
}

/** 存档写入结果 */
export interface SaveWriteResult {
  readonly success: boolean;
  readonly slotIndex: number;
  readonly errorCode: SaveErrorCode;
  readonly message: string;
  readonly summary: SaveSlotSummary | null;
}

/** 存档读取结果 */
export interface SaveLoadResult {
  readonly success: boolean;
  readonly slotIndex: number;
  readonly errorCode: SaveErrorCode;
  readonly message: string;
  readonly state: CampaignSaveState | null;
  readonly summary: SaveSlotSummary | null;
}

/** 序列化至 JSON 文本的顶层封套结构（将 Infinity 安全编码为 -1） */
interface SerializedNodeDto {
  readonly nodeId?: string;
  readonly owner?: string;
  readonly garrisonStrength?: number;
  readonly defenseHp?: number;
  readonly isolatedTurns?: number;
  readonly hasAmbushTrap?: boolean;
  readonly supplyGrade?: string;
  readonly supplyHops?: number;
}

interface SerializedRosterDto {
  readonly unitType?: string;
  readonly count?: number;
  readonly corpsRole?: string;
}

interface SerializedFactionDto {
  readonly factionId?: string;
  readonly isAlive?: boolean;
  readonly gold?: number;
  readonly wood?: number;
  readonly grain?: number;
  readonly credibility?: number;
  readonly unlockedTechIds?: string[];
  readonly commanderLevel?: number;
  readonly commanderExp?: number;
  readonly betrayalMoralePenaltyBattles?: number;
  readonly commanderInjuredTurns?: number;
  readonly fieldArmyRoster?: SerializedRosterDto[];
  readonly armyLocationNodeId?: string;
}

interface SerializedDiplomacyDto {
  readonly factionA?: string;
  readonly factionB?: string;
  readonly relation?: number;
  readonly status?: string;
  readonly remainingTurns?: number;
  readonly vendettaLockTurns?: number;
}

interface SerializedSaveStateDto {
  readonly schemaVersion?: number;
  readonly turnNumber?: number;
  readonly playerFaction?: string;
  readonly nodes?: SerializedNodeDto[];
  readonly factions?: SerializedFactionDto[];
  readonly diplomacy?: SerializedDiplomacyDto[];
  readonly totalBattlesFought?: number;
  readonly totalBattlesWon?: number;
  readonly totalEnemiesKilled?: number;
  readonly recentLogs?: string[];
}

interface SerializedSlotEnvelope {
  readonly envelopeVersion?: number;
  readonly slotIndex?: number;
  readonly title?: string;
  readonly updatedAtIso?: string;
  readonly state?: SerializedSaveStateDto;
}

/**
 * 战役离线存档管理器（槽位 0 为自动存档槽，槽位 1~5 为手动存档槽）
 */
export class SaveManager {
  public static readonly AUTO_SAVE_SLOT: number = 0;
  public static readonly MIN_MANUAL_SLOT: number = 1;
  public static readonly MAX_MANUAL_SLOT: number = 5;
  public static readonly TOTAL_SLOT_COUNT: number = 6;
  public static readonly SUPPORTED_SCHEMA_VERSION: number = 1;
  public static readonly KEY_PREFIX: string = 'stickman_war_save_slot_';

  private backend: PersistenceBackendAdapter;
  private readonly memoryStateCache: Map<number, CampaignSaveState>;
  private readonly memorySummaryCache: Map<number, SaveSlotSummary>;

  private readonly validFactionIds: Set<string>;
  private readonly validNodeIds: Set<string>;
  private readonly validUnitIds: Set<string>;
  private readonly validCorpsRoles: Set<string>;
  private readonly validSupplyGrades: Set<string>;
  private readonly validDiploStatuses: Set<string>;

  public constructor(backend?: PersistenceBackendAdapter) {
    this.backend = backend !== undefined ? backend : new InMemoryPersistenceBackend();
    this.memoryStateCache = new Map<number, CampaignSaveState>();
    this.memorySummaryCache = new Map<number, SaveSlotSummary>();

    this.validFactionIds = new Set<string>();
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      this.validFactionIds.add(FACTION_STATIC_CONFIGS[i].id);
    }

    this.validNodeIds = new Set<string>();
    for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
      this.validNodeIds.add(CAMPAIGN_MAP_NODES[i].id);
    }

    this.validUnitIds = new Set<string>();
    for (let i: number = 0; i < UNIT_STATIC_CONFIGS.length; i++) {
      this.validUnitIds.add(UNIT_STATIC_CONFIGS[i].id);
    }

    this.validCorpsRoles = new Set<string>([
      ArmyCorpsRole.VANGUARD_CENTER,
      ArmyCorpsRole.LEFT_WING,
      ArmyCorpsRole.RIGHT_WING,
      ArmyCorpsRole.REAR_RESERVE,
      ArmyCorpsRole.SIEGE_BATTERY,
      ArmyCorpsRole.SUPPLY_ESCORT
    ]);

    this.validSupplyGrades = new Set<string>([
      SupplyLineGrade.FULL_SUPPLY,
      SupplyLineGrade.EXTENDED_MARCH,
      SupplyLineGrade.OVEREXTENDED,
      SupplyLineGrade.SEVERED
    ]);

    this.validDiploStatuses = new Set<string>([
      DiplomaticStatus.WAR,
      DiplomaticStatus.TRUCE,
      DiplomaticStatus.NEUTRAL,
      DiplomaticStatus.NON_AGGRESSION,
      DiplomaticStatus.TRADE_PACT,
      DiplomaticStatus.ALLIANCE,
      DiplomaticStatus.VASSAL
    ]);
  }

  /**
   * 绑定或切换持久化后端适配器（切换时清空内存缓存以确保与底层存储一致）
   */
  public setBackend(backend: PersistenceBackendAdapter): void {
    this.backend = backend;
    this.memoryStateCache.clear();
    this.memorySummaryCache.clear();
  }

  /**
   * 获取当前绑定的持久化后端适配器
   */
  public getBackend(): PersistenceBackendAdapter {
    return this.backend;
  }

  /**
   * 生成指定槽位的底层存储键名
   */
  public static getStorageKeyForSlot(slotIndex: number): string {
    return `${SaveManager.KEY_PREFIX}${slotIndex}`;
  }

  /**
   * 判断槽位编号是否合法（0 为自动存档，1~5 为手动存档）
   */
  public static isValidSlotIndex(slotIndex: number): boolean {
    return (
      Number.isInteger(slotIndex) &&
      slotIndex >= SaveManager.AUTO_SAVE_SLOT &&
      slotIndex <= SaveManager.MAX_MANUAL_SLOT
    );
  }

  /**
   * 写入自动存档槽（槽位 0）
   */
  public saveAuto(state: CampaignSaveState, nowIso?: string): SaveWriteResult {
    return this.saveToSlot(SaveManager.AUTO_SAVE_SLOT, state, undefined, nowIso);
  }

  /**
   * 保存战役状态至指定槽位（0 ~ 5）
   */
  public saveToSlot(
    slotIndex: number,
    state: CampaignSaveState,
    customTitle?: string,
    nowIso?: string
  ): SaveWriteResult {
    if (!SaveManager.isValidSlotIndex(slotIndex)) {
      const badSlot: SaveWriteResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.INVALID_SLOT,
        message: `非法存档槽位 ${slotIndex}（有效范围 0~5）。`,
        summary: null
      };
      return badSlot;
    }

    if (state.schemaVersion !== SaveManager.SUPPORTED_SCHEMA_VERSION) {
      const badVer: SaveWriteResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.SCHEMA_VERSION_MISMATCH,
        message: `不支持的存档结构版本 v${state.schemaVersion}（当前仅支持 v${SaveManager.SUPPORTED_SCHEMA_VERSION}）。`,
        summary: null
      };
      return badVer;
    }

    const clonedState: CampaignSaveState = CampaignEngine.deepCloneSaveState(state);
    let ownedNodes: number = 0;
    for (let i: number = 0; i < clonedState.nodes.length; i++) {
      if (clonedState.nodes[i].owner === clonedState.playerFaction) {
        ownedNodes++;
      }
    }

    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(clonedState.playerFaction);
    const factionName: string = fCfg !== undefined ? fCfg.name : clonedState.playerFaction;
    const defaultTitle: string =
      slotIndex === SaveManager.AUTO_SAVE_SLOT
        ? `自动存档 · ${factionName} 第${clonedState.turnNumber}回合`
        : `${factionName} · 第${clonedState.turnNumber}回合 (${ownedNodes}城)`;
    const resolvedTitle: string =
      customTitle !== undefined && customTitle.trim().length > 0 ? customTitle.trim() : defaultTitle;
    const timestamp: string =
      nowIso !== undefined && nowIso.length > 0 ? nowIso : new Date().toISOString();

    const envelope: SerializedSlotEnvelope = this.serializeToEnvelope(
      slotIndex,
      resolvedTitle,
      timestamp,
      clonedState
    );

    const summary: SaveSlotSummary = {
      slotIndex: slotIndex,
      title: resolvedTitle,
      factionId: clonedState.playerFaction,
      turnNumber: clonedState.turnNumber,
      controlledNodes: ownedNodes,
      updatedAtIso: timestamp,
      isEmpty: false
    };

    try {
      const jsonText: string = JSON.stringify(envelope);
      this.backend.writeText(SaveManager.getStorageKeyForSlot(slotIndex), jsonText);
      this.memoryStateCache.set(slotIndex, clonedState);
      this.memorySummaryCache.set(slotIndex, summary);

      const okRes: SaveWriteResult = {
        success: true,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.NONE,
        message: `槽位 ${slotIndex} 存档写入成功。`,
        summary: summary
      };
      return okRes;
    } catch (e) {
      const ioErr: SaveWriteResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.BACKEND_IO_ERROR,
        message: '底层存储写入失败。',
        summary: null
      };
      return ioErr;
    }
  }

  /**
   * 从指定槽位加载战役状态（具备完整 JSON 损坏容错、版本号核验与结构校验）
   * @param slotIndex 槽位 0 ~ 5
   * @param bypassMemoryCache 若为 true 则强制重新从持久化后端读取并校验（适用于测试外部注入损坏文件）
   */
  public loadFromSlot(slotIndex: number, bypassMemoryCache: boolean = false): SaveLoadResult {
    if (!SaveManager.isValidSlotIndex(slotIndex)) {
      const badSlot: SaveLoadResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.INVALID_SLOT,
        message: `非法存档槽位 ${slotIndex}（有效范围 0~5）。`,
        state: null,
        summary: null
      };
      return badSlot;
    }

    if (!bypassMemoryCache) {
      const cachedState: CampaignSaveState | undefined = this.memoryStateCache.get(slotIndex);
      const cachedSummary: SaveSlotSummary | undefined = this.memorySummaryCache.get(slotIndex);
      if (cachedState !== undefined && cachedSummary !== undefined) {
        const hitRes: SaveLoadResult = {
          success: true,
          slotIndex: slotIndex,
          errorCode: SaveErrorCode.NONE,
          message: `从内存缓存加载槽位 ${slotIndex} 成功。`,
          state: CampaignEngine.deepCloneSaveState(cachedState),
          summary: cachedSummary
        };
        return hitRes;
      }
    }

    let rawText: string | null = null;
    try {
      rawText = this.backend.readText(SaveManager.getStorageKeyForSlot(slotIndex));
    } catch (e) {
      const readErr: SaveLoadResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.BACKEND_IO_ERROR,
        message: '读取底层存储异常。',
        state: null,
        summary: null
      };
      return readErr;
    }

    if (rawText === null || rawText.trim().length === 0) {
      this.memoryStateCache.delete(slotIndex);
      this.memorySummaryCache.delete(slotIndex);
      const emptyRes: SaveLoadResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.EMPTY_SLOT,
        message: `槽位 ${slotIndex} 为空存档。`,
        state: null,
        summary: SaveManager.createEmptySlotSummary(slotIndex)
      };
      return emptyRes;
    }

    let parsed: SerializedSlotEnvelope | null = null;
    try {
      parsed = JSON.parse(rawText) as SerializedSlotEnvelope | null;
    } catch (e) {
      this.memoryStateCache.delete(slotIndex);
      this.memorySummaryCache.delete(slotIndex);
      const jsonErr: SaveLoadResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.CORRUPTED_JSON,
        message: `槽位 ${slotIndex} JSON 数据损坏，已安全拦截防止崩溃。`,
        state: null,
        summary: null
      };
      return jsonErr;
    }

    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      this.memoryStateCache.delete(slotIndex);
      this.memorySummaryCache.delete(slotIndex);
      const invalidRoot: SaveLoadResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.INVALID_STATE_PAYLOAD,
        message: `槽位 ${slotIndex} 存档根对象非法。`,
        state: null,
        summary: null
      };
      return invalidRoot;
    }

    // 兼容两种格式：带封套 `{ envelopeVersion, state }` 或直接存储 `CampaignSaveState`
    const dtoCandidate: SerializedSaveStateDto | undefined =
      parsed.state !== undefined && parsed.state !== null && typeof parsed.state === 'object'
        ? parsed.state
        : (parsed as SerializedSaveStateDto);

    if (dtoCandidate === undefined || typeof dtoCandidate.schemaVersion !== 'number') {
      this.memoryStateCache.delete(slotIndex);
      this.memorySummaryCache.delete(slotIndex);
      const missingVer: SaveLoadResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.SCHEMA_VERSION_MISMATCH,
        message: `槽位 ${slotIndex} 缺失有效的 schemaVersion 字段。`,
        state: null,
        summary: null
      };
      return missingVer;
    }

    if (dtoCandidate.schemaVersion !== SaveManager.SUPPORTED_SCHEMA_VERSION) {
      this.memoryStateCache.delete(slotIndex);
      this.memorySummaryCache.delete(slotIndex);
      const mismatchRes: SaveLoadResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.SCHEMA_VERSION_MISMATCH,
        message: `槽位 ${slotIndex} 存档版本号不兼容（读取到 v${dtoCandidate.schemaVersion}，期望 v${SaveManager.SUPPORTED_SCHEMA_VERSION}）。`,
        state: null,
        summary: null
      };
      return mismatchRes;
    }

    const validatedState: CampaignSaveState | null = this.validateAndReconstructState(dtoCandidate);
    if (validatedState === null) {
      this.memoryStateCache.delete(slotIndex);
      this.memorySummaryCache.delete(slotIndex);
      const payloadErr: SaveLoadResult = {
        success: false,
        slotIndex: slotIndex,
        errorCode: SaveErrorCode.INVALID_STATE_PAYLOAD,
        message: `槽位 ${slotIndex} 存档内容字段不完整或已遭篡改损坏。`,
        state: null,
        summary: null
      };
      return payloadErr;
    }

    let controlledNodes: number = 0;
    for (let i: number = 0; i < validatedState.nodes.length; i++) {
      if (validatedState.nodes[i].owner === validatedState.playerFaction) {
        controlledNodes++;
      }
    }

    const titleStr: string =
      typeof parsed.title === 'string' && parsed.title.length > 0
        ? parsed.title
        : SaveManager.defaultSlotLabel(slotIndex);
    const updatedIso: string =
      typeof parsed.updatedAtIso === 'string' && parsed.updatedAtIso.length > 0
        ? parsed.updatedAtIso
        : '未知时间';

    const reconstructedSummary: SaveSlotSummary = {
      slotIndex: slotIndex,
      title: titleStr,
      factionId: validatedState.playerFaction,
      turnNumber: validatedState.turnNumber,
      controlledNodes: controlledNodes,
      updatedAtIso: updatedIso,
      isEmpty: false
    };

    this.memoryStateCache.set(slotIndex, validatedState);
    this.memorySummaryCache.set(slotIndex, reconstructedSummary);

    const okLoad: SaveLoadResult = {
      success: true,
      slotIndex: slotIndex,
      errorCode: SaveErrorCode.NONE,
      message: `槽位 ${slotIndex} 存档加载并校验通过。`,
      state: CampaignEngine.deepCloneSaveState(validatedState),
      summary: reconstructedSummary
    };
    return okLoad;
  }

  /**
   * 枚举全部 6 个槽位（槽位 0 自动存档 + 槽位 1~5 手动存档）摘要列表
   * 任何单槽损坏均自动降级显示为空/损坏提示，绝不阻塞或导致存档列表崩溃
   */
  public listSlotSummaries(): SaveSlotSummary[] {
    const list: SaveSlotSummary[] = [];
    for (let slot: number = 0; slot < SaveManager.TOTAL_SLOT_COUNT; slot++) {
      const loadRes: SaveLoadResult = this.loadFromSlot(slot, true);
      if (loadRes.success && loadRes.summary !== null) {
        list.push(loadRes.summary);
      } else if (loadRes.errorCode === SaveErrorCode.EMPTY_SLOT) {
        list.push(SaveManager.createEmptySlotSummary(slot));
      } else {
        const corruptedSummary: SaveSlotSummary = {
          slotIndex: slot,
          title: `${SaveManager.defaultSlotLabel(slot)}（数据损坏已隔离）`,
          factionId: FactionId.YANLONG,
          turnNumber: 0,
          controlledNodes: 0,
          updatedAtIso: '损坏不可读',
          isEmpty: true
        };
        list.push(corruptedSummary);
      }
    }
    return list;
  }

  /**
   * 删除清空指定槽位存档
   */
  public deleteSlot(slotIndex: number): boolean {
    if (!SaveManager.isValidSlotIndex(slotIndex)) {
      return false;
    }
    this.memoryStateCache.delete(slotIndex);
    this.memorySummaryCache.delete(slotIndex);
    try {
      this.backend.deleteKey(SaveManager.getStorageKeyForSlot(slotIndex));
      return true;
    } catch (e) {
      return false;
    }
  }

  private serializeToEnvelope(
    slotIndex: number,
    title: string,
    updatedAtIso: string,
    state: CampaignSaveState
  ): SerializedSlotEnvelope {
    const nodeDtos: SerializedNodeDto[] = [];
    for (let i: number = 0; i < state.nodes.length; i++) {
      const n: CampaignNodeRuntime = state.nodes[i];
      const safeHops: number =
        n.supplyGrade === SupplyLineGrade.SEVERED || !Number.isFinite(n.supplyHops)
          ? -1
          : Math.floor(n.supplyHops);
      const nd: SerializedNodeDto = {
        nodeId: n.nodeId,
        owner: n.owner,
        garrisonStrength: n.garrisonStrength,
        defenseHp: n.defenseHp,
        isolatedTurns: n.isolatedTurns,
        hasAmbushTrap: n.hasAmbushTrap,
        supplyGrade: n.supplyGrade,
        supplyHops: safeHops
      };
      nodeDtos.push(nd);
    }

    const factionDtos: SerializedFactionDto[] = [];
    for (let i: number = 0; i < state.factions.length; i++) {
      const f: FactionCampaignRuntime = state.factions[i];
      const rosterDtos: SerializedRosterDto[] = [];
      for (let r: number = 0; r < f.fieldArmyRoster.length; r++) {
        const item: RosterEntry = f.fieldArmyRoster[r];
        const rd: SerializedRosterDto = {
          unitType: item.unitType,
          count: item.count,
          corpsRole: item.corpsRole
        };
        rosterDtos.push(rd);
      }
      const fd: SerializedFactionDto = {
        factionId: f.factionId,
        isAlive: f.isAlive,
        gold: f.gold,
        wood: f.wood,
        grain: f.grain,
        credibility: f.credibility,
        unlockedTechIds: f.unlockedTechIds.slice(),
        commanderLevel: f.commanderLevel,
        commanderExp: f.commanderExp,
        betrayalMoralePenaltyBattles: f.betrayalMoralePenaltyBattles,
        commanderInjuredTurns: f.commanderInjuredTurns,
        fieldArmyRoster: rosterDtos,
        armyLocationNodeId: f.armyLocationNodeId
      };
      factionDtos.push(fd);
    }

    const diploDtos: SerializedDiplomacyDto[] = [];
    for (let i: number = 0; i < state.diplomacy.length; i++) {
      const d: BilateralDiplomacyState = state.diplomacy[i];
      const dd: SerializedDiplomacyDto = {
        factionA: d.factionA,
        factionB: d.factionB,
        relation: d.relation,
        status: d.status,
        remainingTurns: d.remainingTurns,
        vendettaLockTurns: d.vendettaLockTurns
      };
      diploDtos.push(dd);
    }

    const stateDto: SerializedSaveStateDto = {
      schemaVersion: state.schemaVersion,
      turnNumber: state.turnNumber,
      playerFaction: state.playerFaction,
      nodes: nodeDtos,
      factions: factionDtos,
      diplomacy: diploDtos,
      totalBattlesFought: state.totalBattlesFought,
      totalBattlesWon: state.totalBattlesWon,
      totalEnemiesKilled: state.totalEnemiesKilled,
      recentLogs: state.recentLogs.slice()
    };

    const envelope: SerializedSlotEnvelope = {
      envelopeVersion: 1,
      slotIndex: slotIndex,
      title: title,
      updatedAtIso: updatedAtIso,
      state: stateDto
    };
    return envelope;
  }

  private validateAndReconstructState(dto: SerializedSaveStateDto): CampaignSaveState | null {
    if (
      typeof dto.turnNumber !== 'number' ||
      !Number.isFinite(dto.turnNumber) ||
      dto.turnNumber < 1 ||
      typeof dto.playerFaction !== 'string' ||
      !this.validFactionIds.has(dto.playerFaction)
    ) {
      return null;
    }

    if (
      !Array.isArray(dto.nodes) ||
      dto.nodes.length !== CAMPAIGN_MAP_NODES.length ||
      !Array.isArray(dto.factions) ||
      dto.factions.length !== FACTION_STATIC_CONFIGS.length ||
      !Array.isArray(dto.diplomacy)
    ) {
      return null;
    }

    // 1. 严格校验全部 40 座城关节点
    const seenNodes: Set<string> = new Set<string>();
    const nodes: CampaignNodeRuntime[] = [];
    for (let i: number = 0; i < dto.nodes.length; i++) {
      const rawNode: SerializedNodeDto = dto.nodes[i];
      if (
        rawNode === null ||
        typeof rawNode !== 'object' ||
        typeof rawNode.nodeId !== 'string' ||
        !this.validNodeIds.has(rawNode.nodeId) ||
        seenNodes.has(rawNode.nodeId) ||
        typeof rawNode.owner !== 'string' ||
        !this.validFactionIds.has(rawNode.owner) ||
        typeof rawNode.garrisonStrength !== 'number' ||
        !Number.isFinite(rawNode.garrisonStrength) ||
        rawNode.garrisonStrength < 0 ||
        typeof rawNode.defenseHp !== 'number' ||
        !Number.isFinite(rawNode.defenseHp) ||
        rawNode.defenseHp < 0 ||
        typeof rawNode.isolatedTurns !== 'number' ||
        !Number.isFinite(rawNode.isolatedTurns) ||
        rawNode.isolatedTurns < 0 ||
        typeof rawNode.hasAmbushTrap !== 'boolean' ||
        typeof rawNode.supplyGrade !== 'string' ||
        !this.validSupplyGrades.has(rawNode.supplyGrade)
      ) {
        return null;
      }

      seenNodes.add(rawNode.nodeId);
      const grade: SupplyLineGrade = rawNode.supplyGrade as SupplyLineGrade;
      let restoredHops: number = Number.POSITIVE_INFINITY;
      if (grade !== SupplyLineGrade.SEVERED) {
        if (
          typeof rawNode.supplyHops !== 'number' ||
          !Number.isFinite(rawNode.supplyHops) ||
          rawNode.supplyHops < 0
        ) {
          return null;
        }
        restoredHops = Math.floor(rawNode.supplyHops);
      }

      const cleanNode: CampaignNodeRuntime = {
        nodeId: rawNode.nodeId,
        owner: rawNode.owner as FactionId,
        garrisonStrength: Math.floor(rawNode.garrisonStrength),
        defenseHp: Math.floor(rawNode.defenseHp),
        isolatedTurns: Math.floor(rawNode.isolatedTurns),
        hasAmbushTrap: rawNode.hasAmbushTrap,
        supplyGrade: grade,
        supplyHops: restoredHops
      };
      nodes.push(cleanNode);
    }

    // 2. 严格校验全部 8 大势力
    const seenFactions: Set<string> = new Set<string>();
    const factions: FactionCampaignRuntime[] = [];
    for (let i: number = 0; i < dto.factions.length; i++) {
      const rf: SerializedFactionDto = dto.factions[i];
      if (
        rf === null ||
        typeof rf !== 'object' ||
        typeof rf.factionId !== 'string' ||
        !this.validFactionIds.has(rf.factionId) ||
        seenFactions.has(rf.factionId) ||
        typeof rf.isAlive !== 'boolean' ||
        !SaveManager.isNonNegativeNumber(rf.gold) ||
        !SaveManager.isNonNegativeNumber(rf.wood) ||
        !SaveManager.isNonNegativeNumber(rf.grain) ||
        !SaveManager.isNonNegativeNumber(rf.credibility) ||
        !Array.isArray(rf.unlockedTechIds) ||
        !SaveManager.isNonNegativeNumber(rf.commanderLevel) ||
        !SaveManager.isNonNegativeNumber(rf.commanderExp) ||
        !SaveManager.isNonNegativeNumber(rf.betrayalMoralePenaltyBattles) ||
        !SaveManager.isNonNegativeNumber(rf.commanderInjuredTurns) ||
        !Array.isArray(rf.fieldArmyRoster) ||
        typeof rf.armyLocationNodeId !== 'string' ||
        !this.validNodeIds.has(rf.armyLocationNodeId)
      ) {
        return null;
      }

      seenFactions.add(rf.factionId);
      const techs: string[] = [];
      for (let t: number = 0; t < rf.unlockedTechIds.length; t++) {
        if (typeof rf.unlockedTechIds[t] !== 'string') {
          return null;
        }
        techs.push(rf.unlockedTechIds[t]);
      }

      const roster: RosterEntry[] = [];
      for (let r: number = 0; r < rf.fieldArmyRoster.length; r++) {
        const rr: SerializedRosterDto = rf.fieldArmyRoster[r];
        if (
          rr === null ||
          typeof rr !== 'object' ||
          typeof rr.unitType !== 'string' ||
          !this.validUnitIds.has(rr.unitType) ||
          typeof rr.count !== 'number' ||
          !Number.isFinite(rr.count) ||
          rr.count < 0 ||
          typeof rr.corpsRole !== 'string' ||
          !this.validCorpsRoles.has(rr.corpsRole)
        ) {
          return null;
        }
        if (rr.count > 0) {
          const cleanRoster: RosterEntry = {
            unitType: rr.unitType as UnitTypeId,
            count: Math.floor(rr.count),
            corpsRole: rr.corpsRole as ArmyCorpsRole
          };
          roster.push(cleanRoster);
        }
      }

      const cleanFaction: FactionCampaignRuntime = {
        factionId: rf.factionId as FactionId,
        isAlive: this.countNodesOwnedBy(nodes, rf.factionId as FactionId) > 0,
        gold: Math.floor(rf.gold as number),
        wood: Math.floor(rf.wood as number),
        grain: Math.floor(rf.grain as number),
        credibility: Math.min(100, Math.floor(rf.credibility as number)),
        unlockedTechIds: techs,
        commanderLevel: Math.max(1, Math.floor(rf.commanderLevel as number)),
        commanderExp: Math.floor(rf.commanderExp as number),
        betrayalMoralePenaltyBattles: Math.floor(rf.betrayalMoralePenaltyBattles as number),
        commanderInjuredTurns: Math.floor(rf.commanderInjuredTurns as number),
        fieldArmyRoster: roster,
        armyLocationNodeId: rf.armyLocationNodeId
      };
      factions.push(cleanFaction);
    }

    // 3. 严格校验双边外交状态表
    const diplomacy: BilateralDiplomacyState[] = [];
    for (let i: number = 0; i < dto.diplomacy.length; i++) {
      const rd: SerializedDiplomacyDto = dto.diplomacy[i];
      if (
        rd === null ||
        typeof rd !== 'object' ||
        typeof rd.factionA !== 'string' ||
        !this.validFactionIds.has(rd.factionA) ||
        typeof rd.factionB !== 'string' ||
        !this.validFactionIds.has(rd.factionB) ||
        rd.factionA === rd.factionB ||
        typeof rd.relation !== 'number' ||
        !Number.isFinite(rd.relation) ||
        typeof rd.status !== 'string' ||
        !this.validDiploStatuses.has(rd.status) ||
        !SaveManager.isNonNegativeNumber(rd.remainingTurns) ||
        !SaveManager.isNonNegativeNumber(rd.vendettaLockTurns)
      ) {
        return null;
      }

      const clampedRel: number = Math.max(-100, Math.min(100, Math.round(rd.relation)));
      const cleanDiplo: BilateralDiplomacyState = {
        factionA: rd.factionA as FactionId,
        factionB: rd.factionB as FactionId,
        relation: clampedRel,
        status: rd.status as DiplomaticStatus,
        remainingTurns: Math.floor(rd.remainingTurns as number),
        vendettaLockTurns: Math.floor(rd.vendettaLockTurns as number)
      };
      diplomacy.push(cleanDiplo);
    }

    const totalFought: number = SaveManager.isNonNegativeNumber(dto.totalBattlesFought)
      ? Math.floor(dto.totalBattlesFought as number)
      : 0;
    const totalWon: number = SaveManager.isNonNegativeNumber(dto.totalBattlesWon)
      ? Math.floor(dto.totalBattlesWon as number)
      : 0;
    if (totalWon > totalFought) {
      return null;
    }
    const totalKilled: number = SaveManager.isNonNegativeNumber(dto.totalEnemiesKilled)
      ? Math.floor(dto.totalEnemiesKilled as number)
      : 0;

    const logs: string[] = [];
    if (Array.isArray(dto.recentLogs)) {
      for (let i: number = 0; i < dto.recentLogs.length; i++) {
        if (typeof dto.recentLogs[i] === 'string') {
          logs.push(dto.recentLogs[i]);
        }
      }
    }

    const state: CampaignSaveState = {
      schemaVersion: SaveManager.SUPPORTED_SCHEMA_VERSION,
      turnNumber: Math.floor(dto.turnNumber),
      playerFaction: dto.playerFaction as FactionId,
      nodes: nodes,
      factions: factions,
      diplomacy: diplomacy,
      totalBattlesFought: totalFought,
      totalBattlesWon: totalWon,
      totalEnemiesKilled: totalKilled,
      recentLogs: logs
    };
    return state;
  }

  private countNodesOwnedBy(nodes: readonly CampaignNodeRuntime[], factionId: FactionId): number {
    let count: number = 0;
    for (let i: number = 0; i < nodes.length; i++) {
      if (nodes[i].owner === factionId) {
        count++;
      }
    }
    return count;
  }

  private static createEmptySlotSummary(slotIndex: number): SaveSlotSummary {
    const empty: SaveSlotSummary = {
      slotIndex: slotIndex,
      title: SaveManager.defaultSlotLabel(slotIndex),
      factionId: FactionId.YANLONG,
      turnNumber: 0,
      controlledNodes: 0,
      updatedAtIso: '未创建',
      isEmpty: true
    };
    return empty;
  }

  private static defaultSlotLabel(slotIndex: number): string {
    if (slotIndex === SaveManager.AUTO_SAVE_SLOT) {
      return '自动存档槽';
    }
    return `手动存档槽 #${slotIndex}`;
  }

  private static isNonNegativeNumber(val: number | undefined): boolean {
    return typeof val === 'number' && Number.isFinite(val) && val >= 0;
  }
}
