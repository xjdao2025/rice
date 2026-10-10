defmodule Rice.FakeGreen do
  @moduledoc false
  # 阿里云内容安全的返回体,按真实接口录的形状;请求逐条记下来给断言用
  def post(url, form) do
    send(self(), {:green, url, form})
    params = Jason.decode!(form["ServiceParameters"])

    case {form["Action"], params} do
      {_, %{"content" => "宕机"}} ->
        {:error, :timeout}

      {"TextModerationPlus", %{"content" => content}} ->
        {:ok, %{"Code" => 200, "Data" => text_result(content)}}

      {"ImageModeration", %{"imageUrl" => url}} ->
        {:ok,
         %{
           "Code" => 200,
           "Data" =>
             if(url =~ "bad",
               do: %{
                 "RiskLevel" => "high",
                 "Result" => [%{"Label" => "pornographic_adult", "Description" => "疑似色情"}]
               },
               else: %{"RiskLevel" => "none", "Result" => [%{"Label" => "nonLabel"}]}
             )
         }}
    end
  end

  defp text_result(content) do
    cond do
      content =~ "领导人" ->
        %{
          "RiskLevel" => "high",
          "Result" => [%{"Label" => "political_figure", "Description" => "疑似政治人物"}]
        }

      # 带链接的正常帖子:这个服务一律标成引流,要放行
      content =~ "https://" ->
        %{
          "RiskLevel" => "high",
          "Result" => [%{"Label" => "pt_to_contact", "Description" => "疑似引流广告号"}]
        }

      true ->
        %{"RiskLevel" => "none", "Result" => [%{"Label" => "nonLabel"}]}
    end
  end
end
