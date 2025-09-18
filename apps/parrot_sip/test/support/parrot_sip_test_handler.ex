defmodule ParrotSip.TestHandler do
  @moduledoc """
  Alias module for backward compatibility with tests.
  Delegates to ParrotSip.Test.TestHandler.
  """
  
  defdelegate new(args \\ nil, opts \\ []), to: ParrotSip.Test.TestHandler
end