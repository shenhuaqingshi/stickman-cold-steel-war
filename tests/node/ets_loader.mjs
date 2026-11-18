import { registerHooks } from 'node:module';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * Node 24 原生 ArkTS (.ets) 加载钩子：
 * 1. 自动补齐相对路径 .ets 后缀；
 * 2. 兼容 ArkTS 不区分 import type 与值导入的语法（为 export interface/type 注入同名运行时占位符）；
 * 用法：cd /home/hatch/workspace/stickman-war && node --experimental-transform-types --import ./tests/node/ets_loader.mjs tests/node/test_xxx.mjs
 */
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (
      specifier.startsWith('.') &&
      !specifier.endsWith('.ets') &&
      !specifier.endsWith('.mjs') &&
      !specifier.endsWith('.js')
    ) {
      return nextResolve(`${specifier}.ets`, context);
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.endsWith('.ets')) {
      let src = fs.readFileSync(fileURLToPath(url), 'utf8');
      const exportedTypes = [];
      for (const m of src.matchAll(/export\s+(?:interface|type)\s+([A-Za-z0-9_]+)/g)) {
        exportedTypes.push(m[1]);
      }
      if (exportedTypes.length > 0) {
        const stubs = exportedTypes.map((name) => `export const ${name} = undefined;`).join('\n');
        src = `${src}\n// Node ESM type-import compatibility stubs\n${stubs}\n`;
      }
      return {
        format: 'module-typescript',
        shortCircuit: true,
        source: src
      };
    }
    return nextLoad(url, context);
  }
});
