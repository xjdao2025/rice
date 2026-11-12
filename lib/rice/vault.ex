defmodule Rice.Vault do
  @moduledoc """
  AES-256-GCM encryption for secrets stored at rest (linked-account passwords and payment app credentials).

  Ciphertext layout: `iv(12) <> tag(16) <> ciphertext`. The key is a raw 32-byte
  binary from `config :rice, Rice.Vault, key:` (decoded from `RICE_LINK_ENC_KEY`
  in `config/runtime.exs`).
  """

  @aad "rice.semi_link.v1"

  @spec encrypt(binary()) :: binary()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @spec decrypt(binary()) :: {:ok, binary()} | {:error, atom()}
  def decrypt(<<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> {:error, :decrypt_failed}
    end
  rescue
    _ -> {:error, :decrypt_failed}
  end

  def decrypt(_), do: {:error, :malformed}

  defp key do
    case Application.fetch_env!(:rice, __MODULE__)[:key] do
      k when is_binary(k) and byte_size(k) == 32 ->
        k

      other ->
        raise "Rice.Vault requires a 32-byte key (set RICE_LINK_ENC_KEY); got #{inspect(other)}"
    end
  end
end
