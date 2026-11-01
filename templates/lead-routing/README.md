# lead-routing · 客户线索分发

表单或广告平台来线索，去重后写入 CRM，同时通知销售群。

## 触发方式

Webhook，`POST http://localhost:5678/webhook/lead-routing`

```json
{
  "email": "jane@acme.com",
  "company": "Acme",
  "source": "website-form"
}
```

## 流程

```
Lead In (Webhook)
  -> Normalise Lead (Code)      构造 eventId = email::source
  -> Claim Key (Postgres)       幂等占位，重复直接停
  -> Push to CRM (HTTP)         写 CRM
  -> Notify Sales (Slack)       通知
         └─ error -> Log Error
```

## 需要的凭证 / 外部服务

| 项 | 说明 |
|---|---|
| Postgres | 用容器自带的 `ak-postgres`，host `postgres`，port `5432` |
| CRM API | 把 `Push to CRM` 的 URL 换成你的 CRM，或任何接受 JSON 的接口 |
| Slack | 需要一个 Slack App 的 Bot Token，并拿到目标频道 ID |

**完全跑通最小依赖**：只填 Postgres 凭证、把 `Push to CRM` 指向一个测试接口（如 `https://httpbin.org/post`），Slack 节点禁用，就能验证主链路。

## 失败时会怎样

| 失败点 | 行为 |
|---|---|
| 请求缺 `email` | Code 节点抛错，工作流失败，n8n 执行历史里能看到原因 |
| CRM 返回 5xx | 自动重试 3 次，间隔 3 秒；仍失败则进 `Log Error`，写一行到 `workflow_errors` |
| Slack 发送失败 | 同上；**不会**回滚 CRM 写入（业务上线索已经落库，通知失败不影响数据） |
| 同一条线索重复推送 | `Claim Key` 返回 0 行，后续节点不执行，**调用记录不会重复** |

## 怎么改成你的字段

1. 打开 `Normalise Lead`，改 `body.email` / `body.company` / `body.source` 三个取值路径
2. `eventId` 的组成决定去重粒度：想「同一个人不同渠道只收一次」，就把 `+ '::' + source` 删掉
3. `Push to CRM` 的 `jsonBody` 按目标接口的字段名调整

## 已知边界

- 不做线索评分（scoring），那是 CRM 的职责
- 不做批量导入，一次请求一条
- Webhook 是明文 HTTP，生产环境请在前面挂 Nginx / Caddy 做 TLS
