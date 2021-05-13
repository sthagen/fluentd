#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

module Fluent
  module FileWrapper
    def self.open(*args)
      io = WindowsFile.new(*args).io
      if block_given?
        v = yield io
        io.close
        v
      else
        io
      end
    end

    def self.stat(path)
      f = WindowsFile.new(path)
      s = f.stat
      f.close
      s
    end
  end

  module WindowsFileExtension
    attr_reader :path

    def stat
      s = super
      s.instance_variable_set :@ino, @ino
      def s.ino; @ino; end
      s
    end
  end

  class Win32Error < StandardError
    require 'windows/error'
    include Windows::Error

    attr_reader :errcode, :msg

    def initialize(errcode, msg = nil)
      @errcode = errcode
      @msg = msg
    end

    def format_english_message(errcode)
      buf = 0.chr * 260
      flags = FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_ARGUMENT_ARRAY
      english_lang_id = 1033 # The result of MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US)
      FormatMessageA.call(flags, 0, errcode, english_lang_id, buf, buf.size, 0)
      buf.force_encoding(Encoding.default_external).strip
    end

    def to_s
      msg = super
      msg << ": code: #{@errcode}, #{format_english_message(@errcode)}"
      msg << " - #{@msg}" if @msg
      msg
    end

    def inspect
      "#<#{to_s}>"
    end

    def ==(other)
      return false if other.class != Win32Error
      @errcode == other.errcode && @msg == other.msg
    end
  end

  # To open and get stat with setting FILE_SHARE_DELETE
  class WindowsFile
    require 'windows/file'
    require 'windows/error'
    require 'windows/handle'
    require 'windows/nio'

    include Windows::Error
    include Windows::File
    include Windows::Handle
    include Windows::NIO

    def initialize(path, mode='r', sharemode=FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE)
      @path = path
      @file_handle = INVALID_HANDLE_VALUE
      @mode = mode


      access, creationdisposition, seektoend = case mode.delete('b')
      when "r" ; [FILE_GENERIC_READ                     , OPEN_EXISTING, false]
      when "r+"; [FILE_GENERIC_READ | FILE_GENERIC_WRITE, OPEN_ALWAYS  , false]
      when "w" ; [FILE_GENERIC_WRITE                    , CREATE_ALWAYS, false]
      when "w+"; [FILE_GENERIC_READ | FILE_GENERIC_WRITE, CREATE_ALWAYS, false]
      when "a" ; [FILE_GENERIC_WRITE                    , OPEN_ALWAYS  , true]
      when "a+"; [FILE_GENERIC_READ | FILE_GENERIC_WRITE, OPEN_ALWAYS  , true]
      else raise "unknown mode '#{mode}'"
      end

      @file_handle = CreateFile.call(@path, access, sharemode,
                     0, creationdisposition, FILE_ATTRIBUTE_NORMAL, 0)
      if @file_handle == INVALID_HANDLE_VALUE
        err = Win32::API.last_error
        if err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND || err == ERROR_ACCESS_DENIED
          raise Errno::ENOENT
        end
        raise Win32Error.new(err, path)
      end
    end

    def close
      CloseHandle.call(@file_handle)
      @file_handle = INVALID_HANDLE_VALUE
    end

    def io
      fd = _open_osfhandle(@file_handle, 0)
      raise Errno::ENOENT if fd == -1
      io = File.for_fd(fd, @mode)
      io.instance_variable_set :@ino, self.ino
      io.instance_variable_set :@path, @path
      io.extend WindowsFileExtension
      io
    end

    def ino
      by_handle_file_information = '\0'*(4+8+8+8+4+4+4+4+4+4)   #72bytes

      unless GetFileInformationByHandle.call(@file_handle, by_handle_file_information)
        return 0
      end

      by_handle_file_information.unpack("I11Q1")[11] # fileindex
    end

    def stat
      s = File.stat(@path)
      s.instance_variable_set :@ino, self.ino
      def s.ino; @ino; end
      s
    end
  end
end if Fluent.windows?
