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

    NULL_IN_C = 0
    private_constant :NULL_IN_C

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
        in :getlocal_WC_0
          assembler.mov(
            :rax,
            [CFP, ::RubyVM::RJIT::C.rb_control_frame_t.offsetof(:ep)]
          )
          assembler.mov(
            STACK[stack_size],
            [:rax, -instruction_sequence.body.iseq_encoded[index + 1] * ::RubyVM::RJIT::C.VALUE.size]
          )
          stack_size += 1
        in :leave
          assembler.add(CFP, ::RubyVM::RJIT::C.rb_control_frame_t.size)
          assembler.mov([EC, ::RubyVM::RJIT::C.rb_execution_context_t.offsetof(:cfp)], CFP)
          assembler.mov(:rax, STACK[stack_size - 1])
          assembler.ret
        in :nop
          # none
        in :opt_lt
          rhs = STACK[stack_size - 1]
          lhs = STACK[stack_size - 2]
          stack_size -= 1
          assembler.cmp(lhs, rhs)
          assembler.mov(lhs, ::RubyVM::RJIT::C.to_value(false))
          assembler.mov(:rax, ::RubyVM::RJIT::C.to_value(true))
          assembler.cmovl(lhs, :rax)
        in :opt_minus
          rhs = STACK[stack_size - 1]
          lhs = STACK[stack_size - 2]
          stack_size -= 1
          assembler.sub(lhs, rhs)
          assembler.add(lhs, 1)
        in :opt_plus
          rhs = STACK[stack_size - 1]
          lhs = STACK[stack_size - 2]
          stack_size -= 1
          assembler.add(lhs, rhs)
          assembler.sub(lhs, 1)
        in :opt_send_without_block
          call_data = ::RubyVM::RJIT::C.rb_call_data.new(
            instruction_sequence.body.iseq_encoded[index + 1]
          )
          callee_instruction_sequence = call_data.cc.cme_.def.body.iseq.iseqptr

          # Compile callee if it is not done yet.
          if callee_instruction_sequence.body.jit_func == NULL_IN_C
            compile(callee_instruction_sequence)
          end

          arguments_count = ::RubyVM::RJIT::C.vm_ci_argc(call_data.ci)

          # Push argument1, argument2, ..., argumentN to cfp->sp.
          assembler.mov(
            :rax,
            [CFP, ::RubyVM::RJIT::C.rb_control_frame_t.offsetof(:sp)]
          )
          arguments_count.times do |i|
            assembler.mov(
              [:rax, ::RubyVM::RJIT::C.VALUE.size * i],
              STACK[stack_size - arguments_count + i]
            )
          end

          # Push a new control frame to call stack, and then set cfp->sp, cfp->ep, and cfp->self.
          assembler.sub(
            CFP,
            ::RubyVM::RJIT::C.rb_control_frame_t.size
          )
          assembler.add(
            :rax,
            ::RubyVM::RJIT::C.VALUE.size * (arguments_count + 3) # arguments + cme + block_handler + frame type (callee EP)
          )
          assembler.mov(
            [CFP, ::RubyVM::RJIT::C.rb_control_frame_t.offsetof(:sp)],
            :rax
          )
          assembler.sub(
            :rax,
            ::RubyVM::RJIT::C.VALUE.size
          )
          assembler.mov(
            [CFP, ::RubyVM::RJIT::C.rb_control_frame_t.offsetof(:ep)],
            :rax
          )
          assembler.sub(
            :rax,
            STACK[stack_size - arguments_count - 1]
          )
          assembler.mov(
            [CFP, ::RubyVM::RJIT::C.rb_control_frame_t.offsetof(:self)],
            :rax
          )

          # Call the callee.
          STACK.each do |register|
            assembler.push(register)
          end
          assembler.call(callee_instruction_sequence.body.jit_func)
          STACK.reverse_each do |register|
            assembler.pop(register)
          end
          stack_size -= arguments_count
          assembler.mov(
            STACK[stack_size - 1],
            :rax
          )
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
        in :putself
          assembler.mov(
            STACK[stack_size],
            [CFP, ::RubyVM::RJIT::C.rb_control_frame_t.offsetof(:self)]
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
