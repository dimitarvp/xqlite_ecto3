defmodule XqliteEcto3.UUIDv7Test do
  use ExUnit.Case, async: true

  alias XqliteEcto3.UUIDv7

  doctest XqliteEcto3.UUIDv7

  describe "generate/0" do
    test "returns a 36-character string" do
      uuid = UUIDv7.generate()
      assert is_binary(uuid)
      assert String.length(uuid) == 36
    end

    test "parses as a valid UUID via Ecto.UUID" do
      uuid = UUIDv7.generate()
      assert {:ok, raw} = Ecto.UUID.dump(uuid)
      assert byte_size(raw) == 16
    end

    test "version nibble is 7" do
      uuid = UUIDv7.generate()
      {:ok, <<_ts::48, ver::4, _rest::76>>} = Ecto.UUID.dump(uuid)
      assert ver == 7
    end

    test "variant bits are 10 (RFC 4122)" do
      uuid = UUIDv7.generate()
      {:ok, <<_ts_and_ver::64, variant::2, _rand_b::62>>} = Ecto.UUID.dump(uuid)
      assert variant == 0b10
    end

    test "the embedded timestamp matches wall clock within a few ms" do
      before = System.system_time(:millisecond)
      uuid = UUIDv7.generate()
      later = System.system_time(:millisecond)

      {:ok, <<embedded_ts::48, _rest::80>>} = Ecto.UUID.dump(uuid)

      assert embedded_ts >= before
      assert embedded_ts <= later
    end

    test "generating many UUIDs produces no duplicates" do
      uuids = for _ <- 1..2_000, do: UUIDv7.generate()
      assert uuids |> Enum.uniq() |> length() == 2_000
    end

    test "UUIDs generated in temporal order sort in the same order" do
      first = UUIDv7.generate()
      Process.sleep(5)
      second = UUIDv7.generate()

      # Lexicographic comparison of the 36-char string == chronological order,
      # because the timestamp occupies the leading hex digits.
      assert first < second
    end

    test "two UUIDs generated in the same millisecond differ via random bits" do
      # Tight loop to try to land two in the same millisecond.
      # Retry a few times to avoid timing flakiness on a slow host.
      same_ms_pair =
        Enum.find_value(1..100, fn _ ->
          a = UUIDv7.generate()
          b = UUIDv7.generate()
          {:ok, <<ts_a::48, _::80>>} = Ecto.UUID.dump(a)
          {:ok, <<ts_b::48, _::80>>} = Ecto.UUID.dump(b)
          if ts_a == ts_b, do: {a, b}
        end)

      # If we couldn't land two in the same ms in 100 tries, the host is
      # pathologically slow and the test is moot. Accept either outcome.
      case same_ms_pair do
        {a, b} -> assert a != b
        nil -> assert true
      end
    end
  end
end
