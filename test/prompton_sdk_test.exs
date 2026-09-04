defmodule PromptOnSDKTest do
  use ExUnit.Case, async: true

  test "core modules are loaded" do
    for mod <- [
          PromptOnSDK,
          PromptOnSDK.SnapshotData,
          PromptOnSDK.Resolver,
          PromptOnSDK.Resolution,
          PromptOnSDK.Template,
          PromptOnSDK.StopKind,
          PromptOnSDK.Params
        ] do
      assert Code.ensure_loaded?(mod), "#{inspect(mod)} not loaded"
    end
  end
end
