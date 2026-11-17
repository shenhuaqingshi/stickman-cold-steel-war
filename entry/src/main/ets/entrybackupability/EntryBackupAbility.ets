import { BackupExtensionAbility, BundleVersion } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'StickmanBackupAbility';

/**
 * 本地备份恢复扩展 Ability（HarmonyOS NEXT Stage 模型标准组件）
 * 负责单机存档、战役进度与本地战绩统计的数据备份与迁移恢复
 */
export default class EntryBackupAbility extends BackupExtensionAbility {
  async onBackup(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'EntryBackupAbility onBackup invoked');
    await Promise.resolve();
  }

  async onRestore(bundleVersion: BundleVersion): Promise<void> {
    hilog.info(
      DOMAIN,
      TAG,
      'EntryBackupAbility onRestore invoked, version=%{public}d.%s',
      bundleVersion.code,
      bundleVersion.name
    );
    await Promise.resolve();
  }
}
