defmodule Bilimbi.People.Payroll.ReplayTest do
  use ExUnit.Case, async: true
  alias Bilimbi.Base.Artifacts.PDF.Renderer
  alias Bilimbi.People.Payroll.Replay

  test "six-place rates and quantities replay exactly independent of order and ambient precision" do
    setup = %{"items" => [%{"id" => 1, "code" => "item", "amount" => "1234567890123.123456"}]}

    a = %{
      "source_key" => "a",
      "employee_id" => 2,
      "item_id" => 1,
      "units" => "0.000001",
      "direction" => "earning"
    }

    b = %{a | "source_key" => "b", "units" => "1.000001", "direction" => "deduction"}
    result = Replay.calculate(setup, [b, a])
    assert result == Replay.calculate(setup, [a, b])

    assert result ==
             Decimal.Context.with(%Decimal.Context{precision: 3}, fn ->
               Replay.calculate(setup, [b, a])
             end)

    assert hd(result["lines"])["amount"] == "1234567.890123123456"
    assert hd(result["totals"])["net"] == "-1234567890123.123456000000"
  end

  test "employer contributions are reported separately from employee net" do
    setup = %{"items" => [%{"id" => 1, "amount" => "0.1", "code" => "item"}]}

    inputs =
      for {direction, key} <- [{"earning", "a"}, {"deduction", "b"}, {"employer", "c"}] do
        %{
          "source_key" => key,
          "employee_id" => 1,
          "item_id" => 1,
          "units" => "0.2",
          "direction" => direction
        }
      end

    assert [%{"net" => "0.00", "employer" => "0.02"}] = Replay.calculate(setup, inputs)["totals"]
  end

  test "generated paginated PDF can be opened by a real reader" do
    document = %{
      title: "Payroll report",
      blocks: for(n <- 1..100, do: {:text, "Employee #{n} (exact amount) \\ 1.234567"})
    }

    assert {:ok, pdf} = Renderer.render(document)
    assert {:ok, ^pdf} = Renderer.render(document)

    if executable = System.find_executable("pdfinfo") do
      path = Path.join(System.tmp_dir!(), "payroll-pdf-#{Ecto.UUID.generate()}.pdf")

      File.write!(path, pdf)

      on_exit(fn -> File.rm(path) end)
      {info, 0} = System.cmd(executable, [path], stderr_to_stdout: true)
      assert info =~ "Pages:           3"
    end
  end
end
