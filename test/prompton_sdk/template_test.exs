defmodule PromptOnSDK.TemplateTest do
  use ExUnit.Case, async: true

  alias PromptOnSDK.{Fixtures, Template}

  @numbered "Please write a diary entry based on these voice transcriptions:\n\n{% for t in transcriptions %}{{ forloop.index }}. {{ t }}\n\n{% endfor %}"

  describe "golden: HeyDiary numbered/1" do
    test "renders byte-identical to the hand-written numbered list" do
      assert {:ok, out} = Template.render(@numbered, %{"transcriptions" => ["a", "b"]})

      assert out ==
               "Please write a diary entry based on these voice transcriptions:\n\n1. a\n\n2. b\n\n"
    end

    test "empty list renders only the header" do
      assert {:ok, out} = Template.render(@numbered, %{transcriptions: []})
      assert out == "Please write a diary entry based on these voice transcriptions:\n\n"
    end

    test "the fixture diary template renders each mode" do
      tpl = Fixtures.diary_user_template()

      assert {:ok, fresh} = Template.render(tpl, %{mode: "fresh", transcriptions: ["a", "b"]})

      assert fresh ==
               "Please write a diary entry based on these voice transcriptions:\n\n1. a\n\n2. b\n\n"

      assert {:ok, inc} =
               Template.render(tpl, %{
                 mode: "incremental",
                 transcriptions: ["c"],
                 existing_diary: "Dear diary"
               })

      assert inc ==
               "Here is the existing diary:\n\nDear diary\n\nAppend these new voice transcriptions:\n\n1. c\n\n"

      assert {:ok, edit} = Template.render(tpl, %{mode: "edit", user_content: "shorter please"})
      assert edit == "Edit the diary below according to the user's request.\n\nshorter please"
    end
  end

  describe "parse/2 and render/3" do
    test "parse returns a Solid.Template usable by render" do
      assert {:ok, %Solid.Template{} = parsed} = Template.parse("Hi {{ name }}!")
      assert {:ok, "Hi Ana!"} = Template.render(parsed, %{"name" => "Ana"})
      assert {:ok, "Hi Ana!"} = Template.render(parsed, %{name: "Ana"})
    end

    test "parse rejects tags outside the whitelist" do
      assert {:error, %Solid.TemplateError{}} = Template.parse("{% capture x %}a{% endcapture %}")

      assert {:error, {:parse, %Solid.TemplateError{}}} =
               Template.render("{% comment %}a{% endcomment %}", %{})
    end

    test "no escaping — raw substitution" do
      assert {:ok, "<b>&\"'</b>"} = Template.render("{{ x }}", %{x: "<b>&\"'</b>"})
    end

    test "non-string values render like Liquid" do
      assert {:ok, "3 1.5 true "} =
               Template.render("{{ i }} {{ f }} {{ b }} {{ n }}", %{i: 3, f: 1.5, b: true, n: nil})

      assert {:ok, "ab"} = Template.render("{{ list }}", %{list: ["a", "b"]})
      assert {:ok, "a, b"} = Template.render("{{ list | join: ', ' }}", %{list: ["a", "b"]})
      assert {:ok, "2"} = Template.render("{{ list | size }}", %{list: ["a", "b"]})
    end

    test "nested access, atom keys inside nested maps and lists" do
      vars = %{user: %{name: "Ana", tags: [%{label: "x"}]}}
      assert {:ok, "Ana x"} = Template.render("{{ user.name }} {{ user.tags[0].label }}", vars)
    end

    test "forloop.index / forloop.last / else / break / continue" do
      tpl =
        "{% for i in items %}{% if i == 'skip' %}{% continue %}{% endif %}{{ forloop.index }}:{{ i }}{% unless forloop.last %},{% endunless %}{% endfor %}"

      assert {:ok, "1:a,3:c"} = Template.render(tpl, %{items: ["a", "skip", "c"]})

      assert {:ok, "none"} =
               Template.render("{% for i in items %}{{ i }}{% else %}none{% endfor %}", %{
                 items: []
               })

      assert {:ok, "1"} =
               Template.render(
                 "{% for i in items %}{% if i == 2 %}{% break %}{% endif %}{{ i }}{% endfor %}",
                 %{items: [1, 2, 3]}
               )
    end

    test "assign and default" do
      assert {:ok, "B"} = Template.render("{% assign x = a | default: 'B' %}{{ x }}", %{a: nil})
      assert {:ok, "n"} = Template.render("{{ x | default: 'n' }}", %{x: nil})
      assert {:ok, "n"} = Template.render("{{ x | default: 'n' }}", %{x: ""})
    end

    test "if / elsif / else / unless" do
      tpl =
        "{% if m == 'a' %}A{% elsif m == 'b' %}B{% else %}C{% endif %}{% unless m == 'a' %}!{% endunless %}"

      assert {:ok, "A"} = Template.render(tpl, %{m: "a"})
      assert {:ok, "B!"} = Template.render(tpl, %{m: "b"})
      assert {:ok, "C!"} = Template.render(tpl, %{m: "z"})
    end

    test "engine: :raw returns the source untouched" do
      src = "keep {{ this }} and {% that %} as-is"
      assert {:ok, ^src} = Template.render(src, %{}, engine: :raw)
      assert {:ok, ^src} = Template.render(src, nil, engine: :raw)
    end
  end

  describe "strict_variables" do
    test "missing top-level variable → {:missing_variable, name}" do
      assert {:error, {:missing_variable, "name"}} = Template.render("Hi {{ name }}", %{})
    end

    test "missing nested key reports the full path" do
      assert {:error, {:missing_variable, "a.b"}} = Template.render("{{ a.b }}", %{a: %{}})
    end

    test "variables in a non-executed branch are NOT checked (measured behaviour)" do
      tpl = ~s({% if mode == "x" %}{{ missing }}{% endif %})
      assert {:ok, ""} = Template.render(tpl, %{mode: "y"})
      assert {:error, {:missing_variable, "missing"}} = Template.render(tpl, %{mode: "x"})
    end

    test "solid quirk: undefined variables in a falsy if/elsif condition are silently dropped" do
      tpl = ~s({% if mode == "x" %}{{ missing }}{% endif %})
      assert {:ok, ""} = Template.render(tpl, %{})

      assert {:ok, ""} =
               Template.render("{% if ok %}a{% elsif missing %}b{% endif %}", %{ok: false})

      # It is reported on a path where the condition evaluates to true
      assert {:error, {:missing_variable, "missing"}} =
               Template.render("{% if missing or ok %}a{% endif %}", %{ok: true})

      # unless / for / assign do report it
      assert {:error, {:missing_variable, "missing"}} =
               Template.render("{% unless missing %}a{% endunless %}", %{})

      assert {:error, {:missing_variable, "missing"}} =
               Template.render("{% for x in missing %}a{% endfor %}", %{})

      assert {:error, {:missing_variable, "missing"}} =
               Template.render("{% assign y = missing %}", %{})
    end

    test "default filter does not rescue an undefined variable, but nil is fine" do
      assert {:error, {:missing_variable, "x"}} = Template.render("{{ x | default: 'n' }}", %{})
      assert {:ok, "n"} = Template.render("{{ x | default: 'n' }}", %{x: nil})
    end

    test "first missing variable in source order is reported" do
      assert {:error, {:missing_variable, "a"}} = Template.render("{{ a }} {{ b }}", %{})
    end

    test "non-variable render errors are {:render, errors}" do
      assert {:error, {:render, [%Solid.ArgumentError{}]}} =
               Template.render("{% if x > 1 %}y{% endif %}", %{x: "s"})
    end
  end

  describe "render_messages/3" do
    test "renders each content, preserving role and other keys" do
      messages = [
        %{role: "system", content: "You are {{ persona }}."},
        %{role: "user", content: "Hi {{ name }}", name: "u1"}
      ]

      assert {:ok,
              [
                %{role: "system", content: "You are kind."},
                %{role: "user", content: "Hi Ana", name: "u1"}
              ]} = Template.render_messages(messages, %{persona: "kind", name: "Ana"})
    end

    test "string-keyed messages work too" do
      assert {:ok, [%{"role" => "user", "content" => "x=1"}]} =
               Template.render_messages([%{"role" => "user", "content" => "x={{ x }}"}], %{x: 1})
    end

    test "first failing message aborts" do
      messages = [%{role: "system", content: "ok"}, %{role: "user", content: "{{ nope }}"}]
      assert {:error, {:missing_variable, "nope"}} = Template.render_messages(messages, %{})
    end

    test "engine: :raw leaves contents untouched" do
      messages = [%{role: "user", content: "{{ raw }}"}]
      assert {:ok, ^messages} = Template.render_messages(messages, %{}, engine: :raw)
    end
  end

  describe "variables/1" do
    test "extracts top-level names, excluding loop vars, assigns and forloop" do
      assert Template.variables(Fixtures.diary_user_template()) ==
               ~w(existing_diary mode transcriptions user_content)

      assert Template.variables(
               "{% for t in items %}{{ forloop.index }} {{ t.name }} {{ sep }}{% endfor %}"
             ) ==
               ~w(items sep)

      assert Template.variables("{% assign x = a | default: b %}{{ x }} {{ y.z }}") == ~w(a b y)

      assert Template.variables("{% if flag and other == 'x' %}{{ v[idx] }}{% endif %}") ==
               ~w(flag idx other v)

      assert Template.variables("plain text") == []
    end

    test "falls back to a regex scan when parsing fails" do
      assert Template.variables("{{ a }} {% if b %}{{ c }}") == ~w(a b c)
    end
  end

  describe "lint/1" do
    test "accepts the whitelist" do
      assert :ok = Template.lint(Fixtures.diary_user_template())

      assert :ok =
               Template.lint(
                 "{% assign n = items | size %}{% for i in items %}{% if i == 1 %}{% break %}{% elsif i == 2 %}{% continue %}{% else %}{{ i | default: 'x' }}{% endif %}{% endfor %}{% unless n %}{{ items | join: ', ' }}{% endunless %}"
               )

      assert :ok = Template.lint("plain text with -}} and %} outside blocks")
      assert :ok = Template.lint("")
    end

    test "rejects whitespace control" do
      assert {:error, reasons} = Template.lint("{%- if a -%}x{% endif %}")
      assert {:whitespace_control, "{%-"} in reasons
      assert {:whitespace_control, "-%}"} in reasons

      assert {:error, [{:whitespace_control, "{{-"}]} = Template.lint("{{- a }}")
      assert {:error, [{:whitespace_control, "-}}"}]} = Template.lint("{{ a -}}")
    end

    test "rejects tags outside the whitelist" do
      assert {:error, reasons} = Template.lint("{% capture x %}a{% endcapture %}")
      assert {:disallowed_tag, "capture"} in reasons

      assert {:error, [{:disallowed_tag, "comment"} | _]} =
               Template.lint("{% comment %}a{% endcomment %}")

      assert {:error, [{:disallowed_tag, "raw"} | _]} =
               Template.lint("{% raw %}{{ a }}{% endraw %}")

      assert {:error, [{:disallowed_tag, "case"} | _]} =
               Template.lint("{% case a %}{% when 1 %}x{% endcase %}")

      assert {:error, [{:disallowed_tag, "render"} | _]} = Template.lint("{% render 'x' %}")
      assert {:error, [{:disallowed_tag, "increment"}]} = Template.lint("{% increment i %}")

      assert {:error, [{:disallowed_tag, "liquid"} | _]} =
               Template.lint("{% liquid assign a = 1 %}")
    end

    test "rejects filters outside the whitelist" do
      assert {:error, [{:disallowed_filter, "upcase"}]} = Template.lint("{{ a | upcase }}")

      assert {:error, [{:disallowed_filter, "strip"}]} =
               Template.lint("{% assign b = a | strip %}")

      assert {:error, [{:disallowed_filter, "downcase"}]} =
               Template.lint("{{ a | size | downcase }}")

      assert {:error, [{:disallowed_filter, "totally_unknown"}]} =
               Template.lint("{{ a | totally_unknown }}")
    end

    test "reports syntax errors as {:parse, message}" do
      assert {:error, [{:parse, _}]} = Template.lint("{% if a %}never closed")
      assert {:error, [{:parse, _}]} = Template.lint("{{ a ")
    end

    test "collects multiple reasons at once" do
      assert {:error, reasons} = Template.lint("{{- a | upcase }}")
      assert {:whitespace_control, "{{-"} in reasons
      assert {:disallowed_filter, "upcase"} in reasons
    end
  end

  test "allowed_tags/0 and allowed_filters/0" do
    assert Template.allowed_tags() == ~w(assign break continue for if unless)
    assert Template.allowed_filters() == ~w(size join default)
  end
end
