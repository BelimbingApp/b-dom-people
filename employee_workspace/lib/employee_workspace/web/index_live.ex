defmodule Bilimbi.People.EmployeeWorkspace.Web.IndexLive do
  @moduledoc "Company-scoped People employee workbench."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Core.Company
  alias Bilimbi.People.EmployeeWorkspace

  @capability "people.employees.view"

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_scope.actor
    company_id = actor.company_id

    case Company.authorize_company_target(actor, company_id, @capability) do
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

      case EmployeeWorkspace.save_view(
             scope(socket),
             socket.assigns.company_id,
             actor_id(socket),
             attrs
           ) do
        {:ok, _} -> {:noreply, socket |> load() |> put_flash(:info, "View saved.")}
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
           EmployeeWorkspace.delete_view(
             scope(socket),
             socket.assigns.company_id,
             actor_id(socket),
             id
           ) do
      {:noreply, socket |> load() |> put_flash(:info, "View deleted.")}
    else
      _ -> {:noreply, put_flash(socket, :error, "View unavailable.")}
    end
  end

  defp load(socket) do
    with {:ok, employees} <-
           EmployeeWorkspace.employees(scope(socket), socket.assigns.company_id),
         {:ok, views} <-
           EmployeeWorkspace.saved_views(
             scope(socket),
             socket.assigns.company_id,
             actor_id(socket)
           ) do
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
  defp actor_id(socket), do: socket.assigns.current_scope.actor.id
end
