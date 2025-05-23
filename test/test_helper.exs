# Compile support files
Code.compile_file("test/support/example_shared_steps.ex")
Code.compile_file("test/support/shared_steps/authentication.ex")
Code.compile_file("test/support/shared_steps/shopping.ex")

ExUnit.start()
