import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
import { FactionId, RouteLaunchParams } from '../model/GameTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'BattlePage';

/**
 * 鸿蒙平板战场大视野与右侧指挥台双栏骨架页
 * 第 1 步停点说明：仅验证平板横竖屏/分屏响应式双栏 HUD 容器，按督工要求暂不编写第 2 步战斗模拟逻辑
 */
@Entry
@Component
struct BattlePage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;
  @State viewModeLabel: string = 'RTS 主帅全局视野（骨架占位）';

  private readonly corpsList: readonly string[] = [
    '1号 · 中军前锋（刀盾+长枪）',
    '2号 · 左翼军团（北路迂回骑兵）',
    '3号 · 右翼军团（南路包抄骑兵）',
    '4号 · 总预备队（重斧/铁浮图）',
    '5号 · 远程攻城群（强弩+投石）',
    '6号 · 辎重护粮队（工兵采运）'
  ];

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private openResultSkeleton(): void {
    const launchParams: RouteLaunchParams = {
      modeKey: 'result_preview',
      modeTitle: '战后结算预览',
      factionId: FactionId.YANLONG
    };
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/BattleResultPage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Open BattleResultPage warning: %{public}s', JSON.stringify(err));
    });
  }

  build() {
    Column({ space: 10 }) {
      // 顶部平板宽幅战场态势条（大尺寸按钮 >= 48vp）
      Row({ space: 12 }) {
        Button('‹ 撤出预览')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 16, right: 16 })
          .fontSize(14)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.goBack();
          })

        Text(`战场 ${GameConstants.BATTLEFIELD_WIDTH}×${GameConstants.BATTLEFIELD_HEIGHT} ｜ 军粮 ${GameConstants.BATTLE_INIT_GRAIN}`)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')

        Text(this.viewModeLabel)
          .fontSize(14)
          .fontColor('#81C784')
          .layoutWeight(1)

        Button('切换主帅上阵 / RTS')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 16, right: 16 })
          .fontSize(14)
          .backgroundColor('#455A64')
          .onClick(() => {
            this.viewModeLabel = this.viewModeLabel.startsWith('RTS')
              ? '亲自上阵英雄模式（刀/枪/弓切换占位）'
              : 'RTS 主帅全局视野（骨架占位）';
          })

        Button('结算页骨架 ›')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 16, right: 16 })
          .fontSize(14)
          .backgroundColor('#6D4C41')
          .onClick(() => {
            this.openResultSkeleton();
          })
      }
      .width('100%')

      // 主体平板双栏：左侧超大 Canvas 战场视口（70%）+ 右侧多军团列表与战术指令侧栏（30%）
      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        Column({ space: 10 }) {
          Text('鸿蒙平板大视野 Canvas 战场画布容器（第 1 步停点：尚未接入第 2 步战斗模拟逻辑）')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ECEFF1')
          Text('第2~3步将在此渲染百人火柴人真刀真枪挥砍格挡、箭雨抛射、铁骑凿阵、八象限合围与主帅提刀拼杀；支持双指缩放与手写笔划路线包抄')
            .fontSize(13)
            .fontColor('#90A4AE')
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .justifyContent(FlexAlign.Center)
        .width(this.isWideScreen ? '70%' : '100%')
        .height(this.isWideScreen ? '100%' : '58%')
        .backgroundColor('#1E1B18')
        .borderRadius(10)
        .border({ width: 1.5, color: '#3E3532' })

        // 右侧军团调度与大按钮战术指令面板
        Column({ space: 8 }) {
          Text('多军团战线列表（点选/手写笔框选）')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD54F')

          List({ space: 6 }) {
            ForEach(this.corpsList, (corpsTitle: string) => {
              ListItem() {
                Text(corpsTitle)
                  .fontSize(13)
                  .fontColor('#FFF8E1')
                  .width('100%')
                  .constraintSize({ minHeight: 42 })
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .backgroundColor('#26201E')
                  .borderRadius(6)
              }
            }, (corpsTitle: string) => corpsTitle)
          }
          .layoutWeight(1)
          .width('100%')

          Text('阵型与复杂战术热区（>=48vp）：[方阵/雁行/锥形/圆阵] · [推进/坚守/冲锋/包抄/钳形合围/诈败/设伏]')
            .fontSize(12)
            .fontColor('#B0BEC5')
            .width('100%')
            .padding(10)
            .backgroundColor('#232020')
            .borderRadius(8)
        }
        .alignItems(HorizontalAlign.Start)
        .width(this.isWideScreen ? '30%' : '100%')
        .height(this.isWideScreen ? '100%' : '42%')
        .margin({ left: this.isWideScreen ? 12 : 0, top: this.isWideScreen ? 0 : 10 })
        .padding(12)
        .backgroundColor('#1A1514')
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
