import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
import { getFactionConfigById } from '../config/FactionConfig';
import { FactionId } from '../core/CoreContracts';
import { GameSessionCoordinator, HallOfFameStats } from '../core/session/GameSessionCoordinator';
import { FactionStaticConfig, RouteLaunchParams, SaveSlotSummary } from '../model/GameTypes';
import { SaveLoadResult, SaveManager, SaveWriteResult } from '../storage/SaveManager';

const DOMAIN: number = 0x0001;
const TAG: string = 'SavePage';

/**
 * 本地离线多槽位存档与统帅战绩档案平板双栏正式页（SavePage.ets）
 * 左栏（58%）：槽位 0 自动存档 + 槽位 1~5 手动存档槽列表；
 * 右栏（42%）：选中槽位保存/读取/删除操作与统帅累计战绩统计。
 */
@Entry
@Component
struct SavePage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;
  @State slots: SaveSlotSummary[] = [];
  @State selectedSlotIndex: number = 0;
  @State hasActiveCampaign: boolean = false;
  @State hallStatsText: string = '';
  @State feedbackMessage: string = '全部存档离线保存于 HarmonyOS 应用沙箱（含损坏 JSON 隔离与断粮 Infinity 安全还原）。';

  private readonly session: GameSessionCoordinator = GameSessionCoordinator.getInstance();

  aboutToAppear(): void {
    this.refreshSlotsAndStats();
  }

  onPageShow(): void {
    this.refreshSlotsAndStats();
  }

  private refreshSlotsAndStats(): void {
    this.slots = this.session.listAllSaveSlots();
    this.hasActiveCampaign = this.session.hasActiveCampaign();
    const hall: HallOfFameStats = this.session.getHallOfFameStats();
    const fCfg: FactionStaticConfig | undefined = getFactionConfigById(hall.activeCampaignFaction);
    const facName: string = fCfg !== undefined ? fCfg.name : hall.activeCampaignFaction;
    const winRate: number =
      hall.totalBattlesFought > 0
        ? Math.round((hall.totalBattlesWon / hall.totalBattlesFought) * 100)
        : 0;

    this.hallStatsText =
      `• 当前战役诸侯：${facName}（第 ${hall.activeCampaignTurn} 回合）\n` +
      `• 统辖城关：${hall.activeControlledCities} / 40 座（核心王都 ${hall.activeControlledCapitals} / 8 座）\n` +
      `• 累计指挥会战：${hall.totalBattlesFought} 场 ｜ 凯旋大捷：${hall.totalBattlesWon} 场（胜率 ${winRate}%）\n` +
      `• 战役累计歼灭敌军：${hall.totalEnemiesKilled} 人\n` +
      `• 单局演武会战：${hall.standaloneBattlesFought} 场（主帅亲斩 ${hall.standaloneHeroKills} 敌）`;
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private resolveSlotHeading(slot: SaveSlotSummary): string {
    if (slot.slotIndex === SaveManager.AUTO_SAVE_SLOT) {
      return `[槽位 0 · 自动存档] ${slot.title}`;
    }
    return `[槽位 ${slot.slotIndex} · 手动存档] ${slot.title}`;
  }

  private resolveFactionLabel(fid: FactionId): string {
    const cfg: FactionStaticConfig | undefined = getFactionConfigById(fid);
    return cfg !== undefined ? cfg.name : fid;
  }

  private saveToSelectedSlot(): void {
    if (!this.session.hasActiveCampaign()) {
      this.session.ensureCampaignForFaction(this.session.getSelectedMenuFaction(), false);
    }
    const res: SaveWriteResult = this.session.saveCurrentCampaignToSlot(this.selectedSlotIndex);
    this.feedbackMessage = res.message;
    this.refreshSlotsAndStats();
  }

  private loadSelectedSlotAndEnterMap(): void {
    const res: SaveLoadResult = this.session.loadCampaignFromSlot(this.selectedSlotIndex);
    this.feedbackMessage = res.message;
    if (!res.success || res.state === null) {
      this.refreshSlotsAndStats();
      return;
    }

    const launchParams: RouteLaunchParams = {
      modeKey: 'campaign',
      modeTitle: '读取存档进入大地图',
      factionId: res.state.playerFaction
    };
    this.getUIContext().getRouter().replaceUrl({
      url: 'pages/CampaignPage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Load into CampaignPage warning: %{public}s', JSON.stringify(err));
    });
  }

  private clearSelectedSlot(): void {
    const ok: boolean = this.session.deleteSaveSlot(this.selectedSlotIndex);
    this.feedbackMessage = ok
      ? `已清空槽位 ${this.selectedSlotIndex} 离线存档。`
      : `清空槽位 ${this.selectedSlotIndex} 失败。`;
    this.refreshSlotsAndStats();
  }

  private currentSelectedSlot(): SaveSlotSummary {
    if (this.selectedSlotIndex >= 0 && this.selectedSlotIndex < this.slots.length) {
      return this.slots[this.selectedSlotIndex];
    }
    const emptyFallback: SaveSlotSummary = {
      slotIndex: this.selectedSlotIndex,
      title: '空存档槽',
      factionId: FactionId.YANLONG,
      turnNumber: 0,
      controlledNodes: 0,
      updatedAtIso: '未创建',
      isEmpty: true
    };
    return emptyFallback;
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 14 }) {
        Button('‹ 返回上一页')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 18, right: 18 })
          .fontSize(15)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.goBack();
          })

        Text('本地离线多槽位存档与统帅战绩档案（SaveManager 6槽防损坏沙箱存储）')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')
          .layoutWeight(1)
      }
      .width('100%')

      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        // ==================== 左栏（58%）：6 个标准离线存档槽列表 ====================
        List({ space: 10 }) {
          ForEach(this.slots, (slot: SaveSlotSummary) => {
            ListItem() {
              Row() {
                Column({ space: 4 }) {
                  Text(this.resolveSlotHeading(slot))
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#FFF8E1')
                  Text(
                    slot.isEmpty
                      ? `状态：${slot.updatedAtIso}（可写入新进度）`
                      : `诸侯：${this.resolveFactionLabel(slot.factionId)} · 第 ${slot.turnNumber} 回合 · 统辖 ${slot.controlledNodes} 城 ｜ ${slot.updatedAtIso}`
                  )
                    .fontSize(12)
                    .fontColor('#90A4AE')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text(slot.isEmpty ? '空槽' : '可读取')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(slot.isEmpty ? '#78909C' : '#81C784')
              }
              .width('100%')
              .constraintSize({ minHeight: GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP })
              .padding(14)
              .backgroundColor(this.selectedSlotIndex === slot.slotIndex ? '#3E2E28' : '#232020')
              .borderRadius(10)
              .border({
                width: 1.5,
                color: this.selectedSlotIndex === slot.slotIndex ? '#D4A843' : '#373232'
              })
              .onClick(() => {
                this.selectedSlotIndex = slot.slotIndex;
              })
            }
          }, (slot: SaveSlotSummary) => `${slot.slotIndex}_${slot.updatedAtIso}_${slot.turnNumber}`)
        }
        .width(this.isWideScreen ? '58%' : '100%')
        .height(this.isWideScreen ? '100%' : '54%')

        // ==================== 右栏（42%）：槽位读写删操作与历代战绩面板 ====================
        Column({ space: 12 }) {
          Text(`当前选中：槽位 ${this.selectedSlotIndex}`)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD54F')

          Button(`将当前战役写入【槽位 ${this.selectedSlotIndex}】`)
            .width('100%')
            .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .backgroundColor('#2E7D32')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.saveToSelectedSlot();
            })

          Button(
            this.currentSelectedSlot().isEmpty
              ? `槽位 ${this.selectedSlotIndex} 为空（无法读档）`
              : `读取【槽位 ${this.selectedSlotIndex}】并进入战略大地图 ›`
          )
            .width('100%')
            .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .backgroundColor(this.currentSelectedSlot().isEmpty ? '#37474F' : '#B71C1C')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.loadSelectedSlotAndEnterMap();
            })

          Button(`清空删除【槽位 ${this.selectedSlotIndex}】存档`)
            .width('100%')
            .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
            .fontSize(14)
            .backgroundColor('#4E342E')
            .fontColor('#FFCDD2')
            .onClick(() => {
              this.clearSelectedSlot();
            })

          Text(this.feedbackMessage)
            .fontSize(12)
            .fontColor('#FFE082')
            .width('100%')
            .padding(10)
            .backgroundColor('#261F1B')
            .borderRadius(8)

          Text('统帅征战档案概览')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#81C784')

          Text(this.hallStatsText)
            .fontSize(13)
            .lineHeight(22)
            .fontColor('#CFD8DC')
        }
        .alignItems(HorizontalAlign.Start)
        .width(this.isWideScreen ? '42%' : '100%')
        .height(this.isWideScreen ? '100%' : '46%')
        .margin({ left: this.isWideScreen ? 14 : 0, top: this.isWideScreen ? 0 : 10 })
        .padding(16)
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
