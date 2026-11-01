# invoice-parsing · 发票结构化解析

把发票 PDF 变成结构化字段，够可信就进财务系统，不够可信就进人工复核队列。

## 触发方式

Webhook，`POST http://localhost:5678/webhook/invoice-parsing`

```json
{
  "messageId": "<abc123@mail.example.com>",
  "attachmentName": "invoice-2026-10.pdf",
  "fileUrl": "https://your-storage.example.com/invoice-2026-10.pdf",
  "vendorHint": "Acme Ltd"
}
```

**换成邮件触发**：把 `Invoice In` 节点替换成 IMAP / Gmail 触发节点即可，后面的链路完全不动。这就是把它拆成 Webhook + 单独一个 PDF 节点的原因——邮件触发在不同客户环境里凭证差异最大，单独隔离出来最容易替换。

## 流程

```
Invoice In (Webhook)
  -> Normalise Invoice (Code)    key = messageId::attachmentName
  -> Claim Key (Postgres)
  -> PDF to Text (HTTP)          PDF 转文本，占位服务
  -> LLM Extract (HTTP)          结构化抽取，强制 JSON
  -> Parse & Score (Code)        confidence = 填满的核心字段 / 5
  -> Confident? (IF) >= 0.8
         ├─ true  -> Push to Accounting (HTTP)
         └─ false -> Queue for Review (Postgres)
                └─ 任一失败 -> Log Error
```

## 需要的凭证 / 外部服务

| 项 | 说明 |
|---|---|
| Postgres | 容器自带 |
| PDF 转文本服务 | `PDF to Text` 的 URL 换成你自己的（pdf.co / Adobe Extract / 自建 `pdftotext` 服务都行） |
| DeepSeek | `predefinedCredentialType: httpHeaderAuth` |
| 财务系统 | `Push to Accounting` 的 URL 换成你的接收端 |

## 失败时会怎样

| 失败点 | 行为 |
|---|---|
| 缺 `messageId` / `fileUrl` | Code 节点抛错，执行历史可见 |
| PDF 服务超时 | 重试 3 次，仍失败进 `Log Error`，**不进复核队列**（因为连文本都没有，人工也没东西看） |
| LLM 返回 429 | 重试 3 次后进 `Log Error` |
| **LLM 只抽出一半字段** | 不报错。`confidence < 0.8` → 进 `review_queue`，`reason` 写明缺哪几个字段 |
| 财务系统返回 5xx | 重试 3 次后进 `Log Error`，`processed_keys` 里留有 payload 可人工重放 |
| 同一封邮件重复触发 | `Claim Key` 返回 0 行，链路停止 |

## confidence 怎么算的

```
confidence = 已填的核心字段数 / 5
核心字段：vendor, invoice_number, invoice_date, currency, total_amount
```

0.8 的阈值意味着**只允许缺 1 个核心字段**。想更严格就把 IF 节点的右值改成 `1.0`，想放宽改 `0.6`。

## 改字段的地方

1. `Normalise Invoice` 的 `body.*` 路径
2. `LLM Extract` 里的 `content` 提示词——把字段清单换成你业务需要的
3. `Parse & Score` 的 `CORE` 数组，必须与提示词里的字段名保持一致

## 已知边界

- 不做多页表格的跨页合并
- 不做发票重复报销校验（那需要和财务库对账）
- 图片型发票依赖 PDF 服务先做 OCR，模板本身不内置 OCR
