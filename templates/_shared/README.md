# 模板工程契约（Template Contract）

6 个模板不是 6 份独立稿子，而是同一套约定的 6 次实例化。新增模板时照抄本文件即可。

---

## 契约一 · 重试（Retry）

任何**外部调用**节点必须开启节点级重试：

```json
"retryOnFail": true,
"maxTries": 3,
"waitBetweenTries": 3000
```

适用范围：`httpRequest`、`slack`、`notion`、`googleSheets`、`emailSend`、`postgres`（读操作）。

**不适用**：写库节点（`INSERT` / `UPDATE`）。写库节点重试会导致重复写入，由契约三的数据库约束兜底，而不是靠重试。

---

## 契约二 · 错误分支（Error Branch）

外部调用节点统一设置：

```json
"onError": "continueErrorOutput"
```

设置后该节点会多出一个 **error output**（`main` 数组的第 2 个元素），必须连到一个 `Log Error` 节点：

```json
"connections": {
  "Push to CRM": {
    "main": [
      [{ "node": "Notify Sales", "type": "main", "index": 0 }],
      [{ "node": "Log Error", "type": "main", "index": 0 }]
    ]
  }
}
```

`Log Error` 是 `n8n-nodes-base.postgres` 节点，执行：

```sql
INSERT INTO workflow_errors (workflow, node, message, payload)
VALUES ($1, $2, $3, $4::jsonb)
```

参数替换（Query Parameters）：

```text
={{ $workflow.name }}, {{ $prevNode.name }}, {{ ($json.error && $json.error.message) || 'request failed' }}, {{ JSON.stringify($json) }}
```

**为什么用 `$prevNode.name` 而不是 `$json.node.name`**：错误输出 item 的形状是「原始 item + 一个 `error` 对象」，**没有** `node` 字段。实测 n8n 2.45.0 里 `$json.node` 恒为 `undefined`，之前落库的 `node` 列全是 `unknown`，等于这一列没有意义。`$prevNode.name` 拿到的是「实际把数据喂给当前节点的那一个节点」，也就是出错的那个，已在实机验证。

**为什么不用独立的 Error Workflow**：独立 error workflow 靠 workflow ID 互相引用，导入到客户环境后 ID 不匹配，直接失效。节点级错误输出是自包含的，导入即用。

> 生产环境可以再挂一层全局 Error Workflow 做兜底，但**模板本身必须自包含**。

---

## 契约三 · 幂等（Idempotency）

幂等由「一占位 + 一闸门 + 一收尾」三个节点组成，缺一不可。

### 3.1 占位（Claim）：租约式两阶段（lease-based two-phase claim）

```sql
INSERT INTO processed_keys (key, workflow, payload, status)
VALUES ($1, $2, $3::jsonb, 'claimed')
ON CONFLICT (key) DO UPDATE
  SET status = 'claimed',
      updated_at = now()
  WHERE processed_keys.status <> 'done'
    AND processed_keys.updated_at < now() - interval '10 minutes'
RETURNING key, payload
```

参数替换：

```text
={{ $json.eventId }}, {{ $workflow.name }}, {{ JSON.stringify($json) }}
```

三个状态语义：

| 情况 | 数据库动作 | 含义 |
|---|---|---|
| key 不存在 | 插入 `status='claimed'` | 本次运行拿到这个 key |
| key 已 `done` | 不更新，返回 0 行 | 这条事件已经处理完，永久去重 |
| key 是 `claimed` 且租约未过期（10 分钟内） | 不更新，返回 0 行 | 同一事件正在处理中（并发/重投） |
| key 是 `claimed` 且租约已过期 | 改回 `claimed` 并刷新时间 | 上次运行中途失败，允许重试 |

**为什么不是 `ON CONFLICT DO NOTHING`**：那样一次失败（LLM 超时、CRM 5xx）就把这个 key 永久占死，客户修好配置后重投同一条事件也不会有任何反应 —— 这是实测踩到的坑。租约让失败可以自愈，又不会把并发重投放进来。

### 3.2 闸门（Gate）：真正让链路停下来

**实测结论（n8n 2.45.0）**：Postgres 节点在 SQL 返回 0 行时，输出**不是**空，而是一条 `{ "success": true }`。所以「0 行 → 后续节点没有输入 → 链路自然停止」这个说法是错的，主链路会带着这条空数据继续往下跑。

