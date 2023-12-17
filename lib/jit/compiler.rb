require_relative 'assembler'

module JIT
  class Compiler
    JIT_BUFFER_SIZE = 1024 * 1024
    private_constant :JIT_BUFFER_SIZE

    # @note We use these registers as a stack.
    STACK = %i[
      r8
      r9
      r10
      r11
    ]
    private_constant :STACK

    # @note "EC" means "execution context".
    EC = :rdi
    private_constant :EC

    # @note "CFP" means "control frame pointer".
    CFP = :rsi
    private_constant :CFP

    def initialize
      @jit_buffer_address = ::RubyVM::RJIT::C.mmap(JIT_BUFFER_SIZE)
      @jit_buffer_offset = 0
    end

    # @param [RubyVM::InstructionSequence] instruction_sequence
    # @return [void]
    def compile(instruction_sequence)
      assembler = Assembler.new

      stack_size = 0
      iterate_instructions(instruction_sequence) do |instruction, index|
        case instruction.name
        in :leave
          assembler.add(CFP, ::RubyVM::RJIT::C.rb_control_frame_t.size)
          assembler.mov([EC, ::RubyVM::RJIT::C.rb_execution_context_t.offsetof(:cfp)], CFP)
          assembler.mov(:rax, STACK[stack_size - 1])
          assembler.ret
        in :nop
          # none
        in :opt_plus
          rhs = STACK[stack_size - 1]
          lhs = STACK[stack_size - 2]
          stack_size -= 1
          assembler.add(lhs, rhs)
          assembler.sub(lhs, 1)
        in :putnil
          assembler.mov(
            STACK[stack_size],
            ::RubyVM::RJIT::C.to_value(nil)
          )
          stack_size += 1
        in :putobject
          assembler.mov(
            STACK[stack_size],
            instruction_sequence.body.iseq_encoded[index + 1]
          )
          stack_size += 1
        in :putobject_INT2FIX_0_
          assembler.mov(
            STACK[stack_size],
            ::RubyVM::RJIT::C.to_value(0)
          )
          stack_size += 1
        in :putobject_INT2FIX_1_
          assembler.mov(
            STACK[stack_size],
            ::RubyVM::RJIT::C.to_value(1)
          )
          stack_size += 1
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
    # @yield [RubyVM::RJIT::Instruction, Integer]
    # @return [void]
    def iterate_instructions(instruction_sequence)
      index = 0
      while index < instruction_sequence.body.iseq_size
        instruction = ::RubyVM::RJIT::INSNS.fetch(
          ::RubyVM::RJIT::C.rb_vm_insn_decode(
            instruction_sequence.body.iseq_encoded[index]
          )
        )
        yield instruction, index
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
