defmodule ParrotTest do
  use ExUnit.Case, async: true

  describe "child_spec/1" do
    test "returns a valid child spec with required options" do
      opts = [
        router: MyApp.Router,
        transports: [
          {:udp, port: 5060}
        ]
      ]

      child_spec = Parrot.child_spec(opts)

      assert child_spec.id == Parrot.Supervisor
      assert child_spec.start == {Parrot.Supervisor, :start_link, [opts]}
      assert child_spec.type == :supervisor
    end

    test "accepts router option" do
      opts = [router: MyApp.Router, transports: []]
      child_spec = Parrot.child_spec(opts)

      {_module, :start_link, [passed_opts]} = child_spec.start
      assert Keyword.get(passed_opts, :router) == MyApp.Router
    end

    test "accepts transports option with UDP config" do
      opts = [
        router: MyApp.Router,
        transports: [{:udp, port: 5060}]
      ]

      child_spec = Parrot.child_spec(opts)

      {_module, :start_link, [passed_opts]} = child_spec.start
      assert Keyword.get(passed_opts, :transports) == [{:udp, port: 5060}]
    end

    test "accepts transports option with multiple transports" do
      opts = [
        router: MyApp.Router,
        transports: [
          {:udp, port: 5060},
          {:tcp, port: 5060},
          {:tls, port: 5061, certfile: "cert.pem", keyfile: "key.pem"}
        ]
      ]

      child_spec = Parrot.child_spec(opts)

      {_module, :start_link, [passed_opts]} = child_spec.start
      transports = Keyword.get(passed_opts, :transports)

      assert length(transports) == 3
      assert {:udp, port: 5060} in transports
      assert {:tcp, port: 5060} in transports
      assert {:tls, port: 5061, certfile: "cert.pem", keyfile: "key.pem"} in transports
    end

    test "raises if router option is missing" do
      opts = [transports: [{:udp, port: 5060}]]

      assert_raise ArgumentError, ~r/router.*required/, fn ->
        Parrot.child_spec(opts)
      end
    end

    test "raises if transports option is missing" do
      opts = [router: MyApp.Router]

      assert_raise ArgumentError, ~r/transports.*required/, fn ->
        Parrot.child_spec(opts)
      end
    end
  end
end
