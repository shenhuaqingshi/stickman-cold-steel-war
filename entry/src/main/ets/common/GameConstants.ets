/**
 * 全局游戏常量定义（第 1 步：骨架与静态常量层，不含战斗逻辑）
 * 与 DESIGN.md 数值体系保持严格一致
 */
export class GameConstants {
  // ==================== 战场大地图尺寸（硬性要求 >= 4000x2000） ====================
  /** 标准野战/遭遇战逻辑宽度（px） */
  public static readonly BATTLEFIELD_WIDTH: number = 4800;
  /** 标准野战/遭遇战逻辑高度（px） */
  public static readonly BATTLEFIELD_HEIGHT: number = 2400;
  /** 大型攻城战逻辑宽度（px） */
  public static readonly SIEGE_BATTLEFIELD_WIDTH: number = 5600;
  /** 大型攻城战逻辑高度（px） */
  public static readonly SIEGE_BATTLEFIELD_HEIGHT: number = 2600;
  /** 空间均匀网格哈希单格尺寸（px），4800x2400 划分为 40x20=800 桶 */
  public static readonly SPATIAL_GRID_CELL_SIZE: number = 120;
  /** 视口裁剪安全外扩边距（px），防止长枪/投石轨迹边缘闪烁 */
  public static readonly VIEWPORT_CULL_MARGIN: number = 96;
  /** 战场常规步兵基础视野半径（px，战争迷雾索敌） */
  public static readonly VISION_RADIUS_INFANTRY: number = 420;
  /** 战场侦察骑兵基础视野半径（px） */
  public static readonly VISION_RADIUS_CAVALRY: number = 580;
  /** 长枪架枪迎击冲锋骑兵时的动能附加破甲率 */
  public static readonly BRACED_ANTICAV_BONUS_PEN: number = 0.30;

  // ==================== 战役战略大地图尺寸（硬性要求 8 区域、30+ 节点） ====================
  /** 战役战略地图逻辑宽度（px） */
  public static readonly CAMPAIGN_MAP_WIDTH: number = 3600;
  /** 战役战略地图逻辑高度（px） */
  public static readonly CAMPAIGN_MAP_HEIGHT: number = 2400;
  /** 战役大地图地理大区数量 */
  public static readonly CAMPAIGN_REGION_COUNT: number = 8;
  /** 战役大地图城池/关隘/要塞总节点数（每大区均衡 5 座城关，共 40 座） */
  public static readonly CAMPAIGN_NODE_COUNT: number = 40;
  /** 战役地图最小缩放倍率 */
  public static readonly CAMPAIGN_ZOOM_MIN: number = 0.45;
  /** 战役地图最大缩放倍率 */
  public static readonly CAMPAIGN_ZOOM_MAX: number = 1.80;

  // ==================== 鸿蒙平板（MatePad）大屏触控与视口交互常量 ====================
  /** 平板手指触控按钮最小高度（vp，禁止使用手机端局促小按钮） */
  public static readonly TABLET_MIN_TOUCH_HEIGHT_VP: number = 48;
  /** 平板主操作按钮标准高度（vp） */
  public static readonly TABLET_PRIMARY_BTN_HEIGHT_VP: number = 54;
  /** 平板战场视口最小鸟瞰缩放倍率（大屏一次纵览多条战线） */
  public static readonly BATTLE_ZOOM_MIN: number = 0.45;
  /** 平板战场视口最大特写缩放倍率（近看火柴人刀剑格挡与英雄拼杀） */
  public static readonly BATTLE_ZOOM_MAX: number = 1.65;
  /** 手写笔（M-Pencil）点选士兵/编队精准拾取容差半径（px） */
  public static readonly STYLUS_PICK_RADIUS_PX: number = 24;
  /** 手指触控点选编队放大拾取热区半径（px） */
  public static readonly FINGER_PICK_RADIUS_PX: number = 44;

  // ==================== 帧率与对象池容量预算 ====================
  /** 逻辑模拟步进频率（Hz） */
  public static readonly LOGIC_TICK_HZ: number = 30;
  /** 渲染目标帧率（FPS） */
  public static readonly RENDER_TARGET_FPS: number = 60;
  /** 单场战斗同屏士兵对象池上限 */
  public static readonly MAX_UNIT_POOL_SIZE: number = 600;
  /** 单场战斗投射物对象池上限 */
  public static readonly MAX_PROJECTILE_POOL_SIZE: number = 400;
  /** 战场最大保留倒地遗骸/折断旌旗数量（环形覆盖，兼顾古战场惨烈实感与渲染性能） */
  public static readonly MAX_FALLEN_CORPSE_DECAL: number = 150;
  /** 单场方阵人口标准上限（单方） */
  public static readonly DEFAULT_ARMY_POP_CAP: number = 240;
  /** 单方最大独立可调度军团编组数（前锋/左翼/右翼/预备队/远程群/护粮队） */
  public static readonly MAX_ARMY_CORPS_GROUPS: number = 6;
  /** 主帅重击命中顿帧时长（ms，强化冷兵器劈砍卡肉打击实感） */
  public static readonly HERO_HIT_STOP_MS: number = 40;

