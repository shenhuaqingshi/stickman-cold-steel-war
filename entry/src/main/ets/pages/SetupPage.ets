import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GameConstants } from '../common/GameConstants';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../config/FactionConfig';
import { UNIT_STATIC_CONFIGS } from '../config/UnitConfig';
import {
  ArmyCorpsRole,
  BattleScenarioType,
  FactionId,
  RosterEntry,
  TerrainType,
  UnitTypeId,
  WeatherType
} from '../core/CoreContracts';
import { GameSessionCoordinator, SetupDraftState } from '../core/session/GameSessionCoordinator';
import { FactionStaticConfig, RouteLaunchParams, UnitStaticStats } from '../model/GameTypes';

const DOMAIN: number = 0x0001;
const TAG: string = 'SetupPage';

interface CorpsOptionItem {
  readonly role: ArmyCorpsRole;
  readonly label: string;
}

interface TerrainOptionItem {
  readonly terrain: TerrainType;
  readonly label: string;
}

interface WeatherOptionItem {
  readonly weather: WeatherType;
  readonly label: string;
}

interface ScenarioOptionItem {
  readonly scenario: BattleScenarioType;
  readonly label: string;
}

/**
 * 战前整军平板双栏正式页（支撑遭遇战 / 守城挑战 / 自定义战场）
 * 左栏（38%）：敌我阵营、地形天气、携行军粮、六大建制军团导航与预设；
 * 右栏（62%）：16 种冷兵器兵种检阅矩阵与实时增减编配主视图。
 */
@Entry
@Component
struct SetupPage {
  @StorageProp('isWideScreen') isWideScreen: boolean = true;
  @State modeKey: string = 'skirmish';
  @State modeTitle: string = '遭遇战 · 战前整军配兵';
  @State playerFaction: FactionId = FactionId.YANLONG;
  @State enemyFaction: FactionId = FactionId.CANGLANG;
  @State scenarioType: BattleScenarioType = BattleScenarioType.FIELD_PITCHED;
  @State selectedTerrain: TerrainType = TerrainType.RIVER_FORD;
  @State selectedWeather: WeatherType = WeatherType.CLEAR_DAY;
  @State initialGrain: number = GameConstants.BATTLE_INIT_GRAIN;
  @State selectedCorpsRole: ArmyCorpsRole = ArmyCorpsRole.VANGUARD_CENTER;
  @State selectedUnitIndex: number = 1;
  @State popUsed: number = 0;
  @State totalSoldiers: number = 0;
  @State rosterVersion: number = 0;
  @State tipMessage: string = '点选左侧目标军团与右侧兵种卡片，配置前锋抗线、两翼包抄与总预备队后点击右上角开战！';

  private readonly session: GameSessionCoordinator = GameSessionCoordinator.getInstance();

  private readonly corpsOptions: readonly CorpsOptionItem[] = [
    { role: ArmyCorpsRole.VANGUARD_CENTER, label: '1 中军前锋' },
    { role: ArmyCorpsRole.LEFT_WING, label: '2 左翼军团' },
    { role: ArmyCorpsRole.RIGHT_WING, label: '3 右翼军团' },
    { role: ArmyCorpsRole.REAR_RESERVE, label: '4 总预备队' },
    { role: ArmyCorpsRole.SIEGE_BATTERY, label: '5 远程攻城' },
    { role: ArmyCorpsRole.SUPPLY_ESCORT, label: '6 辎重护粮' }
  ];

  private readonly terrainOptions: readonly TerrainOptionItem[] = [
    { terrain: TerrainType.PLAIN, label: '开阔平原' },
    { terrain: TerrainType.RIVER_FORD, label: '河流浅滩' },
    { terrain: TerrainType.HIGH_GROUND, label: '山坡高地' },
    { terrain: TerrainType.DENSE_FOREST, label: '迷雾密林' },
    { terrain: TerrainType.BRIDGE_PASS, label: '桥梁窄关' },
    { terrain: TerrainType.DESERT_DUNE, label: '荒漠沙丘' },
    { terrain: TerrainType.SNOWFIELD, label: '极寒雪原' },
    { terrain: TerrainType.FORT_WALL, label: '雄关城防' }
  ];

  private readonly weatherOptions: readonly WeatherOptionItem[] = [
    { weather: WeatherType.CLEAR_DAY, label: '晴朗白昼' },
    { weather: WeatherType.HEAVY_FOG, label: '浓雾弥漫' },
    { weather: WeatherType.RAIN_MUD, label: '暴雨泥泞' },
    { weather: WeatherType.BLIZZARD, label: '凛冽暴雪' },
    { weather: WeatherType.NIGHT, label: '幽暗黑夜' }
  ];

