require_relative 'assembler'

module JIT
  class Compiler
    JIT_BUFFER_SIZE = 1024 * 1024
    private_constant :JIT_BUFFER_SIZE

    def initialize
      @jit_buffer_address = ::RubyVM::RJIT::C.mmap(JIT_BUFFER_SIZE)
      @jit_buffer_offset = 0
    end

    # @param [RubyVM::InstructionSequence] instruction_sequence
    # @return [void]
    def compile(instruction_sequence)
      assembler = Assembler.new

      iterate_instructions(instruction_sequence) do |instruction|
        case instruction.name
        in :nop
          # none
        end
      end

      write_jit_function(
        assembler: assembler,
        instruction_sequence: instruction_sequence
      )
    rescue ::Exception => e
      abort e.full_message
    end

    private

    # @param [RubyVM::InstructionSequence] instruction_sequence
    # @yield [RubyVM::RJIT::Instruction]
    # @return [void]
    def iterate_instructions(instruction_sequence)
      index = 0
      while index < instruction_sequence.body.iseq_size
        instruction = ::RubyVM::RJIT::INSNS.fetch(
          ::RubyVM::RJIT::C.rb_vm_insn_decode(
            instruction_sequence.body.iseq_encoded[index]
          )
        )
        yield instruction
        index += instruction.len
      end
    end

    # Write bytes in a given assembler into @jit_buffer_address.
    # @param [JIT::Assembler] assembler
    # @return [Integer]
    def write(assembler)
      jit_address = @jit_buffer_address + @jit_buffer_offset

      # Append machine code to the JIT buffer.
      ::RubyVM::RJIT::C.mprotect_write(@jit_buffer_address, JIT_BUFFER_SIZE) # Make JTI buffer writable.
      assembled_bytes_size = assembler.assemble(jit_address)
      ::RubyVM::RJIT::C.mprotect_exec(@jit_buffer_address, JIT_BUFFER_SIZE) # Make JIT buffer executable.

      # Dump disassembly if --rjit-dump-disasm.
      if ::RubyVM::RJIT::C.rjit_opts.dump_disasm
        ::RubyVM::RJIT::C.dump_disasm(jit_address, jit_address + assembled_bytes_size).each do |address, mnemonic, operands_in_string|
          puts format(
            '  0x%<address>x: %<mnemonic>s %<operands_in_string>s',
            address:,
            mnemonic:,
            operands_in_string:
          )
        end
        puts
      end

      @jit_buffer_offset += assembled_bytes_size

      jit_address
    end

    # @param [JIT::Assembler] assembler
    # @param [RubyVM::InstructionSequence] instruction_sequence
    # @return [void]
    def write_jit_function(assembler:, instruction_sequence:)
      instruction_sequence.body.jit_func = write(assembler)
    end
  end
end
