require 'ffi'
require 'ffi/tools/const_generator'
require "eventmachine"

# 
# To debug when developing, add the environment 
# variables NLDBG=4 NLCB=debug
# 

module NL
  extend FFI::Library
  ffi_lib 'libnl-3.so'
  ['CN_IDX_PROC','CN_VAL_PROC','NETLINK_CONNECTOR','NLMSG_DONE'].each do |const|
    const_set(const,FFI::ConstGenerator.new(nil, :required => true) do |gen|
      gen.include 'linux/connector.h'
      gen.include 'linux/netlink.h'
      gen.const(const)
    end[const].to_i)
  end

  Event = enum( :PROC_EVENT_NONE , 0x00000000,
                :PROC_EVENT_FORK , 0x00000001,
                :PROC_EVENT_EXEC , 0x00000002,
                :PROC_EVENT_UID  , 0x00000004,
                :PROC_EVENT_GID  , 0x00000040,
                :PROC_EVENT_SID  , 0x00000080,
                :PROC_EVENT_PTRACE , 0x00000100,
                :PROC_EVENT_COMM , 0x00000200,
                :PROC_EVENT_EXIT , -0x80000000)
  
  class Cn_data_msg < FFI::Struct
    layout :idx, :uint32, 
    :val, :uint32,
    :seq, :uint32,
    :ack, :uint32,
    :len, :uint16,
    :flags, :uint16,
    :what, Event,
    :cpu, :uint32,
    :timestamp_ns, :uint64,
    :pid, :uint32,
    :tid, :uint32 
  end

  class Cn_msg < FFI::Struct
    layout :idx, :uint32, 
    :val, :uint32,
    :seq, :uint32,
    :ack, :uint32,
    :len, :uint16,
    :flags, :uint16,
    :data, :uint32
  end

  attach_function :nl_socket_alloc, [], :pointer
  attach_function :nl_socket_get_fd, [:pointer], :int
  attach_function :nl_connect, [:pointer,:int], :int
  attach_function :nlmsg_data, [:pointer], :pointer
  attach_function :nl_send_auto, [:pointer,:pointer], :int
  attach_function :nl_geterror, [:int], :string
  attach_function :nl_socket_disable_seq_check, [:pointer], :void
  attach_function :nlmsg_alloc_simple, [:int, :int], :pointer
  attach_function :nlmsg_reserve, [:pointer, :size_t, :int], :pointer
  attach_function :nl_socket_disable_auto_ack, [:pointer], :void
  attach_function :nl_join_groups, [:pointer, :int], :void
  attach_function :nl_socket_enable_msg_peek, [:pointer], :void
  attach_function :nl_recv, [:pointer, :pointer, :pointer, :pointer], :int
  attach_function :nlmsg_ok, [:pointer, :int], :int

  def self.error?(what,error,abovezero=nil)
    if abovezero && error>=0
      puts "#{what}: #{abovezero} (#{error})"
    else
      puts "#{what}: #{NL.nl_geterror(error)} (#{error})"
    end
  end
end

nl=NL.nl_socket_alloc()
NL.nl_socket_disable_seq_check(nl)
NL.nl_join_groups(nl,NL::CN_IDX_PROC)
NL.error?("Attemping to connect to netlink",NL.nl_connect(nl,NL::NETLINK_CONNECTOR))
NL.nl_socket_disable_auto_ack(nl)
NL.nl_socket_disable_seq_check(nl)
sock=NL.nl_socket_get_fd(nl)

netlink_message=NL.nlmsg_alloc_simple(NL::NLMSG_DONE,0)
data=NL.nlmsg_reserve(netlink_message,24,4)

proc_message=NL::Cn_msg.new(data)
proc_message[:idx] = NL::CN_IDX_PROC;
proc_message[:val] = NL::CN_VAL_PROC;
proc_message[:data] = 1
proc_message[:len]=4 # Contains an int
proc_message[:seq]=0
proc_message[:ack]=0

NL.error?("Sending message",NL.nl_send_auto(nl,netlink_message),"Sent")

# Alternatively, you can also attach the file descriptor to eventmachine
# fd=BasicSocket.for_fd(NL.nl_socket_get_fd(nl))
# conn = EM.attach(fd,Handler)

NL.nl_socket_enable_msg_peek(nl)
empty_nl_struct = FFI::MemoryPointer.new(32)
pointer_to_buffer_pointer = FFI::MemoryPointer.new(:pointer)
while true
  data_length=NL.nl_recv(nl,empty_nl_struct,pointer_to_buffer_pointer,nil)
  if data_length > 0 && (buffer_pointer=pointer_to_buffer_pointer.read_pointer) && NL.nlmsg_ok(buffer_pointer, data_length)>0
    nlmsg_data=NL.nlmsg_data(buffer_pointer)
    proc_reply=NL::Cn_data_msg.new(nlmsg_data)
    begin
      case proc_reply[:what]
      when :PROC_EVENT_FORK
        puts IO.read("/proc/#{proc_reply[:pid]}/cmdline").split("\0").join(" ")+" forked"
      when :PROC_EVENT_EXEC
        puts IO.read("/proc/#{proc_reply[:pid]}/cmdline").split("\0").join(" ")+" execed"
      when :PROC_EVENT_EXIT
        puts "#{proc_reply[:pid]} died"
      end
    rescue Errno::ENOENT, Errno::ESRCH
      puts "#{proc_reply[:pid]} did not live long enough to identify"
    end
  end
end
