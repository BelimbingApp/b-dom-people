defmodule Bilimbi.People.Training.DocumentOwner do
  @moduledoc false
  @behaviour Bilimbi.Base.Artifacts.Owner
  @behaviour Bilimbi.Base.Artifacts.PDF
  alias Bilimbi.People.Training.Participation
  @impl true
  def artifact_owner_id, do: "people/training"
  @impl true
  def authorize(scope, company, :purge, nil),
    do: permit(scope, company, "people.training.retention.manage")

  def authorize(scope, company, operation, %{subject: subject, kind: "passport"})
      when operation in [:read, :create],
      do: Bilimbi.People.Training.Passport.authorize_subject(scope, company, subject, operation)

  def authorize(scope, company, :delete, %{kind: "passport"}),
    do: permit(scope, company, "people.training.retention.manage")

  def authorize(scope, company, :read, %{subject: id, kind: "evidence"}) do
    if match?(%{id: _}, Participation.fact(scope, company, id)) or
         Bilimbi.People.Training.Passport.can_read_fact?(scope, company, id),
       do: :ok,
       else: {:error, :forbidden}
  end

  def authorize(scope, company, operation, %{subject: id, kind: "evidence"})
      when operation in [:create, :delete] do
    capability =
      case operation do
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

  @impl true
  def render_pdf(_, _, _, data), do: Bilimbi.Base.Artifacts.PDF.Renderer.render(data)

  defp permit(scope, company, capability) do
    case Participation.authorize(scope, company, capability) do
      {:ok, _} -> :ok
      _ -> {:error, :forbidden}
    end
  end
end
