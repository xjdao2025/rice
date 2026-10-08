# Ecto.Multi 的 struct 里有 MapSet(opaque),OTP 28 的 Dialyzer 认为
# `Multi.new() |> Multi.insert(...)` 是在"不带 opaque 的调用"里传 opaque 值。
# 这是 Ecto 类型声明与新 Dialyzer 的冲突,不是 rice 的问题。
[
  ~r/call_without_opaque Type mismatch in call without opaque term in (insert|update|run|insert_or_update)\./
]
