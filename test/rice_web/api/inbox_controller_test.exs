defmodule RiceWeb.Api.InboxControllerTest do
  use RiceWeb.ConnCase, async: true

  test "business inbox pages only the current recipient's notifications" do
    {recipient, token} = user_with_token()
    {other, other_token} = user_with_token()

    ids =
      for number <- 1..5 do
        {:ok, notification} =
          Rice.Inbox.notify(
            Rice.Repo,
            recipient.id,
            other.id,
            "community_approved",
            "通知 #{number}",
            "node",
            Rice.Tsid.generate()
          )

        notification.id
      end

    {:ok, foreign} =
      Rice.Inbox.notify(
        Rice.Repo,
        other.id,
        recipient.id,
        "community_approved",
        "别人的通知",
        "node",
        Rice.Tsid.generate()
      )

    assert length(Rice.Inbox.list(recipient)) == 5
    uri = fn id -> "business-notification:#{id}" end

    first =
      build_conn() |> authed(token) |> get(~p"/api/notifications?limit=2") |> json_response(200)

    assert Enum.map(first["notifications"], & &1["uri"]) ==
             Enum.map([Enum.at(ids, 4), Enum.at(ids, 3)], uri)

    assert first["cursor"] == Enum.at(ids, 3)

    second =
      build_conn()
      |> authed(token)
      |> get(~p"/api/notifications?limit=2&before=#{first["cursor"]}")
      |> json_response(200)

    assert Enum.map(second["notifications"], & &1["uri"]) ==
             Enum.map([Enum.at(ids, 2), Enum.at(ids, 1)], uri)

    assert second["cursor"] == Enum.at(ids, 1)

    last =
      build_conn()
      |> authed(token)
      |> get(~p"/api/notifications?limit=2&before=#{second["cursor"]}")
      |> json_response(200)

    assert Enum.map(last["notifications"], & &1["uri"]) == [uri.(hd(ids))]
    assert last["cursor"] == nil

    other_page =
      build_conn()
      |> authed(other_token)
      |> get(~p"/api/notifications?limit=2")
      |> json_response(200)

    assert Enum.map(other_page["notifications"], & &1["uri"]) == [uri.(foreign.id)]
    assert other_page["cursor"] == nil

    invalid =
      build_conn()
      |> authed(token)
      |> get(~p"/api/notifications?limit=2&before=invalid")
      |> json_response(200)

    assert invalid == first
  end
end
