import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
import { FactionId, RouteLaunchParams } from '../model/GameTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'BattlePage';

/**
 * 战场 HUD 与 Canvas 视口容器骨架页（第 1 步：仅搭页面布局骨架，严格按要求暂不编写战斗模拟逻辑）
 */
@Entry
@Component
struct BattlePage {
  @State viewModeLabel: string = 'RTS 主帅上帝视角（骨架占位）';

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
      // 顶部战场态势栏占位（资源/粮草预警/总士气/视角切换/暂停）
      Row({ space: 12 }) {
        Button('‹ 退出战场')
          .height(32)
          .fontSize(12)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.goBack();
          })

        Text(`战场逻辑尺寸 ${GameConstants.BATTLEFIELD_WIDTH}×${GameConstants.BATTLEFIELD_HEIGHT}`)
          .fontSize(13)
          .fontColor('#D4A843')

        Text(this.viewModeLabel)
          .fontSize(13)
          .fontColor('#81C784')

        Blank()

        Button('切换主帅/RTS占位')
          .height(32)
          .fontSize(12)
          .backgroundColor('#455A64')
          .onClick(() => {
            this.viewModeLabel = this.viewModeLabel.startsWith('RTS')
              ? '主帅亲自上阵英雄视角（骨架占位）'
              : 'RTS 主帅上帝视角（骨架占位）';
          })

        Button('结算页骨架 ›')
          .height(32)
          .fontSize(12)
          .backgroundColor('#6D4C41')
          .onClick(() => {
            this.openResultSkeleton();
          })
      }
      .width('100%')

      // 中央战场画布预留容器
      Column({ space: 8 }) {
        Text('Canvas 大战场视口容器（第 1 步停点：尚未接入战斗模拟、寻敌与渲染循环）')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#ECEFF1')
        Text('将在督工验收第 1 步后，按 DESIGN.md 接入空间哈希寻敌、批量火柴人绘制、阵型士气与英雄操控')
          .fontSize(12)
          .fontColor('#90A4AE')
      }
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#1E1B18')
      .borderRadius(8)
      .border({ width: 1, color: '#3E3532' })

      // 底部指令条占位（招募/阵型/战术指令/英雄技能槽）
      Row({ space: 8 }) {
        Text('底部指挥栏占位：[方阵] [雁行] [锥形] [圆阵]  |  [稳步推进] [坚守] [全军冲锋] [交替撤退] [侧翼包抄]')
          .fontSize(12)
          .fontColor('#B0BEC5')
      }
      .width('100%')
      .padding(10)
      .backgroundColor('#1A1514')
      .borderRadius(6)
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor('#141110')
  }
}
