/**
 * 鸿蒙平板（MatePad）显示、触控摇杆、M-Pencil 手写笔与音效震动设置存储（SettingsStore.ets）
 * 严格遵循 HarmonyOS NEXT ArkTS 静态类型规范（零 any / unknown，零 @kit.ArkUI 硬依赖）
 *
 * 管理维度：
 * 1. 60 / 30 FPS 帧率上限档位（适配平板满帧模式与分屏/悬浮窗省电稳帧模式）；
 * 2. 远景百人同屏骨骼 LOD 策略（自动鸟瞰精简 / 强制高精 / 省电精简）；
 * 3. 英雄模式左右手虚拟摇杆布局切换；
 * 4. 华为 M-Pencil 手写笔灵敏度系数 [0.25, 2.0] 与沙盘画线包抄开关；
 * 5. 冷兵器金铁音效开关、主音量 [0.0, 1.0] 与破阵震动反馈开关。
 */
import { GameConstants } from '../common/GameConstants';
import { InMemoryPersistenceBackend, PersistenceBackendAdapter } from './SaveManager';

/** 帧率上限档位枚举 */
export enum TargetFpsOption {
  FPS_60 = 60,
  FPS_30 = 30
}

/** 远景百人同屏骨骼 LOD 档位枚举 */
export enum DistantLodPolicy {
  AUTO_BY_ZOOM = 'auto_by_zoom',       // 缩放 < 0.60x 自动切入远景精简 LOD（推荐）
  ALWAYS_HIGH_DETAIL = 'high_detail',  // 始终保留完整 8 关节肘膝细节
  PERFORMANCE_SAVER = 'perf_saver'     // 积极启用精简 LOD 降低分屏负载
}

/** 英雄模式大尺寸虚拟摇杆左右手布局枚举 */
export enum JoystickHandedness {
  LEFT_MOVE_RIGHT_SKILL = 'left_handed',  // 左手移动摇杆 + 右手兵刃战吼轮盘
  RIGHT_MOVE_LEFT_SKILL = 'right_handed'  // 右手移动摇杆 + 左手兵刃战吼轮盘
}

/** 全局可序列化用户设置结构 */
export interface GameSettingsData {
  readonly schemaVersion: number;
  readonly targetFps: TargetFpsOption;
  readonly distantLodPolicy: DistantLodPolicy;
  readonly joystickHandedness: JoystickHandedness;
  /** M-Pencil 手写笔采样与拾取灵敏度倍率 [0.25, 2.0]，默认 1.0 */
  readonly stylusSensitivity: number;
  /** 是否开启 M-Pencil 手写笔在战场上直接手绘迂回曲线生成航点 */
  readonly stylusTacticalLineEnabled: boolean;
  readonly soundEnabled: boolean;
  /** 全局音效主音量 [0.0, 1.0] */
  readonly soundVolume: number;
  readonly vibrationEnabled: boolean;
}

/** 部分更新请求参数 */
export interface GameSettingsPatch {
  readonly targetFps?: TargetFpsOption;
  readonly distantLodPolicy?: DistantLodPolicy;
  readonly joystickHandedness?: JoystickHandedness;
  readonly stylusSensitivity?: number;
  readonly stylusTacticalLineEnabled?: boolean;
  readonly soundEnabled?: boolean;
  readonly soundVolume?: number;
  readonly vibrationEnabled?: boolean;
}

/** 反序列化校验候选结构 */
interface RawSettingsCandidate {
  readonly schemaVersion?: number;
  readonly targetFps?: number;
  readonly distantLodPolicy?: string;
  readonly joystickHandedness?: string;
  readonly stylusSensitivity?: number;
  readonly stylusTacticalLineEnabled?: boolean;
  readonly soundEnabled?: boolean;
  readonly soundVolume?: number;
  readonly vibrationEnabled?: boolean;
}

/**
 * 平板设置内存缓存与本地持久化管理器
 */
