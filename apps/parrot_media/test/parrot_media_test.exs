defmodule ParrotMediaTest do
  use ExUnit.Case
  doctest ParrotMedia

  test "module exists" do
    assert function_exported?(ParrotMedia, :start_session, 1)
  end
end
