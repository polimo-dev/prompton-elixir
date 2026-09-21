defmodule PromptOnSDK.RequestTest do
  use PromptOnSDK.RuntimeCase, async: false

  alias PromptOnSDK.{Prompt, PromptDocument, Resolution, Resolver, Result}

  setup do
    Application.put_env(:prompton_sdk, :mode, :test)
    :ok
  end

  defp decision do
    %{
      "state" => %{
        "message" => "{{ input }}",
        "nested" => [true, 3, nil, %{"text" => "{{ input }}"}]
      },
      "questions" => %{
        "route" => %{
          "type" => "choice",
          "instructions" => ["Choose for {{ team }}", %{"value" => "{{ input }}"}],
          "criteria" => %{"{{ literal_label }}" => "{{ team }}", "other" => nil}
        },
        "urgent" => %{"type" => "noul", "instructions" => "Is this urgent?"},
        "severity" => %{
          "type" => "score",
          "instructions" => "Assess severity",
          "criteria" => ["low", "high"]
        }
      }
    }
  end

  defp resolution(kind \\ :chat) do
    %Resolution{
      prompt_key: "route",
      kind: kind,
      model: "typesafe/jev-1.13",
      provider: :openrouter,
      api: if(kind == :chat, do: :chat_completions, else: :decisions),
      request_path:
        if(kind == :chat, do: "/api/v1/chat/completions", else: "/api/alpha/decisions"),
      engine: :liquid,
      messages: [%{role: "user", content: "{{ input }}"}],
      decision: if(kind == :decision, do: decision())
    }
  end

  defp document(kind \\ "decision") do
    %{
      "schema_version" => 6,
      "environment" => "test",
      "prompts" => %{"route" => %{"id" => "p", "kind" => kind}},
      "deployments" => %{
        "route" => %{
          "id" => "d",
          "model_id" => "m",
          "revision" => 2,
          "api" => if(kind == "chat", do: "chat_completions", else: "decisions"),
          "request_path" =>
            if(kind == "chat", do: "/api/v1/chat/completions", else: "/api/alpha/decisions"),
          "template_pins" => %{"default" => "v"}
        }
      },
      "prompt_versions" => %{
        "v" => %{
          "id" => "v",
          "kind" => kind,
          "number" => 3,
          "engine" => "liquid",
          "messages" => [%{"role" => "user", "content" => "{{ input }}"}],
          "decision" => if(kind == "decision", do: decision())
        }
      },
      "models" => %{
        "m" => %{"id" => "m", "provider" => "openrouter", "model_id" => "typesafe/jev-1.13"}
      }
    }
  end

  test "chat prepares an OpenRouter body with merged params, routing and required usage" do
    r = %{
      resolution()
      | model: "openai/gpt-5-mini",
        params: %{temperature: 0.2, max_tokens: 100},
        provider_options: %{only: ["OpenAI"], allow_fallbacks: false}
    }

    assert {:ok, request} = PromptOnSDK.request(r, %{input: "hello"})

    assert request == %{
             api: :chat_completions,
             method: :post,
             path: "/api/v1/chat/completions",
             body: %{
               "model" => "openai/gpt-5-mini",
               "messages" => [%{"role" => "user", "content" => "hello"}],
               "temperature" => 0.2,
               "max_tokens" => 100,
               "provider" => %{"only" => ["OpenAI"], "allow_fallbacks" => false},
               "usage" => %{"include" => true}
             }
           }

    assert {:ok, ^request} =
             r |> Prompt.from_resolution() |> PromptOnSDK.request(%{input: "hello"})
  end

  test "OpenAI and Groq use explicit paths without OpenRouter fields" do
    for {provider, path} <- [openai: "/v1/chat/completions", groq: "/openai/v1/chat/completions"] do
      assert {:ok, %{path: ^path, body: body}} =
               PromptOnSDK.request(%{resolution() | provider: provider, request_path: path}, %{
                 input: "hi"
               })

      refute Map.has_key?(body, "usage")
      refute Map.has_key?(body, "provider")

      assert {:error, :unsupported_provider_options} =
               PromptOnSDK.request(
                 %{
                   resolution()
                   | provider: provider,
                     request_path: path,
                     provider_options: %{only: ["a"]}
                 },
                 %{}
               )
    end
  end

  test "per-call overrides merge shallowly, omit Chat nil params and preserve provider null" do
    r = %{
      resolution()
      | params: %{temperature: 0.2, max_tokens: 20},
        provider_options: %{only: ["OpenAI"]}
    }

    assert {:ok, %{body: body}} =
             PromptOnSDK.request(r, %{input: "hello"},
               params: %{temperature: nil, max_tokens: 30},
               provider_options: %{only: nil}
             )

    refute Map.has_key?(body, "temperature")
    assert body["max_tokens"] == 30
    assert body["provider"] == %{"only" => nil}

    assert {:error, {:protected_params, ["model"]}} =
             PromptOnSDK.request(r, %{}, params: %{model: "other"})

    assert {:error, :invalid_request_options} = PromptOnSDK.request(r, %{}, invented: true)

    assert {:error, :decision_options_require_decisions_api} =
             PromptOnSDK.request(r, %{}, session_id: "session")
  end

  test "Decision per-call metadata is typed and overrides deployed values" do
    r = %{resolution(:decision) | params: %{user: "deployed"}}

    assert {:ok, %{body: body}} =
             PromptOnSDK.request(r, %{input: "hi", team: "Support"},
               params: %{user: "param"},
               user: "call",
               session_id: "session",
               trace: %{name: "test"}
             )

    assert body["user"] == "call"
    assert body["session_id"] == "session"
    assert body["trace"] == %{"name" => "test"}

    for key <- [:user, :session_id, :trace] do
      expected = Atom.to_string(key)

      assert {:error, {:invalid_decision_param, ^expected}} =
               PromptOnSDK.request(r, %{}, [{key, nil}])
    end
  end

  test "Decision renders string values directly, preserving nested JSON, names, labels and types" do
    input = "quote \" and newline\n\\slash {{ untouched }}"

    assert {:ok, %{api: :decisions, path: "/api/alpha/decisions", body: body}} =
             PromptOnSDK.request(resolution(:decision), %{input: input, team: "Support"})

    assert body["state"]["message"] == input
    assert body["state"]["nested"] == [true, 3, nil, %{"text" => input}]

    assert body["questions"]["route"]["instructions"] == [
             "Choose for Support",
             %{"value" => input}
           ]

    assert body["questions"]["route"]["criteria"] == %{
             "{{ literal_label }}" => "Support",
             "other" => nil
           }

    assert body["questions"]["severity"]["type"] == "score"
    refute Map.has_key?(body, "messages")
    refute Map.has_key?(body, "usage")
    assert Jason.decode!(Jason.encode!(body)) == body
  end

  test "missing variables and raw engine behavior are shared with chat templates" do
    for r <- [resolution(), resolution(:decision)] do
      assert {:error, {:missing_variable, "input"}} = PromptOnSDK.request(r, %{})
      assert {:ok, raw} = PromptOnSDK.request(%{r | engine: :raw}, %{})
      assert Jason.encode!(raw.body) =~ "{{ input }}"
    end
  end

  test "Decision only accepts supported typed params and separate provider options" do
    r = %{
      resolution(:decision)
      | params: %{session_id: "session", trace: %{name: "test"}, user: "user"},
        provider_options: %{only: ["TypeSafe"]}
    }

    assert {:ok, %{body: body}} = PromptOnSDK.request(r, %{input: "hello", team: "Support"})

    assert Map.take(body, ~w(session_id trace user provider)) ==
             %{
               "session_id" => "session",
               "trace" => %{"name" => "test"},
               "user" => "user",
               "provider" => %{"only" => ["TypeSafe"]}
             }

    for key <- ~w(temperature tools stream max_tokens) do
      assert {:error, {:unsupported_decision_params, [^key]}} =
               PromptOnSDK.request(%{r | params: %{key => nil}}, %{})
    end

    for {key, value} <- [{"user", String.duplicate("x", 257)}, {"session_id", 1}, {"trace", []}] do
      assert {:error, {:invalid_decision_param, ^key}} =
               PromptOnSDK.request(%{r | params: %{key => value}}, %{})
    end
  end

  test "params cannot override protected body or request fields, even with nil" do
    for r <- [resolution(), resolution(:decision)],
        key <- ~w(model messages questions state provider usage api request_path method path body) do
      assert {:error, {:protected_params, [^key]}} =
               PromptOnSDK.request(%{r | params: %{key => nil}}, %{})
    end
  end

  test "metadata is mandatory and invalid or mismatched metadata is never inferred" do
    for r <- [%{resolution() | api: nil}, %{resolution() | request_path: nil}] do
      assert {:error, :missing_request_metadata} = PromptOnSDK.request(r, %{})
    end

    assert {:error, :request_kind_mismatch} =
             PromptOnSDK.request(%{resolution() | api: :decisions}, %{})

    for path <- [
          "https://evil.test/v1/chat/completions",
          "//evil.test/path",
          "/v1/chat/completions",
          "",
          123
        ] do
      assert {:error, :invalid_request_path} =
               PromptOnSDK.request(%{resolution() | request_path: path}, %{})
    end

    assert {:error, :unsupported_provider_api} =
             PromptOnSDK.request(%{resolution() | provider: :other}, %{})

    assert {:error, :unsupported_prompt_kind} =
             PromptOnSDK.request(%{resolution() | kind: :text}, %{})

    assert {:error, :missing_model} = PromptOnSDK.request(%{resolution() | model: " "}, %{})

    assert {:error, :invalid_template_engine} =
             PromptOnSDK.request(%{resolution() | engine: nil}, %{})
  end

  test "malformed params, options, messages and variables fail explicitly" do
    for params <- [[], nil, %{bad: self()}] do
      assert {:error, :invalid_params} =
               PromptOnSDK.request(%{resolution() | params: params}, %{})
    end

    assert {:error, :invalid_provider_options} =
             PromptOnSDK.request(%{resolution() | provider_options: []}, %{})

    for messages <- [
          nil,
          [],
          [%{content: "missing role"}],
          [%{role: "user", content: %{bad: "shape"}}]
        ] do
      assert {:error, :invalid_messages} =
               PromptOnSDK.request(%{resolution() | messages: messages}, %{})
    end

    assert {:error, :invalid_variables} = PromptOnSDK.request(resolution(), [])
  end

  test "Decision rejects incomplete or malformed requests before rendering" do
    invalid = [
      nil,
      %{},
      %{"state" => 1, "questions" => %{}},
      Map.put(decision(), "messages", []),
      put_in(decision(), ["state", "bad"], self()),
      put_in(decision(), ["questions", "route", "type"], "{{ type }}"),
      put_in(decision(), ["questions", "route", "criteria"], %{"x" => 1}),
      put_in(decision(), ["questions", "urgent", "criteria"], %{"true" => "yes"})
    ]

    for native <- invalid do
      assert {:error, {:invalid_decision, _}} =
               PromptOnSDK.request(%{resolution(:decision) | decision: native}, %{})
    end
  end

  test "Decision validates choice and score cardinality boundaries" do
    for count <- [1, 2, 10, 11] do
      r = %{
        resolution(:decision)
        | decision:
            put_in(
              decision(),
              ["questions", "severity", "criteria"],
              List.duplicate("level", count)
            )
      }

      result = PromptOnSDK.request(r, %{input: "hello", team: "Support"})

      if count in 2..10,
        do: assert(match?({:ok, _}, result)),
        else: assert(match?({:error, {:invalid_decision, _}}, result))
    end

    for count <- [0, 1, 255, 256] do
      choices =
        Map.new(List.duplicate(nil, count) |> Enum.with_index(), fn {value, index} ->
          {to_string(index), value}
        end)

      r = %{
        resolution(:decision)
        | decision: put_in(decision(), ["questions", "route", "criteria"], choices)
      }

      result = PromptOnSDK.request(r, %{input: "hello", team: "Support"})

      if count in 1..255,
        do: assert(match?({:ok, _}, result)),
        else: assert(match?({:error, {:invalid_decision, _}}, result))
    end
  end

  test "schema v6 preserves fields through resolution and Prompt round trip" do
    assert {:ok, decoded, []} = PromptDocument.decode(document())
    assert decoded.deployments["route"].api == :decisions
    assert decoded.prompt_versions["v"].kind == :decision
    assert {:ok, r} = Resolver.resolve(decoded, "route")
    assert r.kind == :decision
    assert r.decision == decision()
    assert r.messages == nil
    assert r == r |> Prompt.from_resolution() |> Prompt.to_resolution()
    assert {:ok, _} = PromptOnSDK.request(r, %{input: "hello", team: "Support"})
  end

  test "pinned Chat version keeps Chat API even after current authoring kind becomes Decision" do
    doc = put_in(document("chat"), ["prompts", "route", "kind"], "decision")
    assert {:ok, decoded, []} = PromptDocument.decode(doc)
    assert {:ok, r} = Resolver.resolve(decoded, "route")
    assert r.kind == :chat
    assert {:ok, %{api: :chat_completions}} = PromptOnSDK.request(r, %{input: "hi"})
  end

  test "missing v6 version kind or invalid API cannot silently become Chat" do
    doc = put_in(document("chat"), ["prompt_versions", "v", "kind"], nil)
    {:ok, data, _} = PromptDocument.decode(doc)
    {:ok, r} = Resolver.resolve(data, "route")
    assert {:error, :unsupported_prompt_kind} = PromptOnSDK.request(r, %{})
    doc = put_in(document("chat"), ["deployments", "route", "api"], "invented")
    {:ok, data, warnings} = PromptDocument.decode(doc)
    assert {:unknown_api, "invented"} in warnings
    {:ok, r} = Resolver.resolve(data, "route")
    assert {:error, :missing_request_metadata} = PromptOnSDK.request(r, %{})
  end

  test "legacy schema v5 still renders messages and refuses prepared request even with added metadata" do
    doc = Map.put(document("chat"), "schema_version", 5)
    {:ok, data, []} = PromptDocument.decode(doc)
    {:ok, r} = Resolver.resolve(data, "route")

    assert {:ok, [%{content: "hi"}]} =
             r |> Prompt.from_resolution() |> PromptOnSDK.messages(%{input: "hi"})

    assert {:error, :missing_request_metadata} = PromptOnSDK.request(r, %{input: "hi"})
  end

  test "disk and bundled v6 documents preserve prepared request metadata and native templates" do
    path = tmp_path("decision.json")
    write_snapshot_file(path, document(), %{"etag" => "v6"})

    for source <- [:disk, :bundle] do
      assert {:ok, entry} = Store.load_file(path, source, "test")
      Store.put(entry)
      assert {:ok, prompt} = PromptOnSDK.prompt("route")
      assert prompt.source == source
      assert prompt.etag == "v6"

      assert {:ok, %{api: :decisions, body: body}} =
               PromptOnSDK.request(prompt, %{input: "cached", team: "Support"})

      assert body["state"]["message"] == "cached"
    end
  end

  test "test stubs and named selection keep request and next log pinned together" do
    spec = %{
      kind: :decision,
      model: "typesafe/jev-1.13",
      api: :decisions,
      request_path: "/api/alpha/decisions",
      decision: decision()
    }

    PromptOnSDK.Test.stub("route", spec)
    PromptOnSDK.Test.stub("route", Map.put(spec, :template, "ko"))
    {:ok, prompt} = PromptOnSDK.prompt("route")

    assert {:ok, request} =
             PromptOnSDK.request(prompt, %{input: "hello", team: "Support"}, template: "ko")

    assert {:ok, result} =
             PromptOnSDK.track(
               prompt,
               %{input_decision: Map.take(request.body, ~w(state questions))},
               fn -> Result.from_decisions(response()) end
             )

    assert result.result == response()["answers"]
    assert_receive {:prompton_log, log}
    assert log["template"] == "ko"
    assert log["prompt_version_id"] == "stub-pv-route-ko"
    assert log["kind"] == "decision"
    assert log["input"]["decision"] == Map.take(request.body, ~w(state questions))
    assert Jason.decode!(log["output"]["content"]) == response()["answers"]
  end

  defp response do
    %{
      "model" => "typesafe/jev-1.13",
      "answers" => %{
        "route" => %{
          "type" => "choice",
          "choice" => "Support",
          "confidence" => 0.8,
          "probabilities" => %{"Support" => 0.8, "Sales" => 0.2}
        },
        "urgent" => %{"type" => "noul", "noul" => 0.4},
        "severity" => %{"type" => "score", "score" => 2.5}
      },
      "usage" => %{"input_tokens" => 12, "output_tokens" => 3, "cost" => 0.02}
    }
  end

  test "typed Decision results preserve full JSON and usage without losing zero values" do
    body = put_in(response(), ["answers", "urgent", "noul"], 0)
    assert {:ok, %Result{} = result} = Result.from_decisions(body)
    assert result.result == body["answers"]
    assert Jason.decode!(result.content) == body["answers"]
    assert result.raw == body
    assert result.usage.input_tokens == 12
    assert result.cost_usd == 0.02
    assert result.stop_kind == :stop

    assert {:ok, byok} =
             Result.from_decisions(
               put_in(body, ["usage"], %{
                 "input_tokens" => 0,
                 "output_tokens" => 0,
                 "cost" => 0,
                 "is_byok" => true,
                 "cost_details" => %{"upstream_inference_cost" => 0.01}
               })
             )

    assert byok.cost_usd == 0.01
  end

  test "malformed Decisions responses return an error rather than empty success" do
    for body <- [
          nil,
          %{},
          Map.delete(response(), "usage"),
          put_in(response(), ["answers"], %{}),
          put_in(response(), ["answers", "urgent", "noul"], false),
          put_in(response(), ["answers", "route", "confidence"], "bad")
        ] do
      assert {:error, :invalid_decisions_response} = Result.from_decisions(body)
    end
  end
end
