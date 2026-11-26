if System.get_env("HARMONY_LIBBEAM") == "1",
  do: ExUnit.start(),
  else: ExUnit.start(exclude: [:libbeam])
