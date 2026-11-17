import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FACTION_STATIC_CONFIGS } from '../config/FactionConfig';
import { FactionStaticConfig, RouteLaunchParams } from '../model/GameTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'IndexPage';

interface MenuEntryItem {
  readonly key: string;
  readonly title: string;
  readonly subtitle: string;
  readonly routeUrl: string;
}

/**
 * 火柴人冷兵器大战 — 主菜单入口页（第 1 步：Stage 模型骨架与路由导航）
 * 说明：当前为第 1 步完整 Stage 骨架，绑定静态八大势力配置并打通各子页面路由容器，不含战斗模拟逻辑。
 */
@Entry
@Component
struct Index {
  @State selectedTab: string = 'campaign';
  @State selectedFactionIndex: number = 0;
  @State statusTip: string = '第1步骨架就绪：点选左侧模式可验证 Stage 页面路由，点选右侧势力可查看编制特性';

  private readonly menuEntries: readonly MenuEntryItem[] = [
    { key: 'campaign', title: '战役模式', subtitle: '8大区域 · 36城关 · 外交纵横', routeUrl: 'pages/CampaignPage' },
    { key: 'skirmish', title: '遭遇战', subtitle: '4800×2400宏大战场 · 快速开战', routeUrl: 'pages/SetupPage' },
    { key: 'siege', title: '守城挑战', subtitle: '据城死守 · 波次强敌攻城', routeUrl: 'pages/SetupPage' },
    { key: 'custom', title: '自定义战场', subtitle: '自选8势力、地形与百人军团', routeUrl: 'pages/SetupPage' },
    { key: 'save', title: '本地存档', subtitle: '单机离线进度与战绩统计', routeUrl: 'pages/SavePage' },
    { key: 'settings', title: '游戏设置', subtitle: '画质帧率 · 音效 · 触控摇杆配置', routeUrl: 'pages/SettingsPage' }
  ];

  private navigateToPage(item: MenuEntryItem): void {
    this.selectedTab = item.key;
    const launchParams: RouteLaunchParams = {
      modeKey: item.key,
      modeTitle: item.title,
      factionId: FACTION_STATIC_CONFIGS[this.selectedFactionIndex].id
    };
    this.getUIContext().getRouter().pushUrl({
      url: item.routeUrl,
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Router pushUrl warning: %{public}s', JSON.stringify(err));
      this.statusTip = `路由跳转提示：${item.title}（${err.message}）`;
    });
  }

  build() {
    Row() {
      // 左侧：游戏标题与主菜单路由入口列表
      Column({ space: 10 }) {
        Text($r('app.string.app_name'))
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F5E6C8')

        Text('Stickman Cold Steel War · API 12 Stage')
          .fontSize(12)
          .fontColor('#9E9E9E')
          .margin({ bottom: 4 })

        List({ space: 8 }) {
          ForEach(this.menuEntries, (item: MenuEntryItem) => {
            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Text(item.title)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFF8E1')
                  Text(item.subtitle)
                    .fontSize(11)
                    .fontColor('#B0BEC5')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('进入 ›')
                  .fontSize(12)
                  .fontColor('#D4A843')
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor(this.selectedTab === item.key ? '#4E342E' : '#26201E')
              .borderRadius(8)
              .border({
                width: 1,
                color: this.selectedTab === item.key ? '#D4A843' : '#3E3532'
              })
              .onClick(() => {
                this.navigateToPage(item);
              })
            }
          }, (item: MenuEntryItem) => item.key)
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('38%')
      .height('100%')
      .padding(20)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#1A1514')

      // 右侧：八大势力一览（绑定统一静态配置表）与特性详情栏
      Column({ space: 10 }) {
        Row() {
          Text('八方割据 · 势力总览')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#D4A843')
          Blank()
          Text('单机离线 · 无需联网')
            .fontSize(12)
            .fontColor('#81C784')
        }
        .width('100%')

        Grid() {
          ForEach(FACTION_STATIC_CONFIGS, (faction: FactionStaticConfig, idx: number) => {
            GridItem() {
              Row({ space: 8 }) {
                Row()
                  .width(6)
                  .height(36)
                  .borderRadius(3)
                  .backgroundColor(faction.primaryColor)
                Column({ space: 3 }) {
                  Text(faction.name)
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#ECEFF1')
                  Text(faction.specialtyTag)
                    .fontSize(11)
                    .fontColor('#90A4AE')
                }
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding(10)
              .backgroundColor(this.selectedFactionIndex === idx ? '#2E2623' : '#232020')
              .borderRadius(8)
              .border({
                width: 1,
                color: this.selectedFactionIndex === idx ? faction.primaryColor : '#373232'
              })
              .onClick(() => {
                this.selectedFactionIndex = idx;
                this.statusTip = `【${faction.name}】优势：${faction.bonusSummary}`;
              })
            }
          }, (faction: FactionStaticConfig) => faction.id)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .layoutWeight(1)
        .width('100%')

        Text(this.statusTip)
          .fontSize(12)
          .fontColor('#FFD54F')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding(10)
          .backgroundColor('#2B2318')
          .borderRadius(6)
      }
      .width('62%')
      .height('100%')
      .padding(20)
      .backgroundColor('#141110')
    }
    .width('100%')
    .height('100%')
  }
}
