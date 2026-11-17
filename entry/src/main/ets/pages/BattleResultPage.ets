/**
 * 战后结算骨架页（第 1 步：伤亡、俘虏、缴获与晋升路由容器占位）
 */
@Entry
@Component
struct BattleResultPage {
  private returnToMenu(): void {
    this.getUIContext().getRouter().clear();
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
  }

  build() {
    Column({ space: 14 }) {
      Text('战后结算面板（Stage 路由骨架占位）')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#D4A843')

      Text('结算维度预留：双方投入兵力 / 阵亡与重伤恢复 / 俘虏收编或赎金 / 粮草军械缴获 / 主帅经验与伤势')
        .fontSize(13)
        .fontColor('#B0BEC5')

      Button('返回主菜单')
        .height(38)
        .fontSize(14)
        .backgroundColor('#4E342E')
        .fontColor('#FFF8E1')
        .onClick(() => {
          this.returnToMenu();
        })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding(24)
    .backgroundColor('#141110')
  }
}
