// context.mjs —— 压测上下文的**输入层**校验（契约 F1.2 ~ F1.7）
//
// 三条硬约束都在这里落地：
//   1. **封闭字段集**：顶层封闭 5 个、workload 条目封闭 10 个、profile/tool/steps 各封闭 2 个；
//      出现表外字段 ⇒ 输入非法（rc=1）。
//   2. **引用不悬空**：workload 的 environment 必须在 environments[] 内；
//      id / name 格式合法且文件内唯一；target 形如 "METHOD /path"。
//   3. **阈值成对**：thresholds 与 thresholds_source 必须同时出现或同时不出现；
//      只给一个 ⇒ 输入非法（凭空拍阈值 / 自相矛盾都拒）。
//
// ⚠️ 所有问题**一次性收集**再抛出 ⇒ stderr 点名**每一个**坏点。
// ⚠️ 校验期间**不碰文件系统** ⇒ 非法输入时不可能留下半份产物。

import {
  CONTEXT_FIELDS,
  CONTEXT_REQUIRED_FIELDS,
  CONTEXT_SCHEMA_VERSION,
  ENVIRONMENT_FIELDS,
  NAME_PATTERN,
  OPEN_QUESTION_FIELDS,
  OPEN_QUESTION_ID_PATTERN,
  OPEN_QUESTION_TOPICS,
  PROFILE_FIELDS,
  PROFILE_STEP_FIELDS,
  PROFILE_TYPES,
  RATE_THRESHOLD_KEYS,
  RUNNERS,
  RUNTIMES,
  SERVICE_FIELDS,
  TARGET_PATTERN,
  THRESHOLD_KEYS,
  TOOL_FIELDS,
  WORKLOAD_FIELDS,
  WORKLOAD_ID_PATTERN,
} from './catalog.mjs';
import { InputError, isFilledString, isObject } from './io.mjs';

/**
 * 校验一条未决问题条目（封闭 3 个字段）。
 * @param {*} question 待校验条目
 * @param {string} where 出错时用的位置标签
 * @param {Set<string>} seenIds 已用过的 id（文件内唯一）
 * @param {string[]} problems 问题清单
 */
function checkOpenQuestion(question, where, seenIds, problems) {
  if (!isObject(question)) {
    problems.push(`${where} 必须是对象`);
    return;
  }
  for (const key of Object.keys(question)) {
    if (!OPEN_QUESTION_FIELDS.includes(key)) problems.push(`${where} 出现表外字段 "${key}"`);
  }
  for (const key of OPEN_QUESTION_FIELDS) {
    if (!(key in question)) problems.push(`${where} 缺必填字段 "${key}"`);
  }
  if (!isFilledString(question.id)) {
    problems.push(`${where}.id 必须是非空字符串`);
  } else if (!OPEN_QUESTION_ID_PATTERN.test(question.id)) {
    problems.push(`${where}.id "${question.id}" 不合格式 ^OQ-\\d{3}$`);
  } else if (seenIds.has(question.id)) {
    problems.push(`${where}.id "${question.id}" 重复（文件内 id 必须唯一）`);
  } else {
    seenIds.add(question.id);
  }
  if (!OPEN_QUESTION_TOPICS.includes(question.topic)) {
    problems.push(`${where}.topic "${question.topic}" 不在允许值内（${OPEN_QUESTION_TOPICS.join(' / ')}）`);
  }
  if (!isFilledString(question.question)) {
    problems.push(`${where}.question 必须是非空字符串`);
  }
}

/**
 * 校验一条 workload（封闭 10 个字段）。
 * @param {*} workload 待校验条目
 * @param {number} index 下标（错误信息里用）
 * @param {Set<string>} envNames environments[] 里的环境名
 * @param {Set<string>} seenIds 已用过的容量目标 id
 * @param {Set<string>} seenNames 已用过的容量目标 name
 * @param {string[]} problems 问题清单
 */
