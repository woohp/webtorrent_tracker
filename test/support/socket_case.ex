defmodule WebtorrentTrackerWeb.SocketCase do
  @moduledoc """
  This module defines the test case to be used by our custom socket tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import WebtorrentTrackerWeb.SocketCase
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

  def receive_json(timeout \\ nil) do
    timeout = ExUnit.Assertions.__timeout__(timeout, :assert_receive_timeout)

    receive do
      <<body::binary>> -> json_decode!(body)
    after
      timeout -> flunk("failed to receive message")
    end
  end

  def assert_receive_nothing(timeout \\ nil) do
    timeout = ExUnit.Assertions.__timeout__(timeout, :assert_receive_timeout)

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
