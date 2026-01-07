defmodule Parrot.Router do
  @moduledoc """
  Phoenix-style router for SIP message routing.

  Provides a DSL for defining routes with scopes, pipelines, and pattern matching
  on SIP-specific criteria like source IP, headers, and URI patterns.

  ## Example

      defmodule MyApp.Router do
        use Parrot.Router

        pipeline :authenticated do
          plug :verify_registration
          plug :check_acl
        end

        scope "/", from_ip: "192.168.1.0/24" do
          pipe_through :authenticated
          invite "1xxx", ExtensionsHandler
          invite "*", DefaultHandler
        end

        invite "*", RejectHandler

        register MyRegistrationHandler
        presence MyPresenceHandler
      end

  ## Scope Options

  - `from_ip` - Match source IP (CIDR notation, single IP, or list of IPs)
  - `from` - Match From URI pattern (e.g., "*@domain.com")
  - `to` - Match To URI pattern
  - `header` - Match header tuple like `{"X-Header", "value"}`

  ## Pattern Syntax

  - `"1xxx"` - `x` matches a single digit
  - `"9~"` - `~` matches any number of characters
  - `"*"` - Catch-all pattern
  """

  @doc """
  Macro to use Parrot.Router in a module.
  """
  defmacro __using__(_opts) do
    quote do
      import Parrot.Router,
        only: [
          pipeline: 2,
          plug: 1,
          plug: 2,
          scope: 2,
          scope: 3,
          pipe_through: 1,
          invite: 2,
          register: 1,
          presence: 1
        ]

      Module.register_attribute(__MODULE__, :routes, accumulate: true)
      Module.register_attribute(__MODULE__, :pipelines, accumulate: true)
      Module.register_attribute(__MODULE__, :current_scope, accumulate: false)
      Module.register_attribute(__MODULE__, :current_pipelines, accumulate: false)
      Module.register_attribute(__MODULE__, :current_plugs, accumulate: true)
      Module.register_attribute(__MODULE__, :register_handler, accumulate: false)
      Module.register_attribute(__MODULE__, :presence_handler, accumulate: false)

      Module.put_attribute(__MODULE__, :current_scope, [])
      Module.put_attribute(__MODULE__, :current_pipelines, [])

      @before_compile Parrot.Router
    end
  end

  @doc """
  Defines a named pipeline with a list of plugs.
  """
  defmacro pipeline(name, do: block) do
    quote do
      # Reset current plugs for this pipeline
      Module.delete_attribute(__MODULE__, :current_plugs)
      Module.register_attribute(__MODULE__, :current_plugs, accumulate: true)

      unquote(block)

      plugs = Module.get_attribute(__MODULE__, :current_plugs) |> Enum.reverse()
      Module.put_attribute(__MODULE__, :pipelines, {unquote(name), plugs})
    end
  end

  @doc """
  Adds a plug to the current pipeline being defined.
  """
  defmacro plug(name, _opts \\ []) do
    quote do
      Module.put_attribute(__MODULE__, :current_plugs, unquote(name))
    end
  end

  @doc """
  Defines a scope with options and routes.
  """
  defmacro scope(_path, opts \\ [], do: block) do
    quote do
      # Save current scope state
      previous_scope = Module.get_attribute(__MODULE__, :current_scope) || []
      previous_pipelines = Module.get_attribute(__MODULE__, :current_pipelines) || []

      # Merge new scope options with parent scope
      scope_opts =
        case unquote(opts) do
          opts when is_list(opts) -> opts
          _ -> []
        end

      new_scope = Parrot.Router.merge_scope(previous_scope, scope_opts)
      Module.put_attribute(__MODULE__, :current_scope, new_scope)

      unquote(block)

      # Restore previous scope state
      Module.put_attribute(__MODULE__, :current_scope, previous_scope)
      Module.put_attribute(__MODULE__, :current_pipelines, previous_pipelines)
    end
  end

  @doc """
  Associates one or more pipelines with routes in the current scope.
  """
  defmacro pipe_through(pipeline_names) do
    quote do
      current_pipelines = Module.get_attribute(__MODULE__, :current_pipelines) || []

      new_pipelines =
        case unquote(pipeline_names) do
          names when is_list(names) -> names
          name -> [name]
        end

      Module.put_attribute(__MODULE__, :current_pipelines, current_pipelines ++ new_pipelines)
    end
  end

  @doc """
  Defines a route for INVITE requests matching the given pattern.
  """
  defmacro invite(pattern, handler) do
    quote do
      scope_opts = Module.get_attribute(__MODULE__, :current_scope) || []
      pipelines = Module.get_attribute(__MODULE__, :current_pipelines) || []

      route = %{
        pattern: unquote(pattern),
        handler: unquote(handler),
        scope: Map.new(scope_opts),
        pipelines: pipelines
      }

      Module.put_attribute(__MODULE__, :routes, route)
    end
  end

  @doc """
  Sets the handler for REGISTER requests.
  """
  defmacro register(handler) do
    quote do
      Module.put_attribute(__MODULE__, :register_handler, unquote(handler))
    end
  end

  @doc """
  Sets the handler for presence (SUBSCRIBE/PUBLISH) requests.
  """
  defmacro presence(handler) do
    quote do
      Module.put_attribute(__MODULE__, :presence_handler, unquote(handler))
    end
  end

  @doc false
  def merge_scope(parent_scope, child_scope) do
    # Merge child scope into parent, child takes precedence for same keys
    Keyword.merge(parent_scope, child_scope)
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      @doc """
      Returns the list of defined routes in order.
      """
      def __routes__ do
        @routes |> Enum.reverse()
      end

      @doc """
      Returns a map of defined pipelines.
      """
      def __pipelines__ do
        @pipelines |> Enum.into(%{})
      end

      @doc """
      Returns the registered handler module, or nil if not set.
      """
      def __register_handler__ do
        @register_handler
      end

      @doc """
      Returns the presence handler module, or nil if not set.
      """
      def __presence_handler__ do
        @presence_handler
      end

      @doc """
      Dispatches a SIP message to the appropriate handler.

      Returns `{:ok, handler, opts}` for a matching route, or
      `{:no_match, reason}` if no route matches.
      """
      def dispatch(%ParrotSip.Message{} = message) do
        Parrot.Router.Dispatcher.dispatch(__MODULE__, message)
      end
    end
  end
end
