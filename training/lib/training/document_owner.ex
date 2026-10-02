defmodule Bilimbi.People.Training.DocumentOwner do
  @moduledoc false
  @behaviour Bilimbi.Base.Artifacts.Owner
  alias Bilimbi.People.Training.Participation
  @impl true
  def artifact_owner_id, do: "people/training"
  @impl true
  def authorize(scope, company, :purge, nil),
    do: permit(scope, company, "people.training.retention.manage")

  def authorize(scope, company, operation, %{subject: id, kind: "evidence"})
      when operation in [:read, :create, :delete] do
    capability =
      case operation do
        :read -> "people.training.records.view"
        :create -> "people.training.evidence.manage"
        :delete -> "people.training.retention.manage"
      end

    with :ok <- permit(scope, company, capability),
         %{id: _} <- Participation.fact(scope, company, id, capability) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def authorize(_, _, _, _), do: {:error, :forbidden}

  defp permit(scope, company, capability) do
    case Participation.authorize(scope, company, capability) do
      {:ok, _} -> :ok
      _ -> {:error, :forbidden}
    end
  end
end
