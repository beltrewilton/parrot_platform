defmodule ParrotTransportTest do
  use ExUnit.Case
  doctest ParrotTransport

  test "module exists" do
    assert function_exported?(ParrotTransport, :start_listener, 2)
  end
end
