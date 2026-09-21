defmodule PromptOnSDK.Decisions do
  @moduledoc false

  alias PromptOnSDK.Template

  def normalize(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, value} -> {normalize_key(key), normalize(value)} end)

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value), do: value

  def json?(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: true

  def json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  def json?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, nested} -> is_binary(key) and json?(nested) end)

  def json?(_), do: false

  def validate(value) when is_map(value) and not is_struct(value) do
    decision = normalize(value)

    cond do
      not json?(decision) ->
        invalid("decision must contain JSON values")

      Enum.sort(Map.keys(decision)) != ["questions", "state"] ->
        invalid("decision requires only state and questions")

      not guidance?(decision["state"]) ->
        invalid("state must be a string, object, or array")

      not is_map(decision["questions"]) or map_size(decision["questions"]) == 0 ->
        invalid("questions must be a non-empty object")

      true ->
        validate_questions(decision["questions"])
    end
  end

  def validate(_), do: invalid("decision must contain state and questions")

  def render(decision, variables, engine) do
    decision = normalize(decision)

    with :ok <- validate(decision),
         {:ok, state} <- render_value(decision["state"], variables, engine),
         {:ok, questions} <- render_questions(decision["questions"], variables, engine) do
      {:ok, %{"state" => state, "questions" => questions}}
    end
  end

  defp validate_questions(questions) do
    Enum.reduce_while(questions, :ok, fn {name, question}, :ok ->
      result =
        cond do
          String.trim(name) == "" ->
            invalid("question names must be non-empty")

          not is_map(question) ->
            invalid("question #{inspect(name)} must be an object")

          Map.keys(question) -- ["type", "instructions", "criteria"] != [] ->
            invalid("question #{inspect(name)} accepts only type, instructions, and criteria")

          not guidance?(question["instructions"]) ->
            invalid("question #{inspect(name)} requires instructions")

          true ->
            validate_criteria(name, question["type"], question["criteria"])
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_criteria(_name, "noul", nil), do: :ok

  defp validate_criteria(name, "noul", criteria) when is_map(criteria) do
    if Enum.sort(Map.keys(criteria)) == ["false", "true"] and
         Enum.all?(Map.values(criteria), &guidance?/1),
       do: :ok,
       else:
         invalid("noul question #{inspect(name)} criteria must contain true and false guidance")
  end

  defp validate_criteria(name, "choice", criteria) when is_map(criteria) do
    if map_size(criteria) in 1..255 and
         Enum.all?(criteria, fn {key, value} ->
           String.trim(key) != "" and (is_nil(value) or guidance?(value))
         end),
       do: :ok,
       else:
         invalid("choice question #{inspect(name)} needs 1 to 255 choices with guidance or null")
  end

  defp validate_criteria(name, "score", criteria) when is_list(criteria) do
    if length(criteria) in 2..10 and Enum.all?(criteria, &guidance?/1),
      do: :ok,
      else: invalid("score question #{inspect(name)} needs 2 to 10 guidance values")
  end

  defp validate_criteria(name, _type, _criteria),
    do: invalid("question #{inspect(name)} has an unsupported type or criteria")

  defp render_questions(questions, variables, engine) do
    map_values(questions, &render_question(&1, variables, engine))
  end

  defp render_question(question, variables, engine) do
    guidance = Map.take(question, ["instructions", "criteria"])

    with {:ok, rendered} <- map_values(guidance, &render_value(&1, variables, engine)) do
      {:ok, Map.merge(question, rendered)}
    end
  end

  defp render_value(value, variables, engine) when is_binary(value),
    do: Template.render(value, variables, engine: engine)

  defp render_value(value, variables, engine) when is_map(value),
    do: map_values(value, &render_value(&1, variables, engine))

  defp render_value(value, variables, engine) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn entry, {:ok, result} ->
      case render_value(entry, variables, engine) do
        {:ok, rendered} -> {:cont, {:ok, [rendered | result]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp render_value(value, _variables, _engine), do: {:ok, value}

  defp map_values(map, fun) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      case fun.(value) do
        {:ok, rendered} -> {:cont, {:ok, Map.put(result, key, rendered)}}
        error -> {:halt, error}
      end
    end)
  end

  defp guidance?(value), do: is_binary(value) or is_map(value) or is_list(value)
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
  defp invalid(message), do: {:error, {:invalid_decision, message}}
end