function checkWorkload(workload, index, envNames, seenIds, seenNames, problems) {
  const where = `workloads[${index}]`;
  if (!isObject(workload)) {
    problems.push(`${where} 必须是对象`);
    return;
  }
  for (const key of Object.keys(workload)) {
    if (!WORKLOAD_FIELDS.includes(key)) problems.push(`${where} 出现表外字段 "${key}"`);
  }

  // --- id：格式 + 文件内唯一 ---
  if (!isFilledString(workload.id)) {
    problems.push(`${where}.id 必须是非空字符串`);
  } else if (!WORKLOAD_ID_PATTERN.test(workload.id)) {
    problems.push(`${where}.id "${workload.id}" 不合格式 ^WL-\\d{3}$`);
  } else if (seenIds.has(workload.id)) {
    problems.push(`${where}.id "${workload.id}" 与前面的容量目标 id 重复（文件内 id 必须唯一）`);
  } else {
    seenIds.add(workload.id);
  }

  // --- name：命名约定 + 文件内唯一（场景文件名由它决定） ---
  if (!isFilledString(workload.name)) {
    problems.push(`${where}.name 必须是非空字符串`);
  } else if (!NAME_PATTERN.test(workload.name)) {
    problems.push(`${where}.name "${workload.name}" 不合命名约定 ^[a-z0-9][a-z0-9-]*$`);
  } else if (seenNames.has(workload.name)) {
    problems.push(`${where}.name "${workload.name}" 与前面的容量目标重名（场景文件名由 name 决定，必须唯一）`);
  } else {
    seenNames.add(workload.name);
  }

  // --- target：方法 + 空格 + 路径 ---
  if (!isFilledString(workload.target)) {
    problems.push(`${where}.target 必须是非空字符串`);
  } else if (!TARGET_PATTERN.test(workload.target)) {
    problems.push(
      `${where}.target "${workload.target}" 不合格式（须为 "METHOD /path"，METHOD ∈ GET / POST / PUT / DELETE / PATCH / HEAD / OPTIONS）`,
    );
  }

  // --- environment：不得悬空 ---
  if (!isFilledString(workload.environment)) {
    problems.push(`${where}.environment 必须是非空字符串`);
  } else if (!envNames.has(workload.environment)) {
    problems.push(
      `${where}.environment "${workload.environment}" 不在 environments[] 内（可用: ${[...envNames].join(' / ')}）`,
    );
  }

  // --- profile：封闭 2 ---
  if (!isObject(workload.profile)) {
    problems.push(`${where}.profile 必须是对象`);
  } else {
    for (const key of Object.keys(workload.profile)) {
      if (!PROFILE_FIELDS.includes(key)) problems.push(`${where}.profile 出现表外字段 "${key}"`);
    }
    if (!PROFILE_TYPES.includes(workload.profile.type)) {
      problems.push(
        `${where}.profile.type "${workload.profile.type}" 不在允许值内（${PROFILE_TYPES.join(' / ')}）`,
      );
    }
    if (!Array.isArray(workload.profile.steps) || workload.profile.steps.length < 1) {
      problems.push(`${where}.profile.steps 必须是至少 1 项的数组`);
    } else {
      workload.profile.steps.forEach((step, stepIndex) => {
        const stepWhere = `${where}.profile.steps[${stepIndex}]`;
        if (!isObject(step)) {
          problems.push(`${stepWhere} 必须是对象`);
          return;
        }
        for (const key of Object.keys(step)) {
          if (!PROFILE_STEP_FIELDS.includes(key)) problems.push(`${stepWhere} 出现表外字段 "${key}"`);
        }
        if (!Number.isInteger(step.duration_s) || step.duration_s < 1) {
          problems.push(`${stepWhere}.duration_s 必须是 ≥ 1 的整数`);
        }
        if (!Number.isInteger(step.concurrency) || step.concurrency < 1) {
          problems.push(`${stepWhere}.concurrency 必须是 ≥ 1 的整数`);
        }
      });
    }
  }

  // --- thresholds 与 thresholds_source：必须成对 ---
  const hasThresholds = 'thresholds' in workload;
  const hasSource = 'thresholds_source' in workload;
  if (hasThresholds !== hasSource) {
    problems.push(
      `${where}.thresholds 与 thresholds_source 必须成对出现（${
        hasThresholds ? '给了 thresholds 却缺 thresholds_source' : '给了 thresholds_source 却缺 thresholds'
      }）`,
    );
  } else if (hasThresholds) {
    if (!isFilledString(workload.thresholds_source)) {
      problems.push(`${where}.thresholds_source 必须是非空字符串`);
    }
    if (!isObject(workload.thresholds)) {
      problems.push(`${where}.thresholds 必须是对象`);
    } else {
      const keys = Object.keys(workload.thresholds);
      if (keys.length < 1) problems.push(`${where}.thresholds 至少要有 1 个键`);
      for (const key of keys) {
        if (!THRESHOLD_KEYS.includes(key)) {
          problems.push(`${where}.thresholds 出现表外键 "${key}"（允许键: ${THRESHOLD_KEYS.join(' / ')}）`);
          continue;
        }
        const value = workload.thresholds[key];
        if (typeof value !== 'number' || !Number.isFinite(value)) {
          problems.push(`${where}.thresholds.${key} 必须是数字`);
        } else if (RATE_THRESHOLD_KEYS.includes(key)) {
          if (value < 0 || value > 1) problems.push(`${where}.thresholds.${key} 必须在 [0, 1] 内`);
        } else if (value < 0) {
          problems.push(`${where}.thresholds.${key} 必须 ≥ 0`);
        }
      }
    }
  }

  // --- tool：封闭 2 ---
  if (!isObject(workload.tool)) {
    problems.push(`${where}.tool 必须是对象`);
  } else {
    for (const key of Object.keys(workload.tool)) {
      if (!TOOL_FIELDS.includes(key)) problems.push(`${where}.tool 出现表外字段 "${key}"`);
    }
    if (!RUNNERS.includes(workload.tool.runner)) {
      problems.push(
        `${where}.tool.runner "${workload.tool.runner}" 不在允许值内（${RUNNERS.join(' / ')}）`,
      );
    }
    if (!RUNTIMES.includes(workload.tool.runtime)) {
      problems.push(
        `${where}.tool.runtime "${workload.tool.runtime}" 不在允许值内（${RUNTIMES.join(' / ')}）`,
      );
    }
  }

  // --- args（开放键值）与 requirement_refs ---
  if ('args' in workload && !isObject(workload.args)) {
    problems.push(`${where}.args 必须是对象`);
  }
  if ('requirement_refs' in workload) {
    if (!Array.isArray(workload.requirement_refs)) {
      problems.push(`${where}.requirement_refs 必须是字符串数组`);
    } else {
      workload.requirement_refs.forEach((ref, refIndex) => {
        if (typeof ref !== 'string') problems.push(`${where}.requirement_refs[${refIndex}] 必须是字符串`);
      });
    }
  }
}

