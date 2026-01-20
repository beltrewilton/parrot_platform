# Ensure Ranch/Cowboy are started before tests that use MockWsServer
# This fixes "ranch_server_proxy :noproc" errors in WsBidirectional tests
{:ok, _} = Application.ensure_all_started(:plug_cowboy)

ExUnit.start()
