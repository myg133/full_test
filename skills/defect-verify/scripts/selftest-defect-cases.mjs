#!/usr/bin/env node
/**
 * selftest-defect-cases.mjs —— 派生规则的**单元自测**（需求 L-05 / D97）。
 *
 * §0 验收夹具**造不出**共享场景（5 条缺陷互不共享用例），所以共享分支的证据只有这里。
 * 本脚本用自造的最小夹具，把下列分支逐条跑一遍并断言产物的实际内容：
 *
 *   T1  同一缺陷的 case_refs 内有**重复 id** ⇒ 先去重，再按「全中 ⇒ reused」判（D97.1）
 *   T2  case_refs **部分命中** ⇒ 整条改判 unresolved，理由点名找不到的 id（D73）
 *   T3  **两条缺陷引用同一条已有用例** ⇒ 产物里该用例只出现一次，
 *       且 defect_refs / tags / requirement_refs 含**全部**引用它的缺陷（D97.2）
 *   T4  扩展编号段被占用 ⇒ 顺延到下一个空闲号（D82）
 *   T5  复现信息不足 ⇒ unresolved + 非空理由（F1.3）
 *   T6  幂等：同一输入两次，除 meta.generated_at 外逐字相同（D83）
 *
 * 用法: node scripts/selftest-defect-cases.mjs [--keep]
 * 退出码: 0 = 全部通过 / 1 = 有用例不通过 / 2 = 用法错误
 *
 * 纯 Node.js：只用 node: 内置模块，零第三方依赖，不联网。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MAKER = path.join(HERE, 'make-defect-cases.mjs');

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
 * 写一个 JSON 文件。
 * @param {string} file 目标文件
 * @param {object} value 内容
 */
function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

/**
 * 造一条已有用例。
 * @param {string} id 用例 id
 * @param {string} title 标题
 * @param {string[]} actions 步骤 action
 * @param {string[]} tags 标签
 * @returns {object}
 */
function mkCase(id, title, actions, tags) {
  return {
    id,
    title,
    requirement_refs: ['R-0'],
    dimension: 'functional',
    priority: 'P0',
    method: ['M1.1'],
    status: 'active',
    preconditions: [],
    steps: actions.map((action) => ({ action, expected: '正常' })),
    data: {},
    tags,
  };
}

/**
 * 跑一次主入口。
 * @param {string} root 工作根
 * @param {object} defects 缺陷单
 * @param {object} cases 用例集
 * @param {string} outName 输出目录名
 * @returns {{code: number, stdout: string, stderr: string, file: string}}
 */
function runMaker(root, defects, cases, outName) {
  const defectsFile = path.join(root, 'inputs', 'defects.json');
  const casesFile = path.join(root, 'inputs', 'cases.json');
  writeJson(defectsFile, defects);
  writeJson(casesFile, cases);
  const cycleDir = path.join(root, 'cycles', 'R3-SELFTEST');
  writeJson(path.join(cycleDir, 'cycle.json'), {
    cycle_id: 'R3-SELFTEST',
    round: 'R3',
    round_type: 'defect-verify',
    requirement: 'REQ-SELFTEST',
    scopes: ['functional'],
    scopes_skipped: [],
    status: 'in_progress',
    stages: { clarify: { status: 'done' }, design: { status: 'in_progress' } },
    history: [],
    trigger: { type: 'defect', ref: 'BUG-001' },
  });
  const outDir = path.join(root, outName);
  const result = spawnSync(
    process.execPath,
    [MAKER, '--defects', defectsFile, '--cases', casesFile, '--suite', 'REQ-SELFTEST', '--cycle-dir', cycleDir, '--out-dir', outDir],
    { encoding: 'utf8' },
  );
  const file = path.join(outDir, 'defect-cases.json');
  const product = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
  return {
    code: result.status === null ? 2 : result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
    file,
    product,
  };
}

/**
 * 主流程。
 * @returns {number} 退出码
 */
