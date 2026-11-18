import { describe, it, expect } from '@ohos/hypium';
import { GameConstants } from '../../../main/ets/common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../../../main/ets/config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../../../main/ets/config/FactionConfig';
import { UNIT_STATIC_CONFIGS, getUnitConfigById } from '../../../main/ets/config/UnitConfig';
import { CampaignNodeConfig, UnitTypeId } from '../../../main/ets/model/GameTypes';

/**
 * 第 1 步 Stage 模型骨架、平板触控常量与静态设计表一致性单元测试（Hypium）
 */
export default function abilityTest(): void {
  describe('StageSkeletonAndDesignConfigTest', () => {
    it('assertBattlefieldCampaignAndTabletSpecsMeetBrief', 0, () => {
      expect(GameConstants.BATTLEFIELD_WIDTH >= 4000).assertTrue();
      expect(GameConstants.BATTLEFIELD_HEIGHT >= 2000).assertTrue();
      expect(GameConstants.CAMPAIGN_REGION_COUNT).assertEqual(8);
      expect(CAMPAIGN_MAP_NODES.length >= 30).assertTrue();
      expect(CAMPAIGN_MAP_NODES.length).assertEqual(GameConstants.CAMPAIGN_NODE_COUNT);
      expect(GameConstants.TABLET_MIN_TOUCH_HEIGHT_VP >= 48).assertTrue();
      expect(GameConstants.MAX_ARMY_CORPS_GROUPS >= 4).assertTrue();
    });

    it('assertEightFactionsHaveUniqueUnitsAndEqualStartingNodes', 0, () => {
      expect(FACTION_STATIC_CONFIGS.length).assertEqual(8);
      for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
        const faction = FACTION_STATIC_CONFIGS[i];
        const exclusiveUnit = getUnitConfigById(faction.exclusiveUnitId);
        expect(exclusiveUnit !== undefined).assertTrue();
        if (exclusiveUnit !== undefined) {
          expect(exclusiveUnit.exclusiveFaction).assertEqual(faction.id);
        }
        expect(getFactionConfigById(faction.id) !== undefined).assertTrue();

        // 验证每个势力开局公平拥有 5 座城关且王都具备补给仓城属性
        let ownedCount: number = 0;
        let capitalIsDepot: boolean = false;
        for (let j: number = 0; j < CAMPAIGN_MAP_NODES.length; j++) {
          const node: CampaignNodeConfig = CAMPAIGN_MAP_NODES[j];
          if (node.initialOwner === faction.id) {
            ownedCount++;
          }
          if (node.id === faction.capitalNodeId && node.initialOwner === faction.id && node.isSupplyDepot) {
            capitalIsDepot = true;
          }
        }
        expect(ownedCount).assertEqual(5);
        expect(capitalIsDepot).assertTrue();
      }
    });

    it('assertSixteenUnitsAndBattleRationPacingValid', 0, () => {
      expect(UNIT_STATIC_CONFIGS.length).assertEqual(16);
      for (let i: number = 0; i < UNIT_STATIC_CONFIGS.length; i++) {
        const unit = UNIT_STATIC_CONFIGS[i];
        expect(unit.hp > 0).assertTrue();
        expect(unit.attack > 0).assertTrue();
        expect(unit.attackIntervalSec > 0).assertTrue();
        expect(unit.moveSpeed > 0).assertTrue();
        expect(unit.popCap >= 1).assertTrue();
      }

      // 验证百人刀盾军团开局携行粮草至少支撑 100 秒以上，绝不会在 31 秒接敌行军途中提前断粮
      const shieldInfantry = getUnitConfigById(UnitTypeId.SHIELD_SWORDSMAN);
      expect(shieldInfantry !== undefined).assertTrue();
      if (shieldInfantry !== undefined) {
        const hundredUnitsUpkeepPerSec: number = shieldInfantry.grainUpkeepPerSec * 100;
        const sustainSeconds: number = GameConstants.BATTLE_INIT_GRAIN / hundredUnitsUpkeepPerSec;
        expect(sustainSeconds >= 100).assertTrue();
      }
    });

    it('assertCampaignGraphSymmetricAndFullyConnected', 0, () => {
      let directedEdgeCount: number = 0;
      for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
        const nodeA: CampaignNodeConfig = CAMPAIGN_MAP_NODES[i];
        directedEdgeCount += nodeA.neighbors.length;
        for (let j: number = 0; j < nodeA.neighbors.length; j++) {
          const neighborId: string = nodeA.neighbors[j];
          let foundSymmetric: boolean = false;
          for (let k: number = 0; k < CAMPAIGN_MAP_NODES.length; k++) {
            const nodeB: CampaignNodeConfig = CAMPAIGN_MAP_NODES[k];
            if (nodeB.id === neighborId) {
              foundSymmetric = nodeB.neighbors.indexOf(nodeA.id) >= 0;
              break;
            }
          }
          expect(foundSymmetric).assertTrue();
        }
      }
      expect(directedEdgeCount).assertEqual(GameConstants.CAMPAIGN_ROAD_COUNT * 2);

      // BFS 验证全图 40 节点处于同一连通分量，无孤立死岛
      const visitedIds: string[] = [CAMPAIGN_MAP_NODES[0].id];
      let queueHead: number = 0;
      while (queueHead < visitedIds.length) {
        const currentId: string = visitedIds[queueHead];
        queueHead++;
        for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
          if (CAMPAIGN_MAP_NODES[i].id === currentId) {
            const nbrs: readonly string[] = CAMPAIGN_MAP_NODES[i].neighbors;
            for (let m: number = 0; m < nbrs.length; m++) {
              if (visitedIds.indexOf(nbrs[m]) < 0) {
                visitedIds.push(nbrs[m]);
              }
            }
            break;
          }
        }
      }
      expect(visitedIds.length).assertEqual(CAMPAIGN_MAP_NODES.length);
    });
  });
}