  private readonly scenarioOptions: readonly ScenarioOptionItem[] = [
    { scenario: BattleScenarioType.FIELD_PITCHED, label: '标准野战' },
    { scenario: BattleScenarioType.SIEGE_ASSAULT, label: '攻城拔寨' },
    { scenario: BattleScenarioType.SIEGE_DEFENSE, label: '据城死守' },
    { scenario: BattleScenarioType.AMBUSH, label: '密林伏击' },
    { scenario: BattleScenarioType.CONVOY_ESCORT, label: '奇袭断粮' },
    { scenario: BattleScenarioType.NIGHT_RAID, label: '黑夜劫营' }
  ];

  aboutToAppear(): void {
    const rawParams: Object | undefined = this.getUIContext().getRouter().getParams();
    if (rawParams !== undefined) {
      const typedParams: RouteLaunchParams = rawParams as RouteLaunchParams;
      if (typedParams.modeKey && typedParams.factionId) {
        const currentDraft: SetupDraftState = this.session.getSetupDraft();
        if (currentDraft.modeKey !== typedParams.modeKey) {
          this.session.prepareSetupForMode(
            typedParams.modeKey,
            typedParams.modeTitle,
            typedParams.factionId
          );
        }
      }
    }
    this.syncFromSessionDraft();
  }

