defmodule Bilimbi.People.EmployeeWorkspace.Web.IndexLive do
  @moduledoc """
  Company-scoped People employee workbench.

  Every reload reads the directory through the facade, which requires
  `people.employees.view` now, so a filter after the grant is withdrawn shows
  the unavailable state instead of fresh employee facts.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.EmployeeWorkspace

  # Saved views are self-service: each one belongs to the signed-in actor and
  # the facade scopes every write to that actor's own views.
  @write_guard_opt_out ~w(save_view delete_view)

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_scope.actor
    company_id = actor.company_id

    case Company.get_company(actor.scope, company_id) do
      {:ok, company} ->
        {:ok,
         socket
         |> assign(:page_title, "Employees")
         |> assign(:company, company)
         |> assign(:company_id, company_id)
         |> assign(:search, "")
         |> assign(:status, "")
         |> load()}

      _ ->
        {:ok,
         socket
         |> assign(:page_title, "Employees")
         |> assign(:company, nil)
         |> assign(:company_id, nil)
         |> assign(:employees, [])
         |> assign(:views, [])
         |> assign(:search, "")
         |> assign(:status, "")}
    end
  end

  @impl true
  def handle_event("filter", %{"search" => search, "status" => status}, socket) do
    {:noreply,
     socket |> assign(:search, String.slice(search, 0, 200)) |> assign(:status, status) |> load()}
  end

  def handle_event("save_view", %{"view" => attrs}, socket) do
    if socket.assigns.company do
      attrs =
        Map.merge(attrs, %{"search" => socket.assigns.search, "status" => socket.assigns.status})

      case EmployeeWorkspace.save_view(scope(socket), socket.assigns.company_id, attrs) do
        {:ok, _} -> {:noreply, socket |> load() |> put_flash(:info, "View saved.")}
        {:error, :unauthorized} -> {:noreply, socket |> load() |> put_flash(:error, refusal())}
        _ -> {:noreply, put_flash(socket, :error, "Use a unique view name.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_view", %{"id" => raw_id}, socket) do
    case Integer.parse(raw_id) do
      {id, ""} ->
        case Enum.find(socket.assigns.views, &(&1.id == id)) do
          nil ->
            {:noreply, socket}

          view ->
            {:noreply,
             socket
             |> assign(:search, view.search || "")
             |> assign(:status, view.status || "")
             |> load()}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_view", %{"id" => raw_id}, socket) do
    with {id, ""} <- Integer.parse(raw_id),
         {:ok, :deleted} <-
           EmployeeWorkspace.delete_view(scope(socket), socket.assigns.company_id, id) do
      {:noreply, socket |> load() |> put_flash(:info, "View deleted.")}
    else
      {:error, :unauthorized} -> {:noreply, socket |> load() |> put_flash(:error, refusal())}
      _ -> {:noreply, put_flash(socket, :error, "View unavailable.")}
    end
  end

  defp refusal, do: "You no longer have permission to view this company's employees."

  defp load(%{assigns: %{company_id: nil}} = socket), do: socket

  defp load(socket) do
    with {:ok, employees} <-
           EmployeeWorkspace.employees(scope(socket), socket.assigns.company_id),
         {:ok, views} <- EmployeeWorkspace.saved_views(scope(socket), socket.assigns.company_id) do
      search = String.downcase(socket.assigns.search)
      status = socket.assigns.status

      visible =
        Enum.filter(employees, fn employee ->
          (search == "" or String.contains?(String.downcase(employee.full_name), search) or
             String.contains?(String.downcase(employee.employee_number), search)) and
            (status == "" or employee.status == status)
        end)

      socket |> assign(:employees, visible) |> assign(:views, views)
    else
      _ -> socket |> assign(:company, nil) |> assign(:employees, []) |> assign(:views, [])
    end
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
end
