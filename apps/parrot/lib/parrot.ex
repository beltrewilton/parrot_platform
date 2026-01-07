defmodule Parrot do
  @moduledoc """
  High-level DSL framework for building VoIP applications in Elixir.

  Parrot provides a Phoenix-style DSL for building softswitches, PBXs, and
  VoIP applications. It sits on top of parrot_sip and parrot_media to provide
  an ergonomic API for handling SIP calls, media, and telephony features.

  ## Usage

  Add Parrot to your supervision tree in your application:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {Parrot,
              router: MyApp.Router,
              transports: [
                {:udp, port: 5060},
                {:tcp, port: 5060},
                {:tls, port: 5061, certfile: "cert.pem", keyfile: "key.pem"}
              ]}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Options

  * `:router` - Required. The router module that defines how to route incoming calls.
  * `:transports` - Required. A list of transport configurations to listen on.

  ## Transport Configuration

  Each transport is a tuple of `{protocol, options}`:

  * `{:udp, port: 5060}` - UDP transport on port 5060
  * `{:tcp, port: 5060}` - TCP transport on port 5060
  * `{:tls, port: 5061, certfile: "cert.pem", keyfile: "key.pem"}` - TLS transport

  """

  @doc """
  Returns a child specification for starting Parrot under a supervisor.

  ## Options

  * `:router` - Required. The router module that defines call routing.
  * `:transports` - Required. List of transport configurations.

  ## Examples

      # Start with UDP only
      {Parrot, router: MyApp.Router, transports: [{:udp, port: 5060}]}

      # Start with multiple transports
      {Parrot,
        router: MyApp.Router,
        transports: [
          {:udp, port: 5060},
          {:tcp, port: 5060},
          {:tls, port: 5061, certfile: "cert.pem", keyfile: "key.pem"}
        ]}

  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    validate_opts!(opts)

    %{
      id: Parrot.Supervisor,
      start: {Parrot.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  defp validate_opts!(opts) do
    unless Keyword.has_key?(opts, :router) do
      raise ArgumentError, "the :router option is required"
    end

    unless Keyword.has_key?(opts, :transports) do
      raise ArgumentError, "the :transports option is required"
    end

    opts
  end
end
