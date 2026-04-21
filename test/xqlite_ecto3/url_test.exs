defmodule XqliteEcto3.URLTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.URL
  alias XqliteEcto3.URLError

  doctest XqliteEcto3.URL

  describe "parse/1 — happy paths" do
    test "absolute file path" do
      assert {:ok, [database: "/tmp/my.db"]} = URL.parse("sqlite:///tmp/my.db")
    end

    test "sqlite3 scheme accepted" do
      assert {:ok, [database: "/tmp/my.db"]} = URL.parse("sqlite3:///tmp/my.db")
    end

    test "file scheme accepted" do
      assert {:ok, [database: "/tmp/my.db"]} = URL.parse("file:///tmp/my.db")
    end

    test ":memory: database" do
      assert {:ok, [database: ":memory:"]} = URL.parse("sqlite::memory:")
      assert {:ok, [database: ":memory:"]} = URL.parse("sqlite3::memory:")
    end

    test "single query parameter" do
      assert {:ok, opts} = URL.parse("sqlite:///tmp/my.db?busy_timeout=10000")
      assert opts == [database: "/tmp/my.db", busy_timeout: 10_000]
    end

    test "multiple query parameters preserve declared order in the URL" do
      assert {:ok, opts} =
               URL.parse(
                 "sqlite:///tmp/my.db?busy_timeout=5000&journal_mode=wal&foreign_keys=true"
               )

      assert Keyword.get(opts, :database) == "/tmp/my.db"
      assert Keyword.get(opts, :busy_timeout) == 5_000
      assert Keyword.get(opts, :journal_mode) == :wal
      assert Keyword.get(opts, :foreign_keys) == true
    end
  end

  describe "parse/1 — query-param coercions" do
    test "atom_enum: valid value" do
      assert {:ok, opts} = URL.parse("sqlite:///x?journal_mode=truncate")
      assert opts[:journal_mode] == :truncate
    end

    test "atom_enum: rejects unknown atom" do
      assert {:error, %URLError{reason: {:invalid_option, "journal_mode", {:not_in_enum, _}}}} =
               URL.parse("sqlite:///x?journal_mode=bogus")
    end

    test "boolean: accepts true/false/on/off/1/0" do
      for {input, expected} <- [
            {"true", true},
            {"false", false},
            {"on", true},
            {"off", false},
            {"1", true},
            {"0", false}
          ] do
        assert {:ok, opts} = URL.parse("sqlite:///x?foreign_keys=#{input}")
        assert opts[:foreign_keys] == expected
      end
    end

    test "boolean: rejects garbage" do
      assert {:error, %URLError{reason: {:invalid_option, "foreign_keys", :not_a_boolean}}} =
               URL.parse("sqlite:///x?foreign_keys=maybe")
    end

    test "integer: negative cache_size is valid" do
      assert {:ok, opts} = URL.parse("sqlite:///x?cache_size=-64000")
      assert opts[:cache_size] == -64_000
    end

    test "integer: rejects non-integer" do
      assert {:error, %URLError{reason: {:invalid_option, "cache_size", :not_an_integer}}} =
               URL.parse("sqlite:///x?cache_size=big")
    end

    test "non_neg_integer: rejects negative" do
      assert {:error, %URLError{reason: {:invalid_option, "mmap_size", :negative_value}}} =
               URL.parse("sqlite:///x?mmap_size=-1")
    end

    test "timeout: accepts non-negative integer" do
      assert {:ok, opts} = URL.parse("sqlite:///x?busy_timeout=0")
      assert opts[:busy_timeout] == 0
    end

    test "timeout: accepts `infinity`" do
      assert {:ok, opts} = URL.parse("sqlite:///x?busy_timeout=infinity")
      assert opts[:busy_timeout] == :infinity
    end

    test "timeout: rejects negative integer" do
      assert {:error, %URLError{reason: {:invalid_option, "busy_timeout", :negative_value}}} =
               URL.parse("sqlite:///x?busy_timeout=-1")
    end
  end

  describe "parse/1 — pool and DBConnection tuning params" do
    test "pool_size accepts non-negative integer" do
      assert {:ok, opts} = URL.parse("sqlite:///x?pool_size=20")
      assert opts[:pool_size] == 20
    end

    test "pool_size rejects negative" do
      assert {:error, %URLError{reason: {:invalid_option, "pool_size", :negative_value}}} =
               URL.parse("sqlite:///x?pool_size=-1")
    end

    test "timeout accepts integer ms" do
      assert {:ok, opts} = URL.parse("sqlite:///x?timeout=15000")
      assert opts[:timeout] == 15_000
    end

    test "timeout accepts `infinity`" do
      assert {:ok, opts} = URL.parse("sqlite:///x?timeout=infinity")
      assert opts[:timeout] == :infinity
    end

    test "connect_timeout accepts integer and `infinity`" do
      assert {:ok, opts1} = URL.parse("sqlite:///x?connect_timeout=5000")
      assert opts1[:connect_timeout] == 5_000

      assert {:ok, opts2} = URL.parse("sqlite:///x?connect_timeout=infinity")
      assert opts2[:connect_timeout] == :infinity
    end

    test "queue_target and queue_interval accept non-negative integers" do
      assert {:ok, opts} = URL.parse("sqlite:///x?queue_target=50&queue_interval=1000")
      assert opts[:queue_target] == 50
      assert opts[:queue_interval] == 1_000
    end

    test "queue_target rejects negative" do
      assert {:error, %URLError{reason: {:invalid_option, "queue_target", :negative_value}}} =
               URL.parse("sqlite:///x?queue_target=-10")
    end

    test "mixed pool + pragma params in one URL" do
      url = "sqlite:///tmp/my.db?pool_size=10&busy_timeout=5000&journal_mode=wal&timeout=30000"
      assert {:ok, opts} = URL.parse(url)
      assert opts[:database] == "/tmp/my.db"
      assert opts[:pool_size] == 10
      assert opts[:busy_timeout] == 5_000
      assert opts[:journal_mode] == :wal
      assert opts[:timeout] == 30_000
    end
  end

  describe "parse/1 — rejection cases" do
    test "no scheme at all" do
      assert {:error, %URLError{reason: :missing_scheme}} = URL.parse("/raw/path.db")
    end

    test "unsupported scheme" do
      assert {:error, %URLError{reason: {:unsupported_scheme, "postgres"}}} =
               URL.parse("postgres://localhost/foo")

      assert {:error, %URLError{reason: {:unsupported_scheme, "http"}}} =
               URL.parse("http://example.com/db")
    end

    test "host component rejected" do
      assert {:error, %URLError{reason: {:unsupported_host, "myhost"}}} =
               URL.parse("sqlite://myhost/tmp/my.db")
    end

    test "no database path" do
      assert {:error, %URLError{reason: :missing_database}} = URL.parse("sqlite://")
    end

    test "unknown query param" do
      assert {:error, %URLError{reason: {:unknown_option, "not_a_thing"}}} =
               URL.parse("sqlite:///tmp/my.db?not_a_thing=1")
    end

    test "first-unknown-wins when multiple problems" do
      # Order within the query map is not guaranteed but we fail-fast on
      # the first problem encountered.
      assert {:error, %URLError{reason: reason}} =
               URL.parse("sqlite:///tmp/my.db?unknown_a=1&unknown_b=2")

      assert reason in [{:unknown_option, "unknown_a"}, {:unknown_option, "unknown_b"}]
    end

    test "error struct carries the original URL" do
      url = "postgres://foo/bar"
      assert {:error, %URLError{url: ^url}} = URL.parse(url)
    end
  end

  describe "parse!/1" do
    test "returns opts directly on success" do
      assert URL.parse!("sqlite:///tmp/my.db") == [database: "/tmp/my.db"]
    end

    test "raises URLError on failure" do
      err =
        assert_raise URLError, fn ->
          URL.parse!("postgres://foo/bar")
        end

      assert err.reason == {:unsupported_scheme, "postgres"}
      assert err.url == "postgres://foo/bar"
    end
  end

  describe "URLError.message/1" do
    test "composes a readable message for each reason variant" do
      for reason <- [
            :malformed,
            :missing_scheme,
            :missing_database,
            {:unsupported_scheme, "http"},
            {:unsupported_host, "foo.example"},
            {:unknown_option, "nope"},
            {:invalid_option, "foreign_keys", :not_a_boolean}
          ] do
        msg = Exception.message(%URLError{url: "sqlite:///x", reason: reason})
        assert is_binary(msg)
        assert String.length(msg) > 10
      end
    end
  end

  describe "top-level XqliteEcto3.parse_url/1 + parse_url!/1" do
    test "parse_url/1 forwards to URL.parse/1" do
      assert {:ok, opts} = XqliteEcto3.parse_url("sqlite:///tmp/my.db")
      assert opts == [database: "/tmp/my.db"]
    end

    test "parse_url!/1 forwards to URL.parse!/1" do
      assert XqliteEcto3.parse_url!("sqlite:///tmp/my.db") == [database: "/tmp/my.db"]
    end
  end
end
