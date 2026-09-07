defmodule SSHClient.SSH.AuthTest do
  use ExUnit.Case, async: true

  alias SSHClient.Host
  alias SSHClient.SSH.Auth

  @temp_dir Path.join(System.tmp_dir!(), "ssh_auth_test_#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@temp_dir)

    File.write!(Path.join(@temp_dir, "test_id_rsa"), "dummy_rsa")
    File.write!(Path.join(@temp_dir, "test_id_ed25519"), "dummy_ed25519")
    File.write!(Path.join(@temp_dir, "custom_key"), "dummy_custom")

    on_exit(fn ->
      File.rm_rf(@temp_dir)
    end)

    :ok
  end

  describe "resolve_identities/1" do
    test "tries custom path, id_ed25519, id_rsa in order" do
      custom_key = Path.join(@temp_dir, "custom_key")

      identities =
        Auth.resolve_identities(
          user_dir: @temp_dir,
          identity_file: custom_key,
          standard_key_names: ["test_id_ed25519", "test_id_rsa"]
        )

      assert length(identities) == 3
      assert Path.expand(Enum.at(identities, 0)) == Path.expand(custom_key)
      assert Path.expand(Enum.at(identities, 1)) == Path.expand(Path.join(@temp_dir, "test_id_ed25519"))
      assert Path.expand(Enum.at(identities, 2)) == Path.expand(Path.join(@temp_dir, "test_id_rsa"))
    end

    test "resolves standard identities in order when no custom key is provided" do
      identities =
        Auth.resolve_identities(
          user_dir: @temp_dir,
          standard_key_names: ["test_id_ed25519", "test_id_rsa"]
        )

      assert length(identities) == 2
      assert Enum.at(identities, 0) == Path.join(@temp_dir, "test_id_ed25519")
      assert Enum.at(identities, 1) == Path.join(@temp_dir, "test_id_rsa")
    end

    test "ignores non-existent custom key" do
      identities =
        Auth.resolve_identities(
          user_dir: @temp_dir,
          identity_file: "/non/existent/path",
          standard_key_names: ["test_id_ed25519", "test_id_rsa"]
        )

      assert length(identities) == 2
      assert Enum.at(identities, 0) == Path.join(@temp_dir, "test_id_ed25519")
    end
  end

  describe "auth_methods_for_order/1" do
    test "converts default order to charlists" do
      methods = Auth.auth_methods_for_order([:key, :password, :keyboard_interactive])
      assert methods == ~c"publickey,password,keyboard-interactive"
    end

    test "respects per-host auth order override" do
      methods = Auth.auth_methods_for_order([:password, :key])
      assert methods == ~c"password,publickey"

      kbi_first = Auth.auth_methods_for_order([:keyboard_interactive, :password])
      assert kbi_first == ~c"keyboard-interactive,password"
    end

    test "handles single atom or nil" do
      assert Auth.auth_methods_for_order(:password) == ~c"password"

      assert Auth.auth_methods_for_order(nil) ==
               ~c"publickey,password,keyboard-interactive"
    end
  end

  describe "build_keyboard_interactive_fun/1" do
    test "wraps 3-arity function and returns charlist answers" do
      custom_fun = fn name, instruction, prompts ->
        assert name == "OTP SSH"
        assert instruction == "Enter credentials"
        assert prompts == [{"Password: ", false}]
        ["secret_password"]
      end

      kbi = Auth.build_keyboard_interactive_fun(custom_fun)
      assert is_function(kbi, 3)

      answers = kbi.(~c"OTP SSH", ~c"Enter credentials", [{~c"Password: ", false}])
      assert answers == [~c"secret_password"]
    end

    test "supports map of prompt substrings to answers" do
      answer_map = %{
        "password" => "my_pass",
        "verification code" => "123456"
      }

      kbi = Auth.build_keyboard_interactive_fun(answer_map)

      prompts = [
        {~c"Enter your password: ", false},
        {~c"Verification code: ", false}
      ]

      answers = kbi.(~c"", ~c"", prompts)
      assert answers == [~c"my_pass", ~c"123456"]
    end

    test "supports static string fallback" do
      kbi = Auth.build_keyboard_interactive_fun("always_the_same")
      answers = kbi.(~c"", ~c"", [{~c"Token: ", false}])
      assert answers == [~c"always_the_same"]
    end
  end

  describe "build_options/2" do
    test "builds options from %Host{} struct with custom order and identity" do
      custom_key = Path.join(@temp_dir, "custom_key")

      host = %Host{
        id: "test-cloud-vm",
        name: "Cloud VM",
        address: "10.0.0.1",
        port: 2222,
        user: "ubuntu",
        auth_method: :keyboard_interactive,
        auth_order: [:keyboard_interactive, :password],
        identity_file: custom_key
      }

      opts = Auth.build_options(host, password: "temp_password")

      assert Keyword.get(opts, :auth_methods) == ~c"keyboard-interactive,password"
      assert Keyword.get(opts, :password) == ~c"temp_password"
      assert Path.expand(to_string(Keyword.get(opts, :user_dir))) == Path.expand(Path.dirname(custom_key))
    end

    test "resolves password from PassphraseCache if cached in memory" do
      SSHClient.PassphraseCache.put("password:deploy@staging-box", "ephemeral-secret-999")
      target = %{id: "staging-box", user: "deploy", auth_method: :password}
      opts = Auth.build_options(target)
      assert Keyword.get(opts, :password) == ~c"ephemeral-secret-999"
    end
  end
end
