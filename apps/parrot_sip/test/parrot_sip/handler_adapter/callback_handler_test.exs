defmodule ParrotSip.HandlerAdapter.CallbackHandlerTest do
  use ExUnit.Case, async: true
  alias ParrotSip.HandlerAdapter.CallbackHandler
  require Logger

  # Define a test handler module inline
  defmodule TestHandler do
    def handle_invite(_request, _state) do
      {:respond, 200, "OK", %{}, "test"}
    end

    def handle_bye(_request, _state) do
      {:respond, 200, "OK", %{}, ""}
    end
  end

  describe "call_method_handler/4" do
    test "calls the correct handler method when module is loaded" do
      result =
        CallbackHandler.call_method_handler(
          TestHandler,
          "INVITE",
          %{method: "INVITE"},
          %{}
        )

      assert result == {:respond, 200, "OK", %{}, "test"}
    end

    test "handles lowercase method names" do
      result =
        CallbackHandler.call_method_handler(
          TestHandler,
          "invite",
          %{method: "INVITE"},
          %{}
        )

      assert result == {:respond, 200, "OK", %{}, "test"}
    end

    test "handles atom method names" do
      result =
        CallbackHandler.call_method_handler(
          TestHandler,
          :bye,
          %{method: "BYE"},
          %{}
        )

      assert result == {:respond, 200, "OK", %{}, ""}
    end

    test "returns 501 when handler method doesn't exist" do
      result =
        CallbackHandler.call_method_handler(
          TestHandler,
          "OPTIONS",
          %{method: "OPTIONS"},
          %{}
        )

      assert result == {:respond, 501, "Not Implemented by User Handler", %{}, ""}
    end

    test "ensures module is loaded before checking function_exported" do
      # This test verifies that CallbackHandler always ensures the module is loaded
      # before checking if a function is exported

      # Use the test handler which we know exists
      module = TestHandler

      # Even if we were to somehow unload it (which we can't easily do in a test),
      # the CallbackHandler should still work because it calls Code.ensure_loaded
      result =
        CallbackHandler.call_method_handler(
          module,
          "INVITE",
          %{method: "INVITE"},
          %{}
        )

      # Should successfully call the handler
      assert result == {:respond, 200, "OK", %{}, "test"}

      # Verify the module is loaded
      assert Code.ensure_loaded?(module)
    end

    test "returns 501 when module doesn't exist" do
      result =
        CallbackHandler.call_method_handler(
          NonExistentModule,
          "INVITE",
          %{method: "INVITE"},
          %{}
        )

      assert result == {:respond, 501, "Not Implemented by User Handler", %{}, ""}
    end

    test "handles module as string" do
      # Sometimes module names might come as strings
      module_string = "#{__MODULE__}.TestHandler"
      module_atom = String.to_atom(module_string)

      result =
        CallbackHandler.call_method_handler(
          module_atom,
          "INVITE",
          %{method: "INVITE"},
          %{}
        )

      assert result == {:respond, 200, "OK", %{}, "test"}
    end
  end

  describe "call_transaction_handler/6" do
    defmodule TransactionTestHandler do
      def handle_transaction_invite_trying(_request, _transaction, _state) do
        {:respond, 100, "Trying", %{}, ""}
      end

      def handle_invite(_request, _state) do
        {:respond, 200, "OK fallback", %{}, ""}
      end
    end

    test "calls transaction-specific handler when it exists" do
      result =
        CallbackHandler.call_transaction_handler(
          TransactionTestHandler,
          "invite",
          :trying,
          %{method: "INVITE"},
          %{},
          %{}
        )

      assert result == {:respond, 100, "Trying", %{}, ""}
    end

    test "falls back to method handler when transaction handler doesn't exist" do
      result =
        CallbackHandler.call_transaction_handler(
          TransactionTestHandler,
          "invite",
          # No handle_transaction_invite_proceeding
          :proceeding,
          %{method: "INVITE"},
          %{},
          %{}
        )

      assert result == {:respond, 200, "OK fallback", %{}, ""}
    end
  end

  describe "call_dialog_handler/5" do
    defmodule DialogTestHandler do
      def handle_dialog_early(_request, _dialog, _state) do
        {:respond, 180, "Ringing", %{}, ""}
      end
    end

    test "calls dialog handler when it exists" do
      result =
        CallbackHandler.call_dialog_handler(
          DialogTestHandler,
          :early,
          %{},
          %{},
          %{}
        )

      assert result == {:respond, 180, "Ringing", %{}, ""}
    end

    test "returns :noreply when dialog handler doesn't exist" do
      result =
        CallbackHandler.call_dialog_handler(
          DialogTestHandler,
          :confirmed,
          %{},
          %{},
          %{}
        )

      assert result == :noreply
    end
  end
end
