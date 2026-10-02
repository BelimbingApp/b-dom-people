defmodule Bilimbi.People.Training.Web.PassportController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias Bilimbi.People.Training.Passport
  alias Bilimbi.People.Training.Web.Support
  def show(conn, %{"company_id" => company, "id" => id}), do: respond(conn, Passport.download(conn.assigns.current_scope.scope, Support.integer(company), id), "passport.pdf")
  def evidence(conn, %{"company_id" => company, "id" => id}), do: respond(conn, Passport.read_evidence(conn.assigns.current_scope.scope, Support.integer(company), id), "evidence.pdf")
  defp respond(conn, {:ok, %{bytes: bytes}}, filename) do
    conn |> put_resp_content_type("application/pdf") |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"") |> put_resp_header("cache-control", "private, no-store") |> put_resp_header("x-content-type-options", "nosniff") |> send_resp(200, bytes)
  end
  defp respond(conn, _, _), do: send_resp(conn, 404, "Document unavailable")
end
