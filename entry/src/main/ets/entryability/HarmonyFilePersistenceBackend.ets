/**
 * HarmonyOS NEXT 应用沙箱离线文件持久化适配器（HarmonyFilePersistenceBackend.ets）
 * 基于 @kit.CoreFileKit (fileIo) 将自动存档、5 个手动存档槽与平板设置离线存储于应用沙箱 filesDir，
 * 同时内置内存后备容错，在 DevEco Previewer 或只读沙箱环境下自动平滑降级不崩溃。
 */
import { fileIo } from '@kit.CoreFileKit';
import { PersistenceBackendAdapter } from '../storage/SaveManager';

export class HarmonyFilePersistenceBackend implements PersistenceBackendAdapter {
  private readonly baseDir: string;
  private readonly fallbackMemory: Map<string, string>;

  public constructor(filesDir: string) {
    this.baseDir = filesDir !== undefined ? filesDir : '';
    this.fallbackMemory = new Map<string, string>();
  }

  private resolveSafePath(key: string): string {
    const sanitizedKey: string = key.replace(/[^a-zA-Z0-9_\-]/g, '_');
    return `${this.baseDir}/${sanitizedKey}.json`;
  }

  public readText(key: string): string | null {
    if (this.baseDir.length > 0) {
      const targetPath: string = this.resolveSafePath(key);
      try {
        if (fileIo.accessSync(targetPath)) {
          const content: string = fileIo.readTextSync(targetPath);
          this.fallbackMemory.set(key, content);
          return content;
        }
      } catch (e) {
        // 读取沙箱异常时回退至内存缓存
      }
    }
    const mem: string | undefined = this.fallbackMemory.get(key);
    return mem !== undefined ? mem : null;
  }

  public writeText(key: string, content: string): void {
    this.fallbackMemory.set(key, content);
    if (this.baseDir.length <= 0) {
      return;
    }
    const targetPath: string = this.resolveSafePath(key);
    try {
      const file: fileIo.File = fileIo.openSync(
        targetPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      try {
        fileIo.writeSync(file.fd, content);
      } finally {
        fileIo.closeSync(file);
      }
    } catch (e) {
      // 忽略 Previewer 沙箱不可写异常，已保留内存缓存
    }
  }

  public deleteKey(key: string): void {
    this.fallbackMemory.delete(key);
    if (this.baseDir.length <= 0) {
      return;
    }
    const targetPath: string = this.resolveSafePath(key);
    try {
      if (fileIo.accessSync(targetPath)) {
        fileIo.unlinkSync(targetPath);
      }
    } catch (e) {
      // 忽略文件已不存在异常
    }
  }
}
