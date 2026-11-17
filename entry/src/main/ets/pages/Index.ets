import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
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
 * 火柴人冷兵器大战 — 鸿蒙平板主菜单入口页（第 1 步：Stage 响应式双栏骨架，不含战斗模拟逻辑）
 * 横屏平板采用左导航（36%）+ 右势力详情总览（64%）双栏布局；竖屏或窄分屏自动切换上下自适应布局
 */
@Entry
@Component
struct Index {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;
  @State selectedTab: string = 'campaign';
  @State selectedFactionIndex: number = 0;
  @State statusTip: string = '第1步平板骨架就绪：左侧大热区卡片验证 Stage 路由，右侧查看八大势力非对称编制';

  private readonly menuEntries: readonly MenuEntryItem[] = [
    { key: 'campaign', title: '战役模式', subtitle: '8大区域 · 40城关 · 外交纵横', routeUrl: 'pages/CampaignPage' },
    { key: 'skirmish', title: '遭遇战', subtitle: '4800×2400宏大战场 · 多军团会战', routeUrl: 'pages/SetupPage' },
    { key: 'siege', title: '守城挑战', subtitle: '据城死守 · 多波次强敌攻城', routeUrl: 'pages/SetupPage' },
    { key: 'custom', title: '自定义战场', subtitle: '自选8势力、地形与百人混编军团', routeUrl: 'pages/SetupPage' },
    { key: 'save', title: '本地存档', subtitle: '单机离线进度与历史战绩统计', routeUrl: 'pages/SavePage' },
    { key: 'settings', title: '游戏设置', subtitle: '平板高刷LOD · 手写笔 · 摇杆配置', routeUrl: 'pages/SettingsPage' }
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
    Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
      // 左栏（横屏 36%）：游戏主标题与平板大热区模式菜单
      Column({ space: 12 }) {
        Text($r('app.string.app_name'))
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F5E6C8')

        Text('HarmonyOS NEXT · MatePad 大屏冷兵器战争策略动作')
          .fontSize(13)
          .fontColor('#9E9E9E')
          .margin({ bottom: 4 })

        List({ space: 10 }) {
          ForEach(this.menuEntries, (item: MenuEntryItem) => {
            ListItem() {
              Row() {
                Column({ space: 4 }) {
                  Text(item.title)
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFF8E1')
                  Text(item.subtitle)
                    .fontSize(13)
                    .fontColor('#B0BEC5')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('进入 ›')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#D4A843')
              }
              .width('100%')
              .constraintSize({ minHeight: GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP })
              .padding({ left: 18, right: 18, top: 12, bottom: 12 })
              .backgroundColor(this.selectedTab === item.key ? '#4E342E' : '#26201E')
              .borderRadius(10)
              .border({
                width: 1.5,
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
      .width(this.isWideScreen ? '36%' : '100%')
      .height(this.isWideScreen ? '100%' : '46%')
      .padding(22)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#1A1514')

      // 右栏（横屏 64%）：八大势力大屏卡片矩阵与选中势力军情详情区
      Column({ space: 12 }) {
        Row() {
          Text('八方割据 · 统帅择主')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#D4A843')
          Blank()
          Text('平板大屏适配 · 单机离线无联网')
            .fontSize(13)
            .fontColor('#81C784')
        }
        .width('100%')

        Grid() {
          ForEach(FACTION_STATIC_CONFIGS, (faction: FactionStaticConfig, idx: number) => {
            GridItem() {
              Row({ space: 10 }) {
                Row()
                  .width(8)
                  .height(44)
                  .borderRadius(4)
                  .backgroundColor(faction.primaryColor)
                Column({ space: 4 }) {
                  Text(`${faction.name} · ${faction.bannerTitle}`)
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#ECEFF1')
                  Text(faction.specialtyTag)
                    .fontSize(13)
                    .fontColor('#90A4AE')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .constraintSize({ minHeight: GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP })
              .padding(14)
              .backgroundColor(this.selectedFactionIndex === idx ? '#2E2623' : '#232020')
              .borderRadius(10)
              .border({
                width: 1.5,
                color: this.selectedFactionIndex === idx ? faction.primaryColor : '#373232'
              })
              .onClick(() => {
                this.selectedFactionIndex = idx;
                this.statusTip = `【${faction.name}】优势：${faction.bonusSummary} ｜ 短板：${faction.weaknessSummary}`;
              })
            }
          }, (faction: FactionStaticConfig) => faction.id)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(12)
        .rowsGap(12)
        .layoutWeight(1)
        .width('100%')

        Text(this.statusTip)
          .fontSize(13)
          .fontColor('#FFD54F')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding(14)
          .backgroundColor('#2B2318')
          .borderRadius(8)
      }
      .width(this.isWideScreen ? '64%' : '100%')
      .height(this.isWideScreen ? '100%' : '54%')
      .padding(22)
      .backgroundColor('#141110')
    }
    .width('100%')
    .height('100%')
  }
}