export class SettingsStore {
  public static readonly SETTINGS_STORAGE_KEY: string = 'stickman_war_tablet_settings_v1';
  public static readonly CURRENT_SCHEMA_VERSION: number = 1;
  public static readonly MIN_STYLUS_SENSITIVITY: number = 0.25;
  public static readonly MAX_STYLUS_SENSITIVITY: number = 2.0;

  private backend: PersistenceBackendAdapter;
  private current: GameSettingsData;

  public constructor(backend?: PersistenceBackendAdapter) {
    this.backend = backend !== undefined ? backend : new InMemoryPersistenceBackend();
    this.current = SettingsStore.createDefaultSettings();
    this.reloadFromBackend();
  }

  /**
   * 生成 MatePad 大屏横屏推荐默认设置
   */
  public static createDefaultSettings(): GameSettingsData {
    const defaults: GameSettingsData = {
      schemaVersion: SettingsStore.CURRENT_SCHEMA_VERSION,
      targetFps: TargetFpsOption.FPS_60,
      distantLodPolicy: DistantLodPolicy.AUTO_BY_ZOOM,
      joystickHandedness: JoystickHandedness.LEFT_MOVE_RIGHT_SKILL,
      stylusSensitivity: 1.0,
      stylusTacticalLineEnabled: true,
      soundEnabled: true,
      soundVolume: 0.85,
      vibrationEnabled: true
    };
    return defaults;
  }

  /**
   * 绑定持久化后端并立即尝试同步已有配置（若为空或损坏则安全回退默认值）
   */
  public setBackend(backend: PersistenceBackendAdapter): GameSettingsData {
    this.backend = backend;
    return this.reloadFromBackend();
  }

  /**
   * 获取当前完整设置快照（返回不可变拷贝）
   */
  public getSettings(): GameSettingsData {
    return SettingsStore.cloneSettings(this.current);
  }

  /**
   * 从持久化后端重新加载配置；遇到损坏 JSON 或非法版本号时绝不崩溃，自动回退默认配置
   */
  public reloadFromBackend(): GameSettingsData {
    let raw: string | null = null;
    try {
      raw = this.backend.readText(SettingsStore.SETTINGS_STORAGE_KEY);
    } catch (e) {
      this.current = SettingsStore.createDefaultSettings();
      return this.getSettings();
    }

    if (raw === null || raw.trim().length === 0) {
      this.current = SettingsStore.createDefaultSettings();
      return this.getSettings();
    }

    try {
      const parsed: RawSettingsCandidate | null = JSON.parse(raw) as RawSettingsCandidate | null;
      if (
        parsed === null ||
        typeof parsed !== 'object' ||
        Array.isArray(parsed) ||
        parsed.schemaVersion !== SettingsStore.CURRENT_SCHEMA_VERSION
      ) {
        this.current = SettingsStore.createDefaultSettings();
        return this.getSettings();
      }
      this.current = SettingsStore.sanitizeCandidate(parsed);
    } catch (e) {
      this.current = SettingsStore.createDefaultSettings();
    }

    return this.getSettings();
  }

  /**
   * 批量更新部分配置并立即写入后端存储
   */
  public updateSettings(patch: GameSettingsPatch): GameSettingsData {
    const nextFps: TargetFpsOption =
      patch.targetFps !== undefined
        ? SettingsStore.normalizeFps(patch.targetFps)
        : this.current.targetFps;
    const nextLod: DistantLodPolicy =
      patch.distantLodPolicy !== undefined
        ? SettingsStore.normalizeLod(patch.distantLodPolicy)
        : this.current.distantLodPolicy;
    const nextHand: JoystickHandedness =
      patch.joystickHandedness !== undefined
        ? SettingsStore.normalizeHandedness(patch.joystickHandedness)
        : this.current.joystickHandedness;
    const nextSens: number =
      patch.stylusSensitivity !== undefined
        ? SettingsStore.normalizeStylusSensitivity(patch.stylusSensitivity)
        : this.current.stylusSensitivity;
    const nextLine: boolean =
      patch.stylusTacticalLineEnabled !== undefined
        ? patch.stylusTacticalLineEnabled
        : this.current.stylusTacticalLineEnabled;
    const nextSound: boolean =
      patch.soundEnabled !== undefined ? patch.soundEnabled : this.current.soundEnabled;
    const nextVol: number =
      patch.soundVolume !== undefined
        ? SettingsStore.normalizeVolume(patch.soundVolume)
        : this.current.soundVolume;
    const nextVib: boolean =
      patch.vibrationEnabled !== undefined ? patch.vibrationEnabled : this.current.vibrationEnabled;

    const updated: GameSettingsData = {
      schemaVersion: SettingsStore.CURRENT_SCHEMA_VERSION,
      targetFps: nextFps,
      distantLodPolicy: nextLod,
      joystickHandedness: nextHand,
      stylusSensitivity: nextSens,
      stylusTacticalLineEnabled: nextLine,
      soundEnabled: nextSound,
      soundVolume: nextVol,
      vibrationEnabled: nextVib
    };

    this.current = updated;
    this.persistCurrent();
    return this.getSettings();
  }

