# 任务、申请与奖励

> 以代码为准:[`lib/rice/tasks.ex`](../lib/rice/tasks.ex)、
> [`lib/rice/tasks/application_state.ex`](../lib/rice/tasks/application_state.ex)。
> 本文说明它们之间的关系,不重复实现细节。

## 两层状态机

任务(`tasks.status`)和申请(`task_applications.status`)各有一个状态机,**申请是每个人的真实状态,
任务状态由它们决定**。

### 申请:`task_applications.status`

```
pending ──指派──▶ appointed ──提交──▶ under_review ──通过──▶ completed
   │                 │  ▲                 │
   │                 │  └───要求修改──────┘
   │                 └─超期─▶ overdue ──提交──▶ under_review
   ├──拒绝──▶ rejected
   ├──名额满 / 申请截止──▶ not_selected   (申请重新开放时可回到 pending)
   └──任务取消 / 过期──▶ cancelled / expired
```

- 终态:`completed`、`rejected`、`cancelled`、`expired`。
- **所有改状态的地方都经过 `Rice.Tasks.move_applications/4`**,它只放行
  `Rice.Tasks.ApplicationState.transitions/0` 里列出的迁移,非法迁移不改动任何行。
- 数据库约束 `task_applications_status` / `task_applications_status_fields` 保证取值合法,
  且 `appointed_at` / `rejected_at` 与状态一致。
- 重新开放任务会进入下一轮(`round + 1`),旧一轮的申请归档(写 `final_status`),只看当前轮。

### 任务:`tasks.status`

`draft → open → in_progress → under_review → completed`,另有 `overdue`、`expired`、`cancelled`。

| | 单人(`capacity = 1`) | 多人(`capacity > 1`) |
| --- | --- | --- |
| 承接人 | `tasks.assignee_id` | 没有,`assignee_id` 恒为空(有约束) |
| 任务状态 | 被指派的那一个申请的状态,同名对应 | 所有已指派申请状态的**汇总** |
| 同步方式 | 每次任务状态变化,在同一事务内同步那一个申请 | 个人状态独立流转,任务状态随后聚合 |

单人对应:`open ↔ pending`、`in_progress ↔ appointed`、`overdue`、`under_review`、`completed` 同名;
取消/过期时所有 `pending` 申请变 `cancelled` / `expired`;指派时其余申请变 `not_selected`。

多人汇总规则(`aggregate_multi_status`),**最差者优先**:

1. 有人 `overdue` → `overdue`;
2. 否则有人 `under_review` → `under_review`;
3. 否则 → `in_progress`;
4. 全部已指派的人都 `completed`,**并且**(名额已满 **或** 申请已截止)→ `completed`。

因此任务状态不能用来判断某个人能做什么,个人动作一律看自己的申请状态(`my_status`)。
`appointed` / `overdue` 以交付截止时间实时判断,落库的 `overdue` 由定时任务
(`check_due_tasks`)和编辑任务时追平。

## 多人承接的数据在哪

| 表 | 内容 |
| --- | --- |
| `task_applications` | 每个申请人一行:`status`、`appointed_at`、`appointment_reason`、`reward_slot`(1..capacity,`(task_id, round, reward_slot)` 唯一)、`rejected_at` |
| `task_submissions` | 每人每轮的交付成果,各自审核 |
| `grain_receipts` | 每个名额一条冻结/结算/退款记录,`subject_uri` 形如 `rice://tasks/<id>/slots/<n>` |
| `tasks` | `capacity`、汇总状态;单人任务另有 `assignee_id` |

## 奖励

- `reward_amount` 是**每人**的奖励。发布时从**节点账户**(`funding_node_id`)一次性冻结
  `reward_amount × capacity`,不是发布者个人余额。节点余额不足,发布返回 422。
- 每个名额在指派时分配 `reward_slot`;该人验收通过时只结算他那一份。
- 任务整体完成时,没有用上的名额按份退回节点。
- 任务 `reward_status` 在部分结算期间保持 `reserved`,完成后才是 `settled`;个人结算以
  `grain_receipts` 为准。

## 发布后能改什么

| 任务状态 | 奖励 / 人数 / 所属节点 | 其他字段 |
| --- | --- | --- |
| `draft` | 可改 | 可改 |
| `open` / `in_progress` / `overdue` / `under_review` | **不可改**(422) | 可改 |
| `expired` / `cancelled`(编辑即重新开放) | 可改,按新的 `单价 × 人数` 重新冻结,`round + 1` | 可改 |

已有人被指派后,奖励与人数就锁死。把申请截止时间改到过去可以提前收尾:已指派的人都完成时,
任务立即完成并退回剩余名额(这是副作用而非专门的功能)。

## 接口

申请对象有两个状态字段:

- `status`:**粗粒度**,给现有前端用。取值 `pending` / `appointed` / `not_selected` /
  `cancelled` / `expired`(`appointed` 包含 overdue、under_review、completed;`rejected` 显示为
  `not_selected`)。
- `state`:**细粒度**,即 `task_applications.status` 本身。

## 迁移

任务相关的三份迁移合并为 `priv/repo/migrations/20261009000000_add_task_capacity_and_application_status.exs`
(节点发放唯一索引、`capacity` / `reward_slot`、申请 `status` 及回填)。`down` 不可用。
已经跑过合并前两份旧迁移(`20261007120000`、`20261008065240`)的库无法再跑它,需要重建。
