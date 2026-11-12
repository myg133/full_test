// changelog.mjs —— 变更日志切分与引用标记抽取
//
// 口径（需求 F2）：
//  - 按**二级及以下标题**切分成变更条目，逐条自动编号 C-1、C-2…
//  - 条目正文 = 标题行 + 其后到下一个标题之前的全部行（标记检索范围）；
//  - 显式引用标记：@R-<n>（需求条目）、@TC-<nnn>（用例）、@dim:<维度名>（维度）。
//
// 纯 Node.js。

/** 需求条目引用标记。 */
const REQUIREMENT_REF = /@R-(\d+)/g;
/** 用例引用标记。 */
const CASE_REF = /@TC-(\d{3})/g;
/** 维度引用标记。 */
const DIMENSION_REF = /@dim:([A-Za-z0-9_-]+)/g;
/** 二级及以下标题。 */
const HEADING = /^(#{2,6})\s+(.*)$/;

/**
 * 去重且保持首次出现顺序。
 * @param {string[]} list 原始列表
 * @returns {string[]} 去重后的列表
 */
function unique(list) {
  const out = [];
  for (const item of list) if (!out.includes(item)) out.push(item);
  return out;
}

/**
 * 切分变更日志并抽取标记。
 * @param {string} text 变更日志全文
 * @returns {{id: string, title: string, text: string, requirement_refs: string[], case_refs: string[], dim_refs: string}[]}
 */
export function parseChangelog(text) {
  const lines = text.split(/\r?\n/);
  const entries = [];
  let current = null;
  for (const line of lines) {
    const heading = HEADING.exec(line);
    if (heading) {
      if (current) entries.push(current);
      current = { title: heading[2], text: line };
      continue;
    }
    if (current) current.text += `\n${line}`;
  }
  if (current) entries.push(current);

  return entries.map((entry, index) => ({
    id: `C-${index + 1}`,
    title: entry.title,
    text: entry.text,
    requirement_refs: unique([...entry.text.matchAll(REQUIREMENT_REF)].map((m) => `R-${m[1]}`)),
    case_refs: unique([...entry.text.matchAll(CASE_REF)].map((m) => `TC-${m[1]}`)),
    dim_refs: unique([...entry.text.matchAll(DIMENSION_REF)].map((m) => m[1])),
  }));
}
