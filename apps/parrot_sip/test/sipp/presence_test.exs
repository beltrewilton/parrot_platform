defmodule SippTest.PresenceTest do
  @moduledoc """
  SIPp integration tests for presence (SUBSCRIBE/NOTIFY and PUBLISH) scenarios.

  Tests covered:
  - SUBSCRIBE/NOTIFY presence flow
  - PUBLISH presence update

  RFC References:
  - RFC 3856: A Presence Event Package for SIP
  - RFC 3903: SIP Extension for Event State Publication
  - RFC 6665: SIP-Specific Event Notification
  """

  use ExUnit.Case, async: false

  alias SippTest.{SippRunner, SipStackHelper}
  alias ParrotSip.{Handler, Message}
  alias ParrotSip.Transaction.Server

  @moduletag :sipp
  @moduletag :presence

  # Custom handler for presence testing that sends NOTIFY after SUBSCRIBE
  defmodule PresenceTestHandler do
    @moduledoc false
    @behaviour ParrotSip.Handler

    require Logger

    @impl true
    def transp_request(_msg, _args), do: :process_transaction

    @impl true
    def transaction(_trans, _sip_msg, _args), do: :process_uas

    @impl true
    def transaction_stop(_trans, _result, _args), do: :ok

    @impl true
    def uas_request(uas, sip_msg, args) do
      Logger.debug("[PresenceTestHandler] uas_request: #{sip_msg.method}")

      case sip_msg.method do
        :subscribe -> handle_subscribe_with_notify(uas, sip_msg, args)
        :publish -> handle_publish(uas, sip_msg, args)
        :notify -> handle_notify(uas, sip_msg, args)
        _ -> send_not_implemented(uas, sip_msg)
      end
    end

    @impl true
    def uas_cancel(_uas_id, _args), do: :ok

    @impl true
    def process_ack(_sip_msg, _args), do: :ok

    # Handle SUBSCRIBE - respond with 200 OK and then send NOTIFY
    defp handle_subscribe_with_notify(uas, sip_msg, args) do
      update_stats(args, :subscribes)
      Logger.debug("[PresenceTestHandler] Handling SUBSCRIBE with NOTIFY")

      # Send 200 OK for SUBSCRIBE
      response = Message.reply(sip_msg, 200, "OK")

      response = %{
        response
        | expires: Map.get(sip_msg, :expires, 3600)
      }

      Server.response(response, uas)

      # Schedule NOTIFY to be sent after a short delay
      # This gives SIPp time to process the 200 OK and be ready to receive NOTIFY
      spawn(fn ->
        Process.sleep(100)
        send_notify(sip_msg, args)
      end)

      :ok
    end

    # Send NOTIFY with presence document
    defp send_notify(subscribe_msg, args) do
      Logger.debug("[PresenceTestHandler] Sending NOTIFY")

      # Extract needed info from SUBSCRIBE
      from = subscribe_msg.from
      to = subscribe_msg.to
      call_id = subscribe_msg.call_id

      # Create NOTIFY request
      # NOTIFY goes to the Contact from SUBSCRIBE, or back to the From address
      contact_uri =
        case subscribe_msg.contact do
          nil -> ParrotSip.Uri.to_string(from.uri)
          [contact | _] -> ParrotSip.Uri.to_string(contact.uri)
          contact -> ParrotSip.Uri.to_string(contact.uri)
        end

      # Parse contact URI to get host and port for routing
      {:ok, target_uri} = ParrotSip.Uri.parse(contact_uri)
      target_host = target_uri.host
      target_port = target_uri.port || 5060

      # Presence document (PIDF)
      pidf_body = """
      <?xml version="1.0" encoding="UTF-8"?>
      <presence xmlns="urn:ietf:params:xml:ns:pidf" entity="#{ParrotSip.Uri.to_string(to.uri)}">
        <tuple id="tuple1">
          <status>
            <basic>open</basic>
          </status>
          <contact priority="1.0">#{contact_uri}</contact>
        </tuple>
      </presence>
      """

      notify =
        ParrotSip.Message.new_request(
          :notify,
          target_uri,
          from: %{uri: to.uri, tag: to.tag},
          to: %{uri: from.uri, tag: from.tag},
          call_id: call_id,
          cseq: 1,
          event: "presence",
          subscription_state: "active;expires=3600",
          content_type: "application/pidf+xml",
          body: String.trim(pidf_body)
        )

      # Send via callback if provided, otherwise log warning
      case args[:notify_callback] do
        callback when is_function(callback) ->
          callback.(notify)

        nil ->
          # No callback provided - NOTIFY cannot be sent without proper transport setup
          Logger.warning(
            "[PresenceTestHandler] No notify_callback provided, cannot send NOTIFY to #{target_host}:#{target_port}"
          )
      end
    end

    # Handle PUBLISH - respond with 200 OK
    @impl true
    def handle_publish(uas, sip_msg, args) do
      update_stats(args, :publishes)
      Logger.debug("[PresenceTestHandler] Handling PUBLISH")

      response = Message.reply(sip_msg, 200, "OK")

      # Add SIP-ETag for event state
      response = %{
        response
        | sip_etag: "entity-tag-#{:erlang.unique_integer([:positive])}"
      }

      Server.response(response, uas)
      :ok
    end

    # Handle NOTIFY from remote (as UAS)
    @impl true
    def handle_notify(uas, sip_msg, args) do
      update_stats(args, :notifies)
      Logger.debug("[PresenceTestHandler] Handling NOTIFY")

      response = Message.reply(sip_msg, 200, "OK")
      Server.response(response, uas)
      :ok
    end

    defp send_not_implemented(uas, sip_msg) do
      response = Message.reply(sip_msg, 501, "Not Implemented")
      Server.response(response, uas)
      :ok
    end

    defp update_stats(%{stats_pid: pid}, key) when is_pid(pid) do
      send(pid, {:update_stat, key})
    end

    defp update_stats(_, _), do: :ok

    # Public API for creating handler
    def new(opts \\ []) do
      stats_pid =
        spawn(fn ->
          stats_loop(%{
            subscribes: 0,
            notifies: 0,
            publishes: 0
          })
        end)

      args =
        Enum.into(opts, %{})
        |> Map.put(:stats_pid, stats_pid)

      Handler.new(__MODULE__, args)
    end

    def get_stats(%Handler{args: %{stats_pid: pid}}) do
      send(pid, {:get_stats, self()})

      receive do
        {:stats, stats} -> stats
      after
        5000 -> {:error, :timeout}
      end
    end

    defp stats_loop(stats) do
      receive do
        {:get_stats, from} ->
          send(from, {:stats, stats})
          stats_loop(stats)

        {:update_stat, key} ->
          new_stats = Map.update(stats, key, 1, &(&1 + 1))
          stats_loop(new_stats)
      end
    end
  end

  # Simple handler that just responds to SUBSCRIBE and PUBLISH without sending NOTIFY
  # Used for basic scenario testing
  defmodule SimplePresenceHandler do
    @moduledoc false
    @behaviour ParrotSip.Handler

    require Logger

    @impl true
    def transp_request(_msg, _args), do: :process_transaction

    @impl true
    def transaction(_trans, _sip_msg, _args), do: :process_uas

    @impl true
    def transaction_stop(_trans, _result, _args), do: :ok

    @impl true
    def uas_request(uas, sip_msg, args) do
      Logger.debug("[SimplePresenceHandler] uas_request: #{sip_msg.method}")

      case sip_msg.method do
        :subscribe -> handle_subscribe(uas, sip_msg, args)
        :publish -> handle_publish(uas, sip_msg, args)
        _ -> send_not_implemented(uas, sip_msg)
      end
    end

    @impl true
    def uas_cancel(_uas_id, _args), do: :ok

    @impl true
    def process_ack(_sip_msg, _args), do: :ok

    @impl true
    def handle_subscribe(uas, sip_msg, args) do
      update_stats(args, :subscribes)

      response = Message.reply(sip_msg, 200, "OK")
      response = %{response | expires: Map.get(sip_msg, :expires, 3600)}
      Server.response(response, uas)
      :ok
    end

    @impl true
    def handle_publish(uas, sip_msg, args) do
      update_stats(args, :publishes)

      response = Message.reply(sip_msg, 200, "OK")
      response = %{response | sip_etag: "etag-#{:erlang.unique_integer([:positive])}"}
      Server.response(response, uas)
      :ok
    end

    defp send_not_implemented(uas, sip_msg) do
      response = Message.reply(sip_msg, 501, "Not Implemented")
      Server.response(response, uas)
      :ok
    end

    defp update_stats(%{stats_pid: pid}, key) when is_pid(pid) do
      send(pid, {:update_stat, key})
    end

    defp update_stats(_, _), do: :ok

    def new(opts \\ []) do
      stats_pid =
        spawn(fn ->
          stats_loop(%{subscribes: 0, publishes: 0})
        end)

      args =
        Enum.into(opts, %{})
        |> Map.put(:stats_pid, stats_pid)

      Handler.new(__MODULE__, args)
    end

    def get_stats(%Handler{args: %{stats_pid: pid}}) do
      send(pid, {:get_stats, self()})

      receive do
        {:stats, stats} -> stats
      after
        5000 -> {:error, :timeout}
      end
    end

    defp stats_loop(stats) do
      receive do
        {:get_stats, from} ->
          send(from, {:stats, stats})
          stats_loop(stats)

        {:update_stat, key} ->
          new_stats = Map.update(stats, key, 1, &(&1 + 1))
          stats_loop(new_stats)
      end
    end
  end

  describe "SUBSCRIBE/NOTIFY presence flow" do
    setup do
      # Use simple handler - we test SUBSCRIBE response only
      # Full NOTIFY flow requires more complex UAC capabilities
      handler = SimplePresenceHandler.new()

      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      on_exit(fn ->
        try do
          SipStackHelper.stop(stack)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      %{stack: stack, handler: handler}
    end

    @tag timeout: 15_000
    test "SUBSCRIBE receives 200 OK", %{stack: stack, handler: handler} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/presence/uac_subscribe_notify.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 1,
          timeout: 10_000
        )

      assert result == :ok

      Process.sleep(100)
      stats = SimplePresenceHandler.get_stats(handler)
      assert stats.subscribes == 1
    end

    @tag timeout: 20_000
    test "multiple SUBSCRIBE requests", %{stack: stack, handler: handler} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/presence/uac_subscribe_notify.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 3,
          timeout: 15_000
        )

      assert result == :ok

      Process.sleep(100)
      stats = SimplePresenceHandler.get_stats(handler)
      assert stats.subscribes == 3
    end
  end

  describe "PUBLISH presence update" do
    setup do
      handler = SimplePresenceHandler.new()

      {:ok, stack} = SipStackHelper.start_udp(handler, port: 0)

      on_exit(fn ->
        try do
          SipStackHelper.stop(stack)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      %{stack: stack, handler: handler}
    end

    @tag timeout: 15_000
    test "PUBLISH receives 200 OK with SIP-ETag", %{stack: stack, handler: handler} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/presence/uac_publish.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 1,
          timeout: 10_000
        )

      assert result == :ok

      Process.sleep(100)
      stats = SimplePresenceHandler.get_stats(handler)
      assert stats.publishes == 1
    end

    @tag timeout: 20_000
    test "multiple PUBLISH requests", %{stack: stack, handler: handler} do
      result =
        SippRunner.run_scenario(
          scenario_file: "test/sipp/scenarios/presence/uac_publish.xml",
          remote_host: "127.0.0.1",
          remote_port: stack.port,
          calls: 3,
          timeout: 15_000
        )

      assert result == :ok

      Process.sleep(100)
      stats = SimplePresenceHandler.get_stats(handler)
      assert stats.publishes == 3
    end
  end
end
