require_relative 'jit/compiler'
require_relative 'jit/rjit_compiler_extension'
require_relative 'jit/version'

return unless RubyVM::RJIT.enabled?

# Replace RJIT with JIT::Compiler.
RubyVM::RJIT::Compiler.prepend JIT::RJITCompilerExtension

# Enable JIT compilation (paused by --rjit=pause)
RubyVM::RJIT.resume
