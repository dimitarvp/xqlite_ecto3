defmodule XqliteEcto3.UUIDv7 do
  @moduledoc """
  UUID v7 generator.

  Per [RFC 9562 section 5.7](https://www.rfc-editor.org/rfc/rfc9562#section-5.7),
  v7 UUIDs are time-ordered: the first 48 bits are a Unix millisecond
  timestamp, so sorting by UUID value approximates sorting by creation
  time. This keeps B-tree indexes tight and avoids the random-scatter
  pathology that v4 imposes on inserts.

  ## Layout (128 bits)

      | bits | contents                           |
      |------|------------------------------------|
      | 0–47 | unix timestamp (milliseconds, BE) |
      | 48–51| version nibble (`0b0111` = 7)     |
      | 52–63| 12 random bits                    |
      | 64–65| variant bits (`0b10`)             |
      | 66–127| 62 random bits                   |

  Random bits come from `:crypto.strong_rand_bytes/1`.

  ## Usage with Ecto

  Wire it into a schema's `@primary_key` autogenerate slot:

      defmodule MyApp.Thing do
        use Ecto.Schema

        @primary_key {:id, :binary_id, autogenerate: {XqliteEcto3.UUIDv7, :generate, []}}
        schema "things" do
          # ...
        end
      end

  The `:binary_id` Ecto type handles storage (TEXT or BLOB, controlled
  by `config :xqlite_ecto3, :binary_id_storage`). This module only
  produces the 36-character string form.
  """

  @doc """
  Generates a UUID v7 as a 36-character string.

  ## Examples

      iex> uuid = XqliteEcto3.UUIDv7.generate()
      iex> {:ok, _} = Ecto.UUID.cast(uuid)
      iex> String.length(uuid)
      36

      iex> uuid = XqliteEcto3.UUIDv7.generate()
      iex> <<_::binary-size(14), version::binary-size(1), _rest::binary>> = uuid
      iex> version
      "7"
  """
  @spec generate() :: Ecto.UUID.t()
  def generate do
    ts_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _padding::6>> = :crypto.strong_rand_bytes(10)
    bin = <<ts_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    {:ok, str} = Ecto.UUID.load(bin)
    str
  end
end
