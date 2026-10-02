defmodule Bilimbi.People.Training.Web.EvidenceController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias Bilimbi.People.Training.Participation
  alias Bilimbi.People.Training.Web.Support

  def show(conn, %{"company_id" => company, "id" => id}) do
    case Participation.read_evidence(
           conn.assigns.current_scope.scope,
           Support.integer(company),
           id
         ) do
      {:ok, %{bytes: bytes, metadata: metadata}} ->
        conn
        |> put_resp_content_type(metadata.content_type)
        |> put_resp_header("content-disposition", "attachment; filename=\"evidence.pdf\"")
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, bytes)

      {:error, _} ->
        send_resp(conn, 404, "Evidence unavailable")
    end
  end
end
