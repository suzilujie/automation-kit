# AutomationKit

6 个可直接导入的 n8n 工作流模板，每个都自带**失败重试**、**错误分支**、**幂等去重**。

面向 Upwork 客户交付，对应 Project Catalog 服务包（$95 / $190 / $380）。

---

## 一分钟启动

**前置**：装了 Docker Desktop，并且它正在运行。

```bat
双击 start.bat
```

或者命令行：

```powershell
.\start.ps1
```

首次运行会：

1. 自动生成 `.env`（含随机的 n8n 加密密钥与数据库密码）
2. 拉取镜像（n8n 约 1.5 GB，只需一次）
3. 启动 n8n（端口 **5678**）与 Postgres（端口 **5433**）
4. 等 n8n 健康检查通过后打印访问地址

打开 `http://localhost:5678`，首次访问会让你创建管理员账号（本地库，随意设）。

---

## 6 个模板

| 模板 | 触发 | 作用 | 外部依赖 |
|---|---|---|---|
| `lead-routing` | Webhook | 线索去重 → 写 CRM → 通知销售群 | CRM 接口、Slack |
| `support-triage` | Webhook | 工单 LLM 分类 → 按类别发到对应频道 | DeepSeek、Slack |
| `invoice-parsing` | Webhook（可换邮件） | 发票 PDF → 结构化字段 → 高置信入库 / 低置信复核 | PDF 服务、DeepSeek、财务系统 |
| `rss-summary` | 定时（每小时） | RSS 新文章 → LLM 摘要 → 写 Notion | DeepSeek、Notion |
| `sheets-notion-sync` | 定时（每 15 分钟） | 表格改动 → 建 Notion 记录 | Google Sheets、Notion |
| `daily-digest` | 定时（每天 09:00） | 查本地库 → LLM 写简报 → 邮件 | DeepSeek、SMTP |

每个模板目录下都有 `workflow.json` 与一份 `README.md`（说明依赖、凭证、失败行为、改哪些字段）。

---

## 导入模板

单个：

```bash
docker compose exec n8n n8n import:workflow --input=/data/templates/lead-routing/workflow.json
```

全部（PowerShell）：

```powershell
$names = @('lead-routing','invoice-parsing','support-triage','rss-summary','sheets-notion-sync','daily-digest')
foreach ($n in $names) {
    docker compose exec -T n8n n8n import:workflow --input="/data/templates/$n/workflow.json"
    Write-Host "imported $n"
}
```

导入后工作流默认**未激活**。需要在编辑器里逐个：

1. 建好所需凭证（Credentials）
2. 在节点里选中凭证
3. 手动点 Publish（n8n 2.x 里「激活」按钮叫 Publish）

---

## 三条工程契约

所有模板必须遵守，详见 [`templates/_shared/README.md`](templates/_shared/README.md)：

| 契约 | 做法 | 为什么 |
|---|---|---|
| **重试** | 外部调用节点开 `retryOnFail`，3 次 / 间隔 3 秒 | 第三方接口抖动是常态，不重试等于把偶发故障甩给客户 |
| **错误分支** | 节点 `onError: continueErrorOutput` + 错误输出接 `Log Error`；落库时用 `$prevNode.name` 记出错节点 | 失败必须留痕，不能静默；错误 item 里没有 `node` 字段，写 `$json.node.name` 只会得到 `unknown` |
| **幂等** | `processed_keys` 三节点：`Claim`（租约式占位）→ `Claimed?`（闸门）→ `Mark Done`（成功落章） | 只靠 `ON CONFLICT DO NOTHING` 有两个坑：失败的 key 会被永久占死；0 行时 Postgres 节点仍输出 `{success:true}`，链路根本停不下来 |

---

## 数据表

首次启动时由 `sql/init.sql` 自动创建：

| 表 | 用途 |
|---|---|
| `processed_keys` | 幂等键 + 状态。`status` 为 `claimed`（已占位，10 分钟租约）或 `done`（已成功，永久去重） |
| `workflow_errors` | 错误落表。所有模板共用一个 `Log Error` 节点写入，`node` 列是实际失败的节点名 |
| `review_queue` | 低置信度结果排队等人工处理（发票解析在用） |

查看今天出了哪些错：

```powershell
docker compose exec -T postgres psql -U autokit -d autokit -c "select workflow, node, message, created_at from workflow_errors order by created_at desc limit 20;"
```

---

## 目录结构

```
automation-kit/
├── start.bat / start.ps1        一键启动
├── docker-compose.yml           n8n 2.45.0 + Postgres 17
├── .env.example                 环境变量样例
├── sql/init.sql                 幂等表 / 错误表 / 复核队列表
├── templates/                   6 个模板 + _shared 契约
├── site/templates.html          给客户看的模板目录页
└── docs/
    ├── system-design.html       系统设计文档
    ├── reliability.html         可靠性保障（四层防线 / 5 个实跑用例 / 12 项静态断言）
    └── page-design.html         目录页设计文档
```

---

## 常见操作

```powershell
# 看日志
docker compose logs -f ak-n8n

# 停掉（保留数据）
docker compose down

# 停掉并清空所有数据（重新初始化数据库）
docker compose down -v

# 进数据库
docker compose exec postgres psql -U autokit -d autokit
```

---

## 边界与已知限制

- **Webhook 是明文 HTTP**：生产环境请在前面挂 Nginx / Caddy 做 TLS
- **凭证需自建**：模板里只有占位符，不含任何真实密钥
- **`rss-summary` 先占位后调用**：失败的文章需要人工从 `workflow_errors` 重放，换取的是「不漏也不重」
- **`sheets-notion-sync` 是单向同步**：表格为唯一事实来源，Notion 的编辑不回写
- **不做多租户**：这是单团队自托管工具，一个实例一个团队
