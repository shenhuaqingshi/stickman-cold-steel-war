import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
import { getFactionConfigById } from '../config/FactionConfig';
import {
  CampaignEngine,
  CampaignVictoryKind,
  PrisonerDisposition,
  SettlementApplyReport
} from '../core/campaign/CampaignEngine';
import {
  BattleOutcomeReason,
  BattleScenarioType,
  BattleSettlementSummary,
  FactionId
} from '../core/CoreContracts';
import { GameSessionCoordinator } from '../core/session/GameSessionCoordinator';
import { FactionStaticConfig, RouteLaunchParams } from '../model/GameTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'BattleResultPage';

/**
 * 战后军功、伤亡恢复、战俘处置与战役回写平板双栏正式页（BattleResultPage.ets）
 * 左栏（46%）：胜负战报、双方投入/阵亡/重伤痊愈/主帅斩获明细；
 * 右栏（54%）：粮械缴获、战役战俘处置（整编入伍 vs 换取赎金）、孤城士气打击与晋升回写闭环。
 */
@Entry
@Component
struct BattleResultPage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;
  @State isVictory: boolean = true;
  @State outcomeReason: BattleOutcomeReason = BattleOutcomeReason.ENEMY_ARMY_ROUTED;
  @State playerFactionName: string = '炎龙帝国';
  @State enemyFactionName: string = '苍狼汗国';
  @State durationSec: number = 0;
  @State playerInitial: number = 0;
  @State playerKilled: number = 0;
  @State playerRecovered: number = 0;
  @State enemyInitial: number = 0;
  @State enemyKilled: number = 0;
  @State capturedPrisoners: number = 0;
  @State lootedGold: number = 0;
  @State lootedWood: number = 0;
  @State lootedGrain: number = 0;
  @State heroKills: number = 0;
  @State expGained: number = 0;

  @State isFromCampaign: boolean = false;
  @State settlementCommitted: boolean = false;
  @State selectedDisposition: PrisonerDisposition = PrisonerDisposition.RECRUIT;
  @State campaignFeedbackText: string = '';
  @State campaignVictoryBanner: string = '';

  private readonly session: GameSessionCoordinator = GameSessionCoordinator.getInstance();

  aboutToAppear(): void {
    let summary: BattleSettlementSummary | null = this.session.getPendingSettlementSummary();
    if (summary === null) {
      summary = this.session.finalizeActiveBattle();
    }
    this.isFromCampaign = this.session.isPendingSettlementFromCampaign();
    this.settlementCommitted = this.session.isPendingSettlementApplied();

    if (summary !== null) {
      this.isVictory = summary.isVictory;
      this.outcomeReason = summary.outcomeReason;
      this.playerFactionName = this.resolveFactionName(summary.playerFaction);
      this.enemyFactionName = this.resolveFactionName(summary.enemyFaction);
      this.durationSec = Math.round(summary.durationSec);
      this.playerInitial = summary.playerInitialTotal;
      this.playerKilled = summary.playerKilled;
      this.playerRecovered = summary.playerWoundedRecovered;
      this.enemyInitial = summary.enemyInitialTotal;
      this.enemyKilled = summary.enemyKilled;
      this.capturedPrisoners = summary.capturedPrisoners;
      this.lootedGold = summary.lootedGold;
      this.lootedWood = summary.lootedWood;
      this.lootedGrain = summary.lootedGrain;
      this.heroKills = summary.heroKills;
      this.expGained = summary.commanderExpGained;

      if (this.isFromCampaign && (!this.isVictory || this.capturedPrisoners === 0)) {
        this.applyCampaignSettlementNow(PrisonerDisposition.RANSOM);
      } else if (this.isFromCampaign) {
        this.campaignFeedbackText = `大捷俘获 ${this.capturedPrisoners} 名敌兵！请选择【整编入伍】补充前线编制，或【遣返换取赎金】（每俘 ${CampaignEngine.RANSOM_GOLD_PER_PRISONER} 金）。`;
      }
    } else {
      // 安全兜底（如直接路由调试进入）
      const fallback: BattleSettlementSummary = {
        scenarioType: BattleScenarioType.FIELD_PITCHED,
        campaignNodeId: '',
        playerFaction: FactionId.YANLONG,
        enemyFaction: FactionId.CANGLANG,
        isVictory: true,
        outcomeReason: BattleOutcomeReason.ENEMY_ARMY_ROUTED,
        durationSec: 95,
        playerInitialTotal: 100,
        playerKilled: 12,
        playerWoundedRecovered: 5,
        enemyInitialTotal: 100,
        enemyKilled: 78,
        capturedPrisoners: 14,
        lootedGold: 160,
        lootedWood: 90,
        lootedGrain: 220,
        heroKills: 8,
        commanderExpGained: 85
      };
      this.playerInitial = fallback.playerInitialTotal;
      this.enemyKilled = fallback.enemyKilled;
    }
  }

  private resolveFactionName(fid: FactionId): string {
    const cfg: FactionStaticConfig | undefined = getFactionConfigById(fid);
    return cfg !== undefined ? cfg.name : fid;
  }

  private applyCampaignSettlementNow(disposition: PrisonerDisposition): void {
    this.selectedDisposition = disposition;
    const report: SettlementApplyReport | null =
      this.session.commitPendingCampaignSettlement(disposition);
    if (report === null) {
      return;
    }
    this.settlementCommitted = true;
    const parts: string[] = [];
    if (report.nodeCaptured) {
      parts.push('成功攻克目标城关并纳入版图！');
    }
    if (report.prisonersRecruited > 0) {
      parts.push(`收编精兵 ${report.prisonersRecruited} 人`);
    }
    if (report.ransomGoldGained > 0) {
      parts.push(`获战俘赎金 +${report.ransomGoldGained} 金`);
    }
    if (report.reliefAmbushMoraleShockAppliedTo.length > 0) {
      parts.push(`【围点打援】大捷震慑孤城守军士气 -25！`);
    }
    if (report.commanderLeveledUp) {
      parts.push(`统帅晋升至 Lv.${report.newCommanderLevel}！`);
    }
    if (report.commanderInjuredTurns > 0) {
      parts.push(`主帅阵前重创，需回都休养 ${report.commanderInjuredTurns} 回合`);
    }
    parts.push('战役态势已自动写入槽位0离线存档。');
    this.campaignFeedbackText = parts.join(' ｜ ');

    if (report.victoryCheck.kind !== CampaignVictoryKind.ONGOING) {
      this.campaignVictoryBanner = report.victoryCheck.summaryText;
    }
  }

  private returnToCampaignMap(): void {
    if (this.isFromCampaign && !this.settlementCommitted) {
      this.applyCampaignSettlementNow(this.selectedDisposition);
    }
    const campFac: FactionId = this.session.getCampaignEngine().getState().playerFaction;
    const launchParams: RouteLaunchParams = {
      modeKey: 'campaign',
      modeTitle: '战略大地图',
      factionId: campFac
    };
    this.getUIContext().getRouter().replaceUrl({
      url: 'pages/CampaignPage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Return CampaignPage warning: %{public}s', JSON.stringify(err));
    });
  }

  private returnToSetupRematch(): void {
    const draft = this.session.getSetupDraft();
    const launchParams: RouteLaunchParams = {
      modeKey: draft.modeKey,
      modeTitle: draft.modeTitle,
      factionId: draft.playerFaction
    };
    this.getUIContext().getRouter().replaceUrl({
      url: 'pages/SetupPage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Return SetupPage warning: %{public}s', JSON.stringify(err));
    });
  }

  private returnToMainMenu(): void {
    if (this.isFromCampaign && !this.settlementCommitted) {
      this.applyCampaignSettlementNow(this.selectedDisposition);
    }
    this.getUIContext().getRouter().clear();
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'replaceUrl to Index warning: %{public}s', JSON.stringify(err));
    });
  }

  private headlineText(): string {
    if (this.outcomeReason === BattleOutcomeReason.TRUCE_NEGOTIATED) {
      return '阵前议和 · 罢兵休战';
    }
    return this.isVictory ? '三军奏凯 · 战功赫赫！' : '战局失利 · 重整旗鼓';
  }

  build() {
    Column({ space: 14 }) {
      // 顶部结算横幅
      Row({ space: 14 }) {
        Text(this.headlineText())
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isVictory ? '#FFD54F' : '#FF8A80')
        Blank()
        Text(`${this.playerFactionName} VS ${this.enemyFactionName} · 激战 ${this.durationSec} 秒`)
          .fontSize(15)
          .fontColor('#B0BEC5')
      }
      .width('100%')

      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        // ==================== 左栏（46%）：双方兵力投入、阵亡、伤愈与主帅斩将统计 ====================
        Column({ space: 10 }) {
          Text('沙场伤亡与统帅武勋明细')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#D4A843')

          Text(`终局原因：${this.outcomeReason}`)
            .fontSize(13)
            .fontColor('#90A4AE')

          Column({ space: 8 }) {
            Text(`• 我军参战总兵力：${this.playerInitial} 人`)
              .fontSize(14)
              .fontColor('#ECEFF1')
            Text(`• 阵亡将士：${this.playerKilled} 人 ｜ 战后医帐救回伤兵：+${this.playerRecovered} 人`)
              .fontSize(14)
              .fontColor('#81C784')
            Text(`• 我军实际净减员：${Math.max(0, this.playerKilled - this.playerRecovered)} 人`)
              .fontSize(14)
              .fontColor('#FFE082')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .backgroundColor('#232020')
          .borderRadius(8)

          Column({ space: 8 }) {
            Text(`• 敌军参战总兵力：${this.enemyInitial} 人`)
              .fontSize(14)
              .fontColor('#ECEFF1')
            Text(`• 阵斩敌军：${this.enemyKilled} 人 ｜ 生擒敌方战俘：${this.capturedPrisoners} 人`)
              .fontSize(14)
              .fontColor('#FFD54F')
            Text(`• 主帅亲手斩敌：${this.heroKills} 人 ｜ 统帅历练经验：+${this.expGained} EXP`)
              .fontSize(14)
              .fontColor('#81D4FA')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .backgroundColor('#232020')
          .borderRadius(8)
        }
        .alignItems(HorizontalAlign.Start)
        .width(this.isWideScreen ? '46%' : '100%')
        .height(this.isWideScreen ? '100%' : '48%')
        .padding(16)
        .backgroundColor('#1A1514')
        .borderRadius(10)

        // ==================== 右栏（54%）：缴获物资、战俘处置与战役回写/再战主视图 ====================
        Column({ space: 12 }) {
          Text('战利品缴获与善后军务决断')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#D4A843')

          Row({ space: 10 }) {
            Text(`缴获金币 +${this.lootedGold}`)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFD54F')
              .layoutWeight(1)
            Text(`缴获木材 +${this.lootedWood}`)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#A5D6A7')
              .layoutWeight(1)
            Text(`缴获粮草 +${this.lootedGrain}`)
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFE082')
              .layoutWeight(1)
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#241E1C')
          .borderRadius(8)

          if (this.isFromCampaign) {
            if (this.isVictory && this.capturedPrisoners > 0 && !this.settlementCommitted) {
              Text(`战俘处置抉择（共俘获 ${this.capturedPrisoners} 人）：`)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFF8E1')

              Row({ space: 12 }) {
                Button(`收编入伍 (+${this.capturedPrisoners}兵)`)
                  .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                  .layoutWeight(1)
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .backgroundColor('#2E7D32')
                  .fontColor('#FFFFFF')
                  .onClick(() => {
                    this.applyCampaignSettlementNow(PrisonerDisposition.RECRUIT);
                  })

                Button(`遣返换赎金 (+${this.capturedPrisoners * CampaignEngine.RANSOM_GOLD_PER_PRISONER}金)`)
                  .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                  .layoutWeight(1)
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .backgroundColor('#8D6E63')
                  .fontColor('#FFFFFF')
                  .onClick(() => {
                    this.applyCampaignSettlementNow(PrisonerDisposition.RANSOM);
                  })
              }
              .width('100%')
            }

            Text(this.campaignFeedbackText)
              .fontSize(13)
              .fontColor('#81C784')
              .lineHeight(20)
              .width('100%')
              .padding(12)
              .backgroundColor('#232020')
              .borderRadius(8)

            if (this.campaignVictoryBanner.length > 0) {
              Text(`★ 天下大势终局：${this.campaignVictoryBanner}`)
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFD54F')
                .width('100%')
                .padding(12)
                .backgroundColor('#4E342E')
                .borderRadius(8)
            }

            Blank()

            Row({ space: 12 }) {
              Button('确认回写 · 返回40城战略大地图 ›')
                .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                .layoutWeight(2)
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#B71C1C')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.returnToCampaignMap();
                })

              Button('返回主菜单')
                .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(14)
                .backgroundColor('#3E2723')
                .fontColor('#FFF8E1')
                .onClick(() => {
                  this.returnToMainMenu();
                })
            }
            .width('100%')
          } else {
            Text('单局会战已计入统帅战绩档案。可返回整军面板微调兵种克制再战，或回到主菜单开启 40 城宏大战略战役！')
              .fontSize(13)
              .fontColor('#B0BEC5')
              .lineHeight(20)

            Blank()

            Row({ space: 12 }) {
              Button('重新整军再战 ›')
                .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#B71C1C')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.returnToSetupRematch();
                })

              Button('返回主菜单')
                .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#4E342E')
                .fontColor('#FFF8E1')
                .onClick(() => {
                  this.returnToMainMenu();
                })
            }
            .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width(this.isWideScreen ? '54%' : '100%')
        .height(this.isWideScreen ? '100%' : '52%')
        .margin({ left: this.isWideScreen ? 14 : 0, top: this.isWideScreen ? 0 : 12 })
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
