// stub.mjs —— 本地桩服务（**只监听回环地址**）
//
// 契约（F3 / D187 / D193 / D196 / D209）：
//   - **只监听 127.0.0.1** ⇒ 物理上不可能被外部访问；
//   - **自带计数**（按 path，path 不含 query）与**延迟直方图**（按 ms 桶，**聚合**，不存全量样本）；
//   - **每条 invocation 前重置观测** ⇒ 桩侧观测是**本次增量**，不是累计；
//   - **记录绝对时序**：相对**桩启动**的毫秒偏移（首/末请求到达时刻）⇒ 可机械核「顺序执行、无重叠」；
//   - **支持注入**：延迟（`delayMs`）与错误率（`errorRate`）⇒ 响应码按注入比例取 200 / 500；
//   - **配置面封闭**：只有「延迟注入」「错误率注入」「响应码」「重置观测」四项，**不含任何真实业务逻辑**；
//   - **生命周期由执行器托管**：起（等就绪）⇒ 跑 ⇒ 停（停的时候连同残留连接一起断开）。
//
// ⚠️ 桩是**辅助证据**：桩侧观测**不参与阈值判定**（主观测量取客户端侧，见 D198）。
// ⚠️ 桩侧「延迟」= 桩的**服务端处理耗时**（含注入延迟），与客户端 RTT **语义不同**（C3）。

import http from 'node:http';

/** 桩只监听回环地址（IPv4）。 */
export const STUB_HOST = '127.0.0.1';

/** 桩自己的只读观测端点 / 重置端点（**不计入**请求计数）。 */
export const STUB_OBSERVATIONS_PATH = '/__stub/observations';
export const STUB_RESET_PATH = '/__stub/reset';

const CONTROL_PATHS = new Set([STUB_OBSERVATIONS_PATH, STUB_RESET_PATH]);

/**
 * 桩服务（单实例：端口 0 随机分配 ⇒ 同机多套件天然隔离）。
 */
export class Stub {
  /**
   * @param {object} [options]
   * @param {number} [options.delayMs=0] 注入延迟（毫秒）
   * @param {number} [options.errorRate=0] 注入错误率（0~1）
   */
  constructor(options = {}) {
    const delayMs = Number(options.delayMs);
    const errorRate = Number(options.errorRate);
    this.delayMs = Number.isFinite(delayMs) && delayMs > 0 ? Math.floor(delayMs) : 0;
    this.errorRate = Number.isFinite(errorRate) && errorRate > 0 ? Math.min(1, errorRate) : 0;
    this.origin = '';
    this.startedAtMs = 0;
    this.server = null;
    this.sockets = new Set();
    this.resetObservations();
  }

  /** 重置观测（⇒ 桩侧观测是**本次增量**）。 */
  resetObservations() {
    this.requests = 0;
    this.errors = 0;
    this.sumMs = 0;
    this.minMs = null;
    this.maxMs = null;
    this.histogramMs = {};
    this.firstAtMs = null;
    this.lastAtMs = null;
    this.pathCounts = {};
    this.methods = {};
  }

  /**
   * 起桩（端口 0 ⇒ 随机分配）；resolve 之后桩已就绪。
   * @returns {Promise<string>} 桩的 origin
   */
  async start() {
    if (this.server) throw new Error('桩已经在运行');
    this.server = http.createServer((req, res) => {
      this.handle(req, res);
    });
    this.server.on('connection', (socket) => {
      this.sockets.add(socket);
      socket.on('close', () => this.sockets.delete(socket));
      socket.on('error', () => { /* 客户端被中断时的连接错误：忽略 */ });
    });
    this.server.on('clientError', (err, socket) => {
      try { socket.destroy(); } catch { /* 已断开 */ }
    });
    await new Promise((resolve, reject) => {
      const onError = (err) => reject(err);
      this.server.once('error', onError);
      this.server.listen(0, STUB_HOST, () => {
        this.server.removeListener('error', onError);
        resolve();
      });
    });
    const address = this.server.address();
    this.origin = `http://${STUB_HOST}:${address.port}`;
    this.startedAtMs = Date.now();
    return this.origin;
  }

