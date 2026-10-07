import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private stage?: window.WindowStage;
  private mainWindow?: window.Window;
  private avoidListener: (event: window.AvoidAreaOptions) => void =
    (_event: window.AvoidAreaOptions): void => { this.updateAvoidAreas(); };
  private sizeListener: (size: window.Size) => void =
    (_size: window.Size): void => { this.updateAvoidAreas(); };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.stage = windowStage;
    this.mainWindow = windowStage.getMainWindowSync();
    this.mainWindow.on('avoidAreaChange', this.avoidListener);
    this.mainWindow.on('windowSizeChange', this.sizeListener);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    this.configureSystemBars().then(() => {
      this.updateAvoidAreas();
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
        this.updateAvoidAreas();
      });
    });
  }

  onWindowStageDestroy(): void {
    this.mainWindow?.off('avoidAreaChange', this.avoidListener);
    this.mainWindow?.off('windowSizeChange', this.sizeListener);
    this.mainWindow = undefined;
    this.stage = undefined;
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    this.configureSystemBars();
    this.updateAvoidAreas();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onConfigurationUpdate(): void {
    this.configureSystemBars();
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  private async configureSystemBars(): Promise<void> {
    if (!this.stage) return;
    try {
      const mainWindow = this.stage.getMainWindowSync();
      const dark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      await mainWindow.setWindowLayoutFullScreen(true);
      await mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        isStatusBarLightIcon: dark,
        isNavigationBarLightIcon: dark
      });
      mainWindow.setWindowBackgroundColor(dark ? '#10151F' : '#F4F8FD');
    } catch (err) {
      hilog.error(DOMAIN, 'OHSurfing', 'System bar configuration failed: %{public}s', JSON.stringify(err));
    }
  }

  private updateAvoidAreas(): void {
    if (!this.mainWindow) return;
    try {
      const system = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const indicator = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate('safeTopPx', Math.max(system.topRect.height, cutout.topRect.height));
      AppStorage.setOrCreate('safeBottomPx', Math.max(system.bottomRect.height, indicator.bottomRect.height,
        cutout.bottomRect.height));
      AppStorage.setOrCreate('safeLeftPx', Math.max(system.leftRect.width, cutout.leftRect.width));
      AppStorage.setOrCreate('safeRightPx', Math.max(system.rightRect.width, cutout.rightRect.width));
    } catch (err) {
      hilog.error(DOMAIN, 'OHSurfing', 'Cannot read avoid areas: %{public}s', JSON.stringify(err));
    }
  }
}
