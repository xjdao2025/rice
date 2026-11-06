# 信息流与业务列表的查询边界

## 信息流

`rice-front/src/features/feed/api.ts` 不再扫描点赞/转发的 `listRecords` 历史。

- 公开帖子列表仍通过 `aerox.feed.listPosts` 获取。
- 已登录读者通过 PDS 代理的 `app.bsky.feed.getPosts` 按当前帖子 URI 查询 viewer 状态：URI 去重，每批最多 25 个。
- 帖子详情直接复用已认证 `getPostThread` 的 viewer 状态，不增加互动状态请求。
- 来自其他 DID、错误 collection 或无有效记录 key 的互动 URI 不会被保留；访客的 viewer 字段被清除。
- 上游认证失败仍交给会话刷新流程；一般上游错误则返回不含 viewer 的公开帖子，不回退到全历史扫描。
- AppView 索引存在延迟，刚写入的互动可能短暂未出现在服务端回读中。现有客户端的互动成功更新不变；本次没有引入跨用户的服务端互动缓存。

作者和转发者通过 `POST /api/users/profiles` 补全，DID 去重，每批最多 100 个。

请求：`{"dids": ["did:plc:..."]}`；响应：`{"data": [...]}`。

只返回 `UserJSON.public` 字段，数据库也只选择所需的公开用户列与头像外键；不查询 Semi wallet，不返回邮箱、手机号或余额。未注册、已注销、停用用户不出现在响应中，前端继续使用 AppView 原资料。超限/畸形输入返回 422。

## 业务列表

列表记录使用只读的 `list_summary` 虚拟字段；不要把列表的关联集合误当成完整详情数据，也不要用列表快照授权后续写操作。写操作继续锁定并重读数据库记录。

### 任务

- 申请总数、是否存在可处理申请、是否存在待审成果以及最近发布时间，通过页内任务 ID 批量聚合/投影。
- 仅预加载本期承接者和当前读者自己的申请，不加载往期申请、成果正文或事件历史。
- 为兼容现有 API，`assignees` 仍返回全部本期承接者；该集合受任务容量上限 1000 约束。本次没有擅自把它截断为预览列表。
- 管理员列表动作仍根据全体申请/成果的聚合判断，不会因为未加载其他候选人而错误隐藏动作。
- 详情保持完整读取；从动作刷新详情时会清除列表 summary，防止沿用旧统计。

### 活动

- 本期申请数和已通过人数在数据库中按页聚合。
- 每项活动只预加载当前读者的最新本期申请，即使该读者多次撤销、重报，也只加载一份。
- 不加载历史记录或其他参与者名单；容量和动作判断使用聚合人数，不是部分关联数组的长度。

### 节点目录

- 只加载当前读者的 membership 和最新申请，不加载成员的用户/头像或管理员的全部申请队列。
- 节点详情和成员接口保持原有返回语义。
- 节点父目录本次仍保持现有完整目录接口；若节点总量本身增长到需要分页，应另行调整前端目录/选择器协议。

## 索引与迁移

`20261022073003_add_feed_and_list_query_indexes.exs` 增加：

1. `grain_receipts (from_user_id, id)`：个人凭证游标读取。
2. `verification_codes (channel, lower(target), inserted_at)`：按目标限额与最近发送时间。
3. `event_applications (event_id, round, user_id, id)`：包括已拒绝/撤销记录的本期计数和本人最新申请。此前同类唯一索引已变成部分索引，不能覆盖全量计数。
4. `task_submissions (task_id, round) WHERE review_reason IS NULL AND final_status IS NULL`：待审成果存在性查询。

索引使用 `CONCURRENTLY`，migration 禁用 DDL transaction 和 migration lock；必须保证同一数据库只运行一个 migrator。失败后应检查是否留下 INVALID 索引，再按数据库运维流程处理，不要盲目重复执行。迁移可逆，不更改业务数据或原有索引。

发布顺序：先后端及 migration，再前端，因为新前端依赖批量公开资料接口。本地测试已执行迁移并检查四个索引均有效；未执行生产 migration、生产 EXPLAIN 或压力测试。实际索引收益需以真实分布的脱敏副本执行计划进一步验证。

## 回归验证

- 前端 `src/features/feed/performance.test.ts`：无互动历史扫描、25 URI 批次上限、作者/转发者去重与 100 DID 批次上限、复用线程 viewer、认证错误传播。
- 后端 `test/rice_web/api/list_performance_test.exs`：公开字段边界、批量输入限制、资料查询次数恒定、列表关联读取范围、列表/详情的计数和允许动作一致。
- 后端 `test/rice/query_indexes_test.exs`：索引存在且有效。

以上仅使用本地数据库与模拟 HTTP，不调用真实 PDS、短信、邮件或生产审核服务。
