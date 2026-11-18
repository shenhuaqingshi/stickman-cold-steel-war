import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../config/FactionConfig';
import { getUnitConfigById } from '../config/UnitConfig';
import { GameSessionCoordinator, HallOfFameStats } from '../core/session/GameSessionCoordinator';
import {
  FactionId,
  FactionStaticConfig,
  FactionTechItem,
  RouteLaunchParams,
  UnitStaticStats
} from '../model/GameTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'IndexPage';

interface MenuEntryItem {
  readonly key: string;
  readonly title: string;
  readonly subtitle: string;
  readonly routeUrl: string;
}

/**
 * 《火柴人冷兵器大战》鸿蒙平板主菜单入口页（全流程打通正式版）
 * MatePad 横屏采用左栏模式导航与战役快进（36%）+ 右栏八大势力统帅择主与王牌兵种/科技检阅主视图（64%）
 */
@Entry
@Component
struct Index {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;
  @State selectedTab: string = 'campaign';
  @State selectedFactionIndex: number = 0;
  @State hasOngoingCampaign: boolean = false;
  @State activeCampaignLabel: string = '尚未开启战役';
  @State hallSummaryLabel: string = '累计会战 0 场 · 胜捷 0 场';
  @State statusTip: string = '选择右侧任一势力统帅三军：既可在 40 城 78 路大地图合纵连横，也可直接进入 4800×2400 宏大战场提刀拼杀';

  private readonly session: GameSessionCoordinator = GameSessionCoordinator.getInstance();

  private readonly menuEntries: readonly MenuEntryItem[] = [
    { key: 'campaign', title: '战役模式', subtitle: '8大区域 · 40城78路 · 外交纵横', routeUrl: 'pages/CampaignPage' },
    { key: 'skirmish', title: '遭遇战', subtitle: '4800×2400宏大战场 · 六军团会战', routeUrl: 'pages/SetupPage' },
    { key: 'siege', title: '守城挑战', subtitle: '5600×2600雄关死守 · 强敌攻城', routeUrl: 'pages/SetupPage' },
    { key: 'custom', title: '自定义战场', subtitle: '自选8势力、地形天气与16兵种混编', routeUrl: 'pages/SetupPage' },
    { key: 'save', title: '本地存档', subtitle: '6槽离线进度读写与统帅战绩统计', routeUrl: 'pages/SavePage' },
    { key: 'settings', title: '游戏设置', subtitle: '平板高刷LOD · 手写笔 · 摇杆配置', routeUrl: 'pages/SettingsPage' }
  ];

  aboutToAppear(): void {
    this.syncSessionOverview();
  }

  onPageShow(): void {
    this.syncSessionOverview();
  }

