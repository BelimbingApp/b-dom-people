defmodule BilimbiWeb.ReferenceDataLiveTest do
  use BilimbiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "reference editor requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, "/people/companies/73/references")
  end
end
