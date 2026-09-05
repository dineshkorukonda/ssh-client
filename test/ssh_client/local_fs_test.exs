defmodule SSHClient.LocalFSTest do
  use ExUnit.Case, async: true

  alias SSHClient.LocalFS

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "local_fs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "default_path/0" do
    test "returns a valid string path" do
      path = LocalFS.default_path()
      assert is_binary(path)
      assert File.dir?(path)
    end
  end

  describe "list_dir/1" do
    test "lists and sorts entries with folders first", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file_b.txt"), "hello")
      File.write!(Path.join(tmp_dir, "file_a.txt"), "world")
      File.mkdir_p!(Path.join(tmp_dir, "subfolder"))

      {:ok, entries} = LocalFS.list_dir(tmp_dir)
      names = Enum.map(entries, & &1.name)

      # Directory first, then alphabetical files
      assert hd(names) == "subfolder"
      assert "file_a.txt" in names
      assert "file_b.txt" in names
    end
  end

  describe "parent_dir/1" do
    test "returns parent directory path", %{tmp_dir: tmp_dir} do
      sub = Path.join(tmp_dir, "nested")
      File.mkdir_p!(sub)

      parent = LocalFS.parent_dir(sub)
      assert Path.expand(parent) == Path.expand(tmp_dir)
    end
  end

  describe "file operations" do
    test "writes, reads, and deletes a local file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "sample.txt")
      assert LocalFS.write_file(path, "test payload") == :ok
      assert LocalFS.read_file(path) == {:ok, "test payload"}
      assert LocalFS.delete_path(path) == :ok
      assert File.exists?(path) == false
    end
  end

  describe "format_size/1" do
    test "formats bytes properly" do
      assert LocalFS.format_size(500) == "500 B"
      assert LocalFS.format_size(2048) == "2.0 KB"
      assert LocalFS.format_size(10_485_760) == "10.0 MB"
      assert LocalFS.format_size(2_147_483_648) == "2.0 GB"
    end
  end
end
