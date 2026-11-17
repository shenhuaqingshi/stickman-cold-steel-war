import { GameConstants } from '../common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS } from '../config/FactionConfig';
import { CampaignNodeConfig, FactionStaticConfig } from '../model/GameTypes';

/**
 * 战役战略大地图与外交总览骨架页（第 1 步：Stage 路由容器与静态拓扑预览，不含战役回合与战斗逻辑）
 */
@Entry
@Component
struct CampaignPage {
  @State selectedRegion: number = 5;

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  build() {
    Column({ space: 12 }) {
      // 顶部战略导航条
      Row({ space: 12 }) {
        Button('‹ 返回主菜单')
          .height(34)
          .fontSize(13)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.goBack();
          })

        Text(`战役战略大地图骨架（${GameConstants.CAMPAIGN_MAP_WIDTH}×${GameConstants.CAMPAIGN_MAP_HEIGHT} · ${GameConstants.CAMPAIGN_REGION_COUNT}大区 · ${CAMPAIGN_MAP_NODES.length}城关）`)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')

        Blank()

        Text('外交面板 / 小地图 / 缩放视口（第2阶段接入交互）')
          .fontSize(12)
          .fontColor('#81C784')
      }
      .width('100%')

      // 中部：左列势力外交态势占位 + 右列36城关静态节点核验列表
      Row({ space: 12 }) {
        Column({ space: 8 }) {
          Text('八方外交初始信誉一览')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F5E6C8')

          List({ space: 6 }) {
            ForEach(FACTION_STATIC_CONFIGS, (faction: FactionStaticConfig) => {
              ListItem() {
                Row() {
                  Text(faction.name)
                    .fontSize(13)
                    .fontColor('#ECEFF1')
                  Blank()
                  Text(`信誉 ${faction.startingCredibility}`)
                    .fontSize(12)
                    .fontColor('#FFD54F')
                }
                .width('100%')
                .padding(8)
                .backgroundColor('#232020')
                .borderRadius(6)
              }
            }, (faction: FactionStaticConfig) => faction.id)
          }
          .layoutWeight(1)
          .width('100%')
        }
        .width('34%')
        .height('100%')
        .padding(12)
        .backgroundColor('#1A1514')
        .borderRadius(8)

        Column({ space: 8 }) {
          Text(`战略节点拓扑核验（共 ${CAMPAIGN_MAP_NODES.length} 座城池/雄关/仓城/渡口）`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F5E6C8')

          Grid() {
            ForEach(CAMPAIGN_MAP_NODES, (node: CampaignNodeConfig) => {
              GridItem() {
                Column({ space: 2 }) {
                  Text(`${node.name} [${node.regionName}]`)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFF8E1')
                  Text(`坐标(${node.x},${node.y}) · 城防Lv.${node.defenseLevel} · 邻路${node.neighbors.length}条`)
                    .fontSize(10)
                    .fontColor('#90A4AE')
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding(8)
                .backgroundColor('#221E1D')
                .borderRadius(6)
              }
            }, (node: CampaignNodeConfig) => node.id)
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(8)
          .rowsGap(8)
          .layoutWeight(1)
          .width('100%')
        }
        .width('66%')
        .height('100%')
        .padding(12)
        .backgroundColor('#1A1514')
        .borderRadius(8)
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