  private syncSessionOverview(): void {
    const activeFac: FactionId = this.session.getSelectedMenuFaction();
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      if (FACTION_STATIC_CONFIGS[i].id === activeFac) {
        this.selectedFactionIndex = i;
        break;
      }
    }
    this.hasOngoingCampaign = this.session.hasActiveCampaign();
    const hall: HallOfFameStats = this.session.getHallOfFameStats();
    if (this.hasOngoingCampaign) {
      const fCfg: FactionStaticConfig | undefined = getFactionConfigById(hall.activeCampaignFaction);
      const fName: string = fCfg !== undefined ? fCfg.name : hall.activeCampaignFaction;
      this.activeCampaignLabel = `进行中：${fName} · 第${hall.activeCampaignTurn}回合 · 统辖${hall.activeControlledCities}城（王都${hall.activeControlledCapitals}/8）`;
    } else {
      this.activeCampaignLabel = '当前无进行中战役（点击【战役模式】或右侧按钮立即开局）';
    }
    this.hallSummaryLabel = `累计大战 ${hall.totalBattlesFought} 场 · 大捷 ${hall.totalBattlesWon} 场 · 歼敌 ${hall.totalEnemiesKilled}`;
  }

  private currentChosenFaction(): FactionStaticConfig {
    return FACTION_STATIC_CONFIGS[this.selectedFactionIndex];
  }

  private navigateToMode(item: MenuEntryItem, forceNewCampaign: boolean = false): void {
    this.selectedTab = item.key;
    const chosen: FactionStaticConfig = this.currentChosenFaction();
    this.session.setSelectedMenuFaction(chosen.id);

    if (item.key === 'campaign') {
      const shouldRestart: boolean =
        forceNewCampaign ||
        !this.session.hasActiveCampaign() ||
        this.session.getCampaignEngine().getState().playerFaction !== chosen.id;
      this.session.ensureCampaignForFaction(chosen.id, shouldRestart);
    } else if (item.key === 'skirmish' || item.key === 'siege' || item.key === 'custom') {
      this.session.prepareSetupForMode(item.key, item.title, chosen.id);
    }

    const launchParams: RouteLaunchParams = {
      modeKey: item.key,
      modeTitle: item.title,
      factionId: chosen.id
    };
    this.getUIContext().getRouter().pushUrl({
      url: item.routeUrl,
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Router pushUrl warning: %{public}s', JSON.stringify(err));
      this.statusTip = `路由跳转提示：${item.title}（${err.message}）`;
    });
  }

  private resumeOngoingCampaign(): void {
    if (!this.session.hasActiveCampaign()) {
      return;
    }
    const campFac: FactionId = this.session.getCampaignEngine().getState().playerFaction;
    const launchParams: RouteLaunchParams = {
      modeKey: 'campaign',
      modeTitle: '继续战役',
      factionId: campFac
    };
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/CampaignPage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Resume CampaignPage warning: %{public}s', JSON.stringify(err));
    });
  }

  build() {
    Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
      // ==================== 左栏（横屏 36%）：模式导航与战役快进栏 ====================
      Column({ space: 10 }) {
        Text($r('app.string.app_name'))
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F5E6C8')

        Text('HarmonyOS NEXT · MatePad 大屏冷兵器战争策略动作')
          .fontSize(12)
          .fontColor('#90A4AE')

        Column({ space: 6 }) {
          Text(this.activeCampaignLabel)
            .fontSize(12)
            .fontColor('#FFE082')
            .maxLines(2)
          Text(this.hallSummaryLabel)
            .fontSize(11)
            .fontColor('#81C784')

          if (this.hasOngoingCampaign) {
            Button('继续当前战役大地图 ›')
              .width('100%')
              .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .backgroundColor('#2E7D32')
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.resumeOngoingCampaign();
              })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(10)
        .backgroundColor('#241E1C')
        .borderRadius(8)
        .border({ width: 1, color: '#3E3532' })

        List({ space: 8 }) {
          ForEach(this.menuEntries, (item: MenuEntryItem) => {
            ListItem() {
              Row() {
                Column({ space: 3 }) {
                  Text(item.title)
                    .fontSize(17)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFF8E1')
                  Text(item.subtitle)
                    .fontSize(12)
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
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor(this.selectedTab === item.key ? '#4E342E' : '#26201E')
              .borderRadius(10)
              .border({
                width: 1.5,
                color: this.selectedTab === item.key ? '#D4A843' : '#3E3532'
              })
              .onClick(() => {
                this.navigateToMode(item, false);
              })
            }
          }, (item: MenuEntryItem) => item.key)
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width(this.isWideScreen ? '36%' : '100%')
      .height(this.isWideScreen ? '100%' : '46%')
      .padding(18)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#1A1514')

      // ==================== 右栏（横屏 64%）：八大势力矩阵与非对称特性主视图 ====================
      Column({ space: 10 }) {
        Row() {
          Text('八方割据 · 统帅择主（点选势力出征战役或遭遇战）')
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor('#D4A843')
          Blank()
          Text('纯单机离线 · 40城78路 · 真刀真枪')
            .fontSize(12)
            .fontColor('#81C784')
        }
        .width('100%')

        Grid() {
          ForEach(FACTION_STATIC_CONFIGS, (faction: FactionStaticConfig, idx: number) => {
            GridItem() {
              Row({ space: 10 }) {
                Row()
                  .width(8)
                  .height(42)
                  .borderRadius(4)
                  .backgroundColor(faction.primaryColor)
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(`${faction.name} · ${faction.bannerTitle}`)
                      .fontSize(15)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#ECEFF1')
                    Blank()
                    Text(`信誉 ${faction.startingCredibility}`)
                      .fontSize(11)
                      .fontColor('#FFD54F')
                  }
                  .width('100%')

                  Text(faction.specialtyTag)
                    .fontSize(12)
                    .fontColor('#90A4AE')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .constraintSize({ minHeight: GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP })
              .padding(12)
              .backgroundColor(this.selectedFactionIndex === idx ? '#2E2623' : '#232020')
              .borderRadius(10)
              .border({
                width: 1.5,
                color: this.selectedFactionIndex === idx ? faction.primaryColor : '#373232'
              })
              .onClick(() => {
                this.selectedFactionIndex = idx;
                this.session.setSelectedMenuFaction(faction.id);
                this.statusTip = `【${faction.name}】强势：${faction.bonusSummary} ｜ 突破口：${faction.weaknessSummary}`;
              })
            }
          }, (faction: FactionStaticConfig) => faction.id)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .layoutWeight(1)
        .width('100%')

        // 选中势力王牌兵种、优劣势与三阶科技详情检阅卡 + 快速开战动作条
        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Text(`选中诸侯：【${this.currentChosenFaction().name}】`)
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFF8E1')

            Text(this.buildAceUnitBadgeText(this.currentChosenFaction()))
              .fontSize(12)
              .fontColor('#81C784')
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')

          Text(this.statusTip)
            .fontSize(12)
            .fontColor('#FFD54F')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.buildTechChainText(this.currentChosenFaction()))
            .fontSize(12)
            .fontColor('#B0BEC5')
            .maxLines(1)
            .width('100%')

          Row({ space: 12 }) {
            Button(`以【${this.currentChosenFaction().name}】新开40城战役 ›`)
              .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
              .layoutWeight(1)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .backgroundColor('#8D3B24')
              .fontColor('#FFFFFF')
              .onClick(() => {
                this.navigateToMode(this.menuEntries[0], true);
              })

            Button(`以【${this.currentChosenFaction().name}】打响遭遇战 ›`)
              .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
              .layoutWeight(1)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .backgroundColor('#4E342E')
              .fontColor('#FFF8E1')
              .onClick(() => {
                this.navigateToMode(this.menuEntries[1], false);
              })
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(14)
        .backgroundColor('#221C19')
        .borderRadius(10)
        .border({ width: 1, color: '#3E3532' })
      }
      .width(this.isWideScreen ? '64%' : '100%')
      .height(this.isWideScreen ? '100%' : '54%')
      .padding(18)
      .backgroundColor('#141110')
    }
    .width('100%')
    .height('100%')
  }

  private buildAceUnitBadgeText(faction: FactionStaticConfig): string {
    const u: UnitStaticStats | undefined = getUnitConfigById(faction.exclusiveUnitId);
    if (u === undefined) {
      return '';
    }
    return `专属王牌【${u.name}】HP ${u.hp} · 攻 ${u.attack} · 破甲 ${Math.round(u.armorPenetration * 100)}% · 甲 ${u.armor}`;
  }

  private buildTechChainText(faction: FactionStaticConfig): string {
    const names: string[] = [];
    for (let i: number = 0; i < faction.uniqueTechs.length; i++) {
      const tech: FactionTechItem = faction.uniqueTechs[i];
      names.push(`《${tech.name}》(${tech.effectSummary})`);
    }
    return `三阶国策科技：${names.join(' → ')}`;
  }
}
