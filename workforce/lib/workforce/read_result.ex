defmodule Bilimbi.People.Workforce.ReadResult do
  @moduledoc """
  A workforce read value and the freshness state callers may rely on.

  Native reads are current. Adapters can represent cached stale values with the
  time they were last confirmed, or unavailable data with a reason.
  """

  @enforce_keys [:freshness]
  defstruct [:value, :freshness]

  @type freshness ::
          :current
          | {:stale, DateTime.t()}
          | {:unavailable, atom() | String.t()}

  @type t :: %__MODULE__{value: term(), freshness: freshness()}

  @spec current(term()) :: t()
  def current(value), do: %__MODULE__{value: value, freshness: :current}

  @spec stale(term(), DateTime.t()) :: t()
  def stale(value, %DateTime{} = last_confirmed_at),
    do: %__MODULE__{value: value, freshness: {:stale, last_confirmed_at}}

  @spec unavailable(atom() | String.t()) :: t()
  def unavailable(reason) when is_atom(reason) or is_binary(reason),
    do: %__MODULE__{value: nil, freshness: {:unavailable, reason}}

  @spec require_current(t()) :: {:ok, term()} | {:error, {:not_current, freshness()}}
  def require_current(%__MODULE__{freshness: :current, value: value}), do: {:ok, value}

  def require_current(%__MODULE__{freshness: freshness}),
    do: {:error, {:not_current, freshness}}
end