/**
 * 校验整份压测上下文。
 * @param {*} doc 解析后的上下文
 * @returns {{service: object, environments: object[], workloads: object[], openQuestions: object[]}} 归一化后的上下文
 * @throws {InputError} 任一非法
 */
export function validateContext(doc) {
  if (!isObject(doc)) throw new InputError('压测上下文必须是 JSON 对象');

  const problems = [];

  // --- 顶层：封闭 5 个 ---
  for (const key of Object.keys(doc)) {
    if (!CONTEXT_FIELDS.includes(key)) {
      problems.push(`压测上下文顶层出现表外字段 "${key}"（顶层字段集封闭: ${CONTEXT_FIELDS.join(' / ')}）`);
    }
  }
  for (const key of CONTEXT_REQUIRED_FIELDS) {
    if (!(key in doc)) problems.push(`压测上下文缺必填字段 "${key}"`);
  }
  if (problems.length > 0) throw new InputError(problems.join('\n'));

  if (doc.schema_version !== CONTEXT_SCHEMA_VERSION) {
    problems.push(
      `压测上下文的 schema_version 必须是 ${CONTEXT_SCHEMA_VERSION}（实际 ${JSON.stringify(doc.schema_version)}）`,
    );
  }

  // --- service：封闭 2 ---
  if (!isObject(doc.service)) {
    problems.push('压测上下文的 service 必须是对象');
  } else {
    for (const key of Object.keys(doc.service)) {
      if (!SERVICE_FIELDS.includes(key)) problems.push(`service 出现表外字段 "${key}"`);
    }
    if (!isFilledString(doc.service.name)) problems.push('service.name 必须是非空字符串');
    if ('description' in doc.service && typeof doc.service.description !== 'string') {
      problems.push('service.description 必须是字符串');
    }
  }

  // --- environments：目标环境清单（≥ 1 项，元素封闭 2） ---
  const envNames = new Set();
  if (!Array.isArray(doc.environments)) {
    problems.push('压测上下文的 environments 必须是数组');
  } else if (doc.environments.length < 1) {
    problems.push('压测上下文的 environments 至少要有 1 项');
  } else {
    doc.environments.forEach((environment, index) => {
      const where = `environments[${index}]`;
      if (!isObject(environment)) {
        problems.push(`${where} 必须是对象`);
        return;
      }
      for (const key of Object.keys(environment)) {
        if (!ENVIRONMENT_FIELDS.includes(key)) problems.push(`${where} 出现表外字段 "${key}"`);
      }
      if (!isFilledString(environment.name)) {
        problems.push(`${where}.name 必须是非空字符串`);
      } else if (!NAME_PATTERN.test(environment.name)) {
        problems.push(`${where}.name "${environment.name}" 不合命名约定 ^[a-z0-9][a-z0-9-]*$`);
      } else {
        envNames.add(environment.name);
      }
      if (!isFilledString(environment.base_url)) {
        problems.push(`${where}.base_url 必须是非空字符串`);
      }
    });
  }

  // --- workloads：容量目标（≥ 1 项，元素封闭 10） ---
  const seenIds = new Set();
  const seenNames = new Set();
  if (!Array.isArray(doc.workloads)) {
    problems.push('压测上下文的 workloads 必须是数组');
  } else if (doc.workloads.length < 1) {
    problems.push('压测上下文的 workloads 至少要有 1 项');
  } else {
    doc.workloads.forEach((workload, index) => {
      checkWorkload(workload, index, envNames, seenIds, seenNames, problems);
    });
  }

  // --- open_questions（可选，元素封闭 3） ---
  const openQuestions = [];
  if ('open_questions' in doc && doc.open_questions !== undefined) {
    const seenQuestionIds = new Set();
    if (!Array.isArray(doc.open_questions)) {
      problems.push('压测上下文的 open_questions 必须是数组');
    } else {
      doc.open_questions.forEach((question, index) => {
        checkOpenQuestion(question, `open_questions[${index}]`, seenQuestionIds, problems);
        if (isObject(question)) openQuestions.push(question);
      });
    }
  }

  if (problems.length > 0) throw new InputError(problems.join('\n'));

  return {
    service: doc.service,
    environments: doc.environments,
    workloads: doc.workloads,
    openQuestions,
  };
}
