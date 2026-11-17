import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UNIT_STATIC_CONFIGS } from '../config/UnitConfig';
import { FactionId, RouteLaunchParams, UnitStaticStats } from '../model/GameTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'SetupPage';

/**
 * 战前整军配置骨架页（第 1 步：承载遭遇战 / 守城挑战 / 自定义战场参数入口，不含战斗逻辑）
 */
@Entry
@Component
struct SetupPage {
  @State modeTitle: string = '遭遇战 / 自定义战前整军';

  aboutToAppear(): void {
    const rawParams: Object | undefined = this.getUIContext().getRouter().getParams();
    if (rawParams !== undefined) {
      const typedParams = rawParams as RouteLaunchParams;
      if (typedParams.modeTitle) {
        this.modeTitle = `${typedParams.modeTitle} · 战前整军骨架`;
      }
    }
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private enterBattleSkeleton(): void {
    const launchParams: RouteLaunchParams = {
      modeKey: 'skirmish',
      modeTitle: this.modeTitle,
      factionId: FactionId.YANLONG
    };
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/BattlePage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Enter BattlePage skeleton warning: %{public}s', JSON.stringify(err));
    });
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Button('‹ 返回主菜单')
          .height(34)
          .fontSize(13)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.goBack();
          })

        Text(this.modeTitle)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')

        Blank()

        Button('预览战场 HUD 骨架 ›')
          .height(34)
          .fontSize(13)
          .backgroundColor('#8D6E63')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.enterBattleSkeleton();
          })
      }
      .width('100%')

      Text(`兵种静态配置表预览（共 ${UNIT_STATIC_CONFIGS.length} 种：8 通用 + 8 势力专属）`)
        .fontSize(13)
        .fontColor('#B0BEC5')
        .width('100%')

      Grid() {
        ForEach(UNIT_STATIC_CONFIGS, (unit: UnitStaticStats) => {
          GridItem() {
            Column({ space: 3 }) {
              Text(unit.name)
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFF8E1')
              Text(`HP ${unit.hp} · 攻 ${unit.attack} · 甲 ${unit.armor} · 速 ${unit.moveSpeed}`)
                .fontSize(11)
                .fontColor('#FFD54F')
              Text(`金${unit.cost.gold}/木${unit.cost.wood}/粮${unit.cost.grain} · 人口${unit.popCap}`)
                .fontSize(10)
                .fontColor('#90A4AE')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(8)
            .backgroundColor('#232020')
            .borderRadius(6)
          }
        }, (unit: UnitStaticStats) => unit.id)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(8)
      .rowsGap(8)
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#141110')
  }
}
