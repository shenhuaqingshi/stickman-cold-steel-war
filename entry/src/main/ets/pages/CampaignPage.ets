import { GameConstants } from '../common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS } from '../config/FactionConfig';
import { CampaignNodeConfig, FactionStaticConfig } from '../model/GameTypes';

/**
 * 战役战略大地图与外交纵横平板双栏骨架页（第 1 步：左侧大地图视口/城关 + 右侧外交详情侧栏，不含战役与战斗逻辑）
 */
@Entry
@Component
struct CampaignPage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;
  @State selectedNodeIndex: number = 20;

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  build() {
    Column({ space: 12 }) {
      // 顶部平板宽幅战略状态栏（触控按钮高度 >= 48vp）
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

        Text(`战略大地图（${GameConstants.CAMPAIGN_MAP_WIDTH}×${GameConstants.CAMPAIGN_MAP_HEIGHT} · ${GameConstants.CAMPAIGN_REGION_COUNT}大区 · ${CAMPAIGN_MAP_NODES.length}城关）`)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')
          .layoutWeight(1)

        Text('支持双指缩放漫游 / M-Pencil 点选城关')
          .fontSize(13)
          .fontColor('#81C784')
      }
      .width('100%')

      // 主体响应式双栏：左侧战略大地图城关视野区（65%）+ 右侧城防粮道与八国外交谈判侧栏（35%）
      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        Column({ space: 10 }) {
          Text(`左侧大地图主视口骨架（点选任一城关可在右侧查看驻防与粮道详情，共 ${CAMPAIGN_MAP_NODES.length} 节点）`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F5E6C8')

          Grid() {
            ForEach(CAMPAIGN_MAP_NODES, (node: CampaignNodeConfig, idx: number) => {
              GridItem() {
                Column({ space: 4 }) {
                  Text(`${node.name} [${node.regionName}]`)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFF8E1')
                  Text(`坐标(${node.x},${node.y}) · 城防Lv.${node.defenseLevel} · 邻路${node.neighbors.length}条`)
                    .fontSize(12)
                    .fontColor('#90A4AE')
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })
                .padding(10)
                .backgroundColor(this.selectedNodeIndex === idx ? '#3E2E28' : '#221E1D')
                .borderRadius(8)
                .border({
                  width: 1,
                  color: this.selectedNodeIndex === idx ? '#D4A843' : '#332C2A'
                })
                .onClick(() => {
                  this.selectedNodeIndex = idx;
                })
              }
            }, (node: CampaignNodeConfig) => node.id)
          }
          .columnsTemplate(this.isWideScreen ? '1fr 1fr 1fr' : '1fr 1fr')
          .columnsGap(10)
          .rowsGap(10)
          .layoutWeight(1)
          .width('100%')
        }
        .width(this.isWideScreen ? '65%' : '100%')
        .height(this.isWideScreen ? '100%' : '56%')
        .padding(14)
        .backgroundColor('#1A1514')
        .borderRadius(10)

        Column({ space: 10 }) {
          Text(`选中要地：${CAMPAIGN_MAP_NODES[this.selectedNodeIndex].name}`)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD54F')

          Text(`产金 ${CAMPAIGN_MAP_NODES[this.selectedNodeIndex].goldYield} · 产木 ${CAMPAIGN_MAP_NODES[this.selectedNodeIndex].woodYield} · 产粮 ${CAMPAIGN_MAP_NODES[this.selectedNodeIndex].grainYield} · ${CAMPAIGN_MAP_NODES[this.selectedNodeIndex].isSupplyDepot ? '核心补给仓城' : '前线战略节点'}`)
            .fontSize(13)
            .fontColor('#B0BEC5')

          Text('八方外交关系与议和入口侧栏（结盟/媾和/宣战）')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F5E6C8')
            .margin({ top: 4 })

          List({ space: 8 }) {
            ForEach(FACTION_STATIC_CONFIGS, (faction: FactionStaticConfig) => {
              ListItem() {
                Row() {
                  Text(faction.name)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#ECEFF1')
                  Blank()
                  Text(`信誉 ${faction.startingCredibility} · 派使谈判`)
                    .fontSize(13)
                    .fontColor('#FFD54F')
                }
                .width('100%')
                .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .backgroundColor('#232020')
                .borderRadius(8)
              }
            }, (faction: FactionStaticConfig) => faction.id)
          }
          .layoutWeight(1)
          .width('100%')
        }
        .width(this.isWideScreen ? '35%' : '100%')
        .height(this.isWideScreen ? '100%' : '44%')
        .margin({ left: this.isWideScreen ? 12 : 0, top: this.isWideScreen ? 0 : 10 })
        .padding(14)
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
