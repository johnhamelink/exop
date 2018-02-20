defmodule Exop.Validation do
  @moduledoc """
    Provides high-level functions for a contract validation.
    The main function is valid?/2
    Mostly invokes Exop.ValidationChecks module functions.
  """

  alias Exop.ValidationChecks

  defmodule ValidationError do
    @moduledoc """
      An operation's contract validation failure error.
    """
    defexception message: "Contract validation failed"
  end

  @type validation_error :: {:error, {:validation, map()}}

  @spec function_present?(Elixir.Exop.Validation | Elixir.Exop.ValidationChecks, atom()) :: boolean()
  defp function_present?(module, function_name) do
    :functions
    |> module.__info__
    |> Keyword.has_key?(function_name)
  end

  @doc """
  Validate received params over a contract.

  ## Examples

      iex> Exop.Validation.valid?([%{name: :param, opts: [required: true]}], [param: "hello"])
      :ok
  """
  @spec valid?(list(map()), Keyword.t | map()) :: :ok | validation_error
  def valid?(contract, received_params) do
    validation_results = validate(contract, received_params, [])

    if Enum.empty?(validation_results) || Enum.all?(validation_results, &(&1 == true)) do
      :ok
    else
      error_results = validation_results |> consolidate_errors
      {:error, {:validation, error_results}}
    end
  end

  @spec consolidate_errors(list) :: map()
  defp consolidate_errors(validation_results) do
    error_results = validation_results |> Enum.reject(&(&1 == true))
    Enum.reduce(error_results, %{}, fn (error_result, map) ->
      item_name = error_result |> Map.keys |> List.first
      error_message = Map.get(error_result, item_name)

      Map.put(map, item_name, [error_message | (map[item_name] || [])])
    end)
  end

  @spec errors_message(map()) :: String.t
  def errors_message(errors) do
    errors
      |> Enum.map(fn {item_name, error_messages} ->
        "#{item_name}: #{Enum.join(error_messages, "\n\t")}"
      end)
      |> Enum.join("\n")
  end

  @doc """
  Validate received params over a contract. Accumulate validation results into a list.

  ## Examples

      iex> Exop.Validation.validate([%{name: :param, opts: [required: true, type: :string]}], [param: "hello"], [])
      [true, true]
  """
  @spec validate([map()], map() | Keyword.t, list) :: list
  def validate([], _received_params, result), do: result
  def validate([contract_item | contract_tail], received_params, result) do
    checks_result =
      if !required_param?(contract_item) && empty_param?(received_params, contract_item) do
        []
      else
        validate_params(contract_item, received_params)
      end

    validate(contract_tail, received_params, result ++ List.flatten(checks_result))
  end

  defp required_param?(%{opts: opts}), do: opts[:required] || false

  defp empty_param?(params, %{name: param_name}) when is_map(params) do
    is_nil(Map.get(params, param_name))
  end
  defp empty_param?(params, %{name: param_name}), do: is_nil(params[param_name])

  # TODO: Refactor this - flatten it out and move the inner type checking inside
  #       the validate_param function.
  defp validate_params(contract_item = %{name: name, opts: contract_items}, received_params) do
    for {check_name, check_expectation} <- contract_items, into: [] do
      if check_name == :inner do
        inner_type = get_in(contract_items, [:type])
        check_type =
          if is_nil(inner_type) do
            check_name
          else
            [check_name, inner_type]
          end
        validate_param(check_type, received_params[name], check_name, check_expectation)
      else
        validate_param([check_name, nil], received_params, name, check_expectation)
      end
    end
  end

  # TODO: Add Typespec here
  def validate_param([:inner, :map], received_params, item_name, checks) do
    received_params = Enum.into(received_params, %{})
    checks = Enum.into(checks, %{})
    for key <- Map.keys(checks) do
      param_checks = Enum.into(checks[key], [])

      {:ok, param} = Map.fetch(received_params, key)

      for {type, expected} <- param_checks do
        validate_param([type, nil], received_params, key, expected)
      end
    end
  end

  # TODO: Add Typespec here
  def validate_param([:inner, :list], received_params, item_name, checks) when is_list(received_params),
  do: validate_param([:inner, :list], List.first(received_params), item_name, checks)

  def validate_param([:inner, :list], {name, params}, item_name, checks) do
    params
    |> Enum.with_index
    |> Enum.map(fn({param, index}) ->
      contract = %{name: "#{name}_#{index}", opts: checks}
      validate_params(contract, param)
    end)
  end

  # TODO: Add Typespec here
  def validate_param([check_name, _], received_params, item_name, checks) do
    check_function_name = String.to_atom("check_#{check_name}")
    cond do
      function_present?(__MODULE__, check_function_name) ->
        apply(
          __MODULE__,
          check_function_name,
          [received_params, item_name, checks]
        )
      function_present?(ValidationChecks, check_function_name) ->
        apply(
          ValidationChecks,
          check_function_name,
          [received_params, item_name, checks]
        )
      true -> true
    end
  end

  # TODO: Add Typespec here
  def validate_param(check_name, received_params, item_name, checks) when not is_list(check_name),
  do: validate_param([check_name, nil], received_params, item_name, checks)


  @doc """
  Checks inner item of the contract param (which is a Map itself) with their own checks.

  ## Examples

      iex> Exop.Validation.check_inner(%{param: 1}, :param, [type: :integer, required: true])
      true
  """
  @spec check_inner(map() | Keyword.t, atom, map() | Keyword.t) :: list
  def check_inner(check_items, item_name, checks) when is_map(checks) do
     checked_param = ValidationChecks.get_check_item(check_items, item_name)

     inner_contract = for {inner_param_name, inner_param_checks} <- checks, into: [] do
       %{name: inner_param_name, opts:  inner_param_checks}
     end

     validate(inner_contract, checked_param, [])
  end

  def check_inner(_received_params, _contract_item_name, _check_params), do: true
end
