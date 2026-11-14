// catalog.mjs —— 负载规划域的**枚举与字段集基线**（单一来源）
//
// 契约（REQ-009 F1 / F2 / F3）：
//   - 上下文的顶层字段集**封闭 5 个**；workload 条目**封闭 10 个**；
//   - 负载画像 `profile.type` **5 值**；`tool.runner` **2 值**、`tool.runtime` **3 值**；
//   - `thresholds` 的键**白名单封闭 6 个**；
//   - 负载模型本体顶层**封闭 14 个**（其中 2 个是条件字段）；
//   - `suite.json` 顶层 ⊆ 上游 **9 个**允许字段；套件级引用件顶层**封闭 3 个**。
//
// 纯数据模块：不依赖 node: 内置模块之外的任何东西，也不做任何 IO。

/** 上下文 schema 版本。 */
export const CONTEXT_SCHEMA_VERSION = 1;

/** 负载模型 / 引用件的 schema 版本。 */
export const PRODUCT_SCHEMA_VERSION = 1;

/** 压测计划清单（report.json）的 schema 版本。 */
export const REPORT_SCHEMA_VERSION = 1;

/** 本 REQ 的需求编号（写进 suite.json 的 `requirement`）。 */
export const REQUIREMENT_ID = 'REQ-009';

/** 负载画像类型（5 个）。 */
export const PROFILE_TYPES = ['constant', 'ramp-up', 'ramp-down', 'spike', 'soak'];

/** runner（只是**声明**，本 skill 不装、不跑）。 */
export const RUNNERS = ['loadtest', 'python'];

/** runner 的运行时。 */
export const RUNTIMES = ['bun', 'python', 'node'];

/** 阈值键白名单（封闭 6 个）。 */
export const THRESHOLD_KEYS = [
  'p50_latency_ms',
  'p95_latency_ms',
  'p99_latency_ms',
  'error_rate',
  'throughput_rps',
  'max_concurrency',
];

/** 取值必须落在 [0, 1] 的阈值键。 */
export const RATE_THRESHOLD_KEYS = ['error_rate'];

/** 未决问题的主题（封闭 4 个）。 */
export const OPEN_QUESTION_TOPICS = ['thresholds', 'coverage', 'runner', 'other'];

/** 上下文的顶层字段集（封闭 5 个）。 */
export const CONTEXT_FIELDS = ['schema_version', 'service', 'environments', 'workloads', 'open_questions'];

/** 上下文的必填顶层字段。 */
export const CONTEXT_REQUIRED_FIELDS = ['schema_version', 'service', 'environments', 'workloads'];

/** `service` 的字段集（封闭 2 个）。 */
export const SERVICE_FIELDS = ['name', 'description'];

/** `environments[]` 元素的字段集（封闭 2 个）。 */
export const ENVIRONMENT_FIELDS = ['name', 'base_url'];

/** workload 条目的字段集（封闭 10 个）。 */
export const WORKLOAD_FIELDS = [
  'id',
  'name',
  'target',
  'environment',
  'profile',
  'thresholds',
  'thresholds_source',
  'tool',
  'args',
  'requirement_refs',
];

/** `profile` 的字段集（封闭 2 个）。 */
export const PROFILE_FIELDS = ['type', 'steps'];

/** `profile.steps[]` 元素的字段集（封闭 2 个）。 */
export const PROFILE_STEP_FIELDS = ['duration_s', 'concurrency'];

/** `tool` 的字段集（封闭 2 个）。 */
export const TOOL_FIELDS = ['runner', 'runtime'];

/** 未决问题条目的字段集（封闭 3 个）。 */
export const OPEN_QUESTION_FIELDS = ['id', 'topic', 'question'];

/** 负载模型本体的顶层字段集（封闭 14 个）。 */
export const SCENARIO_FIELDS = [
  'schema_version',
  'id',
  'name',
  'service',
  'target',
  'environment',
  'profile',
  'thresholds',
  'thresholds_source',
  'thresholds_status',
  'tool',
  'args',
  'traceability',
  'open_questions',
];

/** 负载模型本体的必填顶层字段（`thresholds` / `thresholds_source` / `args` 是条件字段）。 */
export const SCENARIO_REQUIRED_FIELDS = [
  'schema_version',
  'id',
  'name',
  'service',
  'target',
  'environment',
  'profile',
  'thresholds_status',
  'tool',
  'traceability',
  'open_questions',
];

/** `traceability` 的字段集（封闭 3 个）。 */
export const TRACEABILITY_FIELDS = ['workload_id', 'requirement_refs', 'case_refs'];

/** 套件级引用件的顶层字段集（封闭 3 个）。 */
export const REFERENCE_FIELDS = ['schema_version', 'suite', 'scenarios'];

/** 引用件元素的字段集（封闭 3 个）。 */
export const REFERENCE_ENTRY_FIELDS = ['path', 'id', 'name'];

/** `suite.json` 的允许字段集（上游 9 个，允许字段是**子集**）。 */
export const SUITE_ALLOWED_FIELDS = [
  'suite',
  'requirement',
  'scope',
  'environment',
  'cases_file',
  'executor',
  'base_url_from',
  'tags',
  'report',
];

/** `suite.json` 的必填字段（6 个）。 */
export const SUITE_REQUIRED_FIELDS = [
  'suite',
  'requirement',
  'scope',
  'environment',
  'cases_file',
  'executor',
];

/** 压测计划清单（report.json）的顶层字段集（封闭 5 个）。 */
export const REPORT_FIELDS = ['schema_version', 'service', 'suites', 'scenarios', 'open_questions'];

/** 压测结论键 —— 产物里**一个都不许出现**（本 REQ 不发压）。 */
export const FORBIDDEN_RESULT_KEYS = [
  'status',
  'result',
  'verdict',
  'executed',
  'passed',
  'outcome',
  'conclusion',
];

/** 场景短名 / 环境名的命名约定。 */
export const NAME_PATTERN = /^[a-z0-9][a-z0-9-]*$/;

/** 容量目标 id 的格式。 */
export const WORKLOAD_ID_PATTERN = /^WL-\d{3}$/;

/** 被压链路的格式：方法 + 空格 + 路径。 */
export const TARGET_PATTERN = /^(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS) \/.*$/;

/** 未决问题 id 的格式。 */
export const OPEN_QUESTION_ID_PATTERN = /^OQ-\d{3}$/;

/** 套件目录名的格式。 */
export const SUITE_DIR_PATTERN = /^LOAD-\d{3}-[a-z0-9][a-z0-9-]*$/;

/** `scope` / `executor` 在压测套件里**必须**是这个值。 */
export const LOAD_SCOPE = 'load';

/** 套件级引用件指向本体时的相对路径前缀（相对套件目录）。 */
export const SCENARIO_RELATIVE_PREFIX = '../../scenarios/';
