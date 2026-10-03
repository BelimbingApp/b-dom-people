defmodule Bilimbi.People.EmployeeWorkspace.Web.ShowLive do
  @moduledoc """
  Read-first People facts for one Core employee.

  The `can_manage?` and `can_review?` assigns only decide which controls
  render; they are refreshed before every event so a withdrawn grant hides
  its controls. Authority for each operation is the facade's own check, so
  an event that slips past the assigns is still refused there.
  """
  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.People.EmployeeWorkspace
  alias Bilimbi.People.Workforce.Authorization

  @manage_events ~w(save_profile save_access request_change)
  @review_events ~w(review_change)

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    actor = socket.assigns.current_scope.actor
    company_id = actor.company_id
    employee_id = positive_id(raw_id)

    result =
      with true <- is_integer(employee_id),
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
      |> refresh_access()
      |> attach_hook(:employee_access, :handle_event, fn _event, _params, socket ->
        {:cont, refresh_access(socket)}
      end)

    case result do
      {:ok, employee} ->
        {:ok, socket |> assign(:employee, employee) |> load_facts()}

      _ ->
        {:ok, clear_facts(socket)}
    end
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{can_manage?: false}} = socket)
      when event in @manage_events,
      do: {:noreply, put_flash(socket, :error, refusal(:unauthorized))}

  def handle_event(event, _params, %{assigns: %{can_review?: false}} = socket)
      when event in @review_events,
      do: {:noreply, put_flash(socket, :error, refusal(:unauthorized))}

  def handle_event("save_profile", %{"profile" => attrs}, socket) do
    if socket.assigns.employee do
      case EmployeeWorkspace.put_work_profile(
             scope(socket),
             company_id(socket),
             employee_id(socket),
             attrs
           ) do
        {:ok, _} -> {:noreply, socket |> load_facts() |> put_flash(:info, "Work profile saved.")}
        {:error, :unauthorized} -> {:noreply, refused(socket)}
        _ -> {:noreply, put_flash(socket, :error, "Check the work profile values.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_access", %{"access" => attrs}, socket) do
    if socket.assigns.employee do
      case EmployeeWorkspace.put_access(
             scope(socket),
             company_id(socket),
             employee_id(socket),
             attrs
           ) do
        {:ok, _} -> {:noreply, socket |> load_facts() |> put_flash(:info, "Portal access saved.")}
        {:error, :unauthorized} -> {:noreply, refused(socket)}
        _ -> {:noreply, put_flash(socket, :error, "Check the access values.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("request_change", %{"request" => attrs}, socket) do
    if socket.assigns.employee do
      case EmployeeWorkspace.request_change(
             scope(socket),
             company_id(socket),
             employee_id(socket),
             attrs
           ) do
        {:ok, _} ->
          {:noreply, socket |> load_facts() |> put_flash(:info, "Change request recorded.")}

        {:error, :unauthorized} ->
          {:noreply, refused(socket)}

        _ ->
          {:noreply, put_flash(socket, :error, "Check the proposed change.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("review_change", %{"id" => raw_id, "decision" => decision}, socket) do
    if socket.assigns.employee do
      case EmployeeWorkspace.review_change(
             scope(socket),
             company_id(socket),
             employee_id(socket),
             positive_id(raw_id),
             decision
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> load_facts()
           |> put_flash(:info, "Request reviewed. Core employee details are unchanged.")}

        {:error, :unauthorized} ->
          {:noreply, refused(socket)}

        _ ->
          {:noreply, put_flash(socket, :error, "Request cannot be reviewed.")}
      end
    else
      {:noreply, socket}
    end
  end

  @doc "Operator-facing text for a refusal."
  def refusal(:unauthorized),
    do: "You no longer have permission to change this employee's People facts."

  defp refused(socket), do: socket |> load_facts() |> put_flash(:error, refusal(:unauthorized))

  defp refresh_access(socket) do
    scope = scope(socket)
    company_id = company_id(socket)

    socket
    |> assign(
      :can_manage?,
      Authorization.allowed?(scope, company_id, EmployeeWorkspace.manage_capability())
    )
    |> assign(
      :can_review?,
      Authorization.allowed?(scope, company_id, EmployeeWorkspace.review_capability())
    )
  end

  # Every read re-authorizes `people.employees.view`; a refusal shows the
  # unavailable state rather than facts fetched before the revocation.
  defp load_facts(socket) do
    scope = scope(socket)
    company_id = company_id(socket)
    employee_id = employee_id(socket)

    with {:ok, profile} <- EmployeeWorkspace.work_profile(scope, company_id, employee_id),
         {:ok, access} <- EmployeeWorkspace.access(scope, company_id, employee_id),
         {:ok, requests} <- EmployeeWorkspace.change_requests(scope, company_id, employee_id) do
      socket
      |> assign(:profile, profile)
      |> assign(:access, access)
      |> assign(:requests, requests)
    else
      _ -> clear_facts(socket)
    end
  end

  defp clear_facts(socket) do
    socket
    |> assign(:employee, nil)
    |> assign(:profile, nil)
    |> assign(:access, nil)
    |> assign(:requests, [])
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
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
