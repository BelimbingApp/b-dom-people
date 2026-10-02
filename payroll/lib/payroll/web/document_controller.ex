defmodule Bilimbi.People.Payroll.Web.DocumentController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  alias Bilimbi.People.Payroll

  def show(conn, %{"id" => id, "company_id" => company}) do
    with {company_id, ""} <- Integer.parse(company),
         {:ok, %{bytes: bytes}} <-
           Payroll.read_document(conn.assigns.current_scope.scope, company_id, id) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", "attachment; filename=\"payroll-#{id}.pdf\"")
      |> put_resp_content_type("application/pdf")
      |> send_resp(200, bytes)
    else
      _ -> send_resp(conn, 404, "Document unavailable")
    end
  end

  def show(conn, _), do: send_resp(conn, 404, "Document unavailable")
end
