# daily-digest · 每日运营简报

每天早 9 点，把过去 24 小时的运行数字写成一份简报，邮件发出去。

## 触发方式

定时，每天 09:00（时区取 `GENERIC_TIMEZONE`，默认 Asia/Shanghai）。

## 流程

```
Daily 09:00 (Schedule)
  -> Query Last 24h (Postgres)   直接查本地库
  -> Claim Today (Postgres)      key = 日期，一天只发一次
  -> Compose Facts (Code)        把数字拼成事实清单
  -> LLM Write Digest (HTTP)
  -> Send Digest (SMTP)
         └─ error -> Log Error
```

## 为什么这个模板第一天就能跑

其余五个模板都要接外部系统才有数据，这个不用：数字全部来自本机 Postgres 里的 `processed_keys` / `workflow_errors` / `review_queue`。

也就是说，**你刚装好环境、还没接任何业务系统，就能先把这个跑通**，用来验证 SMTP 和 LLM 凭证是否配置正确。

## 需要的凭证 / 外部服务

| 项 | 说明 |
|---|---|
| Postgres | 容器自带 |
| DeepSeek | `predefinedCredentialType: httpHeaderAuth` |
| SMTP | `Send Digest` 节点，填 `fromEmail` / `toEmail`，凭证里填主机与账号 |

## 失败时会怎样

| 失败点 | 行为 |
|---|---|
| 数据库查询失败 | 重试 3 次 → `Log Error`，不发邮件 |
| 同一天重复执行 | `Claim Today` 返回 0 行，**不会发第二封** |
| LLM 失败 | 重试 3 次 → `Log Error`，不发邮件（不会发半份报告） |
| SMTP 失败 | 重试 3 次 → `Log Error`；邮件未发出，但当天 key 已被占用，需要人工删掉那行才能重发 |

> 最后一条是有意的：宁可漏发一封，也不要因为 SMTP 抖动给团队发三四封重复简报。要重发就删 key：
> `DELETE FROM processed_keys WHERE key = '2026-11-01';`

## 提示词的关键约束

```
Use ONLY the numbers given, never invent or recalculate them.
```

**数字由 SQL 算好，模型只负责措辞。**让模型做算术是这类模板最常见的出错点——它会把 3 和 5 加起来说成 9 而不报错。

## 改字段的地方

1. `Query Last 24h` 的 SQL——换成你真正关心的指标
2. `Compose Facts` 的事实清单（必须与 SQL 的列名一一对应）
3. `Send Digest` 的收件人与主题

## 已知边界

- 只发纯文本，不做 HTML 排版与图表
- 不按人个性化，一封发全组
- 不做周报/月报，改 `triggerAtHour` 与 SQL 的时间窗口即可
