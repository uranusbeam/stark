require 'thrift_optz/ast'

module ThriftOptz
  class Ruby
    def initialize(stream=STDOUT)

      @namespace = nil
      @indent = 0
      @structs = {}
      @enums = {}

      @stream = stream


      o "require 'thrift_optz/client'"
      o "require 'thrift_optz/struct'"
      o "require 'thrift_optz/field'"
      o "require 'thrift_optz/converters'"
      o "require 'thrift_optz/processor'"
    end

    def process_namespace(ns)
      @namespace = ns.namespace if ns.lang == "rb"
    end

    def process_include(inc)
    end

    def process_enum(enum)
      e = "Enum_#{enum.name}"
      o "#{e} = Hash.new { |h,k| p [:bad, k]; h[k] = -1 }"

      idx = 0
      enum.values.each do |f|
        o "#{e}[#{idx}] = :'#{f}'"
        o "#{e}[:'#{f}'] = #{idx}"
        idx += 1
      end

      @enums[enum.name] = enum
    end

    def process_struct(str)
      @structs[str.name] = str

      o "class #{str.name} < ThriftOptz::Struct"
      indent
      o "Fields = {"
      indent

      str.fields.each do |f|
        c = "ThriftOptz::Converters::#{f.type.upcase}"

        o "#{f.index} => ThriftOptz::Field.new(#{f.index}, '#{f.name}', #{c}),"
      end

      o ":count => #{str.fields.size}"

      outdent
      o "}"
      outdent
      o "end"

    end

    def o(str)
      @stream.print(" " * @indent)
      @stream.puts str
    end

    def indent
      @indent += 2
    end

    def outdent
      @indent -= 2
    end

    CoreTypes = {
      'bool' => "::Thrift::Types::BOOL",
      'byte' => "::Thrift::Types::BYTE",
      'double' => "::Thrift::Types::DOUBLE",
      'i16' => "::Thrift::Types::I16",
      'i32' => "::Thrift::Types::I32",
      'i64' => "::Thrift::Types::I64",
      'string' => '::Thrift::Types::STRING',
      'struct' => '::Thrift::Types::STRUCT',
      'map' => '::Thrift::Types::MAP',
      'set' => '::Thrift::Types::SET',
      'list' => '::Thrift::Types::LIST'
    }

    ReadFunc = {
      'bool' => 'read_bool',
      'byte' => 'read_byte',
      'double' => 'read_double',
      'i16' => "read_i16",
      'i32' => "read_i32",
      'i64' => "read_i64",
      'string' => 'read_string',
    }

    WriteFunc = {
      'bool' => 'write_bool',
      'byte' => 'write_byte',
      'double' => 'write_double',
      'i16' => "write_i16",
      'i32' => "write_i32",
      'i64' => "write_i64",
      'string' => 'write_string',
    }

    def type(t)
      CoreTypes[t] || raise("unknown type - #{t}")
    end

    def wire_type(t)
      return "::Thrift::Types::STRUCT" if @structs[t]
      return "::Thrift::Types::I32" if @enums[t]

      case t
      when ThriftOptz::Parser::AST::Map
        "::Thrift::Types::MAP"
      when ThriftOptz::Parser::AST::List
        "::Thrift::Types::LIST"
      when ThriftOptz::Parser::AST::Set
        "::Thrift::Types::SET"
      else
        type t
      end
    end

    def object_type(t)
      return t if @structs[t]
      type t
    end

    def read_func(t)
      ReadFunc[t] || raise("unknown type - #{t}")
    end

    def write_func(t)
      WriteFunc[t] || raise("unknown type - #{t}")
    end

    def output_struct(desc, obj)
      o "op.write_struct_begin '#{desc.name}'"

      desc.fields.each do |f|
        if desc = @structs[f.type]
          o "op.write_field_begin '#{f.name}', ::Thrift::Types::STRUCT, #{f.index}"
          output_struct desc, f.name
          o "op.write_field_end"
        else
          o "op.write_field_begin '#{f.name}', #{type(f.type)}, #{f.index}"
          o "op.#{write_func(f.type)} #{obj}.#{f.name}"
          o "op.write_field_end"
        end
      end

      o "op.write_field_stop"
      o "op.write_struct_end"
    end

    def write_processor(serv)
      o "class Processor < ThriftOptz::Processor"
      indent

      serv.functions.each do |func|
        o "def process_#{func.name}(seqid, ip, op)"
        indent

        o "ip.read_struct_begin"
        args = Array(func.arguments)
        o "args = Array.new(#{args.size})"

        args.each do |arg|
          if desc = @structs[arg.type]
            o "_, rtype, rid = ip.read_field_begin"
            o "if rtype != #{wire_type(arg.type)}"
            o "  handle_unexpected rtype"
            o "else"
            o "  args[#{arg.index - 1}] = read_struct ip, rtype, rid, #{desc.name}"
            o "end"
            o "ip.read_field_end"
          elsif desc = @enums[arg.type]
            o "_, rtype, _ = ip.read_field_begin"
            o "if rtype != #{wire_type(arg.type)}"
            o "  handle_unexpected rtype"
            o "else"
            o "  args[#{arg.index - 1}] = Enum_#{desc.name}[ip.read_i32]"
            o "end"
            o "ip.read_field_end"

          elsif arg.type.kind_of? ThriftOptz::Parser::AST::Map
            ft = arg.type

            o "_, rtype, _ = ip.read_field_begin"
            o "if rtype != #{wire_type(arg.type)}"
            o "  handle_unexpected rtype"
            o "else"
            o "  kt, vt, size = ip.read_map_begin"
            o "  if kt == #{wire_type(ft.key)} && vt == #{wire_type(ft.value)}"
            o "    result = {}"
            o "    size.times do"
            o "      result[ip.#{read_func(ft.key)}] = ip.#{read_func(ft.value)}"
            o "    end"
            o "    args[#{arg.index - 1}] = result"
            o "  else"
            o "    handle_bad_map size"
            o "  end"
            o "  ip.read_map_end"
            o "end"
            o "ip.read_field_end"
          elsif arg.type.kind_of? ThriftOptz::Parser::AST::List
            ft = arg.type
            o "_, rtype, _ = ip.read_field_begin"
            o "if rtype == ::Thrift::Types::LIST"
            o "  vt, size = ip.read_list_begin"
            o "  if vt == #{wire_type(ft.value)}"
            o "    args[#{arg.index - 1}] = Array.new(size) { |n| ip.#{read_func(ft.value)} }"
            o "  else"
            o "    handle_bad_list size"
            o "  end"
            o "  ip.read_list_end"
            o "else"
            o "  handle_unexpected rtype"
            o "end"
            o "ip.read_field_end"
          else
            o "_, rtype, _ = ip.read_field_begin"
            o "if rtype == #{type(arg.type)}"
            o "  args[#{arg.index - 1}]= ip.#{read_func(arg.type)}"
            o "else"
            o "  handle_unexpected rtype"
            o "end"
            o "ip.read_field_end"
          end
        end

        o "_, rtype, _ = ip.read_field_begin"
        o "fail unless rtype == ::Thrift::Types::STOP"
        o "ip.read_struct_end"
        o "ip.read_message_end"

        o "result = @handler.#{func.name}(*args)"

        o "op.write_message_begin '#{func.name}', ::Thrift::MessageTypes::REPLY, seqid"
        o "op.write_struct_begin '#{func.name}_result'"

        ft = func.return_type

        if desc = @structs[ft]
          o "op.write_field_begin 'result', ::Thrift::Types::STRUCT, 0"
          output_struct desc, "result"
          o "op.write_field_end"
        elsif desc = @enums[ft]
          o "op.write_field_begin 'result', ::Thrift::Types::I32, 0"
          o "op.write_i32 Enum_#{desc.name}[result.to_sym]"

          o "op.write_field_end"
        elsif ft.kind_of? ThriftOptz::Parser::AST::Map
          o "result = hash_cast result"
          o "op.write_field_begin 'result', ::Thrift::Types::MAP, 0"
          o "op.write_map_begin(#{wire_type(ft.key)}, #{wire_type(ft.value)}, result.size)"

          o "result.each do |k,v|"
          indent
          o "op.#{write_func(ft.key)} k"
          o "op.#{write_func(ft.value)} v"
          outdent
          o "end"

          o "op.write_map_end"
          o "op.write_field_end"
        elsif ft.kind_of? ThriftOptz::Parser::AST::List
          o "result = Array(result)"
          o "op.write_field_begin 'result', ::Thrift::Types::LIST, 0"
          o "op.write_list_begin(#{wire_type(ft.value)}, result.size)"
          o "result.each { |v| op.#{write_func(ft.value)}(v) }"
          o "op.write_list_end"

          o "op.write_field_end"
        elsif ft != "void"
          o "op.write_field_begin 'result', #{type(ft)}, 0"
          o "op.#{write_func(ft)} result"
          o "op.write_field_end"
        end

        o "op.write_field_stop"
        o "op.write_struct_end"
        o "op.write_message_end"
        o "op.trans.flush"
        o "return result"

        outdent
        o "end"
      end

      outdent
      o "end"
    end

    def process_service(serv)
      o "module #{serv.name}"
      indent
      o "class Client < ThriftOptz::Client"
      indent

      o "Functions = {}"
      serv.functions.each do |func|
        o "Functions[\"#{func.name}\"] = {"

        o "    :args => {"

        Array(func.arguments).each do |a|
          o "      #{a.index} => #{wire_type(a.type)}"
        end

        o "    }"
        o "  }"
      end

      serv.functions.each do |func|
        names = Array(func.arguments).map { |f| f.name }.join(", ")

        o "def #{func.name}(#{names})"
        indent
        o "op = @oprot"
        o "op.write_message_begin '#{func.name}', ::Thrift::MessageTypes::CALL, 0"
        o "op.write_struct_begin \"#{func.name}_args\""

        Array(func.arguments).each do |arg|
          if desc = @structs[arg.type]
            o "op.write_field_begin '#{arg.name}', ::Thrift::Types::STRUCT, #{arg.index}"
            output_struct desc, arg.name
            o "op.write_field_end"
          elsif desc = @enums[arg.type]
            o "op.write_field_begin '#{arg.name}', ::Thrift::Types::I32, #{arg.index}"
            o "op.write_i32 Enum_#{desc.name}[#{arg.name}.to_sym]"

            o "op.write_field_end"
          elsif arg.type.kind_of? ThriftOptz::Parser::AST::Map
            o "#{arg.name} = hash_cast #{arg.name}"
            o "op.write_field_begin '#{arg.name}', ::Thrift::Types::MAP, #{arg.index}"
            o "op.write_map_begin(#{wire_type(arg.type.key)}, #{wire_type(arg.type.value)}, #{arg.name}.size)"

            o "#{arg.name}.each do |k,v|"
            indent
            o "op.#{write_func(arg.type.key)} k"
            o "op.#{write_func(arg.type.value)} v"
            outdent
            o "end"

            o "op.write_map_end"
            o "op.write_field_end"
          elsif arg.type.kind_of? ThriftOptz::Parser::AST::List
            o "#{arg.name} = Array(#{arg.name})"
            o "op.write_field_begin '#{arg.name}', ::Thrift::Types::LIST, #{arg.index}"
            o "op.write_list_begin(#{wire_type(arg.type.value)}, #{arg.name}.size)"
            o "#{arg.name}.each { |v| op.#{write_func(arg.type.value)}(v) }"
            o "op.write_list_end"

            o "op.write_field_end"
          elsif arg.type != "void"
            o "op.write_field_begin '#{arg.name}', #{type(arg.type)}, #{arg.index}"
            o "op.#{write_func(arg.type)} #{arg.name}"
            o "op.write_field_end"
          end
        end

        o "op.write_field_stop"
        o "op.write_struct_end"
        o "op.write_message_end"
        o "op.trans.flush"

        o "ip = @iprot"
        o "_, mtype, _ = ip.read_message_begin"
        o "handle_exception mtype"

        o "ip.read_struct_begin"
        o "result = nil"

        if func.return_type == "void"
          o "_, rtype, _ = ip.read_field_begin"
        else
          if desc = @structs[func.return_type]
            o "_, rtype, rid = ip.read_field_begin"
            o "if rtype != #{wire_type(func.return_type)}"
            o "  handle_unexpected rtype"
            o "else"
            o "  result = read_generic rtype, rid, #{desc.name}"
            o "end"
          elsif desc = @enums[func.return_type]
            o "_, rtype, rid = ip.read_field_begin"
            o "if rtype != #{wire_type(func.return_type)}"
            o "  handle_unexpected rtype"
            o "else"
            o "  result = Enum_#{desc.name}[ip.read_i32]"
            o "end"

          elsif func.return_type.kind_of? ThriftOptz::Parser::AST::Map
            ft = func.return_type

            o "_, rtype, rid = ip.read_field_begin"
            o "if rtype != #{wire_type(func.return_type)}"
            o "  handle_unexpected rtype"
            o "else"
            o "  kt, vt, size = ip.read_map_begin"
            o "  if kt == #{wire_type(ft.key)} && vt == #{wire_type(ft.value)}"
            o "    result = {}"
            o "    size.times do"
            o "      result[ip.#{read_func(ft.key)}] = ip.#{read_func(ft.value)}"
            o "    end"
            o "  else"
            o "    handle_bad_map size"
            o "  end"
            o "  ip.read_map_end"
            o "end"
          elsif func.return_type.kind_of? ThriftOptz::Parser::AST::List
            ft = func.return_type
            o "_, rtype, rid = ip.read_field_begin"
            o "if rtype == ::Thrift::Types::LIST"
            o "  vt, size = ip.read_list_begin"
            o "  if vt == #{wire_type(ft.value)}"
            o "    result = Array.new(size) { |n| ip.#{read_func(ft.value)} }"
            o "  else"
            o "    handle_bad_list size"
            o "  end"
            o "  ip.read_list_end"
            o "else"
            o "  handle_unexpected rtype"
            o "end"
          else
            o "_, rtype, _ = ip.read_field_begin"
            o "if rtype == #{type(func.return_type)}"
            o "  result = ip.#{read_func(func.return_type)}"
            o "else"
            o "  handle_unexpected rtype"
            o "end"
          end

          o "_, rtype, rid = ip.read_field_begin unless rtype == ::Thrift::Types::STOP"
        end

        o "fail if rtype != ::Thrift::Types::STOP"

        o "ip.read_struct_end"
        o "ip.read_message_end"
        o "return result"

        outdent

        o "end"
      end

      outdent
      o "end"

      write_processor serv

      outdent
      o "end"
    end
  end

end

