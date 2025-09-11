defmodule ParrotSip.Headers.Allow do
  @moduledoc """
  Module for working with SIP Allow headers as defined in RFC 3261 Section 20.5.

  The Allow header field lists the set of methods supported by the User Agent
  generating the message. The Allow header field MUST be present in a 405
  (Method Not Allowed) response.

  This module uses `ParrotSip.MethodSet` internally for efficient method set operations.

  References:
  - RFC 3261 Section 20.5: Allow Header Field
  """

  alias ParrotSip.{Method, MethodSet}

  @doc """
  Creates a new Allow header with the specified methods.

  ## Examples

      iex> ParrotSip.Headers.Allow.new([:invite, :ack, :bye])
      %ParrotSip.MethodSet{}
  """
  @spec new([Method.t() | String.t()]) :: MethodSet.t()
  def new(methods) when is_list(methods), do: MethodSet.new(methods)

  @doc """
  Creates a standard set of common SIP methods.

  ## Examples

      iex> ParrotSip.Headers.Allow.standard()
      #ParrotSip.MethodSet<[:ack, :bye, :cancel, :invite, :message, :notify, :options, :register, :subscribe]>
  """
  @spec standard() :: MethodSet.t()
  def standard do
    MethodSet.standard_methods()
  end

  @doc """
  Parses an Allow header string into a method set.

  ## Examples

      iex> ParrotSip.Headers.Allow.parse("INVITE, ACK, BYE")
      #ParrotSip.MethodSet<[:ack, :bye, :invite]>
      
      iex> ParrotSip.Headers.Allow.parse("")
      #ParrotSip.MethodSet<[]>
  """
  @spec parse(String.t()) :: MethodSet.t()
  def parse(""), do: MethodSet.new()

  def parse(string) when is_binary(string) do
    MethodSet.from_allow_string(string)
  end

  @doc """
  Formats a method set as a string for the Allow header.

  ## Examples

      iex> set = ParrotSip.MethodSet.new([:invite, :ack, :bye])
      iex> ParrotSip.Headers.Allow.format(set)
      "INVITE, ACK, BYE"
      
      iex> ParrotSip.Headers.Allow.format(ParrotSip.MethodSet.new())
      ""
  """
  @spec format(MethodSet.t()) :: String.t()
  def format(%MethodSet{methods: methods}) when map_size(methods) == 0, do: ""

  def format(%MethodSet{} = method_set) do
    MethodSet.to_allow_string(method_set)
  end

  # For backward compatibility
  def format([]), do: ""

  def format(methods) when is_list(methods) do
    MethodSet.new(methods) |> format()
  end

  @doc """
  Adds a method to the Allow header.

  ## Examples

      iex> set = ParrotSip.MethodSet.new([:invite, :ack])
      iex> ParrotSip.Headers.Allow.add(set, :bye)
      #ParrotSip.MethodSet<[:ack, :bye, :invite]>
      
      iex> set = ParrotSip.MethodSet.new([:invite, :ack, :bye])
      iex> ParrotSip.Headers.Allow.add(set, :invite)
      #ParrotSip.MethodSet<[:ack, :bye, :invite]>
  """
  @spec add(MethodSet.t(), Method.t() | String.t()) :: MethodSet.t()
  def add(%MethodSet{} = method_set, method) do
    MethodSet.put(method_set, method)
  end

  # For backward compatibility
  def add(methods, method) when is_list(methods) do
    MethodSet.new(methods) |> add(method)
  end

  @doc """
  Removes a method from the Allow header.

  ## Examples

      iex> set = ParrotSip.MethodSet.new([:invite, :ack, :bye])
      iex> ParrotSip.Headers.Allow.remove(set, :invite)
      #ParrotSip.MethodSet<[:ack, :bye]>
      
      iex> set = ParrotSip.MethodSet.new([:invite, :ack])
      iex> ParrotSip.Headers.Allow.remove(set, :bye)
      #ParrotSip.MethodSet<[:ack, :invite]>
  """
  @spec remove(MethodSet.t(), Method.t() | String.t()) :: MethodSet.t()
  def remove(%MethodSet{} = method_set, method) do
    MethodSet.delete(method_set, method)
  end

  # For backward compatibility
  def remove(methods, method) when is_list(methods) do
    MethodSet.new(methods) |> remove(method)
  end

  @doc """
  Checks if a specific method is allowed.

  ## Examples

      iex> set = ParrotSip.MethodSet.new([:invite, :ack, :bye])
      iex> ParrotSip.Headers.Allow.allows?(set, :invite)
      true
      
      iex> set = ParrotSip.MethodSet.new([:invite, :ack])
      iex> ParrotSip.Headers.Allow.allows?(set, :bye)
      false
  """
  @spec allows?(MethodSet.t(), Method.t() | String.t()) :: boolean()
  def allows?(%MethodSet{} = method_set, method) do
    MethodSet.member?(method_set, method)
  end

  # For backward compatibility
  def allows?(methods, method) when is_list(methods) do
    MethodSet.new(methods) |> allows?(method)
  end
end
