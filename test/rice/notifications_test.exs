defmodule Rice.NotificationsTest do
  @moduledoc """
  验证码外发通道。

  签名算错的表现是线上 400,通道选错的表现是"验证码永远收不到" —— 两种都不会
  在类型或编译期暴露,只能靠测试盯着。
  """
  use ExUnit.Case, async: false

  alias Rice.Notifications.{AliyunSms, Dispatcher}

  describe "阿里云签名" do
    # 参数固定时签名必须逐字节可复现,否则改动编码规则就没人发现
    @cfg [
      access_key_id: "testid",
      access_key_secret: "testsecret",
      sign_name: "乡建DAO",
      template_code: "SMS_0001"
    ]

    test "同样的输入签出同样的名字" do
      params = %{"Action" => "SendSms", "PhoneNumbers" => "13800000000"}

      a = AliyunSms.signed(params, @cfg, "fixednonce", "2026-07-28T00:00:00Z")
      b = AliyunSms.signed(params, @cfg, "fixednonce", "2026-07-28T00:00:00Z")

      assert a["Signature"] == b["Signature"]
      assert byte_size(a["Signature"]) > 0
    end

    test "换一个参数签名就变" do
      base = %{"Action" => "SendSms", "PhoneNumbers" => "13800000000"}
      other = %{"Action" => "SendSms", "PhoneNumbers" => "13800000001"}

      a = AliyunSms.signed(base, @cfg, "n", "2026-07-28T00:00:00Z")
      b = AliyunSms.signed(other, @cfg, "n", "2026-07-28T00:00:00Z")

      refute a["Signature"] == b["Signature"]
    end

    test "换一把密钥签名就变" do
      params = %{"Action" => "SendSms"}
      other_cfg = Keyword.put(@cfg, :access_key_secret, "另一把")

      a = AliyunSms.signed(params, @cfg, "n", "2026-07-28T00:00:00Z")
      b = AliyunSms.signed(params, other_cfg, "n", "2026-07-28T00:00:00Z")

      refute a["Signature"] == b["Signature"]
    end

    test "公共参数一个都不能少" do
      signed = AliyunSms.signed(%{"Action" => "SendSms"}, @cfg)

      for key <- ~w(Format Version AccessKeyId SignatureMethod SignatureVersion
                    SignatureNonce Timestamp Signature) do
        assert Map.has_key?(signed, key), "缺少公共参数 #{key}"
      end

      assert signed["Version"] == "2017-05-25"
      assert signed["SignatureMethod"] == "HMAC-SHA1"
    end

    test "每次请求的 nonce 不重复 —— 重复会被阿里云当成重放" do
      a = AliyunSms.signed(%{"Action" => "SendSms"}, @cfg)
      b = AliyunSms.signed(%{"Action" => "SendSms"}, @cfg)

      refute a["SignatureNonce"] == b["SignatureNonce"]
    end
  end

  describe "短信正文" do
    test "从正文里取出验证码" do
      assert AliyunSms.extract_code("你的验证码是 123456,30 分钟内有效") == "123456"
    end

    test "取不出验证码时不发,而不是发一条内容不对的短信" do
      assert AliyunSms.extract_code("没有数字") == nil
      assert {:error, {:unsupported_message, _}} = AliyunSms.send_sms("86", "13800000000", "没有数字")
    end
  end

  describe "通道选择" do
    test "四个必填项少一个就算没配好" do
      full = [access_key_id: "a", access_key_secret: "b", sign_name: "c", template_code: "d"]
      keys = [:access_key_id, :access_key_secret, :sign_name, :template_code]

      Application.put_env(:rice, :__test_sms__, full)
      assert Dispatcher.configured?(:__test_sms__, keys)

      for missing <- keys do
        Application.put_env(:rice, :__test_sms__, Keyword.put(full, missing, ""))
        refute Dispatcher.configured?(:__test_sms__, keys), "#{missing} 为空时不该算已配置"

        Application.put_env(:rice, :__test_sms__, Keyword.delete(full, missing))
        refute Dispatcher.configured?(:__test_sms__, keys), "缺 #{missing} 时不该算已配置"
      end
    after
      Application.delete_env(:rice, :__test_sms__)
    end

    @tag :capture_log
    test "没配置时明确失败,不伪装已发送" do
      previous = Application.get_env(:rice, Rice.Notifications.AliyunSms)
      on_exit(fn -> Application.put_env(:rice, Rice.Notifications.AliyunSms, previous) end)
      Application.delete_env(:rice, Rice.Notifications.AliyunSms)

      assert Dispatcher.send_sms("86", "13800000000", "验证码 123456") ==
               {:error, :channel_not_configured}
    end
  end
end
