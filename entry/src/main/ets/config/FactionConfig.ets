import {
  AiPersonality,
  FactionId,
  FactionStaticConfig,
  TerrainType,
  UnitTypeId
} from '../model/GameTypes';

/**
 * 八大势力静态配置表（第 1 步：纯静态元数据配置，严格对应 DESIGN.md）
 */
export const FACTION_STATIC_CONFIGS: readonly FactionStaticConfig[] = [
  {
    id: FactionId.YANLONG,
    name: '炎龙帝国',
    bannerTitle: '赤底蟠龙金纹旗',
    primaryColor: '#C62828',
    accentColor: '#FFD54F',
    specialtyTag: '重甲步兵 · 攻城器械',
    exclusiveUnitId: UnitTypeId.YANLONG_HALBERD_GRENADIER,
    aiPersonality: AiPersonality.IMPERIAL_METHODICAL,
    capitalNodeId: 'yl_capital',
    homeTerrain: TerrainType.PLAIN,
    bonusSummary: '步兵护甲 +15%；攻城器械造价 -20% 且对城防伤害 +25%；本阵城池耐久 +20%',
    weaknessSummary: '骑兵招募花费 +15%；重装编队大地图与野战基础移速 -5%',
    startingCredibility: 88,
    uniqueTechs: [
      {
        id: 'yl_tech_armor',
        name: '玄铁札甲',
        effectSummary: '全步兵护甲额外 +8，对箭矢穿透抗性提升',
        cost: { gold: 260, wood: 120, grain: 80 }
      },
      {
        id: 'yl_tech_thunder',
        name: '神机火雷',
        effectSummary: '神机重卫火雷装填增至 2 枚，投石车解锁火油弹引燃效果',
        cost: { gold: 340, wood: 180, grain: 100 }
      },
      {
        id: 'yl_tech_discipline',
        name: '督战军法',
        effectSummary: '方阵与圆阵下部队士气动摇阈值下降 8 点，稳固防线',
        cost: { gold: 220, wood: 80, grain: 140 }
      }
    ]
  },
  {
    id: FactionId.CANGLANG,
    name: '苍狼汗国',
    bannerTitle: '苍青奔狼白纛旗',
    primaryColor: '#0277BD',
    accentColor: '#E1F5FE',
    specialtyTag: '轻骑游击 · 侧翼包抄',
    exclusiveUnitId: UnitTypeId.CANGLANG_KESHIG_HORSE_ARCHER,
    aiPersonality: AiPersonality.NOMAD_OPPORTUNIST,
    capitalNodeId: 'cl_capital',
    homeTerrain: TerrainType.PLAIN,
    bonusSummary: '全骑兵移速 +12%；远征补给跳数惩罚降低 35%；劫掠敌方农田/粮车获得双倍粮草',
    weaknessSummary: '无法建造重型配重投石车（攻城限用连弩车与云梯火矢）；步兵基础抗线士气 -5',
    startingCredibility: 72,
    uniqueTechs: [
      {
        id: 'cl_tech_remount',
        name: '双马换乘',
        effectSummary: '大地图行军力 +25%，战场骑兵冲锋冷却缩短 20%',
        cost: { gold: 240, wood: 90, grain: 160 }
      },
      {
        id: 'cl_tech_whistle',
        name: '鸣镝齐射',
        effectSummary: '怯薛骑射与复合弓手集火同一目标时附加破甲标记 +15%',
        cost: { gold: 280, wood: 150, grain: 100 }
      },
      {
        id: 'cl_tech_forage',
        name: '草原劫掠',
        effectSummary: '每击溃一队敌军当场回收 25 粮草与 15 金币以战养战',
        cost: { gold: 200, wood: 60, grain: 120 }
      }
    ]
  },
  {
    id: FactionId.TIEYING,
    name: '铁鹰王国',
    bannerTitle: '靛蓝铁翼双头鹰旗',
    primaryColor: '#283593',
    accentColor: '#B0BEC5',
    specialtyTag: '强弩齐射 · 防守反击',
    exclusiveUnitId: UnitTypeId.TIEYING_PAVISE_CROSSBOW,
    aiPersonality: AiPersonality.FORTRESS_COUNTER,
    capitalNodeId: 'ty_capital',
    homeTerrain: TerrainType.HIGH_GROUND,
    bonusSummary: '全远程射程 +12%；据守高地或城墙伤害额外 +15%；工兵修筑拒马与箭塔速度 +40%',
    weaknessSummary: '冲锋突击类近战兵种招募金币 +10%；离开工事野战机动偏慢',
    startingCredibility: 86,
    uniqueTechs: [
      {
        id: 'ty_tech_arbalest',
        name: '踏张钢弩',
        effectSummary: '神弩手与连弩车装填间隔缩短 15%，射程额外 +30px',
        cost: { gold: 300, wood: 200, grain: 80 }
      },
      {
        id: 'ty_tech_pavise',
        name: '背盾轮射',
        effectSummary: '远程编队处于雁行阵或坚守态时，正面近战格挡提升 20%',
        cost: { gold: 240, wood: 160, grain: 90 }
      },
      {
        id: 'ty_tech_bastion',
        name: '棱堡工事',
        effectSummary: '拒马对冲锋骑兵反伤翻倍，关隘/城池守城箭塔射速 +25%',
        cost: { gold: 260, wood: 220, grain: 70 }
      }
    ]
  },
  {
    id: FactionId.SHAMO,
    name: '沙漠商盟',
    bannerTitle: '鎏金天平弯月旗',
    primaryColor: '#F9A825',
    accentColor: '#FFF8E1',
    specialtyTag: '富甲天下 · 雇佣混编',
    exclusiveUnitId: UnitTypeId.SHAMO_MAMELUKE_CAMEL,
    aiPersonality: AiPersonality.MERCHANT_PRAGMATIC,
    capitalNodeId: 'sm_capital',
    homeTerrain: TerrainType.DESERT_DUNE,
    bonusSummary: '金矿采集与通商收入 +35%；可耗纯金币即时征召外邦雇佣团（免训练耗时）；沙漠地形无减速与耗粮惩罚',
    weaknessSummary: '本土常规步兵初始士气 -6；若国库或战场金币跌至 0 则雇佣军士气每秒衰减',
    startingCredibility: 78,
    uniqueTechs: [
      {
        id: 'sm_tech_caravan',
        name: '丝路商队',
        effectSummary: '每签署一份通商协定额外产出 +45 金币/回合，外交送礼好感效率 +25%',
        cost: { gold: 280, wood: 100, grain: 80 }
      },
      {
        id: 'sm_tech_mercenary',
        name: '黄金契约',
        effectSummary: '雇佣兵征召费用降低 20%，并解锁邻近盟友专属精锐的限量雇佣权',
        cost: { gold: 380, wood: 60, grain: 100 }
      },
      {
        id: 'sm_tech_camel',
        name: '骆驼惊骑阵',
        effectSummary: '马穆鲁克卫队惊马光环半径扩大至 220px，并免疫沙暴视野损失',
        cost: { gold: 260, wood: 90, grain: 120 }
      }
    ]
  },
  {
    id: FactionId.SHUANGYUAN,
    name: '霜原熊族',
    bannerTitle: '冰晶咆哮白熊图腾旗',
    primaryColor: '#29B6F6',
    accentColor: '#E0F7FA',
    specialtyTag: '重斧巨人 · 正面硬刚',
    exclusiveUnitId: UnitTypeId.SHUANGYUAN_GIANT_BREAKER,
    aiPersonality: AiPersonality.HONOR_BERSERK_BEAR,
    capitalNodeId: 'sy_capital',
    homeTerrain: TerrainType.SNOWFIELD,
    bonusSummary: '全军生命上限 +15%；极寒雪原与暴风雪免疫减速/冻耗且近战伤害 +10%',
    weaknessSummary: '远程弓弩射程 -10%；族人食量庞大导致全军日常耗粮 +15%',
    startingCredibility: 84,
    uniqueTechs: [
      {
        id: 'sy_tech_frostaxe',
        name: '寒铁重斧',
        effectSummary: '巨斧兵与巨熊破阵者横扫范围 +25%，命中附带短暂破盾僵直',
        cost: { gold: 270, wood: 140, grain: 150 }
      },
      {
        id: 'sy_tech_totem',
        name: '熊灵战意',
        effectSummary: '主帅亲自近战搏杀时，全图友军近战攻击力提升 10%',
        cost: { gold: 230, wood: 100, grain: 160 }
      },
      {
        id: 'sy_tech_winterhunt',
        name: '雪原冬猎',
        effectSummary: '抵消全军 15% 额外耗粮惩罚，雪原行军速度反增 +15%',
        cost: { gold: 190, wood: 120, grain: 140 }
      }
    ]
  },
  {
    id: FactionId.WULIN,
    name: '雾林猎手',
    bannerTitle: '翡翠银叶鹿角旗',
    primaryColor: '#2E7D32',
    accentColor: '#C8E6C9',
    specialtyTag: '神射狙击 · 丛林陷阱',
    exclusiveUnitId: UnitTypeId.WULIN_SHADOW_SNIPER,
    aiPersonality: AiPersonality.GUERRILLA_TRAPPER,
    capitalNodeId: 'wl_capital',
    homeTerrain: TerrainType.DENSE_FOREST,
    bonusSummary: '密林地形移速反增 +20% 且透视林间迷雾；战前与战中可布置尖刺陷坑与绊马索',
    weaknessSummary: '缺乏超重甲抗线单位（全军护甲上限受限）；开阔无遮挡平原正面对决吃亏',
    startingCredibility: 76,
    uniqueTechs: [
      {
        id: 'wl_tech_venom',
        name: '见血封喉',
        effectSummary: '影袭神射与复合弓手箭矢附带持续 4 秒流血毒伤，克制高血量巨人与战马',
        cost: { gold: 260, wood: 170, grain: 90 }
      },
      {
        id: 'wl_tech_pitfall',
        name: '诡道陷坑',
        effectSummary: '战场可部署陷阱上限 +4，绊马索必定令冲锋骑兵坠马眩晕 3 秒',
        cost: { gold: 210, wood: 190, grain: 80 }
      },
      {
        id: 'wl_tech_mist',
        name: '迷雾潜行',
        effectSummary: '浓雾与黑夜下全军远程射程不衰减，脱战潜行进入时间缩短至 2.5 秒',
        cost: { gold: 250, wood: 140, grain: 100 }
      }
    ]
  },
  {
    id: FactionId.XUANJIA,
    name: '玄甲重骑军团',
    bannerTitle: '暗紫玄铁狮鹫枪旗',
    primaryColor: '#7B1FA2',
    accentColor: '#E1BEE7',
    specialtyTag: '具装铁骑 · 破阵冲锋',
    exclusiveUnitId: UnitTypeId.XUANJIA_CATAPHRACT,
    aiPersonality: AiPersonality.IRON_SHOCK_ELITE,
    capitalNodeId: 'xj_capital',
    homeTerrain: TerrainType.PLAIN,
    bonusSummary: '骑兵护甲 +25%、冲锋撞击倍率 +30%；每次冲锋击溃敌队重置 50% 冲锋冷却并回升士气 +12',
    weaknessSummary: '精锐骑兵造价与粮耗高昂、兵员数量少；泥泞河流与断粮状态下战马移速暴跌 35%',
    startingCredibility: 82,
    uniqueTechs: [
      {
        id: 'xj_tech_barding',
        name: '人马具装',
        effectSummary: '铁浮图与游骑兵远程箭矢减伤额外 +20%，免疫轻步兵阻滞',
        cost: { gold: 350, wood: 100, grain: 140 }
      },
      {
        id: 'xj_tech_wedge',
        name: '楔形连环马',
        effectSummary: '锥形阵下骑兵正面抗长枪反制伤害减免 30%，凿穿深度增加',
        cost: { gold: 320, wood: 120, grain: 150 }
      },
      {
        id: 'xj_tech_trample',
        name: '铁蹄破阵',
        effectSummary: '冲锋撞击波及路径两侧敌军造成额外士气震慑 -10',
        cost: { gold: 280, wood: 90, grain: 130 }
      }
    ]
  },
  {
    id: FactionId.XUEYUE,
    name: '血月祭司团',
    bannerTitle: '绯紫血月骨鼓旗',
    primaryColor: '#AD1457',
    accentColor: '#F8BBD0',
    specialtyTag: '战鼓祭祀 · 嗜血狂战',
    exclusiveUnitId: UnitTypeId.XUEYUE_WARDRUM_BERSERKER,
    aiPersonality: AiPersonality.ZEALOT_SWARM,
    capitalNodeId: 'xy_capital',
    homeTerrain: TerrainType.DENSE_FOREST,
    bonusSummary: '敌我伤亡充能【血月狂热】赋予全军移速+20%与免溃；夜战全军视野无损且攻击力 +15%',
    weaknessSummary: '主力护甲极薄且缺盾，畏惧强弩火器密集交叉火力；正统诸侯初始外交好感 -15',
    startingCredibility: 65,
    uniqueTechs: [
      {
        id: 'xy_tech_wardrum',
        name: '血祭战鼓',
        effectSummary: '狂热池充能效率 +35%，激活期间近战攻击附带 15% 生命汲取',
        cost: { gold: 240, wood: 110, grain: 130 }
      },
      {
        id: 'xy_tech_eternalnight',
        name: '永夜狂热',
        effectSummary: '大地图发起夜袭成功率 +40%，夜战敌军视野额外缩减 15%',
        cost: { gold: 260, wood: 100, grain: 120 }
      },
      {
        id: 'xy_tech_dread',
        name: '骸骨威慑',
        effectSummary: '狂战士接敌近身时令周围 100px 敌军每秒士气流失 1.2 点',
        cost: { gold: 220, wood: 90, grain: 110 }
      }
    ]
  }
];

/**
 * 按势力 ID 检索静态配置
 */
export function getFactionConfigById(factionId: FactionId): FactionStaticConfig | undefined {
  for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
    if (FACTION_STATIC_CONFIGS[i].id === factionId) {
      return FACTION_STATIC_CONFIGS[i];
    }
  }
  return undefined;
}
