defmodule SippTest.RegisterAuthTest do
  @moduledoc """
  SIPp integration tests for REGISTER with Digest Authentication.

  Tests the 401 challenge/response flow for SIP REGISTER as defined in:
  - RFC 3261 Section 10: Registrations
  - RFC 3261 Section 22: Usage of HTTP Authentication
  - RFC 2617: HTTP Digest Authentication
  """

  use ExUnit.Case, async: false

  alias SippTest.SippRunner
  alias ParrotSip.Auth.NonceStore
  alias ParrotSip.{Message, Registrar}
  alias ParrotSip.Transaction.Server

  @moduletag :sipp
  @moduletag :auth

  # Test handler that uses Registrar for authentication
  defmodule AuthTestHandler do
    @moduledoc false
    @behaviour ParrotSip.Handler

    require Logger

    # Implements RegistrationHandler callbacks
    use Parrot.RegistrationHandler

    @impl Parrot.RegistrationHandler
    def get_password("alice"), do: {:ok, "secret123"}
    def get_password("bob"), do: {:ok, "bobspassword"}
    def get_password(_), do: :error

    @impl Parrot.RegistrationHandler
    def store_binding(aor, contact, expires) do
      Logger.debug("[AuthTestHandler] store_binding: #{aor} -> #{contact} (expires: #{expires})")
      # Store in process dictionary for testing
      bindings = Process.get(:auth_test_bindings, %{})
      contacts = Map.get(bindings, aor, [])

      new_contacts =
        if expires > 0 do
          [{contact, expires} | Enum.reject(contacts, fn {c, _} -> c == contact end)]
        else
          Enum.reject(contacts, fn {c, _} -> c == contact end)
        end

      Process.put(:auth_test_bindings, Map.put(bindings, aor, new_contacts))
      :ok
    end

    @impl Parrot.RegistrationHandler
    def get_bindings(aor) do
      bindings = Process.get(:auth_test_bindings, %{})
      contacts = Map.get(bindings, aor, [])
      Enum.map(contacts, fn {contact, _expires} -> contact end)
    end

    # ParrotSip.Handler callbacks
    @impl ParrotSip.Handler
    def transp_request(_msg, _args), do: :process_transaction

    @impl ParrotSip.Handler
    def transaction(_trans, _sip_msg, _args), do: :process_uas

    @impl ParrotSip.Handler
    def transaction_stop(_trans, _result, _args), do: :ok

    @impl ParrotSip.Handler
    def uas_request(uas, sip_msg, args) do
      Logger.debug("[AuthTestHandler] uas_request: #{sip_msg.method}")

      case sip_msg.method do
        :register -> handle_register_with_auth(uas, sip_msg, args)
        _ -> send_not_implemented(uas, sip_msg)
      end
    end

    @impl ParrotSip.Handler
    def uas_cancel(_uas_id, _args), do: :ok

    @impl ParrotSip.Handler
    def process_ack(_sip_msg, _args), do: :ok

    # Handle REGISTER with authentication
    defp handle_register_with_auth(uas, sip_msg, args) do
      nonce_store = args[:nonce_store]
      realm = args[:realm] || "example.com"

      case Registrar.process_register(sip_msg, __MODULE__, realm, nonce_store) do
        {:ok, response} ->
          Logger.debug("[AuthTestHandler] Registration successful")
          Server.response(response, uas)

        {:challenge, response} ->
          Logger.debug("[AuthTestHandler] Sending 401 challenge")
          Server.response(response, uas)

        {:error, response} ->
          Logger.debug("[AuthTestHandler] Authentication failed - sending 403")
          Server.response(response, uas)
      end

      :ok
    end

    defp send_not_implemented(uas, sip_msg) do
      response = Message.reply(sip_msg, 501, "Not Implemented")
      Server.response(response, uas)
      :ok
    end
  end

  # Helper module for starting the SIP stack with auth handler
  defmodule AuthStackHelper do
    @moduledoc false
    use GenServer

    alias ParrotTransport.Types.{ListenerConfig, IncomingPacket}
    alias ParrotSip.TransportHandler

    defstruct [:transport_listener, :transport_handler, :sip_handler, :port, :nonce_store]

    def start_udp(handler, opts \\ []) do
      port = Keyword.get(opts, :port, 0)
      ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
      nonce_store = Keyword.fetch!(opts, :nonce_store)
      realm = Keyword.get(opts, :realm, "example.com")

      with {:ok, bridge} <- start_bridge(handler, nonce_store, realm),
           {:ok, listener, actual_ip, actual_port} <- start_udp_listener(bridge, ip, port) do
        :ok =
          TransportHandler.register_transport(
            ParrotSip.TransportHandler,
            listener,
            :udp,
            actual_ip,
            actual_port
          )

        stack = %__MODULE__{
          transport_listener: listener,
          transport_handler: bridge,
          sip_handler: handler,
          port: actual_port,
          nonce_store: nonce_store
        }

        {:ok, stack}
      end
    end

    def stop(%__MODULE__{} = stack) do
      ParrotTransport.stop_listener(stack.transport_listener)
      GenServer.stop(stack.transport_handler)
      :ok
    end

    def start_bridge(sip_handler, nonce_store, realm) do
      GenServer.start_link(__MODULE__, {sip_handler, nonce_store, realm})
    end

    @impl true
    def init({sip_handler, nonce_store, realm}) do
      transport_handler = Process.whereis(ParrotSip.TransportHandler)

      unless transport_handler do
        raise "ParrotSip.TransportHandler not found"
      end

      {:ok,
       %{
         sip_handler: sip_handler,
         transport_handler: transport_handler,
         nonce_store: nonce_store,
         realm: realm
       }}
    end

    @impl true
    def handle_info({:incoming_packet, %IncomingPacket{} = packet}, state) do
      alias ParrotSip.{Parser, Source, TransactionStatem}

      case Parser.parse(packet.data) do
        {:ok, sip_message} ->
          source = %Source{
            transport: packet.source.transport,
            remote: packet.source.remote_addr,
            local: packet.source.local_addr,
            connection: packet.source.connection
          }

          message_with_source = Map.put(sip_message, :source, source)

          # Pass nonce_store and realm through handler args
          handler_with_auth_args = %{
            state.sip_handler
            | args:
                Map.merge(state.sip_handler.args || %{}, %{
                  nonce_store: state.nonce_store,
                  realm: state.realm
                })
          }

          case message_with_source.type do
            :request ->
              TransactionStatem.server_process(message_with_source, handler_with_auth_args)

            :response ->
              via = List.first(message_with_source.via)
              TransactionStatem.client_response(via, packet.data)
          end

        {:error, reason} ->
          require Logger
          Logger.error("[AuthStackHelper] Failed to parse SIP message: #{inspect(reason)}")
      end

      {:noreply, state}
    end

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}

    defp start_udp_listener(bridge_pid, ip, port) do
      sip_trace = System.get_env("SIP_TRACE", "false") == "true"

      config = %ListenerConfig{
        transport: :udp,
        ip: ip,
        port: port,
        trace: sip_trace
      }

      case ParrotTransport.start_listener(config) do
        {:ok, listener} ->
          ParrotTransport.register_handler(listener, bridge_pid)
          {:ok, {actual_ip, actual_port}} = ParrotTransport.get_local_address(listener)
          {:ok, listener, actual_ip, actual_port}

        error ->
          error
      end
    end
  end

  describe "REGISTER with Digest Authentication" do
    setup do
      # Start nonce store
      {:ok, nonce_store} = NonceStore.start_link(name: :"nonce_store_#{:erlang.unique_integer()}")

      # Create handler
      handler = ParrotSip.Handler.new(AuthTestHandler, %{})

      # Start SIP stack with auth support
      {:ok, stack} =
        AuthStackHelper.start_udp(handler,
          port: 0,
          nonce_store: nonce_store,
          realm: "example.com"
        )

      on_exit(fn ->
        try do
          AuthStackHelper.stop(stack)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(nonce_store), do: GenServer.stop(nonce_store)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      %{stack: stack, nonce_store: nonce_store}
    end

    @tag timeout: 30_000
    test "REGISTER with correct credentials succeeds after 401 challenge", %{stack: stack} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/register/uac_register_auth.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok
    end

    @tag timeout: 30_000
    test "REGISTER with wrong password receives 403 Forbidden", %{stack: stack} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/register/uac_register_auth_wrong_password.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 1,
          timeout: 15_000
        )

      assert result == :ok
    end

    @tag timeout: 30_000
    test "multiple sequential registrations with auth", %{stack: stack} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/register/uac_register_auth.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 3,
          timeout: 20_000
        )

      assert result == :ok
    end
  end
end
