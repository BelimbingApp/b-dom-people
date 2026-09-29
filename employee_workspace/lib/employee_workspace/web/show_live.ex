defmodule Bilimbi.People.EmployeeWorkspace.Web.ShowLive do
  @moduledoc "Read-first People facts for one Core employee."
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Core.Company
  alias Bilimbi.People.EmployeeWorkspace

  @view "people.employees.view"
  @manage "people.employees.manage"
  @review "people.employees.review"

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    actor = socket.assigns.current_scope.actor
    company_id = actor.company_id
    employee_id = positive_id(raw_id)

    result =
      with true <- is_integer(employee_id),
           {:ok, _company} <- Company.authorize_company_target(actor, company_id, @view),
           {:ok, employee} <- EmployeeWorkspace.employee(actor.scope, company_id, employee_id) do
        {:ok, employee}
      else
        _ -> {:error, :not_found}
      end

    socket =
      socket
      |> assign(:page_title, "Employee workbench")
      |> assign(:company_id, company_id)
      |> assign(:employee_id, employee_id)
      |> assign(:can_manage, Authz.can(actor, @manage).allowed)
      |> assign(:can_review, Authz.can(actor, @review).allowed)

    case result do
      {:ok, employee} -> {:ok, socket |> assign(:employee, employee) |> load_facts()}
      _ -> {:ok, socket |> assign(:employee, nil) |> assign(:profile, nil)
             |> assign(:access, nil) |> assign(:requests, [])}
    end
  end

  @impl true
  def handle_event("save_profile", %{"profile" => attrs}, socket) do
    if socket.assigns.employee && socket.assigns.can_manage do
      case EmployeeWorkspace.put_work_profile(scope(socket), company_id(socket), employee_id(socket), attrs) do
        {:ok, _} -> {:noreply, socket |> load_facts() |> put_flash(:info, "Work profile saved.")}
        _ -> {:noreply, put_flash(socket, :error, "Check the work profile values.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_access", %{"access" => attrs}, socket) do
    if socket.assigns.employee && socket.assigns.can_manage do
      case EmployeeWorkspace.put_access(scope(socket), company_id(socket), employee_id(socket), attrs) do
        {:ok, _} -> {:noreply, socket |> load_facts() |> put_flash(:info, "Portal access saved.")}
        _ -> {:noreply, put_flash(socket, :error, "Check the access values.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("request_change", %{"request" => attrs}, socket) do
    if socket.assigns.employee && socket.assigns.can_manage do
      case EmployeeWorkspace.request_change(scope(socket), company_id(socket), employee_id(socket), actor_id(socket), attrs) do
        {:ok, _} -> {:noreply, socket |> load_facts() |> put_flash(:info, "Change request recorded.")}
        _ -> {:noreply, put_flash(socket, :error, "Check the proposed change.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("review_change", %{"id" => raw_id, "decision" => decision}, socket) do
    if socket.assigns.employee && socket.assigns.can_review do
      case EmployeeWorkspace.review_change(scope(socket), company_id(socket), employee_id(socket), positive_id(raw_id), actor_id(socket), decision) do
        {:ok, _} -> {:noreply, socket |> load_facts() |> put_flash(:info, "Request reviewed. Core employee details are unchanged.")}
        _ -> {:noreply, put_flash(socket, :error, "Request cannot be reviewed.")}
      end
    else
      {:noreply, socket}
    end
  end

  defp load_facts(socket) do
    scope = scope(socket)
    company_id = company_id(socket)
    employee_id = employee_id(socket)
    {:ok, profile} = EmployeeWorkspace.work_profile(scope, company_id, employee_id)
    {:ok, access} = EmployeeWorkspace.access(scope, company_id, employee_id)
    {:ok, requests} = EmployeeWorkspace.change_requests(scope, company_id, employee_id)

    socket |> assign(:profile, profile) |> assign(:access, access)
    |> assign(:requests, requests)
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp actor_id(socket), do: socket.assigns.current_scope.actor.id
  defp company_id(socket), do: socket.assigns.company_id
  defp employee_id(socket), do: socket.assigns.employee_id

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_id(_), do: nil
end
