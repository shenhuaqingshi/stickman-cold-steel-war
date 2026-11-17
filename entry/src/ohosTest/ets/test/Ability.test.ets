import { describe, it, expect } from '@ohos/hypium';
import { GameConstants } from '../../../main/ets/common/GameConstants';
import { CAMPAIGN_MAP_NODES } from '../../../main/ets/config/CampaignMapConfig';
import { FACTION_STATIC_CONFIGS, getFactionConfigById } from '../../../main/ets/config/FactionConfig';
import { UNIT_STATIC_CONFIGS, getUnitConfigById } from '../../../main/ets/config/UnitConfig';

/**
 * 第 1 步 Stage 模型骨架与静态设计表一致性单元测试（Hypium）
 */
export default function abilityTest(): void {
  describe('StageSkeletonAndDesignConfigTest', () => {
    it('assertBattlefieldAndCampaignDimensionsMeetBrief', 0, () => {
      expect(GameConstants.BATTLEFIELD_WIDTH >= 4000).assertTrue();
      expect(GameConstants.BATTLEFIELD_HEIGHT >= 2000).assertTrue();
      expect(GameConstants.CAMPAIGN_REGION_COUNT).assertEqual(8);
      expect(CAMPAIGN_MAP_NODES.length >= 30).assertTrue();
      expect(CAMPAIGN_MAP_NODES.length).assertEqual(GameConstants.CAMPAIGN_NODE_COUNT);
    });

    it('assertEightFactionsHaveUniqueExclusiveUnits', 0, () => {
      expect(FACTION_STATIC_CONFIGS.length).assertEqual(8);
      for (let i: number = 0; i < FACTION_STATIC_CONFIGS.length; i++) {
        const faction = FACTION_STATIC_CONFIGS[i];
        const exclusiveUnit = getUnitConfigById(faction.exclusiveUnitId);
        expect(exclusiveUnit !== undefined).assertTrue();
        if (exclusiveUnit !== undefined) {
          expect(exclusiveUnit.exclusiveFaction).assertEqual(faction.id);
        }
        expect(getFactionConfigById(faction.id) !== undefined).assertTrue();
      }
    });

    it('assertSixteenUnitsHaveValidPositiveStats', 0, () => {
      expect(UNIT_STATIC_CONFIGS.length).assertEqual(16);
      for (let i: number = 0; i < UNIT_STATIC_CONFIGS.length; i++) {
        const unit = UNIT_STATIC_CONFIGS[i];
        expect(unit.hp > 0).assertTrue();
        expect(unit.attack > 0).assertTrue();
        expect(unit.attackIntervalSec > 0).assertTrue();
        expect(unit.moveSpeed > 0).assertTrue();
        expect(unit.popCap >= 1).assertTrue();
      }
    });

    it('assertCampaignGraphUndirectedSymmetry', 0, () => {
      for (let i: number = 0; i < CAMPAIGN_MAP_NODES.length; i++) {
        const nodeA = CAMPAIGN_MAP_NODES[i];
        for (let j: number = 0; j < nodeA.neighbors.length; j++) {
          const neighborId: string = nodeA.neighbors[j];
          let foundSymmetric: boolean = false;
          for (let k: number = 0; k < CAMPAIGN_MAP_NODES.length; k++) {
            const nodeB = CAMPAIGN_MAP_NODES[k];
            if (nodeB.id === neighborId) {
              foundSymmetric = nodeB.neighbors.indexOf(nodeA.id) >= 0;
              break;
            }
          }
          expect(foundSymmetric).assertTrue();
        }
      }
    });
  });
}
