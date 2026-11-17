import { FactionId, SaveSlotSummary } from '../model/GameTypes';

/**
 * 本地离线存档与战绩统计骨架页（第 1 步：Stage 路由容器占位，单机无需联网）
 */
@Entry
@Component
struct SavePage {
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

        Text('本地离线存档与历史战绩（Preferences / Sandbox JSON 骨架）')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')
      }
      .width('100%')

      List({ space: 10 }) {
        ForEach(this.defaultSlots, (slot: SaveSlotSummary) => {
          ListItem() {
            Row() {
              Column({ space: 4 }) {
                Text(`槽位 ${slot.slotIndex}：${slot.title}`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#FFF8E1')
                Text(slot.isEmpty ? '空槽位（待接入本地持久化模块）' : `第 ${slot.turnNumber} 回合 · 城关 ${slot.controlledNodes}`)
                  .fontSize(12)
                  .fontColor('#90A4AE')
              }
              .alignItems(HorizontalAlign.Start)
              Blank()
              Text('离线存储')
                .fontSize(12)
                .fontColor('#81C784')
            }
            .width('100%')
            .padding(14)
            .backgroundColor('#232020')
            .borderRadius(8)
          }
        }, (slot: SaveSlotSummary) => `${slot.slotIndex}`)
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
