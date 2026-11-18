import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { GameSessionCoordinator } from '../core/session/GameSessionCoordinator';
import { HarmonyFilePersistenceBackend } from './HarmonyFilePersistenceBackend';

const DOMAIN: number = 0x0001;
const TAG: string = 'StickmanColdSteelWar';

/**
 * 游戏主入口 Ability（HarmonyOS NEXT Stage 模型 · 鸿蒙平板 MatePad 优先适配）
 * 负责初始化平板大屏窗口、监听横竖屏旋转与分屏/悬浮窗尺寸变化，确保多窗动态布局不崩不裁切
 */
export default class EntryAbility extends UIAbility {
  private mainWinRef: window.Window | null = null;

  private updateWindowMetrics(widthPx: number, heightPx: number): void {
    const safeW: number = widthPx > 0 ? widthPx : 2560;
    const safeH: number = heightPx > 0 ? heightPx : 1600;
    AppStorage.setOrCreate<number>('winWidthPx', safeW);
    AppStorage.setOrCreate<number>('winHeightPx', safeH);
    // 宽高比 >= 1.05 视为横屏/宽幅平板双栏模式；竖屏或窄分屏时自动平滑降级为上下双区响应式布局
    AppStorage.setOrCreate<boolean>('isWideScreen', safeW >= safeH * 1.05);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setColorMode warning: %{public}s', JSON.stringify(error));
    }
    AppStorage.setOrCreate<boolean>('isWideScreen', true);
    try {
      const sandboxBackend: HarmonyFilePersistenceBackend = new HarmonyFilePersistenceBackend(
        this.context.filesDir
      );
      GameSessionCoordinator.getInstance().bindPersistenceBackend(sandboxBackend);
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'bindPersistenceBackend fallback warning: %{public}s', JSON.stringify(error));
    }
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate, launchReason=%{public}d', launchParam.launchReason);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageCreate');

    // 适配鸿蒙平板（MatePad）：默认横屏大视野优先，同时兼容横竖屏自由旋转、分屏与悬浮窗模式
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      this.mainWinRef = mainWindow;
      const rect: window.Rect = mainWindow.getWindowProperties().windowRect;
      this.updateWindowMetrics(rect.width, rect.height);

      mainWindow.on('windowSizeChange', (size: window.Size) => {
        this.updateWindowMetrics(size.width, size.height);
      });

      mainWindow.setWindowLayoutFullScreen(true).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen skipped in multi-window: %{public}s', JSON.stringify(err));
      });
      mainWindow.setWindowSystemBarEnable([]).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarEnable skipped in multi-window: %{public}s', JSON.stringify(err));
      });
      mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setPreferredOrientation warning: %{public}s', JSON.stringify(err));
      });
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'getMainWindow failed: %{public}s', JSON.stringify(err));
    });

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load pages/Index. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading pages/Index.');
    });
  }

  onWindowStageDestroy(): void {
    if (this.mainWinRef !== null) {
      try {
        this.mainWinRef.off('windowSizeChange');
      } catch (err) {
        const error = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'off windowSizeChange warning: %{public}s', JSON.stringify(error));
      }
      this.mainWinRef = null;
    }
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onBackground');
  }
}
