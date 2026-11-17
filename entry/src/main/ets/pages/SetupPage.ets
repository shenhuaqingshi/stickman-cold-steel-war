import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
import { UNIT_STATIC_CONFIGS } from '../config/UnitConfig';
import { FactionId, RouteLaunchParams, UnitStaticStats } from '../model/GameTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'SetupPage';

/**
 * 战前整军平板双栏骨架页（第 1 步：左侧 16 兵种名册 + 右侧多军团编组与粮草配置栏，不含战斗模拟逻辑）
 */
@Entry
@Component
struct SetupPage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;
  @State modeTitle: string = '遭遇战 · 战前整军大屏配置';
  @State selectedUnitIndex: number = 1;

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

        Text(this.modeTitle)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')
          .layoutWeight(1)

        Button('进入平板战场视口骨架 ›')
          .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
          .padding({ left: 22, right: 22 })
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#8D6E63')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.enterBattleSkeleton();
          })
      }
      .width('100%')

      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        // 左侧（62%）：16 种冷兵器兵种招募名册
        Column({ space: 10 }) {
          Text(`全兵种编制名册（共 ${UNIT_STATIC_CONFIGS.length} 种：点选兵种在右栏检阅详细克制关系）`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F5E6C8')

          Grid() {
            ForEach(UNIT_STATIC_CONFIGS, (unit: UnitStaticStats, idx: number) => {
              GridItem() {
                Column({ space: 4 }) {
                  Text(unit.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#FFF8E1')
                  Text(`HP ${unit.hp} · 攻 ${unit.attack} · 甲 ${unit.armor} · 速 ${unit.moveSpeed}`)
                    .fontSize(12)
                    .fontColor('#FFD54F')
                  Text(`金${unit.cost.gold}/木${unit.cost.wood}/粮${unit.cost.grain} · 人口${unit.popCap}`)
                    .fontSize(11)
                    .fontColor('#90A4AE')
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .constraintSize({ minHeight: GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP })
                .padding(10)
                .backgroundColor(this.selectedUnitIndex === idx ? '#3E2E28' : '#232020')
                .borderRadius(8)
                .border({
                  width: 1,
                  color: this.selectedUnitIndex === idx ? '#D4A843' : '#373232'
                })
                .onClick(() => {
                  this.selectedUnitIndex = idx;
                })
              }
            }, (unit: UnitStaticStats) => unit.id)
          }
          .columnsTemplate(this.isWideScreen ? '1fr 1fr 1fr' : '1fr 1fr')
          .columnsGap(10)
          .rowsGap(10)
          .layoutWeight(1)
          .width('100%')
        }
        .width(this.isWideScreen ? '62%' : '100%')
        .height(this.isWideScreen ? '100%' : '58%')
        .padding(14)
        .backgroundColor('#1A1514')
        .borderRadius(10)

        // 右侧（38%）：选中兵种详评与前锋/两翼/预备队配给预览
        Column({ space: 12 }) {
          Text(`兵种检阅：${UNIT_STATIC_CONFIGS[this.selectedUnitIndex].name}`)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#D4A843')

          Text(UNIT_STATIC_CONFIGS[this.selectedUnitIndex].traitDesc)
            .fontSize(14)
            .fontColor('#ECEFF1')
            .lineHeight(22)

          Text(`破甲率 ${Math.round(UNIT_STATIC_CONFIGS[this.selectedUnitIndex].armorPenetration * 100)}% ｜ 正面盾减伤 ${Math.round(UNIT_STATIC_CONFIGS[this.selectedUnitIndex].shieldRangedBlock * 100)}% ｜ 反骑倍率 ${UNIT_STATIC_CONFIGS[this.selectedUnitIndex].antiCavalryMultiplier}x`)
            .fontSize(13)
            .fontColor('#81C784')

          Column({ space: 6 }) {
            Text('战前军团部署与携行后勤标准')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#F5E6C8')
            Text(`• 标准战场尺度：${GameConstants.BATTLEFIELD_WIDTH} × ${GameConstants.BATTLEFIELD_HEIGHT} px`)
              .fontSize(13)
              .fontColor('#B0BEC5')
            Text(`• 初始携行军资：金 ${GameConstants.BATTLE_INIT_GOLD} / 木 ${GameConstants.BATTLE_INIT_WOOD} / 粮 ${GameConstants.BATTLE_INIT_GRAIN}`)
              .fontSize(13)
              .fontColor('#B0BEC5')
            Text(`• 多线建制上限：${GameConstants.MAX_ARMY_CORPS_GROUPS} 大独立军团（前锋/左翼/右翼/预备队/攻城/护粮）`)
              .fontSize(13)
              .fontColor('#B0BEC5')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .backgroundColor('#232020')
          .borderRadius(8)
        }
        .alignItems(HorizontalAlign.Start)
        .width(this.isWideScreen ? '38%' : '100%')
        .height(this.isWideScreen ? '100%' : '42%')
        .margin({ left: this.isWideScreen ? 12 : 0, top: this.isWideScreen ? 0 : 10 })
        .padding(16)
        .backgroundColor('#1A1514')
        .borderRadius(10)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(18)
    .backgroundColor('#141110')
  }
}
