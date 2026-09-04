defmodule PromptOnSDKTest do
  use ExUnit.Case, async: true

  test "core modules are loaded" do
    for mod <- [
          PromptOnSDK,
          PromptOnSDK.UseCase,
          PromptOnSDK.Result,
          PromptOnSDK.UseCaseDocument,
          PromptOnSDK.Template,
          PromptOnSDK.StopKind,
          PromptOnSDK.Params
        ] do
      assert Code.ensure_loaded?(mod), "#{inspect(mod)} not loaded"
    end
  end
end
