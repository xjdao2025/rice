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
             cond do
               url =~ "political" ->
                 %{
                   "RiskLevel" => "high",
                   "Result" => [
                     %{"Label" => "political_politicalFigure", "Description" => "疑似政治人物"}
                   ]
                 }

               url =~ "bad" ->
                 %{
                   "RiskLevel" => "high",
                   "Result" => [
                     %{"Label" => "pornographic_adultContent", "Description" => "疑似色情"}
                   ]
                 }

               true ->
                 %{"RiskLevel" => "none", "Result" => [%{"Label" => "nonLabel"}]}
             end
         }}
    end
  end

  defp text_result(content) do
    cond do
      content =~ "领导人" ->
        %{
          "RiskLevel" => "high",
          "Result" => [
            %{"Label" => "pornographic_adult", "Description" => "疑似色情内容"},
            %{"Label" => "political_figure", "Description" => "疑似政治人物"}
          ]
        }

      # 非政治类别即使高风险也放行
      content =~ "色情" ->
        %{
          "RiskLevel" => "high",
          "Result" => [%{"Label" => "pornographic_adult", "Description" => "疑似色情内容"}]
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