因此占位节点后面固定接一个 Code 节点 `Claimed?`：

```js
// 两个职责，都必要：
//  1. key 没拿到就停（0 行会被 Postgres 节点变成 { success: true }，只能靠过滤停）
//  2. 把原始 payload 放回去（占位节点的输出是 SQL 行，不放回去下游就读不到字段）
return items
  .filter((item) => item.json && item.json.key)
  .map((item) => ({
    json: Object.assign({}, item.json.payload || {}, { claimKey: item.json.key }),
  }));
```

闸门只连 true 分支（`main[0]`），没有 false 分支：过滤成空数组后，后续节点自然不会执行。

### 3.3 收尾（Mark Done）：成功后落章

最后一个成功节点后面接 `Mark Done`：

```sql
UPDATE processed_keys
SET status = 'done',
    updated_at = now()
WHERE key = $1
RETURNING key
```

参数替换：`={{ $('Claim Key').first().json.key }}`（用占位节点的输出，不重算 key，避免两处逻辑漂移）。

`Mark Done` 只挂在**成功终点**上：中途失败时它不执行，key 会停留在 `claimed`，10 分钟后可被重新认领 —— 这正是「失败可重试」与「成功不重发」的分界。

### 3.4 eventId 的构造规则

每个模板在 Code 节点里定义：

| 模板 | eventId 组成 |
|---|---|
| lead-routing | `email::source` |
| invoice-parsing | `messageId::attachmentName` |
| support-triage | `ticketId` |
| rss-summary | `feedGuid` 或 `link` 的哈希 |
| sheets-notion-sync | `sheetRowId::updatedAt` |
| daily-digest | `date`（每天只发一次） |

**为什么不用 Code 节点「先查后写」判断**：先查询再写入在并发与重试下有竞态（race condition），数据库唯一约束才是原子保证。

---

## 节点命名规范

| 用途 | 命名 |
|---|---|
| 触发器 | `Lead In` / `Ticket In` / `Every Hour` / `Daily 09:00` |
| 数据清洗 | `Normalise X` |
| 幂等占位 | `Claim Key`（daily-digest 里叫 `Claim Today`） |
| 幂等闸门 | 一律叫 `Claimed?` |
| 幂等收尾 | 一律叫 `Mark Done` |
| 外部写操作 | `Push to CRM` / `Save Ticket` / `Create Notion Page` |
| 分支 | `Confident?` / `Changed?` |
| 错误落表 | 一律叫 `Log Error`（每个模板固定一个） |
| 说明便签 | `Sticky Note` |

**每个模板只能有一个 `Log Error` 节点**，所有错误分支都连到它，便于客户在一个地方看全部失败。

---

## 凭证（Credentials）约定

模板内一律使用占位符，**不写入任何真实密钥**：

```text
YOUR_DEEPSEEK_API_KEY
C0000000000            # Slack 频道占位 ID
YOUR_NOTION_DATABASE_ID
YOUR_SHEET_ID_HERE
YOUR_SMTP_ACCOUNT
YOUR_CRM_DOMAIN
```

**Slack 频道为什么不用 `YOUR_SLACK_CHANNEL_ID`**：Slack 节点的频道 ID 有格式校验（正则 `^(?:[CGD][A-Z0-9]{2,}|#?[a-z0-9_\-]{2,})$`），写成 `YOUR_SLACK_CHANNEL_ID` 会让整条工作流被判为「has issues」，n8n 直接拒绝执行与激活，连错误分支都进不去。改成格式合法的占位 ID 后，模板能正常激活；真跑时 Slack 返回鉴权/频道不存在，走错误分支落表，客户看到的是一条明确的失败记录，而不是一个打不开的工作流。

导入后客户需要在 n8n 里自建对应凭证，再回到节点里选中。每个模板的 `README.md` 都列出了所需凭证清单。

---

## 导入方式

单个导入：

```bash
docker compose exec n8n n8n import:workflow --input=/data/templates/lead-routing/workflow.json
```

全部导入（Windows PowerShell）：

```powershell
$names = @('lead-routing','invoice-parsing','support-triage','rss-summary','sheets-notion-sync','daily-digest')
foreach ($n in $names) {
    docker compose exec -T n8n n8n import:workflow --input="/data/templates/$n/workflow.json"
}
```

导入后工作流默认是**未激活**状态，需要在 n8n 编辑器里逐个检查凭证并手动激活。
