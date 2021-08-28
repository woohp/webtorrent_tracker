defmodule WebtorrentTrackerWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use WebtorrentTrackerWeb.ChannelCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import WebtorrentTrackerWeb.ChannelCase
    end
  end

  setup _tags do
    :ok
  end

  def json_encode!(message) do
    Phoenix.json_library().encode!(message)
  end

  def json_decode!(body) do
    Phoenix.json_library().decode!(body)
  end

  defmacro assert_receive_nothing(timeout \\ nil) do
    quote do
      timeout = ExUnit.Assertions.__timeout__(unquote(timeout), :assert_receive_timeout)

      receive do
        item ->
          opts = struct(Inspect.Opts, [])
          doc = Inspect.Algebra.group(Inspect.Algebra.to_doc(item, opts))
          chardata = Inspect.Algebra.format(doc, opts.width)
          flunk("Exected no messages, got\n#{chardata}")
      after
        timeout -> :ok
      end
    end
  end
end