function main() {
  const keep = process.argv.slice(2).includes('--keep');
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'defect-verify-selftest-'));
  console.log(`[info] 自测工作根: ${root}`);

  const baseCases = {
    schema_version: 2,
    requirements: [{ id: 'R-0', title: '原套件的需求', source_ref: 'x', testable: true }],
    open_questions: [],
    coverage_matrix: [],
    cases: [
      mkCase('TC-001', '优惠券核销用例', ['以满减券下单', '触发核销'], ['coupon']),
      mkCase('TC-101', '已占用扩展段编号的用例', ['占位导出'], ['report']),
    ],
  };

  const full = (command, steps, expected) => ({
    command,
    steps,
    expected_failure: expected,
  });

  try {
    // --- T1：case_refs 内重复 id ⇒ 先去重 ---
    {
      const defects = {
        schema_version: 1,
        defects: [
          {
            id: 'BUG-001',
            title: '重复引用的缺陷',
            severity: 'high',
            status: 'open',
            case_refs: ['TC-001', 'TC-001'],
            reproduction: full('curl -X POST https://api.example.com/coupon/redeem', ['以满减券下单', '触发核销'], '实付金额多 0.01 元'),
          },
        ],
      };
      const run = runMaker(root, defects, baseCases, 'out-t1');
      const entry = run.product && run.product.defects[0];
      check('T1 重复 id 去重后仍判 reused', Boolean(entry) && entry.disposition === 'reused', JSON.stringify(entry));
      check(
        'T1 reused_case_refs 去重后只有一条',
        Boolean(entry) && Array.isArray(entry.reused_case_refs) && entry.reused_case_refs.length === 1
          && entry.reused_case_refs[0].case_id === 'TC-001',
        JSON.stringify(entry && entry.reused_case_refs),
      );
    }

    // --- T2：部分命中 ⇒ 整条 unresolved ---
    {
      const defects = {
        schema_version: 1,
        defects: [
          {
            id: 'BUG-001',
            title: '部分命中的缺陷',
            severity: 'high',
            status: 'open',
            case_refs: ['TC-001', 'TC-404'],
            reproduction: full('curl -X POST https://api.example.com/coupon/redeem', ['以满减券下单'], '失败'),
          },
        ],
      };
      const run = runMaker(root, defects, baseCases, 'out-t2');
      const entry = run.product && run.product.defects[0];
      check('T2 部分命中 ⇒ unresolved', Boolean(entry) && entry.disposition === 'unresolved', JSON.stringify(entry));
      check(
        'T2 理由点名找不到的 id',
        Boolean(entry) && typeof entry.reason === 'string' && entry.reason.includes('TC-404'),
        JSON.stringify(entry && entry.reason),
      );
      check(
        'T2 不得部分复用（无 reused_case_refs）',
        Boolean(entry) && !('reused_case_refs' in entry),
        JSON.stringify(entry),
      );
    }

    // --- T3：两条缺陷共享同一条已有用例 ---
    {
      const defects = {
        schema_version: 1,
        defects: [
          {
            id: 'BUG-001',
            title: '缺陷一',
            severity: 'high',
            status: 'open',
            case_refs: ['TC-001'],
            reproduction: full('curl -X POST https://api.example.com/coupon/redeem', ['以满减券下单', '触发核销'], '失败一'),
          },
          {
            id: 'BUG-002',
            title: '缺陷二（同一根因的另一症状）',
            severity: 'medium',
            status: 'open',
            case_refs: ['TC-001'],
            reproduction: full('curl -X POST https://api.example.com/coupon/redeem', ['以满减券下单', '触发核销'], '失败二'),
          },
        ],
      };
      const run = runMaker(root, defects, baseCases, 'out-t3');
      const product = run.product;
      const shared = product && product.cases.filter((c) => c.id === 'TC-001');
      check('T3 共享用例在 cases[] 里只出现一次', Boolean(product) && shared.length === 1, `出现 ${shared ? shared.length : 0} 次`);
      check(
        'T3 共享用例的 defect_refs 含两条缺陷',
        Boolean(shared && shared[0]) && shared[0].defect_refs.slice().sort().join(',') === 'BUG-001,BUG-002',
        JSON.stringify(shared && shared[0] && shared[0].defect_refs),
      );
      check(
        'T3 共享用例的 tags 含 defect-verify 与两条缺陷 id',
        Boolean(shared && shared[0])
          && ['defect-verify', 'BUG-001', 'BUG-002'].every((tag) => shared[0].tags.includes(tag)),
        JSON.stringify(shared && shared[0] && shared[0].tags),
      );
      check(
        'T3 共享用例的 requirement_refs 含两条缺陷的 R-<n> 且不悬空',
        Boolean(shared && shared[0])
          && shared[0].requirement_refs.slice().sort().join(',') === 'R-1,R-2'
          && product.requirements.map((r) => r.id).sort().join(',') === 'R-1,R-2',
        JSON.stringify(shared && shared[0] && shared[0].requirement_refs),
      );
      check(
        'T3 两条缺陷各自独立判 reused',
        Boolean(product)
          && product.defects.length === 2
          && product.defects.every((d) => d.disposition === 'reused'),
        JSON.stringify(product && product.defects),
      );
      check(
        'T3 产物里没有重复 id 的用例',
        Boolean(product) && new Set(product.cases.map((c) => c.id)).size === product.cases.length,
        JSON.stringify(product && product.cases.map((c) => c.id)),
      );
    }

    // --- T4：扩展编号段被占用 ⇒ 顺延 ---
    {
      const defects = {
        schema_version: 1,
        defects: [
          {
            id: 'BUG-001',
            title: '没有对应用例的缺陷',
            severity: 'low',
            status: 'open',
            reproduction: full('curl -X GET https://api.example.com/reports/export', ['触发报表导出', '下载导出文件'], '导出文件为空'),
          },
        ],
      };
      const run = runMaker(root, defects, baseCases, 'out-t4');
      const entry = run.product && run.product.defects[0];
      check('T4 判 derived', Boolean(entry) && entry.disposition === 'derived', JSON.stringify(entry));
      check(
        'T4 顺延到 TC-102（TC-101 已被占用）',
        Boolean(entry) && entry.derived_case_id === 'TC-102',
        JSON.stringify(entry && entry.derived_case_id),
      );
    }

    // --- T5：复现信息不足 ⇒ unresolved ---
    {
      const defects = {
        schema_version: 1,
        defects: [
          {
            id: 'BUG-001',
            title: '复现信息不足的缺陷',
            severity: 'low',
            status: 'open',
            reproduction: { command: '', steps: [], expected_failure: '' },
          },
        ],
      };
      const run = runMaker(root, defects, baseCases, 'out-t5');
      const entry = run.product && run.product.defects[0];
      check('T5 信息不足 ⇒ unresolved', Boolean(entry) && entry.disposition === 'unresolved', JSON.stringify(entry));
      check(
        'T5 理由非空且说明缺什么',
        Boolean(entry) && typeof entry.reason === 'string' && entry.reason.trim() !== ''
          && entry.reason.includes('reproduction'),
        JSON.stringify(entry && entry.reason),
      );
      check(
        'T5 不产出用例',
        Boolean(run.product) && run.product.cases.length === 0,
        JSON.stringify(run.product && run.product.cases),
      );
    }

    // --- T6：幂等 ---
    {
      const defects = {
        schema_version: 1,
        defects: [
          {
            id: 'BUG-001',
            title: '幂等用的缺陷',
            severity: 'high',
            status: 'open',
            case_refs: ['TC-001'],
            reproduction: full('curl -X POST https://api.example.com/coupon/redeem', ['以满减券下单', '触发核销'], '失败'),
          },
          {
            id: 'BUG-002',
            title: '要派生的缺陷',
            severity: 'medium',
            status: 'open',
            reproduction: full('curl -X GET https://api.example.com/reports/export', ['触发报表导出'], '导出文件为空'),
          },
        ],
      };
      const first = runMaker(root, defects, baseCases, 'out-t6a');
      const second = runMaker(root, defects, baseCases, 'out-t6b');
      const strip = (file) => {
        const text = fs.readFileSync(file, 'utf8');
        const doc = JSON.parse(text);
        const stamp = doc.meta.generated_at;
        return text.split(stamp).join('<TS>');
      };
      const same = first.code === 0 && second.code === 0
        && strip(first.file) === strip(second.file);
      check('T6 同一输入两次除 generated_at 外逐字相同', same, '两份产物不一致');
    }
  } finally {
    if (!keep) {
      try {
        fs.rmSync(root, { recursive: true, force: true });
      } catch {
        // 清理失败不影响退出码
      }
    } else {
      console.log(`[info] 自测工作根保留: ${root}`);
    }
  }

  console.log(`[info] 自测结论: ${passed} 通过 / ${failed} 失败`);
  return failed === 0 ? 0 : 1;
}

process.exitCode = main();
