import { GameConstants } from '../common/GameConstants';

/**
 * 游戏设置平板适配骨架页（第 1 步：平板高刷 LOD、手写笔模式、左右手虚拟摇杆与音效配置）
 */
@Entry
@Component
struct SettingsPage {
  @State targetFpsMode: string = '60 FPS 平板高刷满帧档';
  @State stylusTacticalLineEnabled: boolean = true;
  @State joystickLeftHanded: boolean = true;
  @State soundEnabled: boolean = true;

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  build() {
    Column({ space: 16 }) {
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

        Text('游戏设置（MatePad 平板显示与触控手写笔配置）')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')
      }
      .width('100%')

      Column({ space: 16 }) {
        Row() {
          Text('高分屏战场帧率与百人同屏 LOD 档位')
            .fontSize(16)
            .fontColor('#ECEFF1')
          Blank()
          Button(this.targetFpsMode)
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .padding({ left: 18, right: 18 })
            .fontSize(14)
            .backgroundColor('#4E342E')
            .onClick(() => {
              this.targetFpsMode = this.targetFpsMode.startsWith('60')
                ? '30 FPS 分屏省电稳帧档'
                : '60 FPS 平板高刷满帧档';
            })
        }
        .width('100%')

        Row() {
          Text('手写笔（M-Pencil）精准点选编队与画线规划包抄路径')
            .fontSize(16)
            .fontColor('#ECEFF1')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.stylusTacticalLineEnabled })
            .onChange((isOn: boolean) => {
              this.stylusTacticalLineEnabled = isOn;
            })
        }
        .width('100%')
        .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })

        Row() {
          Text('英雄模式大尺寸虚拟摇杆布局（左摇杆移动 / 右侧武器与战吼）')
            .fontSize(16)
            .fontColor('#ECEFF1')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.joystickLeftHanded })
            .onChange((isOn: boolean) => {
              this.joystickLeftHanded = isOn;
            })
        }
        .width('100%')
        .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })

        Row() {
          Text('冷兵器金铁交鸣、战鼓号角与震屏反馈')
            .fontSize(16)
            .fontColor('#ECEFF1')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.soundEnabled })
            .onChange((isOn: boolean) => {
              this.soundEnabled = isOn;
            })
        }
        .width('100%')
        .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })
      }
      .padding(20)
      .backgroundColor('#232020')
      .borderRadius(10)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(18)
    .backgroundColor('#141110')
  }
}
