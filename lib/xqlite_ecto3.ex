defmodule XqliteEcto3 do
  @moduledoc """
  Ecto 3.x adapter for SQLite via xqlite.

  ## Usage

      # In your config:
      config :my_app, MyApp.Repo,
        adapter: XqliteEcto3,
        database: "priv/my_app.db"

      # In your repo:
      defmodule MyApp.Repo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: XqliteEcto3
      end
  """

  use Ecto.Adapters.SQL,
    driver: :xqlite_ecto3

  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure

  @impl Ecto.Adapter.Storage
  def storage_up(opts) do
    database = Keyword.fetch!(opts, :database)

    if File.exists?(database) do
      {:error, :already_up}
    else
      database
      |> Path.dirname()
      |> File.mkdir_p!()

      {:ok, conn} = XqliteNIF.open(database)
      XqliteNIF.close(conn)
      :ok
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_down(opts) do
    database = Keyword.fetch!(opts, :database)

    case File.rm(database) do
      :ok ->
        File.rm(database <> "-wal")
        File.rm(database <> "-shm")
        :ok

      {:error, :enoent} ->
        {:error, :already_down}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_status(opts) do
    database = Keyword.fetch!(opts, :database)

    if File.exists?(database) do
      :up
    else
      :down
    end
  end

  @impl Ecto.Adapter.Structure
  def structure_dump(default, config) do
    database = Keyword.fetch!(config, :database)
    path = config[:dump_path] || Path.join(default, "structure.sql")

    case System.cmd("sqlite3", [database, ".dump"], stderr_to_stdout: true) do
      {dump, 0} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, dump)
        {:ok, path}

      {output, _code} ->
        {:error, output}
    end
  end

  @impl Ecto.Adapter.Structure
  def structure_load(default, config) do
    database = Keyword.fetch!(config, :database)
    path = config[:dump_path] || Path.join(default, "structure.sql")

    case File.read(path) do
      {:ok, sql} ->
        {:ok, conn} = XqliteNIF.open(database)
        result = XqliteNIF.execute_batch(conn, sql)
        XqliteNIF.close(conn)

        case result do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, reason} ->
        {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end

  @impl Ecto.Adapter.Structure
  def dump_cmd(_args, _opts, _config) do
    raise "dump_cmd is not supported — use structure_dump/2 instead"
  end

  @impl Ecto.Adapter.Migration
  def supports_ddl_transaction?, do: true

  @impl Ecto.Adapter.Migration
  def lock_for_migrations(_meta, _options, fun) do
    fun.()
  end

  @impl Ecto.Adapter.Schema
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: Ecto.UUID.generate()

  @impl Ecto.Adapter
  def loaders(:boolean, type), do: [&bool_decode/1, type]
  def loaders(:naive_datetime, type), do: [&naive_datetime_decode/1, type]
  def loaders(:naive_datetime_usec, type), do: [&naive_datetime_decode/1, type]
  def loaders(:utc_datetime, type), do: [&utc_datetime_decode/1, type]
  def loaders(:utc_datetime_usec, type), do: [&utc_datetime_decode/1, type]
  def loaders(:date, type), do: [&date_decode/1, type]
  def loaders(:time, type), do: [&time_decode/1, type]
  def loaders(:time_usec, type), do: [&time_decode/1, type]
  def loaders(:map, type), do: [&json_decode/1, type]
  def loaders({:map, _}, type), do: [&json_decode/1, type]
  def loaders({:array, _}, type), do: [&json_decode/1, type]
  def loaders(_, type), do: [type]

  @impl Ecto.Adapter
  def dumpers(:boolean, type), do: [type, &bool_encode/1]
  def dumpers(_, type), do: [type]

  defp bool_decode(0), do: {:ok, false}
  defp bool_decode(1), do: {:ok, true}
  defp bool_decode(nil), do: {:ok, nil}

  defp bool_decode(x) do
    {:error, "expected 0 or 1 for boolean column, got: #{inspect(x)}"}
  end

  defp bool_encode(false), do: {:ok, 0}
  defp bool_encode(true), do: {:ok, 1}
  defp bool_encode(x), do: {:ok, x}

  defp naive_datetime_decode(val) when is_binary(val) do
    case NaiveDateTime.from_iso8601(val) do
      {:ok, dt} -> {:ok, dt}
      _ -> {:ok, val}
    end
  end

  defp naive_datetime_decode(val), do: {:ok, val}

  defp utc_datetime_decode(val) when is_binary(val) do
    case DateTime.from_iso8601(val) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:ok, val}
    end
  end

  defp utc_datetime_decode(val), do: {:ok, val}

  defp date_decode(val) when is_binary(val) do
    case Date.from_iso8601(val) do
      {:ok, d} -> {:ok, d}
      _ -> {:ok, val}
    end
  end

  defp date_decode(val), do: {:ok, val}

  defp time_decode(val) when is_binary(val) do
    case Time.from_iso8601(val) do
      {:ok, t} -> {:ok, t}
      _ -> {:ok, val}
    end
  end

  defp time_decode(val), do: {:ok, val}

  defp json_decode(val) when is_binary(val) do
    case Jason.decode(val) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:ok, val}
    end
  end

  defp json_decode(val), do: {:ok, val}
end
