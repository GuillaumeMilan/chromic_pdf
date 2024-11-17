# SPDX-License-Identifier: Apache-2.0

defmodule ChromicPDF.ProtocolMacros do
  @moduledoc false

  require Logger
  alias ChromicPDF.JsonRPC

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defmacro steps(do: block) do
    quote do
      alias ChromicPDF.JsonRPC
      alias ChromicPDF.Protocol

      @behaviour Protocol

      Module.register_attribute(__MODULE__, :steps, accumulate: true)

      unquote(block)

      @impl Protocol
      def new(opts \\ []) do
        Protocol.new(
          build_steps(opts),
          initial_state(opts)
        )
      end

      @impl Protocol
      def new(session_id, opts) do
        Protocol.new(
          build_steps(opts),
          initial_state(session_id, opts)
        )
      end

      defp initial_state(opts) do
        opts
        |> Enum.into(%{})
        |> Map.put(:__protocol__, __MODULE__)
      end

      defp initial_state(session_id, opts) do
        opts
        |> initial_state()
        |> Map.put("sessionId", session_id)
      end

      defp build_steps(opts) do
        @steps
        |> Enum.reverse()
        |> do_build_steps([], opts)
      end

      defp do_build_steps([], acc, _opts), do: acc

      defp do_build_steps([:end | rest], acc, opts) do
        do_build_steps(rest, acc, opts)
      end

      defp do_build_steps([{:if_option, key} | rest], acc, opts) do
        if Keyword.has_key?(opts, key) do
          do_build_steps(rest, acc, opts)
        else
          skip_branch(rest, acc, opts)
        end
      end

      defp do_build_steps([{:if_option, key, value} | rest], acc, opts) do
        if Keyword.get(opts, key) in List.wrap(value) do
          do_build_steps(rest, acc, opts)
        else
          skip_branch(rest, acc, opts)
        end
      end

      defp do_build_steps([{:include_protocol, protocol_mod} | rest], acc, opts) do
        do_build_steps(rest, acc ++ protocol_mod.new(opts).steps, opts)
      end

      defp do_build_steps([{type, name, arity} | rest], acc, opts) do
        do_build_steps(
          rest,
          acc ++ [{type, Function.capture(__MODULE__, name, arity)}],
          opts
        )
      end

      defp skip_branch([:end | rest], acc, opts), do: do_build_steps(rest, acc, opts)
      defp skip_branch([_skipped | rest], acc, opts), do: skip_branch(rest, acc, opts)
    end
  end

  defmacro if_option({test_key, test_value}, do: block) do
    quote do
      @steps {:if_option, unquote(test_key), unquote(test_value)}
      unquote(block)
      @steps :end
    end
  end

  defmacro if_option(test_key, do: block) do
    quote do
      @steps {:if_option, unquote(test_key)}
      unquote(block)
      @steps :end
    end
  end

  defmacro include_protocol(protocol_mod) do
    quote do
      @steps {:include_protocol, unquote(protocol_mod)}
    end
  end

  defmacro call(name, method, params_from_state, default_params) do
    quote do
      @steps {:call, unquote(name), 2}
      def unquote(name)(state, call_id) do
        params =
          fetch_params_for_call(
            state,
            unquote(params_from_state),
            unquote(default_params)
          )

        call =
          case Map.get(state, "sessionId") do
            nil -> {unquote(method), params}
            session_id -> {session_id, unquote(method), params}
          end

        {Map.put(state, :last_call_id, call_id), call}
      end
    end
  end

  def fetch_params_for_call(state, fun, defaults) when is_function(fun, 1) do
    Map.merge(defaults, fun.(state))
  end

  def fetch_params_for_call(state, keys, defaults) when is_list(keys) do
    Enum.into(keys, defaults, &fetch_param_for_call(state, &1))
  end

  defp fetch_param_for_call(state, {name, key_path}) do
    {name, get_in!(state, key_path)}
  end

  defp fetch_param_for_call(state, key) do
    fetch_param_for_call(state, {key, key})
  end

  defmacro defawait({name, _, args} = fundef, do: block) do
    quote generated: true do
      @steps {:await, unquote(name), unquote(length(args))}

      def unquote(fundef) do
        with :no_match <- intercept_exception_thrown(unquote_splicing(args)),
             :no_match <- intercept_console_api_called(unquote_splicing(args)) do
          unquote(block)
        end
      end
    end
  end

  defmacro await_response(name, put_keys, do: block) do
    quote generated: true do
      await_response(unquote(name), unquote(put_keys))
      await_response_callback(unquote(name), do: unquote(block))
    end
  end

  defmacro await_response_callback(name, do: block) do
    quote generated: true do
      def unquote(:"#{name}_callback")(var!(state), var!(msg)) do
        unquote(block)
      end
    end
  end

  defmacro await_response(name, put_keys) do
    cb_name = :"#{name}_callback"

    quote do
      defawait unquote(name)(state, msg) do
        last_call_id = Map.fetch!(state, :last_call_id)

        if JsonRPC.response?(msg, last_call_id) do
          cond do
            function_exported?(__MODULE__, unquote(cb_name), 2) ->
              apply(__MODULE__, unquote(cb_name), [state, msg])

            JsonRPC.is_error?(msg) ->
              {:error, JsonRPC.extract_error(msg)}

            true ->
              :ok
          end
          |> case do
            :ok ->
              state = extract_from_payload(msg, "result", unquote(put_keys), state)
              {:match, :remove, state}

            {:error, error} ->
              {:error, error}
          end
        else
          :no_match
        end
      end
    end
  end

  defmacro await_notification(name, method, match_keys, put_keys) do
    quote do
      defawait unquote(name)(state, msg) do
        with true <- JsonRPC.notification?(msg, unquote(method)),
             true <- state["sessionId"] == msg["sessionId"],
             true <- Enum.all?(unquote(match_keys), &notification_matches?(state, msg, &1)) do
          state = extract_from_payload(msg, "params", unquote(put_keys), state)

          {:match, :remove, state}
        else
          _ -> :no_match
        end
      end
    end
  end

  def intercept_exception_thrown(state, msg) do
    with true <- JsonRPC.notification?(msg, "Runtime.exceptionThrown"),
         true <- state["sessionId"] == msg["sessionId"] do
      exception = get_in!(msg, ["params", "exceptionDetails"])
      prefix = get_in(exception, ["text"])

      suffix =
        get_in(exception, ["exception", "description"])
        |> case do
          nil -> "undefined"
          description -> description
        end

      description = "#{prefix} #{suffix}"

      case Map.get(state, :unhandled_runtime_exceptions, :log) do
        :ignore ->
          {:match, :keep, state}

        :log ->
          Logger.warning("""
          [ChromicPDF] Unhandled exception in JS runtime

          #{description}
          """)

          {:match, :keep, state}

        :raise ->
          {:error, {:exception_thrown, description}}
      end
    else
      _ -> :no_match
    end
  end

  def intercept_console_api_called(state, msg) do
    with true <- JsonRPC.notification?(msg, "Runtime.consoleAPICalled"),
         true <- state["sessionId"] == msg["sessionId"] do
      type = get_in!(msg, ["params", "type"])
      args = get_in!(msg, ["params", "args"]) |> Jason.encode!(pretty: true)

      case Map.get(state, :console_api_calls, :ignore) do
        :ignore ->
          {:match, :keep, state}

        :log ->
          Logger.warning("""
          [ChromicPDF] console.#{type} called in JS runtime

          #{args}
          """)

          {:match, :keep, state}

        :raise ->
          {:error, {:console_api_called, {type, args}}}
      end
    else
      _ -> :no_match
    end
  end

  def extract_from_payload(msg, payload_key, put_keys, state) do
    Enum.into(
      put_keys,
      state,
      fn
        {path, key} -> {key, get_in!(msg, [payload_key | path])}
        key -> {key, get_in!(msg, [payload_key, key])}
      end
    )
  end

  def notification_matches?(state, msg, {msg_path, key}) do
    get_in(msg, ["params" | msg_path]) == get_in!(state, key)
  end

  def notification_matches?(state, msg, key), do: notification_matches?(state, msg, {[key], key})

  defmacro output(key) when is_binary(key) do
    quote do
      @steps {:output, :output, 1}
      def output(state), do: Map.fetch!(state, unquote(key))
    end
  end

  defmacro output(keys) when is_list(keys) do
    quote do
      @steps {:output, :output, 1}
      def output(state), do: Map.take(state, unquote(keys))
    end
  end

  defp get_in!(map, keys) do
    accessor =
      keys
      |> List.wrap()
      |> Enum.map(&Access.key!(&1))

    get_in(map, accessor)
  end
end
