defmodule Bilimbi.People.Payroll.PDF do
  @moduledoc false

  # A complete paginated PDF with built-in Helvetica, no resources or executable
  # renderer. Only frozen identifiers and exact decimals enter this template.
  def render(lines) do
    pages = lines |> Enum.flat_map(&wrap/1) |> Enum.chunk_every(48)
    count = length(pages)
    page_ids = for n <- 0..(count - 1), do: 4 + n * 2
    objects = ["<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Count #{count} /Kids [#{Enum.map_join(page_ids, " ", &"#{&1} 0 R")}] >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"] ++
      Enum.flat_map(Enum.with_index(pages), fn {page, n} ->
        stream = "BT /F1 10 Tf 40 800 Td 15 TL\n" <>
          Enum.map_join(page, "\n", &"(#{escape(&1)}) Tj T*") <> "\nET\n"
        ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents #{5 + n * 2} 0 R >>",
         "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}endstream"]
      end)
    {body, offsets} = Enum.reduce(Enum.with_index(objects, 1), {"%PDF-1.4\n", []}, fn {object, id}, {body, offsets} ->
      {body <> "#{id} 0 obj\n#{object}\nendobj\n", offsets ++ [byte_size(body)]}
    end)
    xref = "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <>
      Enum.map_join(offsets, "", &(String.pad_leading(to_string(&1), 10, "0") <> " 00000 n \n"))
    body <> xref <> "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end

  defp wrap(line), do: line |> String.to_charlist() |> Enum.chunk_every(90) |> Enum.map(&List.to_string/1)
  defp escape(text), do: text |> String.replace("\\", "\\\\") |> String.replace("(", "\\(") |> String.replace(")", "\\)")
end