  // ==================== 战场开局标准资源（经行军接敌耗时数学标定） ====================
  /** 战场标准初始金币 */
  public static readonly BATTLE_INIT_GOLD: number = 500;
  /** 战场标准初始木材 */
  public static readonly BATTLE_INIT_WOOD: number = 350;
  /** 战场标准初始携行粮草（支撑百人军团约 3.5~4.5 分钟高强度作战，防接敌前提前饿死） */
  public static readonly BATTLE_INIT_GRAIN: number = 1200;

  // ==================== 侧背包抄、钳形夹击、合围与半渡而击战术常数 ====================
  /** 侧翼受击伤害倍率（60°~135°） */
  public static readonly FLANK_DAMAGE_MULTIPLIER: number = 1.25;
  /** 背击突袭伤害倍率（>135°，且无视正面盾防与架枪） */
  public static readonly REAR_DAMAGE_MULTIPLIER: number = 1.45;
  /** 钳形夹击（>=2个互成>=120°非正面方向同时受敌）每秒额外士气流失 */
  public static readonly PINCER_MORALE_DRAIN_PER_SEC: number = 2.2;
  /** 铁桶合围判定所需受敌扇区数（8象限中至少5个扇区有敌且退路受阻） */
  public static readonly ENCIRCLEMENT_MIN_OCTANTS: number = 5;
  /** 铁桶合围状态下每秒士气雪崩流失值 */
  public static readonly ENCIRCLEMENT_MORALE_DRAIN_PER_SEC: number = 4.8;
  /** 渡河“半渡而击”（分队 30%~80% 成员涉水首尾脱节时受击）额外易伤倍率 */
  public static readonly HALF_FORD_VULNERABILITY_MULT: number = 1.20;

  // ==================== 士气与主帅边界阈值 ====================
  /** 初始标准士气 */
  public static readonly MORALE_BASE: number = 80;
  /** 士气满分上限 */
  public static readonly MORALE_MAX: number = 100;
  /** 动摇阈值（低于此值攻防下降） */
  public static readonly MORALE_WAVERING_THRESHOLD: number = 40;
  /** 溃逃阈值（低于此值脱离控制溃退） */
  public static readonly MORALE_ROUT_THRESHOLD: number = 20;
  /** 重整旗鼓恢复控制阈值（需回升至此值才解除溃逃，形成迟滞环防抖） */
  public static readonly MORALE_RALLY_THRESHOLD: number = 32;
  /** 主帅首次重伤落马造成的全军士气骤降值 */
  public static readonly HERO_FIRST_DOWN_MORALE_SHOCK: number = 35;
  /** 主帅重伤期间全军士气临时封顶值 */
  public static readonly HERO_DOWN_MORALE_CAP: number = 65;

  // ==================== 后勤补给与断粮阈值 ====================
  /** 补给线无损最大连通跳数 */
  public static readonly SUPPLY_FULL_HOPS: number = 2;
  /** 战场余粮红色告警秒数 */
  public static readonly RATION_WARNING_SECONDS: number = 15;
  /** 战场断粮由“饥饿”升级为“饥溃”的持续秒数 */
  public static readonly STARVATION_SEVERE_SECONDS: number = 30;

  // ==================== 外交关系与信誉边界 ====================
  /** 外交关系最小值（死敌/世仇） */
  public static readonly DIPLOMACY_REL_MIN: number = -100;
  /** 外交关系最大值（铁杆同盟） */
  public static readonly DIPLOMACY_REL_MAX: number = 100;
  /** 初始外交信誉值 */
  public static readonly CREDIBILITY_INIT: number = 80;
  /** 缔结同盟所需最低关系值 */
  public static readonly ALLIANCE_MIN_RELATION: number = 55;
  /** 缔结同盟所需最低信誉值 */
  public static readonly ALLIANCE_MIN_CREDIBILITY: number = 50;
  /** 背盟造成的信誉暴跌惩罚 */
  public static readonly BETRAYAL_CREDIBILITY_PENALTY: number = 45;
  /** 背盟造成的全图第三方关系惩罚 */
  public static readonly BETRAYAL_GLOBAL_RELATION_PENALTY: number = 25;
}
