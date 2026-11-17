import { GameConstants } from '../common/GameConstants';
import { FactionId, SaveSlotSummary } from '../model/GameTypes';

/**
 * 本地离线存档与战绩统计平板双栏骨架页（第 1 步：左存档槽列表 + 右战绩统计概览，单机无需联网）
 */
@Entry
@Component
struct SavePage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;

  private readonly defaultSlots: readonly SaveSlotSummary[] = [
    {
      slotIndex: 1,
      title: '自动存档槽（待战役模块写入）',
      factionId: FactionId.YANLONG,
      turnNumber: 0,
      controlledNodes: 0,
      updatedAtIso: '未创建',
      isEmpty: true
    },
    {
      slotIndex: 2,
      title: '手动存档槽 #1',
      factionId: FactionId.CANGLANG,
      turnNumber: 0,
      controlledNodes: 0,
      updatedAtIso: '未创建',
      isEmpty: true
    },
    {
      slotIndex: 3,
      title: '手动存档槽 #2',
      factionId: FactionId.TIEYING,
      turnNumber: 0,
      controlledNodes: 0,
      updatedAtIso: '未创建',
      isEmpty: true
    }
  ];

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  build() {
    Column({ space: 14 }) {
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

        Text('本地离线存档与统帅战绩档案（应用沙箱 JSON + BackupAbility）')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')
      }
      .width('100%')

      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        List({ space: 12 }) {
          ForEach(this.defaultSlots, (slot: SaveSlotSummary) => {
            ListItem() {
              Row() {
                Column({ space: 5 }) {
                  Text(`槽位 ${slot.slotIndex}：${slot.title}`)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFF8E1')
                  Text(slot.isEmpty ? '空槽位（待接入本地持久化读写模块）' : `第 ${slot.turnNumber} 回合 · 城关 ${slot.controlledNodes}`)
                    .fontSize(13)
                    .fontColor('#90A4AE')
                }
                .alignItems(HorizontalAlign.Start)
                Blank()
                Text('单机离线存储')
                  .fontSize(13)
                  .fontColor('#81C784')
              }
              .width('100%')
              .constraintSize({ minHeight: GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP })
              .padding(16)
              .backgroundColor('#232020')
              .borderRadius(10)
            }
          }, (slot: SaveSlotSummary) => `${slot.slotIndex}`)
        }
        .width(this.isWideScreen ? '60%' : '100%')
        .height(this.isWideScreen ? '100%' : '58%')

        Column({ space: 10 }) {
          Text('历代战役统帅战绩概览（预留）')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD54F')
          Text('• 累计大捷场次 / 攻克王都数\n• 主帅亲手斩将夺旗次数\n• 经典以少胜多合围战役记录')
            .fontSize(14)
            .lineHeight(24)
            .fontColor('#B0BEC5')
        }
        .alignItems(HorizontalAlign.Start)
        .width(this.isWideScreen ? '40%' : '100%')
        .height(this.isWideScreen ? '100%' : '42%')
        .margin({ left: this.isWideScreen ? 14 : 0, top: this.isWideScreen ? 0 : 12 })
        .padding(18)
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
