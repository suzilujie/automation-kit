# sheets-notion-sync · 表格到 Notion 单向同步

每 15 分钟扫一次表格，发现改动过的行就建一条 Notion 记录，没改的跳过。

## 触发方式

定时，每 15 分钟一次（`Every 15 Min`）。

## 流程

```
Every 15 Min (Schedule)
  -> Read Rows (Google Sheets)
  -> Detect Changes (Code)       key = row_number::updated_at
  -> Claim Key (Postgres)
  -> Upsert Notion (HTTP)
         └─ error -> Log Error
```

## 单向同步是刻意的

**表格是唯一事实来源（single source of truth），Notion 只写不读。**

原因：双向同步一旦遇到「两边都改过」，就必须定义冲突解决规则，而任何自动规则都会在某个时刻悄悄覆盖掉用户的修改。单向同步没有这个问题——Notion 里的编辑不会被回写，也就永远不会丢失表格里的数据。

需要双向的场景，正确做法是给表格加一列 `synced_at`，并把 Notion 的修改当成新的一行事件来接受，而不是试图合并同一个字段。

## 需要的凭证 / 外部服务

| 项 | 说明 |
|---|---|
| Google Sheets | OAuth2 凭证，`YOUR_SHEET_ID_HERE` 换成真实表格 ID |
| 表格结构 | 至少四列：`name`、`email`、`status`、`updated_at` |
| Postgres | 容器自带 |
| Notion | Token + 数据库 ID；数据库属性：`Name`(title)、`Email`(email)、`Status`(select)、`Updated`(rich_text) |

## 失败时会怎样

| 失败点 | 行为 |
|---|---|
| 表格里某行缺 `name` 或 `email` | 该行被 `Detect Changes` 静默丢弃，不入库、不报错 |
| Google Sheets 鉴权过期 | 重试 3 次后进 `Log Error`，整轮同步失败，下一轮继续 |
| Notion 创建失败 | 重试 3 次后进 `Log Error`；下一轮会**重新尝试同一行**（key 未成功写入），不会产生重复页面 |
| 同一行被编辑两次 | `updated_at` 不同 → key 不同 → 建两条 Notion 记录（这是预期行为，代表两个版本） |
| 定时重叠执行 | 数据库唯一约束保证同版本只写一次 |

## 关于「行被编辑就会新建一条记录」

这是本模板最容易让客户困惑的地方，需要在交付时说清楚：

- 想**只保留最新版本** → 在 Notion 端按 `row_number` 去重，或改成用 `PATCH /v1/pages/{id}` 更新已有页面
- 想**保留历史版本** → 保持现状，一条 Notion 记录对应一个版本

模板默认选后者，因为历史可追溯比干净更重要；要改成更新式，需要额外存一张 `row_number → notion_page_id` 的映射表。

## 改字段的地方

1. `Read Rows` 的表格 ID 与工作表名
2. `Detect Changes` 的 `REQUIRED` 数组（必填列）
3. `Upsert Notion` 的 `jsonBody` 属性映射

## 已知边界

- 不支持删除同步（表格删行，Notion 不会删）
- 不支持超过 1000 行的表格分页（需要加 `options.returnAll`）
- 不做字段级 diff，整行变更视为一个版本