  /**
   * 停桩（**连同残留连接一起断开** ⇒ 进程能退出、端口能释放）。
   * @returns {Promise<void>}
   */
  async stop() {
    const server = this.server;
    this.server = null;
    if (!server) return;
    for (const socket of this.sockets) {
      try { socket.destroy(); } catch { /* 已断开 */ }
    }
    this.sockets.clear();
    if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
    await new Promise((resolve) => {
      server.close(() => resolve());
    });
  }

  /**
   * 处理一次请求。
   * @param {import('node:http').IncomingMessage} req 请求
   * @param {import('node:http').ServerResponse} res 响应
   */
  handle(req, res) {
    let path = '/';
    let query = '';
    try {
      const parsed = new URL(req.url || '/', this.origin || `http://${STUB_HOST}`);
      path = parsed.pathname;
      query = parsed.search;
    } catch {
      path = req.url || '/';
    }

    if (CONTROL_PATHS.has(path)) {
      this.handleControl(req, res, path);
      return;
    }

    const arrivedAtMs = Date.now() - this.startedAtMs;
    this.requests += 1;
    this.pathCounts[path] = (this.pathCounts[path] || 0) + 1;
    this.methods[req.method] = (this.methods[req.method] || 0) + 1;
    if (this.firstAtMs === null) this.firstAtMs = arrivedAtMs;
    this.lastAtMs = arrivedAtMs;

    // 请求体读掉（POST 可能有 body）；不读会让连接挂住。
    req.on('error', () => { /* 客户端中断：忽略 */ });
    req.resume();

    const beganAt = Date.now();
    const respond = () => {
      const elapsedMs = Date.now() - beganAt;
      this.recordLatency(elapsedMs);
      const status = this.pickStatus();
      if (status >= 400) this.errors += 1;
      if (res.writableEnded || res.destroyed) return;
      try {
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ stub: true, path, query, status }));
      } catch {
        /* 客户端已断开：忽略 */
      }
    };

    if (this.delayMs > 0) setTimeout(respond, this.delayMs);
    else respond();
  }

  /**
   * 桩自己的控制面（观测 / 重置）—— **不计入**请求计数。
   * @param {import('node:http').IncomingMessage} req 请求
   * @param {import('node:http').ServerResponse} res 响应
   * @param {string} path 路径
   */
  handleControl(req, res, path) {
    req.resume();
    if (path === STUB_RESET_PATH) this.resetObservations();
    const body = JSON.stringify(this.snapshot());
    if (res.writableEnded || res.destroyed) return;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(body);
  }

  /**
   * 记录一条延迟观测（**聚合**：直方图 + 计数 + 合计 + 极值，**不存全量样本**）。
   * @param {number} elapsedMs 处理耗时（毫秒）
   */
  recordLatency(elapsedMs) {
    const bucket = String(Math.max(0, Math.round(elapsedMs)));
    this.histogramMs[bucket] = (this.histogramMs[bucket] || 0) + 1;
    this.sumMs += elapsedMs;
    if (this.minMs === null || elapsedMs < this.minMs) this.minMs = elapsedMs;
    if (this.maxMs === null || elapsedMs > this.maxMs) this.maxMs = elapsedMs;
  }

  /**
   * 按注入比例取响应码（200 / 500）。
   * @returns {number} HTTP 状态码
   */
  pickStatus() {
    if (this.errorRate > 0 && Math.random() < this.errorRate) return 500;
    return 200;
  }

  /**
   * 桩侧观测快照（**封闭 9 个键**）。
   * @returns {object} 观测快照
   */
  snapshot() {
    return {
      requests: this.requests,
      errors: this.errors,
      error_rate: this.requests > 0 ? this.errors / this.requests : null,
      mean_ms: this.requests > 0 ? Math.round((this.sumMs / this.requests) * 10) / 10 : 0,
      min_ms: this.minMs === null ? 0 : this.minMs,
      max_ms: this.maxMs === null ? 0 : this.maxMs,
      histogram_ms: { ...this.histogramMs },
      first_at_ms: this.firstAtMs === null ? 0 : this.firstAtMs,
      last_at_ms: this.lastAtMs === null ? 0 : this.lastAtMs,
    };
  }

  /**
   * 桩侧的辅助诊断信息（**不进产物**，只在报错时用）。
   * @returns {object} 诊断信息
   */
  diagnostics() {
    return {
      requests: this.requests,
      paths: { ...this.pathCounts },
      methods: { ...this.methods },
    };
  }
}
