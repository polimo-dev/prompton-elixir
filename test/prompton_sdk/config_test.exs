defmodule PromptOnSDK.ConfigTest do
  use ExUnit.Case, async: false

  alias PromptOnSDK.Config

  doctest PromptOnSDK.Config

  setup do
    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:prompton_sdk) do
        Application.delete_env(:prompton_sdk, key)
      end
    end)
  end

  test "defaults" do
    config = Config.load([])

    assert config.mode == :live
    assert config.poll_interval == 30_000
    assert config.api_key == nil
    assert config.base_url == nil
    assert config.disk_cache == nil
    assert config.bundle == nil
    assert config.client == PromptOnSDK.Client.Req
    assert config.hash_end_user == false
    assert config.environment == "production"
    assert config.env_slug == "production"

    assert config.log == %{
             flush_interval: 2_000,
             flush_size: 100,
             flush_bytes: 1_000_000,
             max_buffer: 10_000,
             redact: nil
           }

    assert config.http == [receive_timeout: 5_000]
    assert config.payload_defaults == %{mode: :full, sample_rate: 1.0, max_bytes: 262_144}
  end

  test "opts override application env" do
    Application.put_env(:prompton_sdk, :api_key, "ptn_myapp_abc")
    Application.put_env(:prompton_sdk, :environment, "staging")
    Application.put_env(:prompton_sdk, :base_url, "https://staging.example/api/v1/")
    Application.put_env(:prompton_sdk, :log, flush_size: 5)

    config =
      Config.load(base_url: "https://prod.example/api/v1", bundle: "priv/x.json", mode: :offline)

    assert config.api_key == "ptn_myapp_abc"
    assert config.environment == "staging"
    assert config.env_slug == "staging"
    assert config.base_url == "https://prod.example/api/v1"
    assert config.bundle == {:file, "priv/x.json"}
    assert config.mode == :offline
    assert config.log.flush_size == 5
    assert config.log.flush_interval == 2_000
  end

  test "http opts keep receive_timeout default and pass extras through" do
    config = Config.load(http: [plug: :some_plug, receive_timeout: 100])
    assert Keyword.get(config.http, :plug) == :some_plug
    assert Keyword.get(config.http, :receive_timeout) == 100
  end

  test "the environment comes from config, not from the key prefix" do
    # Keys are per project (2026-09-01); the prefix is not parsed.
    config = Config.load(api_key: "ptn_heydiary_k3jd9")
    assert config.environment == "production"
    assert Config.default_environment() == "production"

    assert Config.load(api_key: "ptn_heydiary_k3jd9", environment: "staging").env_slug ==
             "staging"
  end

  test "validation errors" do
    assert_raise ArgumentError, ~r/mode/, fn -> Config.load(mode: :nope) end
    assert_raise ArgumentError, ~r/poll_interval/, fn -> Config.load(poll_interval: 0) end
    assert_raise ArgumentError, ~r/bundle/, fn -> Config.load(bundle: 123) end
    assert_raise ArgumentError, ~r/log.flush_size/, fn -> Config.load(log: [flush_size: -1]) end
    assert_raise ArgumentError, ~r/redact/, fn -> Config.load(log: [redact: :nope]) end
    assert_raise ArgumentError, ~r/api_key/, fn -> Config.load(api_key: 1) end
  end

  test "get/0 falls back to app env when supervisor never stored a config" do
    Config.erase()
    Application.put_env(:prompton_sdk, :mode, :test)
    assert Config.get().mode == :test
    assert Config.mode() == :test
  end
end
