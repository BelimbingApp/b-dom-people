defmodule Bilimbi.People.Workforce.Snapshot do
  @moduledoc "One read result with explicit source freshness."

  @enforce_keys [:source_id, :status, :observed_at, :value]
  defstruct [:source_id, :status, :observed_at, :value]

  @type t :: %__MODULE__{
          source_id: String.t(),
          status: :current | :stale | :unavailable,
          observed_at: DateTime.t() | nil,
          value: term()
        }

  @spec current(String.t(), term()) :: t()
  def current(source_id, value) when is_binary(source_id) do
    %__MODULE__{
      source_id: source_id,
      status: :current,
      observed_at: DateTime.utc_now(),
      value: value
    }
  end

  @spec require_current(t()) :: {:ok, term()} | {:error, :stale | :unavailable}
  def require_current(%__MODULE__{status: :current, value: value}), do: {:ok, value}
  def require_current(%__MODULE__{status: :stale}), do: {:error, :stale}
  def require_current(%__MODULE__{status: :unavailable}), do: {:error, :unavailable}
end
