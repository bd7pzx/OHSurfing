import { wifiManager } from '@kit.ConnectivityKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { BusinessError } from '@kit.BasicServicesKit';
import native, { AuthStatus } from 'libohsurfing.so';
import { CredentialStore } from '../services/CredentialStore';

const BLUE: string = '#007DFF';
const RED: string = '#E35D65';

@Entry
@Component
struct Index {
  @StorageProp('safeTopPx') private safeTopPx: number = 0;
  @StorageProp('safeBottomPx') private safeBottomPx: number = 0;
  @StorageProp('safeLeftPx') private safeLeftPx: number = 0;
  @StorageProp('safeRightPx') private safeRightPx: number = 0;
  @State private page: number = 0;
  @State private selectedTab: number = 0;
  @State private username: string = '';
  @State private password: string = '';
  @State private rememberCredentials: boolean = false;
  @State private snapshot: AuthStatus = native.status();
  @State private running: boolean = native.status().running;
  @State private ssid: string = '未连接 Wi-Fi';
  @State private gripEnabled: boolean = false;
  @State private holding: motion.HoldingHandStatus = motion.HoldingHandStatus.UNKNOWN_STATUS;
  @State private glow: number = 60;
  @State private totalSeconds: number = 0;
  @State private now: number = Date.now();
  @State private busy: boolean = false;
  @State private aboutOpen: boolean = false;
  @State private credentialError: string = '';
  @State private powerOnLeft: boolean = false;
  @State private gripMessage: string = '';
  @State private dockWidth: number = 360;
  @State private dockHeight: number = 640;
  private gripSubscribed: boolean = false;
  private gripSubscriptionPending: boolean = false;
  private pageVisible: boolean = true;
  private pulseInFlight: boolean = false;
  private connectionEpoch: number = 0;
  private tickTimer: number = -1;
  private pulseTimer: number = -1;
  private settingsQueue: Promise<void> = Promise.resolve();
  private tabsController: HdsTabsController = new HdsTabsController();
  private gripListener: (status: motion.HoldingHandStatus) => void =
    (status: motion.HoldingHandStatus): void => {
      this.holding = status;
      // Keep the last usable hand when the phone reports both hands or an unknown pose.
      if (status === motion.HoldingHandStatus.LEFT_HAND_HELD ||
        status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
        this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseInOut }, () => {
          this.powerOnLeft = status === motion.HoldingHandStatus.LEFT_HAND_HELD;
        });
      }
    };

  onPageShow(): void {
    this.pageVisible = true;
    if (!this.busy && !this.pulseInFlight) this.updateSnapshot(native.status());
    if (this.gripEnabled) this.subscribeGrip(false);
  }

  onPageHide(): void {
    this.pageVisible = false;
    this.unsubscribeGrip();
  }

  aboutToAppear(): void {
    this.restoreSettings();
    this.refreshWifi();
    this.tickTimer = setInterval((): void => {
      this.now = Date.now();
      this.refreshWifi();
    }, 1000);
    this.pulseTimer = setInterval((): void => { this.pulse(); }, 30000);
  }

  aboutToDisappear(): void {
    if (this.tickTimer !== -1) clearInterval(this.tickTimer);
    if (this.pulseTimer !== -1) clearInterval(this.pulseTimer);
    this.unsubscribeGrip();
  }

  private async restoreSettings(): Promise<void> {
    try {
      const store = await preferences.getPreferences(getContext(this), 'ohsurfing');
      this.rememberCredentials = Boolean(await store.get('rememberCredentials', false));
      if (this.rememberCredentials) {
        const saved = await CredentialStore.load();
        this.username = saved.username || String(await store.get('username', ''));
        this.password = saved.password;
      } else {
        this.username = String(await store.get('username', ''));
      }
      this.glow = Number(await store.get('glow', 60));
      this.totalSeconds = Number(await store.get('totalSeconds', 0));
      this.gripEnabled = Boolean(await store.get('gripEnabled', false));
      if (this.gripEnabled) await this.subscribeGrip(true);
    } catch (_) { this.gripEnabled = false; }
  }

  private saveSettings(): Promise<void> {
    this.settingsQueue = this.settingsQueue.then(() => this.writeSettings());
    return this.settingsQueue;
  }

  private async writeSettings(): Promise<void> {
    try {
      const store = await preferences.getPreferences(getContext(this), 'ohsurfing');
      await store.put('rememberCredentials', this.rememberCredentials);
      // Remove credentials saved by older versions of the app in plain preferences.
      await store.delete('username');
      await store.delete('password');
      await store.put('glow', this.glow);
      await store.put('totalSeconds', this.totalSeconds);
      await store.put('gripEnabled', this.gripEnabled);
      await store.flush();
      if (this.rememberCredentials) {
        await CredentialStore.save(this.username, this.password);
      } else {
        await CredentialStore.clear();
      }
      this.credentialError = '';
    } catch (_) {
      this.credentialError = '保存设置失败，请重试';
    }
  }

  private async setRememberCredentials(enabled: boolean): Promise<void> {
    this.rememberCredentials = enabled;
    await this.saveSettings();
  }

  private async refreshWifi(): Promise<void> {
    try {
      if (!wifiManager.isConnected()) { this.ssid = '未连接 Wi-Fi'; return; }
      const info = await wifiManager.getLinkedInfo();
      this.ssid = info.ssid || '已连接 Wi-Fi';
    } catch (_) { this.ssid = 'SSID 暂不可用'; }
  }

  private async subscribeGrip(requestPermission: boolean): Promise<void> {
    if (this.gripSubscribed || this.gripSubscriptionPending) return;
    this.gripSubscriptionPending = true;
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let granted = await manager.checkAccessToken(context.applicationInfo.accessTokenId,
        'ohos.permission.DETECT_GESTURE') === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      if (!granted && requestPermission) {
        const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.DETECT_GESTURE']);
        granted = result.authResults[0] === 0;
      }
      if (!granted) { this.gripMessage = '未获握姿权限，请在系统设置中允许'; return; }
      if (!this.pageVisible || !this.gripEnabled) return;
      motion.on('holdingHandChanged', this.gripListener);
      this.gripSubscribed = true;
      this.gripMessage = '';
    } catch (error) {
      const code = (error as BusinessError).code;
      this.gripMessage = code === 801 ? '此设备不支持握姿识别' : `握姿识别暂不可用（${code}）`;
    } finally {
      this.gripSubscriptionPending = false;
    }
  }

  private unsubscribeGrip(): void {
    if (this.gripSubscribed) {
      try { motion.off('holdingHandChanged', this.gripListener); } catch (_) { }
    }
    this.gripSubscribed = false;
    this.holding = motion.HoldingHandStatus.UNKNOWN_STATUS;
  }

  private async setGrip(enabled: boolean): Promise<void> {
    if (enabled) {
      this.gripEnabled = true;
      await this.subscribeGrip(true);
    } else {
      this.gripEnabled = false;
      this.unsubscribeGrip();
      this.powerOnLeft = false;
    }
    await this.saveSettings();
  }

  private async toggleConnection(): Promise<void> {
    if (this.busy) return;
    if (!this.running && (!this.username.trim() || !this.password)) {
      this.selectedTab = 1;
      this.tabsController.changeIndex(1);
      return;
    }
    this.busy = true;
    this.connectionEpoch++;
    const stopping = this.running;
    this.running = !stopping;
    try {
      if (stopping) {
        this.totalSeconds += this.currentSessionSeconds();
        this.updateSnapshot(await native.stop());
        await this.saveSettings();
      } else {
        this.updateSnapshot(await native.start(this.username.trim(), this.password));
        if (!this.rememberCredentials) this.password = '';
        await this.saveSettings();
      }
      this.now = Date.now();
    } catch (_) { this.updateSnapshot(native.status()); }
    finally { this.busy = false; }
  }

  private async pulse(): Promise<void> {
    if (this.busy || this.pulseInFlight || !this.running) return;
    this.pulseInFlight = true;
    const epoch = this.connectionEpoch;
    const wasAuthenticated: boolean = this.snapshot.authenticated;
    const elapsed: number = this.currentSessionSeconds();
    try {
      const status = await native.pulse();
      if (epoch !== this.connectionEpoch) return;
      this.updateSnapshot(status);
    } catch (_) {
      if (epoch !== this.connectionEpoch) return;
      this.updateSnapshot(native.status());
    } finally { this.pulseInFlight = false; }
    if (wasAuthenticated && !this.snapshot.authenticated) {
      this.totalSeconds += elapsed;
      await this.saveSettings();
    }
  }

  private currentSessionSeconds(): number {
    if (!this.snapshot.authenticated || !this.snapshot.connectedAt) return 0;
    return Math.max(0, Math.floor((this.now - this.snapshot.connectedAt) / 1000));
  }

  private duration(): string {
    const total = this.totalSeconds + this.currentSessionSeconds();
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;
    return `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
  }

  private updateSnapshot(status: AuthStatus): void {
    this.snapshot = status;
    this.running = status.running;
  }

  private connected(): boolean {
    return this.snapshot.authenticated || this.snapshot.phase === 'online';
  }

  private gripText(): string {
    if (!this.gripEnabled) return '已关闭';
    if (this.gripMessage) return this.gripMessage;
    switch (this.holding) {
      case motion.HoldingHandStatus.LEFT_HAND_HELD: return '左手握持';
      case motion.HoldingHandStatus.RIGHT_HAND_HELD: return '右手握持';
      case motion.HoldingHandStatus.BOTH_HANDS_HELD: return '双手握持';
      case motion.HoldingHandStatus.NOT_HELD: return '未握持';
      default: return '等待识别';
    }
  }

  @Builder
  private header() {
    Row() {
      Image($r('app.media.tianyi_logo')).width(48).height(48).objectFit(ImageFit.Contain)
      Column({ space: 2 }) {
        Text('天翼校园').fontSize(23).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Text('OHSurfing').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.alignItems(HorizontalAlign.Start).margin({ left: 12 })
      Blank()
      Text(this.connected() ? '已连接' : this.running && this.busy ? '连接中' : '未连接')
        .fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(this.connected() ? $r('app.color.status_online') : $r('app.color.text_secondary'))
        .backgroundColor(this.connected() ? $r('app.color.status_online_bg') : $r('app.color.status_idle_bg'))
        .borderRadius(99).padding({ left: 12, right: 12, top: 7, bottom: 7 })
    }.width('100%').padding({ left: 24, right: 24, top: 18, bottom: 20 })
  }

  @Builder
  private home() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 9 }) {
          Text('连接总时长').fontSize(14).fontColor($r('app.color.text_secondary'))
          Text(this.duration()).fontSize(39).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          Text(this.snapshot.detail).fontSize(13)
            .fontColor(this.snapshot.phase === 'error' ? $r('app.color.error') : $r('app.color.text_secondary'))
        }.width('100%').alignItems(HorizontalAlign.Start).padding(24)
          .backgroundColor($r('app.color.card')).borderRadius(25)
        Row({ space: 14 }) {
          SymbolGlyph($r('sys.symbol.wifi')).fontSize(27).fontColor([BLUE])
          Column({ space: 5 }) {
            Text('Wi-Fi SSID').fontSize(13).fontColor($r('app.color.text_secondary'))
            Text(this.ssid).fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start)
        }.width('100%').padding(22).backgroundColor($r('app.color.card')).borderRadius(25)
        Column({ space: 14 }) {
          Row({ space: 9 }) {
            SymbolGlyph($r('sys.symbol.list_bullet')).fontSize(20).fontColor([BLUE])
            Text('运行日志').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
          }.width('100%')
          if (this.snapshot.logs.length === 0) {
            Text('连接后将在这里显示验证记录').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          } else {
            ForEach(this.snapshot.logs.slice().reverse(), (line: string, index: number) => {
              Text(line).fontSize(12).fontColor($r('app.color.text_log')).width('100%')
                .padding({ top: 7, bottom: 7 })
            }, (line: string, index: number) => `${index}:${line}`)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(22)
          .backgroundColor($r('app.color.card')).borderRadius(25)
      }.width('100%').padding({ left: 20, right: 20, top: 4, bottom: 108 })
    }.align(Alignment.TopStart).scrollBar(BarState.Off).layoutWeight(1)
  }

  @Builder
  private profile() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 15 }) {
          Text('个人信息').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
          Text('校园网账号').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: this.username, placeholder: '请输入账号' })
            .onChange((value: string) => { this.username = value; if (this.rememberCredentials) this.saveSettings(); })
            .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_secondary'))
            .height(50).backgroundColor($r('app.color.input')).borderRadius(14)
          Text('密码').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: this.password, placeholder: '请输入密码' })
            .type(InputType.Password).onChange((value: string) => {
              this.password = value;
              if (this.rememberCredentials) this.saveSettings();
            })
            .fontColor($r('app.color.text_primary')).placeholderColor($r('app.color.text_secondary'))
            .height(50).backgroundColor($r('app.color.input')).borderRadius(14)
          Row() {
            Column({ space: 4 }) {
              Text('记住账号密码').fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
              Text('凭据保存在本机关键资产中').fontSize(12).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.rememberCredentials })
              .selectedColor(BLUE).onChange((value: boolean) => { this.setRememberCredentials(value); })
          }.width('100%')
          if (this.credentialError) {
            Text(this.credentialError).fontSize(12).fontColor($r('app.color.error')).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(22)
          .backgroundColor($r('app.color.card')).borderRadius(25)
        Column({ space: 15 }) {
          Row() {
            Text('动态光感强度').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Blank()
            Text(`${this.glow}%`).fontSize(14).fontColor(BLUE)
          }.width('100%')
          Slider({ value: this.glow, min: 0, max: 100, step: 5 })
            .selectedColor(BLUE).onChange((value: number) => {
              this.glow = value; this.saveSettings();
            })
          Row() {
            Column({ space: 4 }) {
              Text('握姿检测').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              Text(this.gripText()).fontSize(12).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.gripEnabled })
              .selectedColor(BLUE).onChange((value: boolean) => { this.setGrip(value); })
          }.width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start).padding(22)
          .backgroundColor($r('app.color.card')).borderRadius(25)
        Column({ space: 9 }) {
          Row() {
            Text('关于').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
            Blank()
            SymbolGlyph($r('sys.symbol.info_circle')).fontSize(18).fontColor([$r('app.color.text_secondary')])
          }.width('100%').onClick(() => { this.aboutOpen = !this.aboutOpen; })
          if (this.aboutOpen) {
            Text('OHSurfing · 基于 ESurfingClient-C 验证协议。连接需处于支持的天翼校园网络；握姿识别依赖设备能力。')
              .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(22)
          .backgroundColor($r('app.color.card')).borderRadius(25)
      }.width('100%').padding({ left: 20, right: 20, top: 4, bottom: 108 })
    }.align(Alignment.TopStart).scrollBar(BarState.Off).layoutWeight(1)
  }

  @Builder
  private tabButton(title: string, symbol: Resource, target: number) {
    Column({ space: 4 }) {
      SymbolGlyph(symbol).fontSize(23)
        .fontColor([this.selectedTab === target ? BLUE : $r('app.color.text_secondary')])
      Text(title).fontSize(11)
        .fontWeight(this.selectedTab === target ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.selectedTab === target ? BLUE : $r('app.color.text_secondary'))
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      .backgroundColor(this.selectedTab === target ? $r('app.color.tab_selected') : Color.Transparent)
      .borderRadius(24)
      .animation({ duration: 120, curve: Curve.EaseOut })
  }

  @Builder
  private powerButton() {
    Button() {
      if (this.running) {
        SymbolGlyph($r('sys.symbol.pause')).fontSize(26).fontColor(['#FFFFFF'])
      } else {
        SymbolGlyph($r('sys.symbol.play_fill')).fontSize(26).fontColor(['#FFFFFF'])
      }
    }
      .width(56).height(56).borderRadius(28)
      .backgroundColor(this.running ? RED : BLUE)
      .shadow({ radius: this.glow / 9,
        color: this.running ? '#66E35D65' : '#66007DFF', offsetY: 3 })
      .animation({ duration: 280, curve: Curve.EaseInOut })
      .accessibilityText(this.running ? '暂停连接' : '开始连接')
      .enabled(!this.busy).onClick(() => { this.toggleConnection(); })
  }

  @Builder
  private powerDock() {
    Row() {
      this.powerButton()
    }.width(56).height(56)
      .position({ x: this.gripEnabled && this.powerOnLeft ? 20 : Math.max(20, this.dockWidth - 76),
        y: Math.max(0, this.dockHeight - 64) })
      .animation({ duration: 280, curve: Curve.EaseInOut })
  }

  build() {
    Column() {
      Stack() {
      HdsTabs({ index: this.page, controller: this.tabsController }) {
        TabContent() {
          Column() {
            this.header()
            this.home()
          }.height('100%')
        }.tabBar(this.tabButton('主页', $r('sys.symbol.house'), 0))
        TabContent() {
          Column() {
            this.header()
            this.profile()
          }.height('100%')
        }.tabBar(this.tabButton('个人信息', $r('sys.symbol.person'), 1))
      }
      .barHeight(56)
      .barPosition(BarPosition.End)
      .vertical(false)
      .barOverlap(true)
      .barFloatingStyle({
        barWidth: { smallWidth: Math.min(168, Math.max(144, this.dockWidth - 152)),
          mediumWidth: 168, largeWidth: 184 },
        barBottomMargin: 8,
        gradientMask: { maskColor: $r('app.color.canvas'), maskHeight: 72 },
        lightColor: `#${Math.round(this.glow * 0.6).toString(16).padStart(2, '0')}FFFFFF`,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .scrollable(false)
      .animationDuration(200)
      .onTabBarClick((index: number) => { this.selectedTab = index; })
      .onChange((index: number) => { this.page = index; this.selectedTab = index; })
      .expandSafeArea([], [])
      .width('100%').height('100%')
      this.powerDock()
      }.width('100%').layoutWeight(1)
        .onAreaChange((_oldArea: Area, area: Area) => {
          this.dockWidth = Number(area.width);
          this.dockHeight = Number(area.height);
        })
    }.width(LayoutPolicy.matchParent).height(LayoutPolicy.matchParent)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.ALL])
      .padding({
        top: this.getUIContext().px2vp(this.safeTopPx),
        bottom: this.getUIContext().px2vp(this.safeBottomPx),
        left: this.getUIContext().px2vp(this.safeLeftPx),
        right: this.getUIContext().px2vp(this.safeRightPx)
      })
      .backgroundColor($r('app.color.canvas'))
  }
}
