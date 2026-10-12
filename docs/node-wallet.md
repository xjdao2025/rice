# 节点钱包与增发

2026-10-12 本地实现：增发对象只能是节点，个人通过节点分配或其他转账取得稻米。
历史个人增发流水保留，不重写、不重复增发。

## 管理端

需要后台 `role=admin` 与当前管理员手机验证码。

- `POST /api/admin/grain_grants/challenge`：取得验证码。
- `POST /api/admin/grain_grants`：单个或批量节点增发。

```json
{
  "node_ids": ["节点TSID"],
  "amount": 100,
  "memo": "节点启动资金",
  "client_request_id": "唯一请求标识",
  "code": "短信验证码"
}
```

`amount` 为每个节点的金额；节点 ID 去重。整批在同一事务内写流水和更新余额。
相同管理员与请求标识、相同节点集合/金额/备注重试返回 200、`replayed=true`，
不会重复入账或再次消耗验证码；修改内容返回 409。首次成功返回 201。
不存在节点、非法金额、溢出或无效备注均不部分入账。旧 `to` 个人收款参数返回 422。

`POST /api/admin/nodes/:node_id/grain_grants` 保留为单节点入口；请求字段为
`amount/memo/client_request_id/code`，幂等范围是该管理员和节点，与批量入口分别计数。
重试须使用原入口与原标识。

`GET /api/admin/grain_grants` 查询新旧流水，节点接收者在 `to_node`，历史个人接收者在 `to`。

## 节点与个人流转

- `GET /api/nodes/:id/wallet`：节点管理员读节点余额与明细。
- `POST /api/nodes/:id/fund`：个人转入节点，扣个人余额，不改变发行量。
- `POST /api/nodes/:id/grain_transfers`：节点管理员将节点已有稻米分配给用户，扣节点余额，不增发。
- 节点管理员可选节点或个人钱包，默认节点钱包；个人发布者只能用自己的个人钱包。
- 任务请求 `funding_source` 为 `node` 或 `personal`；草稿可修改，发布后不能切换。
- 重开任务时重新校验出资授权，不能借超级管理员身份冻结别人的个人资金。
- 平台管理员或超级管理员的个人资金属于 User 钱包；平台角色不自动授权使用节点钱包。
- 任务退款/结算按原冻结凭证选账户，兼容历史个人出资节点任务。
- 节点活动费完成后结算到节点；节点详情和节点账本统一使用节点余额。

## 对账

增发记 `grain_transfers.kind=grant`，无付款方，接收账户为 `to_node_id`。
节点向用户分配记 `gift`，付款方为 `from_node_id`、接收方为 `to_user_id`。
冻结、退款和结算凭证记录在 `grain_receipts`。

全站用户与节点的可用余额、冻结余额之和，应等于所有历史和新增 grant 总额。
生产负责人账户中的历史节点资金如需迁入节点，须另行确认并记转账，不能复制余额或再次增发。

内部 `Rice.Grains.grant/3` 目前仅用于测试构造历史用户余额，无产品调用入口。
