defmodule Rice.ZzReview1Test do
  use Rice.DataCase, async: false
  import Ecto.Query
  alias Rice.Tasks
  alias Rice.Tasks.{Task, Event, Notification, Application, Submission}

  setup do
    Agent.start_link(fn -> {[], %{}} end, name: :rv1)
    :ok
  end

  defp label(id, name), do: Agent.update(:rv1, fn {l, m} -> {l, Map.put(m, to_string(id), name)} end)

  defp user(name) do
    u = user_fixture(%{nickname: "nick_" <> name})
    label(u.id, name)
    label(u.did, name <> "_did")
    label(u.handle, name <> "_handle")
    u
  end

  defp log(term), do: Agent.update(:rv1, fn {l, m} -> {[term | l], m} end)

  defp step(name, fun) do
    res =
      try do
        case fun.() do
          {:ok, %Task{} = t} -> {:ok, t.status}
          {:ok, other} -> {:ok, other.__struct__}
          {:error, %Ecto.Changeset{} = cs} -> {:error, :changeset, cs.errors}
          other -> other
        end
      rescue
        e -> {:raised, Exception.message(e) |> String.slice(0, 200)}
      end

    log({:step, name, res})
    res
  end

  defp past(task, field, secs \\ -3600) do
    Repo.update_all(from(t in Task, where: t.id == ^task.id),
      set: [{field, DateTime.add(DateTime.utc_now(), secs)}]
    )
  end

  defp t(task), do: Repo.get!(Task, task.id)

  defp app(task, user),
    do: Repo.one!(from a in Application, where: a.task_id == ^task.id and a.user_id == ^user.id and a.round == ^t(task).round)

  defp sub(task, user),
    do:
      Repo.one!(
        from s in Submission,
          where: s.task_id == ^task.id and s.user_id == ^user.id,
          order_by: [desc: s.id],
          limit: 1
      )

  defp snap(name, task, viewers) do
    task = t(task)
    label(task.id, "TASK")

    tk = Map.take(task, [:status, :reward_status, :assignee_id, :round, :reward_subject_uri, :appointment_reason])
    tk = Map.put(tk, :appointed_at_set, not is_nil(task.appointed_at))

    apps =
      Repo.all(from a in Application, where: a.task_id == ^task.id, order_by: [a.user_id, a.round])
      |> Enum.map(&{&1.user_id, &1.round, &1.status, &1.reward_slot, &1.final_status, not is_nil(&1.appointed_at), &1.appointment_reason})
      |> Enum.sort()

    subs =
      Repo.all(from s in Submission, where: s.task_id == ^task.id, order_by: s.id)
      |> Enum.map(&{&1.user_id, &1.round, &1.body, &1.review_reason, &1.final_status})

    events =
      Repo.all(from e in Event, where: e.task_id == ^task.id, order_by: e.id)
      |> Enum.map(&{&1.actor_id, &1.from_status, &1.to_status, &1.detail, not is_nil(&1.before)})

    notes =
      Repo.all(from n in Notification, where: n.task_id == ^task.id)
      |> Enum.map(&{&1.recipient_id, &1.actor_id, &1.event, &1.detail})
      |> Enum.sort()

    receipts =
      Repo.all(from r in Rice.Grains.Receipt, where: like(r.subject_uri, ^"rice://tasks/#{task.id}%"))
      |> Enum.map(fn r ->
        {r.kind, String.replace(r.subject_uri, ~r{/edits/[0-9A-Za-z]+}, "/edits/X"), r.amount, r.from_user_id, r.from_node_id, r.to_user_id}
      end)
      |> Enum.sort()

    json =
      for v <- viewers do
        full = Rice.Tasks.fetch_task(task.id, v)

        case full do
          {:ok, ft} ->
            {v && v.id, RiceWeb.Api.TaskJSON.show(%{task: ft, current_user: v})}

          other ->
            {v && v.id, other}
        end
      end

    list =
      for v <- viewers, v != nil, mine <- ["assigned", "applied", "managed"], st <- [nil, "in_progress", "overdue", "under_review", "completed"] do
        params = %{"mine" => mine} |> then(&if(st, do: Map.put(&1, "status", st), else: &1))
        {v.id, mine, st, Enum.any?(Tasks.list_tasks(v, params).entries, &(&1.id == task.id))}
      end

    avail = for v <- viewers, v != nil, do: {v.id, Enum.any?(Tasks.list_tasks(v, %{"available" => "true"}).entries, &(&1.id == task.id))}

    log({:snap, name, tk, apps, subs, events, notes, receipts, json, list, avail})
  end

  defp norm(%DateTime{}), do: :time
  defp norm(%NaiveDateTime{}), do: :time
  defp norm(%{__struct__: _} = s), do: s
  defp norm(m) when is_map(m), do: m |> Enum.map(fn {k, v} -> {k, norm(v)} end) |> Enum.sort()
  defp norm(l) when is_list(l), do: Enum.map(l, &norm/1)
  defp norm(t) when is_tuple(t), do: t |> Tuple.to_list() |> norm() |> List.to_tuple()
  defp norm(x), do: x

  defp dump(file) do
    {l, m} = Agent.get(:rv1, & &1)

    text =
      l
      |> Enum.reverse()
      |> Enum.map(&norm/1)
      |> Enum.map_join("\n", &inspect(&1, limit: :infinity, printable_limit: :infinity, pretty: true, width: 160))

    text =
      Enum.reduce(Enum.sort_by(m, fn {k, _} -> -String.length(k) end), text, fn {k, v}, acc ->
        String.replace(acc, k, v)
      end)

    text = Regex.replace(~r/~U\[[^\]]+\]/, text, "~U[T]")
    text = Regex.replace(~r/"[0-9a-z]{13}"/, text, "\"ID\"")
    text = Regex.replace(~r/节点\d+/, text, "节点N")
    text = Regex.replace(~r/did:plc:test\d+/, text, "did")
    File.write!(file, text)
  end

  test "trace" do
    pub = task_publisher_fixture(%{nickname: "nick_pub"})
    label(pub.id, "PUB")
    label(pub.did, "PUB_did")
    label(pub.handle, "PUB_handle")
    node = funded_node_fixture(pub, 10_000)
    label(node.id, "NODE")
    [w1, w2, w3, vis] = for n <- ~w(W1 W2 W3 VIS), do: user(n)
    viewers = [nil, pub, w1, w2, vis]
    fut = fn h -> DateTime.add(DateTime.utc_now(), h * 3600) end

    mk = fn attrs ->
      {:ok, task} =
        Tasks.create_task(pub, Map.merge(%{title: "T", description: "D", organizer_contact: "C", reward_amount: 20, application_deadline: fut.(24), execution_deadline: fut.(48)}, attrs))

      task
    end

    # A: single happy path
    a = mk.(%{})
    for w <- [w1, w2, w3], do: step("A apply", fn -> Tasks.apply(w, t(a), %{contact: "c"}) end)
    step("A reject w3", fn -> Tasks.reject_application(pub, t(a), app(a, w3).id) end)
    snap("A applied", a, viewers)
    step("A appoint w1", fn -> Tasks.appoint(pub, t(a), app(a, w1).id, %{appointment_reason: "why"}) end)
    snap("A appointed", a, viewers)
    step("A reappoint w1", fn -> Tasks.appoint(pub, t(a), app(a, w1).id) end)
    step("A appoint w2", fn -> Tasks.appoint(pub, t(a), app(a, w2).id) end)
    step("A w2 submit", fn -> Tasks.submit_result(w2, t(a), %{body: "x"}) end)
    step("A w1 submit", fn -> Tasks.submit_result(w1, t(a), %{body: "b1"}) end)
    step("A w1 submit again", fn -> Tasks.submit_result(w1, t(a), %{body: "b1"}) end)
    snap("A submitted", a, viewers)
    step("A changes", fn -> Tasks.request_changes(pub, t(a), sub(a, w1).id, "fix it") end)
    snap("A changes", a, viewers)
    step("A w1 submit2", fn -> Tasks.submit_result(w1, t(a), %{body: "b2"}) end)
    step("A approve self?", fn -> Tasks.approve_result(w1, t(a), sub(a, w1).id) end)
    step("A approve", fn -> Tasks.approve_result(pub, t(a), sub(a, w1).id) end)
    step("A reapprove", fn -> Tasks.approve_result(pub, t(a), sub(a, w1).id) end)
    step("A close completed", fn -> Tasks.close(pub, t(a)) end)
    snap("A done", a, viewers)

    # B: late submit
    b = mk.(%{})
    step("B apply", fn -> Tasks.apply(w1, t(b), %{contact: "c"}) end)
    step("B appoint", fn -> Tasks.appoint(pub, t(b), app(b, w1).id) end)
    past(b, :application_deadline, -7200)
    past(b, :execution_deadline)
    step("B late submit", fn -> Tasks.submit_result(w1, t(b), %{body: "late"}) end)
    snap("B late", b, viewers)
    step("B changes", fn -> Tasks.request_changes(pub, t(b), sub(b, w1).id, "again") end)
    snap("B changes", b, viewers)
    step("B cron", fn -> Tasks.check_due_tasks() |> elem(0) end)
    step("B submit2", fn -> Tasks.submit_result(w1, t(b), %{body: "late2"}) end)
    step("B approve", fn -> Tasks.approve_result(pub, t(b), sub(b, w1).id) end)
    snap("B done", b, viewers)

    # C: cron overdue
    c = mk.(%{})
    step("C apply", fn -> Tasks.apply(w1, t(c), %{contact: "c"}) end)
    step("C apply2", fn -> Tasks.apply(w2, t(c), %{contact: "c"}) end)
    step("C appoint", fn -> Tasks.appoint(pub, t(c), app(c, w1).id) end)
    past(c, :application_deadline, -7200)
    past(c, :execution_deadline)
    step("C cron", fn -> Tasks.check_due_tasks() |> elem(0) end)
    step("C cron2", fn -> Tasks.check_due_tasks() |> elem(0) end)
    snap("C overdue", c, viewers)
    step("C close", fn -> Tasks.close(pub, t(c)) end)
    snap("C closed", c, viewers)
    step("C reopen", fn -> Tasks.update_task(pub, t(c), %{"application_deadline" => fut.(10), "execution_deadline" => fut.(20), "reward_amount" => 7}) end)
    snap("C reopened", c, viewers)
    step("C apply w2", fn -> Tasks.apply(w2, t(c), %{contact: "c"}) end)
    step("C appoint w2", fn -> Tasks.appoint(pub, t(c), app(c, w2).id) end)
    step("C submit w2", fn -> Tasks.submit_result(w2, t(c), %{body: "r2"}) end)
    step("C approve w2", fn -> Tasks.approve_result(pub, t(c), sub(c, w2).id) end)
    snap("C round2 done", c, viewers)

    # D: edits on single
    d = mk.(%{})
    step("D apply", fn -> Tasks.apply(w1, t(d), %{contact: "c"}) end)
    step("D appoint", fn -> Tasks.appoint(pub, t(d), app(d, w1).id) end)
    past(d, :application_deadline, -7200)
    step("D edit exec past", fn -> Tasks.update_task(pub, t(d), %{"execution_deadline" => DateTime.add(DateTime.utc_now(), -60)}) end)
    snap("D overdue by edit", d, viewers)
    step("D edit extend", fn -> Tasks.update_task(pub, t(d), %{"execution_deadline" => fut.(5)}) end)
    snap("D extended", d, viewers)
    step("D edit exec past2", fn -> Tasks.update_task(pub, t(d), %{"execution_deadline" => DateTime.add(DateTime.utc_now(), -60)}) end)
    step("D edit exec nil", fn -> Tasks.update_task(pub, t(d), %{"execution_deadline" => nil}) end)
    snap("D nil deadline", d, viewers)
    step("D edit title", fn -> Tasks.update_task(pub, t(d), %{"title" => "T2"}) end)
    step("D submit", fn -> Tasks.submit_result(w1, t(d), %{body: "x"}) end)
    step("D edit while review", fn -> Tasks.update_task(pub, t(d), %{"execution_deadline" => DateTime.add(DateTime.utc_now(), -30)}) end)
    step("D changes", fn -> Tasks.request_changes(pub, t(d), sub(d, w1).id, "more") end)
    snap("D after changes", d, viewers)

    # E: expire / cancel
    e = mk.(%{})
    step("E apply", fn -> Tasks.apply(w1, t(e), %{contact: "c"}) end)
    past(e, :application_deadline)
    step("E cron", fn -> Tasks.check_due_tasks() |> elem(0) end)
    snap("E expired", e, viewers)
    e2 = mk.(%{})
    step("E2 apply", fn -> Tasks.apply(w1, t(e2), %{contact: "c"}) end)
    step("E2 cancel by w1", fn -> Tasks.cancel(w1, t(e2)) end)
    step("E2 cancel", fn -> Tasks.cancel(pub, t(e2)) end)
    snap("E2 cancelled", e2, viewers)

    # F: multi
    f = mk.(%{capacity: 2, reward_amount: 10})
    for w <- [w1, w2, w3], do: step("F apply", fn -> Tasks.apply(w, t(f), %{contact: "c"}) end)
    step("F appoint w1", fn -> Tasks.appoint(pub, t(f), app(f, w1).id) end)
    step("F appoint w2", fn -> Tasks.appoint(pub, t(f), app(f, w2).id) end)
    step("F appoint w2 again", fn -> Tasks.appoint(pub, t(f), app(f, w2).id) end)
    snap("F full", f, viewers)
    step("F release w2", fn -> Tasks.release_assignee(pub, t(f), app(f, w2).id, %{"reason" => " gone "}) end)
    step("F appoint w3", fn -> Tasks.appoint(pub, t(f), app(f, w3).id) end)
    step("F submit w1", fn -> Tasks.submit_result(w1, t(f), %{body: "m1"}) end)
    step("F approve w1", fn -> Tasks.approve_result(pub, t(f), sub(f, w1).id) end)
    step("F approve w1 again", fn -> Tasks.approve_result(pub, t(f), sub(f, w1).id) end)
    past(f, :application_deadline, -7200)
    past(f, :execution_deadline)
    step("F cron", fn -> Tasks.check_due_tasks() |> elem(0) end)
    snap("F overdue", f, viewers)
    step("F close", fn -> Tasks.close(pub, t(f)) end)
    snap("F closed", f, viewers)

    # G: zero reward single
    g = mk.(%{reward_amount: 0})
    step("G apply", fn -> Tasks.apply(w1, t(g), %{contact: "c"}) end)
    step("G appoint", fn -> Tasks.appoint(pub, t(g), app(g, w1).id) end)
    step("G submit", fn -> Tasks.submit_result(w1, t(g), %{body: "z"}) end)
    step("G approve", fn -> Tasks.approve_result(pub, t(g), sub(g, w1).id) end)
    snap("G done", g, viewers)

    log({:reconcile, Rice.Grains.reconcile().ok?})
    dump(System.get_env("TRACE_OUT") || "/tmp/rv1_trace.txt")
  end
end
