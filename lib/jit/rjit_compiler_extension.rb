module JIT
  module RJITCompilerExtension
    # @param [RubyVM::InstructionSequence] instruction_sequence
    # @return [void]
    # @note Overriding `RubyVM::RJIT::Compiler#compile`.
    #   This method is called if the same method is called N times,
    #   which is configured by --rjit-call-threshold option.
    def compile(instruction_sequence, _)
      compiler.compile(instruction_sequence)
    end

    private

    # @return [JIT::Compiler]
    def compiler
      @compiler ||= Compiler.new
    end
  end
end
