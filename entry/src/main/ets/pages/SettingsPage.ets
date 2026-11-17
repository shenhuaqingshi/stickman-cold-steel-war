/**
 * 游戏设置骨架页（第 1 步：画质帧率、视口 LOD、触控摇杆与音效开关容器）
 */
@Entry
@Component
struct SettingsPage {
  @State targetFpsMode: string = '60 FPS 高刷流畅档';
  @State joystickLeftHanded: boolean = true;
  @State soundEnabled: boolean = true;

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Button('‹ 返回主菜单')
          .height(34)
          .fontSize(13)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.goBack();
          })

        Text('游戏设置（骨架页）')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')
      }
      .width('100%')

      Column({ space: 12 }) {
        Row() {
          Text('战场帧率与同屏 LOD 策略')
            .fontSize(14)
            .fontColor('#ECEFF1')
          Blank()
          Button(this.targetFpsMode)
            .height(32)
            .fontSize(12)
            .backgroundColor('#4E342E')
            .onClick(() => {
              this.targetFpsMode = this.targetFpsMode.startsWith('60')
                ? '30 FPS 省电稳帧档'
                : '60 FPS 高刷流畅档';
            })
        }
        .width('100%')

        Row() {
          Text('英雄模式虚拟摇杆布局（左手移动 / 右手挥砍技能）')
            .fontSize(14)
            .fontColor('#ECEFF1')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.joystickLeftHanded })
            .onChange((isOn: boolean) => {
              this.joystickLeftHanded = isOn;
            })
        }
        .width('100%')

        Row() {
          Text('冷兵器金铁交鸣与战鼓音效')
            .fontSize(14)
            .fontColor('#ECEFF1')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.soundEnabled })
            .onChange((isOn: boolean) => {
              this.soundEnabled = isOn;
            })
        }
        .width('100%')
      }
      .padding(16)
      .backgroundColor('#232020')
      .borderRadius(8)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#141110')
  }
}
