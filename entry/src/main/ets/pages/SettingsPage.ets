import { GameConstants } from '../common/GameConstants';
import { GameSessionCoordinator } from '../core/session/GameSessionCoordinator';
import {
  DistantLodPolicy,
  GameSettingsData,
  JoystickHandedness,
  SettingsStore,
  TargetFpsOption
} from '../storage/SettingsStore';

/**
 * 鸿蒙平板（MatePad）高刷显示、M-Pencil 手写笔与英雄摇杆设置双栏正式页（SettingsPage.ets）
 * 左栏（36%）：当前平板适配参数实时遥测与多窗说明；
 * 右栏（64%）：SettingsStore 全项持久化配置大热区面板（按钮高度全部 >= 48vp）。
 */
@Entry
@Component
struct SettingsPage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;
  @StorageProp('winWidthPx') winWidthPx: number = 2560;
  @StorageProp('winHeightPx') winHeightPx: number = 1600;

  @State targetFps: TargetFpsOption = TargetFpsOption.FPS_60;
  @State lodPolicy: DistantLodPolicy = DistantLodPolicy.AUTO_BY_ZOOM;
  @State handedness: JoystickHandedness = JoystickHandedness.LEFT_MOVE_RIGHT_SKILL;
  @State stylusSensitivity: number = 1.0;
  @State effectiveStylusPx: number = GameConstants.STYLUS_PICK_RADIUS_PX;
  @State stylusLineEnabled: boolean = true;
  @State soundEnabled: boolean = true;
  @State soundVolume: number = 0.85;
  @State vibrationEnabled: boolean = true;
  @State tipText: string = '所有设置修改后立即通过 SettingsStore 离线持久化，并在战场渲染器与英雄操控台实时生效。';

  private readonly session: GameSessionCoordinator = GameSessionCoordinator.getInstance();

  aboutToAppear(): void {
    this.syncFromStore();
  }

  private syncFromStore(): void {
    const store: SettingsStore = this.session.getSettingsStore();
    const s: GameSettingsData = store.getSettings();
    this.targetFps = s.targetFps;
    this.lodPolicy = s.distantLodPolicy;
    this.handedness = s.joystickHandedness;
    this.stylusSensitivity = s.stylusSensitivity;
    this.effectiveStylusPx = store.getEffectiveStylusPickRadiusPx();
    this.stylusLineEnabled = s.stylusTacticalLineEnabled;
    this.soundEnabled = s.soundEnabled;
    this.soundVolume = s.soundVolume;
    this.vibrationEnabled = s.vibrationEnabled;
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private lodLabel(policy: DistantLodPolicy): string {
    if (policy === DistantLodPolicy.ALWAYS_HIGH_DETAIL) {
      return '始终完整 8 关节骨骼';
    }
    if (policy === DistantLodPolicy.PERFORMANCE_SAVER) {
      return '分屏/悬浮窗省电精简 LOD';
    }
    return '智能鸟瞰 (<0.60x 自动精简)';
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        Button('‹ 返回主菜单')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 18, right: 18 })
          .fontSize(15)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.goBack();
          })

        Text('游戏设置（MatePad 大屏帧率 LOD · M-Pencil 手写笔 · 虚拟摇杆）')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')
          .layoutWeight(1)

        Button('恢复推荐默认')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 16, right: 16 })
          .fontSize(14)
          .backgroundColor('#4E342E')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.session.getSettingsStore().resetToDefaults();
            this.syncFromStore();
            this.tipText = '已恢复 MatePad 横屏推荐默认配置。';
          })
      }
      .width('100%')

      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        // ==================== 左栏（36%）：平板窗口与手写笔实时参数摘要 ====================
        Column({ space: 10 }) {
          Text('当前平板视口与硬件状态')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD54F')

          Text(`• 窗口像素尺寸：${this.winWidthPx} × ${this.winHeightPx} px`)
            .fontSize(13)
            .fontColor('#ECEFF1')
          Text(`• 响应式分栏模式：${this.isWideScreen ? '横屏宽幅左右双栏' : '竖屏/窄分屏上下自适应'}`)
            .fontSize(13)
            .fontColor('#81C784')
          Text(`• 手指编队点选半径：${GameConstants.FINGER_PICK_RADIUS_PX} px`)
            .fontSize(13)
            .fontColor('#ECEFF1')
          Text(`• M-Pencil 有效拾取半径：${this.effectiveStylusPx} px（倍率 ${this.stylusSensitivity}x）`)
            .fontSize(13)
            .fontColor('#81D4FA')
          Text(`• 目标逻辑步频 / 渲染帧率：30Hz 物理 / ${this.targetFps} FPS`)
            .fontSize(13)
            .fontColor('#FFE082')

          Blank()

          Text(this.tipText)
            .fontSize(12)
            .fontColor('#B0BEC5')
            .lineHeight(19)
            .padding(12)
            .backgroundColor('#232020')
            .borderRadius(8)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width(this.isWideScreen ? '36%' : '100%')
        .height(this.isWideScreen ? '100%' : '38%')
        .padding(16)
        .backgroundColor('#1A1514')
        .borderRadius(10)

        // ==================== 右栏（64%）：交互式设置操控主面板 ====================
        Scroll() {
          Column({ space: 12 }) {
            // 1. 60 / 30 FPS 档位
            Row({ space: 10 }) {
              Text('高分屏战场目标帧率')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#ECEFF1')
                .layoutWeight(1)

              Button('60 FPS 满帧高刷')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(13)
                .backgroundColor(this.targetFps === TargetFpsOption.FPS_60 ? '#2E7D32' : '#2C2624')
                .onClick(() => {
                  this.session.getSettingsStore().setTargetFps(TargetFpsOption.FPS_60);
                  this.syncFromStore();
                })

              Button('30 FPS 分屏省电')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(13)
                .backgroundColor(this.targetFps === TargetFpsOption.FPS_30 ? '#0277BD' : '#2C2624')
                .onClick(() => {
                  this.session.getSettingsStore().setTargetFps(TargetFpsOption.FPS_30);
                  this.syncFromStore();
                })
            }
            .width('100%')

            // 2. 远景百人同屏骨骼 LOD 策略
            Row({ space: 10 }) {
              Text(`远景百人骨骼 LOD：${this.lodLabel(this.lodPolicy)}`)
                .fontSize(14)
                .fontColor('#ECEFF1')
                .layoutWeight(1)

              Button('切换 LOD 策略 ↻')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(13)
                .backgroundColor('#4E342E')
                .onClick(() => {
                  const nextLod: DistantLodPolicy =
                    this.lodPolicy === DistantLodPolicy.AUTO_BY_ZOOM
                      ? DistantLodPolicy.ALWAYS_HIGH_DETAIL
                      : (this.lodPolicy === DistantLodPolicy.ALWAYS_HIGH_DETAIL
                          ? DistantLodPolicy.PERFORMANCE_SAVER
                          : DistantLodPolicy.AUTO_BY_ZOOM);
                  this.session.getSettingsStore().setDistantLodPolicy(nextLod);
                  this.syncFromStore();
                })
            }
            .width('100%')

            // 3. 左右手虚拟摇杆布局
            Row({ space: 10 }) {
              Text('英雄模式虚拟摇杆握持布局')
                .fontSize(15)
                .fontColor('#ECEFF1')
                .layoutWeight(1)

              Button('左手摇杆+右手战吼')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(13)
                .backgroundColor(
                  this.handedness === JoystickHandedness.LEFT_MOVE_RIGHT_SKILL ? '#6A1B9A' : '#2C2624'
                )
                .onClick(() => {
                  this.session
                    .getSettingsStore()
                    .setJoystickHandedness(JoystickHandedness.LEFT_MOVE_RIGHT_SKILL);
                  this.syncFromStore();
                })

              Button('右手摇杆+左手战吼')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(13)
                .backgroundColor(
                  this.handedness === JoystickHandedness.RIGHT_MOVE_LEFT_SKILL ? '#6A1B9A' : '#2C2624'
                )
                .onClick(() => {
                  this.session
                    .getSettingsStore()
                    .setJoystickHandedness(JoystickHandedness.RIGHT_MOVE_LEFT_SKILL);
                  this.syncFromStore();
                })
            }
            .width('100%')

            // 4. M-Pencil 手写笔灵敏度与战术画线开关
            Row({ space: 8 }) {
              Text('M-Pencil 笔尖灵敏度')
                .fontSize(14)
                .fontColor('#ECEFF1')
                .layoutWeight(1)

              Button('0.75x')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(12)
                .backgroundColor(this.stylusSensitivity === 0.75 ? '#00695C' : '#2C2624')
                .onClick(() => {
                  this.session.getSettingsStore().setStylusSensitivity(0.75);
                  this.syncFromStore();
                })
              Button('1.00x')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(12)
                .backgroundColor(this.stylusSensitivity === 1.0 ? '#00695C' : '#2C2624')
                .onClick(() => {
                  this.session.getSettingsStore().setStylusSensitivity(1.0);
                  this.syncFromStore();
                })
              Button('1.25x')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(12)
                .backgroundColor(this.stylusSensitivity === 1.25 ? '#00695C' : '#2C2624')
                .onClick(() => {
                  this.session.getSettingsStore().setStylusSensitivity(1.25);
                  this.syncFromStore();
                })
              Button('1.50x')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(12)
                .backgroundColor(this.stylusSensitivity === 1.5 ? '#00695C' : '#2C2624')
                .onClick(() => {
                  this.session.getSettingsStore().setStylusSensitivity(1.5);
                  this.syncFromStore();
                })
            }
            .width('100%')

            Row() {
              Text('M-Pencil 手绘迂回曲线直接生成包抄航点')
                .fontSize(15)
                .fontColor('#ECEFF1')
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.stylusLineEnabled })
                .onChange((isOn: boolean) => {
                  this.session.getSettingsStore().setStylusTacticalLineEnabled(isOn);
                  this.syncFromStore();
                })
            }
            .width('100%')
            .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })

            // 5. 音效与主音量、重劈震屏开关
            Row({ space: 8 }) {
              Text(`冷兵器金铁音效（音量 ${Math.round(this.soundVolume * 100)}%）`)
                .fontSize(14)
                .fontColor('#ECEFF1')
                .layoutWeight(1)

              Button('音量-25%')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(12)
                .backgroundColor('#2C2624')
                .onClick(() => {
                  this.session
                    .getSettingsStore()
                    .setSoundEnabled(this.soundEnabled, Math.max(0, this.soundVolume - 0.25));
                  this.syncFromStore();
                })
              Button('音量+25%')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(12)
                .backgroundColor('#2C2624')
                .onClick(() => {
                  this.session
                    .getSettingsStore()
                    .setSoundEnabled(this.soundEnabled, Math.min(1.0, this.soundVolume + 0.25));
                  this.syncFromStore();
                })
              Toggle({ type: ToggleType.Switch, isOn: this.soundEnabled })
                .onChange((isOn: boolean) => {
                  this.session.getSettingsStore().setSoundEnabled(isOn);
                  this.syncFromStore();
                })
            }
            .width('100%')
            .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })

            Row() {
              Text('主帅重劈 40ms 卡肉顿帧微震屏与战吼反馈')
                .fontSize(15)
                .fontColor('#ECEFF1')
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.vibrationEnabled })
                .onChange((isOn: boolean) => {
                  this.session.getSettingsStore().setVibrationEnabled(isOn);
                  this.syncFromStore();
                })
            }
            .width('100%')
            .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })
          }
          .width('100%')
        }
        .width(this.isWideScreen ? '64%' : '100%')
        .height(this.isWideScreen ? '100%' : '62%')
        .margin({ left: this.isWideScreen ? 14 : 0, top: this.isWideScreen ? 0 : 10 })
        .padding(18)
        .backgroundColor('#232020')
        .borderRadius(10)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#141110')
  }
}