  /**
   * 设置 60 / 30 FPS 帧率档位
   */
  public setTargetFps(fps: TargetFpsOption): GameSettingsData {
    const patch: GameSettingsPatch = { targetFps: fps };
    return this.updateSettings(patch);
  }

  /**
   * 设置远景骨骼 LOD 策略
   */
  public setDistantLodPolicy(policy: DistantLodPolicy): GameSettingsData {
    const patch: GameSettingsPatch = { distantLodPolicy: policy };
    return this.updateSettings(patch);
  }

  /**
   * 设置英雄模式左右手虚拟摇杆布局
   */
  public setJoystickHandedness(handedness: JoystickHandedness): GameSettingsData {
    const patch: GameSettingsPatch = { joystickHandedness: handedness };
    return this.updateSettings(patch);
  }

  /**
   * 设置 M-Pencil 手写笔灵敏度（自动钳制在 [0.25, 2.0] 安全范围）
   */
  public setStylusSensitivity(sensitivity: number): GameSettingsData {
    const patch: GameSettingsPatch = { stylusSensitivity: sensitivity };
    return this.updateSettings(patch);
  }

  /**
   * 设置 M-Pencil 战术画线生成包抄航点开关
   */
  public setStylusTacticalLineEnabled(enabled: boolean): GameSettingsData {
    const patch: GameSettingsPatch = { stylusTacticalLineEnabled: enabled };
    return this.updateSettings(patch);
  }

  /**
   * 设置音效开关与可选主音量
   */
  public setSoundEnabled(enabled: boolean, volume?: number): GameSettingsData {
    if (volume !== undefined) {
      const volPatch: GameSettingsPatch = { soundEnabled: enabled, soundVolume: volume };
      return this.updateSettings(volPatch);
    }
    const patch: GameSettingsPatch = { soundEnabled: enabled };
    return this.updateSettings(patch);
  }

  /**
   * 设置破阵重击与战吼微震动开关
   */
  public setVibrationEnabled(enabled: boolean): GameSettingsData {
    const patch: GameSettingsPatch = { vibrationEnabled: enabled };
    return this.updateSettings(patch);
  }

  /**
   * 计算当前手写笔灵敏度下的有效点选拾取半径（px）
   */
  public getEffectiveStylusPickRadiusPx(): number {
    return Math.round(GameConstants.STYLUS_PICK_RADIUS_PX * this.current.stylusSensitivity);
  }

  /**
   * 一键恢复出厂默认设置并持久化
   */
  public resetToDefaults(): GameSettingsData {
    this.current = SettingsStore.createDefaultSettings();
    this.persistCurrent();
    return this.getSettings();
  }

  private persistCurrent(): void {
    try {
      this.backend.writeText(SettingsStore.SETTINGS_STORAGE_KEY, JSON.stringify(this.current));
    } catch (e) {
      // 忽略沙箱只读或磁盘满异常，保持内存态可用不闪退
    }
  }

