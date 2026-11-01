# support-triage · 工单分类路由

客户工单进来，LLM 判断类别与优先级，自动发到对应的 Slack 频道，并附一段建议回复。

## 触发方式

Webhook，`POST http://localhost:5678/webhook/support-triage`

```json
{
  "ticketId": "T-1042",
  "email": "jane@acme.com",
  "text": "I was charged twice this month, please refund the second charge."
}
```

## 流程

```
Ticket In (Webhook)
  -> Normalise Ticket (Code)    取 ticketId 做幂等键
  -> Claim Key (Postgres)
  -> LLM Classify (HTTP)        返回 category / priority / summary / suggested_reply
  -> Route (Code)               解析 JSON，拼出频道名
  -> Post to Channel (Slack)
         └─ error -> Log Error
```

## 需要的凭证 / 外部服务

| 项 | 说明 |
|---|---|
| Postgres | 容器自带，host `postgres` |
| DeepSeek | 用 `predefinedCredentialType: httpHeaderAuth`，填你自己的 API Key |
| Slack | Bot Token + 频道 `support-billing` / `support-bug` / `support-howto` / `support-other` 需提前建好 |

## 失败时会怎样

| 失败点 | 行为 |
|---|---|
| 缺 `ticketId` 或 `text` | Code 节点抛错，执行历史里可见 |
| LLM 返回 429 / 5xx | 重试 3 次（间隔 3 秒），仍失败进 `Log Error` |
| **LLM 返回的不是合法 JSON** | `Route` 节点兜底成 `category=other`、`priority=p3`，**仍然会发出去**，不会卡死 |
| Slack 频道不存在 | 重试后进 `Log Error`，工单不会丢（`processed_keys` 里已留 payload） |
| 同一 ticketId 重复推送 | `Claim Key` 返回 0 行，整条链路停止，不会重复发 Slack |

## 为什么用 HTTP 节点调 LLM，不用 LangChain 节点

LangChain 相关节点版本迭代快、凭证类型多，客户环境版本不一致时最容易导入失败。用 `httpRequest` + `predefinedCredentialType: httpHeaderAuth`：

- 兼容性最好，n8n 各版本都能导入
- 换模型只改 URL 和 body（Claude / DeepSeek / 本地 Ollama 都是同一套写法）
- 输出格式由 `response_format: json_object` 约束，比链式节点的隐式解析更可控

## 改字段的地方

1. `Normalise Ticket` 里 `body.text` → 换成你的工单正文字段名
2. `Route` 里 `ALLOWED` 数组 → 换成你的分类体系
3. `Route` 里 `channelName` 拼接规则 → 换成你的频道命名习惯

## 已知边界

- 不做多轮对话，只做一次性分类
- 不做自动回复发送，建议回复只是给人看的草稿
- 分类准确率取决于提示词，模板里给的是通用四分类，垂直行业需要改提示词
