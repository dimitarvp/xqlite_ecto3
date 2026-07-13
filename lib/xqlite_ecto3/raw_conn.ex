defmodule XqliteEcto3.RawConn do
  @moduledoc false

  # Sentinel DBConnection query: `XqliteEcto3.Driver.handle_execute/4`
  # answers it with the raw XqliteNIF connection reference instead of
  # running SQL. Exists solely to power `XqliteEcto3.with_xqlite/3`.
  defstruct []

  defimpl DBConnection.Query do
    def parse(query, _opts), do: query
    def describe(query, _opts), do: query
    def encode(_query, _params, _opts), do: []
    def decode(_query, result, _opts), do: result
  end

  defimpl String.Chars do
    def to_string(_query), do: "#raw-conn-handle"
  end
end
