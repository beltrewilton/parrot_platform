defmodule Parrot.Bridge.HandlerTest do
  use ExUnit.Case, async: true

  alias Parrot.Bridge.Handler

  defmodule TestRouter do
    @moduledoc false
    use Parrot.Router
    invite "*", SomeHandler
  end

  describe "transp_request/2" do
    test "returns :process_transaction for any message" do
      msg = %{type: :request, method: :invite}
      args = %{router: TestRouter}

      assert :process_transaction = Handler.transp_request(msg, args)
    end
  end

  describe "transaction/3" do
    test "returns :process_uas for server transactions" do
      trans = %{id: "test-tx"}
      msg = %{type: :request, method: :invite}
      args = %{router: TestRouter}

      assert :process_uas = Handler.transaction(trans, msg, args)
    end
  end

  describe "transaction_stop/3" do
    test "returns :ok" do
      trans = %{id: "test-tx"}
      result = :normal
      args = %{router: TestRouter}

      assert :ok = Handler.transaction_stop(trans, result, args)
    end
  end

  describe "uas_cancel/2" do
    test "returns :ok" do
      uas_id = "test-uas-id"
      args = %{router: TestRouter}

      assert :ok = Handler.uas_cancel(uas_id, args)
    end
  end

  describe "process_ack/2" do
    test "returns :ok for ACK messages" do
      ack_msg = %{type: :request, method: :ack}
      args = %{router: TestRouter}

      assert :ok = Handler.process_ack(ack_msg, args)
    end
  end

  describe "behaviour implementation" do
    test "implements ParrotSip.Handler behaviour" do
      behaviours = Parrot.Bridge.Handler.__info__(:attributes)[:behaviour]
      assert ParrotSip.Handler in behaviours
    end

    test "exports all required callbacks" do
      # Required callbacks from ParrotSip.Handler
      assert function_exported?(Handler, :transp_request, 2)
      assert function_exported?(Handler, :transaction, 3)
      assert function_exported?(Handler, :transaction_stop, 3)
      assert function_exported?(Handler, :uas_request, 3)
      assert function_exported?(Handler, :uas_cancel, 2)
      assert function_exported?(Handler, :process_ack, 2)
    end

    test "exports optional method-specific callbacks" do
      # Optional method-specific callbacks
      assert function_exported?(Handler, :handle_invite, 3)
      assert function_exported?(Handler, :handle_bye, 3)
      assert function_exported?(Handler, :handle_register, 3)
      assert function_exported?(Handler, :handle_options, 3)
      assert function_exported?(Handler, :handle_cancel, 3)
    end
  end
end
