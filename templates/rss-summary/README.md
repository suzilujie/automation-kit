# rss-summary · RSS 摘要入库

每小时读一次 RSS，新文章用 LLM 摘要后写进 Notion，读过的永不重复。

## 触发方式

定时，每小时一次（`Every Hour`）。

## 流程

```
Every Hour (Schedule)
  -> Fetch Feed (RSS)
  -> Build Keys (Code)           key = guid 或 link
  -> Claim Key (Postgres)
  -> LLM Summarize (HTTP)
  -> Create Notion Page (HTTP)
         └─ error -> Log Error
```

## 需要的凭证 / 外部服务

| 项 | 说明 |
|---|---|
| RSS 源 | `Fetch Feed` 的 URL |
| Postgres | 容器自带 |
| DeepSeek | `predefinedCredentialType: httpHeaderAuth` |
| Notion | `Create Notion Page` 里的 `Authorization: Bearer YOUR_NOTION_TOKEN_HERE` 与 `YOUR_NOTION_DATABASE_ID` |

Notion 数据库需要两个属性：`Name`（title）和 `Link`（url）。

## 为什么 Notion 用 HTTP 节点而不是 Notion 节点

Notion 官方节点在不同 n8n 版本里属性映射结构改过几次，跨版本导入容易出问题。直接用 `POST /v1/pages` + `Notion-Version` 头，行为在任何版本都一致，客户改字段时也只需要看一份 Notion API 文档。

## 失败时会怎样

| 失败点 | 行为 |
|---|---|
| RSS 源不可达 | 整个执行失败，`Log Error` 不触发（没有数据）。下次定时继续 |
| 新文章 LLM 调用失败 | 重试 3 次后进 `Log Error`；**该文章的 key 已被占用**，不会在下一次重试——需要人工从 `workflow_errors` 里捞出来重放 |
| Notion 创建失败 | 同上 |
| 重复运行同一小时 | 已入库的 guid 全部命中 `Claim Key` 的冲突分支，不会产生重复页面 |
| 文章没有 guid 和 link | `Build Keys` 直接过滤掉，不入库 |

> 注意上面第 2 条是**有意的取舍**：先占位再调用，保证不漏也不重。代价是失败的文章需要人工重放。如果要「失败自动重试到成功」，把 `Claim Key` 挪到 LLM 调用之后——代价是并发时可能重复生成摘要。

## 改字段的地方

1. `Fetch Feed` 的 URL
2. `LLM Summarize` 的提示词（现在是「3 条要点 + 一句为什么重要」）
3. Notion 数据库 ID 与属性名

## 已知边界

- 只支持标准 RSS / Atom
- 不做全文抓取（`contentSnippet` 为空时摘要会很短）
- 不做去重之外的相似文章合并