  private static sanitizeCandidate(raw: RawSettingsCandidate): GameSettingsData {
    const defaults: GameSettingsData = SettingsStore.createDefaultSettings();
    const fps: TargetFpsOption =
      typeof raw.targetFps === 'number'
        ? SettingsStore.normalizeFps(raw.targetFps)
        : defaults.targetFps;
    const lod: DistantLodPolicy =
      typeof raw.distantLodPolicy === 'string'
        ? SettingsStore.normalizeLod(raw.distantLodPolicy)
        : defaults.distantLodPolicy;
    const hand: JoystickHandedness =
      typeof raw.joystickHandedness === 'string'
        ? SettingsStore.normalizeHandedness(raw.joystickHandedness)
        : defaults.joystickHandedness;
    const sens: number =
      typeof raw.stylusSensitivity === 'number'
        ? SettingsStore.normalizeStylusSensitivity(raw.stylusSensitivity)
        : defaults.stylusSensitivity;
    const lineEnabled: boolean =
      typeof raw.stylusTacticalLineEnabled === 'boolean'
        ? raw.stylusTacticalLineEnabled
        : defaults.stylusTacticalLineEnabled;
    const soundOn: boolean =
      typeof raw.soundEnabled === 'boolean' ? raw.soundEnabled : defaults.soundEnabled;
    const soundVol: number =
      typeof raw.soundVolume === 'number'
        ? SettingsStore.normalizeVolume(raw.soundVolume)
        : defaults.soundVolume;
    const vibOn: boolean =
      typeof raw.vibrationEnabled === 'boolean' ? raw.vibrationEnabled : defaults.vibrationEnabled;

    const clean: GameSettingsData = {
      schemaVersion: SettingsStore.CURRENT_SCHEMA_VERSION,
      targetFps: fps,
      distantLodPolicy: lod,
      joystickHandedness: hand,
      stylusSensitivity: sens,
      stylusTacticalLineEnabled: lineEnabled,
      soundEnabled: soundOn,
      soundVolume: soundVol,
      vibrationEnabled: vibOn
    };
    return clean;
  }

  private static normalizeFps(val: number): TargetFpsOption {
    return val === 30 ? TargetFpsOption.FPS_30 : TargetFpsOption.FPS_60;
  }

  private static normalizeLod(val: string): DistantLodPolicy {
    if (val === DistantLodPolicy.ALWAYS_HIGH_DETAIL) {
      return DistantLodPolicy.ALWAYS_HIGH_DETAIL;
    }
    if (val === DistantLodPolicy.PERFORMANCE_SAVER) {
      return DistantLodPolicy.PERFORMANCE_SAVER;
    }
    return DistantLodPolicy.AUTO_BY_ZOOM;
  }

  private static normalizeHandedness(val: string): JoystickHandedness {
    if (val === JoystickHandedness.RIGHT_MOVE_LEFT_SKILL) {
      return JoystickHandedness.RIGHT_MOVE_LEFT_SKILL;
    }
    return JoystickHandedness.LEFT_MOVE_RIGHT_SKILL;
  }

  private static normalizeStylusSensitivity(val: number): number {
    if (!Number.isFinite(val)) {
      return 1.0;
    }
    const clamped: number = Math.max(
      SettingsStore.MIN_STYLUS_SENSITIVITY,
      Math.min(SettingsStore.MAX_STYLUS_SENSITIVITY, val)
    );
    return Math.round(clamped * 100) / 100;
  }

  private static normalizeVolume(val: number): number {
    if (!Number.isFinite(val)) {
      return 0.85;
    }
    const clamped: number = Math.max(0.0, Math.min(1.0, val));
    return Math.round(clamped * 100) / 100;
  }

  private static cloneSettings(src: GameSettingsData): GameSettingsData {
    const copy: GameSettingsData = {
      schemaVersion: src.schemaVersion,
      targetFps: src.targetFps,
      distantLodPolicy: src.distantLodPolicy,
      joystickHandedness: src.joystickHandedness,
      stylusSensitivity: src.stylusSensitivity,
      stylusTacticalLineEnabled: src.stylusTacticalLineEnabled,
      soundEnabled: src.soundEnabled,
      soundVolume: src.soundVolume,
      vibrationEnabled: src.vibrationEnabled
    };
    return copy;
  }
}
