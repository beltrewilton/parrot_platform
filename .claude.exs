%{
  # Stop execution on errors to prevent broken commits
  hooks: %{
    stop: [:compile, :format, :credo],
    post_tool_use: [:compile, :format],
    pre_tool_use: [:check_sipp_available]
  },

  # Phoenix/Elixir development tools (will add more as needed)
  mcp_servers: [],

  # Project-specific sub-agents for specialized reviews
  subagents: [
    %{
      name: "sip-expert",
      type: "code-reviewer",
      description: "Reviews SIP protocol compliance against RFC 3261",
      context: "apps/parrot_sip/",
      rules: "usage-rules/sip.md"
    },
    %{
      name: "media-expert",
      type: "code-reviewer",
      description: "Reviews media handling patterns and Membrane pipelines",
      context: "apps/parrot_media/",
      rules: "usage-rules/media.md"
    },
    %{
      name: "transport-expert",
      type: "code-reviewer",
      description: "Reviews transport layer protocol-agnostic design",
      context: "apps/parrot_transport/",
      rules: "apps/parrot_transport/CORRECT_INTEGRATION.md"
    },
    %{
      name: "test-generator",
      type: "general-purpose",
      description: "Generates SIPp scenarios and property-based tests",
      context: "test/",
      rules: "usage-rules/testing.md"
    },
    %{
      name: "doc-writer",
      type: "general-purpose",
      description: "Writes comprehensive documentation following project style",
      context: "guides/",
      rules: "guides/overview.md"
    }
  ],

  # Verbosity level
  verbosity: :normal
}