  private syncFromSessionDraft(): void {
    const draft: SetupDraftState = this.session.getSetupDraft();
    this.modeKey = draft.modeKey;
    this.modeTitle = `${draft.modeTitle} · 战前整军`;
    this.playerFaction = draft.playerFaction;
    this.enemyFaction = draft.enemyFaction;
    this.scenarioType = draft.scenarioType;
    this.selectedTerrain = draft.terrain;
    this.selectedWeather = draft.weather;
    this.initialGrain = draft.initialGrain;
    this.popUsed = this.session.computeSetupPlayerPopUsed();
    this.totalSoldiers = this.session.computeSetupPlayerTotalSoldiers();
    this.rosterVersion++;
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private launchRealBattle(): void {
    this.session.launchBattleFromSetup();
    const launchParams: RouteLaunchParams = {
      modeKey: this.modeKey,
      modeTitle: this.modeTitle,
      factionId: this.playerFaction
    };
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/BattlePage',
      params: launchParams
    }).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Enter BattlePage warning: %{public}s', JSON.stringify(err));
    });
  }

  private cycleFaction(isPlayer: boolean): void {
    const currentId: FactionId = isPlayer ? this.playerFaction : this.enemyFaction;
    let idx: number = 0;
    for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
      if (FACTION_STATIC_CONFIGS[i].id === currentId) {
        idx = i;
        break;
      }
    }
    const nextIdx: number = (idx + 1) % FACTION_STATIC_CONFIGS.length;
    const nextFac: FactionId = FACTION_STATIC_CONFIGS[nextIdx].id;
    if (isPlayer) {
      this.session.setSetupPlayerFaction(nextFac);
    } else {
      const safeEnemy: FactionId =
        nextFac === this.playerFaction
          ? FACTION_STATIC_CONFIGS[(nextIdx + 1) % FACTION_STATIC_CONFIGS.length].id
          : nextFac;
      this.session.setSetupEnemyFaction(safeEnemy);
    }
    this.syncFromSessionDraft();
  }

  private changeUnitCount(unit: UnitStaticStats, delta: number): void {
    if (!this.session.canUnitBeRecruitedByFaction(this.playerFaction, unit.id)) {
      this.tipMessage = `【${unit.name}】受势力编制限制（他国专属王牌或苍狼禁造配重投石车），不可编入当前诸侯军团。`;
      return;
    }
    const ok: boolean = this.session.adjustSetupUnitCount(unit.id, this.selectedCorpsRole, delta);
    if (!ok && delta > 0) {
      this.tipMessage = `军团总人口已达战场上界 ${GameConstants.DEFAULT_ARMY_POP_CAP}，请先缩减其他编制再增补精锐。`;
    } else {
      this.syncFromSessionDraft();
      const countNow: number = this.session.getSetupUnitCountInCorps(unit.id, this.selectedCorpsRole);
      this.tipMessage = `已调整【${this.getCorpsLabel(this.selectedCorpsRole)}】的【${unit.name}】至 ${countNow} 员（总人口 ${this.popUsed}/${GameConstants.DEFAULT_ARMY_POP_CAP}）。`;
    }
  }

  private getFactionName(fid: FactionId): string {
    const cfg: FactionStaticConfig | undefined = getFactionConfigById(fid);
    return cfg !== undefined ? cfg.name : fid;
  }

  private getCorpsLabel(role: ArmyCorpsRole): string {
    for (let i: number = 0; i < this.corpsOptions.length; i++) {
      if (this.corpsOptions[i].role === role) {
        return this.corpsOptions[i].label;
      }
    }
    return role;
  }

  private summarizeCorpsRoster(role: ArmyCorpsRole, _ver: number): string {
    const list: readonly RosterEntry[] = this.session.getSetupDraft().playerRoster;
    const parts: string[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const item: RosterEntry = list[i];
      if (item.corpsRole === role && item.count > 0) {
        for (let u: number = 0; u < UNIT_STATIC_CONFIGS.length; u++) {
          if (UNIT_STATIC_CONFIGS[u].id === item.unitType) {
            parts.push(`${UNIT_STATIC_CONFIGS[u].name}×${item.count}`);
            break;
          }
        }
      }
    }
    return parts.length > 0 ? parts.join(' + ') : '未编配（空置）';
  }

  private mapDimensionsLabel(): string {
    const isSiege: boolean =
      this.scenarioType === BattleScenarioType.SIEGE_ASSAULT ||
      this.scenarioType === BattleScenarioType.SIEGE_DEFENSE;
    return isSiege
      ? `${GameConstants.SIEGE_BATTLEFIELD_WIDTH}×${GameConstants.SIEGE_BATTLEFIELD_HEIGHT}`
      : `${GameConstants.BATTLEFIELD_WIDTH}×${GameConstants.BATTLEFIELD_HEIGHT}`;
  }

  build() {
    Column({ space: 10 }) {
      // 顶部平板宽幅整军指挥条（触控按钮 >= 48vp / 54vp）
      Row({ space: 12 }) {
        Button('‹ 返回主菜单')
          .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
          .padding({ left: 16, right: 16 })
          .fontSize(14)
          .backgroundColor('#3E2723')
          .fontColor('#FFF8E1')
          .onClick(() => {
            this.goBack();
          })

        Text(`${this.modeTitle}（战场 ${this.mapDimensionsLabel()} · 兵力 ${this.totalSoldiers}人 · 人口 ${this.popUsed}/${GameConstants.DEFAULT_ARMY_POP_CAP} · 携粮 ${this.initialGrain}）`)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#D4A843')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Button('披挂出征 · 进入真实大战场 ›')
          .height(GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP)
          .padding({ left: 22, right: 22 })
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .backgroundColor('#B71C1C')
          .fontColor('#FFFFFF')
          .onClick(() => {
            this.launchRealBattle();
          })
      }
      .width('100%')

      Flex({ direction: this.isWideScreen ? FlexDirection.Row : FlexDirection.Column }) {
        // ==================== 左栏（38%）：对阵双方、地形天气、粮草与六军团建制栏 ====================
        Scroll() {
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              Button(`我方：${this.getFactionName(this.playerFaction)} ↻`)
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#3E2E28')
                .fontColor('#FFF8E1')
                .onClick(() => {
                  this.cycleFaction(true);
                })

              Button(`敌方：${this.getFactionName(this.enemyFaction)} ↻`)
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#2C222E')
                .fontColor('#FFCDD2')
                .onClick(() => {
                  this.cycleFaction(false);
                })
            }
            .width('100%')

            if (this.modeKey === 'custom') {
              Text('战役关卡类型（自定义沙盒可自由切换 6 类会战）')
                .fontSize(12)
                .fontColor('#B0BEC5')

              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.scenarioOptions, (sc: ScenarioOptionItem) => {
                  Button(sc.label)
                    .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                    .margin({ right: 6, bottom: 6 })
                    .padding({ left: 10, right: 10 })
                    .fontSize(12)
                    .backgroundColor(this.scenarioType === sc.scenario ? '#6D4C41' : '#26201E')
                    .fontColor('#FFF8E1')
                    .onClick(() => {
                      this.session.setSetupScenarioType(sc.scenario);
                      this.syncFromSessionDraft();
                    })
                }, (sc: ScenarioOptionItem) => sc.scenario)
              }
              .width('100%')
            }

            Text('古战场地形与天象昼夜选择')
              .fontSize(12)
              .fontColor('#B0BEC5')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.terrainOptions, (tr: TerrainOptionItem) => {
                Button(tr.label)
                  .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                  .margin({ right: 6, bottom: 6 })
                  .padding({ left: 10, right: 10 })
                  .fontSize(12)
                  .backgroundColor(this.selectedTerrain === tr.terrain ? '#4E342E' : '#232020')
                  .fontColor(this.selectedTerrain === tr.terrain ? '#FFD54F' : '#CFD8DC')
                  .onClick(() => {
                    this.session.setSetupTerrain(tr.terrain);
                    this.syncFromSessionDraft();
                  })
              }, (tr: TerrainOptionItem) => tr.terrain)
            }
            .width('100%')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.weatherOptions, (wt: WeatherOptionItem) => {
                Button(wt.label)
                  .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                  .margin({ right: 6, bottom: 6 })
                  .padding({ left: 10, right: 10 })
                  .fontSize(12)
                  .backgroundColor(this.selectedWeather === wt.weather ? '#37474F' : '#232020')
                  .fontColor(this.selectedWeather === wt.weather ? '#81D4FA' : '#CFD8DC')
                  .onClick(() => {
                    this.session.setSetupWeather(wt.weather);
                    this.syncFromSessionDraft();
                  })
              }, (wt: WeatherOptionItem) => wt.weather)
            }
            .width('100%')

            // 携行军粮与一键编制预设
            Row({ space: 6 }) {
              Button('粮 -200')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(12)
                .backgroundColor('#2E2623')
                .onClick(() => {
                  this.session.setSetupInitialGrain(this.initialGrain - 200);
                  this.syncFromSessionDraft();
                })
              Text(`携粮 ${this.initialGrain}`)
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFE082')
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
              Button('粮 +200')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .fontSize(12)
                .backgroundColor('#2E2623')
                .onClick(() => {
                  this.session.setSetupInitialGrain(this.initialGrain + 200);
                  this.syncFromSessionDraft();
                })
            }
            .width('100%')

            Row({ space: 6 }) {
              Button('均衡百人阵')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(12)
                .backgroundColor('#33691E')
                .onClick(() => {
                  this.session.applySetupPreset('balanced');
                  this.syncFromSessionDraft();
                })
              Button('铁骑两翼阵')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(12)
                .backgroundColor('#01579B')
                .onClick(() => {
                  this.session.applySetupPreset('cavalry_blitz');
                  this.syncFromSessionDraft();
                })
              Button('清空重配')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(12)
                .backgroundColor('#4E342E')
                .onClick(() => {
                  this.session.applySetupPreset('clear');
                  this.syncFromSessionDraft();
                })
            }
            .width('100%')

            Text('点选要编配的建制军团（支持 6 路多线同时交锋）：')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFD54F')

            ForEach(this.corpsOptions, (corps: CorpsOptionItem) => {
              Column({ space: 3 }) {
                Text(corps.label)
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFF8E1')
                Text(this.summarizeCorpsRoster(corps.role, this.rosterVersion))
                  .fontSize(12)
                  .fontColor('#81C784')
                  .maxLines(2)
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .constraintSize({ minHeight: GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP })
              .padding(10)
              .backgroundColor(this.selectedCorpsRole === corps.role ? '#3E2E28' : '#232020')
              .borderRadius(8)
              .border({
                width: 1.5,
                color: this.selectedCorpsRole === corps.role ? '#D4A843' : '#332C2A'
              })
              .onClick(() => {
                this.selectedCorpsRole = corps.role;
              })
            }, (corps: CorpsOptionItem) => corps.role)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .width(this.isWideScreen ? '38%' : '100%')
        .height(this.isWideScreen ? '100%' : '46%')
        .padding(12)
        .backgroundColor('#1A1514')
        .borderRadius(10)

        // ==================== 右栏（62%）：16 兵种名册与选中军团增减编配主视图 ====================
        Column({ space: 10 }) {
          Text(`全兵种名册（当前编入目标：【${this.getCorpsLabel(this.selectedCorpsRole)}】）`)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F5E6C8')

          Grid() {
            ForEach(UNIT_STATIC_CONFIGS, (unit: UnitStaticStats, idx: number) => {
              GridItem() {
                Column({ space: 4 }) {
                  Row() {
                    Text(unit.name)
                      .fontSize(14)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(
                        this.session.canUnitBeRecruitedByFaction(this.playerFaction, unit.id)
                          ? '#FFF8E1'
                          : '#78909C'
                      )
                      .layoutWeight(1)
                      .maxLines(1)

                    Text(
                      `×${this.readUnitCountInSelectedCorps(unit.id, this.selectedCorpsRole, this.rosterVersion)}`
                    )
                      .fontSize(13)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#81C784')
                  }
                  .width('100%')

                  Text(`HP ${unit.hp} · 攻 ${unit.attack} · 甲 ${unit.armor} · 速 ${unit.moveSpeed}`)
                    .fontSize(11)
                    .fontColor('#FFD54F')
                  Text(`金${unit.cost.gold}/木${unit.cost.wood}/粮${unit.cost.grain} · 人口${unit.popCap}`)
                    .fontSize(11)
                    .fontColor('#90A4AE')
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .constraintSize({ minHeight: GameConstants.TABLET_PRIMARY_BTN_HEIGHT_VP })
                .padding(10)
                .backgroundColor(this.selectedUnitIndex === idx ? '#3E2E28' : '#232020')
                .borderRadius(8)
                .border({
                  width: 1.5,
                  color: this.selectedUnitIndex === idx ? '#D4A843' : '#373232'
                })
                .onClick(() => {
                  this.selectedUnitIndex = idx;
                })
              }
            }, (unit: UnitStaticStats) => unit.id)
          }
          .columnsTemplate(this.isWideScreen ? '1fr 1fr 1fr' : '1fr 1fr')
          .columnsGap(8)
          .rowsGap(8)
          .layoutWeight(1)
          .width('100%')

          // 底部选中兵种克制详评与大热区增减编配按钮（>= 48vp）
          Column({ space: 8 }) {
            Row({ space: 10 }) {
              Text(`检阅：【${UNIT_STATIC_CONFIGS[this.selectedUnitIndex].name}】`)
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#D4A843')

              Text(
                `破甲 ${Math.round(UNIT_STATIC_CONFIGS[this.selectedUnitIndex].armorPenetration * 100)}% ｜ 正面盾防 ${Math.round(UNIT_STATIC_CONFIGS[this.selectedUnitIndex].shieldRangedBlock * 100)}% ｜ 冲锋 ${UNIT_STATIC_CONFIGS[this.selectedUnitIndex].chargeMultiplier}x ｜ 反骑 ${UNIT_STATIC_CONFIGS[this.selectedUnitIndex].antiCavalryMultiplier}x`
              )
                .fontSize(12)
                .fontColor('#81C784')
                .layoutWeight(1)
            }
            .width('100%')

            Text(UNIT_STATIC_CONFIGS[this.selectedUnitIndex].traitDesc)
              .fontSize(12)
              .fontColor('#ECEFF1')
              .maxLines(2)

            Row({ space: 10 }) {
              Button('-6 缩编')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(14)
                .backgroundColor('#4E342E')
                .fontColor('#FFF8E1')
                .onClick(() => {
                  this.changeUnitCount(UNIT_STATIC_CONFIGS[this.selectedUnitIndex], -6);
                })

              Button('-1 微调')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(14)
                .backgroundColor('#37474F')
                .fontColor('#FFF8E1')
                .onClick(() => {
                  this.changeUnitCount(UNIT_STATIC_CONFIGS[this.selectedUnitIndex], -1);
                })

              Button('+1 增补')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(14)
                .backgroundColor('#2E7D32')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.changeUnitCount(UNIT_STATIC_CONFIGS[this.selectedUnitIndex], 1);
                })

              Button('+6 整队扩编')
                .height(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP)
                .layoutWeight(1)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .backgroundColor('#1B5E20')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.changeUnitCount(UNIT_STATIC_CONFIGS[this.selectedUnitIndex], 6);
                })
            }
            .width('100%')

            Text(this.tipMessage)
              .fontSize(11)
              .fontColor('#FFE082')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .backgroundColor('#221C19')
          .borderRadius(8)
        }
        .width(this.isWideScreen ? '62%' : '100%')
        .height(this.isWideScreen ? '100%' : '54%')
        .margin({ left: this.isWideScreen ? 12 : 0, top: this.isWideScreen ? 0 : 10 })
        .padding(14)
        .backgroundColor('#1A1514')
        .borderRadius(10)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .backgroundColor('#141110')
  }

  private readUnitCountInSelectedCorps(
    unitId: UnitTypeId,
    role: ArmyCorpsRole,
    _ver: number
  ): number {
    return this.session.getSetupUnitCountInCorps(unitId, role);
  }
}
