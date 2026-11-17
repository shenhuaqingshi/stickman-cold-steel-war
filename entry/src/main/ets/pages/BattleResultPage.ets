import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';

const DOMAIN: number = 0x0001;
const TAG: string = 'BattleResultPage';

/**
 * 战后结算平板宽幅骨架页（第 1 步：伤亡、俘虏、缴获与晋升路由容器占位）
 */
@Entry
@Component
struct BattleResultPage {
  private returnToMenu(): void {
    this.getUIContext().getRouter().clear();
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'replaceUrl to Index warning: %{public}s', JSON.stringify(err));
    });
  }

  build() {
    Column({ space: 18 }) {
      Text('战后军功与伤亡结算面板（平板宽幅 Stage 骨架占位）')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor('#D4A843')

      Text('结算维度预留：左栏双方各军团投入/阵亡/重伤恢复明细 ｜ 右栏俘虏收编或赎金、粮草军械缴获、主帅晋升与养伤状态')
        .fontSize(15)
        .fontColor('#B0BEC5')
        .textAlign(TextAlign.Center)

      Button('返回主菜单')
        .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
        .padding({ left: 28, right: 28 })
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .backgroundColor('#4E342E')
        .fontColor('#FFF8E1')
        .onClick(() => {
          this.returnToMenu();
        })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .padding(28)
    .backgroundColor('#141110')
  }
}
