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
   │                 ├─超期─▶ overdue ──提交──▶ under_review
   │                 └─撤销指派 / 提前结束──▶ released   (overdue 同)
   ├──拒绝──▶ rejected
   ├──名额满 / 申请截止──▶ not_selected   (名额空出来或申请重新开放时回到 pending)
   └──任务取消 / 过期──▶ cancelled / expired
```

- 终态:`completed`、`released`、`rejected`、`cancelled`、`expired`。
- `released` 只在多人任务出现:被指派后又被撤销。保留 `appointed_at`,`reward_slot` 清空,
  名额(和它那份冻结)让给下一个被指派的人;对方已提交等待验收时不能撤,要先验收或退回修改。
- **所有改状态的地方都经过 `Rice.Tasks.move_applications/4`**,它只放行
  `Rice.Tasks.ApplicationState.transitions/0` 里列出的迁移,非法迁移不改动任何行。
- 数据库约束 `task_applications_status` / `task_applications_status_fields` 保证取值合法,
  且 `appointed_at` / `rejected_at` 与状态一致。
- 重新开放任务会进入下一轮(`round + 1`),旧一轮的申请归档(写 `final_status`),只看当前轮。

### 任务:`tasks.status`

`draft → open → in_progress → under_review → completed`,另有 `overdue`、`expired`、`cancelled`。

**单人任务就是 `capacity = 1` 的多人任务**,走同一套代码:申请各自迁移,任务状态随后汇总
(`aggregate_status`),**最差者优先**:

1. 没有人占着名额(都被撤销了)→ 回到 `open`,之后按申请截止由定时任务过期退款;
2. 全部占名额的人都 `completed`,**并且**(名额已满 **或** 申请已截止)→ `completed`;
3. 否则有人 `overdue` → `overdue`;
4. 否则有人 `under_review` → `under_review`;
5. 否则 → `in_progress`。

招募阶段取消 / 过期时,所有 `pending` 申请变 `cancelled` / `expired`;名额满或申请截止时其余申请变
`not_selected`。

单人任务为了接口和历史记录不变,保留了几处差别(代码里都有注释):

| | 单人(`capacity = 1`) | 多人(`capacity > 1`) |
| --- | --- | --- |
| 承接人 | 指派时写进 `tasks.assignee_id` / `appointed_at` / `appointment_reason`(约束要求) | `assignee_id` 恒为空(有约束) |
| 个人状态 `my_status` | 就是任务状态 | 自己申请的状态 |
| 招募 | 只在 `open` 时;重复指派、重复验收返回 409 | 进行中名额没满也招;重复指派、验收是幂等的 |
| 超期 | 指派时不判,由定时任务记(交付时还没记就先补记),事件带说明并提醒;退回修改回到超期不再提醒 | 每次汇总都追平,任务变成 `overdue` 时提醒 |
| 验收通过的事件 | 带发放说明(单人任务的事件说明对承接人可见) | 不带 |
| 撤销指派 | 没有,用提前结束 | 有 |
| 奖励账本 | `rice://tasks/<id>`,不分名额 | `rice://tasks/<id>/slots/<n>` |

因此任务状态不能用来判断某个人能做什么,个人动作一律看自己的申请状态(`my_status`)。
`my_status` 的 `appointed` / `overdue` 以交付截止时间实时判断,落库的 `overdue` 由定时任务
(`check_due_tasks`)、各个动作和编辑任务时追平。定时任务只在进行中的任务还有事可做时才处理它
(申请截止后仍有 `pending`、或承作人都结束了该收尾、或交付截止后还有人没记成超期),
已经处理过的不会每分钟重新加锁。

### 多人任务怎么收尾

多人任务不能像单人任务那样取消(只允许 `open` 时取消)。节点管理员有两个动作:

- **撤销指派**(`release_assignee`):某个人不交付或联系不上,把他变成 `released`。
  名额空出来后,之前因名额满而 `not_selected` 的申请重新变回 `pending`。
