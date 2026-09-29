defmodule Bilimbi.People.Workforce.Reference do
  @moduledoc "A stable provider reference, separate from a login actor or database schema."

  @enforce_keys [:source_id, :type, :stable_id]
  defstruct [:source_id, :type, :stable_id]

  @type t :: %__MODULE__{
          source_id: String.t(),
          type: :company | :employee | :position | :assignment,
          stable_id: String.t()
        }
end
