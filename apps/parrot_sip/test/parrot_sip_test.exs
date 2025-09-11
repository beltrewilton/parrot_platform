defmodule ParrotSipTest do
  use ExUnit.Case
  doctest ParrotSip

  test "module exists" do
    assert function_exported?(ParrotSip, :parse_message, 1)
  end
end