- **提前结束**(`close`):不等名额填满。已 `completed` 的保留,仍在承作的变 `released`,
  `pending` 的变 `not_selected`,所有没结算的名额退回节点。有人通过验收记为 `completed`,
  一个都没有记为 `cancelled`。有成果等待验收时拒绝(409),先验收或退回修改。

**单人任务**也可以提前结束:承接人超期不交时,这是唯一能把冻结的奖励退回节点的路
(取消只允许 `open`)。结果是 `cancelled`,承接人变 `released`,任务上的
`assignee_id` / `appointed_at` 清空。单人任务没有撤销指派。

## 多人承接的数据在哪

| 表 | 内容 |
| --- | --- |
| `task_applications` | 每个申请人一行:`status`、`appointed_at`、`appointment_reason`、`reward_slot`(1..capacity,`(task_id, round, reward_slot)` 唯一)、`rejected_at` |
| `task_submissions` | 每人每轮的交付成果,各自审核 |
| `grain_receipts` | 每个名额一条冻结/结算/退款记录,`subject_uri` 形如 `rice://tasks/<id>/slots/<n>`(单人任务是 `rice://tasks/<id>`) |
| `tasks` | `capacity`、汇总状态;单人任务另有 `assignee_id` |

## 谁能发任务

节点管理员,**或**平台在后台给了 `can_publish_tasks` 的用户,满足其一即可:

- 节点管理员发的任务由节点出奖励(`funding_node_id` = 节点)。
- 没有可管节点、但有 `can_publish_tasks` 的人发的任务没有节点,奖励从**自己的**
  稻米冻结(`funding_node_id` 为 nil),由本人管理。不能借这个授权动用任何节点的稻米。

## 奖励

- `reward_amount` 是**每人**的奖励。发布时从出资方一次性冻结 `reward_amount × capacity`:
  节点任务从**节点账户**(`funding_node_id`),个人任务从发布者本人的余额。余额不足,发布返回 422。
- 每个名额在指派时分配 `reward_slot`(取 1..capacity 里最小的空号);该人验收通过时只结算他那一份。
  撤销指派不动账,只是把号让出来。
- 任务整体完成或提前结束时,没有结算的名额按份退回节点。
- 任务 `reward_status` 在部分结算期间保持 `reserved`,完成后才是 `settled`;个人结算以
  `grain_receipts` 为准。

## 发布后能改什么

| 任务状态 | 奖励 / 人数 / 所属节点 | 其他字段 |
| --- | --- | --- |
| `draft` | 可改 | 可改 |
| `open` / `in_progress` / `overdue` / `under_review` | **不可改**(422) | 可改 |
| `expired` / `cancelled`(编辑即重新开放) | 可改,按新的 `单价 × 人数` 重新冻结,`round + 1` | 可改 |

已有人被指派后,奖励与人数就锁死。要提前收尾用上面的「提前结束」,不要靠改截止时间。

改交付截止时间会立即重算超期:延到将来或清空(不再有截止时间),超期的任务和申请回到进行中;
单人、多人一样。

## 接口

多人任务多两个动作,都要节点管理员,什么时候可用看任务的 `allowed_actions`:

- `POST /api/tasks/:id/applications/:application_id/release`(可带 `reason`)→ `release_assignee`
- `POST /api/tasks/:id/close` → `close`

申请对象有两个状态字段:

- `status`:**粗粒度**,给现有前端用。取值 `pending` / `appointed` / `released` / `not_selected` /
  `cancelled` / `expired`(`appointed` 包含 overdue、under_review、completed;`rejected` 显示为
  `not_selected`;多人任务申请已截止但定时任务还没跑时,`pending` 先显示为 `not_selected`)。
- `state`:**细粒度**,即 `task_applications.status` 本身。

## 迁移

任务相关的三份迁移合并为 `priv/repo/migrations/20261009000000_add_task_capacity_and_application_status.exs`
(节点发放唯一索引、`capacity` / `reward_slot`、申请 `status` 及回填)。`down` 不可用。
回填只把**当前轮次**的 `assignee_id` 认作已指派;重开过的任务里同一个人旧轮次的申请仍按归档结果算。
已经跑过合并前两份旧迁移(`20261007120000`、`20261008065240`)的库无法再跑它,需要重建。
