#!/usr/bin/env node
/**
 * selftest-validate-defects.mjs —— 轮次目录名取法的**单元自测**（关联 REQ-007）。
 *
 * 缺陷：原先 `validate-defects.mjs` 用 `cycleDir.split('/').filter(Boolean).pop()`
 * 取轮次目录名 —— 这是 **POSIX-only** 的切法。Windows 上 `cycleDir` 是
 * `C:\Users\...\cycles\R3-VERIFY`（反斜杠），`split('/')` 切不开 ⇒ `pop()` 取到
 * **整条路径** ⇒ 永远 ≠ `cycle_id` ⇒ 轮次契约校验必然抛 InputError ⇒
 * defect-verify 在 Windows 上一跑就挂。Linux 上恰好正确，所以此前验收没暴露它。
 *
 * 本脚本把「取轮次目录名」这一步单独钉死，并带**负控**（证明校验没被改松）：
 *
 *   P1  POSIX 绝对路径   /home/u/proj/test-assets/cycles/R3-VERIFY        ⇒ R3-VERIFY
 *   P2  Windows 绝对路径 C:\Users\cxp\proj\test-assets\cycles\R3-VERIFY    ⇒ R3-VERIFY
 *   P3  Windows 相对路径 test-assets\cycles\R3-VERIFY                     ⇒ R3-VERIFY
 *   P4  POSIX 相对路径   test-assets/cycles/R3-VERIFY                      ⇒ R3-VERIFY
 *   P5  单段路径         R3-VERIFY                                        ⇒ R3-VERIFY
 *   N1  负控：目录名 ≠ cycle_id ⇒ validateCycleDocument **仍须抛错**（不许放宽校验）
 *
 * ⚠️ 期望值是**平台无关**的：取名实现固定按 win32 规则解析（`/` 与 `\` 都当分隔符），
 *    所以这 5 组输入在 Linux / Windows / macOS 上跑出来都是同样的值 ——
 *    本脚本在 Linux 上真跑通过即可证明「Windows 上不会把整条路径当目录名」。
 *
 * 用法: node scripts/selftest-validate-defects.mjs
 * 退出码: 0 = 全部通过 / 1 = 有断言不通过
 *
 * 纯 Node.js：只用 node: 内置模块，零第三方依赖，不联网，不写任何文件。
 */

import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { cycleDirName, validateCycleDocument } from './lib/validate-defects.mjs';
import { InputError } from './lib/io.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));

let passed = 0;
let failed = 0;

/**
 * 断言并记账。
 * @param {string} name 用例名
 * @param {boolean} ok 是否通过
 * @param {string} detail 说明
 */
function check(name, ok, detail) {
  if (ok) {
    passed += 1;
    console.log(`  [ok] ${name}`);
  } else {
    failed += 1;
    console.log(`  [FAIL] ${name} —— ${detail}`);
  }
}

/**
 * 造一个合法的 R3 轮次配置（只关心 cycle_id 字段）。
 * @param {string} cycleId cycle.json 里的 cycle_id
 * @returns {object}
 */
function mkCycle(cycleId) {
  return {
    cycle_id: cycleId,
    round: 'R3',
    round_type: 'defect-verify',
    requirement: 'REQ-007',
    scopes: ['functional'],
    scopes_skipped: [],
    status: 'in_progress',
    stages: { clarify: { status: 'done' }, design: { status: 'in_progress' } },
    history: [],
    trigger: { type: 'defect', ref: 'BUG-001' },
  };
}

/** 各平台风格的轮次目录 ⇒ 期望取到的目录名（平台无关）。 */
const PATH_CASES = [
  ['P1 POSIX 绝对路径', '/home/u/proj/test-assets/cycles/R3-VERIFY', 'R3-VERIFY'],
  ['P2 Windows 绝对路径', 'C:\\Users\\cxp\\proj\\test-assets\\cycles\\R3-VERIFY', 'R3-VERIFY'],
  ['P3 Windows 相对路径', 'test-assets\\cycles\\R3-VERIFY', 'R3-VERIFY'],
  ['P4 POSIX 相对路径', 'test-assets/cycles/R3-VERIFY', 'R3-VERIFY'],
  ['P5 单段路径', 'R3-VERIFY', 'R3-VERIFY'],
];

/**
 * 主流程。
 * @returns {number} 退出码
 */
function main() {
  console.log(`[info] 自测脚本: ${HERE}`);

  // --- P1~P5：取轮次目录名（5 组路径形态，期望值平台无关）---
  for (const [name, dir, expected] of PATH_CASES) {
    const actual = cycleDirName(dir);
    check(
      `${name} ⇒ ${expected}`,
      actual === expected,
      `实际取到 ${JSON.stringify(actual)}（期望 ${JSON.stringify(expected)}）`,
    );
  }

  // --- N1：负控 —— 目录名 ≠ cycle_id ⇒ 校验仍须抛错（不许把校验改松）---
  {
    const cycleFile = '/tmp/selftest/cycle.json';
    const cases = [
      ['N1a POSIX 路径', '/home/u/proj/test-assets/cycles/R3-VERIFY'],
      ['N1b Windows 路径', 'C:\\Users\\cxp\\proj\\test-assets\\cycles\\R3-VERIFY'],
    ];
    for (const [name, dir] of cases) {
      let threw = null;
      try {
        validateCycleDocument(mkCycle('R3-OTHER'), cycleFile, dir, ['BUG-001']);
      } catch (err) {
        threw = err;
      }
      const isInputError = threw instanceof InputError;
      const mentions = isInputError && threw.message.includes('R3-OTHER') && threw.message.includes('R3-VERIFY');
      check(
        `${name} 目录名 ≠ cycle_id ⇒ 仍抛 InputError`,
        isInputError && mentions,
        threw ? `抛的是 ${threw.name}: ${threw.message}` : '没抛错（校验被放宽了！）',
      );
    }
  }

  // --- N2：负控 —— 目录名 == cycle_id 时**不许**抛错（正向不回归）---
  {
    let threw = null;
    try {
      validateCycleDocument(
        mkCycle('R3-VERIFY'),
        '/tmp/selftest/cycle.json',
        'C:\\Users\\cxp\\proj\\test-assets\\cycles\\R3-VERIFY',
        ['BUG-001'],
      );
    } catch (err) {
      threw = err;
    }
    check(
      'N2 Windows 路径 目录名 == cycle_id ⇒ 不抛错',
      threw === null,
      threw ? `抛错了: ${threw.message}` : '',
    );
  }

  console.log(`[info] 自测结论: ${passed} 通过 / ${failed} 失败`);
  return failed === 0 ? 0 : 1;
}

process.exitCode = main();
